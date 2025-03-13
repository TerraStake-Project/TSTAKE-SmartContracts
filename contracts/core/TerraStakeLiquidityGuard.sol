// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "../interfaces/ITerraStakeRewardDistributor.sol";
import "../interfaces/ITerraStakeTreasuryManager.sol";

/**
 * @title TerraStakeLiquidityGuard
 * @notice Manages liquidity for the TerraStake protocol
 * @dev Protects against liquidity attacks, implements anti-whale mechanisms
 */
contract TerraStakeLiquidityGuard is
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    // -------------------------------------------
    //  Roles
    // -------------------------------------------
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    // -------------------------------------------
    //  Constants
    // -------------------------------------------
    uint256 public constant ONE_DAY = 1 days;
    uint256 public constant ONE_WEEK = 7 days;
    uint256 public constant PERCENTAGE_DENOMINATOR = 100;
    uint256 public constant DEFAULT_SLIPPAGE_TOLERANCE = 50; // 0.5%
    uint24 public constant DEFAULT_POOL_FEE = 3000; // 0.3%
    // -------------------------------------------
    //  Errors
    // -------------------------------------------
    error InvalidZeroAddress(string param);
    error InvalidParameter(string param, uint256 value);
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error DailyLiquidityLimitExceeded(uint256 requested, uint256 available);
    error WeeklyLiquidityLimitExceeded(uint256 requested, uint256 available);
    error LiquidityCooldownNotMet(uint256 remainingTime);
    error TooEarlyToWithdraw(uint256 available, uint256 requested);
    error TWAPVerificationFailed(uint256 currentPrice, uint256 twapPrice);
    error PositionNotFound(uint256 tokenId);
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
        uint256 tokenId,
        uint128 liquidity
    );
    event PositionLiquidityDecreased(
        uint256 indexed tokenId,
        uint128 liquidityReduced,
        uint256 token0Amount,
        uint256 token1Amount
    );
    event PositionClosed(uint256 indexed tokenId);
    event PositionFeesCollected(
        uint256 indexed tokenId,
        uint256 token0Fee,
        uint256 token1Fee
    );
    event ParameterUpdated(string paramName, uint256 value);
    event EmergencyModeActivated(address activator);
    event EmergencyModeDeactivated(address deactivator);
    event RewardsReinvested(uint256 rewardAmount, uint256 liquidityAdded);
    event TWAPVerificationFailedEvent(uint256 currentPrice, uint256 twapPrice);
    event WhitelistStatusChanged(address user, bool status);
    // -------------------------------------------
    //  State Variables
    // -------------------------------------------
    
    // Core protocol tokens and contracts
    IERC20 public tStakeToken;
    IERC20 public usdcToken;
    INonfungiblePositionManager public positionManager;
    IUniswapV3Pool public uniswapPool;
    address public treasury;
    ITerraStakeRewardDistributor public rewardDistributor;
    
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
        
        tStakeToken = IERC20(_tStakeToken);
        usdcToken = IERC20(_usdcToken);
        positionManager = INonfungiblePositionManager(_positionManager);
        uniswapPool = IUniswapV3Pool(_uniswapPool);
        
        if (_rewardDistributor != address(0)) {
            rewardDistributor = ITerraStakeRewardDistributor(_rewardDistributor);
        }
        
        if (_treasury != address(0)) {
            treasury = _treasury;
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
                emit TWAPVerificationFailedEvent(price, twap);
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
     * @notice Inject liquidity into Uniswap V3 pool
     * @param tStakeAmount Amount of TStake tokens to inject
     * @param usdcAmount Amount of USDC tokens to inject
     * @param tickLower Lower tick boundary for position
     * @param tickUpper Upper tick boundary for position
     * @return tokenId ID of the newly created position
     */
    function injectLiquidity(
        uint256 tStakeAmount,
        uint256 usdcAmount,
        int24 tickLower,
        int24 tickUpper
    ) external nonReentrant onlyRole(OPERATOR_ROLE) returns (uint256 tokenId) {
        if (emergencyMode) revert EmergencyModeActive();
        if (tStakeAmount == 0 || usdcAmount == 0) revert InvalidParameter("amounts", 0);
        
        // Approve tokens for position manager
        tStakeToken.approve(address(positionManager), tStakeAmount);
        usdcToken.approve(address(positionManager), usdcAmount);
        
        // Create the position parameters
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(tStakeToken),
            token1: address(usdcToken),
            fee: DEFAULT_POOL_FEE,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: tStakeAmount,
            amount1Desired: usdcAmount,
            amount0Min: tStakeAmount * (10000 - slippageTolerance) / 10000,
            amount1Min: usdcAmount * (10000 - slippageTolerance) / 10000,
            recipient: address(this),
            deadline: block.timestamp + 15 minutes
        });
        
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        // Mint the position - fixed by removing type declarations
        (tokenId, liquidity, amount0, amount1) = positionManager.mint(params);
        
        // Add to active positions
        if (!isPositionActive[tokenId]) {
            activePositions.push(tokenId);
            isPositionActive[tokenId] = true;
        }
        
        // Check for refunds of unused tokens
        if (amount0 < tStakeAmount) {
            tStakeToken.approve(address(positionManager), 0);
        }
        if (amount1 < usdcAmount) {
            usdcToken.approve(address(positionManager), 0);
        }
        
        emit LiquidityInjected(amount0, amount1, tokenId, liquidity);
        
        return tokenId;
    }
    
    /**
     * @notice Collect fees from a Uniswap V3 position
     * @param tokenId The ID of the position
     * @return amount0 Amount of token0 collected
     * @return amount1 Amount of token1 collected
     */
    function collectPositionFees(uint256 tokenId) 
        external 
        nonReentrant 
        onlyRole(OPERATOR_ROLE) 
        returns (uint256 amount0, uint256 amount1) 
    {
        if (!isPositionActive[tokenId]) revert PositionNotFound(tokenId);
        
        // Collect all available fees
        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        
        (amount0, amount1) = positionManager.collect(params);
        
        emit PositionFeesCollected(tokenId, amount0, amount1);
        
        return (amount0, amount1);
    }
    
    /**
     * @notice Decrease liquidity in a position
     * @param tokenId The ID of the position
     * @param liquidityPercentage Percentage of liquidity to decrease (1-100)
     * @return amount0 Amount of token0 received
     * @return amount1 Amount of token1 received
     */
    function decreasePositionLiquidity(uint256 tokenId, uint256 liquidityPercentage)
        external
        nonReentrant
        onlyRole(OPERATOR_ROLE)
        returns (uint256 amount0, uint256 amount1)
    {
        if (!isPositionActive[tokenId]) revert PositionNotFound(tokenId);
        if (liquidityPercentage == 0 || liquidityPercentage > 100)
            revert InvalidParameter("liquidityPercentage", liquidityPercentage);
        
        // Get position info
        (, , , , , , , uint128 liquidity, , , , ) = positionManager.positions(tokenId);
        uint128 liquidityToRemove = uint128((uint256(liquidity) * liquidityPercentage) / 100);
        
        if (liquidityToRemove == 0) revert InvalidParameter("liquidityToRemove", 0);
        
        // Prepare decrease liquidity params
        INonfungiblePositionManager.DecreaseLiquidityParams memory params = 
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidityToRemove,
                amount0Min: 0, // We'll collect anyway
                amount1Min: 0, // We'll collect anyway
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
        
        (amount0, amount1) = positionManager.collect(collectParams);
        
        emit PositionLiquidityDecreased(tokenId, liquidityToRemove, amount0, amount1);
        
        return (amount0, amount1);
    }
    
    /**
     * @notice Close a position completely
     * @param tokenId The ID of the position
     * @return amount0 Amount of token0 received
     * @return amount1 Amount of token1 received
     */
    function closePosition(uint256 tokenId)
        external
        nonReentrant
        onlyRole(OPERATOR_ROLE)
        returns (uint256 amount0, uint256 amount1)
    {
        if (!isPositionActive[tokenId]) revert PositionNotFound(tokenId);
        
        // Get position info
        (, , , , , , , uint128 liquidity, , , , ) = positionManager.positions(tokenId);
        
        if (liquidity > 0) {
            // First decrease all liquidity
            INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams = 
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp + 15 minutes
                });
            
            positionManager.decreaseLiquidity(decreaseParams);
        }
        
        // Collect all tokens
        INonfungiblePositionManager.CollectParams memory collectParams = 
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });
        
        (amount0, amount1) = positionManager.collect(collectParams);
        
        // Burn the position
        positionManager.burn(tokenId);
        
        // Remove from active positions
        removePositionFromActive(tokenId);
        
        emit PositionClosed(tokenId);
        
        return (amount0, amount1);
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
        uint256 rewardAmount = rewardDistributor.claimRewards(address(this));
        
        if (rewardAmount < reinjectionThreshold) {
            revert InvalidParameter("rewardAmount", rewardAmount);
        }
        
        // Calculate auto-liquidity portion
        uint256 liquidityPortion = (rewardAmount * autoLiquidityInjectionRate) / 100;
        
        // Get equivalent USDC from Treasury
        if (address(treasury) != address(0) && liquidityPortion > 0) {
            uint256 usdcAmount = treasury.withdrawUSDCEquivalent(liquidityPortion);
            
            if (usdcAmount > 0) {
                // Approve tokens
                tStakeToken.safeApprove(address(positionManager), liquidityPortion);
                usdcToken.safeApprove(address(positionManager), usdcAmount);
                
                // Create the position
                INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
                    token0: address(tStakeToken),
                    token1: address(usdcToken),
                    fee: DEFAULT_POOL_FEE,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    amount0Desired: liquidityPortion,
                    amount1Desired: usdcAmount,
                    amount0Min: liquidityPortion * (10000 - slippageTolerance) / 10000,
                    amount1Min: usdcAmount * (10000 - slippageTolerance) / 10000,
                    recipient: address(this),
                    deadline: block.timestamp + 15 minutes
                });
                
                uint256 tokenId;
                uint128 liquidity;
                // Fixed by removing type declarations
                (tokenId, liquidity, , ) = positionManager.mint(params);
                
                // Add to active positions
                if (!isPositionActive[tokenId]) {
                    activePositions.push(tokenId);
                    isPositionActive[tokenId] = true;
                }
                
                emit RewardsReinvested(rewardAmount, liquidityPortion);
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
     * @notice Verify TWAP price before withdrawal
     * @return valid True if TWAP price is valid
     */
    function verifyTWAPForWithdrawal() external view returns (bool) {

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
                int56 timeChange = int56(secondsAgo);
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
        return 1.0001 ** uint256(int256(tick));
    }
    
    // -------------------------------------------
    //  Helper Functions
    // -------------------------------------------
    
    /**
     * @notice Remove a position from the active positions array
     * @param tokenId The token ID to remove
     */
    function removePositionFromActive(uint256 tokenId) internal {
        if (!isPositionActive[tokenId]) return;
        
        // Find and remove the position from the array
        for (uint256 i = 0; i < activePositions.length; i++) {
            if (activePositions[i] == tokenId) {
                // Replace with the last element and pop
                activePositions[i] = activePositions[activePositions.length - 1];
                activePositions.pop();
                isPositionActive[tokenId] = false;
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

    /**
     * @notice Get the address of the Uniswap V3 pool
     * @return pool Address of the Uniswap V3 pool
     */
    function getLiquidityPool() external view returns (address) {
        return address(uniswapPool);
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
     * @notice Update TWAP maximum deviation percentage
     * @param newDeviation New maximum deviation percentage
     */
    function setTWAPDeviationPercentage(uint256 newDeviation) external onlyRole(GOVERNANCE_ROLE) {
        if (newDeviation > 50) revert InvalidParameter("newDeviation", newDeviation);
        twapDeviationPercentage = newDeviation;
        emit ParameterUpdated("twapDeviationPercentage", newDeviation);
    }
    
    /**
     * @notice Set whitelist status for an address
     * @param user Address to update
     * @param status New whitelist status
     */
    function setWhitelistStatus(address user, bool status) external onlyRole(GOVERNANCE_ROLE) {
        liquidityWhitelist[user] = status;
        emit WhitelistStatusChanged(user, status);
    }
    
    /**
     * @notice Batch set whitelist status for multiple addresses
     * @param users Addresses to update
     * @param statuses New whitelist statuses
     */
    function batchSetWhitelistStatus(address[] calldata users, bool[] calldata statuses) external onlyRole(GOVERNANCE_ROLE) {
        if (users.length != statuses.length) revert InvalidParameter("arrays length mismatch", users.length);
        
        for (uint256 i = 0; i < users.length; i++) {
            liquidityWhitelist[users[i]] = statuses[i];
            emit WhitelistStatusChanged(users[i], statuses[i]);
        }
    }
    
    /**
     * @notice Update reward distributor address
     * @param newDistributor Address of the new reward distributor
     */
    function setRewardDistributor(address newDistributor) external onlyRole(GOVERNANCE_ROLE) {
        if (newDistributor == address(0)) revert InvalidZeroAddress("newDistributor");
        rewardDistributor = ITerraStakeRewardDistributor(newDistributor);
    }
    
    /**
     * @notice Update treasury address
     * @param newTreasury Address of the new treasury
     */
    function setTreasury(address newTreasury) external onlyRole(GOVERNANCE_ROLE) {
        if (newTreasury == address(0)) revert InvalidZeroAddress("newTreasury");
        treasury = newTreasury;
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
     * @param tokenId ID of the position to withdraw from
     */
    function emergencyWithdrawPosition(uint256 tokenId) external onlyRole(EMERGENCY_ROLE) {
        if (!emergencyMode) revert EmergencyModeNotActive();
        if (!isPositionActive[tokenId]) revert PositionNotFound(tokenId);
        
        // Get position info
        (, , , , , , , uint128 liquidity, , , , ) = positionManager.positions(tokenId);
        
        if (liquidity > 0) {
            // First decrease all liquidity
            INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams = 
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp + 15 minutes
                });
            
            positionManager.decreaseLiquidity(decreaseParams);
        }
        
        // Collect all tokens
        INonfungiblePositionManager.CollectParams memory collectParams = 
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });
        
        positionManager.collect(collectParams);
        
        // Remove from active positions
        removePositionFromActive(tokenId);
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
}
        