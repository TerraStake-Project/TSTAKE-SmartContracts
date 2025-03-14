// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@chainlink/contracts/src/v0.8/vrf/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";


import "../interfaces/ITerraStakeRewardDistributor.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";
import "../interfaces/ITerraStakeSlashing.sol";
import "../interfaces/ITerraStakeTreasuryManager.sol";

/**
 * @title TerraStakeLiquidityGuard
 * @notice Manages liquidity for the TerraStake protocol
 * @dev Protects against liquidity attacks, implements anti-whale mechanisms
 */
contract TerraStakeLiquidityGuard is 
    Initializable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    VRFConsumerBaseV2
{
    using SafeERC20 for IERC20;

    // -------------------------------------------
    //  Core State Variables
    // -------------------------------------------
    ITerraStakeTreasuryManager public treasuryManager;
    ITerraStakeRewardDistributor public rewardDistributor;
    ISwapRouter public swapRouter;
    VRFCoordinatorV2Interface public vrfCoordinator;
    ERC20Upgradeable public tStakeToken;
    ERC20Upgradeable public usdcToken;
    INonfungiblePositionManager public positionManager;
    IUniswapV3Pool public uniswapPool;
    uint256 public tokenID;
    uint128 public liquidity;
    uint256 public amount0;
    uint256 public amount1;
    uint256 public tStakeAmount;
    uint256 public usdcAmount;

    // -------------------------------------------
    //  Roles
    // -------------------------------------------
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant TREASURY_MANAGER_ROLE = keccak256("TREASURY_MANAGER_ROLE");
    bytes32 public constant REWARD_DISTRIBUTOR_ROLE = keccak256("REWARD_DISTRIBUTOR_ROLE");

    // -------------------------------------------
    //  Constants
    // -------------------------------------------
    uint256 constant ONE_DAY = 1 days;
    uint256 constant ONE_WEEK = 7 days;
    uint256 constant PERCENTAGE_DENOMINATOR = 100;
    uint256 constant DEFAULT_SLIPPAGE_TOLERANCE = 50; // 0.5%
    uint24 constant DEFAULT_POOL_FEE = 3000; // 0.3%

    // -------------------------------------------
    //  Errors
    // -------------------------------------------
    error InvalidAddress(string param);
    error InvalidZeroAddress(string param);
    error InvalidParameter(string param, uint256 value);
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error DailyLiquidityLimitExceeded(uint256 requested, uint256 available);
    error WeeklyLiquidityLimitExceeded(uint256 requested, uint256 available);
    error LiquidityCooldownNotMet(uint256 remainingTime);
    error TooEarlyToWithdraw(uint256 available, uint256 requested);
    error TWAPVerificationFailed(uint256 currentPrice, uint256 twapPrice);
    error PositionNotFound(uint256 _tokenID);
    error OperationFailed(string operation);
    error EmergencyModeActive();
    error EmergencyModeNotActive();
    error InvalidTWAPTimeframe(uint256 timeframe);
    error SlippageExceeded(uint256 expected, uint256 received);

    // -------------------------------------------
    //  Events
    // -------------------------------------------
    event LiquidityDeposited(address indexed user, uint256 amount);
    event LiquidityRemoved(
        address indexed user,
        uint256 amount,
        uint256 fee,
        uint256 remainingLiquidity,
        uint256 timestamp
    );
    event LiquidityInjected(
        uint256 tStakeAmount,
        uint256 usdcAmount,
        uint256 _tokenID,
        uint128 liquidity
    );
    event PositionLiquidityDecreased(
        uint256 indexed _tokenID,
        uint128 liquidityReduced,
        uint256 token0Amount,
        uint256 token1Amount
    );
    event PositionClosed(uint256 indexed _tokenID);
    event PositionFeesCollected(
        uint256 indexed _tokenID,
        uint256 token0Fee,
        uint256 token1Fee
    );
    event ParameterUpdated(string paramName, uint256 value);
    event EmergencyModeActivated(address activator);
    event EmergencyModeDeactivated(address deactivator);
    event RewardsReinvested(uint256 rewardAmount, uint256 liquidityAdded);
    event TWAPVerificationFailedEvent(uint256 currentPrice, uint256 twapPrice);
    event WhitelistStatusChanged(address user, bool status);

    // Anti-whale mechanism parameters
    uint256 public dailyWithdrawalLimit; // % of user's total liquidity
    uint256 public weeklyWithdrawalLimit; // % of user's total liquidity
    uint256 public vestingUnlockRate; // % unlocked per week
    uint256 public baseFeePercentage; // Base fee for withdrawals
    uint256 public largeLiquidityFeeIncrease; // Additional fee for large withdrawals
    uint256 public liquidityRemovalCooldown; // Time between withdrawals
    uint256 public maxLiquidityPerAddress; // Optional cap per address
    
    // Liquidity management parameters
    uint256 public reinjectionThreshold; // Minimum amount for reinvesting rewards
    uint256 public autoLiquidityInjectionRate; // % of rewards for auto-liquidity
    uint256 public slippageTolerance; // Basis points (0.01%)
    
    // User data
    mapping(address => uint256) public userLiquidity;
    mapping(address => uint256) public userVestingStart;
    mapping(address => uint256) public dailyWithdrawalAmount;
    mapping(address => uint256) public lastDailyWithdrawal;
    mapping(address => uint256) public weeklyWithdrawalAmount;
    mapping(address => uint256) public lastWeeklyWithdrawal;
    mapping(address => uint256) public lastLiquidityRemoval;
    mapping(address => bool) public liquidityWhitelist;
    
    // Position tracking
    uint256[] public activePositions;
    mapping(uint256 => bool) public isPositionActive;
    
    // TWAP price protection
    uint256[] public twapObservationTimeframes;
    uint256 public twapDeviationPercentage; // Maximum allowed deviation
    
    // Analytics and statistics
    uint256 public totalFeesCollected;
    uint256 public totalWithdrawalCount;
    uint256 public largeWithdrawalCount;
    
    // Emergency controls
    bool public emergencyMode;

    // -------------------------------------------
    //  Initialization
    // -------------------------------------------
    
    //  **Constructor for Upgradeable Contracts**
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _vrfCoordinator) VRFConsumerBaseV2(_vrfCoordinator) {
        _disableInitializers();
    }
  
    /**
     * @notice Initialize the liquidity guard contract
     * @param _tStakeToken Address of the TerraStake token
     * @param _usdcToken Address of the USDC token
     * @param _positionManager Address of the Uniswap position manager
     * @param _uniswapPool Address of the Uniswap pool
     * @param _rewardDistributor Address of the reward distributor
     * @param _treasuryManager Address of the treasury manager
     * @param _reinjectionThreshold Minimum amount for liquidity reinjection
     * @param _admin Address of the admin
     */
    function initialize(
        address _tStakeToken,
        address _usdcToken,
        address _positionManager,
        address _uniswapPool,
        address _rewardDistributor,
        address _treasuryManager,
        uint256 _reinjectionThreshold,
        address _admin
    ) external initializer {
        // Initialize OpenZeppelin upgradeable modules
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        // **Ensure all required addresses are valid**
        if (_tStakeToken == address(0)) revert InvalidAddress("tStakeToken");
        if (_usdcToken == address(0)) revert InvalidAddress("usdcToken");
        if (_positionManager == address(0)) revert InvalidAddress("positionManager");
        if (_uniswapPool == address(0)) revert InvalidAddress("uniswapPool");
        if (_rewardDistributor == address(0)) revert InvalidAddress("rewardDistributor");
        if (_treasuryManager == address(0)) revert InvalidAddress("treasuryManager");
        if (_admin == address(0)) revert InvalidAddress("admin");

        //  **Assign State Variables**
        tStakeToken = ERC20Upgradeable(_tStakeToken);
        usdcToken = ERC20Upgradeable(_usdcToken);
        positionManager = INonfungiblePositionManager(_positionManager);
        uniswapPool = IUniswapV3Pool(_uniswapPool);
        rewardDistributor = ITerraStakeRewardDistributor(_rewardDistributor);
        treasuryManager = ITerraStakeTreasuryManager(_treasuryManager);

        //  **Set default anti-whale parameters**
        dailyWithdrawalLimit = 5;      // 5% per day
        weeklyWithdrawalLimit = 25;    // 25% per week
        vestingUnlockRate = 10;        // 10% unlocks per week
        baseFeePercentage = 2;         // 2% base fee
        largeLiquidityFeeIncrease = 8; // +8% for large withdrawals (>50%)
        liquidityRemovalCooldown = 7 days; // 7-day cooldown period

        //  **Set reinjection threshold with a default fallback**
        reinjectionThreshold = (_reinjectionThreshold != 0) ? _reinjectionThreshold : 1e18; // Default to 1 token if 0
        autoLiquidityInjectionRate = 5; // Default 5% auto-liquidity injection rate
        slippageTolerance = DEFAULT_SLIPPAGE_TOLERANCE; // Use predefined default slippage tolerance

        //  **Set TWAP observation timeframes**
        twapObservationTimeframes = [30 minutes, 1 hours, 4 hours, 24 hours];

        //  **Grant Roles**
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(GOVERNANCE_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
        _grantRole(TREASURY_MANAGER_ROLE, _treasuryManager);
        _grantRole(REWARD_DISTRIBUTOR_ROLE, _rewardDistributor);
    }
 
    /**
     * @notice Authorize contract upgrades (restricted to upgrader role)
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // -------------------------------------------
    //  Liquidity Management - Core Functions
    // -------------------------------------------
    
    /**
     * @notice Add liquidity to the contract
     * @param amount Amount of tokens to add as liquidity
     */
    function depositLiquidity(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidParameter("amount", amount);
        
        // Check max liquidity per address if configured
        if (maxLiquidityPerAddress > 0) {
            if (userLiquidity[msg.sender] + amount > maxLiquidityPerAddress) {
                revert InvalidParameter("exceeds max liquidity per address", userLiquidity[msg.sender] + amount);
            }
        }        
        // Transfer tokens to the contract
        IERC20(address(tStakeToken)).safeTransferFrom(msg.sender, address(this), amount);
        
        // Update user's liquidity position
        userLiquidity[msg.sender] += amount;
        
        // Set vesting start time if first deposit
        if (userVestingStart[msg.sender] == 0) {
            userVestingStart[msg.sender] = block.timestamp;
        }
        
        emit LiquidityDeposited(msg.sender, amount);
    }
    /**
     * @notice Reinvest rewards into liquidity
     * @param tickLower Lower tick boundary for position
     * @param tickUpper Upper tick boundary for position
     */
    function reinvestRewards(int24 tickLower, int24 tickUpper) 
        external 
        nonReentrant 
        onlyRole(OPERATOR_ROLE) 
    {
        if (emergencyMode) revert EmergencyModeActive();
        if (address(rewardDistributor) == address(0)) revert InvalidZeroAddress("rewardDistributor");
        
        // Claim rewards from distributor
        uint256 _rewardAmount = rewardDistributor.claimRewards(address(this));
        
        if (_rewardAmount < reinjectionThreshold) {
            revert InvalidParameter("rewardAmount", _rewardAmount);
        }
        
        // Calculate auto-liquidity portion
        uint256 liquidityPortion = (_rewardAmount * autoLiquidityInjectionRate) / 100;
        
        // Get equivalent USDC from TreasuryManager
        if (address(treasuryManager) != address(0) && liquidityPortion > 0) {
            uint256 _usdcAmount = treasuryManager.withdrawUSDCEquivalent(liquidityPortion);
            
            if (_usdcAmount > 0) {
                // Approve tokens
                IERC20(address(tStakeToken)).approve(address(positionManager), liquidityPortion);
                IERC20(address(usdcToken)).approve(address(positionManager), _usdcAmount);
                
                // Create the position
                INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
                    token0: address(tStakeToken),
                    token1: address(usdcToken),
                    fee: DEFAULT_POOL_FEE,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    amount0Desired: liquidityPortion,
                    amount1Desired: _usdcAmount,
                    amount0Min: liquidityPortion * (10000 - slippageTolerance) / 10000,
                    amount1Min: _usdcAmount * (10000 - slippageTolerance) / 10000,
                    recipient: address(this),
                    deadline: block.timestamp + 15 minutes
                });
                
                // Using different variable names to avoid shadowing
                (uint256 _new__tokenID, uint128 _newLiquidity, uint256 _amount0, uint256 _amount1) = positionManager.mint(params);
                
                // Add to active positions
                if (!isPositionActive[_new__tokenID]) {
                    activePositions.push(_new__tokenID);
                    isPositionActive[_new__tokenID] = true;
                }
                
                emit RewardsReinvested(_rewardAmount, liquidityPortion);
            }
        }
    }
    
    // -------------------------------------------
    //  TWAP Validation Functions
    // -------------------------------------------
    
    /**
     * @notice Validate TWAP price against current price
     * @return valid True if TWAP price is valid
     */
    function validateTWAPPrice() public view returns (bool valid) {
        uint256 twapPrice = calculateTWAP();
        if (twapPrice == 0) return true; // If no TWAP, allow the operation
        
        // Get current price
        (uint160 sqrtPriceX96,,,,,,) = uniswapPool.slot0();
        uint256 currentPrice = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> (96 * 2);
        
        // Allow if price is close enough to TWAP
        uint256 maxDeviation = (twapPrice * twapDeviationPercentage) / 100;
        
        // Check if current price is within acceptable range of TWAP
        if (currentPrice >= twapPrice - maxDeviation && currentPrice <= twapPrice + maxDeviation) {
            return true;
        }
        
        return false;
    }

    /**
     * @notice
     * @return 
     */
    function verifyTWAPForWithdrawal() external view returns (bool success) {
        return false;
    }
    
    /**
     * @notice Calculate TWAP price across multiple timeframes
     * @return twap The calculated time-weighted average price
     */
    function calculateTWAP() public view returns (uint256 twap) {
        if (twapObservationTimeframes.length == 0) return 0;
        uint256 totalPrice = 0;
        uint32 totalWeight = 0;
        
        // Get current secondsAgo for observation
        uint32 currentTimestamp = uint32(block.timestamp);
        
        for (uint256 i = 0; i < twapObservationTimeframes.length; i++) {
            uint32 secondsAgo = uint32(twapObservationTimeframes[i]);
            
            // Get observations for time period
            uint32[] memory secondsAgos = new uint32[](2);
            secondsAgos[0] = secondsAgo;
            secondsAgos[1] = 0; // Current observation
            
            try uniswapPool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidity) {
                // Calculate tick change over time period
                int56 tickChange = tickCumulatives[1] - tickCumulatives[0];
                int56 timeChange = int56(uint56(secondsAgo));
                int24 avgTick = int24(tickChange / timeChange);
                
                // Convert tick to price
                uint256 price = tickToPrice(avgTick);
                
                // Weight longer time periods more heavily
                totalPrice += price * secondsAgo;
                totalWeight += secondsAgo;
            } catch {
                // Skip this timeframe if observation fails
                continue;
            }
        }
        
        // Calculate weighted average
        if (totalWeight > 0) {
            return totalPrice / totalWeight;
        }
        
        return 0;
    }
    
    /**
     * @notice Convert tick to price
     * @param tick The tick to convert
     * @return price The calculated price
     */
    function tickToPrice(int24 tick) internal pure returns (uint256 price) {
        // Solidity doesn't support floating point, so we need to use a different approach
        // 1.0001^tick is approximated using a formula based on the tick value
        uint256 baseValue = 1e12; // Use a fixed-point representation
        
        if (tick < 0) {
            // For negative ticks, we divide by 1.0001^|tick|
            uint256 absTick = uint256(-int256(tick));
            uint256 divisor = 1000100000000; // Approximation of 1.0001^1 * 10^12
            for (uint256 i = 0; i < absTick; i++) {
                baseValue = (baseValue * 1e12) / divisor;
            }
        } else {
            // For positive ticks, we multiply by 1.0001^tick
            uint256 multiplier = 1000100000000; // Approximation of 1.0001^1 * 10^12
            for (uint256 i = 0; i < uint256(int256(tick)); i++) {
                baseValue = (baseValue * multiplier) / 1e12;
            }
        }
        
        return baseValue;
    }
    
    // -------------------------------------------
    //  Helper Functions
    // -------------------------------------------
    
    /**
     * @notice Remove a position from the active positions array
     * @param _tokenID The token ID to remove
     */
    function removePositionFromActive(uint256 _tokenID) internal {
        if (!isPositionActive[_tokenID]) return;
        
        // Find and remove the position from the array
        for (uint256 i = 0; i < activePositions.length; i++) {
            if (activePositions[i] == _tokenID) {
                // Replace with the last element and pop
                activePositions[i] = activePositions[activePositions.length - 1];
                activePositions.pop();
                isPositionActive[_tokenID] = false;
                break;
            }
        }
    }
    
    /**
     * @notice Calculate the withdrawal fee based on amount and user activity
     * @param user Address of the user
     * @param amount Amount being withdrawn
     * @return fee The calculated fee amount
     */
    function getWithdrawalFee(address user, uint256 amount) public view returns (uint256 fee) {
        // Whitelisted addresses pay no fees
        if (liquidityWhitelist[user]) return 0;
        
        uint256 totalUserLiquidity = userLiquidity[user] + amount; // Include the withdrawal amount
        uint256 withdrawalPercentage = (amount * 100) / totalUserLiquidity;
        
        // Base fee applies to everyone
        fee = (amount * baseFeePercentage) / 100;
        
        // Additional fee for large withdrawals
        if (withdrawalPercentage > 50) {
            fee += (amount * largeLiquidityFeeIncrease) / 100;
        }
        
        return fee;
    }
    
    /**
     * @notice Get the number of active liquidity positions
     * @return count The number of active positions
     */
    function getActivePositionsCount() external view returns (uint256 count) {
        return activePositions.length;
    }
    
    /**
     * @notice Get all active position IDs
     * @return positions Array of active position IDs
     */
    function getAllActivePositions() external view returns (uint256[] memory positions) {
        return activePositions;
    }
    
    // -------------------------------------------
    //  Admin Functions
    // -------------------------------------------
    
    /**
     * @notice Update the daily withdrawal limit
     * @param newLimit New daily withdrawal limit (percentage)
     */
    function setDailyWithdrawalLimit(uint256 newLimit) external onlyRole(GOVERNANCE_ROLE) {
        if (newLimit > 100) revert InvalidParameter("newLimit", newLimit);
        dailyWithdrawalLimit = newLimit;
        emit ParameterUpdated("dailyWithdrawalLimit", newLimit);
    }
    
    /**
     * @notice Update the weekly withdrawal limit
     * @param newLimit New weekly withdrawal limit (percentage)
     */
    function setWeeklyWithdrawalLimit(uint256 newLimit) external onlyRole(GOVERNANCE_ROLE) {
        if (newLimit > 100) revert InvalidParameter("newLimit", newLimit);
        weeklyWithdrawalLimit = newLimit;
        emit ParameterUpdated("weeklyWithdrawalLimit", newLimit);
    }
    
    /**
     * @notice Update the vesting unlock rate
     * @param newRate New vesting unlock rate (percentage per week)
     */
    function setVestingUnlockRate(uint256 newRate) external onlyRole(GOVERNANCE_ROLE) {
        if (newRate == 0 || newRate > 100) revert InvalidParameter("newRate", newRate);
        vestingUnlockRate = newRate;
        emit ParameterUpdated("vestingUnlockRate", newRate);
    }
    
    /**
     * @notice Update the base fee percentage
     * @param newFeePercentage New base fee percentage
     */
    function setBaseFeePercentage(uint256 newFeePercentage) external onlyRole(GOVERNANCE_ROLE) {
        if (newFeePercentage > 20) revert InvalidParameter("newFeePercentage", newFeePercentage);
        baseFeePercentage = newFeePercentage;
        emit ParameterUpdated("baseFeePercentage", newFeePercentage);
    }
    
    /**
     * @notice Update the large liquidity fee increase
     * @param newFeeIncrease New fee increase for large withdrawals
     */
    function setLargeLiquidityFeeIncrease(uint256 newFeeIncrease) external onlyRole(GOVERNANCE_ROLE) {
        if (newFeeIncrease > 50) revert InvalidParameter("newFeeIncrease", newFeeIncrease);
        largeLiquidityFeeIncrease = newFeeIncrease;
        emit ParameterUpdated("largeLiquidityFeeIncrease", newFeeIncrease);
    }
    
    /**
     * @notice Update the liquidity removal cooldown
     * @param newCooldown New cooldown period in seconds
     */
    function setLiquidityRemovalCooldown(uint256 newCooldown) external onlyRole(GOVERNANCE_ROLE) {
        liquidityRemovalCooldown = newCooldown;
        emit ParameterUpdated("liquidityRemovalCooldown", newCooldown);
    }
    
    /**
     * @notice Update the maximum liquidity per address
     * @param newMax New maximum amount per address (0 = unlimited)
     */
    function setMaxLiquidityPerAddress(uint256 newMax) external onlyRole(GOVERNANCE_ROLE) {
        maxLiquidityPerAddress = newMax;
        emit ParameterUpdated("maxLiquidityPerAddress", newMax);
    }
    
    /**
     * @notice Update the reinjection threshold
     * @param newThreshold New minimum amount for reinvesting rewards
     */
    function setReinjectionThreshold(uint256 newThreshold) external onlyRole(GOVERNANCE_ROLE) {
        reinjectionThreshold = newThreshold;
        emit ParameterUpdated("reinjectionThreshold", newThreshold);
    }
    
    /**
     * @notice Update the auto liquidity injection rate
     * @param newRate New percentage of rewards to auto-reinvest
     */
    function setAutoLiquidityInjectionRate(uint256 newRate) external onlyRole(GOVERNANCE_ROLE) {
        if (newRate > 100) revert InvalidParameter("newRate", newRate);
        autoLiquidityInjectionRate = newRate;
        emit ParameterUpdated("autoLiquidityInjectionRate", newRate);
    }
    
    /**
     * @notice Update the slippage tolerance
     * @param newTolerance New slippage tolerance in basis points
     */
    function setSlippageTolerance(uint256 newTolerance) external onlyRole(GOVERNANCE_ROLE) {
        if (newTolerance > 1000) revert InvalidParameter("newTolerance", newTolerance);
        slippageTolerance = newTolerance;
        emit ParameterUpdated("slippageTolerance", newTolerance);
    }
    
    /**
     * @notice Update TWAP observation timeframes
     * @param newTimeframes Array of new timeframes in seconds
     */
    function setTWAPObservationTimeframes(uint256[] calldata newTimeframes) external onlyRole(GOVERNANCE_ROLE) {
        if (newTimeframes.length == 0) revert InvalidParameter("newTimeframes", 0);
        
        // Clear existing timeframes
        delete twapObservationTimeframes;
        
        // Add new timeframes
        for (uint256 i = 0; i < newTimeframes.length; i++) {
            if (newTimeframes[i] == 0 || newTimeframes[i] > 7 days) {
                revert InvalidTWAPTimeframe(newTimeframes[i]);
            }
            twapObservationTimeframes.push(uint32(newTimeframes[i]));
        }
    }
    // -------------------------------------------
    //  Emergency Functions
    // -------------------------------------------
    
    /**
     * @notice Activate emergency mode
     */
    function activateEmergencyMode() external onlyRole(EMERGENCY_ROLE) {
        emergencyMode = true;
        emit EmergencyModeActivated(msg.sender);
    }
    
    /**
     * @notice Deactivate emergency mode
     */
    function deactivateEmergencyMode() external onlyRole(EMERGENCY_ROLE) {
        emergencyMode = false;
        emit EmergencyModeDeactivated(msg.sender);
    }
    
    /**
     * @notice Emergency withdraw all tokens from a specific position
     * @param ___tokenID ID of the position to withdraw from
     */
    function emergencyWithdrawPosition(uint256 ___tokenID) external onlyRole(EMERGENCY_ROLE) {
        if (!emergencyMode) revert EmergencyModeNotActive();
        if (!isPositionActive[___tokenID]) revert PositionNotFound(___tokenID);
        
        // Get position info
        (, , , , , , , uint128 _liquidity, , , , ) = positionManager.positions(___tokenID);
        
        if (_liquidity > 0) {
            // First decrease all liquidity
            INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams = 
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: ___tokenID,
                    liquidity: _liquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp + 15 minutes
                });
            
            positionManager.decreaseLiquidity(decreaseParams);
        }
        
        // Collect all tokens
        INonfungiblePositionManager.CollectParams memory collectParams = 
            INonfungiblePositionManager.CollectParams({
                tokenId: ___tokenID,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });
        
        positionManager.collect(collectParams);
        
        // Remove from active positions
        removePositionFromActive(___tokenID);
    }
    
    /**
     * @notice Emergency recovery of tokens
     * @param token Address of token to recover
     * @param amount Amount to recover
     * @param recipient Address to send recovered tokens to
     */
    function emergencyTokenRecovery(
        address token,
        uint256 amount,
        address recipient
    ) external onlyRole(EMERGENCY_ROLE) {
        if (!emergencyMode) revert EmergencyModeNotActive();
        if (recipient == address(0)) revert InvalidZeroAddress("recipient");
        
        IERC20(token).safeTransfer(recipient, amount);
    }

    /**
     * @notice Required function for VRF callback
     * @param requestId The ID of the VRF request
     * @param randomWords The array of random values
     */
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        // Implementation for VRF callback - can be used for stochastic mechanisms
    }
}