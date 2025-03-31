// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.21;

/**
 * @title ITerraStakeNeural
 * @notice Interface for TerraStake's neural network portfolio management system
 * @dev Complete interface matching the implementation with all events, errors and functions
 */
interface ITerraStakeNeural {
    // ===============================
    // Custom Errors
    // ===============================
    error InvalidConstituent(address asset);
    error InvalidSmoothingFactor(uint256 provided, uint256 maximum);
    error ConstituentLimitReached();
    error UnauthorizedCaller(address caller, bytes32 requiredRole);
    error ArrayLengthMismatch();
    error ZeroAddress();
    error InvalidParameters(string paramName, string reason);
    error InsufficientGeneticDiversity();
    error OperationPaused(string operation);
    error StalePriceData();
    error InvalidPriceFeed();
    error PriceDeviationTooHigh();

    // ===============================
    // Structs
    // ===============================
    struct NeuralWeight {
        uint256 currentWeight;
        uint256 rawSignal;
        uint256 lastUpdateTime;
        uint256 emaSmoothingFactor;
    }
    
    struct ConstituentData {
        bool isActive;
        uint256 activationTime;
        uint256 evolutionScore;
    }

    // ===============================
    // Events
    // ===============================
    event NeuralWeightUpdated(address indexed asset, uint256 weight, uint256 newRawSignal, uint256 smoothingFactor);
    event ConstituentAdded(address indexed asset, uint256 timestamp);
    event ConstituentRemoved(address indexed asset, uint256 timestamp);
    event DiversityIndexUpdated(uint256 newIndex);
    event AdaptiveRebalanceTriggered(string reason, uint256 timestamp);
    event SelfOptimizationExecuted(uint256 counter, uint256 timestamp);
    event AIEngineOperationExecuted(string operation, bool success);
    event AdaptiveThresholdUpdated(uint256 newThreshold);
    event ConfigUpdated(string parameter, uint256 value);
    event PriceUpdated(address indexed asset, uint256 price);
    // Enhanced events
    event TWAPPriceUpdated(uint256 newPrice, uint256 timestamp, string source);
    event PriceFeedUpdated(address indexed asset, address indexed priceFeed);
    event SyncFailed(string component, address indexed asset);
    event CircuitBreaker(string reason, uint256 lastPrice, uint256 currentPrice);
    event PriceDeviationDetected(uint256 deviation, uint256 oldPrice, uint256 newPrice);
    event ParameterUpdateScheduled(string parameter, uint256 newValue, uint256 effectiveTime);

    // ===============================
    // Constants
    // ===============================
    function MAX_SIGNAL_VALUE() external view returns (uint256);
    function MIN_CONSTITUENTS() external view returns (uint256);
    function MAX_EMA_SMOOTHING() external view returns (uint256);
    function DEFAULT_EMA_SMOOTHING() external view returns (uint256);
    function MIN_DIVERSITY_INDEX() external view returns (uint256);
    function MAX_DIVERSITY_INDEX() external view returns (uint256);
    function VOLATILITY_THRESHOLD() external view returns (uint256);
    function MAX_CONSTITUENTS() external view returns (uint256);
    function MAX_BATCH_SIZE() external view returns (uint256);
    function MAX_PRICE_STALENESS() external view returns (uint256);
    function PRICE_UPDATE_COOLDOWN() external view returns (uint256);
    function DEFAULT_REBALANCE_INTERVAL() external view returns (uint256);
    function MAX_VOLATILITY_THRESHOLD() external view returns (uint256);
    function MIN_VOLATILITY_THRESHOLD() external view returns (uint256);

    // ===============================
    // Roles
    // ===============================
    function ADMIN_ROLE() external view returns (bytes32);
    function NEURAL_INDEXER_ROLE() external view returns (bytes32);
    function AI_MANAGER_ROLE() external view returns (bytes32);
    function UPGRADER_ROLE() external view returns (bytes32);

    // ===============================
    // State Variables
    // ===============================
    function assetNeuralWeights(address) external view returns (
        uint256 currentWeight,
        uint256 rawSignal,
        uint256 lastUpdateTime,
        uint256 emaSmoothingFactor
    );
    
    function constituents(address) external view returns (
        bool isActive,
        uint256 activationTime,
        uint256 evolutionScore
    );
    
    function constituentList(uint256 index) external view returns (address);
    function diversityIndex() external view returns (uint256);
    function geneticVolatility() external view returns (uint256);
    function adaptiveVolatilityThreshold() external view returns (uint256);
    function rebalanceInterval() external view returns (uint256);
    function lastRebalanceTime() external view returns (uint256);
    function selfOptimizationCounter() external view returns (uint256);
    function lastAdaptiveLearningUpdate() external view returns (uint256);
    function rebalancingFrequencyTarget() external view returns (uint256);
    function lastTWAPPrice() external view returns (uint256);
    function lastPriceUpdateTime() external view returns (uint256);
    function aiEngine() external view returns (address);
    function useAIEngine() external view returns (bool);
    function syncWithAIEngine() external view returns (bool);
    // New state variables for time lock
    function operationTimestamps(bytes32 operationId) external view returns (uint256);
    function MIN_DELAY() external view returns (uint256);

    // ===============================
    // Configuration Functions
    // ===============================
    function setAIEngine(address _aiEngine) external;
    function toggleAIEngine(bool _useAIEngine) external;
    function toggleSyncWithAIEngine(bool _syncWithAIEngine) external;
    function setRebalanceInterval(uint256 _rebalanceInterval) external;
    function setVolatilityThreshold(uint256 _threshold) external;
    function updatePriceFeed(address asset, address priceFeed) external;
    
    // New time lock functions
    function scheduleParameterUpdate(string memory parameter, uint256 newValue) external;
    function executeParameterUpdate(string memory parameter, uint256 newValue) external;

    // ===============================
    // Constituent Management
    // ===============================
    function addConstituent(address asset, uint256 initialWeight) external;
    function addConstituentWithPriceFeed(
        address asset,
        uint256 initialWeight,
        address priceFeed
    ) external;
    function removeConstituent(address asset) external;
    function getActiveConstituents() external view returns (address[] memory);
    // New function
    function getConstituentData(address asset) external view returns (
        bool isActive,
        uint256 activationTime,
        uint256 evolutionScore,
        address priceFeed
    );

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
    // Evolution & Scoring
    // ===============================
    function updateEvolutionScore(address asset, uint256 newScore) external;
    function getEvolutionScore(address asset) external view returns (uint256);

    // ===============================
    // Rebalancing Logic
    // ===============================
    function shouldAdaptiveRebalance() external view returns (bool, string memory);
    function triggerAdaptiveRebalance() external returns (string memory);
    function executeSelfOptimization() external;
    // New function
    function getRebalanceStatus() external view returns (
        bool needed,
        string memory reason,
        uint256 nextPossible
    );

    // ===============================
    // Price Data Management
    // ===============================
    function fetchAIPriceData() external;
    function updateTWAPPrice(uint256 price) external;
    function getCurrentPrice() external view returns (uint256);
    function getAssetPriceFeed(address asset) external view returns (address);

    // ===============================
    // Data Retrieval
    // ===============================
    function getActiveConstituentsCount() external view returns (uint256);
    function getTotalConstituentCount() external view returns (uint256);
    function getEcosystemHealthMetrics() external view returns (
        uint256 diversityIdx,
        uint256 geneticVol,
        uint256 activeConstituents,
        uint256 adaptiveThreshold,
        uint256 currentPrice,
        uint256 selfOptCounter
    );
    
    function batchGetNeuralWeights(address[] calldata assets) 
        external 
        view 
        returns (
            uint256[] memory weights,
            uint256[] memory signals,
            uint256[] memory updateTimes
        );
    
    function getNeuralWeight(address asset) 
        external 
        view 
        returns (
            uint256 weight,
            uint256 signal,
            uint256 lastUpdate,
            uint256 smoothingFactor
        );

    // ===============================
    // Maintenance
    // ===============================
    function recalculateDiversityIndex() external;
    function resetOptimizationCycle() external;
    function manualSyncWithAIEngine() external;
    function pause() external;
    function unpause() external;
}