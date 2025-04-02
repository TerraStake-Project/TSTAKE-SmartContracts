// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/src/interfaces/IHooks.sol";
import "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import "@uniswap/v4-core/src/types/PoolKey.sol";
import "@uniswap/v4-core/src/types/PoolId.sol";
import "@uniswap/v4-core/src/libraries/TickMath.sol";
import "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import "@api3/contracts/api3-server-v1/proxies/interfaces/IProxy.sol";

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
 * @dev Integrates with TerraStakeNeuralManager for AI-driven indexing and rebalancing with full Uniswap V4 support
 */
contract TerraStakeToken is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    ERC20BurnableUpgradeable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    IUnlockCallback
{
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    // ============ Constants ============
    uint256 public constant MAX_SUPPLY = 3_000_000_000 * 10**18;
    uint32 public constant MIN_TWAP_PERIOD = 5 minutes;
    uint256 public constant MAX_BATCH_SIZE = 200;
    uint256 public constant PRICE_DECIMALS = 18;
    uint256 public constant MIN_TRANSFER_AMOUNT = 100 * 10**18;
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
    error CrossChainSyncFailed(bytes reason);
    error InvalidChainId();
    error StaleMessage();
    error TransactionThrottled();
    error MaxGasPriceExceeded();
    error TransferAmountTooSmall();
    error SenderIsBot();
    error ReceiverIsBot();
    
    // Uniswap V4 specific errors
    error PoolAlreadyInitialized();
    error InvalidTickRange();
    error SwapSlippageExceeded();
    error PositionNotFound();
    error InsufficientLiquidity();
    error InvalidHookConfiguration();
    error CallbackNotAuthorized();
    error InvalidSqrtPriceLimit();

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
        
        // Initialize Uniswap V4 settings
        twapObservationWindow = 1 days; // Default TWAP window (can be updated by governance)
        poolInitialized = false;
    }

    // ============ Uniswap V4 Integration ============
    
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
        bytes32 _poolId = key.toId();
        poolManager.initialize(key, _sqrtPriceX96, _hookData);
        
        // Store pool information
        poolKey = key;
        poolId = _poolId;
        poolHooks[_poolId] = _hook;
        poolFees[_poolId] = _fee;
        hookAddress[_poolId] = address(_hook);
        
        // Create initial TWAP observation array for this pool
        TWAPObservation memory initialObservation = TWAPObservation({
            blockTimestamp: uint32(block.timestamp),
            sqrtPriceX96: _sqrtPriceX96,
            liquidity: 0
        });
        
        twapObservations[_poolId].push(initialObservation);
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
     * @return positionId The ID of the created position
     * @return liquidityActual The actual amount of liquidity added
     */
    function addLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityDesired,
        address recipient
    ) external onlyRole(LIQUIDITY_MANAGER_ROLE) nonReentrant returns (uint256 positionId, uint128 liquidityActual) {
        if (!poolInitialized) revert PoolNotInitialized();
        if (tickLower >= tickUpper) revert InvalidTickRange();
        
        // Validate tick range is valid for the current tickSpacing
        require(tickLower % poolKey.tickSpacing == 0, "Invalid lower tick");
        require(tickUpper % poolKey.tickSpacing == 0, "Invalid upper tick");
        
        // Create modify liquidity params
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidityDesired))
        });
        
        // Call pool manager to add liquidity
        (int256 amount0, int256 amount1) = poolManager.modifyLiquidity(
            poolKey,
            params,
            abi.encode(this, recipient)
        );
        
        // Calculate token amounts required
        uint256 amount0Uint = amount0 >= 0 ? 0 : uint256(-amount0);
        uint256 amount1Uint = amount1 >= 0 ? 0 : uint256(-amount1);
        
        // Ensure this contract has enough tokens
        if (amount0Uint > 0) {
            IERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(
                msg.sender,
                address(this),
                amount0Uint
            );
            IERC20(Currency.unwrap(poolKey.currency0)).safeApprove(address(poolManager), amount0Uint);
        }
        
        if (amount1Uint > 0) {
            IERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(
                msg.sender,
                address(this),
                amount1Uint
            );
            IERC20(Currency.unwrap(poolKey.currency1)).safeApprove(address(poolManager), amount1Uint);
        }
        
        // Store position info
        positionId = ++positionCounter;
        positions[positionId] = PoolPosition({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidityDesired,
            tokenId: positionId,
            isActive: true
        });
        
        liquidityActual = liquidityDesired;
        
        emit PositionCreated(positionId, tickLower, tickUpper, liquidityDesired);
        
        // Record TWAP observation after liquidity change
        _recordTWAPObservation();
        
        return (positionId, liquidityActual);
    }
    
    /**
     * @notice Remove liquidity from a Uniswap V4 position
     * @param positionId The ID of the position
     * @param liquidityToRemove The amount of liquidity to remove (0 for all)
     * @param recipient The recipient of the withdrawn tokens
     * @return amount0 The amount of token0 withdrawn
     * @return amount1 The amount of token1 withdrawn
     */
    function removeLiquidity(
        uint256 positionId,
        uint128 liquidityToRemove,
        address recipient
    ) external onlyRole(LIQUIDITY_MANAGER_ROLE) nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (!poolInitialized) revert PoolNotInitialized();
        
        PoolPosition storage position = positions[positionId];
        if (!position.isActive) revert PositionNotFound();
        
        // If liquidityToRemove is 0, remove all liquidity
        if (liquidityToRemove == 0) {
            liquidityToRemove = position.liquidity;
        }
        
        if (liquidityToRemove > position.liquidity) {
            liquidityToRemove = position.liquidity;
        }
        
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: position.tickLower,
            tickUpper: position.tickUpper,
            liquidityDelta: -int256(uint256(liquidityToRemove))
        });
        
        // Remove liquidity from the pool
        (int256 amount0Delta, int256 amount1Delta) = poolManager.modifyLiquidity(
            poolKey,
            params,
            abi.encode(this, recipient)
        );
        
        // Update token amounts
        amount0 = amount0Delta > 0 ? uint256(amount0Delta) : 0;
        amount1 = amount1Delta > 0 ? uint256(amount1Delta) : 0;
        
        // Update position state
        position.liquidity -= liquidityToRemove;
        
        if (position.liquidity == 0) {
            position.isActive = false;
            emit PositionBurned(positionId);
        } else {
            emit PositionModified(positionId, -int128(liquidityToRemove));
        }
        
        // Record TWAP observation after liquidity change
        _recordTWAPObservation();
        
        return (amount0, amount1);
    }
    
    /**
     * @notice Execute a swap through the Uniswap V4 pool
     * @param tokenIn The address of the input token
     * @param tokenOut The address of the output token
     * @param amountIn The input amount
     * @param amountOutMinimum The minimum output amount (slippage protection)
     * @param sqrtPriceLimitX96 The price limit for the swap
     * @param recipient The recipient of the output tokens
     * @return amountOut The amount of tokens received
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
        
        // Determine if tokenIn is currency0 or currency1
        bool zeroForOne = tokenIn == Currency.unwrap(poolKey.currency0);
        
        // Transfer tokens from sender to this contract
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).safeApprove(address(poolManager), amountIn);
        
        // Prepare swap parameters
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(amountIn),
            sqrtPriceLimitX96: sqrtPriceLimitX96 == 0 ? 
                (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1) : 
                sqrtPriceLimitX96
        });
        
        // Execute swap
        (int256 amount0Delta, int256 amount1Delta) = poolManager.swap(
            poolKey,
            params,
            abi.encode(this, recipient)
        );
        
        // Calculate output amount
        amountOut = uint256(-(zeroForOne ? amount1Delta : amount0Delta));
        
        // Ensure minimum output amount is satisfied
        if (amountOut < amountOutMinimum) revert SwapSlippageExceeded();
        
        // Record TWAP observation after swap
        _recordTWAPObservation();
        
        emit SwapExecuted(
            poolId,
            tokenIn,
            tokenOut,
            amountIn,
            amountOut
        );
        
        return amountOut;
    }
    
    /**
     * @notice Implementation of Uniswap V4 hook callback handler
     * @param sender The sender of the callback
     * @param key The pool key
     * @param data The callback data
     */
    function v4HookCallback(
        address sender,
        PoolKey calldata key,
        bytes calldata data
    ) external override {
        // Ensure callback is coming from the pool manager
        if (msg.sender != address(poolManager)) revert CallbackNotAuthorized();
        
        // Ensure the pool key matches our pool
        if (key.toId() != poolId) revert InvalidPool();
        
        // Handle callback based on the callback type
        (address callbackContract, address recipient) = abi.decode(data, (address, address));
        
        // Handle token transfers if needed
        // This logic would depend on the specific action being performed
    }
    
    /**
     * @notice Record a TWAP observation for the pool
     */
    function _recordTWAPObservation() internal {
        if (!poolInitialized) return;
        
        (uint160 sqrtPriceX96, int24 tick, , uint128 liquidity) = poolManager.getSlot0(poolKey);
        
        TWAPObservation memory observation = TWAPObservation({
            blockTimestamp: uint32(block.timestamp),
            sqrtPriceX96: sqrtPriceX96,
            liquidity: liquidity
        });
        
        twapObservations[poolId].push(observation);
        lastTwapObservationIndex[poolId] = twapObservations[poolId].length - 1;
        
        // Update internal TWAP price for token metrics
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
     * @notice Calculate token price from sqrtPriceX96
     * @param sqrtPriceX96 The sqrt price in X96 format
     * @return The token price with 18 decimals
     */
    function _calculatePriceFromSqrtPriceX96(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        uint256 price = FullMath.mulDiv(priceX192, 1, 1 << 192);
        
        // Adjust for decimal difference if needed
        // This depends on the token pair (stablecoin usually has 6 decimals, token has 18)
        return price * 1e12; // Assuming USDC (6 decimals) to TSTAKE (18 decimals)
    }
    
    /**
     * @notice Check if a price change is valid based on volatility threshold
     * @param oldPrice The previous price
     * @param newPrice The new price    
     * @return isValid Whether the price change is within acceptable thresholds
     */
    function _isValidPriceChange(uint256 oldPrice, uint256 newPrice) internal view returns (bool isValid) {
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
     * @notice Get time-weighted average price from pool observations
     * @param period The time period to calculate TWAP for
     * @return twapPrice The time-weighted average price
     */
    function getTWAPPrice(uint32 period) public view returns (uint256 twapPrice) {
        if (!poolInitialized) return lastTWAPPrice;
        
        // Ensure we have a reasonable period
        uint32 minPeriod = MIN_TWAP_PERIOD;
        if (period < minPeriod) period = minPeriod;
        
        // Ensure we don't exceed the observation window
        if (period > twapObservationWindow) period = uint32(twapObservationWindow);
        
        // Calculate time boundaries
        uint32 currentTime = uint32(block.timestamp);
        uint32 targetTime = currentTime - period;
        
        // Find observations that bracket the target time
        uint256 observationCount = twapObservations[poolId].length;
        if (observationCount < 2) return lastTWAPPrice;
        
        uint256 latestIndex = lastTwapObservationIndex[poolId];
        uint256 earliestIndex = 0;
        
        // Binary search to find the appropriate observations
        uint256 beforeIndex = 0;
        uint256 afterIndex = 0;
        
        // If the earliest observation is already after our target time
        if (twapObservations[poolId][earliestIndex].blockTimestamp >= targetTime) {
            beforeIndex = earliestIndex;
            afterIndex = earliestIndex;
        } 
        // If the latest observation is before our target time
        else if (twapObservations[poolId][latestIndex].blockTimestamp <= targetTime) {
            beforeIndex = latestIndex;
            afterIndex = latestIndex;
        } 
        // Binary search for the observations that bracket our target time
        else {
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
        
        // Get the observations
        TWAPObservation memory beforeObs = twapObservations[poolId][beforeIndex];
        TWAPObservation memory afterObs = twapObservations[poolId][afterIndex];
        
        // If observations are at the same time, use the price directly
        if (beforeObs.blockTimestamp == afterObs.blockTimestamp) {
            return _calculatePriceFromSqrtPriceX96(afterObs.sqrtPriceX96);
        }
        
        // Calculate weights for time-weighted average
        uint32 timeDelta = afterObs.blockTimestamp - beforeObs.blockTimestamp;
        uint32 timeWeight = targetTime - beforeObs.blockTimestamp;
        
        // Calculate weighted average of sqrtPriceX96
        uint160 weightedSqrtPriceX96;
        if (timeWeight == 0) {
            weightedSqrtPriceX96 = beforeObs.sqrtPriceX96;
        } else if (timeWeight >= timeDelta) {
            weightedSqrtPriceX96 = afterObs.sqrtPriceX96;
        } else {
            uint256 afterWeight = (uint256(timeWeight) * 1e18) / timeDelta;
            uint256 beforeWeight = 1e18 - afterWeight;
            
            uint256 weightedBefore = (uint256(beforeObs.sqrtPriceX96) * beforeWeight) / 1e18;
            uint256 weightedAfter = (uint256(afterObs.sqrtPriceX96) * afterWeight) / 1e18;
            
            weightedSqrtPriceX96 = uint160(weightedBefore + weightedAfter);
        }
        
        // Calculate final price from weighted sqrtPriceX96
        return _calculatePriceFromSqrtPriceX96(weightedSqrtPriceX96);
    }
    
    /**
     * @notice Update the TWAP price from the pool
     */
    function updateTWAPPrice() public {
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
     * @notice Force update the TWAP records with current pool state
     * @dev This can be called periodically to ensure up-to-date TWAP data
     */
    function forceUpdateTWAPObservation() external onlyRole(PRICE_ORACLE_ROLE) {
        _recordTWAPObservation();
    }
    
    /**
     * @notice Set the TWAP observation window
     * @param newWindow The new window in seconds
     */
    function setTWAPObservationWindow(uint32 newWindow) external onlyRole(GOVERNANCE_ROLE) {
        require(newWindow >= MIN_TWAP_PERIOD, "Window too short");
        require(newWindow <= 7 days, "Window too long");
        twapObservationWindow = newWindow;
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
        bytes32 txreference
    ) external {
        require(msg.sender == address(crossChainHandler), "Unauthorized");
        require(!isBlacklisted[recipient], "Recipient blacklisted");
        require(totalSupply() + amount <= MAX_SUPPLY, "Exceeds max supply");
        
        _mint(recipient, amount);
        
        if (address(neuralManager) != address(0)) {
            neuralManager.recordCrossChainTransfer(srcChainId, recipient, amount, txreference);
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
        if (!poolInitialized) revert PoolNotInitialized();
        
        // Prepare swap parameters for V4
        bool zeroForOne = poolKey.currency0 == Currency.wrap(address(priceFeed));
        
        // Ensure the contract has approval to spend the tokens
        IERC20(Currency.unwrap(zeroForOne ? poolKey.currency0 : poolKey.currency1))
            .safeApprove(address(poolManager), usdcAmount);
        
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(usdcAmount),
            sqrtPriceLimitX96: zeroForOne ? 
                TickMath.MIN_SQRT_RATIO + 1 : 
                TickMath.MAX_SQRT_RATIO - 1
        });
        
        // Execute the swap
        (int256 amount0Delta, int256 amount1Delta) = poolManager.swap(
            poolKey,
            params,
            abi.encode(address(this), address(this))
        );
        
        // Calculate how many tokens we received
        uint256 tokensReceived;
        if (zeroForOne) {
            tokensReceived = uint256(-amount1Delta);
        } else {
            tokensReceived = uint256(-amount0Delta);
        }
        
        // Record the TWAP observation after the swap
        _recordTWAPObservation();
        
        return tokensReceived;
    }

    /**
     * @notice Add liquidity to boost market stability
     * @param usdcAmount Amount of USDC to use for liquidity
     * @param tickLower Lower tick boundary for the position
     * @param tickUpper Upper tick boundary for the position
     */
    function injectLiquidity(
        uint256 usdcAmount,
        int24 tickLower,
        int24 tickUpper
    ) external onlyRole(LIQUIDITY_MANAGER_ROLE) nonReentrant returns (uint256 positionId) {
        require(usdcAmount > 0, "Zero amount");
        require(tickLower < tickUpper, "Invalid tick range");
        
        // Calculate the amount of tokens needed based on current price
        uint256 tokenAmount = _calculateTokensForLiquidity(usdcAmount, tickLower, tickUpper);
        require(tokenAmount > 0, "Zero token amount");
        
        // Ensure this contract has enough USDC 
        IERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(
            msg.sender,
            address(this),
            usdcAmount
        );
        
        // Mint tokens for liquidity if needed
        if (balanceOf(address(this)) < tokenAmount) {
            require(totalSupply() + tokenAmount <= MAX_SUPPLY, "Exceeds max supply");
            _mint(address(this), tokenAmount);
        }
        
        // Calculate the liquidity amount based on the current price
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolKey);
        uint128 liquidity = _calculateLiquidityForAmounts(
            sqrtPriceX96, 
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            usdcAmount,
            tokenAmount
        );
        
        // Approve tokens for pool manager
        IERC20(Currency.unwrap(poolKey.currency0)).safeApprove(address(poolManager), usdcAmount);
        IERC20(Currency.unwrap(poolKey.currency1)).safeApprove(address(poolManager), tokenAmount);
        
        // Add liquidity to the pool
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidity))
        });
        
        poolManager.modifyLiquidity(
            poolKey,
            params,
            abi.encode(address(this), address(this))
        );
        
        // Store position info
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
        
        // Record TWAP observation
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
        
        (uint160 sqrtPriceX96, int24 currentTick, , ) = poolManager.getSlot0(poolKey);
        
        // Calculate token amount based on the price range
        if (currentTick < tickLower) {
            // Current price is below range, only token0 (USDC) is needed
            return 0;
        } else if (currentTick >= tickUpper) {
            // Current price is above range, only token1 (TSTAKE) is needed
            // Calculate based on the upper tick price
            uint160 sqrtRatioAtUpperTick = TickMath.getSqrtRatioAtTick(tickUpper);
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
            uint160 sqrtRatioAtLowerTick = TickMath.getSqrtRatioAtTick(tickLower);
            uint160 sqrtRatioAtUpperTick = TickMath.getSqrtRatioAtTick(tickUpper);
            
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
    
    /**
     * @notice Set tax exempt status for an address
     * @param account Address to update
     * @param exempt Whether the address is tax exempt
     */
    function setTaxExempt(address account, bool exempt) external onlyRole(ADMIN_ROLE) {
        taxExempt[account] = exempt;
    }
    
    /**
     * @notice Blacklist or unblacklist an address
     * @param account Address to update
     * @param blacklisted Whether the address is blacklisted
     */
    function setBlacklisted(address account, bool blacklisted) external onlyRole(ADMIN_ROLE) {
        isBlacklisted[account] = blacklisted;
        emit BlacklistUpdated(account, blacklisted);
    }
    
    /**
     * @notice Set tax rates
     * @param _buybackTaxBasisPoints New buyback tax in basis points
     * @param _burnRateBasisPoints New burn rate in basis points
     */
    function setTaxRates(uint256 _buybackTaxBasisPoints, uint256 _burnRateBasisPoints) external onlyRole(GOVERNANCE_ROLE) {
        require(_buybackTaxBasisPoints + _burnRateBasisPoints <= MAX_TAX_BASIS_POINTS, "Tax too high");
        buybackTaxBasisPoints = _buybackTaxBasisPoints;
        burnRateBasisPoints = _burnRateBasisPoints;
    }

    // ============ Administrative Functions ============
    
    /**
     * @notice Pause all token transfers
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause token transfers
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Update governance contract address
     */
    function setGovernanceContract(address _governanceContract) external onlyRole(ADMIN_ROLE) {
        require(_governanceContract != address(0), "Zero address");
        governanceContract = ITerraStakeGovernance(_governanceContract);
        emit GovernanceUpdated(_governanceContract);
    }
    
    /**
     * @notice Update staking contract address
     */
    function setStakingContract(address _stakingContract) external onlyRole(ADMIN_ROLE) {
        require(_stakingContract != address(0), "Zero address");
        stakingContract = ITerraStakeStaking(_stakingContract);
        emit StakingUpdated(_stakingContract);
    }
    
    /**
     * @notice Update liquidity guard contract address
     */
    function setLiquidityGuard(address _liquidityGuard) external onlyRole(ADMIN_ROLE) {
        require(_liquidityGuard != address(0), "Zero address");
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);
        emit LiquidityGuardUpdated(_liquidityGuard);
    }
    /**
     * @notice Update neural manager contract address
     * @param _neuralManager Address of the neural management contract
     */
    function setNeuralManager(address _neuralManager) external onlyRole(ADMIN_ROLE) {
        neuralManager = ITerraStakeNeural(_neuralManager);
        emit NeuralManagerUpdated(_neuralManager);
    }
    
    /**
     * @notice Set maximum gas price for transactions
     * @param _maxGasPrice New maximum gas price
     */
    function setMaxGasPrice(uint256 _maxGasPrice) external onlyRole(ADMIN_ROLE) {
        require(_maxGasPrice > 5 gwei, "Gas price too low");
        maxGasPrice = _maxGasPrice;
        emit MaxGasPriceUpdated(_maxGasPrice);
    }
    
    /**
     * @notice Set TWAP deviation threshold
     * @param _threshold New threshold in basis points (100 = 1%)
     */
    function setTwapDeviationThreshold(uint256 _threshold) external onlyRole(GOVERNANCE_ROLE) {
        require(_threshold >= 100 && _threshold <= 5000, "Invalid threshold");
        twapDeviationThreshold = _threshold;
        emit TwapDeviationThresholdUpdated(_threshold);
    }
    
    /**
     * @notice Update emission rate
     * @param _emissionRate New emission rate
     */
    function updateEmissionRate(uint256 _emissionRate) external onlyRole(GOVERNANCE_ROLE) {
        require(_emissionRate > 0, "Zero emission rate");
        require(_emissionRate <= emissionRate, "Can only decrease");
        emissionRate = _emissionRate;
        emit EmissionRateUpdated(_emissionRate);
    }
    
    /**
     * @notice Set whether to apply halving to minting operations
     * @param _apply Whether to apply halving adjustments
     */
    function setApplyHalvingToMint(bool _apply) external onlyRole(GOVERNANCE_ROLE) {
        applyHalvingToMint = _apply;
        emit HalvingToMintUpdated(_apply);
    }
    
    /**
     * @notice Transfer buyback budget to treasury
     * @param amount Amount to transfer
     * @param recipient Treasury address
     */
    function transferBuybackBudget(uint256 amount, address recipient) external onlyRole(TREASURY_ROLE) {
        require(amount <= buybackBudget, "Exceeds budget");
        require(recipient != address(0), "Zero address");
        
        buybackBudget -= amount;
        super._update(address(this), recipient, amount);
        
        emit BuybackBudgetTransferred(amount, recipient);
    }

    // ============ Minting ============
    
    /**
     * @notice Mint new tokens for rewards or staking programs
     * @param recipient Address receiving tokens
     * @param amount Amount to mint
     */
    function mint(address recipient, uint256 amount) external onlyRole(MINTER_ROLE) nonReentrant returns (uint256) {
        require(recipient != address(0), "Zero address");
        require(!isBlacklisted[recipient], "Recipient blacklisted");
        
        uint256 adjustedAmount = amount;
        
        // Apply halving adjustment if enabled
        if (applyHalvingToMint) {
            adjustedAmount = _applyHalvingToAmount(amount);
        }
        
        // Apply emission rate cap
        uint256 maxMintAmount = emissionRate;
        if (adjustedAmount > maxMintAmount) {
            adjustedAmount = maxMintAmount;
        }
        
        // Check maximum supply limit
        require(totalSupply() + adjustedAmount <= MAX_SUPPLY, "Exceeds max supply");
        
        // Perform minting
        _mint(recipient, adjustedAmount);
        
        // Event
        emit TokensMinted(recipient, adjustedAmount);
        
        // Notify external systems if needed
        if (address(neuralManager) != address(0)) {
            neuralManager.recordMint(recipient, adjustedAmount);
        }
        
        return adjustedAmount;
    }
    
    /**
     * @notice Apply halving adjustment to an amount
     * @param amount Original amount
     * @return Adjusted amount after halving
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
     * @notice Mint tokens directly to the staking contract
     * @param amount Amount to mint
     */
    function mintToStaking(uint256 amount) external onlyRole(STAKING_MANAGER_ROLE) nonReentrant returns (uint256) {
        require(address(stakingContract) != address(0), "Staking not set");
        
        uint256 adjustedAmount = amount;
        
        // Apply halving adjustment if enabled
        if (applyHalvingToMint) {
            adjustedAmount = _applyHalvingToAmount(amount);
        }
        
        // Apply emission rate cap
        uint256 maxMintAmount = emissionRate;
        if (adjustedAmount > maxMintAmount) {
            adjustedAmount = maxMintAmount;
        }
        
        // Check maximum supply limit
        require(totalSupply() + adjustedAmount <= MAX_SUPPLY, "Exceeds max supply");
        
        // Perform minting
        _mint(address(stakingContract), adjustedAmount);
        
        // Event
        emit StakingMint(adjustedAmount);
        
        return adjustedAmount;
    }
    
    /**
     * @notice Mint tokens for governance rewards
     * @param amount Amount to mint
     */
    function mintForGovernance(uint256 amount) external onlyRole(GOVERNANCE_ROLE) nonReentrant returns (uint256) {
        require(address(governanceContract) != address(0), "Governance not set");
        
        uint256 adjustedAmount = amount;
        
        // Apply halving adjustment if enabled
        if (applyHalvingToMint) {
            adjustedAmount = _applyHalvingToAmount(amount);
        }
        
        // Check maximum supply limit
        require(totalSupply() + adjustedAmount <= MAX_SUPPLY, "Exceeds max supply");
        
        // Perform minting
        _mint(address(governanceContract), adjustedAmount);
        
        // Event
        emit GovernanceMint(adjustedAmount);
        
        return adjustedAmount;
    }
    
    /**
     * @notice Burn tokens from sender's balance
     * @param amount Amount to burn
     */
    function burn(uint256 amount) public override {
        require(amount > 0, "Zero amount");
        super.burn(amount);
        emit TokenBurned(_msgSender(), amount);
    }
    
    /**
     * @notice Burn tokens from a specific account (with approval)
     * @param account Account to burn from
     * @param amount Amount to burn
     */
    function burnFrom(address account, uint256 amount) public override onlyRole(BURNER_ROLE) {
        require(amount > 0, "Zero amount");
        super.burnFrom(account, amount);
        emit TokenBurned(account, amount);
    }
    
    // ============ Hooks ============
    
    /**
     * @dev Hook that is called before any transfer of tokens
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override whenNotPaused {
        // Validate gas price to prevent front-running
        if (tx.gasprice > maxGasPrice) revert MaxGasPriceExceeded();
        
        // Enforce minimum required amount
        if (amount < MIN_TRANSFER_AMOUNT && from != address(0) && to != address(0)) {
            revert TransferAmountTooSmall();
        }
        
        // Run anti-bot checks during normal transfers
        if (address(antiBot) != address(0) && from != address(0) && to != address(0)) {
            if (antiBot.isBot(from)) revert SenderIsBot();
            if (antiBot.isBot(to)) revert ReceiverIsBot();
        }
        
        super._beforeTokenTransfer(from, to, amount);
    }
    
    /**
     * @dev Hook that is called after any transfer of tokens
     */
    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        super._afterTokenTransfer(from, to, amount);
        
        // Notify neuralManager about the transfer if it's set
        if (address(neuralManager) != address(0) && from != address(0) && to != address(0)) {
            neuralManager.recordTransfer(from, to, amount);
        }
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get statistics about active buybacks
     * @return stats Buyback statistics
     */
    function getBuybackStatistics() external view returns (BuybackStats memory) {
        return buybackStatistics;
    }
    
    /**
     * @notice Get information about the Uniswap V4 pool
     * @return poolInfo The current pool information
     */
    function getPoolInfo() external view returns (PoolInfo memory poolInfo) {
        if (!poolInitialized) {
            return PoolInfo(bytes32(0), 0, 0, 0, 0, 0);
        }
        
        (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality) = 
            poolManager.getSlot0(poolKey);
        
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
     * @notice Get information about a specific liquidity position
     * @param positionId The position ID
     * @return position The position details
     */
    function getPosition(uint256 positionId) external view returns (PoolPosition memory) {
        return positions[positionId];
    }
    
    /**
     * @notice Get the current halving status
     * @return epoch Current halving epoch
     * @return lastTime Last halving time
     * @return nextTime Next expected halving time
     */
    function getHalvingStatus() external view returns (uint256 epoch, uint256 lastTime, uint256 nextTime) {
        epoch = currentHalvingEpoch;
        lastTime = lastHalvingTime;
        nextTime = lastHalvingTime + stakingContract.getHalvingPeriod();
        return (epoch, lastTime, nextTime);
    }
    
    /**
     * @notice Get protocol fee tokens accumulated
     * @return amount Amount of tokens accumulated for buybacks
     */
    function getBuybackBudget() external view returns (uint256) {
        return buybackBudget;
    }
    
    /**
     * @notice Version of the contract for upgrades
     * @return version Current version string
     */
    function version() external pure returns (string memory) {
        return "TerraStakeToken v1.0";
    }
    
    /**
     * @notice Get the token standard name
     * @return name The standard name
     */
    function tokenStandard() external pure returns (string memory) {
        return "TerraStake ERC20";
    }
}                         