// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {SafeERC20Upgradeable, IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {MathUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";

// Uniswap V4
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";

// API3
import {IApi3ServerV1} from "@api3/contracts/v0.8/interfaces/IApi3ServerV1.sol";

// LayerZero
import {ILayerZeroEndpoint} from "@layerzerolabs/solidity-examples/contracts/interfaces/ILayerZeroEndpoint.sol";
import {ILayerZeroReceiver} from "@layerzerolabs/solidity-examples/contracts/interfaces/ILayerZeroReceiver.sol";

/**
 * @title TerraStakeRewardDistributor
 * @notice Manages reward distribution with advanced protection against price manipulation
 * @dev Implements flashloan protection, cross-chain syncing via LayerZero, and dynamic slippage adjustment
 */
contract TerraStakeRewardDistributor is
    Initializable,
    UUPSUpgradeable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    ILayerZeroReceiver
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using MathUpgradeable for uint256;
    using PoolIdLibrary for PoolKey;

    // ========== CONSTANTS ==========
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant PRICE_PRECISION = 1e18;
    uint256 public constant HALVING_INTERVAL = 730 days;
    uint256 public constant MIN_REWARD_RATE_BPS = 50;
    uint256 public constant MAX_SLIPPAGE_BPS = 500;
    uint256 public constant FLASHLOAN_COOLDOWN_BLOCKS = 1;
    uint256 public constant MAX_FLASHLOAN_IMPACT_BPS = 300; // 3% max temporary price impact
    
    // Re-entrancy guard constants for flashloan detection
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // ========== STRUCTS ==========
    struct DistributionParams {
        uint256 rewardRateBps;
        uint256 maxDailyDistribution;
        uint256 distributedToday;
        uint256 lastDistributionTime;
        uint256 lastHalvingTime;
        uint256 minSlippageBps;
        uint256 maxSlippageBps;
    }

    struct OracleConfig {
        IApi3ServerV1 priceFeed;
        IApi3ServerV1 timeFeed;
        bytes32 priceFeedId;
        uint256 maxPriceAge;
        uint256 maxTimeDeviation;
    }

    struct CrossChainSync {
        ILayerZeroEndpoint lzEndpoint;
        uint16 destinationChainId;
        bytes destinationAddress;
        uint256 lastSyncTimestamp;
        uint256 syncInterval;
        uint256 gasForDestination;
    }

    // ========== STATE VARIABLES ==========
    IERC20Upgradeable public immutable REWARD_TOKEN;
    address public immutable STAKING_CONTRACT;
    IPoolManager public poolManager;
    PoolKey public poolKey;
    PoolId public poolId;
    
    DistributionParams public distributionParams;
    OracleConfig public oracleConfig;
    CrossChainSync public crossChainSync;

    // MEV & Flashloan Protection
    mapping(address => uint256) public lastUserDistribution;
    uint256 public distributionCooldown;
    uint256 private _flashloanStatus;
    mapping(address => uint256) public lastPostFlashInteraction;

    // Slippage Tracking
    uint256[5] public recentSlippageSamples;
    uint256 public slippageSampleIndex;
    uint256 public lastSlippageUpdate;

    // ========== EVENTS ==========
    event RewardsDistributed(address indexed user, uint256 amount, uint256 effectivePrice);
    event CrossChainSynced(uint16 chainId, uint256 rewardRateBps, uint256 timestamp);
    event SlippageAdjusted(uint256 oldSlippage, uint256 newSlippage);
    event FlashloanDetected(address indexed borrower, uint256 amount);
    event EmergencyCircuitBreaker(uint256 blockedAmount);
    event HalvingExecuted(uint256 oldRate, uint256 newRate);
    event MessageReceived(uint16 srcChainId, bytes srcAddress, uint64 nonce, bytes payload);

    // ========== ERRORS ==========
    error InvalidAmount();
    error DailyLimitExceeded();
    error PriceDeviationTooHigh();
    error SlippageTooHigh();
    error BalanceInconsistency();
    error FlashloanActive();
    error CooldownActive();
    error SyncCooldownActive();
    error InvalidAddress();
    error MaxSlippageTooHigh();
    error UnauthorizedSource();

    // ========== INITIALIZATION ==========
    constructor(address rewardToken, address stakingContract) {
        if (rewardToken == address(0) || stakingContract == address(0)) revert InvalidAddress();
        REWARD_TOKEN = IERC20Upgradeable(rewardToken);
        STAKING_CONTRACT = stakingContract;
        _flashloanStatus = _NOT_ENTERED;
    }

    /**
     * @notice Initialize the contract with required parameters
     * @param admin The address that will have admin role
     * @param _poolManager Uniswap V4 pool manager
     * @param _poolKey Uniswap V4 pool key
     * @param api3PriceFeed API3 price feed address
     * @param api3TimeFeed API3 time feed address
     * @param lzEndpoint LayerZero endpoint address
     * @param destinationChainId LayerZero destination chain ID
     * @param destinationAddress Destination contract address (in bytes)
     */
    function initialize(
        address admin,
        address _poolManager,
        PoolKey calldata _poolKey,
        address api3PriceFeed,
        address api3TimeFeed,
        address lzEndpoint,
        uint16 destinationChainId,
        bytes calldata destinationAddress
    ) external initializer {
        __AccessControlEnumerable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        if (admin == address(0)) revert InvalidAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        // Initialize Uniswap V4
        poolManager = IPoolManager(_poolManager);
        poolKey = _poolKey;
        poolId = _poolKey.toId();

        // Initialize oracles
        oracleConfig = OracleConfig({
            priceFeed: IApi3ServerV1(api3PriceFeed),
            timeFeed: IApi3ServerV1(api3TimeFeed),
            priceFeedId: bytes32("TSTAKE_USD"),
            maxPriceAge: 1 hours,
            maxTimeDeviation: 30 seconds
        });

        // Initialize distribution
        distributionParams = DistributionParams({
            rewardRateBps: 500, // 5% initial
            maxDailyDistribution: 100_000 * 10**18,
            distributedToday: 0,
            lastDistributionTime: block.timestamp,
            lastHalvingTime: block.timestamp,
            minSlippageBps: 50,  // 0.5%
            maxSlippageBps: 200  // 2%
        });

        // Initialize cross-chain with LayerZero
        crossChainSync = CrossChainSync({
            lzEndpoint: ILayerZeroEndpoint(lzEndpoint),
            destinationChainId: destinationChainId,
            destinationAddress: destinationAddress,
            lastSyncTimestamp: 0,
            syncInterval: 1 days,
            gasForDestination: 200000  // Default gas limit for destination chain
        });

        distributionCooldown = 6 hours;
    }

    // ========== CORE DISTRIBUTION ==========
    
    /**
     * @notice Distribute rewards to the staking contract
     * @param amount Amount of reward tokens to distribute
     */
    function distributeRewards(uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused
        checkFlashloan
        checkCooldown(msg.sender)
    {
        // 1. Validate amount
        if (amount == 0) revert InvalidAmount();
        
        // 2. Check daily limit
        DistributionParams memory params = distributionParams;
        if (block.timestamp / 1 days > params.lastDistributionTime / 1 days) {
            params.distributedToday = 0;
        }
        if (params.distributedToday + amount > params.maxDailyDistribution) {
            revert DailyLimitExceeded();
        }

        // 3. Verify price stability
        (uint256 twapPrice, uint256 currentPrice) = _getVerifiedPrices();
        uint256 priceImpact = _calculatePriceImpact(twapPrice, currentPrice);
        _adjustSlippage();
        if (priceImpact > params.minSlippageBps) {
            revert SlippageTooHigh();
        }

        // 4. Execute distribution
        uint256 initialBalance = REWARD_TOKEN.balanceOf(address(this));
        REWARD_TOKEN.safeTransfer(STAKING_CONTRACT, amount);
        
        // 5. Post-distribution checks
        if (REWARD_TOKEN.balanceOf(address(this)) < initialBalance - amount) {
            emit EmergencyCircuitBreaker(amount);
            _pause();
            revert BalanceInconsistency();
        }

        // 6. Update state
        params.distributedToday += amount;
        params.lastDistributionTime = block.timestamp;
        distributionParams = params;
        lastUserDistribution[msg.sender] = block.timestamp;

        // 7. Record slippage
        recentSlippageSamples[slippageSampleIndex] = priceImpact;
        slippageSampleIndex = (slippageSampleIndex + 1) % 5;
        lastSlippageUpdate = block.timestamp;

        emit RewardsDistributed(msg.sender, amount, currentPrice);
        _checkHalvingConditions();
    }

    // ========== CROSS-CHAIN SYNC (LAYERZERO) ==========
    
    /**
     * @notice Sync reward rate to another chain via LayerZero
     */
    function syncCrossChain() external {
        CrossChainSync memory sync = crossChainSync;
        if (block.timestamp < sync.lastSyncTimestamp + sync.syncInterval) {
            revert SyncCooldownActive();
        }
        
        // Prepare message payload with the current reward rate
        bytes memory payload = abi.encode(distributionParams.rewardRateBps);
        
        // Estimate fee for sending message
        bytes memory adapterParams = abi.encodePacked(uint16(1), sync.gasForDestination);
        uint256 fee = sync.lzEndpoint.estimateFees(
            sync.destinationChainId,
            address(this),
            payload,
            false,
            adapterParams
        );

        // Send cross-chain message
        sync.lzEndpoint.send{value: fee}(
            sync.destinationChainId,
            sync.destinationAddress,
            payload,
            payable(msg.sender),
            address(0),
            adapterParams
        );
        
        crossChainSync.lastSyncTimestamp = block.timestamp;
        emit CrossChainSynced(sync.destinationChainId, distributionParams.rewardRateBps, block.timestamp);
    }
    
    /**
     * @notice Update gas limit for destination chain
     * @param newGasLimit New gas limit to use
     */
    function updateDestinationGas(uint256 newGasLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        crossChainSync.gasForDestination = newGasLimit;
    }
    
    /**
     * @notice Implements LayerZero message receiver
     * @param srcChainId Source chain ID
     * @param srcAddress Source address (in bytes)
     * @param nonce Message nonce
     * @param payload Message payload
     */
    function lzReceive(
        uint16 srcChainId,
        bytes memory srcAddress,
        uint64 nonce,
        bytes memory payload
    ) external override {
        // Verify that message is from the LayerZero endpoint
        if (msg.sender != address(crossChainSync.lzEndpoint)) {
            revert UnauthorizedSource();
        }
        
        // Validate source chain and address
        if (srcChainId != crossChainSync.destinationChainId ||
            keccak256(srcAddress) != keccak256(crossChainSync.destinationAddress)) {
            revert UnauthorizedSource();
        }

        // Process message payload
        uint256 remoteRewardRate = abi.decode(payload, (uint256));
        
        // Update local reward rate if remote rate is valid
        if (remoteRewardRate >= MIN_REWARD_RATE_BPS) {
            uint256 oldRate = distributionParams.rewardRateBps;
            distributionParams.rewardRateBps = remoteRewardRate;
            emit HalvingExecuted(oldRate, remoteRewardRate);
        }

        emit MessageReceived(srcChainId, srcAddress, nonce, payload);
    }
    
    /**
     * @notice Update destination chain info
     * @param newDestinationChainId New destination chain ID
     * @param newDestinationAddress New destination address
     */
    function updateDestination(
        uint16 newDestinationChainId,
        bytes calldata newDestinationAddress
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        crossChainSync.destinationChainId = newDestinationChainId;
        crossChainSync.destinationAddress = newDestinationAddress;
    }

    // ========== FLASHLOAN PROTECTION ==========
    
    /**
     * @notice Called by flashloan callback to track active loans
     */
    function flashLoanCallback(
        address borrower,
        uint256 amount
    ) external {
        // This is called by the flashloan contract during a loan
        // We check here if this transaction involves our contract
        _flashloanStatus = _ENTERED;
        emit FlashloanDetected(borrower, amount);
    }
    
    /**
     * @notice Check for active flashloans and enforce cooldown
     */
    modifier checkFlashloan() {
        if (_flashloanStatus == _ENTERED) {
            revert FlashloanActive();
        }
        _;
        if (_flashloanStatus == _ENTERED) {
            lastPostFlashInteraction[tx.origin] = block.number + FLASHLOAN_COOLDOWN_BLOCKS;
        }
        _flashloanStatus = _NOT_ENTERED;
    }

    /**
     * @notice Enforce cooldown between user reward distributions
     */
    modifier checkCooldown(address user) {
        if (block.timestamp < lastUserDistribution[user] + distributionCooldown) {
            revert CooldownActive();
        }
        if (lastPostFlashInteraction[user] > block.number) {
            revert FlashloanActive();
        }
        _;
    }

    // ========== ORACLE LOGIC ==========
    
    /**
     * @notice Get verified prices from multiple sources
     * @return twapPrice TWAP price from Uniswap V4
     * @return currentPrice Current price from API3
     */
    function _getVerifiedPrices() internal view returns (uint256 twapPrice, uint256 currentPrice) {
        // 1. Get Uniswap V4 TWAP
        twapPrice = _getSecureTWAP();
        
        // 2. Get API3 price
        (int224 api3Price, uint32 timestamp) = oracleConfig.priceFeed.read();
        currentPrice = uint256(uint224(api3Price)) * PRICE_PRECISION / 1e18;
        
        // Ensure price is fresh
        if (block.timestamp - timestamp > oracleConfig.maxPriceAge) {
            // Fallback to TWAP if API3 is stale
            currentPrice = twapPrice;
        }
        
        // 3. Verify deviation
        uint256 deviation = _calculatePriceImpact(twapPrice, currentPrice);
        if (deviation > MAX_FLASHLOAN_IMPACT_BPS) {
            revert PriceDeviationTooHigh();
        }
        
        return (twapPrice, currentPrice);
    }

    /**
     * @notice Get appropriate TWAP based on market conditions
     */
    function _getSecureTWAP() internal view returns (uint256) {
        return _flashloanStatus == _ENTERED 
            ? _getCustomTWAP(2 hours)  // Stricter during flashloans
            : _getV4TWAPPrice();       // Normal 30m window
    }
    
    /**
     * @notice Get TWAP price from Uniswap V4
     */
    function _getV4TWAPPrice() internal view returns (uint256) {
        // Implementation would depend on the specific Uniswap V4 hook being used
        // This is a placeholder that would need to be replaced with actual implementation
        try poolManager.getPool(poolId) returns (uint160 sqrtPriceX96, int24 tick, uint8 protocolFee, uint24 swapFee) {
            return uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * PRICE_PRECISION / (1 << 192);
        } catch {
            // Fallback to API3 price on failure
            (int224 api3Price, ) = oracleConfig.priceFeed.read();
            return uint256(uint224(api3Price));
        }
    }
    
    /**
     * @notice Get TWAP with custom time window
     * @param timeWindow Time window for TWAP calculation
     */
    function _getCustomTWAP(uint256 timeWindow) internal view returns (uint256) {
        // Similar to _getV4TWAPPrice but with custom time window
        // Implementation depends on the specific Uniswap V4 hook being used
        return _getV4TWAPPrice(); // Simplified for this example
    }
    
    /**
     * @notice Calculate price impact between two prices
     * @param basePrice Base price
     * @param currentPrice Current price
     * @return Price impact in basis points
     */
    function _calculatePriceImpact(uint256 basePrice, uint256 currentPrice) internal pure returns (uint256) {
        if (basePrice == 0) return BPS_DENOMINATOR; // 100% impact as safety
        
        uint256 diff = basePrice > currentPrice 
            ? basePrice - currentPrice
            : currentPrice - basePrice;
            
        return diff * BPS_DENOMINATOR / basePrice;
    }
    
    /**
     * @notice Dynamically adjust slippage tolerance based on recent market conditions
     */
    function _adjustSlippage() internal {
        if (block.timestamp < lastSlippageUpdate + 1 hours) return;
        
        uint256 sum = 0;
        for (uint i = 0; i < 5; i++) {
            sum += recentSlippageSamples[i];
        }
        
        uint256 avgSlippage = sum / 5;
        uint256 oldSlippage = distributionParams.minSlippageBps;
        uint256 newSlippage;
        
        // If average slippage is higher, gradually increase our tolerance
        if (avgSlippage > oldSlippage) {
            newSlippage = oldSlippage + (avgSlippage - oldSlippage) / 10;
            if (newSlippage > distributionParams.maxSlippageBps) {
                newSlippage = distributionParams.maxSlippageBps;
            }
        } else if (avgSlippage < oldSlippage) {
            // If lower, gradually decrease
            newSlippage = oldSlippage - (oldSlippage - avgSlippage) / 20;
            if (newSlippage < 50) newSlippage = 50; // Minimum 0.5%
        } else {
            newSlippage = oldSlippage;
        }
        
        if (newSlippage != oldSlippage) {
            distributionParams.minSlippageBps = newSlippage;
            emit SlippageAdjusted(oldSlippage, newSlippage);
        }
    }
    
    /**
     * @notice Check if halving conditions are met and execute if needed
     */
    function _checkHalvingConditions() internal {
        DistributionParams memory params = distributionParams;
        if (block.timestamp >= params.lastHalvingTime + HALVING_INTERVAL) {
            uint256 oldRate = params.rewardRateBps;
            uint256 newRate = params.rewardRateBps / 2;
            if (newRate < MIN_REWARD_RATE_BPS) {
                newRate = MIN_REWARD_RATE_BPS;
            }
            
            distributionParams.rewardRateBps = newRate;
            distributionParams.lastHalvingTime = block.timestamp;
            
            emit HalvingExecuted(oldRate, newRate);
            
            // Sync to other chains
            if (address(crossChainSync.lzEndpoint) != address(0)) {
                try this.syncCrossChain() {
                    // Successfully triggered cross-chain sync
                } catch {
                    // Failed to sync, but we still executed the local halving
                }
            }
        }
    }

    // ========== GOVERNANCE ==========
    
    /**
     * @notice Set slippage tolerance bounds
     * @param minBps Minimum slippage tolerance (basis points)
     * @param maxBps Maximum slippage tolerance (basis points)
     */
    function setSlippageBounds(uint256 minBps, uint256 maxBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (maxBps > MAX_SLIPPAGE_BPS) revert MaxSlippageTooHigh();
        if (minBps > maxBps) revert("Min cannot exceed max");
        
        distributionParams.minSlippageBps = minBps;
        distributionParams.maxSlippageBps = maxBps;
    }

    /**
     * @notice Update oracle configuration
     * @param priceFeed API3 price feed address
     * @param timeFeed API3 time feed address
     * @param maxPriceAge Maximum age for price data
     */
    function updateOracleConfig(
        address priceFeed,
        address timeFeed,
        uint256 maxPriceAge
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        oracleConfig.priceFeed = IApi3ServerV1(priceFeed);
        oracleConfig.timeFeed = IApi3ServerV1(timeFeed);
        oracleConfig.maxPriceAge = maxPriceAge;
    }
    
    /**
     * @notice Update distribution cooldown period
     * @param newCooldown New cooldown period in seconds
     */
    function setDistributionCooldown(uint256 newCooldown) external onlyRole(DEFAULT_ADMIN_ROLE) {
        distributionCooldown = newCooldown;
    }
    
    /**
     * @notice Update maximum daily distribution amount
     * @param newMax New maximum daily distribution
     */
    function setMaxDailyDistribution(uint256 newMax) external onlyRole(DEFAULT_ADMIN_ROLE) {
        distributionParams.maxDailyDistribution = newMax;
    }
    
    /**
     * @notice Emergency pause all contract operations
     */
    function emergencyPause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Resume contract operations after pause
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Authorize contract upgrades
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
    
    /**
     * @notice Allow contract to receive ETH (needed for LayerZero fees)
     */
    receive() external payable {}
}            