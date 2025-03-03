// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "../interfaces/ITerraStakeRewardDistributor.sol";
import "../interfaces/ITerraStakeTreasury.sol";

/**
 * @title TerraStakeLiquidityGuard
 * @author TerraStake Protocol Team
 * @notice Secure liquidity protection & auto-reinjection for the TerraStake ecosystem
 * @dev Protects against flash loans, price manipulation, and excessive liquidity withdrawals
 *      Implements TWAP-based price monitoring and anti-whale controls
 */
contract TerraStakeLiquidityGuard is 
    Initializable, 
    AccessControlEnumerableUpgradeable, 
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable 
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    // -------------------------------------------
    // 🔹 Errors
    // -------------------------------------------
    error Unauthorized();
    error InvalidZeroAddress(string name);
    error InvalidParameter(string name, uint256 value);
    error LiquidityCooldownNotMet(uint256 remainingTime);
    error DailyLiquidityLimitExceeded(uint256 requested, uint256 allowed);
    error WeeklyLiquidityLimitExceeded(uint256 requested, uint256 allowed);
    error TWAPVerificationFailed(uint256 price, uint256 twap);
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error TooEarlyToWithdraw(uint256 unlockedAmount, uint256 requested);
    error EmergencyModeActive();
    error TransferFailed(address token, uint256 amount);
    error InsufficientPoolLiquidity(uint256 requested, uint256 available);
    error TickOutOfRange(int24 lower, int24 upper, int24 current);
    error SlippageTooHigh(uint256 expected, uint256 received);
    
    // -------------------------------------------
    // 🔹 Constants
    // -------------------------------------------
    // Roles
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    
    // Liquidity limits
    uint256 public constant PERCENTAGE_DENOMINATOR = 100;
    uint256 public constant TWAP_PRICE_TOLERANCE = 5; // 5% price deviation tolerance
    uint256 public constant MAX_FEE_PERCENTAGE = 15;  // 15% max withdrawal fee
    uint256 public constant MIN_INJECTION_INTERVAL = 1 hours; // Minimum time between injections
    uint256 public constant MAX_TICK_RANGE = 30; // Maximum tick range in multiples of tick spacing
    uint256 public constant DEFAULT_SLIPPAGE_TOLERANCE = 5; // 5% default slippage tolerance
    
    // Time constants
    uint256 public constant ONE_DAY = 1 days;
    uint256 public constant ONE_WEEK = 7 days;
    uint256 public constant ONE_MONTH = 30 days;
    
    // -------------------------------------------
    // 🔹 Storage Variables
    // -------------------------------------------
    // Token & Contract References
    IERC20Upgradeable public tStakeToken;
    IERC20Upgradeable public usdcToken;
    INonfungiblePositionManager public positionManager;
    IUniswapV3Pool public uniswapPool;
    ITerraStakeRewardDistributor public rewardDistributor;
    ITerraStakeTreasury public treasury;
    
    // Liquidity Management Parameters
    uint256 public reinjectionThreshold;
    uint256 public autoLiquidityInjectionRate;
    uint256 public maxLiquidityPerAddress;
    uint256 public liquidityRemovalCooldown;
    uint256 public slippageTolerance;
    
    // Anti-Whale Restriction Parameters
    uint256 public dailyWithdrawalLimit;      // % of user's liquidity allowed per day
    uint256 public weeklyWithdrawalLimit;     // % of user's liquidity allowed per week
    uint256 public vestingUnlockRate;         // % of liquidity that unlocks per week
    uint256 public baseFeePercentage;         // Base fee for all withdrawals
    uint256 public largeLiquidityFeeIncrease; // Additional fee for large withdrawals
    
    // User Liquidity Data
    mapping(address => uint256) public userLiquidity;
    mapping(address => uint256) public lastLiquidityRemoval;
    mapping(address => uint256) public userVestingStart;
    mapping(address => uint256) public lastDailyWithdrawal;
    mapping(address => uint256) public dailyWithdrawalAmount;
    mapping(address => uint256) public lastWeeklyWithdrawal;
    mapping(address => uint256) public weeklyWithdrawalAmount;
    
    // Special Access Controls
    mapping(address => bool) public liquidityWhitelist;
    
    // Protocol Monitoring
    bool public emergencyMode;
    uint32[] public twapObservationTimeframes; // Timeframes for TWAP observations in seconds
    
    // Uniswap Position Management
    mapping(uint256 => bool) public managedPositions; // Tracking for position token IDs
    uint256[] public activePositionIds;
    uint256 public lastLiquidityInjectionTime;
    uint256 public totalLiquidityInjected;
    uint256 public totalFeesCollected;
    
    // Enhanced Analytics
    uint256 public totalWithdrawalCount;
    uint256 public largeWithdrawalCount; // Withdrawals >50% of user liquidity
    
    // -------------------------------------------
    // 🔹 Events
    // -------------------------------------------
    event LiquidityInjected(uint256 amount, uint256 tokenAmount, uint256 usdcAmount);
    event LiquidityRemoved(
        address indexed provider, 
        uint256 amount, 
        uint256 fee,
        uint256 remainingLiquidity,
        uint256 timestamp
    );
    event LiquidityDeposited(address indexed provider, uint256 amount);
    
    event LiquidityCapUpdated(uint256 newCap);
    event LiquidityInjectionRateUpdated(uint256 newRate);
    event LiquidityReinjectionThresholdUpdated(uint256 newThreshold);
    event LiquidityParametersUpdated(
        uint256 dailyLimit, 
        uint256 weeklyLimit, 
        uint256 vestingRate, 
        uint256 baseFee
    );
    
    event CircuitBreakerTriggered();
    event TWAPVerificationFailed(uint256 currentPrice, uint256 twapPrice);
    event EmergencyModeChanged(bool active);
    event AddressWhitelisted(address indexed user, bool status);
    event SlippageToleranceUpdated(uint256 oldTolerance, uint256 newTolerance);
    event RewardDistributorUpdated(address oldDistributor, address newDistributor);
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event UniswapPositionCreated(uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event UniswapPositionIncreased(uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event UniswapPositionDecreased(uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event UniswapPositionClosed(uint256 tokenId, uint256 amount0, uint256 amount1);
    event UniswapFeesCollected(uint256 tokenId, uint256 amount0, uint256 amount1);
    event WeeklyLimitBelowRecommended(uint256 actualLimit, uint256 recommendedMinimum);
    
    // -------------------------------------------
    // 🔹 Initialization
    // -------------------------------------------
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @notice Initialize the liquidity guard contract
     * @param _tStakeToken Address of the TerraStake token
     * @param _usdcToken Address of the USDC token
     * @param _positionManager Address of the Uniswap position manager
     * @param _uniswapPool Address of the Uniswap pool
     * @param _rewardDistributor Address of the reward distributor
     * @param _treasury Address of the treasury
     * @param _reinjectionThreshold Minimum amount for liquidity reinjection
     * @param _admin Address of the admin
     */
    function initialize(
        address _tStakeToken,
        address _usdcToken,
        address _positionManager,
        address _uniswapPool,
        address _rewardDistributor,
        address _treasury,
        uint256 _reinjectionThreshold,
        address _admin
    ) external initializer {
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        if (_tStakeToken == address(0)) revert InvalidZeroAddress("tStakeToken");
        if (_usdcToken == address(0)) revert InvalidZeroAddress("usdcToken");
        if (_positionManager == address(0)) revert InvalidZeroAddress("positionManager");
        if (_uniswapPool == address(0)) revert InvalidZeroAddress("uniswapPool");
        if (_admin == address(0)) revert InvalidZeroAddress("admin");
        
        tStakeToken = IERC20Upgradeable(_tStakeToken);
        usdcToken = IERC20Upgradeable(_usdcToken);
        positionManager = INonfungiblePositionManager(_positionManager);
        uniswapPool = IUniswapV3Pool(_uniswapPool);
        
        if (_rewardDistributor != address(0)) {
            rewardDistributor = ITerraStakeRewardDistributor(_rewardDistributor);
        }
        
        if (_treasury != address(0)) {
            treasury = ITerraStakeTreasury(_treasury);
        }
        
        // Set default anti-whale parameters
        dailyWithdrawalLimit = 5;      // 5% per day
        weeklyWithdrawalLimit = 25;    // 25% per week
        vestingUnlockRate = 10;        // 10% unlocks per week
        baseFeePercentage = 2;         // 2% base fee
        largeLiquidityFeeIncrease = 8; // +8% for large withdrawals (>50%)
        liquidityRemovalCooldown = 7 days; // 7 day cooldown
        
        reinjectionThreshold = _reinjectionThreshold;
        autoLiquidityInjectionRate = 5; // 5% default
        slippageTolerance = DEFAULT_SLIPPAGE_TOLERANCE;
        
        // Set TWAP observation timeframes
        twapObservationTimeframes = [30 minutes, 1 hours, 4 hours, 24 hours];
        
        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(GOVERNANCE_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
    }
    
    /**
     * @notice Authorize contract upgrades (restricted to upgrader role)
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
    
    // -------------------------------------------
    // 🔹 Liquidity Management - Core Functions
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
        tStakeToken.safeTransferFrom(msg.sender, address(this), amount);
        
        // Update user's liquidity position
        userLiquidity[msg.sender] += amount;
        
        // Set vesting start time if first deposit
        if (userVestingStart[msg.sender] == 0) {
            userVestingStart[msg.sender] = block.timestamp;
        }
        
        emit LiquidityDeposited(msg.sender, amount);
    }
    
    /**
     * @notice Remove liquidity from the contract
     * @param amount Amount of tokens to remove
     */
    function removeLiquidity(uint256 amount) external nonReentrant {
        if (emergencyMode) revert EmergencyModeActive();
        if (amount == 0) revert InvalidParameter("amount", amount);
                // Whitelist can bypass restrictions
        if (!liquidityWhitelist[msg.sender]) {
            // Validate cooldown period
            if (lastLiquidityRemoval[msg.sender] + liquidityRemovalCooldown > block.timestamp) {
                revert LiquidityCooldownNotMet(
                   lastLiquidityRemoval[msg.sender] + liquidityRemovalCooldown - block.timestamp
                );
            }
            
            // Validate daily withdrawal limit
            uint256 userTotalLiquidity = userLiquidity[msg.sender];
            uint256 maxDailyAmount = (userTotalLiquidity * dailyWithdrawalLimit) / PERCENTAGE_DENOMINATOR;
            
            // Reset daily tracking if a day has passed
            if (lastDailyWithdrawal[msg.sender] + ONE_DAY < block.timestamp) {
                dailyWithdrawalAmount[msg.sender] = 0;
                lastDailyWithdrawal[msg.sender] = block.timestamp;
            }
            
            // Check if new withdrawal would exceed daily limit
            if (dailyWithdrawalAmount[msg.sender] + amount > maxDailyAmount) {
                revert DailyLiquidityLimitExceeded(
                    amount, 
                    maxDailyAmount - dailyWithdrawalAmount[msg.sender]
                );
            }
            
            // Validate weekly withdrawal limit
            uint256 maxWeeklyAmount = (userTotalLiquidity * weeklyWithdrawalLimit) / PERCENTAGE_DENOMINATOR;
            
            // Reset weekly tracking if a week has passed
            if (lastWeeklyWithdrawal[msg.sender] + ONE_WEEK < block.timestamp) {
                weeklyWithdrawalAmount[msg.sender] = 0;
                lastWeeklyWithdrawal[msg.sender] = block.timestamp;
            }
            
            // Check if new withdrawal would exceed weekly limit
            if (weeklyWithdrawalAmount[msg.sender] + amount > maxWeeklyAmount) {
                revert WeeklyLiquidityLimitExceeded(
                    amount, 
                    maxWeeklyAmount - weeklyWithdrawalAmount[msg.sender]
                );
            }
            
            // Validate TWAP price to prevent withdrawals during price crashes
            if (!validateTWAPPrice()) {
                (uint160 sqrtPriceX96,,,,,,) = uniswapPool.slot0();
                uint256 price = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> (96 * 2);
                uint256 twap = calculateTWAP();
                revert TWAPVerificationFailed(price, twap);
            }
            
            // Validate vesting-based unlock
            uint256 timeSinceVestingStart = block.timestamp - userVestingStart[msg.sender];
            uint256 weeksVested = timeSinceVestingStart / ONE_WEEK;
            uint256 unlockedPercentage = (weeksVested * vestingUnlockRate);
            if (unlockedPercentage > 100) unlockedPercentage = 100;
            
            uint256 unlockedAmount = (userTotalLiquidity * unlockedPercentage) / PERCENTAGE_DENOMINATOR;
            uint256 withdrawnAmount = userTotalLiquidity - userLiquidity[msg.sender];
            
            if (withdrawnAmount + amount > unlockedAmount) {
                revert TooEarlyToWithdraw(unlockedAmount - withdrawnAmount, amount);
            }
            
            // Update daily and weekly tracking
            dailyWithdrawalAmount[msg.sender] += amount;
            weeklyWithdrawalAmount[msg.sender] += amount;
        }
        
        // Check if user has enough liquidity
        if (userLiquidity[msg.sender] < amount) {
            revert InsufficientLiquidity(amount, userLiquidity[msg.sender]);
        }
        
        // Calculate fee based on withdrawal size
        uint256 fee = getWithdrawalFee(msg.sender, amount);
        uint256 amountAfterFee = amount - fee;
        
        // Update user's liquidity position
        userLiquidity[msg.sender] -= amount;
        lastLiquidityRemoval[msg.sender] = block.timestamp;
        
        // Update analytics
        totalWithdrawalCount++;
        if (amount > userLiquidity[msg.sender] / 2) {
            largeWithdrawalCount++;
        }
        
        // Transfer tokens to user after fee
        tStakeToken.safeTransfer(msg.sender, amountAfterFee);
        
        // Send fee to treasury if there is one
        if (fee > 0 && address(treasury) != address(0)) {
            tStakeToken.safeTransfer(address(treasury), fee);
            totalFeesCollected += fee;
        }
        
        emit LiquidityRemoved(
            msg.sender, 
            amount, 
            fee, 
            userLiquidity[msg.sender],
            block.timestamp
        );
    }
    
    /**
     * @notice Inject liquidity into the pool 
     * @param amount Amount of tokens to inject into liquidity
     */
    function injectLiquidity(uint256 amount) external nonReentrant {
        // Only reward distributor or governance can call this
        if (msg.sender != address(rewardDistributor) && !hasRole(GOVERNANCE_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        
        if (amount == 0) revert InvalidParameter("amount", amount);
        if (amount < reinjectionThreshold) revert InvalidParameter("amount", amount);
        
        // Check minimum time between injections to prevent transaction ordering attacks
        if (block.timestamp < lastLiquidityInjectionTime + MIN_INJECTION_INTERVAL) {
            revert InvalidParameter("injection too frequent", block.timestamp - lastLiquidityInjectionTime);
        }
        
        // Get current price for determining token ratios
        (uint160 sqrtPriceX96,,,,,,) = uniswapPool.slot0();
        uint256 price = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> (96 * 2);
        
        // Calculate token amounts for balanced liquidity provision
        uint256 tokenAmount = amount / 2;
        uint256 usdcAmount = (tokenAmount * price) / 1e18;
        
        // Ensure we have sufficient USDC balance
        if (usdcToken.balanceOf(address(this)) < usdcAmount) {
            usdcAmount = usdcToken.balanceOf(address(this));
            tokenAmount = (usdcAmount * 1e18) / price;
        }
        
        // Approve tokens to position manager
        tStakeToken.approve(address(positionManager), tokenAmount);
        usdcToken.approve(address(positionManager), usdcAmount);
        
        // Get pool information to determine tick range
        int24 tickSpacing = uniswapPool.tickSpacing();
        (,int24 currentTick,,,,,) = uniswapPool.slot0();
        
        // Calculate tick range centered around current price
        int24 lowerTick = (currentTick / tickSpacing) * tickSpacing - (10 * tickSpacing);
        int24 upperTick = (currentTick / tickSpacing) * tickSpacing + (10 * tickSpacing);
        
        // Ensure ticks are in valid range
        if (lowerTick >= upperTick) {
            revert TickOutOfRange(lowerTick, upperTick, currentTick);
        }
        
        uint256 tokenId;
        uint128 liquidityAdded;
        uint256 amount0;
        uint256 amount1;
        
        // Determine if we should create a new position or increase an existing one
        if (activePositionIds.length == 0) {
            // Create new position
            INonfungiblePositionManager.MintParams memory params = 
                INonfungiblePositionManager.MintParams({
                    token0: address(tStakeToken),
                    token1: address(usdcToken),
                    fee: uniswapPool.fee(),
                    tickLower: lowerTick,
                    tickUpper: upperTick,
                    amount0Desired: tokenAmount,
                    amount1Desired: usdcAmount,
                    amount0Min: tokenAmount * (100 - slippageTolerance) / 100,
                    amount1Min: usdcAmount * (100 - slippageTolerance) / 100,
                    recipient: address(this),
                    deadline: block.timestamp + 15 minutes
                });
                
            // Mint new position
            (tokenId, liquidityAdded, amount0, amount1) = positionManager.mint(params);
            
            // Add to active positions
            managedPositions[tokenId] = true;
            activePositionIds.push(tokenId);
            
            emit UniswapPositionCreated(tokenId, liquidityAdded, amount0, amount1);
        } else {
            // Find the most suitable position to increase
            tokenId = findBestPositionToIncrease(currentTick);
            
            // Increase liquidity of existing position
            INonfungiblePositionManager.IncreaseLiquidityParams memory params =
                INonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId: tokenId,
                    amount0Desired: tokenAmount,
                    amount1Desired: usdcAmount,
                    amount0Min: tokenAmount * (100 - slippageTolerance) / 100,
                    amount1Min: usdcAmount * (100 - slippageTolerance) / 100,
                    deadline: block.timestamp + 15 minutes
                });
                
            // Increase liquidity
            (liquidityAdded, amount0, amount1) = positionManager.increaseLiquidity(params);
            
            emit UniswapPositionIncreased(tokenId, liquidityAdded, amount0, amount1);
        }
        
        // Check for slippage
        if (amount0 < tokenAmount * (100 - slippageTolerance) / 100 || 
            amount1 < usdcAmount * (100 - slippageTolerance) / 100) {
            revert SlippageTooHigh(tokenAmount + usdcAmount, amount0 + amount1);
        }
        
        // Update tracking
        lastLiquidityInjectionTime = block.timestamp;
        totalLiquidityInjected += amount0 + amount1;
        
        emit LiquidityInjected(amount, amount0, amount1);
    }
    
    /**
     * @notice Collect fees from Uniswap position
     * @param tokenId ID of the position to collect fees from
     * @return amount0 Amount of token0 collected
     * @return amount1 Amount of token1 collected
     */
    function collectPositionFees(uint256 tokenId) external nonReentrant onlyRole(OPERATOR_ROLE) returns (uint256 amount0, uint256 amount1) {
        // Verify the position is managed by this contract
        if (!managedPositions[tokenId]) revert Unauthorized();
        
        // Collect all fees
        INonfungiblePositionManager.CollectParams memory params =
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });
            
        // Collect fees
        (amount0, amount1) = positionManager.collect(params);
        
        emit UniswapFeesCollected(tokenId, amount0, amount1);
    }
    
    /**
     * @notice Decreases liquidity from a position and collects fees
     * @param tokenId Position ID
     * @param liquidity Amount of liquidity to remove
     * @param amount0Min Minimum amount of token0 to receive
     * @param amount1Min Minimum amount of token1 to receive
     * @return amount0 Amount of token0 received
     * @return amount1 Amount of token1 received
     */
    function decreasePositionLiquidity(
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min
    ) external nonReentrant onlyRole(OPERATOR_ROLE) returns (uint256 amount0, uint256 amount1) {
        // Verify the position is managed by this contract
        if (!managedPositions[tokenId]) revert Unauthorized();
        
        // Create decrease liquidity parameters
        INonfungiblePositionManager.DecreaseLiquidityParams memory params =
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: block.timestamp + 15 minutes
            });
            
        // Decrease liquidity
        (amount0, amount1) = positionManager.decreaseLiquidity(params);
        
        // Collect the tokens
        INonfungiblePositionManager.CollectParams memory collectParams =
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });
            
        positionManager.collect(collectParams);
        
        emit UniswapPositionDecreased(tokenId, liquidity, amount0, amount1);
    }
    
    /**
     * @notice Close position completely and collect all tokens
     * @param tokenId Position ID to close
     * @return amount0 Amount of token0 received
     * @return amount1 Amount of token1 received
     */
    function closePosition(uint256 tokenId) external nonReentrant onlyRole(OPERATOR_ROLE) returns (uint256 amount0, uint256 amount1) {
        // Verify the position is managed by this contract
        if (!managedPositions[tokenId]) revert Unauthorized();
        
        // Get position info
        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint128 liquidity,
            ,
            ,
            ,
        ) = positionManager.positions(tokenId);
        
        if (liquidity > 0) {
            // Decrease liquidity to zero
            INonfungiblePositionManager.DecreaseLiquidityParams memory params =
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp + 15 minutes
                });
                
            (amount0, amount1) = positionManager.decreaseLiquidity(params);
        }
        
        // Collect all tokens
        INonfungiblePositionManager.CollectParams memory collectParams =
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });
            
        (uint256 collected0, uint256 collected1) = positionManager
            .collect(collectParams);
            
        amount0 += collected0;
        amount1 += collected1;
        
        // Burn the position
        positionManager.burn(tokenId);
        
        // Update tracking
        managedPositions[tokenId] = false;
        
        // Remove tokenId from active positions array
        for (uint256 i = 0; i < activePositionIds.length; i++) {
            if (activePositionIds[i] == tokenId) {
                // Replace with the last element and pop
                activePositionIds[i] = activePositionIds[activePositionIds.length - 1];
                activePositionIds.pop();
                break;
            }
        }
        
        emit UniswapPositionClosed(tokenId, amount0, amount1);
    }
    
    /**
     * @notice Find the best position to increase liquidity based on current price
     * @param currentTick Current pool tick
     * @return tokenId Token ID of the best position to increase
     */
    function findBestPositionToIncrease(int24 currentTick) internal view returns (uint256 tokenId) {
        uint256 bestScore = type(uint256).max;
        
        for (uint256 i = 0; i < activePositionIds.length; i++) {
            uint256 posId = activePositionIds[i];
            
            // Get position details
            (
                ,
                ,
                ,
                ,
                ,
                int24 tickLower,
                int24 tickUpper,
                uint128 liquidity,
                ,
                ,
                ,
            ) = positionManager.positions(posId);
            
            // Skip positions with no liquidity
            if (liquidity == 0) continue;
            
            // Check if current tick is within position range
            if (currentTick >= tickLower && currentTick <= tickUpper) {
                // Prefer positions where current tick is approximately centered
                int24 distFromCenter = abs(currentTick - ((tickUpper + tickLower) / 2));
                uint256 score = uint256(uint24(distFromCenter));
                
                if (score < bestScore) {
                    bestScore = score;
                    tokenId = posId;
                }
            }
        }
        
        // If no suitable position found, use the first active position
        if (tokenId == 0 && activePositionIds.length > 0) {
            tokenId = activePositionIds[0];
        }
    }
    
    /**
     * @notice Calculate the TWAP (Time-Weighted Average Price)
     * @return twapPrice The TWAP price
     */
    function calculateTWAP() public view returns (uint256 twapPrice) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapInterval;
        secondsAgos[1] = 0;
        
        (int56[] memory tickCumulatives,) = uniswapPool.observe(secondsAgos);
        
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 timeWeightedAverageTick = int24(tickCumulativesDelta / int56(uint56(twapInterval)));
        
        // Calculate price from tick
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(timeWeightedAverageTick);
        twapPrice = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18) >> (96 * 2);
    }
    
    /**
     * @notice Validate the TWAP price against threshold
     * @return valid True if the TWAP price is valid
     */
    function validateTWAPPrice() public view returns (bool valid) {
        // Check current price vs TWAP
        (uint160 sqrtPriceX96,,,,,,) = uniswapPool.slot0();
        uint256 currentPrice = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> (96 * 2);
        uint256 twapPrice = calculateTWAP();
        
        // If price is below TWAP by more than deviation threshold, return false
        uint256 priceDeviationPercentage;
        if (currentPrice < twapPrice) {
            priceDeviationPercentage = ((twapPrice - currentPrice) * PERCENTAGE_DENOMINATOR) / twapPrice;
            valid = priceDeviationPercentage <= maxTwapDeviation;
        } else {
            valid = true; // Allow withdrawals when price is above TWAP
        }
    }
    
    /**
     * @notice Calculate the fee for a withdrawal
     * @param user Address of the user
     * @param amount Amount being withdrawn
     * @return fee The calculated fee amount
     */
    function getWithdrawalFee(address user, uint256 amount) public view returns (uint256 fee) {
        // Whitelisted addresses pay no fees
        if (feeWhitelist[user]) return 0;
        
        // Calculate how long the user has been staking
        uint256 stakingDuration = block.timestamp - userVestingStart[user];
        
        // Early withdrawal fee (before min holding period)
        if (stakingDuration < minHoldingPeriod) {
            return (amount * earlyWithdrawalFee) / PERCENTAGE_DENOMINATOR;
        }
        
        // Dynamic fee based on withdrawal size
        uint256 positionSize = userLiquidity[user];
        if (positionSize == 0) return 0;
        
        uint256 withdrawalPercentage = (amount * PERCENTAGE_DENOMINATOR) / positionSize;
        
        // Apply tiered fee structure based on percentage withdrawn
        if (withdrawalPercentage >= 80 * (PERCENTAGE_DENOMINATOR / 100)) {
            return (amount * largeWithdrawalFee) / PERCENTAGE_DENOMINATOR;
        } else if (withdrawalPercentage >= 50 * (PERCENTAGE_DENOMINATOR / 100)) {
            return (amount * mediumWithdrawalFee) / PERCENTAGE_DENOMINATOR;
        } else if (withdrawalPercentage >= 20 * (PERCENTAGE_DENOMINATOR / 100)) {
            return (amount * smallWithdrawalFee) / PERCENTAGE_DENOMINATOR;
        } else {
            return (amount * minimalWithdrawalFee) / PERCENTAGE_DENOMINATOR;
        }
    }
    
    /**
     * @notice Absolute difference between two int24 values
     * @param x First value
     * @param y Second value
     * @return z Absolute difference
     */
    function abs(int24 x) internal pure returns (int24) {
        return x >= 0 ? x : -x;
    }
    
    /**
     * @notice Add an address to the liquidity whitelist
     * @param account Address to whitelist
     */
    function addToLiquidityWhitelist(address account) external onlyRole(GOVERNANCE_ROLE) {
        liquidityWhitelist[account] = true;
        emit WhitelistUpdated(account, true, "liquidity");
    }
    
    /**
     * @notice Remove an address from the liquidity whitelist
     * @param account Address to remove
     */
    function removeFromLiquidityWhitelist(address account) external onlyRole(GOVERNANCE_ROLE) {
        liquidityWhitelist[account] = false;
        emit WhitelistUpdated(account, false, "liquidity");
    }
    
    /**
     * @notice Add an address to the fee whitelist
     * @param account Address to whitelist
     */
    function addToFeeWhitelist(address account) external onlyRole(GOVERNANCE_ROLE) {
        feeWhitelist[account] = true;
        emit WhitelistUpdated(account, true, "fee");
    }
    
    /**
     * @notice Remove an address from the fee whitelist
     * @param account Address to remove
     */
    function removeFromFeeWhitelist(address account) external onlyRole(GOVERNANCE_ROLE) {
        feeWhitelist[account] = false;
        emit WhitelistUpdated(account, false, "fee");
    }
    
    /**
     * @notice Update fee parameters
     * @param _minimalWithdrawalFee Fee for small withdrawals
     * @param _smallWithdrawalFee Fee for small withdrawals
     * @param _mediumWithdrawalFee Fee for medium withdrawals
     * @param _largeWithdrawalFee Fee for large withdrawals
     * @param _earlyWithdrawalFee Fee for early withdrawals
     */
    function updateFees(
        uint256 _minimalWithdrawalFee,
        uint256 _smallWithdrawalFee,
        uint256 _mediumWithdrawalFee,
        uint256 _largeWithdrawalFee,
        uint256 _earlyWithdrawalFee
    ) external onlyRole(GOVERNANCE_ROLE) {
        // Validate fee values
        if (_minimalWithdrawalFee > MAX_FEE ||
            _smallWithdrawalFee > MAX_FEE ||
            _mediumWithdrawalFee > MAX_FEE ||
            _largeWithdrawalFee > MAX_FEE ||
            _earlyWithdrawalFee > MAX_FEE) {
            revert InvalidParameter("fee", _largeWithdrawalFee);
        }
        
        minimalWithdrawalFee = _minimalWithdrawalFee;
        smallWithdrawalFee = _smallWithdrawalFee;
        mediumWithdrawalFee = _mediumWithdrawalFee;
        largeWithdrawalFee = _largeWithdrawalFee;
        earlyWithdrawalFee = _earlyWithdrawalFee;
        
        emit FeesUpdated(_minimalWithdrawalFee, _smallWithdrawalFee, _mediumWithdrawalFee, _largeWithdrawalFee, _earlyWithdrawalFee);
    }
    
    /**
     * @notice Update time constraints
     * @param _minHoldingPeriod Minimum holding period
     * @param _liquidityRemovalCooldown Cooldown between liquidity removals
     */
    function updateTimeConstraints(
        uint256 _minHoldingPeriod,
        uint256 _liquidityRemovalCooldown
    ) external onlyRole(GOVERNANCE_ROLE) {
        minHoldingPeriod = _minHoldingPeriod;
        liquidityRemovalCooldown = _liquidityRemovalCooldown;
        
        emit TimeConstraintsUpdated(_minHoldingPeriod, _liquidityRemovalCooldown);
    }
    
    /**
     * @notice Update withdrawal limits
     * @param _dailyWithdrawalLimit Daily withdrawal limit (in basis points)
     * @param _weeklyWithdrawalLimit Weekly withdrawal limit (in basis points)
     */
    function updateWithdrawalLimits(
        uint256 _dailyWithdrawalLimit,
        uint256 _weeklyWithdrawalLimit
    ) external onlyRole(GOVERNANCE_ROLE) {
        // Validate limits
        if (_dailyWithdrawalLimit > PERCENTAGE_DENOMINATOR) {
            revert InvalidParameter("dailyWithdrawalLimit", _dailyWithdrawalLimit);
        }
        if (_weeklyWithdrawalLimit > PERCENTAGE_DENOMINATOR) {
            revert InvalidParameter("weeklyWithdrawalLimit", _weeklyWithdrawalLimit);
        }
        if (_weeklyWithdrawalLimit < _dailyWithdrawalLimit) {
            revert InvalidParameter("weeklyWithdrawalLimit", _weeklyWithdrawalLimit);
        }
        
        dailyWithdrawalLimit = _dailyWithdrawalLimit;
        weeklyWithdrawalLimit = _weeklyWithdrawalLimit;
        
        emit WithdrawalLimitsUpdated(_dailyWithdrawalLimit, _weeklyWithdrawalLimit);
    }
    
    /**
     * @notice Update TWAP settings
     * @param _twapInterval TWAP observation interval
     * @param _maxTwapDeviation Maximum allowed deviation from TWAP
     */
    function updateTwapSettings(
        uint32 _twapInterval,
        uint256 _maxTwapDeviation
    ) external onlyRole(GOVERNANCE_ROLE) {
        // Validate parameters
        if (_twapInterval < 60 || _twapInterval > 48 hours) {
            revert InvalidParameter("twapInterval", _twapInterval);
        }
        if (_maxTwapDeviation > PERCENTAGE_DENOMINATOR) {
            revert InvalidParameter("maxTwapDeviation", _maxTwapDeviation);
        }
        
        twapInterval = _twapInterval;
        maxTwapDeviation = _maxTwapDeviation;
        
        emit TwapSettingsUpdated(_twapInterval, _maxTwapDeviation);
    }
    
    /**
     * @notice Update vesting settings
     * @param _vestingUnlockRate Weekly vesting unlock rate (in basis points)
     */
    function updateVestingSettings(uint256 _vestingUnlockRate) external onlyRole(GOVERNANCE_ROLE) {
        // Validate parameters
        if (_vestingUnlockRate == 0 || _vestingUnlockRate > 5000) {
            revert InvalidParameter("vestingUnlockRate", _vestingUnlockRate);
        }
        
        vestingUnlockRate = _vestingUnlockRate;
        
        emit VestingSettingsUpdated(_vestingUnlockRate);
    }
    
    /**
     * @notice Update liquidity injection parameters
     * @param _reinjectionThreshold Minimum amount for reinserting liquidity
     * @param _slippageTolerance Maximum slippage tolerance for injections
     */
    function updateInjectionSettings(
        uint256 _reinjectionThreshold,
        uint8 _slippageTolerance
    ) external onlyRole(GOVERNANCE_ROLE) {
        // Validate parameters
        if (_slippageTolerance > 100) {
            revert InvalidParameter("slippageTolerance", _slippageTolerance);
        }
        
        reinjectionThreshold = _reinjectionThreshold;
        slippageTolerance = _slippageTolerance;
        
        emit InjectionSettingsUpdated(_reinjectionThreshold, _slippageTolerance);
    }
    
    /**
     * @notice Emergency withdraw stuck tokens
     * @param token Token address (zero address for ETH)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(
        address token, 
        address to, 
        uint256 amount
    ) external onlyRole(EMERGENCY_ROLE) {
        if (token == address(0)) {
            (bool success, ) = to.call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        
        emit EmergencyWithdrawal(token, to, amount);
    }
    
    /**
     * @notice Set treasury address
     * @param _treasury New treasury address
     */
    function setTreasury(address _treasury) external onlyRole(GOVERNANCE_ROLE) {
        require(_treasury != address(0), "Treasury cannot be zero address");
        treasury = ITreasury(_treasury);
        emit TreasuryUpdated(_treasury);
    }
    
    /**
     * @notice Set reward distributor address
     * @param _rewardDistributor New reward distributor address
     */
    function setRewardDistributor(address _rewardDistributor) external onlyRole(GOVERNANCE_ROLE) {
        require(_rewardDistributor != address(0), "Reward distributor cannot be zero address");
        rewardDistributor = IRewardDistributor(_rewardDistributor);
        emit RewardDistributorUpdated(_rewardDistributor);
    }
    
    /**
     * @notice Pause the contract
     */
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyRole(GOVERNANCE_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Returns a list of all active position IDs
     * @return Array of active position IDs
     */
    function getActivePositions() external view returns (uint256[] memory) {
        return activePositionIds;
    }
    
    /**
     * @notice Get user liquidity and vesting information
     * @param user User address
     * @return totalLiquidity Total user liquidity
     * @return vestingStart User vesting start timestamp
     * @return availableToWithdraw Amount available to withdraw based on vesting
     */
    function getUserInfo(address user) external view returns (
        uint256 totalLiquidity,
        uint256 vestingStart,
        uint256 availableToWithdraw
    ) {
        totalLiquidity = userLiquidity[user];
        vestingStart = userVestingStart[user];
        
        uint256 timeSinceVestingStart = block.timestamp - vestingStart;
        uint256 weeksVested = timeSinceVestingStart / ONE_WEEK;
        uint256 unlockedPercentage = (weeksVested * vestingUnlockRate);
        if (unlockedPercentage > 100) unlockedPercentage = 100;
        
        availableToWithdraw = (totalLiquidity * unlockedPercentage) / PERCENTAGE_DENOMINATOR;
    }
    
    /**
     * @notice Get user withdrawal limits
     * @param user User address
     * @return dailyLimit Daily withdrawal limit
     * @return dailyUsed Amount used from daily limit
     * @return weeklyLimit Weekly withdrawal limit
     * @return weeklyUsed Amount used from weekly limit
     * @return nextAllowedWithdrawalTime Timestamp when next withdrawal is allowed
     */
    function getUserWithdrawalLimits(address user) external view returns (
        uint256 dailyLimit,
        uint256 dailyUsed,
        uint256 weeklyLimit,
        uint256 weeklyUsed,
        uint256 nextAllowedWithdrawalTime
    ) {
        uint256 userTotalLiquidity = userLiquidity[user];
        dailyLimit = (userTotalLiquidity * dailyWithdrawalLimit) / PERCENTAGE_DENOMINATOR;
        weeklyLimit = (userTotalLiquidity * weeklyWithdrawalLimit) / PERCENTAGE_DENOMINATOR;
        
        // Check if daily limit has reset
        if (lastDailyWithdrawal[user] + ONE_DAY < block.timestamp) {
            dailyUsed = 0;
        } else {
            dailyUsed = dailyWithdrawalAmount[user];
        }
        
        // Check if weekly limit has reset
        if (lastWeeklyWithdrawal[user] + ONE_WEEK < block.timestamp) {
            weeklyUsed = 0;
        } else {
            weeklyUsed = weeklyWithdrawalAmount[user];
        }
        
        // Calculate next allowed withdrawal time
        nextAllowedWithdrawalTime = lastLiquidityRemoval[user] + liquidityRemovalCooldown;
        if (nextAllowedWithdrawalTime < block.timestamp) {
            nextAllowedWithdrawalTime = block.timestamp;
        }
    }
    
    /**
     * @notice Get statistics about the liquidity guard
     * @return totalStaked Total staked tokens
     * @return totalUsers Number of users
     * @return totalWithdrawals Number of withdrawals
     * @return largeWithdrawals Number of large withdrawals
     * @return totalFees Total fees collected
     */
    function getStats() external view returns (
        uint256 totalStaked,
        uint256 totalUsers,
        uint256 totalWithdrawals,
        uint256 largeWithdrawals,
        uint256 totalFees
    ) {
        totalStaked = totalLiquidity;
        totalUsers = userCount;
        totalWithdrawals = totalWithdrawalCount;
        largeWithdrawals = largeWithdrawalCount;
        totalFees = totalFeesCollected;
    }
    
    /**
     * @notice Fallback function to receive ETH
     */
    receive() external payable {
        emit Received(msg.sender, msg.value);
    }
}
