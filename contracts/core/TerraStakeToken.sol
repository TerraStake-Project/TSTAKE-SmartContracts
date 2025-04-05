// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/src/interfaces/IHooks.sol";
import "@uniswap/v4-core/src/types/PoolKey.sol";
import "@uniswap/v4-core/src/types/PoolId.sol";
import "@uniswap/v4-core/src/libraries/TickMath.sol";
import "@uniswap/v4-core/src/libraries/FullMath.sol";
import "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import "@api3/contracts/vendor/@chainlink/contracts@1.2.0/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "../interfaces/ITerraStakeGovernance.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";
import "../interfaces/IAIEngine.sol";
import "../interfaces/ITerraStakeNeural.sol";
import "../interfaces/ICrossChainHandler.sol";
import "../interfaces/IAntiBot.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title TerraStakeToken 
 * @notice Advanced ERC20 token with Uniswap V4 integration, cross-chain sync,
 * AI-driven economics, and comprehensive security controls
 * @dev Combines best features from both implementations with full functionality
 */
contract TerraStakeToken is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    ERC20BurnableUpgradeable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ============ Constants ============
    uint256 public constant MAX_SUPPLY = 3_000_000_000 * 10**18;
    uint32 public constant MIN_TWAP_PERIOD = 5 minutes;
    uint256 public constant MAX_BATCH_SIZE = 200;
    uint256 public constant PRICE_DECIMALS = 18;
    uint256 public constant MIN_TRANSFER_AMOUNT = 1 * 10**18; // 1.0 TSTAKE
    uint256 public constant LARGE_TRANSFER_THRESHOLD = 1_000_000 * 10**18;
    uint256 public constant MAX_VOLATILITY_THRESHOLD = 5000;
    uint256 public constant TWAP_UPDATE_COOLDOWN = 30 minutes;
    uint256 public constant BUYBACK_TAX_BASIS_POINTS = 100; // 1%
    uint256 public constant MAX_TAX_BASIS_POINTS = 500; // 5%
    uint256 public constant BURN_RATE_BASIS_POINTS = 10; // 0.1%
    uint256 public constant HALVING_RATE = 65; // 65% of previous emission (35% reduction)
    uint256 public constant EMERGENCY_COOLDOWN = 24 hours;
    uint256 public constant MAX_RATE_LIMIT_WINDOW = 1 hours;
    uint256 public constant CROSS_CHAIN_MESSAGE_EXPIRY = 1 days;
    uint256 public constant MAX_TWAP_OBSERVATIONS = 100;

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

    struct TWAPObservation {
        uint32 blockTimestamp;
        uint160 sqrtPriceX96;
        uint128 liquidity;
    }

    struct PoolPosition {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 tokenId;
        bool isActive;
    }

    struct PoolInfo {
        bytes32 id;
        uint160 sqrtPriceX96;
        int24 tick;
        uint16 observationIndex;
        uint16 observationCardinality;
        uint24 fee;
    }

    struct TaxInfo {
        uint256 total;
        uint256 liquidity;
        uint256 treasury;
        uint256 staking;
        uint256 buyback;
    }

    struct TaxAllocation {
        uint256 liquidity;
        uint256 treasury;
        uint256 staking;
        uint256 buyback;
    }

    struct TokenMetrics {
        uint256 totalSupply;
        uint256 circulatingSupply;
        uint256 burnedTokens;
        uint256 stakingBalance;
        uint256 treasuryBalance;
        uint256 liquidityBalance;
        uint256 lastTWAPPrice;
        uint256 emissionRate;
        uint256 currentHalvingEpoch;
    }

    struct NeuralWeights {
        uint256 timestamp;
        uint256 buyWeight;
        uint256 sellWeight;
        uint256 holdWeight;
        uint256 confidenceScore;
        string modelVersion;
    }

    struct RateLimitConfig {
        bool enabled;
        uint256 maxAmount;
        uint256 windowSize;
    }

    struct CrossChainConfig {
        uint256 messageFee;
        uint256 messageExpiry;
        uint256 minConfirmations;
        bool paused;
    }

    struct ContractInfo {
        string name;
        string version;
        address implementation;
        uint256 deploymentTime;
        uint256 lastUpgradeTime;
        string[] features;
    }

    struct TransactionRecord {
        bytes32 txHash;
        uint256 amount;
        uint256 timestamp;
        string txType;
    }

    struct CrossChainLiquidityData {
        uint256 amount;
        uint256 timestamp;
        uint256 lastUpdated;
    }

    struct Grant {
        address beneficiary;
        uint256 amount;
        uint256 startTime;
        uint256 cliffDuration;
        uint256 vestingDuration;
        uint256 claimed;
        bool revoked;
        bool revocable;
        uint256 created;
    }

    // ============ State Variables ============
    // Uniswap V4 Integration
    IPoolManager public poolManager;
    PoolKey public poolKey;
    bytes32 public poolId;
    bool public poolInitialized;
    
    // V4 Pool Positioning and Hooks
    mapping(bytes32 => IHooks) public poolHooks;
    mapping(bytes32 => address) public hookAddress;
    mapping(uint256 => PoolPosition) public positions;
    uint256 public positionCounter;
    mapping(bytes32 => uint24) public poolFees;
    
    // V4 Oracle Storage
    mapping(bytes32 => TWAPObservation[]) public twapObservations;
    mapping(bytes32 => uint256) public lastTwapObservationIndex;
    uint32 public twapObservationWindow;

    // Ecosystem Contracts
    ITerraStakeGovernance public governanceContract;
    ITerraStakeStaking public stakingContract;
    ITerraStakeLiquidityGuard public liquidityGuard;
    IAIEngine public aiEngine;
    ITerraStakeNeural public neuralManager;
    ICrossChainHandler public crossChainHandler;
    IAntiBot public antiBot;
    address public treasuryAddress;

    // Oracle References
    AggregatorV3Interface public priceFeed;
    AggregatorV3Interface public gasOracle;

    // Governance Address
    address public governanceAddress;

    // Token Metrics
    uint256 public lastTWAPPrice;
    uint256 public lastTWAPUpdate;
    uint256 public maxGasPrice;
    uint256 public buybackBudget;
    uint256 public buybackTotalAmount;
    BuybackStats public buybackStatistics;
    uint256 public totalBurnedTokens;
    uint256 public buyTaxCollected;
    uint256 public sellTaxCollected;
    uint256 public transferTaxCollected;

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
    mapping(address => uint256) public lastTransferTime;
    mapping(address => uint256) public transferVolume;
    RateLimitConfig public rateLimitConfig;
    uint256 public lastEmergencyActionTime;
    bool public emergencyMode;
    // Mapping to check if an address is exempt from rate limits
    mapping(address => bool) public isExemptFromRateLimit;
    // Mapping to store daily transfers per address
    mapping(address => mapping(address => uint256)) public transfersPerDay;

    // Transaction Tax
    uint256 public buybackTaxBasisPoints;
    uint256 public burnRateBasisPoints;
    uint256 public buyTax;
    uint256 public sellTax;
    uint256 public transferTax;
    TaxAllocation public buyTaxAllocation;
    TaxAllocation public sellTaxAllocation;
    TaxAllocation public transferTaxAllocation;
    mapping(address => bool) public isExemptFromTax;
    bool public taxesEnabled;

    // TWAP Validation
    uint256 public twapDeviationThreshold;
    uint256 public lastConfirmedTWAPPrice;

    // Cross-Chain Configuration
    CrossChainConfig public crossChainConfig;
    mapping(bytes32 => bool) public processedMessages;
    mapping(uint16 => uint256) public chainNonces;
    mapping(uint16 => address[]) public crossChainSenders;
    mapping(bytes32 => bool) public trustedCrossChainSenders;
    mapping(uint16 => ICrossChainHandler.CrossChainState) public crossChainStates;
    mapping(uint16 => CrossChainLiquidityData) public crossChainLiquidity;
    bool public crossChainEnabled;

    // Neural Network Configuration
    NeuralWeights public currentNeuralWeights;
    bool public neuralRecommendationsEnabled;
    uint256 public lastNeuralUpdate;
    uint256 public neuralConfidenceThreshold;

    // Contract Information
    ContractInfo private contractInfo;
    mapping(string => string) public parameterDescriptions;
    mapping(address => TransactionRecord[]) private transactionLogs;
    uint256 public maxTrackedTransactions;

    // Grants and Vesting
    Grant[] public grants;

    // ============ Roles ============
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant LIQUIDITY_MANAGER_ROLE = keccak256("LIQUIDITY_MANAGER_ROLE");
    bytes32 public constant NEURAL_INDEXER_ROLE = keccak256("NEURAL_INDEXER_ROLE");
    bytes32 public constant AI_MANAGER_ROLE = keccak256("AI_MANAGER_ROLE");
    bytes32 public constant PRICE_ORACLE_ROLE = keccak256("PRICE_ORACLE_ROLE");
    bytes32 public constant CROSS_CHAIN_OPERATOR_ROLE = keccak256("CROSS_CHAIN_OPERATOR_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant STAKING_MANAGER_ROLE = keccak256("STAKING_MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant RECOVERY_ROLE = keccak256("RECOVERY_ROLE");

    // ============ Events ============
    event BlacklistUpdated(address indexed account, bool status);
    event AirdropExecuted(address[] recipients, uint256 amount, uint256 totalAmount);
    event TWAPPriceUpdated(uint256 price);
    event TokenBurned(address indexed burner, uint256 amount);
    event GovernanceUpdated(address indexed governanceContract);
    event StakingUpdated(address indexed stakingContract);
    event LiquidityGuardUpdated(address indexed liquidityGuard);
    event TreasuryUpdated(address indexed treasuryAddress);
    event BuybackExecuted(uint256 amount, uint256 tokensReceived, uint256 price);
    event LiquidityInjected(uint256 amount, uint256 tokensUsed);
    event HalvingTriggered(uint256 epochNumber, uint256 timestamp);
    event CrossChainSyncSuccessful(uint256 epoch);
    event HalvingSyncFailed();
    event CrossChainHandlerUpdated(address indexed crossChainHandler);
    event CrossChainMessageSent(uint16 indexed destChainId, bytes32 indexed payloadHash, uint256 nonce);
    event CrossChainStateUpdated(uint16 indexed srcChainId, ICrossChainHandler.CrossChainState state);
    event CrossChainSyncFailed(bytes reason);
    event AntiBotUpdated(address indexed newAntiBot);
    event ChainSupportUpdated(uint16 indexed chainId, bool supported);
    event EmissionRateUpdated(uint256 newRate);
    event NeuralManagerUpdated(address indexed neuralManager);
    event MaxGasPriceUpdated(uint256 newMaxGasPrice);
    event TwapDeviationThresholdUpdated(uint256 newThreshold);
    event HalvingToMintUpdated(bool isApplied);
    event BuybackBudgetTransferred(uint256 amount, address indexed recipient);
    event TokensMinted(address indexed recipient, uint256 amount);
    event StakingMint(uint256 amount);
    event GovernanceMint(uint256 amount);
    event AIEngineUpdated(address indexed newAIEngine);
    event NeuralTrainingTriggered(uint256 timestamp, string modelVersion);
    event NeuralWeightsUpdated(uint256 buyWeight, uint256 sellWeight, uint256 holdWeight, uint256 confidenceScore);
    event NeuralRecommendationApplied(string actionType, uint256 timestamp);
    event EmergencyAction(string indexed actionType, bool status);
    event EmergencyActionTriggered(address indexed by, string action);
    event RateLimitConfigUpdated(bool enabled, uint256 maxAmount, uint256 windowSize);
    event FeatureStatusChanged(uint256 indexed featureId, bool enabled);
    event TaxExemptStatusUpdated(address indexed account, bool status);
    event TaxUpdated(string taxType, uint256 newRate);
    event TokenRecovered(address indexed tokenAddress, uint256 amount);
    event ETHRecovered(uint256 amount);
    event ParameterDescriptionUpdated(string parameterName, string description);
    event CrossChainConfigUpdated(uint256 messageFee, uint256 messageExpiry, uint256 minConfirmations, bool paused);
    event NeuralConfidenceThresholdUpdated(uint256 newThreshold);
    event EmergencyModeChanged(bool enabled);
    event ContractUpgraded(address indexed newImplementation, uint256 timestamp);
    event FeesDistributed(uint256 liquidityAmount, uint256 treasuryAmount, uint256 stakingAmount, uint256 buybackAmount);

    // Grant specific events
    event GrantCreated(uint256 indexed grantId, address indexed beneficiary, uint256 amount);
    event TokensClaimed(uint256 indexed grantId, address indexed beneficiary, uint256 amountClaimed);
    event GrantRevoked(uint256 indexed grantId, uint256 amountRevoked);
    
    // Uniswap V4 specific events
    event PoolInitialized(bytes32 indexed poolId, PoolKey poolKey, uint160 sqrtPriceX96);
    event PositionCreated(uint256 positionId, int24 tickLower, int24 tickUpper, uint128 liquidity);
    event PositionModified(uint256 positionId, int128 liquidityDelta);
    event PositionBurned(uint256 positionId);
    event TWAPObservationRecorded(bytes32 indexed poolId, uint32 timestamp, uint160 sqrtPriceX96, uint128 liquidity);
    event SwapExecuted(bytes32 indexed poolId, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);
    event HookRegistered(bytes32 indexed poolId, address hookAddress);

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
    error InvalidChainId();
    error StaleMessage();
    error TransactionThrottled();
    error MaxGasPriceExceeded();
    error TransferAmountTooSmall();
    error SenderIsBot();
    error ReceiverIsBot();
    error PoolAlreadyInitialized();
    error InvalidTickRange();
    error SwapSlippageExceeded();
    error PositionNotFound();
    error InsufficientLiquidity();
    error InvalidHookConfiguration();
    error CallbackNotAuthorized();
    error InvalidSqrtPriceLimit();
    error EmergencyCooldownActive();
    error InvalidFeatureId();
    error InsufficientBalance();
    error TransferLimitExceeded();

    // ============ Initialization ============
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the TerraStake token with all dependencies
     * @param _poolManager Uniswap V4 pool manager address
     * @param _governanceContract Governance contract address
     * @param _stakingContract Staking contract address
     * @param _liquidityGuard Liquidity guard contract address
     * @param _aiEngine AI engine contract address
     * @param _priceFeed Price feed oracle address
     * @param _gasOracle Gas price oracle address
     * @param _neuralManager Neural manager contract address
     * @param _crossChainHandler Cross-chain handler address
     * @param _antiBot Anti-bot contract address
     * @param admin Admin address for initial roles
     */
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
        address _antiBot,
        address _treasuryAddress,
        address admin
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
        require(_treasuryAddress != address(0), "Invalid treasury address");
        require(admin != address(0), "Invalid admin");

        // Set initial roles
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(BURNER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(LIQUIDITY_MANAGER_ROLE, admin);
        _grantRole(NEURAL_INDEXER_ROLE, admin);
        _grantRole(AI_MANAGER_ROLE, admin);
        _grantRole(PRICE_ORACLE_ROLE, admin);
        _grantRole(CROSS_CHAIN_OPERATOR_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(TREASURY_ROLE, admin);
        _grantRole(STAKING_MANAGER_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, admin);
        _grantRole(RECOVERY_ROLE, admin);

        // Initialize contracts
        poolManager = IPoolManager(_poolManager);
        governanceContract = ITerraStakeGovernance(_governanceContract);
        stakingContract = ITerraStakeStaking(_stakingContract);
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);
        priceFeed = AggregatorV3Interface(_priceFeed);
        gasOracle = AggregatorV3Interface(_gasOracle);
        neuralManager = ITerraStakeNeural(_neuralManager);
        if (_aiEngine != address(0)) aiEngine = IAIEngine(_aiEngine);
        if (_crossChainHandler != address(0)) crossChainHandler = ICrossChainHandler(_crossChainHandler);
        if (_antiBot != address(0)) antiBot = IAntiBot(_antiBot);

        treasuryAddress = _treasuryAddress;

        // Initialize state
        currentHalvingEpoch = 0;
        lastHalvingTime = block.timestamp;
        maxGasPrice = 100 gwei;
        buybackTaxBasisPoints = BUYBACK_TAX_BASIS_POINTS;
        burnRateBasisPoints = BURN_RATE_BASIS_POINTS;
        twapDeviationThreshold = 500; // 5%
        applyHalvingToMint = true;
        emissionRate = 1_000_000 * 10**18; // Initial emission rate
        twapObservationWindow = 1 days;
        poolInitialized = false;
        maxTrackedTransactions = 5000;
        neuralConfidenceThreshold = 70;
        emergencyMode = false;

        // Initialize tax rates
        buyTax = 1; // 1%
        sellTax = 2; // 2%
        transferTax = 0; // 0%

        // Initialize tax allocations
        buyTaxAllocation = TaxAllocation({
            liquidity: 40,
            treasury: 30,
            staking: 20,
            buyback: 10
        });

        sellTaxAllocation = TaxAllocation({
            liquidity: 50,
            treasury: 30,
            staking: 10,
            buyback: 10
        });

        transferTaxAllocation = TaxAllocation({
            liquidity: 0,
            treasury: 0,
            staking: 0,
            buyback: 0
        });

        // Initialize contract info
        contractInfo = ContractInfo({
            name: "TerraStakeToken",
            version: "1.0.0",
            implementation: address(this),
            deploymentTime: block.timestamp,
            lastUpgradeTime: block.timestamp,
            features: new string[](5)
        });
        contractInfo.features = ["uniswap_v4", "cross_chain", "neural_network", "staking", "governance"];

        // Initialize cross-chain config
        crossChainConfig = CrossChainConfig({
            messageFee: 0.01 ether,
            messageExpiry: CROSS_CHAIN_MESSAGE_EXPIRY,
            minConfirmations: 3,
            paused: false
        });

        // Initialize rate limiting
        rateLimitConfig = RateLimitConfig({
            enabled: true,
            maxAmount: LARGE_TRANSFER_THRESHOLD,
            windowSize: MAX_RATE_LIMIT_WINDOW
        });

        // Set tax exemption for admin
        taxExempt[admin] = true;
        isExemptFromTax[admin] = true;
    }

    // ============ Upgradeability ============
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        contractInfo.implementation = newImplementation;
        contractInfo.lastUpgradeTime = block.timestamp;
        contractInfo.version = string(abi.encodePacked(contractInfo.version, "+1"));
        emit ContractUpgraded(newImplementation, block.timestamp);
    }
    // ============ Uniswap V4 Functions ============

    /**
     * @notice Initialize a Uniswap V4 pool for the token
     * @param _currency0 The first token in the pool (typically stablecoin)
     * @param _currency1 The second token in the pool (typically this token)
     * @param _fee The pool fee in basis points
     * @param _hook The hook contract to use for this pool
     * @param _hookData Additional data for the hook initialization
     * @param _sqrtPriceX96 The initial sqrt price (X96) for the pool
     */
    function initializePool(
        Currency _currency0,
        Currency _currency1,
        uint24 _fee,
        IHooks _hook,
        bytes calldata _hookData,
        uint160 _sqrtPriceX96
    ) external onlyRole(LIQUIDITY_MANAGER_ROLE) nonReentrant {
        if (poolInitialized) revert PoolAlreadyInitialized();
        
        // Create pool key
        PoolKey memory key = PoolKey({
            currency0: _currency0,
            currency1: _currency1,
            fee: _fee,
            tickSpacing: 60, // Standard tick spacing
            hooks: _hook
        });
        
        // Initialize the pool
        bytes32 _poolId = PoolId.unwrap(key.toId());
        poolManager.initialize(key, _sqrtPriceX96);
        
        // Store pool information
        poolKey = key;
        poolId = _poolId;
        poolHooks[_poolId] = _hook;
        poolFees[_poolId] = _fee;
        hookAddress[_poolId] = address(_hook);
        
        // Create initial TWAP observation
        twapObservations[_poolId].push(TWAPObservation({
            blockTimestamp: uint32(block.timestamp),
            sqrtPriceX96: _sqrtPriceX96,
            liquidity: 0
        }));
        lastTwapObservationIndex[_poolId] = 0;
        
        poolInitialized = true;
        
        emit PoolInitialized(_poolId, key, _sqrtPriceX96);
        emit TWAPObservationRecorded(_poolId, uint32(block.timestamp), _sqrtPriceX96, 0);
        emit HookRegistered(_poolId, address(_hook));
    }

    /**
     * @notice Add liquidity to the Uniswap V4 pool
     * @param tickLower The lower tick boundary
     * @param tickUpper The upper tick boundary
     * @param liquidityDesired The amount of liquidity to add
     * @param recipient The recipient of the position
     */
    function addLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityDesired,
        address recipient
    ) external onlyRole(LIQUIDITY_MANAGER_ROLE) nonReentrant returns (uint256 positionId, uint128 liquidityActual) {
        if (!poolInitialized) revert PoolNotInitialized();
        if (tickLower >= tickUpper) revert InvalidTickRange();
        
        // Validate ticks are properly aligned
        require(tickLower % poolKey.tickSpacing == 0, "Invalid lower tick");
        require(tickUpper % poolKey.tickSpacing == 0, "Invalid upper tick");
        
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidityDesired)),
            salt: keccak256(abi.encode(block.timestamp, tickLower, tickUpper, liquidityDesired))
        });
        
        (BalanceDelta delta0, BalanceDelta delta1) = poolManager.modifyLiquidity(
            poolKey,
            params,
            abi.encode(this, recipient)
        );

        // Handle token transfers
        int256 amount0 = BalanceDelta.unwrap(delta0);
        int256 amount1 = BalanceDelta.unwrap(delta1);
        uint256 amount0Uint = amount0 >= 0 ? 0 : uint256(-amount0);
        uint256 amount1Uint = amount1 >= 0 ? 0 : uint256(-amount1);
        
        if (amount0Uint > 0) {
            IERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(
                msg.sender,
                address(this),
                amount0Uint
            );
            IERC20(Currency.unwrap(poolKey.currency0)).approve(address(poolManager), amount0Uint);
        }
        
        if (amount1Uint > 0) {
            IERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(
                msg.sender,
                address(this),
                amount1Uint
            );
            IERC20(Currency.unwrap(poolKey.currency1)).approve(address(poolManager), amount1Uint);
        }
        
        // Create position
        positionId = ++positionCounter;
        positions[positionId] = PoolPosition({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidityDesired,
            tokenId: positionId,
            isActive: true
        });
        
        emit PositionCreated(positionId, tickLower, tickUpper, liquidityDesired);
        _recordTWAPObservation();
        
        return (positionId, liquidityDesired);
    }

    function removeLiquidity(
        uint256 positionId,
        uint128 liquidityToRemove,
        address recipient
    ) external onlyRole(LIQUIDITY_MANAGER_ROLE) nonReentrant returns (uint256 amount0, uint256 amount1) {
        return _removeLiquidity(positionId, liquidityToRemove, recipient);
    }

    /**
     * @notice Remove liquidity from a position
     * @param positionId The position ID to remove liquidity from
     * @param liquidityToRemove Amount of liquidity to remove (0 = all)
     * @param recipient Address to receive withdrawn tokens
     */
    function _removeLiquidity(
        uint256 positionId,
        uint128 liquidityToRemove,
        address recipient
    ) internal returns (uint256 amount0, uint256 amount1) {
        if (!poolInitialized) revert PoolNotInitialized();
        
        PoolPosition storage position = positions[positionId];
        if (!position.isActive) revert PositionNotFound();
        
        if (liquidityToRemove == 0) {
            liquidityToRemove = position.liquidity;
        } else if (liquidityToRemove > position.liquidity) {
            liquidityToRemove = position.liquidity;
        }
        
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: position.tickLower,
            tickUpper: position.tickUpper,
            liquidityDelta: -int256(uint256(liquidityToRemove)),
            salt: keccak256(abi.encode(block.timestamp, position.tickLower, position.tickUpper, liquidityToRemove))
        });
        
        (BalanceDelta delta0, BalanceDelta delta1) = poolManager.modifyLiquidity(
            poolKey,
            params,
            abi.encode(this, recipient)
        );
        
        // Update position
        position.liquidity -= liquidityToRemove;
        if (position.liquidity == 0) {
            position.isActive = false;
            emit PositionBurned(positionId);
        } else {
            emit PositionModified(positionId, -int128(liquidityToRemove));
        }
        
        // Calculate withdrawn amounts
        int256 amount0Delta = BalanceDelta.unwrap(delta0);
        int256 amount1Delta = BalanceDelta.unwrap(delta1);
        amount0 = amount0Delta > 0 ? uint256(amount0Delta) : 0;
        amount1 = amount1Delta > 0 ? uint256(amount1Delta) : 0;
        
        _recordTWAPObservation();
    }

    /**
     * @notice Execute a swap through the pool
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount to swap
     * @param amountOutMinimum Minimum output amount (slippage protection)
     * @param sqrtPriceLimitX96 Price limit for the swap
     * @param recipient Recipient address
     */
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint160 sqrtPriceLimitX96,
        address recipient
    ) external nonReentrant returns (uint256 amountOut) {
        if (!poolInitialized) revert PoolNotInitialized();
        
        bool zeroForOne = tokenIn == Currency.unwrap(poolKey.currency0);
        
        // Transfer and approve tokens
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).approve(address(poolManager), amountIn);
        
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(amountIn),
            sqrtPriceLimitX96: sqrtPriceLimitX96 == 0 ? 
                (zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1) : 
                sqrtPriceLimitX96
        });
        
        int256 swapDelta = BalanceDelta.unwrap(poolManager.swap(
            poolKey,
            params,
            abi.encode(this, recipient)
        ));
        
        amountOut = uint256(-(swapDelta));
        if (amountOut < amountOutMinimum) revert SwapSlippageExceeded();
        
        emit SwapExecuted(poolId, tokenIn, tokenOut, amountIn, amountOut);
        _recordTWAPObservation();
    }

    /**
     * @notice Uniswap V4 hook callback
     */
    function v4HookCallback(
        address sender,
        PoolKey calldata key,
        bytes calldata data
    ) external {
        if (msg.sender != address(poolManager)) revert CallbackNotAuthorized();
        if (PoolId.unwrap(key.toId()) != poolId) revert InvalidPool();
        
        // Handle callback data
        (address callbackContract, address recipient) = abi.decode(data, (address, address));
        // Additional callback logic would go here
    }

    /**
     * @notice Record a new TWAP observation
     */
    function _recordTWAPObservation() internal {
        if (!poolInitialized) return;
        
        if (twapObservations[poolId].length >= MAX_TWAP_OBSERVATIONS) {
            delete twapObservations[poolId][0];
            for (uint256 i = 1; i < twapObservations[poolId].length; i++) {
                twapObservations[poolId][i - 1] = twapObservations[poolId][i];
            }
            twapObservations[poolId].pop();
        }

        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(PoolId.wrap(poolId));
        uint128 liquidity = poolManager.getLiquidity(PoolId.wrap(poolId));
        
        TWAPObservation memory observation = TWAPObservation({
            blockTimestamp: uint32(block.timestamp),
            sqrtPriceX96: sqrtPriceX96,
            liquidity: liquidity
        });
        
        twapObservations[poolId].push(observation);
        lastTwapObservationIndex[poolId] = twapObservations[poolId].length - 1;
        
        // Update TWAP price
        uint256 price = _calculatePriceFromSqrtPriceX96(sqrtPriceX96);
        if (lastTWAPPrice == 0 || 
            block.timestamp > lastTWAPUpdate + TWAP_UPDATE_COOLDOWN ||
            _isValidPriceChange(lastTWAPPrice, price)) {
            lastTWAPPrice = price;
            lastTWAPUpdate = block.timestamp;
            emit TWAPPriceUpdated(price);
        }
        
        emit TWAPObservationRecorded(poolId, uint32(block.timestamp), sqrtPriceX96, liquidity);
    }

    /**
     * @notice Calculate price from sqrtPriceX96
     */
    function _calculatePriceFromSqrtPriceX96(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        return FullMath.mulDiv(priceX192, 1e12, 1 << 192); // Adjust for USDC decimals
    }

    /**
     * @notice Check if price change is within threshold
     */
    function _isValidPriceChange(uint256 oldPrice, uint256 newPrice) internal view returns (bool) {
        if (oldPrice == 0) return true;
        
        uint256 percentChange;
        if (newPrice > oldPrice) {
            percentChange = ((newPrice - oldPrice) * 10000) / oldPrice;
        } else {
            percentChange = ((oldPrice - newPrice) * 10000) / oldPrice;
        }
        
        return percentChange <= twapDeviationThreshold;
    }

    /**
     * @notice Get TWAP price for a period
     */
    function getTWAPPrice(uint32 period) public view returns (uint256 twapPrice) {
        if (!poolInitialized) return lastTWAPPrice;
        
        uint32 minPeriod = MIN_TWAP_PERIOD;
        if (period < minPeriod) period = minPeriod;
        if (period > twapObservationWindow) period = uint32(twapObservationWindow);
        
        uint32 currentTime = uint32(block.timestamp);
        uint32 targetTime = currentTime - period;
        
        uint256 observationCount = twapObservations[poolId].length;
        if (observationCount < 2) return lastTWAPPrice;
        
        uint256 latestIndex = lastTwapObservationIndex[poolId];
        uint256 earliestIndex = 0;
        
        // Binary search for observations
        uint256 beforeIndex = 0;
        uint256 afterIndex = 0;
        
        if (twapObservations[poolId][earliestIndex].blockTimestamp >= targetTime) {
            beforeIndex = earliestIndex;
            afterIndex = earliestIndex;
        } else if (twapObservations[poolId][latestIndex].blockTimestamp <= targetTime) {
            beforeIndex = latestIndex;
            afterIndex = latestIndex;
        } else {
            uint256 lower = earliestIndex;
            uint256 upper = latestIndex;
            
            while (lower < upper) {
                uint256 mid = (lower + upper) / 2;
                if (twapObservations[poolId][mid].blockTimestamp <= targetTime) {
                    lower = mid + 1;
                } else {
                    upper = mid;
                }
            }
            beforeIndex = lower > 0 ? lower - 1 : 0;
            afterIndex = lower;
        }
        
        TWAPObservation memory beforeObs = twapObservations[poolId][beforeIndex];
        TWAPObservation memory afterObs = twapObservations[poolId][afterIndex];
        
        if (beforeObs.blockTimestamp == afterObs.blockTimestamp) {
            return _calculatePriceFromSqrtPriceX96(afterObs.sqrtPriceX96);
        }
        
        uint32 timeDelta = afterObs.blockTimestamp - beforeObs.blockTimestamp;
        uint32 timeWeight = targetTime - beforeObs.blockTimestamp;
        
        uint160 weightedSqrtPriceX96;
        if (timeWeight == 0) {
            weightedSqrtPriceX96 = beforeObs.sqrtPriceX96;
        } else if (timeWeight >= timeDelta) {
            weightedSqrtPriceX96 = afterObs.sqrtPriceX96;
        } else {
            uint256 afterWeight = (uint256(timeWeight) * 1e18) / timeDelta;
            uint256 beforeWeight = 1e18 - afterWeight;
            weightedSqrtPriceX96 = uint160(
                (uint256(beforeObs.sqrtPriceX96) * beforeWeight + 
                uint256(afterObs.sqrtPriceX96) * afterWeight
            ) / 1e18);
        }
        
        return _calculatePriceFromSqrtPriceX96(weightedSqrtPriceX96);
    }

    /**
     * @notice Update the TWAP price from the pool
     */
    function updateTWAPPrice() public onlyRole(GOVERNANCE_ROLE) {
        if (!poolInitialized) revert PoolNotInitialized();
        if (block.timestamp < lastTWAPUpdate + TWAP_UPDATE_COOLDOWN) revert TWAPUpdateCooldown();
        
        // Get current TWAP price over the default observation window
        uint256 twapPrice = getTWAPPrice(uint32(twapObservationWindow));
        
        // Validate the price change
        if (_isValidPriceChange(lastTWAPPrice, twapPrice)) {
            lastTWAPPrice = twapPrice;
            lastConfirmedTWAPPrice = twapPrice; // Store a confirmed valid price
        } else {
            // If price change is too drastic, use the last confirmed price
            lastTWAPPrice = lastConfirmedTWAPPrice;
        }
        
        lastTWAPUpdate = block.timestamp;
        emit TWAPPriceUpdated(lastTWAPPrice);
    }

    /**
     * @notice Force update TWAP records
     */
    function forceUpdateTWAPObservation() external onlyRole(PRICE_ORACLE_ROLE) {
        _recordTWAPObservation();
    }

    /**
     * @notice Set TWAP observation window
     */
    function setTWAPObservationWindow(uint32 newWindow) external onlyRole(GOVERNANCE_ROLE) {
        require(newWindow >= MIN_TWAP_PERIOD, "Window too short");
        require(newWindow <= 7 days, "Window too long");
        twapObservationWindow = newWindow;
    }
    // ============ Cross-Chain Functions ============

    /**
     * @notice Set cross-chain handler contract
     */
    function setCrossChainHandler(address _crossChainHandler) external onlyRole(ADMIN_ROLE) {
        require(_crossChainHandler != address(0), "Invalid handler");
        crossChainHandler = ICrossChainHandler(_crossChainHandler);
        emit CrossChainHandlerUpdated(_crossChainHandler);
    }

    /**
     * @notice Add supported chain ID
     */
    function addSupportedChain(uint16 chainId) external onlyRole(ADMIN_ROLE) {
        require(!supportedChainIds[chainId], "Chain already supported");
        supportedChainIds[chainId] = true;
        activeChainIds.push(chainId);
        emit ChainSupportUpdated(chainId, true);
    }

    /**
     * @notice Remove supported chain ID
     */
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

    /**
     * @notice Synchronize state across all supported chains
     */
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
            try {
                (bytes32 payloadHash, uint256 nonce) = crossChainHandler.sendMessage(chainId, payload);
                emit CrossChainMessageSent(chainId, payloadHash, nonce);
                emit CrossChainStateUpdated(chainId, state);
            } catch (bytes memory reason) {
                emit CrossChainSyncFailed(reason);
            }
        }
    }

    /**
     * @notice Execute remote token action (called by cross-chain handler)
     */
    function executeRemoteTokenAction(
        uint16 srcChainId,
        address recipient,
        uint256 amount,
        bytes32 txreference
    ) external {
        require(msg.sender == address(crossChainHandler), "Unauthorized");
        require(!isBlacklisted[recipient], "Recipient blacklisted");
        require(totalSupply() + amount <= MAX_SUPPLY, "Exceeds max supply");

        _mint(recipient, amount);
        _recordTransaction(recipient, amount, "cross_chain_mint");

        if (address(neuralManager) != address(0)) {
            neuralManager.recordCrossChainTransfer(srcChainId, recipient, amount, txreference);
        }
    }

    /**
     * @notice Update state from cross-chain message
     */
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
            stakingContract.externalHalvingSync(state.halvingEpoch, state.timestamp);
        }
        
        emit CrossChainStateUpdated(srcChainId, state);
        emit EmissionRateUpdated(state.emissionRate);
    }

    /**
     * @notice Verify and process cross-chain message
     */
    function verifyCrossChainMessage(
        uint16 srcChainId,
        bytes memory sender,
        bytes memory payload
    ) external onlyRole(CROSS_CHAIN_OPERATOR_ROLE) returns (bool success) {
        require(supportedChainIds[srcChainId], "Unsupported chain");

        address decodedSender = abi.decode(sender, (address));
        bytes32 senderHash = keccak256(abi.encodePacked(srcChainId, decodedSender));
        require(trustedCrossChainSenders[senderHash], "Sender not trusted");

        (uint256 messageType, bytes memory data) = abi.decode(payload, (uint256, bytes));

        if (messageType == 1) {
            ICrossChainHandler.CrossChainState memory state = abi.decode(data, (ICrossChainHandler.CrossChainState));
            return _processCrossChainState(srcChainId, state);
        } else if (messageType == 2) {
            uint256 halvingEpoch = abi.decode(data, (uint256));
            return _processCrossChainHalving(halvingEpoch);
        } else if (messageType == 3) {
            (uint256 liquidityAmount, uint256 timestamp) = abi.decode(data, (uint256, uint256));
            return _processCrossChainLiquidity(srcChainId, liquidityAmount, timestamp);
        }

        return false;
    }

    /**
     * @notice Process cross-chain state update
     */
    function _processCrossChainState(
        uint16 srcChainId,
        ICrossChainHandler.CrossChainState memory state
    ) internal returns (bool) {
        require(block.timestamp - state.timestamp <= 1 hours, "Stale cross-chain state");
        crossChainStates[srcChainId] = state;
        emit CrossChainStateUpdated(srcChainId, state);
        return true;
    }

    /**
     * @notice Process cross-chain halving update
     */
    function _processCrossChainHalving(uint256 epoch) internal returns (bool) {
        if (epoch > currentHalvingEpoch) {
            currentHalvingEpoch = epoch;
            lastHalvingTime = block.timestamp;

            if (applyHalvingToMint) {
                emissionRate = (emissionRate * HALVING_RATE) / 100;
                emit EmissionRateUpdated(emissionRate);
            }

            emit CrossChainSyncSuccessful(epoch);
            return true;
        }

        emit HalvingSyncFailed();
        return false;
    }

    /**
     * @notice Process cross-chain liquidity update
     */
    function _processCrossChainLiquidity(
        uint16 srcChainId,
        uint256 totalLiquidity,
        uint256 timestamp
    ) internal returns (bool) {
        require(block.timestamp - timestamp <= 1 hours, "Stale liquidity data");
        crossChainLiquidity[srcChainId] = CrossChainLiquidityData({
            amount: totalLiquidity,
            timestamp: timestamp,
            lastUpdated: block.timestamp
        });
        return true;
    }

    /**
     * @notice Update cross-chain configuration
     */
    function updateCrossChainConfig(
        uint16 chainId,
        bool supported,
        address[] calldata trustedSenders
    ) external onlyRole(ADMIN_ROLE) {
        bool previousState = supportedChainIds[chainId];
        supportedChainIds[chainId] = supported;

        // Revoke previous trusted senders
        address[] storage oldSenders = crossChainSenders[chainId];
        for (uint256 i = 0; i < oldSenders.length; i++) {
            bytes32 oldHash = keccak256(abi.encodePacked(chainId, oldSenders[i]));
            trustedCrossChainSenders[oldHash] = false;
        }

        delete crossChainSenders[chainId];

        // Register new trusted senders
        for (uint256 i = 0; i < trustedSenders.length; i++) {
            require(trustedSenders[i] != address(0), "Zero sender address");
            crossChainSenders[chainId].push(trustedSenders[i]);
            bytes32 senderHash = keccak256(abi.encodePacked(chainId, trustedSenders[i]));
            trustedCrossChainSenders[senderHash] = true;
        }

        if (previousState != supported) {
            emit ChainSupportUpdated(chainId, supported);
        }
    }
    // ============ Neural Network & AI Functions ============

    /**
     * @notice Set AI engine contract
     */
    function setAIEngine(address newAIEngine) external onlyRole(AI_MANAGER_ROLE) {
        require(newAIEngine != address(0), "Invalid AI engine address");
        aiEngine = IAIEngine(newAIEngine);
        emit AIEngineUpdated(newAIEngine);
    }

    /**
     * @notice Trigger neural network training
     */
    function triggerNeuralTraining(string calldata modelVersion) external onlyRole(NEURAL_INDEXER_ROLE) {
        require(address(aiEngine) != address(0), "AI engine not set");
        aiEngine.trainModel(modelVersion);
        
        currentNeuralWeights.timestamp = block.timestamp;
        currentNeuralWeights.modelVersion = modelVersion;
        lastNeuralUpdate = block.timestamp;
        
        emit NeuralTrainingTriggered(block.timestamp, modelVersion);
    }

    /**
     * @notice Update neural weights
     */
    function updateNeuralWeights(
        uint256 buyWeight,
        uint256 sellWeight,
        uint256 holdWeight,
        uint256 confidenceScore,
        string calldata modelVersion
    ) external onlyRole(NEURAL_INDEXER_ROLE) {
        require(buyWeight + sellWeight + holdWeight == 100, "Weights must sum to 100");
        require(confidenceScore <= 100, "Confidence > 100");

        currentNeuralWeights = NeuralWeights({
            timestamp: block.timestamp,
            buyWeight: buyWeight,
            sellWeight: sellWeight,
            holdWeight: holdWeight,
            confidenceScore: confidenceScore,
            modelVersion: modelVersion
        });

        lastNeuralUpdate = block.timestamp;
        emit NeuralWeightsUpdated(buyWeight, sellWeight, holdWeight, confidenceScore);
    }

    /**
     * @notice Apply neural recommendations
     */
    function applyNeuralRecommendations(string calldata actionType) external onlyRole(AI_MANAGER_ROLE) returns (bool) {
        require(neuralRecommendationsEnabled, "Neural recommendations disabled");
        require(currentNeuralWeights.confidenceScore >= neuralConfidenceThreshold, "Confidence too low");

        bytes32 actionHash = keccak256(bytes(actionType));

        uint256 adjustmentStep = taxAdjustmentStep; // State variable, default 50 bps, set via governance
        uint256 newTax = buybackTaxBasisPoints;

        if (currentNeuralWeights.sellWeight > sellWeightThreshold) { // Default 50
            newTax = Math.min(newTax + adjustmentStep, MAX_TAX_BASIS_POINTS);
        } else if (currentNeuralWeights.buyWeight > buyWeightThreshold && newTax >= adjustmentStep) { // Default 50
            newTax -= adjustmentStep;
        } else {
            emit NeuralRecommendationSkipped("tax", "weights_below_threshold", block.timestamp);
            return false;
        }

        if (newTax != buybackTaxBasisPoints) {
            buybackTaxBasisPoints = newTax;
            emit NeuralRecommendationApplied("tax", block.timestamp);
            emit TaxUpdated("buyback_basis_points", newTax);
            return true;
        }
        return false;
        } 
        else if (actionHash == keccak256("liquidity")) {
        if (currentNeuralWeights.holdWeight > holdWeightThreshold) { // Default 60
            _optimizeLiquidity();
            emit NeuralRecommendationApplied("liquidity", block.timestamp);
            return true;
        }
        emit NeuralRecommendationSkipped("liquidity", "hold_weight_too_low", block.timestamp);
        return false;
        } 
        else if (actionHash == keccak256("buyback")) {
        if (currentNeuralWeights.buyWeight < buyWeightThresholdLow && buybackBudget > 0) { // Default 30
            uint256 amount = Math.min(buybackBudget * buybackFraction / 100, buybackBudget); // Default 10%
            executeBuyback(amount);
            emit NeuralRecommendationApplied("buyback", block.timestamp);
            return true;
        }
        emit NeuralRecommendationSkipped("buyback", 
            buybackBudget == 0 ? "insufficient_budget" : "buy_weight_too_high", 
            block.timestamp);
        return false;
        } 
        else {
        revert InvalidActionType(actionType);
        }
    }
        return false;
    }

    /**
     * @notice Toggle neural recommendations
     */
    function toggleNeuralRecommendations(bool enabled) external onlyRole(AI_MANAGER_ROLE) {
        neuralRecommendationsEnabled = enabled;
        emit FeatureStatusChanged(1, enabled);
    }

    /**
     * @notice Set neural confidence threshold
     */
    function setNeuralConfidenceThreshold(uint256 threshold) external onlyRole(AI_MANAGER_ROLE) {
        require(threshold <= 100, "Invalid threshold");
        neuralConfidenceThreshold = threshold;
        emit NeuralConfidenceThresholdUpdated(threshold);
    }

    /**
     * @notice Get current neural weights
     */
    function getNeuralWeights() external view returns (
        uint256 buyWeight,
        uint256 sellWeight,
        uint256 holdWeight,
        uint256 confidenceScore,
        string memory modelVersion
    ) {
        NeuralWeights memory w = currentNeuralWeights;
        return (w.buyWeight, w.sellWeight, w.holdWeight, w.confidenceScore, w.modelVersion);
    }

    /**
     * @notice Internal liquidity optimization based on neural recommendations and current TWAP
     */
    function _optimizeLiquidity() internal {
        if (!poolInitialized) revert PoolNotInitialized();
        if (positions[positionCounter].isActive) {
            _removeLiquidity(positionCounter, 0, address(this));
        }

        (uint160 sqrtPriceX96, int24 currentTick, , ) = poolManager.getSlot0(PoolId.wrap(poolId));

        // Determine direction bias from neural weights
        bool biasUp = currentNeuralWeights.buyWeight > currentNeuralWeights.sellWeight;

        int24 tickSpacing = poolKey.tickSpacing;
        int24 centerTick = (currentTick / tickSpacing) * tickSpacing;

        int24 range = tickSpacing * 20; // ±20 ticks from center
        if (currentNeuralWeights.confidenceScore >= 85) {
            range = tickSpacing * 10; // tighter if confident
        } else if (currentNeuralWeights.holdWeight > 50) {
            range = tickSpacing * 30; // wider for passive
        }

        int24 tickLower = centerTick - range;
        int24 tickUpper = centerTick + range;

        if (biasUp) {
            tickLower += tickSpacing;
            tickUpper += tickSpacing;
        } else {
            tickLower -= tickSpacing;
            tickUpper -= tickSpacing;
        }

        uint256 usdcAmount = IERC20(Currency.unwrap(poolKey.currency0)).balanceOf(address(this));
        uint256 tokenAmount = balanceOf(address(this));
        require(usdcAmount > 0 && tokenAmount > 0, "Insufficient balance");

        // Calculate liquidity based on available balances
        uint128 liquidity = _calculateLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            usdcAmount,
            tokenAmount
        );

        IERC20(Currency.unwrap(poolKey.currency0)).approve(address(poolManager), usdcAmount);
        IERC20(Currency.unwrap(poolKey.currency1)).approve(address(poolManager), tokenAmount);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: keccak256(abi.encode(block.timestamp, tickLower, tickUpper, liquidity))
        });

        poolManager.modifyLiquidity(poolKey, params, abi.encode(address(this), address(this)));

        positionCounter++;
        positions[positionCounter] = PoolPosition({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            tokenId: positionCounter,
            isActive: true
        });

        emit PositionCreated(positionCounter, tickLower, tickUpper, liquidity);
        _recordTWAPObservation();
    }
    // ============ Governance Functions ============
    /**
     * @notice Set governance address
     */
    function setGovernance(address _governance) external onlyRole(ADMIN_ROLE) {
        require(_governance != address(0), "Zero address");
        governanceAddress = _governance;
        emit GovernanceUpdated(_governance);
    }

    /**
     * @notice Set liquidity guard
     */
    function setLiquidityGuard(address _liquidityGuard) external onlyRole(ADMIN_ROLE) {
        require(_liquidityGuard != address(0), "Zero address");
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);
        emit LiquidityGuardUpdated(_liquidityGuard);
    }

    /**
     * @notice Set treasury address
     */
    function setTreasury(address _treasuryAddress) external onlyRole(ADMIN_ROLE) {
        require(_treasuryAddress != address(0), "Zero address");
        treasuryAddress = _treasuryAddress;
        emit TreasuryUpdated(_treasuryAddress);
    }


    // ============ Token Economics Functions ============

    /**
     * @notice Execute token buyback
     */
    function executeBuyback(uint256 usdcAmount) public onlyRole(LIQUIDITY_MANAGER_ROLE) nonReentrant {
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


    /**
     * @notice Internal buyback execution
     */
    function _executeSwapForBuyback(uint256 usdcAmount) internal returns (uint256) {
        if (!poolInitialized) revert PoolNotInitialized();
        
        bool zeroForOne = poolKey.currency0 == Currency.wrap(address(priceFeed));
        
        IERC20(Currency.unwrap(zeroForOne ? poolKey.currency0 : poolKey.currency1))
            .approve(address(poolManager), usdcAmount);
        
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(usdcAmount),
            sqrtPriceLimitX96: zeroForOne ? 
                TickMath.MIN_SQRT_PRICE + 1 : 
                TickMath.MAX_SQRT_PRICE - 1
        });
        
        int256 swapDelta = BalanceDelta.unwrap(poolManager.swap(
            poolKey,
            params,
            abi.encode(address(this), address(this))
        ));
        
        uint256 tokensReceived = uint256(-swapDelta);
        _recordTWAPObservation();
        return tokensReceived;
    }

    /**
     * @notice Inject liquidity into the pool
     */
    function injectLiquidity(
        uint256 usdcAmount,
        int24 tickLower,
        int24 tickUpper
    ) external onlyRole(LIQUIDITY_MANAGER_ROLE) nonReentrant returns (uint256 positionId) {
        require(usdcAmount > 0, "Zero amount");
        require(tickLower < tickUpper, "Invalid tick range");
        
        uint256 tokenAmount = _calculateTokensForLiquidity(usdcAmount, tickLower, tickUpper);
        require(tokenAmount > 0, "Zero token amount");
        
        IERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(
            msg.sender,
            address(this),
            usdcAmount
        );
        
        if (balanceOf(address(this)) < tokenAmount) {
            require(totalSupply() + tokenAmount <= MAX_SUPPLY, "Exceeds max supply");
            _mint(address(this), tokenAmount);
        }
        
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(PoolId.wrap(poolId));
        uint128 liquidity = _calculateLiquidityForAmounts(
            sqrtPriceX96, 
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            usdcAmount,
            tokenAmount
        );
        
        IERC20(Currency.unwrap(poolKey.currency0)).approve(address(poolManager), usdcAmount);
        IERC20(Currency.unwrap(poolKey.currency1)).approve(address(poolManager), tokenAmount);
        
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
                salt: keccak256(abi.encode(block.timestamp, tickLower, tickUpper, liquidity))
            });
            
            (BalanceDelta delta0, BalanceDelta delta1) = poolManager.modifyLiquidity(
                poolKey,
                params,
                abi.encode(address(this), address(this))
            );
            
            positionId = ++positionCounter;
            positions[positionId] = PoolPosition({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: liquidity,
                tokenId: positionId,
                isActive: true
            });
            
            emit LiquidityInjected(usdcAmount, tokenAmount);
            emit PositionCreated(positionId, tickLower, tickUpper, liquidity);
            _recordTWAPObservation();
            return positionId;
        }
        
        poolManager.modifyLiquidity(
            poolKey,
            params,
            abi.encode(address(this), address(this))
        );
        
        positionId = ++positionCounter;
        positions[positionId] = PoolPosition({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            tokenId: positionId,
            isActive: true
        });
        
        emit LiquidityInjected(usdcAmount, tokenAmount);
        emit PositionCreated(positionId, tickLower, tickUpper, liquidity);
        _recordTWAPObservation();
        return positionId;
    }

    /**
     * @notice Calculate liquidity for given token amounts and price range
     * @param sqrtPriceX96 Current sqrt price
     * @param sqrtPriceAX96 Lower sqrt price boundary
     * @param sqrtPriceBX96 Upper sqrt price boundary
     * @param amount0 Amount of token0
     * @param amount1 Amount of token1
     * @return The calculated liquidity amount
     */
    function _calculateLiquidityForAmounts(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        
        if (sqrtPriceX96 <= sqrtPriceAX96) {
            return LiquidityAmounts.getLiquidityForAmount0(sqrtPriceAX96, sqrtPriceBX96, amount0);
        } else if (sqrtPriceX96 >= sqrtPriceBX96) {
            return LiquidityAmounts.getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceBX96, amount1);
        } else {
            uint128 liquidity0 = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceX96, sqrtPriceBX96, amount0);
            uint128 liquidity1 = LiquidityAmounts.getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceX96, amount1);
            return liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        }
    }

    /**
     * @notice Calculate token amount needed for a given USDC amount at current price
     * @param usdcAmount Amount of USDC
     * @param tickLower Lower tick boundary
     * @param tickUpper Upper tick boundary
     * @return tokenAmount Token amount needed
     */
    function _calculateTokensForLiquidity(
        uint256 usdcAmount,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (uint256 tokenAmount) {
        if (!poolInitialized) return 0;
        
        (uint160 sqrtPriceX96, int24 currentTick, , ) = poolManager.getSlot0(PoolId.wrap(poolId));
        
        // Calculate token amount based on the price range
        if (currentTick < tickLower) {
            // Current price is below range, only token0 (USDC) is needed
            return 0;
        } else if (currentTick >= tickUpper) {
            // Current price is above range, only token1 (TSTAKE) is needed
            // Calculate based on the upper tick price
            uint160 sqrtRatioAtUpperTick = TickMath.getSqrtPriceAtTick(tickUpper);
            uint256 priceAtUpperTick = FullMath.mulDiv(
                uint256(sqrtRatioAtUpperTick) * uint256(sqrtRatioAtUpperTick),
                1,
                1 << 192
            );
            
            // Adjust for decimal differences (assuming USDC has 6 decimals, TSTAKE has 18)
            priceAtUpperTick = priceAtUpperTick * 1e12;
            
            // Calculate token amount - usdcAmount / priceAtUpperTick
            return FullMath.mulDiv(usdcAmount, 1e18, priceAtUpperTick);
        } else {
            // Current price is within range, need both tokens
            // Calculate amounts for the portion of the range we're in
            uint160 sqrtRatioAtLowerTick = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sqrtRatioAtUpperTick = TickMath.getSqrtPriceAtTick(tickUpper);
            
            // Calculate liquidity amount
            uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(
                sqrtRatioAtLowerTick,
                sqrtRatioAtUpperTick,
                usdcAmount
            );
            
            // Calculate token1 amount based on this liquidity
            uint256 amount1 = LiquidityAmounts.getAmount1ForLiquidity(
                sqrtPriceX96,
                sqrtRatioAtUpperTick,
                liquidity
            );
            
            return amount1;
        }
    }

    /**
     * @notice Set tax rates and allocations
     */
    function setTaxRatesAndAllocations(
        uint256 _buyTax,
        uint256 _sellTax,
        uint256 _transferTax,
        TaxAllocation calldata buyAlloc,
        TaxAllocation calldata sellAlloc,
        TaxAllocation calldata transferAlloc
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(
            buyAlloc.liquidity + buyAlloc.treasury + buyAlloc.staking + buyAlloc.buyback == _buyTax,
            "Buy tax mismatch"
        );
        require(
            sellAlloc.liquidity + sellAlloc.treasury + sellAlloc.staking + sellAlloc.buyback == _sellTax,
            "Sell tax mismatch"
        );
        require(
            transferAlloc.liquidity + transferAlloc.treasury + transferAlloc.staking + transferAlloc.buyback == _transferTax,
            "Transfer tax mismatch"
        );

        buyTax = _buyTax;
        sellTax = _sellTax;
        transferTax = _transferTax;

        buyTaxAllocation = buyAlloc;
        sellTaxAllocation = sellAlloc;
        transferTaxAllocation = transferAlloc;

        emit TaxUpdated("buy", _buyTax);
        emit TaxUpdated("sell", _sellTax);
        emit TaxUpdated("transfer", _transferTax);
    }

    /**
     * @notice Adjust tax based on market conditions
     */
    function adjustTaxBasedOnMarket(uint256 marketVolatility, uint256 marketVolume) external onlyRole(PRICE_ORACLE_ROLE) {
        require(marketVolatility <= 100, "Invalid volatility");

        if (marketVolatility > 80) {
            sellTax = Math.min(sellTax + 1, 20); // Max 20%
        } else if (marketVolatility < 20 && marketVolume > 1_000_000 * 10**decimals()) {
            if (sellTax > 2) sellTax -= 1;
            if (buyTax > 1) buyTax -= 1;
        } else if (marketVolatility < 50 && marketVolume < 100_000 * 10**decimals()) {
            if (buyTax > 1) buyTax -= 1;
        }

        emit TaxUpdated("buy", buyTax);
        emit TaxUpdated("sell", sellTax);
    }

    /**
     * @notice Calculate tax amount for a transaction
     */
    enum TaxType { Buy, Sell, Transfer }

    function _calculateTax(address sender, address recipient, uint256 amount, TaxType taxType) internal view returns (uint256 taxAmount) {
        uint256 taxRate = (taxType == TaxType.Buy) ? buyTax : (taxType == TaxType.Sell) ? sellTax : transferTax;
        return (amount * taxRate) / 100;
    }

    /**
     * @notice Set tax exemption for multiple addresses
     */
    function setTaxExemptBatch(address[] calldata accounts, bool exempt) external onlyRole(ADMIN_ROLE) {
        for (uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];
            require(account != address(0), "Invalid address");
            isExemptFromTax[account] = exempt;
            emit TaxExemptStatusUpdated(account, exempt);
        }
    }

    /**
     * @notice Get detailed tax information
     */
    function getTaxInfo() external view returns (
        TaxInfo memory buyTaxInfo,
        TaxInfo memory sellTaxInfo,
        TaxInfo memory transferTaxInfo
    ) {
        buyTaxInfo = TaxInfo({
            total: buyTax,
            liquidity: buyTaxAllocation.liquidity,
            treasury: buyTaxAllocation.treasury,
            staking: buyTaxAllocation.staking,
            buyback: buyTaxAllocation.buyback
        });

        sellTaxInfo = TaxInfo({
            total: sellTax,
            liquidity: sellTaxAllocation.liquidity,
            treasury: sellTaxAllocation.treasury,
            staking: sellTaxAllocation.staking,
            buyback: sellTaxAllocation.buyback
        });

        transferTaxInfo = TaxInfo({
            total: transferTax,
            liquidity: transferTaxAllocation.liquidity,
            treasury: transferTaxAllocation.treasury,
            staking: transferTaxAllocation.staking,
            buyback: transferTaxAllocation.buyback
        });
    }
    // ============ Security & Protection Functions ============

    /**
     * @notice Batch update blacklist status
     */
    function batchBlacklist(address[] calldata accounts, bool status) external onlyRole(ADMIN_ROLE) {
        for (uint256 i = 0; i < accounts.length; ) {
            address account = accounts[i];
            require(account != address(0), "Invalid address");
            isBlacklisted[account] = status;
            emit BlacklistUpdated(account, status);
            unchecked { ++i; }
        }
    }

    /**
     * @notice Batch update blacklist status with range
     */
    function batchBlacklist(address[] calldata accounts, bool status, uint256 startIndex, uint256 endIndex) external onlyRole(ADMIN_ROLE) {
        require(startIndex < endIndex && endIndex <= accounts.length, "Invalid range");
        for (uint256 i = startIndex; i < endIndex; ) {
            address account = accounts[i];
            require(account != address(0), "Invalid address");
            isBlacklisted[account] = status;
            emit BlacklistUpdated(account, status);
            unchecked { ++i; }
        }
    }

    /**
     * @notice Check rate limit for an address
     */
    function rateLimit(address sender, uint256 amount) public view returns (bool limited) {
        if (isExemptFromRateLimit[sender]) return false;

        uint256 dayStart = block.timestamp - (block.timestamp % 1 days);
        uint256 dayTransferred = transfersPerDay[sender][dayStart] + amount;

        uint256 maxTransfer = (balanceOf(sender) * 5) / 100;
        return maxTransfer > 0 && dayTransferred > maxTransfer;
    }

    /**
     * @notice Set rate limit exemption
     */
    function setRateLimitExemption(address account, bool exempt) external onlyRole(ADMIN_ROLE) {
        require(account != address(0), "Invalid address");
        isExemptFromRateLimit[account] = exempt;
    }

    /**
     * @notice Pause all token transfers
     */
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause token transfers
     */
    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    /**
     * @notice Set maximum gas price
     */
    function setMaxGasPrice(uint256 _maxGasPrice) external onlyRole(ADMIN_ROLE) {
        require(_maxGasPrice > 5 gwei, "Gas price too low");
        maxGasPrice = _maxGasPrice;
        emit MaxGasPriceUpdated(_maxGasPrice);
    }

    /**
     * @notice Set TWAP deviation threshold
     */
    function setTwapDeviationThreshold(uint256 _threshold) external onlyRole(GOVERNANCE_ROLE) {
        require(_threshold >= 100 && _threshold <= 5000, "Invalid threshold");
        twapDeviationThreshold = _threshold;
        emit TwapDeviationThresholdUpdated(_threshold);
    }

    /**
     * @notice Check if address is a contract
     */
    function _isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }
    // ============ Emergency & Recovery Functions ============

    /**
     * @notice Emergency pause all functions
     */
    function emergencyPause(bool paused) external onlyRole(EMERGENCY_ROLE) {
        if (paused) {
            _pause();
        } else {
            _unpause();
        }
        emit EmergencyAction("pause", paused);
    }

    /**
     * @notice Recover ERC20 tokens
     */
    function recoverERC20(address tokenAddress, uint256 amount)
        external
        onlyRole(RECOVERY_ROLE)
        nonReentrant
        returns (uint256 recovered)
    {
        require(tokenAddress != address(this), "Cannot recover native token");
        IERC20 token = IERC20(tokenAddress);

        uint256 balance = token.balanceOf(address(this));
        uint256 amountToRecover = amount == 0 ? balance : Math.min(amount, balance);

        require(amountToRecover > 0, "No tokens to recover");
        token.safeTransfer(treasuryAddress, amountToRecover);

        emit TokenRecovered(tokenAddress, amountToRecover);
        return amountToRecover;
    }

    /**
     * @notice Recover native ETH
     */
    function recoverETH(uint256 amount)
        external
        onlyRole(RECOVERY_ROLE)
        nonReentrant
        returns (uint256 recovered)
    {
        uint256 balance = address(this).balance;
        uint256 amountToRecover = amount == 0 ? balance : Math.min(amount, balance);

        require(amountToRecover > 0, "No ETH to recover");
        (bool success, ) = treasuryAddress.call{value: amountToRecover}("");
        require(success, "ETH recovery failed");

        emit ETHRecovered(amountToRecover);
        return amountToRecover;
    }

    /**
     * @notice Emergency withdraw all liquidity
     */
    function emergencyWithdraw() external onlyRole(EMERGENCY_ROLE) nonReentrant {
        require(poolInitialized, "Pool not initialized");
        
        // Withdraw from all active positions
        for (uint256 i = 1; i <= positionCounter; i++) {
            if (positions[i].isActive) {
                _removeLiquidity(i, 0, treasuryAddress);
            }
        }
        
        emit EmergencyActionTriggered(msg.sender, "liquidity_withdrawal");
    }

    /**
     * @notice Toggle protocol features
     */
    function setFeatureStatus(uint256 feature, bool enabled) external onlyRole(EMERGENCY_ROLE) {
        if (feature == 1) {
            taxesEnabled = enabled;
        } else if (feature == 2) {
            neuralRecommendationsEnabled = enabled;
        } else if (feature == 3) {
            crossChainEnabled = enabled;
        } else {
            revert InvalidFeatureId();
        }
        emit FeatureStatusChanged(feature, enabled);
    }

    /**
     * @notice Validate system status
     */
    function validateSystemStatus() external view returns (uint256 status, string[] memory issues) {
        string[10] memory systemIssues;
        uint256 issueCount = 0;

        if (address(this).balance == 0) {
            systemIssues[issueCount++] = "Zero ETH balance";
        }

        if (address(priceFeed) == address(0)) {
            systemIssues[issueCount++] = "Price feed not set";
        } else {
            try priceFeed.latestRoundData() returns (
                uint80, int256 answer, uint256, uint256 updatedAt, uint80
            ) {
                if (answer <= 0) {
                    systemIssues[issueCount++] = "Invalid price data";
                }
                if (block.timestamp - updatedAt > 24 hours) {
                    systemIssues[issueCount++] = "Stale price data";
                }
            } catch {
                systemIssues[issueCount++] = "Price feed error";
            }
        }

        if (address(stakingContract) == address(0)) {
            systemIssues[issueCount++] = "Staking contract not set";
        }

        if (address(governanceContract) == address(0)) {
            systemIssues[issueCount++] = "Governance contract not set";
        }

        if (address(liquidityGuard) == address(0)) {
            systemIssues[issueCount++] = "Liquidity guard not set";
        }

        if (emissionRate == 0 && applyHalvingToMint) {
            systemIssues[issueCount++] = "Zero emission rate with halving enabled";
        }

        string[] memory finalIssues = new string[](issueCount);
        for (uint256 i = 0; i < issueCount; i++) {
            finalIssues[i] = systemIssues[i];
        }

        return (issueCount, finalIssues);
    }

    /**
     * @notice Simulate halving effects
     */
    function simulateHalving() external view returns (
        uint256 currentRate,
        uint256 newRate,
        uint256 supplyImpact
    ) {
        currentRate = emissionRate;
        newRate = applyHalvingToMint ? emissionRate / 2 : emissionRate;

        uint256 currentSupplyGrowth = currentRate * stakingContract.getHalvingPeriod();
        uint256 newSupplyGrowth = newRate * stakingContract.getHalvingPeriod();
        supplyImpact = currentSupplyGrowth - newSupplyGrowth;

        return (currentRate, newRate, supplyImpact);
    }
    // ============ Token Transfer Functions ============

    /**
     * @notice Hook for token transfers
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override whenNotPaused {
        // Validate gas price
        if (tx.gasprice > maxGasPrice) revert MaxGasPriceExceeded();
        
        // Minimum transfer amount
        if (amount < MIN_TRANSFER_AMOUNT && from != address(0) && to != address(0)) {
            revert TransferAmountTooSmall();
        }
        
        // Anti-bot checks
        if (address(antiBot) != address(0) && from != address(0) && to != address(0)) {
            if (antiBot.isBot(from)) revert SenderIsBot();
            if (antiBot.isBot(to)) revert ReceiverIsBot();
            if (antiBot.checkThrottle(from)) revert TransactionThrottled();
        }
        
        // Blacklist checks
        if (from != address(0)) require(!isBlacklisted[from], "Sender blacklisted");
        if (to != address(0)) require(!isBlacklisted[to], "Recipient blacklisted");
        
        // Large transfer verification
        if (amount >= LARGE_TRANSFER_THRESHOLD) {
            require(address(poolManager) != address(0), "PoolManager not set");
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

        // Ensure sender is rate-limited
        require(!rateLimit(from, amount), "Transfer exceeds daily limit");
        
        super._update(from, to, amount);
        
        // Update transfer amount for the day
        uint256 dayStart = block.timestamp - (block.timestamp % 1 days);
        transfersPerDay[from][dayStart] += amount;

        // Record transfer in neural manager
        if (address(neuralManager) != address(0) && from != address(0) && to != address(0)) {
            neuralManager.recordTransfer(from, to, amount);
        }
    }

    /**
     * @notice Mint new tokens
     */
    function mint(address recipient, uint256 amount) external onlyRole(MINTER_ROLE) nonReentrant returns (uint256) {
        require(recipient != address(0), "Zero address");
        require(!isBlacklisted[recipient], "Recipient blacklisted");
        
        uint256 adjustedAmount = applyHalvingToMint ? _applyHalvingToAmount(amount) : amount;
        uint256 maxMintAmount = emissionRate;
        
        if (adjustedAmount > maxMintAmount) {
            adjustedAmount = maxMintAmount;
        }
        
        require(totalSupply() + adjustedAmount <= MAX_SUPPLY, "Exceeds max supply");
        _mint(recipient, adjustedAmount);
        
        emit TokensMinted(recipient, adjustedAmount);
        
        if (address(neuralManager) != address(0)) {
            neuralManager.recordMint(recipient, adjustedAmount);
        }
        
        return adjustedAmount;
    }

    /**
     * @notice Mint to staking contract
     */
    function mintToStaking(uint256 amount) external onlyRole(STAKING_MANAGER_ROLE) nonReentrant returns (uint256) {
        require(address(stakingContract) != address(0), "Staking not set");
        
        uint256 adjustedAmount = applyHalvingToMint ? _applyHalvingToAmount(amount) : amount;
        uint256 maxMintAmount = emissionRate;
        
        if (adjustedAmount > maxMintAmount) {
            adjustedAmount = maxMintAmount;
        }
        
        require(totalSupply() + adjustedAmount <= MAX_SUPPLY, "Exceeds max supply");
        _mint(address(stakingContract), adjustedAmount);
        
        emit StakingMint(adjustedAmount);
        return adjustedAmount;
    }

    /**
     * @notice Mint for governance rewards
     */
    function mintForGovernance(uint256 amount) external onlyRole(GOVERNANCE_ROLE) nonReentrant returns (uint256) {
        require(address(governanceContract) != address(0), "Governance not set");
        
        uint256 adjustedAmount = applyHalvingToMint ? _applyHalvingToAmount(amount) : amount;
        require(totalSupply() + adjustedAmount <= MAX_SUPPLY, "Exceeds max supply");
        
        _mint(address(governanceContract), adjustedAmount);
        emit GovernanceMint(adjustedAmount);
        return adjustedAmount;
    }

    /**
     * @notice Burn tokens
     */
    function burn(uint256 amount) public override {
        require(amount > 0, "Zero amount");
        super.burn(amount);
        emit TokenBurned(_msgSender(), amount);
    }

    /**
     * @notice Burn tokens from account
     */
    function burnFrom(address account, uint256 amount) public override onlyRole(BURNER_ROLE) {
        require(amount > 0, "Zero amount");
        super.burnFrom(account, amount);
        emit TokenBurned(account, amount);
    }

    /**
     * @notice Apply halving to amount
     */
    function _applyHalvingToAmount(uint256 amount) internal view returns (uint256) {
        if (currentHalvingEpoch == 0) return amount;
        
        uint256 halvingFactor = HALVING_RATE;
        uint256 halvingDivisor = 100;
        
        for (uint256 i = 0; i < currentHalvingEpoch; i++) {
            amount = (amount * halvingFactor) / halvingDivisor;
        }
        
        return amount;
    }

    /**
     * @notice Set tax exempt status
     */
    function setTaxExempt(address account, bool exempt) external onlyRole(ADMIN_ROLE) {
        taxExempt[account] = exempt;
    }

    /**
     * @notice Set blacklist status
     */
    function setBlacklisted(address account, bool blacklisted) external onlyRole(ADMIN_ROLE) {
        isBlacklisted[account] = blacklisted;
        emit BlacklistUpdated(account, blacklisted);
    }
    // ============ Analytics & Reporting Functions ============

    /**
     * @notice Get detailed token metrics
     */
    function getDetailedTokenMetrics() external view returns (TokenMetrics memory metrics) {
        uint256 totalStaked = stakingContract.getTotalStaked();

        return TokenMetrics({
            totalSupply: totalSupply(),
            circulatingSupply: totalSupply() - balanceOf(address(this)) - balanceOf(address(0)),
            burnedTokens: totalBurnedTokens,
            stakingBalance: totalStaked,
            treasuryBalance: balanceOf(treasuryAddress),
            liquidityBalance: balanceOf(address(poolManager)),
            lastTWAPPrice: lastTWAPPrice,
            emissionRate: emissionRate,
            currentHalvingEpoch: currentHalvingEpoch
        });
    }

    /**
     * @notice Get tax statistics
     */
    function getTaxStats() external view returns (
        uint256 _buyTaxCollected,
        uint256 _sellTaxCollected,
        uint256 _transferTaxCollected,
        uint256 _totalTaxCollected
    ) {
        return (
            buyTaxCollected,
            sellTaxCollected,
            transferTaxCollected,
            buyTaxCollected + sellTaxCollected + transferTaxCollected
        );
    }

    /**
     * @notice Export transaction history
     */
    function exportTransactionHistory(
        address account,
        uint256 startTime,
        uint256 endTime
    ) external view returns (
        bytes32[] memory txHashes,
        uint256[] memory amounts,
        uint256[] memory timestamps,
        string[] memory txTypes
    ) {
        require(account != address(0), "Invalid address");
        require(startTime < endTime, "Invalid time range");

        uint256 total = 0;
        for (uint256 i = 0; i < transactionLogs[account].length; i++) {
            uint256 ts = transactionLogs[account][i].timestamp;
            if (ts >= startTime && ts <= endTime) {
                total++;
            }
        }

        txHashes = new bytes32[](total);
        amounts = new uint256[](total);
        timestamps = new uint256[](total);
        txTypes = new string[](total);

        uint256 idx = 0;
        for (uint256 i = 0; i < transactionLogs[account].length; i++) {
            TransactionRecord memory txRec = transactionLogs[account][i];
            if (txRec.timestamp >= startTime && txRec.timestamp <= endTime) {
                txHashes[idx] = txRec.txHash;
                amounts[idx] = txRec.amount;
                timestamps[idx] = txRec.timestamp;
                txTypes[idx] = txRec.txType;
                idx++;
            }
        }

        return (txHashes, amounts, timestamps, txTypes);
    }

    /**
     * @notice Record transaction for analytics
     */
    function _recordTransaction(
        address user,
        uint256 amount,
        string memory txType
    ) internal {
        if (user == address(0)) return;

        bytes32 txHash = keccak256(abi.encodePacked(user, amount, txType, block.timestamp, blockhash(block.number - 1)));
        transactionLogs[user].push(TransactionRecord({
            txHash: txHash,
            amount: amount,
            timestamp: block.timestamp,
            txType: txType
        }));

        // Maintain size limit
        if (transactionLogs[user].length > maxTrackedTransactions) {
            for (uint256 i = 0; i < transactionLogs[user].length - 1; i++) {
                transactionLogs[user][i] = transactionLogs[user][i + 1];
            }
            transactionLogs[user].pop();
        }
    }

    /**
     * @notice Get current market cap
     */
    function getMarketCap() public view returns (uint256 marketCap) {
        uint256 price = getCurrentPrice();
        return (totalSupply() - balanceOf(address(0))) * price / (10**decimals());
    }

    /**
     * @notice Get current token price
     */
    function getCurrentPrice() public view returns (uint256 price) {
        if (address(priceFeed) != address(0)) {
            (, int256 answer, , , ) = priceFeed.latestRoundData();
            if (answer > 0) {
                return uint256(answer);
            }
        }
        return lastTWAPPrice;
    }

    /**
     * @notice Estimate next halving time
     */
    function estimateNextHalving() public view returns (uint256 timestamp) {
        if (stakingContract.getHalvingPeriod() == 0) return 0;
        return lastHalvingTime + stakingContract.getHalvingPeriod();
    }
    // ============ View Functions ============

    /**
     * @notice Get buyback statistics
     */
    function getBuybackStatistics() external view returns (BuybackStats memory) {
        return buybackStatistics;
    }

    /**
     * @notice Get pool information
     */
    function getPoolInfo() external view returns (PoolInfo memory poolInfo) {
        require(address(poolManager) != address(0), "PoolManager not set");
        require(poolInitialized, "Pool not initialized");
        if (!poolInitialized) {
            return PoolInfo(bytes32(0), 0, 0, 0, 0, 0);
        }
        
        (uint160 sqrtPriceX96, int24 tick, uint24 observationIndex, uint24 observationCardinality) = 
            poolManager.getSlot0(PoolId.wrap(poolId));
        
        return PoolInfo({
            id: poolId,
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            observationIndex: observationIndex,
            observationCardinality: observationCardinality,
            fee: poolFees[poolId]
        });
    }

    /**
     * @notice Get position details
     */
    function getPosition(uint256 positionId) external view returns (PoolPosition memory) {
        return positions[positionId];
    }

    /**
     * @notice Get halving status
     */
    function getHalvingStatus() external view returns (uint256 epoch, uint256 lastTime, uint256 nextTime) {
        epoch = currentHalvingEpoch;
        lastTime = lastHalvingTime;
        nextTime = lastHalvingTime + stakingContract.getHalvingPeriod();
        return (epoch, lastTime, nextTime);
    }

    /**
     * @notice Get buyback budget
     */
    function getBuybackBudget() external view returns (uint256) {
        return buybackBudget;
    }

    /**
     * @notice Get contract version
     */
    function version() external pure returns (string memory) {
        return "TerraStakeToken v1.0";
    }

    /**
     * @notice Get token standard
     */
    function tokenStandard() external pure returns (string memory) {
        return "TerraStake ERC20";
    }

    /**
     * @notice Get last upgrade time
     */
    function getLastUpgradeTime() external view returns (uint256) {
        return contractInfo.lastUpgradeTime;
    }

    /**
     * @notice Get last implementation
     */
    function getLastImplementation() external view returns (address) {
        return contractInfo.implementation;
    }
    // ============ Additional Features ============

    /**
     * @notice Execute airdrop to multiple recipients
     */
    function airdrop(
        address[] calldata recipients,
        uint256 amount
    ) external onlyRole(MINTER_ROLE) nonReentrant {
        require(recipients.length > 0, "No recipients");
        require(recipients.length <= MAX_BATCH_SIZE, "Batch too large");
        // Check for duplicates using a mapping
        mapping(address => bool) memory seen;
        for (uint256 i = 0; i < recipients.length; i++) {
            require(!seen[recipients[i]], "Duplicate recipient");
            seen[recipients[i]] = true;

            // Perform airdrop logic
            require(recipients[i] != address(0), "Invalid recipient");
            require(!isBlacklisted[recipients[i]], "Recipient blacklisted");
            _mint(recipients[i], adjustedAmount);
            _recordTransaction(recipients[i], adjustedAmount, "airdrop");
        }

        emit AirdropExecuted(recipients, adjustedAmount, totalAdjusted);

        uint256 totalAmount = amount * recipients.length;
        uint256 adjustedAmount = applyHalvingToMint ? _applyHalvingToAmount(amount) : amount;
        uint256 totalAdjusted = adjustedAmount * recipients.length;

        require(totalSupply() + totalAdjusted <= MAX_SUPPLY, "Exceeds max supply");

        for (uint256 i = 0; i < recipients.length; i++) {
            address recipient = recipients[i];
            require(!isBlacklisted[recipient], "Recipient blacklisted");
            _mint(recipient, adjustedAmount);
            _recordTransaction(recipient, adjustedAmount, "airdrop");
        }

        emit AirdropExecuted(recipients, adjustedAmount, totalAdjusted);
    }

    /**
     * @notice Create token grant with vesting
     */
    function createGrant(
        address beneficiary,
        uint256 amount,
        uint256 startTime,
        uint256 cliffDuration,
        uint256 vestingDuration,
        bool revocable
    ) external onlyRole(GOVERNANCE_ROLE) returns (uint256 grantId) {
        require(beneficiary != address(0), "Invalid beneficiary");
        require(amount > 0, "Zero amount");
        require(startTime >= block.timestamp, "Start time must be in the future or now");
        require(cliffDuration <= vestingDuration, "Invalid cliff");
        
        grantId = grants.length;
        grants.push(Grant({
            beneficiary: beneficiary,
            amount: amount,
            startTime: startTime,
            cliffDuration: cliffDuration,
            vestingDuration: vestingDuration,
            claimed: 0,
            revoked: false,
            revocable: revocable,
            created: block.timestamp
        }));

        _mint(address(this), amount);
        emit GrantCreated(grantId, beneficiary, amount);
        return grantId;
    }

    /**
     * @notice Claim vested tokens from grant
     */
    function claimGrant(uint256 grantId) external nonReentrant {
        require(grantId < grants.length, "Invalid grant");
        Grant storage grant = grants[grantId];
        require(!grant.revoked, "Grant revoked");
        require(grant.vestingDuration > 0, "Invalid vesting duration");
        require(!grant.revoked, "Grant revoked");

        uint256 vested = calculateVestedAmount(grantId);
        uint256 claimable = vested - grant.claimed;
        require(claimable > 0, "Nothing to claim");

        grant.claimed += claimable;
        _transfer(address(this), msg.sender, claimable);
        emit TokensClaimed(grantId, msg.sender, claimable);
    }

    /**
     * @notice Revoke token grant
     */
    function revokeGrant(uint256 grantId) external onlyRole(GOVERNANCE_ROLE) {
        require(grantId < grants.length, "Invalid grant");
        Grant storage grant = grants[grantId];
        require(grant.revocable, "Not revocable");
        require(!grant.revoked, "Already revoked");

        uint256 vested = calculateVestedAmount(grantId);
        uint256 unvested = grant.amount - vested;
        
        grant.revoked = true;
        if (unvested > 0) {
            _burn(address(this), unvested);
        }
        emit GrantRevoked(grantId, unvested);
    }

    /**
     * @notice Calculate vested amount
     */
    function calculateVestedAmount(uint256 grantId) public view returns (uint256) {
        require(grantId < grants.length, "Invalid grant");
        Grant memory grant = grants[grantId];
        
        if (block.timestamp < grant.startTime + grant.cliffDuration) {
            return 0;
        } else if (block.timestamp >= grant.startTime + grant.vestingDuration) {
            return grant.amount;
        } else {
            return (grant.amount * (block.timestamp - grant.startTime)) / grant.vestingDuration;
        }
    }

    /**
     * @notice Distribute collected fees
     */
    function distributeFees() external onlyRole(GOVERNANCE_ROLE) {
        require(
            buyTaxAllocation.liquidity + buyTaxAllocation.treasury + buyTaxAllocation.staking + buyTaxAllocation.buyback == 100,
            "Allocation percentages must sum to 100"
        );

        uint256 totalFees = buybackBudget;
        require(totalFees > 0, "No fees to distribute");

        uint256 liquidityAmount = (totalFees * buyTaxAllocation.liquidity) / 100;
        uint256 treasuryAmount = (totalFees * buyTaxAllocation.treasury) / 100;
        uint256 stakingAmount = (totalFees * buyTaxAllocation.staking) / 100;
        uint256 buybackAmount = totalFees - liquidityAmount - treasuryAmount - stakingAmount;

        // Ensure poolManager is properly initialized
        require(address(poolManager) != address(0), "PoolManager not set");

        if (liquidityAmount > 0) {
            _transfer(address(this), address(poolManager), liquidityAmount);
        }
        if (stakingAmount > 0) {
            require(address(stakingContract) != address(0), "Staking contract not initialized");
            _transfer(address(this), address(stakingContract), stakingAmount);
        }
        if (stakingAmount > 0 && address(stakingContract) != address(0)) {
            _transfer(address(this), address(stakingContract), stakingAmount);
        }
        require(buybackAmount >= 0, "Buyback amount cannot be negative");
        emit FeesDistributed(liquidityAmount, treasuryAmount, stakingAmount, buybackAmount);
        
    }

    /**
     * @notice Execute batch transfer
        require(recipients.length == amounts.length, "Length mismatch");
        require(recipients.length <= MAX_BATCH_SIZE, "Batch too large");

        uint256 total = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            address recipient = recipients[i];
            uint256 amount = amounts[i];
            require(recipient != address(0), "Invalid recipient");
            total += amount;
            _transfer(msg.sender, recipient, amount);
            _recordTransaction(recipient, amount, "batch_transfer");
        }

        require(balanceOf(msg.sender) >= total, "Insufficient balance");
            uint256 amount = amounts[i];
            require(recipient != address(0), "Invalid recipient");
            _transfer(msg.sender, recipient, amount);
            _recordTransaction(recipient, amount, "batch_transfer");
        }
    }

    /**
     * @notice Verify cross-chain message authenticity
     */
    function isTrustedSender(uint16 srcChainId, address sender) public view returns (bool) {
        bytes32 senderHash = keccak256(abi.encodePacked(srcChainId, sender));
        return trustedCrossChainSenders[senderHash];
    }
}