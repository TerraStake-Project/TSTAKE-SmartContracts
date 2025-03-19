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
    
    function addConstituent(address asset, address priceFeed) external;
    function deactivateConstituent(address asset) external;
    function getActiveConstituents() external view returns (address[] memory activeAssets);

    // ===============================
    // Neural Weight Management
    // ===============================
    
    function updateNeuralWeight(
        address asset,
        uint256 newRawSignal,
        uint256 smoothingFactor
    ) external;
    
    function batchUpdateNeuralWeights(
        address[] calldata assets,
        uint256[] calldata newRawSignals,
        uint256[] calldata smoothingFactors
    ) external;

    // ===============================
    // Diversity Index Management
    // ===============================
    
    function recalculateDiversityIndex() external;

    // ===============================
    // Chainlink Integration
    // ===============================
    
    function fetchLatestPrice(address asset) external returns (uint256);
    function getLatestPrice(address asset) external view returns (uint256 price, bool isFresh);
    function updatePriceFeedAddress(address asset, address newPriceFeed) external;

    // ===============================
    // Rebalancing Logic
    // ===============================
    
    function shouldAdaptiveRebalance() external view returns (bool shouldRebalance, string memory reason);
    function triggerAdaptiveRebalance() external;
    function updateGeneticVolatility(uint256 newVolatility) external;

    // ===============================
    // Chainlink Keeper Methods
    // ===============================
    
    function checkUpkeep(bytes calldata checkData) external view override returns (bool upkeepNeeded, bytes memory performData);
    function performUpkeep(bytes calldata performData) external override;
    function manualKeeper() external;

    // ===============================
    // Configuration Management
    // ===============================
    
    function setRebalanceInterval(uint256 newInterval) external;
    function setVolatilityThreshold(uint256 newThreshold) external;
    function setMaxPriceDeviation(uint256 newDeviation) external;
    function setRequiredApprovals(uint256 newRequiredApprovals) external;
    function setOperationTimelock(uint256 newTimelock) external;

    // ===============================
    // Multi-signature Functionality
    // ===============================
    
    function approveOperation(bytes32 operationId) external;
    function revokeApproval(bytes32 operationId) external;
    function scheduleOperation(bytes32 operationId) external;
    function getOperationId(string calldata action, bytes calldata data) external view returns (bytes32);

    // ===============================
    // Emergency & Safety Controls
    // ===============================
    
    function pause() external;
    function unpause() external;
    function emergencyResetWeights() external;
    function clearPriceDeviationAlert(address asset) external;
}
