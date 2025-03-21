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
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import "../interfaces/ITerraStakeRewardDistributor.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";
import "../interfaces/ITerraStakeSlashing.sol";
import "../interfaces/ITerraStakeTreasuryManager.sol";

/**
 * @title TerraStakeLiquidityGuard
 * @notice Manages liquidity for the TerraStake protocol on Uniswap V3 with anti-whale mechanisms, TWAP protection, and emergency controls.
 * @dev Optimized for Arbitrum deployment. Uses Chainlink VRF for randomness and Uniswap V3 for liquidity provision.
 */
contract TerraStakeLiquidityGuard is
    Initializable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    VRFConsumerBaseV2
{
    using SafeERC20 for IERC20;

    // Core State Variables
    /// @notice The TerraStake treasury manager contract
    ITerraStakeTreasuryManager public treasuryManager;
    /// @notice The TerraStake reward distributor contract
    ITerraStakeRewardDistributor public rewardDistributor;
    /// @notice The Uniswap V3 swap router
    ISwapRouter public swapRouter;
    /// @notice The Chainlink VRF coordinator
    VRFCoordinatorV2Interface public vrfCoordinator;
    /// @notice The TerraStake token (tStake)
    ERC20Upgradeable public tStakeToken;
    /// @notice The USDC token
    ERC20Upgradeable public usdcToken;
    /// @notice The Uniswap V3 position manager
    INonfungiblePositionManager public positionManager;
    /// @notice The Uniswap V3 pool for tStake/USDC
    IUniswapV3Pool public uniswapPool;
    /// @notice Amount of tStake tokens in the contract
    uint256 public tStakeAmount;
    /// @notice Amount of USDC tokens in the contract
    uint256 public usdcAmount;
    /// @notice Total liquidity injected into Uniswap V3
    uint256 public totalLiquidityInjected;
    /// @notice Timestamp of the last liquidity injection
    uint256 public lastLiquidityInjectionTime;

    // Chainlink VRF configuration
    /// @notice Chainlink VRF subscription ID
    uint64 public vrfSubscriptionId;
    /// @notice Chainlink VRF key hash
    bytes32 public vrfKeyHash;
    /// @notice Chainlink VRF callback gas limit
    uint32 public vrfCallbackGasLimit = 100000;
    /// @notice Chainlink VRF request confirmations
    uint16 public vrfRequestConfirmations = 3;

    // Roles
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant TREASURY_MANAGER_ROLE = keccak256("TREASURY_MANAGER_ROLE");
    bytes32 public constant REWARD_DISTRIBUTOR_ROLE = keccak256("REWARD_DISTRIBUTOR_ROLE");

    // Constants
    uint256 public constant ONE_DAY = 1 days;
    uint256 public constant ONE_WEEK = 7 days;
    uint256 public constant PERCENTAGE_DENOMINATOR = 100;
    uint256 public constant DEFAULT_SLIPPAGE_TOLERANCE = 50; // 0.5%
    uint24 public constant DEFAULT_POOL_FEE = 3000; // 0.3%
    uint256 public constant MAX_FEE_PERCENTAGE = 50;
    uint256 public constant MAX_ACTIVE_POSITIONS = 1000;
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = -MIN_TICK;

    // Errors
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

    // Events
    event LiquidityDeposited(address indexed user, uint256 amount0, uint256 amount1);
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
    event TWAPTimeframesUpdated(uint256[] newTimeframes);
    event RandomLiquidityAdjustment(uint256 tokenId, uint256 adjustment);
    event CircuitBreakerTriggered(address triggerer);
    event CircuitBreakerReset(address resetter);

    // Anti-whale mechanism parameters
    /// @notice Daily withdrawal limit as a percentage (e.g., 5 = 5%)
    uint256 public dailyWithdrawalLimit;
    /// @notice Weekly withdrawal limit as a percentage (e.g., 25 = 25%)
    uint256 public weeklyWithdrawalLimit;
    /// @notice Vesting unlock rate per week as a percentage (e.g., 10 = 10% per week)
    uint256 public vestingUnlockRate;
    /// @notice Base fee percentage for withdrawals (e.g., 2 = 2%)
    uint256 public baseFeePercentage;
    /// @notice Additional fee percentage for large withdrawals (e.g., 8 = 8%)
    uint256 public largeLiquidityFeeIncrease;
    /// @notice Cooldown period for liquidity removal in seconds
    uint256 public liquidityRemovalCooldown;
    /// @notice Maximum liquidity per address (0 = unlimited)
    uint256 public maxLiquidityPerAddress;

    // Liquidity management parameters
    /// @notice Minimum amount for reinvesting rewards
    uint256 public reinjectionThreshold;
    /// @notice Percentage of rewards to auto-reinvest (e.g., 5 = 5%)
    uint256 public autoLiquidityInjectionRate;
    /// @notice Slippage tolerance in basis points (e.g., 50 = 0.5%)
    uint256 public slippageTolerance;

    // Configurable tick range
    /// @notice Multiplier for tick range in Uniswap V3 positions
    int24 public tickRangeMultiplier = 10;

    // User data mappings
    /// @notice tStakeToken liquidity per user
    mapping(address => uint256) public userLiquidity;
    /// @notice USDC liquidity per user
    mapping(address => uint256) public userLiquidityUSDC;
    /// @notice Vesting start timestamp per user
    mapping(address => uint256) public userVestingStart;
    /// @notice Daily withdrawal amount per user
    mapping(address => uint256) public dailyWithdrawalAmount;
    /// @notice Last daily withdrawal timestamp per user
    mapping(address => uint256) public lastDailyWithdrawal;
    /// @notice Weekly withdrawal amount per user
    mapping(address => uint256) public weeklyWithdrawalAmount;
    /// @notice Last weekly withdrawal timestamp per user
    mapping(address => uint256) public lastWeeklyWithdrawal;
    /// @notice Last liquidity removal timestamp per user
    mapping(address => uint256) public lastLiquidityRemoval;
    /// @notice Whitelist status for fee exemptions per user
    mapping(address => bool) public liquidityWhitelist;

    // Position tracking
    /// @notice Array of active Uniswap V3 position IDs
    uint256[] public activePositions;
    /// @notice Whether a position is active
    mapping(uint256 => bool) public isPositionActive;
    /// @notice Index of each position in the activePositions array
    mapping(uint256 => uint256) public positionIndex;

    // TWAP price protection
    /// @notice Array of TWAP observation timeframes in seconds
    uint256[] public twapObservationTimeframes;
    /// @notice Maximum allowed deviation for TWAP price as a percentage
    uint256 public twapDeviationPercentage;
    /// @notice Last calculated TWAP price
    uint256 public lastTWAP;
    /// @notice Timestamp of the last TWAP update
    uint256 public lastTWAPUpdate;

    // Analytics and statistics
    /// @notice Total fees collected from withdrawals
    uint256 public totalFeesCollected;
    /// @notice Total number of withdrawals
    uint256 public totalWithdrawalCount;
    /// @notice Number of large withdrawals
    uint256 public largeWithdrawalCount;

    // Emergency controls
    /// @notice Whether emergency mode is active
    bool public emergencyMode;
    /// @notice Whether the circuit breaker is triggered
    bool public circuitBreakerTriggered;

    // Approval tracking for gas optimization
    /// @notice Current approval amount for tStakeToken to positionManager
    uint256 public tStakeTokenApproval;
    /// @notice Current approval amount for usdcToken to positionManager
    uint256 public usdcTokenApproval;

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
     * @param _vrfSubscriptionId Chainlink VRF subscription ID
     * @param _vrfKeyHash Chainlink VRF key hash
     */
    function initialize(
        address _tStakeToken,
        address _usdcToken,
        address _positionManager,
        address _uniswapPool,
        address _rewardDistributor,
        address _treasuryManager,
        uint256 _reinjectionThreshold,
        address _admin,
        uint64 _vrfSubscriptionId,
        bytes32 _vrfKeyHash
    ) external initializer {
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        if (_tStakeToken == address(0)) revert InvalidZeroAddress("tStakeToken");
        if (_usdcToken == address(0)) revert InvalidZeroAddress("usdcToken");
        if (_positionManager == address(0)) revert InvalidZeroAddress("positionManager");
        if (_uniswapPool == address(0)) revert InvalidZeroAddress("uniswapPool");
        if (_rewardDistributor == address(0)) revert InvalidZeroAddress("rewardDistributor");
        if (_treasuryManager == address(0)) revert InvalidZeroAddress("treasuryManager");
        if (_admin == address(0)) revert InvalidZeroAddress("admin");

        tStakeToken = ERC20Upgradeable(_tStakeToken);
        usdcToken = ERC20Upgradeable(_usdcToken);
        positionManager = INonfungiblePositionManager(_positionManager);
        uniswapPool = IUniswapV3Pool(_uniswapPool);
        rewardDistributor = ITerraStakeRewardDistributor(_rewardDistributor);
        treasuryManager = ITerraStakeTreasuryManager(_treasuryManager);

        dailyWithdrawalLimit = 5;
        weeklyWithdrawalLimit = 25;
        vestingUnlockRate = 10;
        baseFeePercentage = 2;
        largeLiquidityFeeIncrease = 8;
        liquidityRemovalCooldown = 7 days;

        reinjectionThreshold = (_reinjectionThreshold != 0) ? _reinjectionThreshold : 1e18;
        autoLiquidityInjectionRate = 5;
        slippageTolerance = DEFAULT_SLIPPAGE_TOLERANCE;

        twapObservationTimeframes = [30 minutes, 1 hours, 4 hours, 24 hours];

        vrfCoordinator = VRFCoordinatorV2Interface(0x41034678D6C633D8a95c75e1138A360a28bA15d1); // Arbitrum One
        vrfSubscriptionId = _vrfSubscriptionId;
        vrfKeyHash = _vrfKeyHash;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(GOVERNANCE_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
        _grantRole(TREASURY_MANAGER_ROLE, _treasuryManager);
        _grantRole(REWARD_DISTRIBUTOR_ROLE, _rewardDistributor);
    }

    /**
     * @notice Add liquidity to the protocol
     * @param amount0 Amount of tStake tokens to add
     * @param amount1 Amount of USDC tokens to add
     */
    function addLiquidity(uint256 amount0, uint256 amount1) external nonReentrant {
        if (emergencyMode) revert EmergencyModeActive();
        if (circuitBreakerTriggered) revert OperationFailed("Circuit breaker triggered");
        if (amount0 == 0 || amount1 == 0) revert InvalidParameter("amount", 0);
        if (activePositions.length >= MAX_ACTIVE_POSITIONS) revert OperationFailed("Max active positions reached");

        if (maxLiquidityPerAddress > 0) {
            if (userLiquidity[msg.sender] + amount0 > maxLiquidityPerAddress) {
                revert InvalidParameter("amount0", amount0);
            }
        }

        IERC20 tStake = IERC20(address(tStakeToken));
        IERC20 usdc = IERC20(address(usdcToken));

        tStake.safeTransferFrom(msg.sender, address(this), amount0);
        usdc.safeTransferFrom(msg.sender, address(this), amount1);

        if (tStakeTokenApproval < amount0) {
            tStake.approve(address(positionManager), type(uint256).max);
            tStakeTokenApproval = type(uint256).max;
        }
        if (usdcTokenApproval < amount1) {
            usdc.approve(address(positionManager), type(uint256).max);
            usdcTokenApproval = type(uint256).max;
        }

        (, int24 currentTick, , , , , ) = uniswapPool.slot0();
        int24 tickSpacing = uniswapPool.tickSpacing();
        int24 multiplier = tickRangeMultiplier;
        int24 tickLower = currentTick - (multiplier * tickSpacing);
        int24 tickUpper = currentTick + (multiplier * tickSpacing);

        tickLower = tickLower - (tickLower % tickSpacing);
        tickUpper = tickUpper - (tickUpper % tickSpacing);

        uint256 slippage = slippageTolerance;
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(tStakeToken),
            token1: address(usdcToken),
            fee: DEFAULT_POOL_FEE,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: amount0 * (10000 - slippage) / 10000,
            amount1Min: amount1 * (10000 - slippage) / 10000,
            recipient: address(this),
            deadline: block.timestamp + 15 minutes
        });

        (uint256 newTokenId, uint128 newLiquidity, uint256 amount0Used, uint256 amount1Used) = positionManager.mint(params);

        if (!isPositionActive[newTokenId]) {
            positionIndex[newTokenId] = activePositions.length;
            activePositions.push(newTokenId);
            isPositionActive[newTokenId] = true;
        }

        if (userVestingStart[msg.sender] == 0) {
            userVestingStart[msg.sender] = block.timestamp;
        }

        userLiquidity[msg.sender] += amount0Used;
        userLiquidityUSDC[msg.sender] += amount1Used;

        totalLiquidityInjected += amount0Used + amount1Used;
        lastLiquidityInjectionTime = block.timestamp;

        emit LiquidityDeposited(msg.sender, amount0Used, amount1Used);
    }

    /**
     * @notice Triggers the circuit breaker, pausing critical operations
     * @dev Restricted to EMERGENCY_ROLE
     */
    function triggerCircuitBreaker() external onlyRole(EMERGENCY_ROLE) {
        if (circuitBreakerTriggered) revert OperationFailed("Circuit breaker already triggered");
        circuitBreakerTriggered = true;
        emit CircuitBreakerTriggered(msg.sender);
    }

    /**
     * @notice Resets the circuit breaker, allowing operations to resume
     * @dev Restricted to EMERGENCY_ROLE
     */
    function resetCircuitBreaker() external onlyRole(EMERGENCY_ROLE) {
        if (!circuitBreakerTriggered) revert OperationFailed("Circuit breaker not triggered");
        circuitBreakerTriggered = false;
        emit CircuitBreakerReset(msg.sender);
    }

    /**
     * @notice Returns the current liquidity settings
     * @return _dailyWithdrawalLimit Daily withdrawal limit percentage
     * @return _weeklyWithdrawalLimit Weekly withdrawal limit percentage
     * @return _vestingUnlockRate Vesting unlock rate percentage per week
     * @return _baseFeePercentage Base fee percentage for withdrawals
     * @return _largeLiquidityFeeIncrease Additional fee percentage for large withdrawals
     * @return _liquidityRemovalCooldown Cooldown period for liquidity removal in seconds
     * @return _maxLiquidityPerAddress Maximum liquidity per address (0 = unlimited)
     * @return _reinjectionThreshold Minimum amount for reinvesting rewards
     * @return _autoLiquidityInjectionRate Percentage of rewards to auto-reinvest
     * @return _slippageTolerance Slippage tolerance in basis points
     */
    function getLiquiditySettings() external view returns (
        uint256 _dailyWithdrawalLimit,
        uint256 _weeklyWithdrawalLimit,
        uint256 _vestingUnlockRate,
        uint256 _baseFeePercentage,
        uint256 _largeLiquidityFeeIncrease,
        uint256 _liquidityRemovalCooldown,
        uint256 _maxLiquidityPerAddress,
        uint256 _reinjectionThreshold,
        uint256 _autoLiquidityInjectionRate,
        uint256 _slippageTolerance
    ) {
        return (
            dailyWithdrawalLimit,
            weeklyWithdrawalLimit,
            vestingUnlockRate,
            baseFeePercentage,
            largeLiquidityFeeIncrease,
            liquidityRemovalCooldown,
            maxLiquidityPerAddress,
            reinjectionThreshold,
            autoLiquidityInjectionRate,
            slippageTolerance
        );
    }

    /**
     * @notice Checks if the circuit breaker is triggered
     * @return True if the circuit breaker is triggered, false otherwise
     */
    function isCircuitBreakerTriggered() external view returns (bool) {
        return circuitBreakerTriggered;
    }

    /**
     * @notice Get user-specific data for the UI
     * @param user Address of the user
     * @return liquidity tStakeToken liquidity of the user
     * @return liquidityUSDC USDC liquidity of the user
     * @return vestingStart Vesting start timestamp
     * @return dailyWithdrawn Amount withdrawn today
     * @return weeklyWithdrawn Amount withdrawn this week
     * @return lastRemoval Last liquidity removal timestamp
     * @return isWhitelisted Whether the user is whitelisted
     */
    function getUserData(address user) external view returns (
        uint256 liquidity,
        uint256 liquidityUSDC,
        uint256 vestingStart,
        uint256 dailyWithdrawn,
        uint256 weeklyWithdrawn,
        uint256 lastRemoval,
        bool isWhitelisted
    ) {
        return (
            userLiquidity[user],
            userLiquidityUSDC[user],
            userVestingStart[user],
            dailyWithdrawalAmount[user],
            weeklyWithdrawalAmount[user],
            lastLiquidityRemoval[user],
            liquidityWhitelist[user]
        );
    }

    /**
     * @notice Get the current withdrawal fee for a user and amount
     * @param user Address of the user
     * @param amount Amount to withdraw
     * @return fee The calculated withdrawal fee
     */
    function getUserWithdrawalFee(address user, uint256 amount) external view returns (uint256 fee) {
        return getWithdrawalFee(user, amount);
    }

    /**
     * @notice Validate price impact for a swap/liquidity operation
     * @param amountIn Input amount
     * @param amountOutMin Minimum output amount
     * @param path Token swap path
     * @return valid True if price impact is acceptable
     */
    function validatePriceImpact(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path
    ) public view returns (bool valid) {
        if (amountIn == 0) return false;

        (uint160 sqrtPriceX96,,,,,,) = uniswapPool.slot0();
        uint256 spotPrice = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> (96 * 2);

        uint256 expectedOutput = (amountIn * spotPrice) / (1e18);
        uint256 priceImpact = ((expectedOutput - amountOutMin) * 10000) / expectedOutput;

        return priceImpact <= slippageTolerance;
    }

    /**
     * @notice Inject liquidity into Uniswap position
     * @param amount Amount of tStake tokens to inject
     */
    function injectLiquidity(uint256 amount) external nonReentrant onlyRole(OPERATOR_ROLE) {
        if (emergencyMode) revert EmergencyModeActive();
        if (circuitBreakerTriggered) revert OperationFailed("Circuit breaker triggered");
        if (amount == 0) revert InvalidParameter("amount", amount);
        
        // Get equivalent USDC from TreasuryManager
        if (address(treasuryManager) == address(0)) revert InvalidZeroAddress("treasuryManager");
        
        if (activePositions.length >= MAX_ACTIVE_POSITIONS) revert OperationFailed("Max active positions reached");

        usdcAmount = treasuryManager.withdrawUSDCEquivalent(amount);
        if (usdcAmount == 0) revert InvalidParameter("usdcAmount", usdcAmount);

        IERC20 tStake = IERC20(address(tStakeToken));
        IERC20 usdc = IERC20(address(usdcToken));

        if (tStakeTokenApproval < amount) {
            tStake.approve(address(positionManager), type(uint256).max);
            tStakeTokenApproval = type(uint256).max;
        }
        if (usdcTokenApproval < usdcAmount) {
            usdc.approve(address(positionManager), type(uint256).max);
            usdcTokenApproval = type(uint256).max;
        }

        (, int24 currentTick, , , , , ) = uniswapPool.slot0();
        int24 tickSpacing = uniswapPool.tickSpacing();
        int24 multiplier = tickRangeMultiplier;
        int24 tickLower = currentTick - (multiplier * tickSpacing);
        int24 tickUpper = currentTick + (multiplier * tickSpacing);

        tickLower = tickLower - (tickLower % tickSpacing);
        tickUpper = tickUpper - (tickUpper % tickSpacing);

        uint256 slippage = slippageTolerance;
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(tStakeToken),
            token1: address(usdcToken),
            fee: DEFAULT_POOL_FEE,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount,
            amount1Desired: usdcAmount,
            amount0Min: amount * (10000 - slippage) / 10000,
            amount1Min: usdcAmount * (10000 - slippage) / 10000,
            recipient: address(this),
            deadline: block.timestamp + 15 minutes
        });

        (uint256 newTokenId, uint128 newLiquidity, uint256 amount0, uint256 amount1) = positionManager.mint(params);

        if (!isPositionActive[newTokenId]) {
            positionIndex[newTokenId] = activePositions.length;
            activePositions.push(newTokenId);
            isPositionActive[newTokenId] = true;
        }

        totalLiquidityInjected += amount0 + amount1;
        lastLiquidityInjectionTime = block.timestamp;
        emit LiquidityInjected(amount, usdcAmount, newTokenId, newLiquidity);
    }

    /**
     * @notice Collect fees from a position
     * @param tokenID The ID of the position
     * @return amount0 Amount of token0 collected
     * @return amount1 Amount of token1 collected
     */
    function collectPositionFees(uint256 tokenID) external nonReentrant onlyRole(OPERATOR_ROLE) returns (uint256 amount0, uint256 amount1) {
        if (!isPositionActive[tokenID]) revert PositionNotFound(tokenID);

        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
            tokenId: tokenID,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        (amount0, amount1) = positionManager.collect(params);
        totalFeesCollected += amount0 + amount1;

        emit PositionFeesCollected(tokenID, amount0, amount1);
        return (amount0, amount1);
    }

    /**
     * @notice Decrease liquidity in a position
     * @param tokenID The ID of the position
     * @param liquidity Amount of liquidity to decrease
     * @param amount0Min Minimum amount of token0 to receive
     * @param amount1Min Minimum amount of token1 to receive
     * @return amount0 Amount of token0 received
     * @return amount1 Amount of token1 received
     */
    function decreasePositionLiquidity(
        uint256 tokenID,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min
    ) external nonReentrant onlyRole(OPERATOR_ROLE) returns (uint256 amount0, uint256 amount1) {
        if (!isPositionActive[tokenID]) revert PositionNotFound(tokenID);

        (, , , , , , , uint128 posLiquidity, , , , ) = positionManager.positions(tokenID);
        if (liquidity > posLiquidity) revert InvalidParameter("liquidity", liquidity);

        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager.DecreaseLiquidityParams({
            tokenId: tokenID,
            liquidity: liquidity,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            deadline: block.timestamp + 15 minutes
        });

        (amount0, amount1) = positionManager.decreaseLiquidity(params);

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenID,
            recipient: address(this),
            amount0Max: uint128(amount0),
            amount1Max: uint128(amount1)
        });

        positionManager.collect(collectParams);

        emit PositionLiquidityDecreased(tokenID, liquidity, amount0, amount1);
        return (amount0, amount1);
    }

    /**
     * @notice Close a position completely
     * @param tokenID The ID of the position
     * @return amount0 Amount of token0 received
     * @return amount1 Amount of token1 received
     */
    function closePosition(uint256 tokenID) external nonReentrant onlyRole(OPERATOR_ROLE) returns (uint256 amount0, uint256 amount1) {
        if (!isPositionActive[tokenID]) revert PositionNotFound(tokenID);

        (, , , , , , , uint128 posLiquidity, , , , ) = positionManager.positions(tokenID);

        if (posLiquidity > 0) {
            INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams = INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenID,
                liquidity: posLiquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 15 minutes
            });

            (amount0, amount1) = positionManager.decreaseLiquidity(decreaseParams);
        }

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenID,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        (uint256 collected0, uint256 collected1) = positionManager.collect(collectParams);
        amount0 += collected0;
        amount1 += collected1;

        removePositionFromActive(tokenID);

        emit PositionClosed(tokenID);
        return (amount0, amount1);
    }

    /**
     * @notice Remove liquidity from the contract
     * @param amount Amount of tokens to remove
     */
    function removeLiquidity(uint256 amount) external nonReentrant {
        if (emergencyMode) revert EmergencyModeActive();
        if (circuitBreakerTriggered) revert OperationFailed("Circuit breaker triggered");
        if (amount == 0) revert InvalidParameter("amount", amount);
        if (userLiquidity[msg.sender] < amount) revert InsufficientLiquidity(amount, userLiquidity[msg.sender]);

        uint256 currentTime = block.timestamp;
        if (currentTime < lastLiquidityRemoval[msg.sender] + liquidityRemovalCooldown) {
            revert LiquidityCooldownNotMet(lastLiquidityRemoval[msg.sender] + liquidityRemovalCooldown - currentTime);
        }

        bool resetDaily = currentTime > lastDailyWithdrawal[msg.sender] + ONE_DAY;
        bool resetWeekly = currentTime > lastWeeklyWithdrawal[msg.sender] + ONE_WEEK;

        if (resetDaily) {
            dailyWithdrawalAmount[msg.sender] = 0;
            lastDailyWithdrawal[msg.sender] = currentTime;
        }
        if (resetWeekly) {
            weeklyWithdrawalAmount[msg.sender] = 0;
            lastWeeklyWithdrawal[msg.sender] = currentTime;
        }

        uint256 dailyLimit = (userLiquidity[msg.sender] * dailyWithdrawalLimit) / 100;
        if (dailyWithdrawalAmount[msg.sender] + amount > dailyLimit) {
            revert DailyLiquidityLimitExceeded(amount, dailyLimit - dailyWithdrawalAmount[msg.sender]);
        }

        uint256 weeklyLimit = (userLiquidity[msg.sender] * weeklyWithdrawalLimit) / 100;
        if (weeklyWithdrawalAmount[msg.sender] + amount > weeklyLimit) {
            revert WeeklyLiquidityLimitExceeded(amount, weeklyLimit - weeklyWithdrawalAmount[msg.sender]);
        }

        if (!validateTWAPPrice()) {
            revert TWAPVerificationFailed(0, 0);
        }

        uint256 fee = getWithdrawalFee(msg.sender, amount);
        uint256 amountAfterFee = amount - fee;

        userLiquidity[msg.sender] -= amount;
        dailyWithdrawalAmount[msg.sender] += amount;
        weeklyWithdrawalAmount[msg.sender] += amount;
        lastLiquidityRemoval[msg.sender] = currentTime;

        totalWithdrawalCount++;
        if (amount > userLiquidity[msg.sender] / 2) {
            largeWithdrawalCount++;
        }

        IERC20(address(tStakeToken)).safeTransfer(msg.sender, amountAfterFee);

        if (fee > 0 && address(treasuryManager) != address(0)) {
            IERC20(address(tStakeToken)).safeTransfer(address(treasuryManager), fee);
            totalFeesCollected += fee;
        }

        emit LiquidityRemoved(msg.sender, amount, fee, userLiquidity[msg.sender], currentTime);
    }

    /**
     * @notice Validate TWAP price against current price
     * @return valid True if TWAP price is valid
     */
    function validateTWAPPrice() public view returns (bool valid) {
        uint256 twapPrice = (block.timestamp - lastTWAPUpdate < 1 hours) ? lastTWAP : calculateTWAP();
        if (twapPrice == 0) return true;

        (uint160 sqrtPriceX96,,,,,,) = uniswapPool.slot0();
        uint256 currentPrice = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> (96 * 2);

        uint256 maxDeviation = (twapPrice * twapDeviationPercentage) / 100;

        if (currentPrice >= twapPrice - maxDeviation && currentPrice <= twapPrice + maxDeviation) {
            return true;
        }

        return false;
    }

    /**
     * @notice Verify TWAP for withdrawal
     * @return success Whether TWAP verification passed
     */
    function verifyTWAPForWithdrawal() external view returns (bool success) {
        return validateTWAPPrice();
    }

    /**
     * @notice Update the cached TWAP price
     */
    function updateTWAP() external {
        lastTWAP = calculateTWAP();
        lastTWAPUpdate = block.timestamp;
    }

    /**
     * @notice Calculate TWAP price across multiple timeframes
     * @return twap The calculated time-weighted average price
     */
    function calculateTWAP() public view returns (uint256 twap) {
        if (twapObservationTimeframes.length == 0) return 0;

        uint256 totalPrice = 0;
        uint32 totalWeight = 0;
        uint32 currentTimestamp = uint32(block.timestamp);
        uint256 successfulObservations = 0;
        uint256 maxObservations = twapObservationTimeframes.length > 5 ? 5 : twapObservationTimeframes.length;

        for (uint256 i = 0; i < maxObservations; i++) {
            uint32 secondsAgo = uint32(twapObservationTimeframes[i]);
            uint32[] memory secondsAgos = new uint32[](2);
            secondsAgos[0] = secondsAgo;
            secondsAgos[1] = 0;

            try uniswapPool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
                uint56 timeChange = uint56(secondsAgo);
                if (timeChange == 0) continue;

                int56 tickChange = tickCumulatives[1] - tickCumulatives[0];
                int24 avgTick = int24(tickChange / int56(timeChange));

                uint256 price = tickToPrice(avgTick);
                totalPrice += price * secondsAgo;
                totalWeight += secondsAgo;
                successfulObservations++;
            } catch {
                continue;
            }

            if (successfulObservations >= 3) break;
        }

        return totalWeight > 0 ? totalPrice / totalWeight : 0;
    }

    /**
     * @notice Convert tick to price
     * @param tick The tick to convert
     * @return price The calculated price
     */
    function tickToPrice(int24 tick) internal pure returns (uint256 price) {
        if (tick >= 0) {
            return uint256(1 << 96) * ((1e6 * (uint256(1) << 96)) / sqrtPriceX96ToUint(getSqrtRatioAtTick(tick), 6));
        } else {
            return uint256(1 << 96) * sqrtPriceX96ToUint(getSqrtRatioAtTick(tick), 6) / 1e6;
        }
    }

    function sqrtPriceX96ToUint(uint160 sqrtPriceX96, uint8 decimals) internal pure returns (uint256) {
        return (uint256(sqrtPriceX96) * (uint256(sqrtPriceX96))) >> (96 * 2 - decimals * 2);
    }

    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= uint256(int256(MAX_TICK)), 'T');

        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        uint256 sqrtRatioX96 = (ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1);
        return uint160(sqrtRatioX96);
    }

    /**
     * @notice Remove a position from the active positions array
     * @param _tokenID The token ID to remove
     */
    function removePositionFromActive(uint256 _tokenID) internal {
        if (!isPositionActive[_tokenID]) return;

        uint256 index = positionIndex[_tokenID];
        uint256 lastTokenId = activePositions[activePositions.length - 1];

        activePositions[index] = lastTokenId;
        positionIndex[lastTokenId] = index;
        activePositions.pop();
        delete positionIndex[_tokenID];
        isPositionActive[_tokenID] = false;
    }

    /**
     * @notice Calculate the withdrawal fee based on amount and user activity
     * @param user Address of the user
     * @param amount Amount being withdrawn
     * @return fee The calculated fee amount
     */
    function getWithdrawalFee(address user, uint256 amount) public view returns (uint256 fee) {
        if (liquidityWhitelist[user]) return 0;

        uint256 totalUserLiquidity = userLiquidity[user];
        uint256 withdrawalPercentage = (amount * 100) / totalUserLiquidity;

        fee = (amount * baseFeePercentage) / 100;

        if (withdrawalPercentage > 50) {
            fee += (amount * largeLiquidityFeeIncrease) / 100;
        }

        uint256 vestingDuration = block.timestamp - userVestingStart[user];
        uint256 vestedWeeks = vestingDuration / ONE_WEEK;

        if (vestedWeeks > 0 && vestingUnlockRate > 0) {
            uint256 vestedPercentage = vestedWeeks * vestingUnlockRate;
            if (vestedPercentage > 100) {
                vestedPercentage = 100;
            }
            fee = fee * (100 - vestedPercentage) / 100;
        }

        if (fee > (amount * MAX_FEE_PERCENTAGE) / 100) {
            fee = (amount * MAX_FEE_PERCENTAGE) / 100;
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

    /**
     * @notice Get a paginated list of active position IDs
     * @param startIndex Starting index
     * @param count Number of positions to return
     * @return positions Array of active position IDs
     */
    function getActivePositionsPaginated(uint256 startIndex, uint256 count) external view returns (uint256[] memory positions) {
        if (startIndex >= activePositions.length) return new uint256[](0);

        uint256 endIndex = startIndex + count;
        if (endIndex > activePositions.length) {
            endIndex = activePositions.length;
        }

        uint256 resultLength = endIndex - startIndex;
        positions = new uint256[](resultLength);
        for (uint256 i = 0; i < resultLength; i++) {
            positions[i] = activePositions[startIndex + i];
        }
        return positions;
    }

    /**
     * @notice Get the address of the Uniswap V3 pool
     * @return pool Address of the Uniswap pool
     */
    function getLiquidityPool() external view returns (address) {
        return address(uniswapPool);
    }
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

        delete twapObservationTimeframes;
        for (uint256 i = 0; i < newTimeframes.length; i++) {
            if (newTimeframes[i] == 0 || newTimeframes[i] > 7 days) {
                revert InvalidTWAPTimeframe(newTimeframes[i]);
            }
            twapObservationTimeframes.push(newTimeframes[i]);
        }
        emit TWAPTimeframesUpdated(newTimeframes);
    }

    /**
     * @notice Set the whitelist status for a user
     * @param user Address of the user
     * @param status New whitelist status
     */
    function setWhitelistStatus(address user, bool status) external onlyRole(GOVERNANCE_ROLE) {
        if (user == address(0)) revert InvalidZeroAddress("user");
        liquidityWhitelist[user] = status;
        emit WhitelistStatusChanged(user, status);
    }

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
     * @param _tokenID ID of the position to withdraw from
     */
    function emergencyWithdrawPosition(uint256 _tokenID) external onlyRole(EMERGENCY_ROLE) {
        if (!emergencyMode) revert EmergencyModeNotActive();
        if (!isPositionActive[_tokenID]) revert PositionNotFound(_tokenID);

        (, , , , , , , uint128 _liquidity, , , , ) = positionManager.positions(_tokenID);

        if (_liquidity > 0) {
            INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams =
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: _tokenID,
                    liquidity: _liquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp + 15 minutes
                });

            positionManager.decreaseLiquidity(decreaseParams);
        }

        INonfungiblePositionManager.CollectParams memory collectParams =
            INonfungiblePositionManager.CollectParams({
                tokenId: _tokenID,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });

        positionManager.collect(collectParams);
        removePositionFromActive(_tokenID);
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
     * @notice Request a random liquidity adjustment using Chainlink VRF
     */
    function requestRandomLiquidityAdjustment() external onlyRole(OPERATOR_ROLE) {
        vrfCoordinator.requestRandomWords(
            vrfKeyHash,
            vrfSubscriptionId,
            vrfRequestConfirmations,
            vrfCallbackGasLimit,
            1
        );
    }

    /**
     * @notice Callback function for Chainlink VRF
     * @param requestId The ID of the VRF request
     * @param randomWords The array of random values
     */
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        if (activePositions.length == 0) return;

        uint256 tokenId = activePositions[randomWords[0] % activePositions.length];
        uint256 adjustment = (randomWords[0] % 100) + 1;
        emit RandomLiquidityAdjustment(tokenId, adjustment);
    }

    /**
     * @notice Authorize contract upgrades
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}
