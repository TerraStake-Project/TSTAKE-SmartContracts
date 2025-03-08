// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
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
            
        (uint256 collected0, uint256 collected1) = positionManager.collect(collectParams);
        
        // Add the collected amounts
        amount0 += collected0;
        amount1 += collected1;
        
        // Remove from active positions
        for (uint i = 0; i < activePositionIds.length; i++) {
            if (activePositionIds[i] == tokenId) {
                // Replace with last element and pop
                activePositionIds[i] = activePositionIds[activePositionIds.length - 1];
                activePositionIds.pop();
                break;
            }
        }
        
        // Update tracking
        managedPositions[tokenId] = false;
        
        emit UniswapPositionClosed(tokenId, amount0, amount1);
    }
    
    /**
     * @notice Calculate the withdrawal fee based on withdrawal size
     * @param user Address of the user withdrawing liquidity
     * @param amount Amount of tokens being withdrawn
     * @return fee The calculated fee amount
     */
    function getWithdrawalFee(address user, uint256 amount) public view returns (uint256) {
        if (liquidityWhitelist[user]) {
            return 0; // Whitelisted users pay no fees
        }
        
        uint256 totalLiquidity = userLiquidity[user];
        uint256 withdrawalPercentage = (amount * PERCENTAGE_DENOMINATOR) / totalLiquidity;
        
        // Progressive fee structure based on withdrawal size
        if (withdrawalPercentage > 50) {
            // >50% withdrawal: base fee + large withdrawal penalty
            return (amount * (baseFeePercentage + largeLiquidityFeeIncrease)) / PERCENTAGE_DENOMINATOR;
        } else if (withdrawalPercentage > 25) {
            // 25-50% withdrawal: mid-tier fee
            return (amount * (baseFeePercentage + 3)) / PERCENTAGE_DENOMINATOR; // +3% for medium withdrawals
        }
        
        // <25% withdrawal: base fee only
        return (amount * baseFeePercentage) / PERCENTAGE_DENOMINATOR;
    }
    
    /**
     * @notice Find the best position to increase liquidity based on current price
     * @param currentTick Current pool tick
     * @return tokenId ID of the best position to increase
     */
    function findBestPositionToIncrease(int24 currentTick) internal view returns (uint256) {
        uint256 bestTokenId;
        int24 bestTickDistance = type(int24).max;
        
        for (uint i = 0; i < activePositionIds.length; i++) {
            uint256 tokenId = activePositionIds[i];
            
            // Get position info
            (
                ,
                ,
                ,
                ,
                ,
                int24 tickLower,
                int24 tickUpper,
                ,
                ,
                ,
                ,
            ) = positionManager.positions(tokenId);
            
            // Calculate how centered the current tick is within position range
            int24 midTick = (tickLower + tickUpper) / 2;
            int24 tickDistance = abs(midTick - currentTick);
            
            // Check if position contains current tick and is better than current best
            if (tickLower <= currentTick && currentTick <= tickUpper && tickDistance < bestTickDistance) {
                bestTickDistance = tickDistance;
                bestTokenId = tokenId;
            }
        }
        
        // If no suitable position found, return the first active position
        if (bestTokenId == 0 && activePositionIds.length > 0) {
            return activePositionIds[0];
        }
        
        return bestTokenId;
    }
    
    /**
     * @notice Helper function to get absolute value of int24
     * @param x Input value
     * @return y Absolute value
     */
    function abs(int24 x) internal pure returns (int24) {
        return x >= 0 ? x : -x;
    }
    
    // -------------------------------------------
    // 🔹 TWAP Price Validation
    // -------------------------------------------
    
    /**
     * @notice Validate current price against TWAP to prevent flash crash exploitation
     * @return valid Whether the current price is within allowed deviation from TWAP
     */
    function validateTWAPPrice() public view returns (bool) {
        (uint160 sqrtPriceX96,,,,,,) = uniswapPool.slot0();
        uint256 currentPrice = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> (96 * 2);
        uint256 twapPrice = calculateTWAP();
        
        // Prevent division by zero
        if (twapPrice == 0) return false;
        
        // Price must be within tolerance range of TWAP
        uint256 lowerBound = (twapPrice * (PERCENTAGE_DENOMINATOR - TWAP_PRICE_TOLERANCE)) / PERCENTAGE_DENOMINATOR;
        uint256 upperBound = (twapPrice * (PERCENTAGE_DENOMINATOR + TWAP_PRICE_TOLERANCE)) / PERCENTAGE_DENOMINATOR;
        
        return (currentPrice >= lowerBound && currentPrice <= upperBound);
    }
    
    /**
     * @notice Calculate time-weighted average price from Uniswap pool
     * @return twapPrice The calculated TWAP value
     */
    function calculateTWAP() public view returns (uint256) {
        uint256[] memory secondsAgos = new uint256[](twapObservationTimeframes.length * 2);
        
        // Set up observation points for each timeframe
        for (uint i = 0; i < twapObservationTimeframes.length; i++) {
            secondsAgos[i*2] = twapObservationTimeframes[i];
            secondsAgos[i*2+1] = 0; // Current observation
        }
        
        // Get observations from Uniswap pool
        (int56[] memory tickCumulatives, ) = uniswapPool.observe(secondsAgos);
        
        uint256 weightedTickSum = 0;
        uint256 totalWeight = 0;
        
        // Calculate TWAP for each timeframe
        for (uint i = 0; i < twapObservationTimeframes.length; i++) {
            uint32 timeframe = twapObservationTimeframes[i];
            int56 tickCumulativeStart = tickCumulatives[i*2];
            int56 tickCumulativeEnd = tickCumulatives[i*2+1];
            
            // Calculate average tick
            int56 tickDiff = tickCumulativeEnd - tickCumulativeStart;
            int24 avgTick = int24(tickDiff / int56(uint56(timeframe)));
            
            // Convert tick to price (1.0001^tick)
            uint256 price = calculatePriceFromTick(avgTick);
            uint256 weight = timeframe;
            
            weightedTickSum += price * weight;
            totalWeight += weight;
        }
        
        return totalWeight > 0 ? weightedTickSum / totalWeight : 0;
    }
    
    /**
     * @notice Convert tick to price
     * @param tick The tick value
     * @return price The price calculated from tick
     */
    function calculatePriceFromTick(int24 tick) internal pure returns (uint256) {
        // Real implementation would use more precise math
        // This is a simplified version that approximates 1.0001^tick
        
        if (tick == 0) return 1e18; // 1.0
        
        int256 t = int256(tick);
        int256 base = 1.0001 * 1e18; // 1.0001 scaled to 1e18
        bool isPositive = t > 0;
        
        if (!isPositive) {
            t = -t; // Make positive for calculation
        }
        
        // Calculate base^tick using repeated multiplication
        uint256 result = 1e18; // Start with 1.0 scaled to 1e18
        
        for (int256 i = 0; i < t; i++) {
            result = (result * base) / 1e18;
        }
        
        if (isPositive) {
            return result;
        } else {
            return (1e36 / result); // Invert result for negative ticks
        }
    }
    
    // -------------------------------------------
    // 🔹 Governance-Controlled Adjustments
    // -------------------------------------------
    
    /**
     * @notice Update liquidity withdrawal parameters with enhanced validation
     * @param newDailyLimit New daily withdrawal limit percentage
     * @param newWeeklyLimit New weekly withdrawal limit percentage
     * @param newVestingRate New vesting unlock rate percentage per week
     * @param newBaseFee New base fee percentage for withdrawals
     */
    function updateLiquidityParameters(
        uint256 newDailyLimit,
        uint256 newWeeklyLimit,
        uint256 newVestingRate,
        uint256 newBaseFee
    ) external onlyRole(GOVERNANCE_ROLE) {
        // Upper bound validation
        if (newDailyLimit > 20) revert InvalidParameter("newDailyLimit", newDailyLimit);
        if (newWeeklyLimit > 50) revert InvalidParameter("newWeeklyLimit", newWeeklyLimit);
        if (newVestingRate > 20) revert InvalidParameter("newVestingRate", newVestingRate);
        if (newBaseFee > 5) revert InvalidParameter("newBaseFee", newBaseFee);
        
        // Lower bound validation
        if (newDailyLimit < 1) revert InvalidParameter("newDailyLimit", newDailyLimit);
        if (newWeeklyLimit < newDailyLimit) revert InvalidParameter("newWeeklyLimit", newWeeklyLimit);
        if (newVestingRate == 0) revert InvalidParameter("newVestingRate", newVestingRate);
        
        // Logical consistency validation
        if (newWeeklyLimit < 7 * newDailyLimit) {
            emit WeeklyLimitBelowRecommended(newWeeklyLimit, 7 * newDailyLimit);
        }
        
        dailyWithdrawalLimit = newDailyLimit;
        weeklyWithdrawalLimit = newWeeklyLimit;
        vestingUnlockRate = newVestingRate;
        baseFeePercentage = newBaseFee;
        
        emit LiquidityParametersUpdated(
            newDailyLimit,
            newWeeklyLimit,
            newVestingRate,
            newBaseFee
        );
    }
    
    /**
     * @notice Update the large withdrawal fee increase
     * @param newFeeIncrease New fee increase percentage for large withdrawals
     */
    function updateLargeLiquidityFeeIncrease(uint256 newFeeIncrease) external onlyRole(GOVERNANCE_ROLE) {
        if (newFeeIncrease + baseFeePercentage > MAX_FEE_PERCENTAGE) 
            revert InvalidParameter("newFeeIncrease", newFeeIncrease);
        
        largeLiquidityFeeIncrease = newFeeIncrease;
    }
    
    /**
     * @notice Update the liquidity injection rate
     * @param newRate New automatic liquidity injection rate
     */
    function updateLiquidityInjectionRate(uint256 newRate) external onlyRole(GOVERNANCE_ROLE) {
        if (newRate > 10) revert InvalidParameter("newRate", newRate);
        
        autoLiquidityInjectionRate = newRate;
        emit LiquidityInjectionRateUpdated(newRate);
    }
    
    /**
     * @notice Update the maximum liquidity cap per address
     * @param newCap New maximum liquidity cap per address
     */
    function updateLiquidityCap(uint256 newCap) external onlyRole(GOVERNANCE_ROLE) {
        maxLiquidityPerAddress = newCap;
        emit LiquidityCapUpdated(newCap);
    }
    
    /**
     * @notice Update the liquidity reinjection threshold
     * @param newThreshold New minimum threshold for liquidity reinjection
     */
    function updateReinjectionThreshold(uint256 newThreshold) external onlyRole(GOVERNANCE_ROLE) {
        reinjectionThreshold = newThreshold;
        emit LiquidityReinjectionThresholdUpdated(newThreshold);
    }
    
    /**
     * @notice Update the liquidity removal cooldown period
     * @param newCooldown New cooldown period in seconds
     */
    function updateRemovalCooldown(uint256 newCooldown) external onlyRole(GOVERNANCE_ROLE) {
        if (newCooldown > 30 days) revert InvalidParameter("newCooldown", newCooldown);
        liquidityRemovalCooldown = newCooldown;
    }
    
    /**
     * @notice Update TWAP observation timeframes
     * @param newTimeframes New array of TWAP observation timeframes in seconds
     */
    function updateTWAPTimeframes(uint32[] calldata newTimeframes) external onlyRole(GOVERNANCE_ROLE) {
        if (newTimeframes.length == 0) revert InvalidParameter("newTimeframes", 0);
        if (newTimeframes.length > 10) revert InvalidParameter("newTimeframes", newTimeframes.length);
        
        twapObservationTimeframes = newTimeframes;
    }
    
    /**
     * @notice Update slippage tolerance for liquidity operations
     * @param newTolerance New slippage tolerance percentage (1-50)
     */
    function updateSlippageTolerance(uint256 newTolerance) external onlyRole(GOVERNANCE_ROLE) {
        if (newTolerance < 1 || newTolerance > 50) 
            revert InvalidParameter("newTolerance", newTolerance);
        
        uint256 oldTolerance = slippageTolerance;
        slippageTolerance = newTolerance;
        
        emit SlippageToleranceUpdated(oldTolerance, newTolerance);
    }
    
    /**
     * @notice Update reward distributor address
     * @param newDistributor New reward distributor address
     */
    function updateRewardDistributor(address newDistributor) external onlyRole(GOVERNANCE_ROLE) {
        if (newDistributor == address(0)) revert InvalidZeroAddress("newDistributor");
        
        address oldDistributor = address(rewardDistributor);
        rewardDistributor = ITerraStakeRewardDistributor(newDistributor);
        
        emit RewardDistributorUpdated(oldDistributor, newDistributor);
    }
    
    /**
     * @notice Update treasury address
     * @param newTreasury New treasury address
     */
    function updateTreasury(address newTreasury) external onlyRole(GOVERNANCE_ROLE) {
        if (newTreasury == address(0)) revert InvalidZeroAddress("newTreasury");
        
        address oldTreasury = address(treasury);
        treasury = ITerraStakeTreasury(newTreasury);
        
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }
    
    // -------------------------------------------
    // 🔹 Emergency Controls
    // -------------------------------------------
    
    /**
     * @notice Enable or disable emergency mode to halt withdrawals
     * @param enabled Whether to enable emergency mode
     */
    function setEmergencyMode(bool enabled) external onlyRole(EMERGENCY_ROLE) {
        emergencyMode = enabled;
        emit EmergencyModeChanged(enabled);
    }
    
    /**
     * @notice Emergency token recovery for stuck tokens (not tStake or USDC)
     * @param token Token address to recover
     * @param amount Amount to recover
     */
    function recoverTokens(address token, uint256 amount) external onlyRole(GOVERNANCE_ROLE) {
        // Cannot withdraw tStake or USDC tokens using this method
        if (token == address(tStakeToken) || token == address(usdcToken)) {
            revert Unauthorized();
        }
        
        IERC20Upgradeable(token).safeTransfer(msg.sender, amount);
    }
    
    /**
     * @notice Add or remove address from whitelist to bypass withdrawal restrictions
     * @param user User address to modify
     * @param status Whether user should be whitelisted
     */
    function setWhitelistStatus(address user, bool status) external onlyRole(GOVERNANCE_ROLE) {
        liquidityWhitelist[user] = status;
        emit AddressWhitelisted(user, status);
    }
    
    // -------------------------------------------
    // 🔹 View Functions
    // -------------------------------------------
    
    /**
     * @notice Get user's liquidity information
     * @param user Address of the user
     * @return liquidity User's liquidity amount
     * @return vestingStart User's vesting start timestamp
     * @return lastRemoval Last time user removed liquidity
     */
    function getUserLiquidityInfo(address user) external view returns (
        uint256 liquidity,
        uint256 vestingStart,
        uint256 lastRemoval
    ) {
        return (
            userLiquidity[user],
            userVestingStart[user],
            lastLiquidityRemoval[user]
        );
    }
    
    /**
     * @notice Get user's daily and weekly withdrawal information
     * @param user Address of the user
     * @return dailyAmount Amount withdrawn today
     * @return dailyLimit Maximum daily withdrawal limit
     * @return weeklyAmount Amount withdrawn this week
     * @return weeklyLimit Maximum weekly withdrawal limit
     */
    function getUserWithdrawalInfo(address user) external view returns (
        uint256 dailyAmount,
        uint256 dailyLimit,
        uint256 weeklyAmount,
        uint256 weeklyLimit
    ) {
        uint256 userTotal = userLiquidity[user];
        
        return (
            dailyWithdrawalAmount[user],
            (userTotal * dailyWithdrawalLimit) / PERCENTAGE_DENOMINATOR,
            weeklyWithdrawalAmount[user],
            (userTotal * weeklyWithdrawalLimit) / PERCENTAGE_DENOMINATOR
        );
    }
    
    /**
     * @notice Calculate the maximum amount a user can withdraw right now
     * @param user Address of the user to check
     * @return amount Maximum amount that can be withdrawn
     */
    function getAvailableWithdrawalAmount(address user) external view returns (uint256) {
        if (emergencyMode) return 0;
        
        // Check total liquidity
        uint256 totalLiquidity = userLiquidity[user];
        if (totalLiquidity == 0) return 0;
        
        // Check vesting unlock
        uint256 timeSinceVestingStart = block.timestamp - userVestingStart[user];
        uint256 weeksVested = timeSinceVestingStart / ONE_WEEK;
        uint256 unlockedPercentage = (weeksVested * vestingUnlockRate);
        if (unlockedPercentage > 100) unlockedPercentage = 100;
        
        uint256 unlockedAmount = (totalLiquidity * unlockedPercentage) / PERCENTAGE_DENOMINATOR;
        
        // Check daily limit
        uint256 dailyLimit = (totalLiquidity * dailyWithdrawalLimit) / PERCENTAGE_DENOMINATOR;
        uint256 availableDailyAmount = dailyLimit;
        
        if (lastDailyWithdrawal[user] + ONE_DAY > block.timestamp) {
            availableDailyAmount = dailyLimit - dailyWithdrawalAmount[user];
        }
        
        // Check weekly limit
        uint256 weeklyLimit = (totalLiquidity * weeklyWithdrawalLimit) / PERCENTAGE_DENOMINATOR;
        uint256 availableWeeklyAmount = weeklyLimit;
        
        if (lastWeeklyWithdrawal[user] + ONE_WEEK > block.timestamp) {
            availableWeeklyAmount = weeklyLimit - weeklyWithdrawalAmount[user];
        }
        
        // Return the minimum of all constraints
        return min3(unlockedAmount, availableDailyAmount, availableWeeklyAmount);
    }
    
    /**
     * @notice Get the minimum of three values
     * @param a First value
     * @param b Second value
     * @param c Third value
     * @return minimum The minimum of the three values
     */
    function min3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return a < b ? (a < c ? a : c) : (b < c ? b : c);
    }
    
    /**
     * @notice Get all active position IDs
     * @return positions Array of active position IDs
     */
    function getActivePositions() external view returns (uint256[] memory) {
        return activePositionIds;
    }
    
    /**
     * @notice Get current TWAP price and current spot price
     * @return twapPrice The current TWAP price
     * @return spotPrice The current spot price
     */
    function getCurrentPrices() external view returns (uint256 twapPrice, uint256 spotPrice) {
        (uint160 sqrtPriceX96,,,,,,) = uniswapPool.slot0();
        spotPrice = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> (96 * 2);
        twapPrice = calculateTWAP();
    }
    
    /**
     * @notice Check if withdrawals would be allowed based on current price conditions
     * @return allowed Whether withdrawals are currently allowed
     */
    function areWithdrawalsAllowed() external view returns (bool) {
        if (emergencyMode) return false;
        return validateTWAPPrice();
    }
    
    /**
     * @notice Get analytics data about the liquidity guard
     * @return totalLiquidity Total current liquidity across all users
     * @return totalInjected Total liquidity injected to Uniswap
     * @return totalFees Total fees collected
     * @return withdrawalStats Statistics about withdrawals (total, large)
     */
    function getAnalytics() external view returns (
        uint256 totalLiquidity,
        uint256 totalInjected,
        uint256 totalFees,
        uint256[2] memory withdrawalStats
    ) {
        withdrawalStats[0] = totalWithdrawalCount;
        withdrawalStats[1] = largeWithdrawalCount;
        
        return (
            tStakeToken.balanceOf(address(this)),
            totalLiquidityInjected,
            totalFeesCollected,
            withdrawalStats
        );
    }
    
    /**
     * @notice Get contract version
     * @return version Contract version string
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}
