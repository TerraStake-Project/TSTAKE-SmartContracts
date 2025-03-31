// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v4-core/contracts/interfaces/IUniswapV4Pool.sol";
import "@uniswap/v4-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v4-periphery/contracts/interfaces/IQuoter.sol";

import "../interfaces/ITerraStakeTreasuryManager.sol";
import "../interfaces/ITerraStakeGovernance.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";
import "../interfaces/ITerraStakeAIBridge.sol";

/**
 * @title TerraStakeTreasuryManager
 * @author TerraStake Protocol
 * @notice Manages treasury functions, buybacks, liquidity, and fund distribution
 * @dev Integrated with AI Bridge for intelligent treasury management
 */
contract TerraStakeTreasuryManager is 
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    ITerraStakeTreasuryManager
{
    // ===============================
    // Roles
    // ===============================
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant AI_EXECUTOR_ROLE = keccak256("AI_EXECUTOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // ===============================
    // Protocol Integrations
    // ===============================
    ITerraStakeGovernance public governance;
    ITerraStakeLiquidityGuard public liquidityGuard;
    ITerraStakeAIBridge public aiBridge;
    ISwapRouter public uniswapRouter;
    IQuoter public uniswapQuoter;

    IERC20 public tStakeToken;
    IERC20 public usdcToken;

    uint24 public constant POOL_FEE = 3000; // UniswapV4 pool fee
    uint256 public constant MIN_BUYBACK_AMOUNT = 1000 * 1e6; // 1000 USDC minimum
    uint256 public constant MAX_SLIPPAGE_BASIS = 500; // 5% max slippage

    bool public paused;

    // ===============================
    // Treasury Allocation Parameters
    // ===============================
    struct TreasuryAllocation {
        uint16 buybackPercentage;
        uint16 liquidityPercentage;
        uint16 burnPercentage;
        uint16 reservePercentage;
    }

    TreasuryAllocation public allocation;

    // ===============================
    // Market Parameters
    // ===============================
    struct MarketParameters {
        uint16 volatilityThreshold;
        uint16 slippageProtection;
        uint16 emergencyThreshold;
        uint16 maxSingleTxPercentage;
    }

    MarketParameters public marketParams;

    // ===============================
    // Treasury Metrics
    // ===============================
    struct TreasuryMetrics {
        uint256 totalBuybacks;
        uint256 totalBurned;
        uint256 totalLiquidity;
        uint256 lastActionTimestamp;
        uint256 treasuryValue;
    }

    TreasuryMetrics public metrics;

    // ===============================
    // Action Queue for Delayed Execution
    // ===============================
    struct QueuedAction {
        bytes32 actionType;
        uint256 amount;
        uint256 executionTime;
        bytes data;
        bool executed;
    }

    mapping(uint256 => QueuedAction) public actionQueue;
    uint256 public actionQueueCount;
    uint256 public pendingActionCount;

    // ===============================
    // Events
    // ===============================
    event BuybackExecuted(uint256 usdcSpent, uint256 tStakeBought, uint16 volatilityIndex);
    event LiquidityAdded(uint256 tStakeAmount, uint256 usdcAmount);
    event TokensBurned(uint256 amount);
    event TreasuryTransfer(address token, address recipient, uint256 amount);
    event AllocationUpdated(uint16 buyback, uint16 liquidity, uint16 burn, uint16 reserve);
    event MarketParamsUpdated(uint16 volatilityThreshold, uint16 slippageProtection, uint16 emergencyThreshold, uint16 maxSingleTxPercentage);
    event PauseToggled(bool paused);
    event ReserveAllocated(uint256 amount);
    event AIRecommendationApplied(bytes32 indexed actionType, uint256 amount, uint16 confidence);
    event EmergencyActionExecuted(bytes32 indexed actionType, address indexed executor);
    event ActionQueued(uint256 indexed actionId, bytes32 indexed actionType, uint256 amount, uint256 executionTime);
    event ActionExecuted(uint256 indexed actionId, bytes32 indexed actionType, uint256 amount);
    event ActionCanceled(uint256 indexed actionId);
    event AIBridgeUpdated(address indexed newAIBridge);

    // ===============================
    // Modifiers
    // ===============================
    modifier onlyGovernance() {
        if (!hasRole(GOVERNANCE_ROLE, msg.sender) && msg.sender != address(governance)) 
            revert TerraStakeErrors.Unauthorized(msg.sender, GOVERNANCE_ROLE);
        _;
    }

    modifier onlyAI() {
        if (!hasRole(AI_EXECUTOR_ROLE, msg.sender) && msg.sender != address(aiBridge)) 
            revert TerraStakeErrors.Unauthorized(msg.sender, AI_EXECUTOR_ROLE);
        _;
    }

    modifier onlyEmergency() {
        if (!hasRole(EMERGENCY_ROLE, msg.sender)) 
            revert TerraStakeErrors.Unauthorized(msg.sender, EMERGENCY_ROLE);
        _;
    }

    modifier whenNotPaused() {
        if (paused) 
            revert TerraStakeErrors.OperationPaused("TreasuryManager");
        _;
    }

    // ===============================
    // Initialization
    // ===============================
    function initialize(
        address _governance,
        address _liquidityGuard,
        address _aiBridge,
        address _tStakeToken,
        address _usdcToken,
        address _uniswapRouter,
        address _uniswapQuoter
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        if (_governance == address(0) || _liquidityGuard == address(0) || 
            _aiBridge == address(0) || _tStakeToken == address(0) || 
            _usdcToken == address(0) || _uniswapRouter == address(0) || 
            _uniswapQuoter == address(0)) {
            revert TerraStakeErrors.InvalidParameters();
        }

        governance = ITerraStakeGovernance(_governance);
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);
        aiBridge = ITerraStakeAIBridge(_aiBridge);
        tStakeToken = IERC20(_tStakeToken);
        usdcToken = IERC20(_usdcToken);
        uniswapRouter = ISwapRouter(_uniswapRouter);
        uniswapQuoter = IQuoter(_uniswapQuoter);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(AI_EXECUTOR_ROLE, _aiBridge);
    }

    // ===============================
    // Treasury Management Functions
    // ===============================

    /**
     * @notice Executes a token buyback with volatility-adjusted parameters
     * @param usdcAmount Amount of USDC to spend on buyback
     */
    function executeBuyback(uint256 usdcAmount) external onlyGovernance whenNotPaused nonReentrant {
        if (usdcAmount < MIN_BUYBACK_AMOUNT) 
            revert TerraStakeErrors.InsufficientAmount(usdcAmount, MIN_BUYBACK_AMOUNT);
        if (usdcToken.balanceOf(address(this)) < usdcAmount) 
            revert TerraStakeErrors.InsufficientBalance(msg.sender, address(usdcToken), usdcAmount, usdcToken.balanceOf(address(this)));

        // Get AI-driven market insights
        uint16 volatilityIndex = aiBridge.getVolatilityIndex();
        (uint16 sentiment, , , uint16 confidence) = aiBridge.getMarketInsights();

        // Calculate dynamic allocation based on market conditions
        uint256 buybackAllocation;
        if (volatilityIndex > marketParams.emergencyThreshold) {
            // Emergency conditions - minimal buyback (10%)
            buybackAllocation = usdcAmount * 10 / 100;
        } else if (volatilityIndex > marketParams.volatilityThreshold) {
            // High volatility - reduced buyback (30%)
            buybackAllocation = usdcAmount * 30 / 100;
        } else if (sentiment > 7000 && confidence > 8000) {
            // Strong positive sentiment - increased buyback (80%)
            buybackAllocation = usdcAmount * 80 / 100;
        } else {
            // Normal conditions - standard buyback (60%)
            buybackAllocation = usdcAmount * 60 / 100;
        }

        // Calculate dynamic slippage protection
        uint256 slippageBasis = calculateDynamicSlippage(volatilityIndex, confidence);
        uint256 minTStakeOut = calculateMinimumOutput(buybackAllocation, slippageBasis);

        // Execute buyback
        usdcToken.approve(address(uniswapRouter), buybackAllocation);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(usdcToken),
            tokenOut: address(tStakeToken),
            fee: POOL_FEE,
            recipient: address(this),
            deadline: block.timestamp + 15 minutes,
            amountIn: buybackAllocation,
            amountOutMinimum: minTStakeOut,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = uniswapRouter.exactInputSingle(params);

        // Update metrics
        metrics.totalBuybacks += buybackAllocation;
        metrics.lastActionTimestamp = block.timestamp;
        metrics.treasuryValue = calculateTreasuryValue();

        emit BuybackExecuted(buybackAllocation, amountOut, volatilityIndex);
    }

    /**
     * @notice Calculates dynamic slippage based on market conditions
     * @param volatilityIndex Current volatility index from AI Bridge
     * @param confidence AI confidence level in market insights
     * @return slippageBasis Slippage in basis points (e.g., 200 = 2%)
     */
    function calculateDynamicSlippage(uint16 volatilityIndex, uint16 confidence) internal view returns (uint256 slippageBasis) {
        // Base slippage from market params
        slippageBasis = marketParams.slippageProtection;

        // Adjust for volatility
        if (volatilityIndex > marketParams.emergencyThreshold) {
            slippageBasis += 300; // Additional 3% for emergency
        } else if (volatilityIndex > marketParams.volatilityThreshold) {
            slippageBasis += 150; // Additional 1.5% for high volatility
        }

        // Adjust for confidence level
        if (confidence < 7000) {
            slippageBasis += (7000 - confidence) / 20; // 0.05% per 100 confidence under 7000
        }

        // Cap at maximum allowed slippage
        return slippageBasis > MAX_SLIPPAGE_BASIS ? MAX_SLIPPAGE_BASIS : slippageBasis;
    }

    /**
     * @notice Calculates minimum expected output with slippage protection
     * @param usdcAmount Amount of USDC to swap
     * @param slippageBasis Slippage in basis points
     * @return minOutput Minimum expected tStake tokens
     */
    function calculateMinimumOutput(uint256 usdcAmount, uint256 slippageBasis) internal view returns (uint256 minOutput) {
        uint256 expectedOutput = quoteBuyback(usdcAmount);
        minOutput = expectedOutput * (10000 - slippageBasis) / 10000;
    }

    /**
     * @notice Adds liquidity to the protocol
     * @param usdcAmount Amount of USDC to add as liquidity
     */
    function addLiquidity(uint256 usdcAmount) external whenNotPaused nonReentrant {
        if (usdcAmount == 0 || usdcToken.balanceOf(address(this)) < usdcAmount) 
            revert TerraStakeErrors.InsufficientBalance();

        uint256 tStakeAmount = (usdcAmount * 1e18) / getTokenPrice();
        tStakeToken.transfer(address(liquidityGuard), tStakeAmount);
        usdcToken.transfer(address(liquidityGuard), usdcAmount);
        liquidityGuard.addLiquidity(tStakeAmount, usdcAmount);

        metrics.totalLiquidity += usdcAmount;
        metrics.lastActionTimestamp = block.timestamp;
        metrics.treasuryValue = calculateTreasuryValue();

        emit LiquidityAdded(tStakeAmount, usdcAmount);
    }

    /**
     * @notice Burns tStake tokens from the treasury
     * @param amount Amount of tStake tokens to burn
     */
    function burnTokens(uint256 amount) public onlyGovernance whenNotPaused nonReentrant {
        if (amount == 0 || tStakeToken.balanceOf(address(this)) < amount) 
            revert TerraStakeErrors.InsufficientBalance();

        tStakeToken.transfer(address(0xdead), amount);

        metrics.totalBurned += amount;
        metrics.lastActionTimestamp = block.timestamp;
        metrics.treasuryValue = calculateTreasuryValue();

        emit TokensBurned(amount);
    }

    /**
     * @notice Allocates USDC to reserves
     * @param amount Amount of USDC to allocate
     */
    function allocateToReserve(uint256 amount) public onlyGovernance whenNotPaused nonReentrant {
        if (amount == 0 || usdcToken.balanceOf(address(this)) < amount) 
            revert TerraStakeErrors.InsufficientBalance();

        // In this implementation, reserves are simply held in the contract
        // Could be extended to transfer to a separate reserve contract
        metrics.lastActionTimestamp = block.timestamp;
        metrics.treasuryValue = calculateTreasuryValue();

        emit ReserveAllocated(amount);
    }

    /**
     * @notice Transfers tokens from treasury to a recipient
     * @param token Token to transfer
     * @param recipient Address to receive tokens
     * @param amount Amount to transfer
     */
    function treasuryTransfer(address token, address recipient, uint256 amount) 
        external 
        onlyGovernance 
        whenNotPaused 
        nonReentrant 
    {
        if (amount == 0 || IERC20(token).balanceOf(address(this)) < amount) 
            revert TerraStakeErrors.InsufficientBalance();

        IERC20(token).transfer(recipient, amount);

        metrics.lastActionTimestamp = block.timestamp;
        metrics.treasuryValue = calculateTreasuryValue();

        emit TreasuryTransfer(token, recipient, amount);
    }

    /**
     * @notice Executes an AI-recommended treasury action
     * @param actionType Type of action (BUYBACK, LIQUIDITY, BURN, RESERVE)
     * @param amount Amount to use
     * @param confidence AI confidence level (basis points)
     */
    function executeAIRecommendedAction(
        bytes32 actionType, 
        uint256 amount, 
        uint16 confidence
    ) external onlyAI whenNotPaused nonReentrant {
        if (confidence < 7000) revert TerraStakeErrors.InsufficientConfidence();
        
        if (actionType == keccak256("BUYBACK")) {
            uint256 minTStakeOut = calculateMinimumOutput(amount, marketParams.slippageProtection);
            executeBuyback(amount, minTStakeOut);
        } else if (actionType == keccak256("LIQUIDITY")) {
            addLiquidity(amount);
        } else if (actionType == keccak256("BURN")) {
            uint256 tStakePrice = getTokenPrice();
            uint256 tStakeAmount = (amount * 1e18) / tStakePrice;
            burnTokens(tStakeAmount);
        } else if (actionType == keccak256("RESERVE")) {
            allocateToReserve(amount);
        } else {
            revert TerraStakeErrors.InvalidActionType();
        }
        
        emit AIRecommendationApplied(actionType, amount, confidence);
    }

    /**
     * @notice Gets a Uniswap price quote for a buyback
     * @param usdcAmount Amount of USDC to convert
     * @return Estimated tStake output
     */
    function quoteBuyback(uint256 usdcAmount) public view returns (uint256) {
        return uniswapQuoter.quoteExactInputSingle(
            address(usdcToken),
            address(tStakeToken),
            POOL_FEE,
            usdcAmount,
            0
        );
    }
    
    /**
     * @notice Gets the current tStake token price in USDC
     * @return Price of 1 tStake in USDC (with 18 decimals)
     */
    function getTokenPrice() public view returns (uint256) {
        return uniswapQuoter.quoteExactInputSingle(
            address(tStakeToken),
            address(usdcToken),
            POOL_FEE,
            1e18, // 1 tStake
            0
        );
    }

    /**
     * @notice Queue a treasury action for delayed execution
     * @param actionType Type of action
     * @param amount Amount to use
     * @param delay Delay before execution (in seconds)
     * @param data Additional data for the action
     * @return actionId ID of the queued action
     */
    function queueAction(
        bytes32 actionType,
        uint256 amount,
        uint256 delay,
        bytes memory data
    ) external onlyGovernance returns (uint256 actionId) {
        if (delay < 1 hours || delay > 7 days) revert TerraStakeErrors.InvalidDelay();
        
        actionId = ++actionQueueCount;
        
        actionQueue[actionId] = QueuedAction({
            actionType: actionType,
            amount: amount,
            executionTime: block.timestamp + delay,
            data: data,
            executed: false
        });
        
        pendingActionCount++;
        
        emit ActionQueued(actionId, actionType, amount, block.timestamp + delay);
        return actionId;
    }
    
    /**
     * @notice Execute a queued action
     * @param actionId ID of the action to execute
     */
    function executeQueuedAction(uint256 actionId) external nonReentrant {
        QueuedAction storage action = actionQueue[actionId];
        
        if (action.actionType == bytes32(0)) revert TerraStakeErrors.ActionDoesNotExist();
        if (action.executed) revert TerraStakeErrors.ActionAlreadyExecuted();
        if (block.timestamp < action.executionTime) revert TerraStakeErrors.ActionNotReady();
        
        action.executed = true;
        pendingActionCount--;
        
        if (action.actionType == keccak256("BUYBACK")) {
            uint256 minTStakeOut = abi.decode(action.data, (uint256));
            executeBuyback(action.amount, minTStakeOut);
        } else if (action.actionType == keccak256("LIQUIDITY")) {
            addLiquidity(action.amount);
        } else if (action.actionType == keccak256("BURN")) {
            burnTokens(action.amount);
        } else if (action.actionType == keccak256("RESERVE")) {
            allocateToReserve(action.amount);
        } else if (action.actionType == keccak256("TRANSFER")) {
            (address token, address recipient) = abi.decode(action.data, (address, address));
            treasuryTransfer(token, recipient, action.amount);
        } else {
            revert TerraStakeErrors.InvalidActionType();
        }
        
        emit ActionExecuted(actionId, action.actionType, action.amount);
    }
    
    /**
     * @notice Cancel a queued action
     * @param actionId ID of the action to cancel
     */
    function cancelQueuedAction(uint256 actionId) external onlyGovernance {
        QueuedAction storage action = actionQueue[actionId];
        
        if (action.actionType == bytes32(0)) revert TerraStakeErrors.ActionDoesNotExist();
        if (action.executed) revert TerraStakeErrors.ActionAlreadyExecuted();
        
        action.executed = true;
        pendingActionCount--;
        
        emit ActionCanceled(actionId);
    }

    /**
     * @notice Update treasury allocation parameters
     * @param buybackPercentage Percentage for buybacks
     * @param liquidityPercentage Percentage for liquidity
     * @param burnPercentage Percentage for burns
     * @param reservePercentage Percentage for reserves
     */
    function updateAllocation(
        uint16 buybackPercentage,
        uint16 liquidityPercentage,
        uint16 burnPercentage,
        uint16 reservePercentage
    ) external onlyGovernance {
        if (buybackPercentage + liquidityPercentage + burnPercentage + reservePercentage != 10000) {
            revert TerraStakeErrors.InvalidPercentages();
        }
        
        allocation = TreasuryAllocation({
            buybackPercentage: buybackPercentage,
            liquidityPercentage: liquidityPercentage,
            burnPercentage: burnPercentage,
            reservePercentage: reservePercentage
        });
        
        emit AllocationUpdated(buybackPercentage, liquidityPercentage, burnPercentage, reservePercentage);
    }
    
    /**
     * @notice Update market parameters
     * @param volatilityThreshold Threshold for high volatility
     * @param slippageProtection Default slippage protection
     * @param emergencyThreshold Threshold for emergency actions
     * @param maxSingleTxPercentage Maximum percentage for single transaction
     */
    function updateMarketParams(
        uint16 volatilityThreshold,
        uint16 slippageProtection,
        uint16 emergencyThreshold,
        uint16 maxSingleTxPercentage
    ) external onlyGovernance {
        if (slippageProtection > 2000 || maxSingleTxPercentage > 5000) {
            revert TerraStakeErrors.InvalidParameters();
        }
        
        marketParams = MarketParameters({
            volatilityThreshold: volatilityThreshold,
            slippageProtection: slippageProtection,
            emergencyThreshold: emergencyThreshold,
            maxSingleTxPercentage: maxSingleTxPercentage
        });
        
        emit MarketParamsUpdated(volatilityThreshold, slippageProtection, emergencyThreshold, maxSingleTxPercentage);
    }
    
    /**
     * @notice Execute emergency action in extreme market conditions
     * @param actionType Type of emergency action
     */
    function executeEmergencyAction(bytes32 actionType) external onlyEmergency {
        ( , uint16 volatility, , ) = aiBridge.getMarketInsights();
        
        if (volatility < marketParams.emergencyThreshold) {
            revert TerraStakeErrors.NotEmergencyCondition();
        }
        
        if (actionType == keccak256("PAUSE")) {
            paused = true;
            emit PauseToggled(true);
        } else if (actionType == keccak256("INCREASE_RESERVES")) {
            allocation.reservePercentage += allocation.buybackPercentage / 2;
            allocation.buybackPercentage /= 2;
            
            emit AllocationUpdated(
                allocation.buybackPercentage,
                allocation.liquidityPercentage,
                allocation.burnPercentage,
                allocation.reservePercentage
            );
        } else if (actionType == keccak256("INCREASE_SLIPPAGE")) {
            marketParams.slippageProtection *= 2;
            
            emit MarketParamsUpdated(
                marketParams.volatilityThreshold,
                marketParams.slippageProtection,
                marketParams.emergencyThreshold,
                marketParams.maxSingleTxPercentage
            );
        } else {
            revert TerraStakeErrors.InvalidActionType();
        }
        
        emit EmergencyActionExecuted(actionType, msg.sender);
    }

    /**
     * @notice Toggles the pause state of the contract
     * @param _paused True to pause, false to unpause
     */
    function togglePause(bool _paused) external onlyGovernance {
        paused = _paused;
        emit PauseToggled(_paused);
    }
    
    /**
     * @notice Update AI Bridge address
     * @param _aiBridge New AI Bridge address
     */
    function updateAIBridge(address _aiBridge) external onlyGovernance {
        if (_aiBridge == address(0)) revert TerraStakeErrors.InvalidParameters();
        
        _revokeRole(AI_EXECUTOR_ROLE, address(aiBridge));
        aiBridge = ITerraStakeAIBridge(_aiBridge);
        _grantRole(AI_EXECUTOR_ROLE, _aiBridge);
        
        emit AIBridgeUpdated(_aiBridge);
    }

    /**
     * @notice Checks if the contract is paused
     */
    function isPaused() external view returns (bool) {
        return paused;
    }
    
    /**
     * @notice Get treasury balances
     * @return tStakeBalance Balance of tStake tokens
     * @return usdcBalance Balance of USDC tokens
     * @return estimatedValueUSDC Estimated total value in USDC
     */
    function getTreasuryBalances() external view returns (
        uint256 tStakeBalance,
        uint256 usdcBalance,
        uint256 estimatedValueUSDC
    ) {
        tStakeBalance = tStakeToken.balanceOf(address(this));
        usdcBalance = usdcToken.balanceOf(address(this));
        
        uint256 tStakePrice = getTokenPrice();
        uint256 tStakeValueUSDC = (tStakeBalance * tStakePrice) / 1e18;
        
        estimatedValueUSDC = tStakeValueUSDC + usdcBalance;
        
        return (tStakeBalance, usdcBalance, estimatedValueUSDC);
    }
    
    /**
     * @notice Get allocation recommendation from AI Bridge
     * @return Recommended allocation percentages
     */
    function getAllocationRecommendation() external view returns (
        uint16 buybackPercentage,
        uint16 liquidityPercentage,
        uint16 burnPercentage,
        uint16 reservePercentage,
        uint16 confidence
    ) {
        (uint16 sentiment, uint16 volatility, uint16 trend, uint16 _confidence) = aiBridge.getMarketInsights();
        
        if (_confidence < 5000) {
            return (
                allocation.buybackPercentage,
                allocation.liquidityPercentage,
                allocation.burnPercentage,
                allocation.reservePercentage,
                _confidence
            );
        }
        
        if (volatility > marketParams.volatilityThreshold) {
            reservePercentage = allocation.reservePercentage + (volatility - marketParams.volatilityThreshold) / 10;
            reservePercentage = reservePercentage > 5000 ? 5000 : reservePercentage;
            
            buybackPercentage = allocation.buybackPercentage - (volatility - marketParams.volatilityThreshold) / 20;
            buybackPercentage = buybackPercentage < 1000 ? 1000 : buybackPercentage;
            
            if (sentiment < 4000) {
                burnPercentage = allocation.burnPercentage + 500;
                liquidityPercentage = 10000 - buybackPercentage - burnPercentage - reservePercentage;
            } else {
                liquidityPercentage = allocation.liquidityPercentage;
                burnPercentage = 10000 - buybackPercentage - liquidityPercentage - reservePercentage;
            }
        } else {
            if (trend > 6000) {
                buybackPercentage = allocation.buybackPercentage + 500;
                liquidityPercentage = allocation.liquidityPercentage + 500;
                burnPercentage = allocation.burnPercentage - 500;
                reservePercentage = 10000 - buybackPercentage - liquidityPercentage - burnPercentage;
            } else if (trend < 4000) {
                reservePercentage = allocation.reservePercentage + 500;
                burnPercentage = allocation.burnPercentage + 500;
                buybackPercentage = allocation.buybackPercentage - 500;
                liquidityPercentage = 10000 - buybackPercentage - burnPercentage - reservePercentage;
            } else {
                buybackPercentage = allocation.buybackPercentage;
                liquidityPercentage = allocation.liquidityPercentage;
                burnPercentage = allocation.burnPercentage;
                reservePercentage = allocation.reservePercentage;
            }
        }
        
        buybackPercentage = buybackPercentage < 500 ? 500 : buybackPercentage;
        liquidityPercentage = liquidityPercentage < 1000 ? 1000 : liquidityPercentage;
        burnPercentage = burnPercentage < 500 ? 500 : burnPercentage;
        reservePercentage = reservePercentage < 1000 ? 1000 : reservePercentage;
        
        uint16 total = buybackPercentage + liquidityPercentage + burnPercentage + reservePercentage;
        if (total != 10000) {
            reservePercentage = reservePercentage + (10000 - total);
        }
        
        return (buybackPercentage, liquidityPercentage, burnPercentage, reservePercentage, _confidence);
    }
    
    /**
     * @notice Apply AI-recommended allocation
     */
    function applyAIRecommendedAllocation() external onlyGovernance {
        (
            uint16 buybackPercentage,
            uint16 liquidityPercentage,
            uint16 burnPercentage,
            uint16 reservePercentage,
            uint16 confidence
        ) = getAllocationRecommendation();
        
        if (confidence < 7000) revert TerraStakeErrors.InsufficientConfidence();
        
        allocation = TreasuryAllocation({
            buybackPercentage: buybackPercentage,
            liquidityPercentage: liquidityPercentage,
            burnPercentage: burnPercentage,
            reservePercentage: reservePercentage
        });
        
        emit AllocationUpdated(buybackPercentage, liquidityPercentage, burnPercentage, reservePercentage);
    }
    
    /**
     * @notice Execute optimal treasury action based on AI recommendation
     * @param maxAmount Maximum amount to use (in USDC)
     */
    function executeOptimalAction(uint256 maxAmount) external onlyGovernance whenNotPaused nonReentrant {
        if (maxAmount == 0 || usdcToken.balanceOf(address(this)) < maxAmount) {
            revert TerraStakeErrors.InsufficientBalance();
        }
        
        (uint16 sentiment, uint16 volatility, uint16 trend, uint16 confidence) = aiBridge.getMarketInsights();
        
        if (confidence < 7000) revert TerraStakeErrors.InsufficientConfidence();
        
        bytes32 actionType;
        uint256 amount = maxAmount;
        
        if (volatility > marketParams.emergencyThreshold) {
            actionType = keccak256("RESERVE");
        } else if (volatility > marketParams.volatilityThreshold) {
            if (sentiment < 4000) {
                actionType = keccak256("BURN");
                uint256 tStakePrice = getTokenPrice();
                uint256 tStakeAmount = (amount * 1e18) / tStakePrice;
                
                if (tStakeToken.balanceOf(address(this)) < tStakeAmount) {
                    actionType = keccak256("RESERVE");
                } else {
                    amount = tStakeAmount;
                }
            } else {
                actionType = keccak256("LIQUIDITY");
                amount = maxAmount / 2;
            }
        } else {
            if (trend > 6000 && sentiment > 6000) {
                actionType = keccak256("BUYBACK");
            } else if (trend < 4000 && sentiment < 4000) {
                actionType = keccak256("BURN");
                uint256 tStakePrice = getTokenPrice();
                uint256 tStakeAmount = (amount * 1e18) / tStakePrice;
                
                if (tStakeToken.balanceOf(address(this)) < tStakeAmount) {
                    actionType = keccak256("RESERVE");
                } else {
                    amount = tStakeAmount;
                }
            } else {
                actionType = keccak256("LIQUIDITY");
            }
        }
        
        if (actionType == keccak256("BUYBACK")) {
            uint256 minTStakeOut = calculateMinimumOutput(amount, confidence);
            executeBuyback(amount, minTStakeOut);
        } else if (actionType == keccak256("LIQUIDITY")) {
            addLiquidity(amount);
        } else if (actionType == keccak256("BURN")) {
            burnTokens(amount);
        } else if (actionType == keccak256("RESERVE")) {
            allocateToReserve(amount);
        }
        
        emit AIRecommendationApplied(actionType, amount, confidence);
    }
    
    /**
     * @notice Distribute treasury funds according to allocation
     * @param amount Total USDC amount to distribute
     */
    function distributeTreasuryFunds(uint256 amount) external onlyGovernance whenNotPaused nonReentrant {
        if (amount == 0 || usdcToken.balanceOf(address(this)) < amount) {
            revert TerraStakeErrors.InsufficientBalance();
        }
        
        uint256 buybackAmount = (amount * allocation.buybackPercentage) / 10000;
        uint256 liquidityAmount = (amount * allocation.liquidityPercentage) / 10000;
        uint256 burnAmount = (amount * allocation.burnPercentage) / 10000;
        uint256 reserveAmount = amount - buybackAmount - liquidityAmount - burnAmount;
        
        if (buybackAmount > 0) {
            uint256 minTStakeOut = quoteBuyback(buybackAmount) * (10000 - marketParams.slippageProtection) / 10000;
            executeBuyback(buybackAmount, minTStakeOut);
        }
        
        if (liquidityAmount > 0) {
            addLiquidity(liquidityAmount);
        }
        
        if (burnAmount > 0) {
            uint256 tStakePrice = getTokenPrice();
            uint256 tStakeAmount = (burnAmount * 1e18) / tStakePrice;
            
            if (tStakeToken.balanceOf(address(this)) >= tStakeAmount) {
                burnTokens(tStakeAmount);
            } else {
                reserveAmount += burnAmount;
            }
        }
        
        if (reserveAmount > 0) {
            allocateToReserve(reserveAmount);
        }
    }

    /**
     * @notice Calculates total treasury value in USDC
     * @return value Total estimated value in USDC
     */
    function calculateTreasuryValue() internal view returns (uint256 value) {
        uint256 tStakeBalance = tStakeToken.balanceOf(address(this));
        uint256 usdcBalance = usdcToken.balanceOf(address(this));
        uint256 tStakeValue = (tStakeBalance * getTokenPrice()) / 1e18;
        return tStakeValue + usdcBalance;
    }
}