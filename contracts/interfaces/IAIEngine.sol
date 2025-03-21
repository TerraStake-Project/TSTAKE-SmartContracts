// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";

/**
 * @title IAIEngine 
 * @notice Interface for the AIEngine contract
 * @dev Defines all external functions and events of the AIEngine contract
 */
interface IAIEngine is AutomationCompatibleInterface {
    // ===============================
    // Structs
    // ===============================
    
    struct NeuralWeight {
        uint256 currentWeight;
        uint256 rawSignal;
        uint256 lastUpdateTime;
        uint256 emaSmoothingFactor;
    }

    struct Constituent {
        bool isActive;
        uint256 activationTime;
        uint256 evolutionScore;
        uint256 index;
        uint256 lastPrice;
        uint256 lastPriceUpdateTime;
    }

    // ===============================
    // Events
    // ===============================
    
    event NeuralWeightUpdated(address indexed asset, uint256 weight, uint256 rawSignal, uint256 smoothingFactor);
    event DiversityIndexUpdated(uint256 newIndex);
    event AdaptiveRebalanceTriggered(string reason, uint256 timestamp);
    event ConstituentAdded(address indexed asset, uint256 timestamp);
    event ConstituentDeactivated(address indexed asset, uint256 timestamp);
    event OperationApproved(bytes32 indexed operationId, address indexed approver, uint256 currentApprovals);
    event OperationScheduled(bytes32 indexed operationId, uint256 executionTime);
    event ConfigUpdated(string parameter, uint256 newValue);
    event PriceUpdated(address indexed asset, uint256 price, uint256 timestamp);
    event CircuitBreaker(address indexed asset, uint256 oldPrice, uint256 newPrice, uint256 deviation);

    // ===============================
    // Constants
    // ===============================
    
    function MAX_SIGNAL_VALUE() external view returns (uint256);
    function MAX_EMA_SMOOTHING() external view returns (uint256);
    function DEFAULT_REBALANCE_INTERVAL() external view returns (uint256);
    function MIN_DIVERSITY_INDEX() external view returns (uint256);
    function MAX_DIVERSITY_INDEX() external view returns (uint256);
    function MAX_PRICE_STALENESS() external view returns (uint256);
    function MAX_PRICE_DEVIATION() external view returns (uint256);
    function MAX_TIMELOCK() external view returns (uint256);

    // ===============================
    // Role Management
    // ===============================
    
    function AI_ADMIN_ROLE() external view returns (bytes32);
    function EMERGENCY_ROLE() external view returns (bytes32);
    function UPGRADER_ROLE() external view returns (bytes32);
    function KEEPER_ROLE() external view returns (bytes32);

    // ===============================
    // State Variables
    // ===============================
    
    function assetNeuralWeights(address asset) external view returns (NeuralWeight memory);
    function constituents(address asset) external view returns (Constituent memory);
    function constituentList(uint256 index) external view returns (address);
    function activeConstituentCount() external view returns (uint256);
    function diversityIndex() external view returns (uint256);
    function geneticVolatility() external view returns (uint256);
    function rebalanceInterval() external view returns (uint256);
    function lastRebalanceTime() external view returns (uint256);
    function adaptiveVolatilityThreshold() external view returns (uint256);
    function requiredApprovals() external view returns (uint256);
    function operationApprovals(bytes32 operationId) external view returns (uint256);
    function hasApproved(bytes32 operationId, address account) external view returns (bool);
    function operationTimelock() external view returns (uint256);
    function operationScheduledTime(bytes32 operationId) external view returns (uint256);
    function maxPriceDeviation() external view returns (uint256);
    function priceFeeds(address asset) external view returns (address);

    // ===============================
    // Constituent Management
    // ===============================
    
    /**
     * @notice Adds a new constituent asset to the portfolio
     * @param asset Address of the asset token
     * @param priceFeed Address of the Chainlink price feed for the asset
     */
    function addConstituent(address asset, address priceFeed) external;
    
    /**
     * @notice Deactivates a constituent asset
     * @param asset Address of the asset to deactivate
     */
    function deactivateConstituent(address asset) external;
    
    /**
     * @notice Returns array of all active constituents
     * @return activeAssets Array of active constituent addresses
     */
    function getActiveConstituents() external view returns (address[] memory activeAssets);

    // ===============================
    // Neural Weight Management
    // ===============================
    
    /**
     * @notice Updates neural weight for a specific asset
     * @param asset Address of the asset
     * @param newRawSignal Raw signal value from neural network
     * @param smoothingFactor EMA smoothing factor (1-100)
     */
    function updateNeuralWeight(
        address asset,
        uint256 newRawSignal,
        uint256 smoothingFactor
    ) external;
    
    /**
     * @notice Updates neural weights for multiple assets at once
     * @param assets Array of asset addresses
     * @param newRawSignals Array of raw signal values
     * @param smoothingFactors Array of EMA smoothing factors
     */
    function batchUpdateNeuralWeights(
        address[] calldata assets,
        uint256[] calldata newRawSignals,
        uint256[] calldata smoothingFactors
    ) external;

    // ===============================
    // Diversity Index Management
    // ===============================
    
    /**
     * @notice Manually triggers diversity index recalculation
     */
    function recalculateDiversityIndex() external;

    // ===============================
    // Chainlink Integration
    // ===============================
    
    /**
     * @notice Fetches the latest price from the Chainlink price feed
     * @param asset Address of the asset to fetch price for
     * @return The latest price of the asset
     */
    function fetchLatestPrice(address asset) external returns (uint256);
    
    /**
     * @notice Gets the latest price without writing to state
     * @param asset Address of the asset
     * @return price The asset price
     * @return isFresh Whether the price data is fresh
     */
    function getLatestPrice(address asset) external view returns (uint256 price, bool isFresh);
    
    /**
     * @notice Updates the price feed address for an asset
     * @param asset Address of the asset
     * @param newPriceFeed Address of the new price feed
     */
    function updatePriceFeedAddress(address asset, address newPriceFeed) external;

    // ===============================
    // Rebalancing Logic
    // ===============================
    
    /**
     * @notice Determines if a rebalance should be triggered
     * @return shouldRebalance Whether rebalance is needed
     * @return reason Human-readable reason for rebalance
     */
    function shouldAdaptiveRebalance() external view returns (bool shouldRebalance, string memory reason);
    
    /**
     * @notice Manually triggers an adaptive rebalance
     */
    function triggerAdaptiveRebalance() external;
    
    /**
     * @notice Updates genetic volatility metric and handles potential rebalancing
     * @param newVolatility New volatility value
     */
    function updateGeneticVolatility(uint256 newVolatility) external;

    // ===============================
    // Chainlink Keeper Methods
    // ===============================
    
    /**
     * @notice Chainlink Automation compatible checkUpkeep function
     * @param checkData Arbitrary data passed from caller
     * @return upkeepNeeded Whether upkeep is needed
     * @return performData Data to be used by performUpkeep
     */
    function checkUpkeep(bytes calldata checkData) external view override returns (bool upkeepNeeded, bytes memory performData);
    
    /**
     * @notice Chainlink Automation compatible performUpkeep function
     * @param performData Data from checkUpkeep that determines actions
     */
    function performUpkeep(bytes calldata performData) external override;
    
    /**
     * @notice Manual trigger for the keeper functions
     */
    function manualKeeper() external;

    // ===============================
    // Configuration Management
    // ===============================
    
    /**
     * @notice Updates the rebalance interval
     * @param newInterval New interval in seconds
     */
    function setRebalanceInterval(uint256 newInterval) external;
    
    /**
     * @notice Sets the volatility threshold for adaptive rebalancing
     * @param newThreshold New threshold value
     */
    function setVolatilityThreshold(uint256 newThreshold) external;
    
    /**
     * @notice Sets the maximum allowed price deviation before requiring approvals
     * @param newDeviation New deviation percentage in basis points (100 = 1%)
     */
    function setMaxPriceDeviation(uint256 newDeviation) external;
    
    /**
     * @notice Sets the number of approvals required for sensitive operations
     * @param newRequiredApprovals New number of required approvals
     */
    function setRequiredApprovals(uint256 newRequiredApprovals) external;
    
    /**
     * @notice Sets the timelock duration for sensitive operations
     * @param newTimelock New timelock duration in seconds
     */
    function setOperationTimelock(uint256 newTimelock) external;

    // ===============================
    // Multi-signature Functionality
    // ===============================
    
    /**
     * @notice Approves a pending operation
     * @param operationId Unique identifier for the operation
     */
    function approveOperation(bytes32 operationId) external;
    
    /**
     * @notice Revokes approval for a pending operation
     * @param operationId Unique identifier for the operation
     */
    function revokeApproval(bytes32 operationId) external;
    
    /**
     * @notice Schedules an operation for execution after timelock
     * @param operationId Unique identifier for the operation
     */
    function scheduleOperation(bytes32 operationId) external;
    
    /**
     * @notice Generates a unique operation ID based on action and data
     * @param action String description of the action
     * @param data Additional data for the operation
     * @return operationId Unique identifier for the operation
     */
    function getOperationId(string calldata action, bytes calldata data) external view returns (bytes32);

    // ===============================
    // Emergency & Safety Controls
    // ===============================
    
    /**
     * @notice Pauses all non-view functions
     */
    function pause() external;
    
    /**
     * @notice Unpauses the contract
     */
    function unpause() external;
    
    /**
     * @notice Emergency function to reset all neural weights
     */
    function emergencyResetWeights() external;
    
    /**
     * @notice Emergency function to clear a specific price deviation alert
     * @param asset Address of the asset with price deviation
     */
    function clearPriceDeviationAlert(address asset) external;
}
