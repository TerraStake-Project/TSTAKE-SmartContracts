// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

/**
 * @title IAIEngine
 * @notice Interface for the AIEngine contract with ML predictions and liquidity optimization for TerraStakeToken
 * @dev Defines the public API of the AIEngine contract, including TerraStakeToken integration
 */
interface IAIEngine {
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
        uint256 lastPrice;
        uint256 lastPriceUpdateTime;
        int256 predictedPriceChange; // ML-predicted price change (percentage * 100, e.g., 500 = +5%)
        uint256 rewardMultiplier;    // Staking reward multiplier in basis points (100 = 1x)
    }

    // ===============================
    // Events
    // ===============================
    event NeuralWeightUpdated(address indexed asset, uint256 weight, uint256 rawSignal, uint256 smoothingFactor);
    event DiversityIndexUpdated(uint256 newIndex);
    event AdaptiveRebalanceTriggered(string reason, uint256 timestamp);
    event ConstituentAdded(address indexed asset, uint256 timestamp);
    event ConstituentDeactivated(address indexed asset, uint256 timestamp);
    event CrossChainSyncExecuted(uint16 indexed chainId, address indexed asset, bool isActive, uint256 weight);
    event ConfigUpdated(string parameter, uint256 newValue);
    event PriceUpdated(address indexed asset, uint256 price, uint256 timestamp);
    event CircuitBreaker(address indexed asset, uint256 oldPrice, uint256 newPrice, uint256 deviation);
    event OperationApproved(bytes32 indexed operationId, address indexed approver, uint256 currentApprovals);
    event OperationScheduled(bytes32 indexed operationId, uint256 executionTime);
    event PredictionUpdated(address indexed asset, int256 predictedPriceChange, uint256 timestamp);
    event RewardMultiplierUpdated(address indexed asset, uint256 multiplier, uint256 timestamp);

    // ===============================
    // Constants
    // ===============================
    function MAX_SIGNAL_VALUE() external view returns (uint256);
    function MAX_EMA_SMOOTHING() external view returns (uint256);
    function DEFAULT_REBALANCE_INTERVAL() external view returns (uint256);
    function MAX_PRICE_STALENESS() external view returns (uint256);
    function MAX_PRICE_DEVIATION() external view returns (uint256);
    function MIN_DIVERSITY_INDEX() external view returns (uint256);
    function MAX_DIVERSITY_INDEX() external view returns (uint256);
    function MAX_TIMELOCK() external view returns (uint256);

    // ===============================
    // Roles
    // ===============================
    function AI_ADMIN_ROLE() external view returns (bytes32);
    function EMERGENCY_ROLE() external view returns (bytes32);
    function UPGRADER_ROLE() external view returns (bytes32);
    function CROSS_CHAIN_OPERATOR_ROLE() external view returns (bytes32);

    // ===============================
    // State Variables
    // ===============================
    function assetNeuralWeights(address asset) external view returns (NeuralWeight memory);
    function constituents(address asset) external view returns (Constituent memory);
    function constituentList(uint256 index) external view returns (address);
    function activeConstituentCount() external view returns (uint256);
    function priceFeeds(address asset) external view returns (address);
    function mlPredictionFeed() external view returns (address);
    function diversityIndex() external view returns (uint256);
    function geneticVolatility() external view returns (uint256);
    function adaptiveVolatilityThreshold() external view returns (uint256);
    function rebalanceInterval() external view returns (uint256);
    function lastRebalanceTime() external view returns (uint256);
    function requiredApprovals() external view returns (uint256);
    function operationApprovals(bytes32 operationId) external view returns (uint256);
    function hasApproved(bytes32 operationId, address account) external view returns (bool);
    function operationTimelock() external view returns (uint256);
    function operationScheduledTime(bytes32 operationId) external view returns (uint256);
    function supportedChainIds(uint16 chainId) external view returns (bool);
    function crossChainHandler() external view returns (address);
    function baseRewardRate() external view returns (uint256);
    function liquidityAdjustmentFactor() external view returns (uint256);

    // ===============================
    // Constituent Management
    // ===============================
    function updateConstituent(address asset, address priceFeed, bool isActive) external;
    function getActiveConstituents() external view returns (address[] memory);

    // ===============================
    // Neural Weight Management
    // ===============================
    function updateNeuralWeight(address asset, uint256 newRawSignal, uint256 smoothingFactor) external;
    function batchUpdateNeuralWeights(
        address[] calldata assets,
        uint256[] calldata newRawSignals,
        uint256[] calldata smoothingFactors
    ) external;

    // ===============================
    // AI Learning Enhancements
    // ===============================
    function updateMLPredictions(address asset) external;

    // ===============================
    // Diversity Index Management
    // ===============================
    function recalculateDiversityIndex() external;

    // ===============================
    // API3 Oracle Integration
    // ===============================
    function fetchLatestPrice(address asset) external returns (uint256);
    function getLatestPrice(address asset) external view returns (uint256 price, bool isFresh);
    function updatePriceFeedAddress(address asset, address newPriceFeed) external;

    // ===============================
    // Liquidity Optimization
    // ===============================
    function setLiquidityConfig(uint256 _baseRewardRate, uint256 _liquidityAdjustmentFactor) external;

    // ===============================
    // Rebalancing Logic
    // ===============================
    function shouldRebalance() external view returns (bool, string memory);
    function triggerRebalance() external returns (string memory);
    function updateGeneticVolatility(uint256 newVolatility) external;

    // ===============================
    // Configuration Management
    // ===============================
    function setConfig(string calldata parameter, uint256 value) external;

    // ===============================
    // Governance
    // ===============================
    function approveOperation(bytes32 operationId) external;
    function revokeApproval(bytes32 operationId) external;
    function scheduleOperation(bytes32 operationId) external;
    function getOperationId(string calldata action, bytes calldata data) external view returns (bytes32);

    // ===============================
    // Cross-Chain Sync
    // ===============================
    function syncCrossChainState(uint16 chainId, address asset, bool isActive, uint256 weight) external;
    function addSupportedChain(uint16 chainId) external;
    function removeSupportedChain(uint16 chainId) external;
    function updateCrossChainHandler(address newHandler) external;

    // ===============================
    // TerraStakeToken Sync
    // ===============================
    function syncConstituentStatus(address asset, bool isActive, uint256 currentWeight) external;
    function getPriceDataForRebalancing()
        external
        view
        returns (address[] memory assets, uint256[] memory prices, uint256[] memory rewardMultipliers, uint256 volatility);

    // ===============================
    // Emergency Controls
    // ===============================
    function pause() external;
    function unpause() external;
    function emergencyResetWeights() external;
    function clearPriceDeviationAlert(address asset) external;
}