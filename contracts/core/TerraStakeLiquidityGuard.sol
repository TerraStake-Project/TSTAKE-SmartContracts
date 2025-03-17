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
    uint256 public totalLiquidityInjected;
    uint256 public lastLiquidityInjectionTime;
    uint256 public constant MAX_FEE_PERCENTAGE = 50;

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

    /// @dev The minimum tick that may be passed to #getSqrtRatioAtTick computed from log base 1.0001 of 2**-128
    int24 internal constant MIN_TICK = -887272;
    /// @dev The maximum tick that may be passed to #getSqrtRatioAtTick computed from log base 1.0001 of 2**128
    int24 internal constant MAX_TICK = -MIN_TICK;

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
        if (_tStakeToken == address(0)) revert InvalidZeroAddress("tStakeToken");
        if (_usdcToken == address(0)) revert InvalidZeroAddress("usdcToken");
        if (_positionManager == address(0)) revert InvalidZeroAddress("positionManager");
        if (_uniswapPool == address(0)) revert InvalidZeroAddress("uniswapPool");
        if (_rewardDistributor == address(0)) revert InvalidZeroAddress("rewardDistributor");
        if (_treasuryManager == address(0)) revert InvalidZeroAddress("treasuryManager");
        if (_admin == address(0)) revert InvalidZeroAddress("admin");
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
     * @notice Inject liquidity into Uniswap position
     * @param amount Amount of tStake tokens to inject
     */
    function injectLiquidity(uint256 amount) external nonReentrant onlyRole(OPERATOR_ROLE) {
        if (emergencyMode) revert EmergencyModeActive();
        if (amount == 0) revert InvalidParameter("amount", amount);
        
        // Get equivalent USDC from TreasuryManager
        if (address(treasuryManager) == address(0)) revert InvalidZeroAddress("treasuryManager");
        
        uint256 usdcAmount = treasuryManager.withdrawUSDCEquivalent(amount);
        if (usdcAmount == 0) revert InvalidParameter("usdcAmount", usdcAmount);
        
        // Get current tick from pool
        (, int24 currentTick, , , , , ) = uniswapPool.slot0();
        
        // Calculate tick range (example: +/- 10% from current price)
        int24 tickSpacing = uniswapPool.tickSpacing();
        int24 tickLower = currentTick - (10 * tickSpacing);
        int24 tickUpper = currentTick + (10 * tickSpacing);
        
        // Ensure ticks are divisible by tick spacing
        tickLower = tickLower - (tickLower % tickSpacing);
        tickUpper = tickUpper - (tickUpper % tickSpacing);
        
        // Approve tokens
        IERC20(address(tStakeToken)).approve(address(positionManager), amount);
        IERC20(address(usdcToken)).approve(address(positionManager), usdcAmount);
        
        // Create the position
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(tStakeToken),
            token1: address(usdcToken),
            fee: DEFAULT_POOL_FEE,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount,
            amount1Desired: usdcAmount,
            amount0Min: amount * (10000 - slippageTolerance) / 10000,
            amount1Min: usdcAmount * (10000 - slippageTolerance) / 10000,
            recipient: address(this),
            deadline: block.timestamp + 15 minutes
        });
        
        // Mint new position
        (uint256 newTokenId, uint128 newLiquidity, uint256 amount0, uint256 amount1) = positionManager.mint(params);
        
        // Add to active positions
        if (!isPositionActive[newTokenId]) {
            activePositions.push(newTokenId);
            isPositionActive[newTokenId] = true;
        }
        
        // Update state
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
        
        // Create collect params
        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
            tokenId: tokenID,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        
        // Collect fees
        (amount0, amount1) = positionManager.collect(params);
        
        // Update total fees collected
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
        
        // Get position info to verify liquidity
        (, , , , , , , uint128 posLiquidity, , , , ) = positionManager.positions(tokenID);
        if (liquidity > posLiquidity) revert InvalidParameter("liquidity", liquidity);
        
        // Create decrease liquidity params
        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager.DecreaseLiquidityParams({
            tokenId: tokenID,
            liquidity: liquidity,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            deadline: block.timestamp + 15 minutes
        });
        
        // Decrease liquidity
        (amount0, amount1) = positionManager.decreaseLiquidity(params);
        
        // Collect the tokens
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
        
        // Get position info
        (, , , , , , , uint128 posLiquidity, , , , ) = positionManager.positions(tokenID);
        
        if (posLiquidity > 0) {
            // First decrease all liquidity
            INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams = INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenID,
                liquidity: posLiquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 15 minutes
            });
            
            (amount0, amount1) = positionManager.decreaseLiquidity(decreaseParams);
        }
        
        // Collect all tokens
        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenID,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        
        (uint256 collected0, uint256 collected1) = positionManager.collect(collectParams);
        amount0 += collected0;
        amount1 += collected1;
        
        // Remove from active positions
        for (uint256 i = 0; i < activePositions.length; i++) {
            if (activePositions[i] == tokenID) {
                activePositions[i] = activePositions[activePositions.length - 1];
                activePositions.pop();
                isPositionActive[tokenID] = false;
                break;
            }
        }
        
        emit PositionClosed(tokenID);
        return (amount0, amount1);
    }

    /**
     * @notice Remove liquidity from the contract
     * @param amount Amount of tokens to remove
     */
    function removeLiquidity(uint256 amount) external nonReentrant {
        if (emergencyMode) revert EmergencyModeActive();
        if (amount == 0) revert InvalidParameter("amount", amount);
        if (userLiquidity[msg.sender] < amount) revert InsufficientLiquidity(amount, userLiquidity[msg.sender]);
        
        // Check cooldown period
        if (block.timestamp < lastLiquidityRemoval[msg.sender] + liquidityRemovalCooldown) {
            revert LiquidityCooldownNotMet(lastLiquidityRemoval[msg.sender] + liquidityRemovalCooldown - block.timestamp);
        }
        
        // Check daily withdrawal limit
        if (block.timestamp > lastDailyWithdrawal[msg.sender] + ONE_DAY) {
            // Reset if a day has passed
            dailyWithdrawalAmount[msg.sender] = 0;
            lastDailyWithdrawal[msg.sender] = block.timestamp;
        }
        
        uint256 dailyLimit = (userLiquidity[msg.sender] * dailyWithdrawalLimit) / 100;
        if (dailyWithdrawalAmount[msg.sender] + amount > dailyLimit) {
            revert DailyLiquidityLimitExceeded(amount, dailyLimit - dailyWithdrawalAmount[msg.sender]);
        }
        
        // Check weekly withdrawal limit
        if (block.timestamp > lastWeeklyWithdrawal[msg.sender] + ONE_WEEK) {
            // Reset if a week has passed
            weeklyWithdrawalAmount[msg.sender] = 0;
            lastWeeklyWithdrawal[msg.sender] = block.timestamp;
        }
        
        uint256 weeklyLimit = (userLiquidity[msg.sender] * weeklyWithdrawalLimit) / 100;
        if (weeklyWithdrawalAmount[msg.sender] + amount > weeklyLimit) {
            revert WeeklyLiquidityLimitExceeded(amount, weeklyLimit - weeklyWithdrawalAmount[msg.sender]);
        }
        
        // Verify TWAP price to prevent manipulation
        if (!validateTWAPPrice()) {
            revert TWAPVerificationFailed(0, 0); // Actual values would be calculated in the function
        }
        
        // Calculate and apply fee
        uint256 fee = getWithdrawalFee(msg.sender, amount);
        uint256 amountAfterFee = amount - fee;
        
        // Update user's liquidity position
        userLiquidity[msg.sender] -= amount;
        dailyWithdrawalAmount[msg.sender] += amount;
        weeklyWithdrawalAmount[msg.sender] += amount;
        lastLiquidityRemoval[msg.sender] = block.timestamp;
        
        // Track analytics
        totalWithdrawalCount++;
        if (amount > userLiquidity[msg.sender] / 2) {
            largeWithdrawalCount++;
        }
        
        // Transfer tokens to the user
        IERC20(address(tStakeToken)).safeTransfer(msg.sender, amountAfterFee);
        
        // Transfer fee to treasury if applicable
        if (fee > 0 && address(treasuryManager) != address(0)) {
            IERC20(address(tStakeToken)).safeTransfer(address(treasuryManager), fee);
            totalFeesCollected += fee;
        }
        
        emit LiquidityRemoved(msg.sender, amount, fee, userLiquidity[msg.sender], block.timestamp);
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
     * @notice Verify TWAP for withdrawal
     * @return success Whether TWAP verification passed
     */
    function verifyTWAPForWithdrawal() external view returns (bool success) {
        return validateTWAPPrice();
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
    // Convert to Q96 format as used by Uniswap V3
    if (tick >= 0) {
        return uint256(1 << 96) * ((1e6 * (uint256(1) << 96)) / sqrtPriceX96ToUint(getSqrtRatioAtTick(tick), 6));
    } else {
        return uint256(1 << 96) * sqrtPriceX96ToUint(getSqrtRatioAtTick(tick), 6) / 1e6;
    }
}

// Helper function to convert sqrtPriceX96 to a uint with desired decimals
function sqrtPriceX96ToUint(uint160 sqrtPriceX96, uint8 decimals) internal pure returns (uint256) {
    return (uint256(sqrtPriceX96) * (uint256(sqrtPriceX96))) >> (96 * 2 - decimals * 2);
}

// Uniswap's implementation of getSqrtRatioAtTick
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

    // This divides by 1<<32 rounding up to go from a Q128.128 to a Q128.96.
    // We then downcast because we know the result always fits within 160 bits due to our tick input constraint.
    // We round up in the division so getTickAtSqrtRatio of the output price is always consistent.
    uint256 sqrtRatioX96 = (ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1);
    return uint160(sqrtRatioX96);
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
        
        uint256 totalUserLiquidity = userLiquidity[user]; // Current liquidity before withdrawal
        uint256 withdrawalPercentage = (amount * 100) / totalUserLiquidity;
        
        // Base fee applies to everyone
        fee = (amount * baseFeePercentage) / 100;
        
        // Additional fee for large withdrawals
        if (withdrawalPercentage > 50) {
            fee += (amount * largeLiquidityFeeIncrease) / 100;
        }
        
        // Apply vesting schedule reduction
        uint256 vestingDuration = block.timestamp - userVestingStart[user];
        uint256 vestedWeeks = vestingDuration / ONE_WEEK;
        
        // Reduce fee based on vesting progress (linear reduction)
        if (vestedWeeks > 0 && vestingUnlockRate > 0) {
        uint256 vestedPercentage = vestedWeeks * vestingUnlockRate;
        if (vestedPercentage > 100) {
            vestedPercentage = 100;
    }
    
    // Reduce fee proportionally to vesting progress
    fee = fee * (100 - vestedPercentage) / 100;
}
        
        // Cap fee at maximum allowed
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
            twapObservationTimeframes.push(newTimeframes[i]);
        }
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
     * @param _tokenID ID of the position to withdraw from
     */
    function emergencyWithdrawPosition(uint256 _tokenID) external onlyRole(EMERGENCY_ROLE) {
        if (!emergencyMode) revert EmergencyModeNotActive();
        if (!isPositionActive[_tokenID]) revert PositionNotFound(_tokenID);
        
        // Get position info
        (, , , , , , , uint128 _liquidity, , , , ) = positionManager.positions(_tokenID);
        
        if (_liquidity > 0) {
            // First decrease all liquidity
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
        
        // Collect all tokens
        INonfungiblePositionManager.CollectParams memory collectParams = 
            INonfungiblePositionManager.CollectParams({
                tokenId: _tokenID,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });
        
        positionManager.collect(collectParams);
        
        // Remove from active positions
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
     * @notice Required function for VRF callback
     * @param requestId The ID of the VRF request
     * @param randomWords The array of random values
     */
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        // Implementation for VRF callback - can be used for stochastic mechanisms
    }
}                

