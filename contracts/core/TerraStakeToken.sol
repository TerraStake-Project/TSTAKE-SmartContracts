// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.21;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

// Uniswap V4 imports
import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/src/interfaces/IHooks.sol";
import "@uniswap/v4-core/src/types/PoolKey.sol";
import "@uniswap/v4-core/src/types/BalanceDelta.sol";
import "@uniswap/v4-core/src/types/Currency.sol";
import "@uniswap/v4-core/src/libraries/PoolId.sol";
import "@uniswap/v4-core/src/libraries/TickMath.sol";
import "@uniswap/v4-core/src/libraries/FullMath.sol";
import "@uniswap/v4-core/src/libraries/CurrencyLibrary.sol";
import "@uniswap/v4-core/src/libraries/Pool.sol";

/**
 * @title TerraStakeToken
 * @notice Advanced ERC20 token with Uniswap V4 integration, cross-chain sync, AI-driven economics,
 * comprehensive security controls, and modular design for scalability.
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
    using Math for uint256;
    using PoolId for PoolKey;
    using CurrencyLibrary for Currency;

    // ============ Constants ============
    uint256 public constant MAX_SUPPLY = 3_000_000_000 * 10**18;
    uint32 public constant MIN_TWAP_PERIOD = 5 minutes;
    uint256 public constant BUYBACK_TAX_BASIS_POINTS = 100; // 1%
    uint256 public constant MAX_TAX_BASIS_POINTS = 500; // 5%
    uint256 public constant BURN_RATE_BASIS_POINTS = 10; // 0.1%
    uint256 public constant HALVING_RATE = 65; // 65% of previous emission (35% reduction)
    uint256 public constant TWAP_UPDATE_COOLDOWN = 30 minutes;
    uint256 public constant EMERGENCY_COOLDOWN = 24 hours;
    address public constant USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // Mainnet USDC

    // ============ Structs ============
    struct BuybackStats {
        uint256 totalTokensBought;
        uint256 totalUSDCSpent;
        uint256 lastBuybackTime;
        uint256 buybackCount;
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

    struct NeuralWeights {
        uint256 timestamp;
        uint256 buyWeight;
        uint256 sellWeight;
        uint256 holdWeight;
        uint256 confidenceScore;
        string modelVersion;
    }

    // ============ State Variables ============
    // Uniswap V4 Integration
    IPoolManager public poolManager;
    PoolKey public poolKey;
    bytes32 public poolId;
    bool public poolInitialized;
    mapping(uint256 => PoolPosition) public positions;
    uint256 public positionCounter;
    mapping(bytes32 => TWAPObservation[]) public twapObservations;
    uint32 public twapObservationWindow;
    Currency public usdcCurrency;

    // Token Metrics and Economics
    uint256 public lastTWAPPrice;
    uint256 public lastTWAPUpdate;
    uint256 public maxGasPrice;
    uint256 public buybackBudget;
    uint256 public totalTaxCollected;
    BuybackStats public buybackStatistics;
    uint256 public currentHalvingEpoch;
    uint256 public lastHalvingTime;
    bool public applyHalvingToMint;
    uint256 public emissionRate;
    uint256 public buybackTaxBasisPoints;
    uint256 public burnRateBasisPoints;
    uint256 public sellTax;
    mapping(address => bool) public isExemptFromTax;

    // Taxation and Allocation
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

    uint256 public buyTax;
    uint256 public transferTax;

    TaxAllocation public buyTaxAllocation;
    TaxAllocation public sellTaxAllocation;
    TaxAllocation public transferTaxAllocation;

    uint256 public maxSellTax;

    // Security and Controls
    mapping(address => bool) public isBlacklisted;
    uint256 public twapDeviationThreshold;
    bool public emergencyMode;
    uint256 public lastEmergencyActionTime;
    NeuralWeights public currentNeuralWeights;
    bool public neuralRecommendationsEnabled;
    uint256 public neuralConfidenceThreshold;
    
    // Emergency & Recovery
    address public treasuryAddress;
    bool public taxesEnabled;
    bool public crossChainEnabled;

    // ============ Roles ============
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant LIQUIDITY_MANAGER_ROLE = keccak256("LIQUIDITY_MANAGER_ROLE");
    bytes32 public constant NEURAL_INDEXER_ROLE = keccak256("NEURAL_INDEXER_ROLE");
    bytes32 public constant AI_MANAGER_ROLE = keccak256("AI_MANAGER_ROLE");
    bytes32 public constant PRICE_ORACLE_ROLE = keccak256("PRICE_ORACLE_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant RECOVERY_ROLE = keccak256("RECOVERY_ROLE");

    // ============ Events ============
    event PoolInitialized(bytes32 indexed poolId, PoolKey poolKey, uint160 sqrtPriceX96);
    event PositionCreated(uint256 positionId, int24 tickLower, int24 tickUpper, uint128 liquidity);
    event PositionModified(uint256 positionId, int128 liquidityDelta);
    event PositionBurned(uint256 positionId);
    event TWAPPriceUpdated(uint256 price);
    event SwapExecuted(bytes32 indexed poolId, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);
    event BuybackExecuted(uint256 amount, uint256 tokensReceived);
    event TaxUpdated(string taxType, uint256 newRate);
    event BlacklistUpdated(address indexed account, bool status);
    event NeuralWeightsUpdated(uint256 buyWeight, uint256 sellWeight, uint256 holdWeight, uint256 confidenceScore);
    event EmergencyModeChanged(bool enabled);
    event EmergencyAction(string action, bool status);
    event TokenRecovered(address indexed token, uint256 amount);
    event ETHRecovered(uint256 amount);
    event FeatureStatusChanged(uint256 feature, bool enabled);
    event FlashLoanExecuted(address indexed recipient, uint256 amount0, uint256 amount1, uint256 fee);

    // ============ Errors ============
    error InvalidPoolManager();
    error InvalidAdmin();
    error PoolNotInitialized();
    error InvalidTickRange();
    error SwapSlippageExceeded();
    error PositionNotFound();
    error SenderIsBot();
    error PoolAlreadyInitialized();
    error EmergencyCooldownActive();
    error InvalidCurrencyPair();
    error FlashLoanFailed();
    error InsufficientFlashLoanFee();

    // ============ Modifiers ============
    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "Not pool manager");
        _;
    }

    // ============ Initialization ============
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _poolManager,
        address admin,
        address _treasuryAddress
    ) public initializer {
        if (_poolManager == address(0)) revert InvalidPoolManager();
        if (admin == address(0)) revert InvalidAdmin();
        if (_treasuryAddress == address(0)) revert("Invalid treasury address");

        __ERC20_init("TerraStakeToken", "TSTAKE");
        __ERC20Permit_init("TerraStakeToken");
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _setupRoles(admin);
        _initializeState(_poolManager, _treasuryAddress);
    }

    function _setupRoles(address admin) private {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(BURNER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(LIQUIDITY_MANAGER_ROLE, admin);
        _grantRole(NEURAL_INDEXER_ROLE, admin);
        _grantRole(AI_MANAGER_ROLE, admin);
        _grantRole(PRICE_ORACLE_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, admin);
        _grantRole(RECOVERY_ROLE, admin);
    }

    function _initializeState(address _poolManager, address _treasuryAddress) private {
        poolManager = IPoolManager(_poolManager);
        treasuryAddress = _treasuryAddress;
        currentHalvingEpoch = 0;
        lastHalvingTime = block.timestamp;
        maxGasPrice = 100 * 10**9;
        buybackTaxBasisPoints = BUYBACK_TAX_BASIS_POINTS;
        burnRateBasisPoints = BURN_RATE_BASIS_POINTS;
        twapDeviationThreshold = 500;
        applyHalvingToMint = true;
        emissionRate = 1_000_000 * 10**18;
        twapObservationWindow = 1 days;
        poolInitialized = false;
        neuralConfidenceThreshold = 70;
        emergencyMode = false;
        buybackBudget = 0;
        taxesEnabled = true;
        crossChainEnabled = true;
        
        // Set up USDC currency for V4
        usdcCurrency = Currency.wrap(USDC_ADDRESS);
    }

    // ============ Uniswap V4 Functions ============
    /**
     * @notice Initialize the TSTAKE/USDC pool in Uniswap V4
     * @param _fee Fee tier for the pool
     * @param _sqrtPriceX96 Initial sqrt price
     */
    function initializeTSTAKE_USDCPool(
        uint24 _fee,
        uint160 _sqrtPriceX96
    ) external onlyRole(LIQUIDITY_MANAGER_ROLE) nonReentrant {
        if (poolInitialized) revert PoolAlreadyInitialized();

        // Create currency for this token
        Currency tokenCurrency = Currency.wrap(address(this));
        
        // Ensure TSTAKE is currency0 and USDC is currency1 (or vice versa) based on sorting
        Currency currency0;
        Currency currency1;
        
        if (tokenCurrency.lt(usdcCurrency)) {
            currency0 = tokenCurrency;
            currency1 = usdcCurrency;
        } else {
            currency0 = usdcCurrency;
            currency1 = tokenCurrency;
        }

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: _fee,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        poolKey = key;
        poolId = key.toId();

        // Initialize the pool
        poolManager.initialize(poolKey, _sqrtPriceX96, "");
        poolInitialized = true;

        // Record initial TWAP observation
        (uint160 sqrtPriceX96, int24 tick, , ) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);

        twapObservations[poolId].push(TWAPObservation({
            blockTimestamp: uint32(block.timestamp),
            sqrtPriceX96: sqrtPriceX96,
            liquidity: liquidity
        }));

        lastTWAPPrice = calculatePriceFromSqrtPriceX96(sqrtPriceX96);
        lastTWAPUpdate = block.timestamp;

        emit PoolInitialized(poolId, poolKey, sqrtPriceX96);
    }

    /**
     * @notice Add liquidity to the TSTAKE/USDC pool
     * @param tickLower Lower tick boundary
     * @param tickUpper Upper tick boundary
     * @param amount0Desired Desired amount of token0
     * @param amount1Desired Desired amount of token1
     * @return positionId ID of the created position
     * @return liquidity Amount of liquidity added
     */
    function addLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external nonReentrant returns (uint256 positionId, uint128 liquidity) {
        if (!poolInitialized) revert PoolNotInitialized();
        if (tickLower >= tickUpper) revert InvalidTickRange();

        // Convert to uint128 for Uniswap V4
        uint128 amount0Uint = uint128(amount0Desired);
        uint128 amount1Uint = uint128(amount1Desired);

        // Create ModifyLiquidityParams
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: 0, // Will be calculated by V4
            salt: keccak256(abi.encode(block.timestamp, tickLower, tickUpper))
        });

        // Use EIP-1153 transient storage for balance tracking
        // This is a key optimization in V4 for netting balance changes
        bytes memory hookData = abi.encode(
            address(this),
            msg.sender,
            amount0Uint,
            amount1Uint
        );

        // Call modifyLiquidity with flash accounting pattern
        (int128 actualAmount0, int128 actualAmount1) = _modifyLiquidityViaPoolManager(
            params,
            amount0Uint,
            amount1Uint,
            hookData
        );

        // Calculate actual liquidity added
        uint128 liquidityDesired = _calculateLiquidity(
            tickLower,
            tickUpper,
            uint256(uint128(actualAmount0)),
            uint256(uint128(actualAmount1))
        );

        // Create position record
        positionId = ++positionCounter;
        positions[positionId] = PoolPosition({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidityDesired,
            tokenId: positionId,
            isActive: true
        });

        emit PositionCreated(positionId, tickLower, tickUpper, liquidityDesired);
        recordTWAPObservation();

        return (positionId, liquidityDesired);
    }

    /**
     * @dev Internal function to modify liquidity using V4's flash accounting pattern
     */
    function _modifyLiquidityViaPoolManager(
        IPoolManager.ModifyLiquidityParams memory params,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes memory hookData
    ) internal returns (int128 amount0, int128 amount1) {
        // Approve tokens to pool manager if needed
        if (amount0Max > 0) {
            IERC20(Currency.unwrap(poolKey.currency0)).approve(address(poolManager), amount0Max);
        }
        if (amount1Max > 0) {
            IERC20(Currency.unwrap(poolKey.currency1)).approve(address(poolManager), amount1Max);
        }

        // Call modifyLiquidity with flash accounting
        BalanceDelta delta = poolManager.modifyLiquidity(
            poolKey,
            params,
            hookData
        );

        // Convert BalanceDelta to int128
        amount0 = delta.amount0();
        amount1 = delta.amount1();

        return (amount0, amount1);
    }

    /**
     * @notice Remove liquidity from a position
     * @param positionId ID of the position
     * @param liquidityToRemove Amount of liquidity to remove (0 for all)
     * @param recipient Address to receive tokens
     * @return amount0 Amount of token0 received
     * @return amount1 Amount of token1 received
     */
    function removeLiquidity(
        uint256 positionId,
        uint128 liquidityToRemove,
        address recipient
    ) external onlyRole(LIQUIDITY_MANAGER_ROLE) nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (!poolInitialized) revert PoolNotInitialized();

        PoolPosition storage position = positions[positionId];
        if (!position.isActive) revert PositionNotFound();

        if (liquidityToRemove == 0 || liquidityToRemove > position.liquidity) {
            liquidityToRemove = position.liquidity;
        }

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: position.tickLower,
            tickUpper: position.tickUpper,
            liquidityDelta: -int256(uint256(liquidityToRemove)),
            salt: keccak256(abi.encode(block.timestamp, position.tickLower, position.tickUpper, liquidityToRemove))
        });

        // Use flash accounting pattern for removing liquidity
        bytes memory hookData = abi.encode(address(this), recipient);
        BalanceDelta delta = poolManager.modifyLiquidity(poolKey, params, hookData);

        // Update position state
        position.liquidity -= liquidityToRemove;
        if (position.liquidity == 0) {
            position.isActive = false;
            emit PositionBurned(positionId);
        } else {
            emit PositionModified(positionId, -int128(liquidityToRemove));
        }

        // Calculate token amounts received
        amount0 = delta.amount0() < 0 ? uint256(-delta.amount0()) : 0;
        amount1 = delta.amount1() < 0 ? uint256(-delta.amount1()) : 0;

        recordTWAPObservation();
        return (amount0, amount1);
    }

    /**
     * @notice Execute a swap using Uniswap V4's flash accounting
     * @param tokenIn Address of input token
     * @param tokenOut Address of output token
     * @param amountIn Amount of input token
     * @param amountOutMinimum Minimum amount of output token
     * @param sqrtPriceLimitX96 Price limit for the swap
     * @param recipient Address to receive output tokens
     * @return amountOut Amount of output token received
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
        if (isBlacklisted[msg.sender] || isBlacklisted[recipient]) revert SenderIsBot();

        bool zeroForOne = tokenIn == Currency.unwrap(poolKey.currency0);
        
        // Transfer tokens from sender to this contract
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        
        // Calculate tax if applicable
        uint256 taxAmount = isExemptFromTax[msg.sender] || !taxesEnabled ? 0 : (amountIn * buybackTaxBasisPoints) / 10000;
        uint256 amountInAfterTax = amountIn - taxAmount;
        
        if (taxAmount > 0) {
            buybackBudget += taxAmount;
            totalTaxCollected += taxAmount;
        }

        // Approve tokens to pool manager
        IERC20(tokenIn).approve(address(poolManager), amountInAfterTax);

        // Set up swap parameters
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(amountInAfterTax),
            sqrtPriceLimitX96: sqrtPriceLimitX96 == 0
                ? (zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1)
                : sqrtPriceLimitX96
        });

        // Execute swap with flash accounting
        bytes memory hookData = abi.encode(address(this), recipient);
        BalanceDelta delta = poolManager.swap(poolKey, params, hookData);

        // Calculate output amount
        amountOut = zeroForOne ? uint256(-delta.amount1()) : uint256(-delta.amount0());

        if (amountOut < amountOutMinimum) revert SwapSlippageExceeded();

        // Update buyback statistics
        buybackStatistics.totalTokensBought += amountOut;
        buybackStatistics.lastBuybackTime = block.timestamp;
        buybackStatistics.buybackCount++;

        emit SwapExecuted(poolId, tokenIn, tokenOut, amountIn, amountOut);
        recordTWAPObservation();

        return amountOut;
    }

    /**
     * @notice Execute a flash loan using Uniswap V4
     * @param amount0 Amount of token0 to borrow
     * @param amount1 Amount of token1 to borrow
     * @param data Arbitrary data to pass to the callback
     */
    function flashLoan(
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external nonReentrant {
        if (!poolInitialized) revert PoolNotInitialized();
        if (isBlacklisted[msg.sender]) revert SenderIsBot();

        // Calculate flash loan fee (0.05%)
        uint256 fee0 = amount0 > 0 ? (amount0 * 5) / 10000 : 0;
        uint256 fee1 = amount1 > 0 ? (amount1 * 5) / 10000 : 0;

        // Encode flash loan data
        bytes memory flashData = abi.encode(
            msg.sender,
            amount0,
            amount1,
            fee0,
            fee1,
            data
        );

        // Execute flash loan through pool manager
        poolManager.lock(abi.encode(address(this), flashData));

        emit FlashLoanExecuted(msg.sender, amount0, amount1, fee0 + fee1);
    }

    /**
     * @notice Callback function for Uniswap V4 hooks
     * @param data Encoded callback data
     * @return result Encoded result
     */
    function uniswapV4LockAcquired(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        // Decode the first layer to determine operation type
        (address caller, bytes memory operationData) = abi.decode(data, (address, bytes));

        // Handle different operation types
        if (caller == address(this)) {
            // This is a flash loan
            (
                address recipient,
                uint256 amount0,
                uint256 amount1,
                uint256 fee0,
                uint256 fee1,
                bytes memory userData
            ) = abi.decode(operationData, (address, uint256, uint256, uint256, uint256, bytes));

            // Transfer borrowed amounts to recipient
            if (amount0 > 0) {
                IERC20(Currency.unwrap(poolKey.currency0)).safeTransfer(recipient, amount0);
            }
            if (amount1 > 0) {
                IERC20(Currency.unwrap(poolKey.currency1)).safeTransfer(recipient, amount1);
            }

            // Call recipient's callback
            IFlashLoanReceiver(recipient).uniswapV4FlashCallback(
                amount0,
                amount1,
                fee0,
                fee1,
                userData
            );

            // Verify repayment with fees
            if (amount0 > 0) {
                uint256 balance = IERC20(Currency.unwrap(poolKey.currency0)).balanceOf(address(this));
                if (balance < amount0 + fee0) revert InsufficientFlashLoanFee();
                IERC20(Currency.unwrap(poolKey.currency0)).safeTransfer(address(poolManager), amount0 + fee0);
            }
            if (amount1 > 0) {
                uint256 balance = IERC20(Currency.unwrap(poolKey.currency1)).balanceOf(address(this));
                if (balance < amount1 + fee1) revert InsufficientFlashLoanFee();
                IERC20(Currency.unwrap(poolKey.currency1)).safeTransfer(address(poolManager), amount1 + fee1);
            }

            return abi.encode(true);
        } else {
            // This is a liquidity or swap operation
            (address sender, address recipient, BalanceDelta delta) = 
                abi.decode(operationData, (address, address, BalanceDelta));

            int128 amount0Delta = delta.amount0();
            int128 amount1Delta = delta.amount1();

            // Handle token transfers using flash accounting pattern
            if (amount0Delta > 0) {
                // We need to send tokens to the pool
                IERC20(Currency.unwrap(poolKey.currency0)).safeTransfer(address(poolManager), uint128(amount0Delta));
            } else if (amount0Delta < 0) {
                // We receive tokens from the pool
                IERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(
                    address(poolManager),
                    recipient,
                    uint128(-amount0Delta)
                );
            }

            if (amount1Delta > 0) {
                // We need to send tokens to the pool
                IERC20(Currency.unwrap(poolKey.currency1)).safeTransfer(address(poolManager), uint128(amount1Delta));
            } else if (amount1Delta < 0) {
                // We receive tokens from the pool
                IERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(
                    address(poolManager),
                    recipient,
                    uint128(-amount1Delta)
                );
            }

            return abi.encode(true);
        }
    }

    /**
     * @dev Calculate liquidity amount from token amounts and tick range
     */
    function _calculateLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (uint128) {
        // Get current sqrt price
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
        
        // Convert ticks to sqrt prices
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtRatioAtTick(tickUpper);
        
        // Calculate liquidity based on current price and amounts
        uint128 liquidity;
        if (sqrtPriceX96 <= sqrtPriceLowerX96) {
            // Current price is below range, only token0 is used
            liquidity = LiquidityAmounts.getLiquidityForAmount0(
                sqrtPriceLowerX96,
                sqrtPriceUpperX96,
                uint256(amount0)
            );
        } else if (sqrtPriceX96 >= sqrtPriceUpperX96) {
            // Current price is above range, only token1 is used
            liquidity = LiquidityAmounts.getLiquidityForAmount1(
                sqrtPriceLowerX96,
                sqrtPriceUpperX96,
                uint256(amount1)
            );
        } else {
            // Current price is within range, both tokens are used
            uint128 liquidity0 = LiquidityAmounts.getLiquidityForAmount0(
                sqrtPriceX96,
                sqrtPriceUpperX96,
                uint256(amount0)
            );
            uint128 liquidity1 = LiquidityAmounts.getLiquidityForAmount1(
                sqrtPriceLowerX96,
                sqrtPriceX96,
                uint256(amount1)
            );
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        }
        
        return liquidity;
    }

    // ============ TWAP Functions ============
    /**
     * @notice Record a TWAP observation for the pool
     */
    function recordTWAPObservation() public {
        if (!poolInitialized) return;

        (uint160 sqrtPriceX96, int24 tick, , ) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);

        twapObservations[poolId].push(TWAPObservation({
            blockTimestamp: uint32(block.timestamp),
            sqrtPriceX96: sqrtPriceX96,
            liquidity: liquidity
        }));

        uint256 price = calculatePriceFromSqrtPriceX96(sqrtPriceX96);
        if (
            lastTWAPPrice == 0 || 
            block.timestamp > lastTWAPUpdate + TWAP_UPDATE_COOLDOWN ||
            isValidPriceChange(lastTWAPPrice, price)
        ) {
            lastTWAPPrice = price;
            lastTWAPUpdate = block.timestamp;
            emit TWAPPriceUpdated(price);
        }
        
        // Clean up old observations to save gas
        _cleanupOldObservations();
    }
    
    /**
     * @dev Remove observations older than the observation window
     */
    function _cleanupOldObservations() internal {
        TWAPObservation[] storage observations = twapObservations[poolId];
        if (observations.length <= 2) return; // Keep at least 2 observations
        
        uint32 cutoffTime = uint32(block.timestamp) - twapObservationWindow;
        uint256 i = 0;
        
        // Find the first observation that's newer than the cutoff
        while (i < observations.length && observations[i].blockTimestamp < cutoffTime) {
            i++;
        }
        
        // If we found observations to remove and it's not all of them
        if (i > 0 && i < observations.length - 1) {
            // Keep one observation before the cutoff for interpolation
            if (i > 1) i--;
            
            // Remove old observations
            uint256 newLength = observations.length - i;
            for (uint256 j = 0; j < newLength; j++) {
                observations[j] = observations[j + i];
            }
            
            // Resize the array
            for (uint256 j = 0; j < i; j++) {
                observations.pop();
            }
        }
    }

    /**
     * @notice Get TWAP price over a specified period
     * @param period Period in seconds
     * @return price TWAP price with 18 decimals
     */
    function getTWAPPrice(uint32 period) public view returns (uint256) {
        if (!poolInitialized || twapObservations[poolId].length < 2) return lastTWAPPrice;

        uint32 targetTime = uint32(block.timestamp) - (period < MIN_TWAP_PERIOD ? MIN_TWAP_PERIOD : period);
        TWAPObservation[] storage observations = twapObservations[poolId];

        uint256 beforeIndex = 0;
        uint256 afterIndex = observations.length - 1;

        // Binary search for observations around target time
        uint256 low = 0;
        uint256 high = observations.length - 1;
        
        while (low <= high) {
            uint256 mid = (low + high) / 2;
            if (observations[mid].blockTimestamp < targetTime) {
                beforeIndex = mid;
                low = mid + 1;
            } else {
                afterIndex = mid;
                if (mid == 0) break;
                high = mid - 1;
            }
        }

        TWAPObservation memory beforeObs = observations[beforeIndex];
        TWAPObservation memory afterObs = observations[afterIndex];

        if (beforeObs.blockTimestamp == afterObs.blockTimestamp) {
            return calculatePriceFromSqrtPriceX96(afterObs.sqrtPriceX96);
        }

        // Interpolate price based on time weights
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
                (uint256(beforeObs.sqrtPriceX96) * beforeWeight + uint256(afterObs.sqrtPriceX96) * afterWeight) / 1e18
            );
        }

        return calculatePriceFromSqrtPriceX96(weightedSqrtPriceX96);
    }

    /**
     * @dev Calculate price from sqrtPriceX96
     */
    function calculatePriceFromSqrtPriceX96(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        return FullMath.mulDiv(priceX192, 1e18, 1 << 192); // Adjust for 18 decimals
    }

    /**
     * @dev Check if price change is valid based on deviation threshold
     */
    function isValidPriceChange(uint256 oldPrice, uint256 newPrice) internal view returns (bool) {
        if (oldPrice == 0) return true;

        uint256 percentChange = oldPrice > newPrice
            ? ((oldPrice - newPrice) * 10000) / oldPrice
            : ((newPrice - oldPrice) * 10000) / oldPrice;

        return percentChange <= twapDeviationThreshold;
    }

    // ============ Tax & Tokenomics ============
    /**
     * @notice Get tax information for different transaction types
     * @return buyTaxInfo Buy tax information
     * @return sellTaxInfo Sell tax information
     * @return transferTaxInfo Transfer tax information
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

        return (buyTaxInfo, sellTaxInfo, transferTaxInfo);
    }

    /**
     * @notice Set tax exemption status for multiple accounts
     * @param accounts Array of account addresses
     * @param exempt Whether accounts should be exempt from tax
     */
    function setTaxExemptBatch(address[] calldata accounts, bool exempt) external onlyRole(ADMIN_ROLE) {
        for (uint256 i = 0; i < accounts.length; i++) {
            require(accounts[i] != address(0), "Invalid address");
            isExemptFromTax[accounts[i]] = exempt;
        }
    }

    /**
     * @notice Dynamically adjust tax rates based on market conditions
     * @param marketVolatility Volatility metric (0-100)
     * @param marketVolume Trading volume in token units
     */
    function adjustTaxBasedOnMarket(uint256 marketVolatility, uint256 marketVolume) external onlyRole(PRICE_ORACLE_ROLE) {
        require(marketVolatility <= 100, "Invalid volatility value");

        if (marketVolatility > 80) {
            sellTax = Math.min(sellTax + 1, maxSellTax);
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
     * @dev Calculate tax amount based on transaction type and participants
     */
    function _calculateTax(
        address sender,
        address recipient,
        uint256 amount,
        string memory taxType
    ) internal view returns (uint256 taxAmount) {
        if (isExemptFromTax[sender] || isExemptFromTax[recipient] || !taxesEnabled) return 0;

        uint256 taxRate;
        if (keccak256(abi.encodePacked(taxType)) == keccak256("buy")) {
            taxRate = buyTax;
        } else if (keccak256(abi.encodePacked(taxType)) == keccak256("sell")) {
            taxRate = sellTax;
        } else {
            taxRate = transferTax;
        }

        return (amount * taxRate) / 100;
    }
    // ============ Token Economics ============
    /**
     * @notice Adjust sell tax based on neural network weights
     * @param sellWeight Sell weight from neural network (0-100)
     */
    function adjustSellTax(uint256 sellWeight) external {
        require(msg.sender == address(poolManager) || hasRole(NEURAL_INDEXER_ROLE, msg.sender), "Unauthorized");
        require(sellWeight <= 100, "Invalid weight");
        
        uint256 newSellTax = sellTax;
        
        if (sellWeight > 70) {
            // High sell pressure predicted, increase tax
            newSellTax = Math.min(sellTax + ((sellWeight - 70) / 10) + 1, maxSellTax);
        } else if (sellWeight < 30) {
            // Low sell pressure predicted, decrease tax
            newSellTax = sellTax > ((30 - sellWeight) / 10) + 1 ? 
                         sellTax - ((30 - sellWeight) / 10) - 1 : 1;
        }
        
        if (newSellTax != sellTax) {
            sellTax = newSellTax;
            emit TaxUpdated("sell", sellTax);
        }
    }

    /**
     * @notice Execute buyback using collected fees
     * @param amount Amount of USDC to use for buyback
     * @return tokensReceived Amount of tokens bought back
     */
    function executeBuyback(uint256 amount) external onlyRole(GOVERNANCE_ROLE) returns (uint256 tokensReceived) {
        require(amount <= buybackBudget, "Insufficient budget");
        require(poolInitialized, "Pool not initialized");
        
        // Determine which token is USDC
        address usdcTokenAddress = Currency.unwrap(usdcCurrency);
        bool zeroForOne = usdcTokenAddress == Currency.unwrap(poolKey.currency0);
        
        // Approve USDC to pool manager
        IERC20(usdcTokenAddress).approve(address(poolManager), amount);
        
        // Set up swap parameters
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(amount),
            sqrtPriceLimitX96: zeroForOne ? 
                TickMath.MIN_SQRT_PRICE + 1 : 
                TickMath.MAX_SQRT_PRICE - 1
        });
        
        // Execute swap with flash accounting
        bytes memory hookData = abi.encode(address(this), treasuryAddress);
        BalanceDelta delta = poolManager.swap(poolKey, params, hookData);
        
        // Calculate tokens received
        tokensReceived = zeroForOne ? 
            uint256(-delta.amount1()) : 
            uint256(-delta.amount0());
        
        // Update buyback statistics
        buybackBudget -= amount;
        buybackStatistics.totalTokensBought += tokensReceived;
        buybackStatistics.totalUSDCSpent += amount;
        buybackStatistics.lastBuybackTime = block.timestamp;
        buybackStatistics.buybackCount++;
        
        emit BuybackExecuted(amount, tokensReceived);
        
        // Burn a portion of bought back tokens
        uint256 burnAmount = (tokensReceived * burnRateBasisPoints) / 10000;
        if (burnAmount > 0) {
            _burn(address(this), burnAmount);
        }
        
        return tokensReceived;
    }

    /**
     * @notice Mint new tokens with halving mechanism
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        require(to != address(0), "Invalid recipient");
        
        // Apply halving if enabled
        if (applyHalvingToMint) {
            // Check if halving should occur
            uint256 timeSinceLastHalving = block.timestamp - lastHalvingTime;
            if (timeSinceLastHalving >= 180 days) {
                // Calculate how many halvings should occur
                uint256 halvingCount = timeSinceLastHalving / 180 days;
                
                for (uint256 i = 0; i < halvingCount; i++) {
                    emissionRate = (emissionRate * HALVING_RATE) / 100;
                    currentHalvingEpoch++;
                }
                
                lastHalvingTime = block.timestamp;
            }
            
            // Ensure amount doesn't exceed emission rate
            amount = Math.min(amount, emissionRate);
        }
        
        // Ensure total supply doesn't exceed max supply
        uint256 newTotalSupply = totalSupply() + amount;
        require(newTotalSupply <= MAX_SUPPLY, "Exceeds max supply");
        
        _mint(to, amount);
    }

    // ============ Security and Governance ============
    /**
     * @notice Update blacklist status for an account
     * @param account Address to update
     * @param status New blacklist status
     */
    function updateBlacklistStatus(address account, bool status) external onlyRole(ADMIN_ROLE) {
        require(account != address(0), "Invalid address");
        isBlacklisted[account] = status;
        emit BlacklistUpdated(account, status);
    }

    /**
     * @notice Set emergency mode status
     * @param enabled Whether emergency mode should be enabled
     */
    function setEmergencyMode(bool enabled) external onlyRole(EMERGENCY_ROLE) {
        if (enabled && block.timestamp < lastEmergencyActionTime + EMERGENCY_COOLDOWN) {
            revert EmergencyCooldownActive();
        }
        emergencyMode = enabled;
        lastEmergencyActionTime = enabled ? block.timestamp : lastEmergencyActionTime;
        emit EmergencyModeChanged(enabled);
    }

    // ============ Neural Network Functions ============
    /**
     * @notice Update neural network weights
     * @param buyWeight Buy weight (0-100)
     * @param sellWeight Sell weight (0-100)
     * @param holdWeight Hold weight (0-100)
     * @param confidenceScore Confidence score (0-100)
     * @param modelVersion Version identifier of the model
     */
    function updateNeuralWeights(
        uint256 buyWeight,
        uint256 sellWeight,
        uint256 holdWeight,
        uint256 confidenceScore,
        string calldata modelVersion
    ) external onlyRole(NEURAL_INDEXER_ROLE) {
        require(buyWeight + sellWeight + holdWeight == 100, "Weights must sum to 100");
        require(confidenceScore <= 100, "Confidence score must be <= 100");

        currentNeuralWeights = NeuralWeights({
            timestamp: block.timestamp,
            buyWeight: buyWeight,
            sellWeight: sellWeight,
            holdWeight: holdWeight,
            confidenceScore: confidenceScore,
            modelVersion: modelVersion
        });

        // If confidence is high enough, automatically adjust taxes
        if (confidenceScore >= neuralConfidenceThreshold && neuralRecommendationsEnabled) {
            if (sellWeight > 70) {
                adjustSellTax(sellWeight);
            } else if (buyWeight > 70) {
                // High buy pressure predicted, decrease buy tax
                buyTax = buyTax > 1 ? buyTax - 1 : 1;
                emit TaxUpdated("buy", buyTax);
            }
        }

        emit NeuralWeightsUpdated(buyWeight, sellWeight, holdWeight, confidenceScore);
    }

    /**
     * @notice Toggle neural recommendations
     * @param enabled Whether neural recommendations should be enabled
     */
    function toggleNeuralRecommendations(bool enabled) external onlyRole(AI_MANAGER_ROLE) {
        neuralRecommendationsEnabled = enabled;
    }

    /**
     * @notice Set neural confidence threshold
     * @param threshold New threshold (0-100)
     */
    function setNeuralConfidenceThreshold(uint256 threshold) external onlyRole(AI_MANAGER_ROLE) {
        require(threshold <= 100, "Threshold must be <= 100");
        neuralConfidenceThreshold = threshold;
    }

    // ============ Emergency & Recovery ============
    /**
     * @notice Emergency pause all token transfers
     * @param paused Whether to pause transfers
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
     * @notice Recover accidentally sent ERC20 tokens
     * @param tokenAddress Address of the token to recover
     * @param amount Amount to recover (0 for all)
     * @return recovered Amount recovered
     */
    function recoverERC20(address tokenAddress, uint256 amount) external onlyRole(RECOVERY_ROLE) returns (uint256 recovered) {
        require(tokenAddress != address(this), "Cannot recover native token");
        
        IERC20 token = IERC20(tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        uint256 amountToRecover = amount == 0 ? balance : Math.min(amount, balance);
        
        require(amountToRecover > 0, "No tokens to recover");
        require(token.transfer(treasuryAddress, amountToRecover), "Transfer failed");
        
        emit TokenRecovered(tokenAddress, amountToRecover);
        return amountToRecover;
    }

    /**
     * @notice Recover accidentally sent ETH
     * @param amount Amount to recover (0 for all)
     * @return recovered Amount recovered
     */
    function recoverETH(uint256 amount) external onlyRole(RECOVERY_ROLE) returns (uint256 recovered) {
        uint256 balance = address(this).balance;
        uint256 amountToRecover = amount == 0 ? balance : Math.min(amount, balance);
        
        require(amountToRecover > 0, "No ETH to recover");
        
        (bool success, ) = treasuryAddress.call{value: amountToRecover}("");
        require(success, "ETH recovery failed");
        
        emit ETHRecovered(amountToRecover);
        return amountToRecover;
    }

    /**
     * @notice Emergency function to disable specific contract features
     * @param feature Feature identifier (1: taxes, 2: neural, 3: crosschain)
     * @param enabled Whether the feature should be enabled
     */
    function setFeatureStatus(uint256 feature, bool enabled) external onlyRole(EMERGENCY_ROLE) {
        if (feature == 1) {
            // Taxes
            taxesEnabled = enabled;
        } else if (feature == 2) {
            // Neural network
            neuralRecommendationsEnabled = enabled;
        } else if (feature == 3) {
            // Cross-chain
            crossChainEnabled = enabled;
        }
        
        emit FeatureStatusChanged(feature, enabled);
    }
    // ============ Upgradeability ============
    /**
     * @notice Authorize contract upgrade
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        require(newImplementation != address(0), "Invalid implementation");
    }

    // ============ Getters ============
    /**
     * @notice Get current neural weights
     * @return buyWeight Buy weight
     * @return sellWeight Sell weight
     * @return holdWeight Hold weight
     * @return confidenceScore Confidence score
     * @return modelVersion Model version
     */
    function getNeuralWeights() external view returns (
        uint256 buyWeight,
        uint256 sellWeight,
        uint256 holdWeight,
        uint256 confidenceScore,
        string memory modelVersion
    ) {
        NeuralWeights memory weights = currentNeuralWeights;
        return (weights.buyWeight, weights.sellWeight, weights.holdWeight, weights.confidenceScore, weights.modelVersion);
    }

    /**
     * @notice Get buyback statistics
     * @return stats Buyback statistics
     */
    function getBuybackStats() external view returns (BuybackStats memory) {
        return buybackStatistics;
    }

    /**
     * @notice Get current halving epoch
     * @return epoch Current halving epoch
     */
    function getCurrentHalvingEpoch() external view returns (uint256) {
        return currentHalvingEpoch;
    }

    /**
     * @notice Get last halving time
     * @return timestamp Last halving time
     */
    function getLastHalvingTime() external view returns (uint256) {
        return lastHalvingTime;
    }

    /**
     * @notice Get pool information
     * @return initialized Whether pool is initialized
     * @return id Pool ID
     * @return token0 Address of token0
     * @return token1 Address of token1
     * @return fee Pool fee
     */
    function getPoolInfo() external view returns (
        bool initialized,
        bytes32 id,
        address token0,
        address token1,
        uint24 fee
    ) {
        return (
            poolInitialized,
            poolId,
            Currency.unwrap(poolKey.currency0),
            Currency.unwrap(poolKey.currency1),
            poolKey.fee
        );
    }

    /**
     * @notice Get position information
     * @param positionId Position ID
     * @return position Position details
     */
    function getPosition(uint256 positionId) external view returns (PoolPosition memory) {
        return positions[positionId];
    }

    // ============ Override Functions ============
    /**
     * @dev Override _beforeTokenTransfer to implement blacklist and emergency mode checks
     * @param from Sender address
     * @param to Recipient address
     * @param amount Transfer amount
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override whenNotPaused {
        require(!isBlacklisted[from] && !isBlacklisted[to], "Address is blacklisted");
        require(!emergencyMode || hasRole(EMERGENCY_ROLE, msg.sender), "Emergency mode: transfers restricted");
        super._beforeTokenTransfer(from, to, amount);
    }

    /**
     * @dev Override transfer function to apply taxes if enabled
     * @param to Recipient address
     * @param amount Transfer amount
     * @return success Whether transfer succeeded
     */
    function transfer(address to, uint256 amount) public override returns (bool) {
        if (taxesEnabled && !isExemptFromTax[msg.sender] && !isExemptFromTax[to]) {
            uint256 taxAmount = _calculateTax(msg.sender, to, amount, "transfer");
            if (taxAmount > 0) {
                uint256 amountAfterTax = amount - taxAmount;
                super.transfer(treasuryAddress, taxAmount);
                return super.transfer(to, amountAfterTax);
            }
        }
        return super.transfer(to, amount);
    }

    /**
     * @dev Override transferFrom function to apply taxes if enabled
     * @param from Sender address
     * @param to Recipient address
     * @param amount Transfer amount
     * @return success Whether transfer succeeded
     */
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (taxesEnabled && !isExemptFromTax[from] && !isExemptFromTax[to]) {
            uint256 taxAmount = _calculateTax(from, to, amount, "transfer");
            if (taxAmount > 0) {
                uint256 amountAfterTax = amount - taxAmount;
                super.transferFrom(from, treasuryAddress, taxAmount);
                return super.transferFrom(from, to, amountAfterTax);
            }
        }
        return super.transferFrom(from, to, amount);
    }

    /**
     * @notice Set treasury address
     * @param _treasuryAddress New treasury address
     */
    function setTreasuryAddress(address _treasuryAddress) external onlyRole(ADMIN_ROLE) {
        require(_treasuryAddress != address(0), "Invalid treasury address");
        treasuryAddress = _treasuryAddress;
    }

    /**
     * @notice Set tax rates
     * @param _buyTax Buy tax rate
     * @param _sellTax Sell tax rate
     * @param _transferTax Transfer tax rate
     * @param _maxSellTax Maximum sell tax rate
     */
    function setTaxRates(
        uint256 _buyTax,
        uint256 _sellTax,
        uint256 _transferTax,
        uint256 _maxSellTax
    ) external onlyRole(ADMIN_ROLE) {
        require(_buyTax <= MAX_TAX_BASIS_POINTS / 100, "Buy tax too high");
        require(_sellTax <= MAX_TAX_BASIS_POINTS / 100, "Sell tax too high");
        require(_transferTax <= MAX_TAX_BASIS_POINTS / 100, "Transfer tax too high");
        require(_maxSellTax <= MAX_TAX_BASIS_POINTS / 100, "Max sell tax too high");
        
        buyTax = _buyTax;
        sellTax = _sellTax;
        transferTax = _transferTax;
        maxSellTax = _maxSellTax;
        
        emit TaxUpdated("buy", buyTax);
        emit TaxUpdated("sell", sellTax);
        emit TaxUpdated("transfer", transferTax);
    }

    /**
     * @notice Set tax allocations
     * @param taxType Tax type (1: buy, 2: sell, 3: transfer)
     * @param liquidity Liquidity allocation percentage
     * @param treasury Treasury allocation percentage
     * @param staking Staking allocation percentage
     * @param buyback Buyback allocation percentage
     */
    function setTaxAllocations(
        uint8 taxType,
        uint256 liquidity,
        uint256 treasury,
        uint256 staking,
        uint256 buyback
    ) external onlyRole(ADMIN_ROLE) {
        require(liquidity + treasury + staking + buyback == 100, "Must sum to 100");
        
        TaxAllocation memory allocation = TaxAllocation({
            liquidity: liquidity,
            treasury: treasury,
            staking: staking,
            buyback: buyback
        });
        
        if (taxType == 1) {
            buyTaxAllocation = allocation;
        } else if (taxType == 2) {
            sellTaxAllocation = allocation;
        } else if (taxType == 3) {
            transferTaxAllocation = allocation;
        } else {
            revert("Invalid tax type");
        }
    }

    /**
     * @notice Set TWAP deviation threshold
     * @param threshold New threshold in basis points
     */
    function setTWAPDeviationThreshold(uint256 threshold) external onlyRole(ADMIN_ROLE) {
        require(threshold <= 10000, "Threshold too high");
        twapDeviationThreshold = threshold;
    }

    /**
     * @notice Set TWAP observation window
     * @param window New window in seconds
     */
    function setTWAPObservationWindow(uint32 window) external onlyRole(ADMIN_ROLE) {
        require(window >= 1 hours && window <= 7 days, "Invalid window");
        twapObservationWindow = window;
    }

    /**
     * @notice Set max gas price for transactions
     * @param _maxGasPrice New max gas price
     */
    function setMaxGasPrice(uint256 _maxGasPrice) external onlyRole(ADMIN_ROLE) {
        maxGasPrice = _maxGasPrice;
    }

    /**
     * @notice Set halving parameters
     * @param _applyHalvingToMint Whether to apply halving to mint
     * @param _emissionRate New emission rate
     */
    function setHalvingParameters(bool _applyHalvingToMint, uint256 _emissionRate) external onlyRole(ADMIN_ROLE) {
        applyHalvingToMint = _applyHalvingToMint;
        if (_emissionRate > 0) {
            emissionRate = _emissionRate;
        }
    }

    /**
     * @dev Function to receive ETH
     */
    receive() external payable {}
}

/**
 * @title IFlashLoanReceiver
 * @notice Interface for flash loan receivers
 */
interface IFlashLoanReceiver {
    function uniswapV4FlashCallback(
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external;
}

/**
 * @title LiquidityAmounts
 * @notice Helper library for calculating liquidity amounts
 */
library LiquidityAmounts {
    /**
     * @notice Calculate liquidity for amount0
     * @param sqrtPriceAX96 Lower sqrt price
     * @param sqrtPriceBX96 Upper sqrt price
     * @param amount0 Amount of token0
     * @return liquidity Calculated liquidity
     */
    function getLiquidityForAmount0(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0
    ) internal pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        uint256 intermediate = FullMath.mulDiv(sqrtPriceAX96, sqrtPriceBX96, 1 << 96);
        return uint128(FullMath.mulDiv(amount0, intermediate, sqrtPriceBX96 - sqrtPriceAX96));
    }

    /**
     * @notice Calculate liquidity for amount1
     * @param sqrtPriceAX96 Lower sqrt price
     * @param sqrtPriceBX96 Upper sqrt price
     * @param amount1 Amount of token1
     * @return liquidity Calculated liquidity
     */
    function getLiquidityForAmount1(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        return uint128(FullMath.mulDiv(amount1, 1 << 96, sqrtPriceBX96 - sqrtPriceAX96));
    }
}                                