// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import "@uniswap/v4-core/contracts/types/PoolKey.sol";
import "@uniswap/v4-core/contracts/libraries/TickMath.sol";

import "@api3/contracts/v0.8/interfaces/IProxy.sol";
import "../libraries/OracleLibrary.sol";

import "../interfaces/ITerraStakeGovernance.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";
import "../interfaces/IAIEngine.sol";
import "../interfaces/ITerraStakeNeural.sol";
import "../interfaces/ICrossChainHandler.sol";
import "../interfaces/IAntiBot.sol";

/**
 * @title TerraStakeToken
 * @notice Advanced ERC20 token for the TerraStake ecosystem with cross-chain synchronization,
 * neural weight management, and comprehensive economic controls.
 * @dev Integrates with TerraStakeNeuralManager for AI-driven indexing and rebalancing
 */
contract TerraStakeToken is
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    ERC20BurnableUpgradeable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // ============ Constants ============
    uint256 public constant MAX_SUPPLY = 3_000_000_000 * 10**18;
    uint32 public constant MIN_TWAP_PERIOD = 5 minutes;
    uint256 public constant MAX_BATCH_SIZE = 200;
    uint256 public constant PRICE_DECIMALS = 18;
    uint256 public constant LARGE_TRANSFER_THRESHOLD = 1_000_000 * 10**18;
    uint256 public constant MAX_VOLATILITY_THRESHOLD = 5000;
    uint256 public constant TWAP_UPDATE_COOLDOWN = 30 minutes;
    uint256 public constant BUYBACK_TAX_BASIS_POINTS = 100; // 1%
    uint256 public constant MAX_TAX_BASIS_POINTS = 500; // 5%
    uint256 public constant BURN_RATE_BASIS_POINTS = 10; // 0.1%
    uint256 public constant HALVING_RATE = 65; // 65% of previous emission (35% reduction)

    // ============ Structs ============
    struct BuybackStats {
        uint256 totalTokensBought;
        uint256 totalUSDCSpent;
        uint256 lastBuybackTime;
        uint256 buybackCount;
    }

    struct CrossChainHalving {
        uint256 epoch;
        uint256 timestamp;
        uint256 totalSupply;
        uint256 halvingPeriod;
    }

    // ============ State Variables ============
    // Uniswap V4 Integration
    IPoolManager public poolManager;
    PoolKey public poolKey;
    bytes32 public poolId;

    // Ecosystem Contracts
    ITerraStakeGovernance public governanceContract;
    ITerraStakeStaking public stakingContract;
    ITerraStakeLiquidityGuard public liquidityGuard;
    IAIEngine public aiEngine;
    ITerraStakeNeural public neuralManager;
    ICrossChainHandler public crossChainHandler;
    IAntiBot public antiBot;

    // Oracle References
    IProxy public priceFeed;
    IProxy public gasOracle;

    // Token Metrics
    uint256 public lastTWAPPrice;
    uint256 public lastTWAPUpdate;
    uint256 public maxGasPrice;
    uint256 public buybackBudget;
    uint256 public buybackTotalAmount;
    BuybackStats public buybackStatistics;

    // Halving Mechanism
    uint256 public currentHalvingEpoch;
    uint256 public lastHalvingTime;
    bool public applyHalvingToMint;
    uint256 public emissionRate;

    // Security Controls
    mapping(address => bool) public isBlacklisted;
    mapping(address => bool) public taxExempt;
    mapping(uint16 => bool) public supportedChainIds;
    uint16[] public activeChainIds;

    // Transaction Tax
    uint256 public buybackTaxBasisPoints;
    uint256 public burnRateBasisPoints;

    // TWAP Validation
    uint256 public twapDeviationThreshold;
    uint256 public lastConfirmedTWAPPrice;

    // ============ Roles ============
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant LIQUIDITY_MANAGER_ROLE = keccak256("LIQUIDITY_MANAGER_ROLE");
    bytes32 public constant NEURAL_INDEXER_ROLE = keccak256("NEURAL_INDEXER_ROLE");
    bytes32 public constant AI_MANAGER_ROLE = keccak256("AI_MANAGER_ROLE");
    bytes32 public constant PRICE_ORACLE_ROLE = keccak256("PRICE_ORACLE_ROLE");
    bytes32 public constant CROSS_CHAIN_OPERATOR_ROLE = keccak256("CROSS_CHAIN_OPERATOR_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    // ============ Events ============
    event BlacklistUpdated(address indexed account, bool status);
    event AirdropExecuted(address[] recipients, uint256 amount, uint256 totalAmount);
    event TWAPPriceUpdated(uint256 price);
    event TokenBurned(address indexed burner, uint256 amount);
    event GovernanceUpdated(address indexed governanceContract);
    event StakingUpdated(address indexed stakingContract);
    event LiquidityGuardUpdated(address indexed liquidityGuard);
    event BuybackExecuted(uint256 amount, uint256 tokensReceived, uint256 price);
    event LiquidityInjected(uint256 amount, uint256 tokensUsed);
    event HalvingTriggered(uint256 epochNumber, uint256 timestamp);
    event CrossChainSyncSuccessful(uint256 epoch);
    event HalvingSyncFailed();
    event CrossChainHandlerUpdated(address indexed crossChainHandler);
    event CrossChainMessageSent(uint16 indexed destChainId, bytes32 indexed payloadHash, uint256 nonce);
    event CrossChainStateUpdated(uint16 indexed srcChainId, ICrossChainHandler.CrossChainState state);
    event AntiBotUpdated(address indexed newAntiBot);
    event TransactionThrottled(address indexed user, uint256 cooldownEnds);
    event ChainSupportUpdated(uint16 indexed chainId, bool supported);
    event EmissionRateUpdated(uint256 newRate);

    // ============ Errors ============
    error NotAuthorized();
    error ZeroAddress();
    error ZeroAmount();
    error TWAPUpdateCooldown();
    error MaxSupplyExceeded();
    error InvalidPool();
    error PoolNotInitialized();
    error NeuralManagerNotSet();
    error CrossChainHandlerNotSet();
    error CrossChainSyncFailed(bytes reason);
    error InvalidChainId();
    error StaleMessage();
    error TransactionThrottled();

    // ============ Initialization ============
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _poolManager,
        address _governanceContract,
        address _stakingContract,
        address _liquidityGuard,
        address _aiEngine,
        address _priceFeed,
        address _gasOracle,
        address _neuralManager,
        address _crossChainHandler,
        address _antiBot
    ) public initializer {
        __ERC20_init("TerraStake", "TSTAKE");
        __ERC20Permit_init("TerraStake");
        __ERC20Burnable_init();
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        // Validate inputs
        require(_poolManager != address(0), "Invalid pool manager");
        require(_governanceContract != address(0), "Invalid governance");
        require(_stakingContract != address(0), "Invalid staking");
        require(_liquidityGuard != address(0), "Invalid liquidity guard");
        require(_priceFeed != address(0), "Invalid price feed");
        require(_gasOracle != address(0), "Invalid gas oracle");
        require(_neuralManager != address(0), "Invalid neural manager");

        // Set initial roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(LIQUIDITY_MANAGER_ROLE, msg.sender);
        _grantRole(NEURAL_INDEXER_ROLE, msg.sender);
        _grantRole(AI_MANAGER_ROLE, msg.sender);
        _grantRole(PRICE_ORACLE_ROLE, msg.sender);
        _grantRole(CROSS_CHAIN_OPERATOR_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);

        // Initialize contracts
        poolManager = IPoolManager(_poolManager);
        governanceContract = ITerraStakeGovernance(_governanceContract);
        stakingContract = ITerraStakeStaking(_stakingContract);
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);
        priceFeed = IProxy(_priceFeed);
        gasOracle = IProxy(_gasOracle);
        neuralManager = ITerraStakeNeural(_neuralManager);
        if (_aiEngine != address(0)) aiEngine = IAIEngine(_aiEngine);
        if (_crossChainHandler != address(0)) crossChainHandler = ICrossChainHandler(_crossChainHandler);
        if (_antiBot != address(0)) antiBot = IAntiBot(_antiBot);

        // Initialize state
        currentHalvingEpoch = 0;
        lastHalvingTime = block.timestamp;
        maxGasPrice = 100 gwei;
        buybackTaxBasisPoints = BUYBACK_TAX_BASIS_POINTS;
        burnRateBasisPoints = BURN_RATE_BASIS_POINTS;
        twapDeviationThreshold = 500; // 5%
        applyHalvingToMint = true;
        emissionRate = 1_000_000 * 10**18; // Initial emission rate
    }

    // ============ Halving Mechanism ============
    function applyHalving() external onlyRole(GOVERNANCE_ROLE) {
        require(block.timestamp >= lastHalvingTime + stakingContract.getHalvingPeriod(), "Halving not due");

        // Reduce emission rate by 35% (keep 65% of previous rate)
        uint256 newEmissionRate = (emissionRate * HALVING_RATE) / 100;
        emissionRate = newEmissionRate;

        currentHalvingEpoch += 1;
        lastHalvingTime = block.timestamp;

        _syncHalvingAcrossChains();
        emit HalvingTriggered(currentHalvingEpoch, block.timestamp);
        emit EmissionRateUpdated(newEmissionRate);
    }

    function triggerHalving() external onlyRole(ADMIN_ROLE) returns (uint256) {
        if (block.timestamp < lastHalvingTime + stakingContract.getHalvingPeriod()) {
            revert("Halving not yet due");
        }

        uint256 stakingEpoch;
        try stakingContract.applyHalving() returns (uint256 epoch) {
            stakingEpoch = epoch;
        } catch {
            revert("Staking halving failed");
        }

        uint256 governanceEpoch;
        try governanceContract.applyHalving() returns (uint256 epoch) {
            governanceEpoch = epoch;
        } catch {
            revert("Governance halving failed");
        }

        if (stakingEpoch != governanceEpoch) {
            revert("Halving epoch mismatch");
        }

        // Apply token halving with 35% reduction
        uint256 newEmissionRate = (emissionRate * HALVING_RATE) / 100;
        emissionRate = newEmissionRate;

        currentHalvingEpoch = stakingEpoch;
        lastHalvingTime = block.timestamp;

        _syncHalvingAcrossChains();
        emit HalvingTriggered(currentHalvingEpoch, lastHalvingTime);
        emit EmissionRateUpdated(newEmissionRate);
        return currentHalvingEpoch;
    }

    function _syncHalvingAcrossChains() internal {
        if (address(crossChainHandler) == address(0)) {
            emit HalvingSyncFailed();
            return;
        }

        ICrossChainHandler.CrossChainState memory state = ICrossChainHandler.CrossChainState({
            halvingEpoch: currentHalvingEpoch,
            timestamp: lastHalvingTime,
            totalSupply: totalSupply(),
            lastTWAPPrice: lastTWAPPrice,
            emissionRate: emissionRate
        });

        bytes memory payload = abi.encode(state);
        
        for (uint256 i = 0; i < activeChainIds.length; i++) {
            uint16 chainId = activeChainIds[i];
            try crossChainHandler.sendMessage(chainId, payload) {
                emit CrossChainSyncSuccessful(chainId);
            } catch (bytes memory reason) {
                emit HalvingSyncFailed();
                emit CrossChainStateUpdated(chainId, state);
            }
        }
    }

    // ============ Cross-Chain Functions ============
    function setCrossChainHandler(address _crossChainHandler) external onlyRole(ADMIN_ROLE) {
        require(_crossChainHandler != address(0), "Invalid handler");
        crossChainHandler = ICrossChainHandler(_crossChainHandler);
        emit CrossChainHandlerUpdated(_crossChainHandler);
    }

    function setAntiBot(address _antiBot) external onlyRole(ADMIN_ROLE) {
        require(_antiBot != address(0), "Invalid AntiBot");
        antiBot = IAntiBot(_antiBot);
        emit AntiBotUpdated(_antiBot);
    }

    function addSupportedChain(uint16 chainId) external onlyRole(ADMIN_ROLE) {
        require(!supportedChainIds[chainId], "Chain already supported");
        supportedChainIds[chainId] = true;
        activeChainIds.push(chainId);
        emit ChainSupportUpdated(chainId, true);
    }

    function removeSupportedChain(uint16 chainId) external onlyRole(ADMIN_ROLE) {
        require(supportedChainIds[chainId], "Chain not supported");
        supportedChainIds[chainId] = false;
        
        for (uint256 i = 0; i < activeChainIds.length; i++) {
            if (activeChainIds[i] == chainId) {
                activeChainIds[i] = activeChainIds[activeChainIds.length - 1];
                activeChainIds.pop();
                break;
            }
        }
        emit ChainSupportUpdated(chainId, false);
    }

    function syncStateToChains() external onlyRole(CROSS_CHAIN_OPERATOR_ROLE) nonReentrant {
        if (address(crossChainHandler) == address(0)) revert CrossChainHandlerNotSet();
        
        ICrossChainHandler.CrossChainState memory state = ICrossChainHandler.CrossChainState({
            halvingEpoch: currentHalvingEpoch,
            timestamp: block.timestamp,
            totalSupply: totalSupply(),
            lastTWAPPrice: lastTWAPPrice,
            emissionRate: emissionRate
        });

        bytes memory payload = abi.encode(state);
        
        for (uint256 i = 0; i < activeChainIds.length; i++) {
            uint16 chainId = activeChainIds[i];
            try crossChainHandler.sendMessage(chainId, payload) returns (bytes32 payloadHash, uint256 nonce) {
                emit CrossChainMessageSent(chainId, payloadHash, nonce);
            } catch (bytes memory reason) {
                emit CrossChainSyncFailed();
                emit CrossChainStateUpdated(chainId, state);
            }
        }
    }

    function executeRemoteTokenAction(
        uint16 srcChainId,
        address recipient,
        uint256 amount,
        bytes32 reference
    ) external {
        require(msg.sender == address(crossChainHandler), "Unauthorized");
        require(!isBlacklisted[recipient], "Recipient blacklisted");
        require(totalSupply() + amount <= MAX_SUPPLY, "Exceeds max supply");
        
        _mint(recipient, amount);
        
        if (address(neuralManager) != address(0)) {
            neuralManager.recordCrossChainTransfer(srcChainId, recipient, amount, reference);
        }
    }

    function updateFromCrossChain(
        uint16 srcChainId,
        ICrossChainHandler.CrossChainState calldata state
    ) external {
        require(msg.sender == address(crossChainHandler), "Unauthorized");
        require(supportedChainIds[srcChainId], "Unsupported chain");
        
        if (state.timestamp <= lastHalvingTime) revert StaleMessage();
        
        currentHalvingEpoch = state.halvingEpoch;
        lastHalvingTime = state.timestamp;
        emissionRate = state.emissionRate;
        
        if (stakingContract.getHalvingEpoch() < state.halvingEpoch) {
            stakingContract.syncHalvingEpoch(state.halvingEpoch, state.timestamp);
        }
        
        emit CrossChainStateUpdated(srcChainId, state);
        emit EmissionRateUpdated(state.emissionRate);
    }

    // ============ Token Economics ============
    function executeBuyback(uint256 usdcAmount) external onlyRole(LIQUIDITY_MANAGER_ROLE) nonReentrant {
        require(buybackBudget >= usdcAmount, "Insufficient budget");
        require(usdcAmount > 0, "Zero amount");
        
        if (block.timestamp > lastTWAPUpdate + TWAP_UPDATE_COOLDOWN) {
            updateTWAPPrice();
        }
        
        uint256 minTokens = (usdcAmount * 10**18 * 95) / (lastTWAPPrice * 100);
        uint256 tokensReceived = _executeSwapForBuyback(usdcAmount);
        require(tokensReceived >= minTokens, "Slippage exceeded");
        
        buybackBudget -= usdcAmount;
        buybackStatistics.totalTokensBought += tokensReceived;
        buybackStatistics.totalUSDCSpent += usdcAmount;
        buybackStatistics.buybackCount++;
        buybackStatistics.lastBuybackTime = block.timestamp;
        
        _burn(address(this), tokensReceived);
        emit BuybackExecuted(usdcAmount, tokensReceived, lastTWAPPrice);
    }

    function _executeSwapForBuyback(uint256 usdcAmount) internal returns (uint256) {
        if (poolId == bytes32(0)) revert PoolNotInitialized();
        
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            tokenIn: address(priceFeed),
            tokenOut: address(this),
            recipient: address(this),
            amountSpecified: int256(usdcAmount),
            sqrtPriceLimitX96: 0
        });

        IERC20Upgradeable(params.tokenIn).safeApprove(address(poolManager), usdcAmount);
        (int256 amount0, int256 amount1) = poolManager.swap(poolKey, params, abi.encode());
        uint256 tokensReceived = uint256(amount1 > 0 ? amount1 : -amount1);
        
        IERC20Upgradeable(params.tokenIn).safeApprove(address(poolManager), 0);
        return tokensReceived;
    }

    // ============ Token Transfers ============
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override whenNotPaused {
        // Anti-bot check
        if (address(antiBot) != address(0)) {
            (bool isThrottled, ) = antiBot.checkThrottle(from);
            if (isThrottled) revert TransactionThrottled();
        }

        // Security checks
        if (from != address(0)) require(!isBlacklisted[from], "Sender blacklisted");
        if (to != address(0)) require(!isBlacklisted[to], "Recipient blacklisted");
        
        // Large transfer verification
        if (amount >= LARGE_TRANSFER_THRESHOLD) {
            require(liquidityGuard.verifyTWAPForWithdrawal(), "Liquidity check failed");
        }

        // Apply taxes if neither party is exempt
        if (!taxExempt[from] && !taxExempt[to]) {
            uint256 burnAmount = (amount * burnRateBasisPoints) / 10000;
            uint256 taxAmount = (amount * buybackTaxBasisPoints) / 10000;
            uint256 totalDeduction = burnAmount + taxAmount;
            
            if (totalDeduction > 0) {
                if (burnAmount > 0) {
                    super._update(from, address(0), burnAmount);
                    emit TokenBurned(from, burnAmount);
                }
                
                if (taxAmount > 0) {
                    buybackBudget += taxAmount;
                    super._update(from, address(this), taxAmount);
                }
                
                super._update(from, to, amount - totalDeduction);
                return;
            }
        }
        
        super._update(from, to, amount);
    }

    // ============ UUPS Upgradeability ============
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}