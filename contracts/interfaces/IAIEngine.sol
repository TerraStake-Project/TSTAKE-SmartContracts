// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import "./ITerraStakeNeural.sol";
import "./IChainlinkDataFeeder.sol";

/**
 * @title IAIEngine 
 * @notice Interface for the AIEngine contract enhanced for TerraStakeToken compatibility
 * @dev Extends the original AIEngine interface to support TerraStakeToken neural integration
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
    
    // New struct for TerraStake synchronization
    struct SyncData {
        uint256 lastSyncTime;
        uint256 syncInterval;
        bool autoSync;
        uint256 syncSuccessCount;
        uint256 syncFailCount;
    }
    
    // TerraStake ESG impact data
    struct ESGImpactData {
        uint256 environmentalScore;
        uint256 socialScore;
        uint256 governanceScore;
        uint256 aggregateScore;
        uint256 lastUpdateTime;
    }

    // ===============================
    // Events
    // ===============================
    
    // Original events
    event NeuralWeightUpdated(address indexed asset, uint256 weight, uint256 rawSignal, uint256 smoothingFactor);
    event DiversityIndexUpdated(uint256 newIndex);
    event AdaptiveRebalanceTriggered(string reason, uint256 timestamp);
    event ConstituentAdded(address indexed asset, uint256 timestamp);
    event ConstituentDeactivated(address indexed asset, uint256 timestamp);
    event OperationApproved(bytes32 indexed operationId, address indexed approver, uint256 currentApprovals);
    event OperationScheduled(bytes32 indexed operationId, uint256 executionTime);
    event ConfigUpdated(string parameter, uint256 newValue);
    event AssetPriceUpdated(address indexed asset, uint256 price, uint256 timestamp);
    event CircuitBreaker(address indexed asset, uint256 oldPrice, uint256 newPrice, uint256 deviation);
    
    // New events for TerraStakeToken integration
    event TerraStakeSynced(address indexed terraStakeToken, uint256 timestamp, bool success);
    event ESGDataIntegrated(address indexed asset, uint256 environmentalScore, uint256 socialScore, uint256 governanceScore);
    event WeightsPushedToTerraStake(address indexed terraStakeToken, uint256 assetCount, uint256 timestamp);
    event SustainabilityDataProcessed(uint256 indexed projectId, IChainlinkDataFeeder.ProjectCategory category);

    // ===============================
    // Constants
    // ===============================
    
    // Original constants
    function MAX_SIGNAL_VALUE() external view returns (uint256);
    function MAX_EMA_SMOOTHING() external view returns (uint256);
    function DEFAULT_REBALANCE_INTERVAL() external view returns (uint256);
    function MIN_DIVERSITY_INDEX() external view returns (uint256);
    function MAX_DIVERSITY_INDEX() external view returns (uint256);
    function MAX_PRICE_STALENESS() external view returns (uint256);
    function MAX_PRICE_DEVIATION() external view returns (uint256);
    function MAX_TIMELOCK() external view returns (uint256);
    
    // New constants for TerraStake integration
    function DEFAULT_SYNC_INTERVAL() external view returns (uint256);
    function MAX_ESG_SCORE() external view returns (uint256);

    // ===============================
    // Role Management
    // ===============================
    
    // Original roles
    function AI_ADMIN_ROLE() external view returns (bytes32);
    function EMERGENCY_ROLE() external view returns (bytes32);
    function UPGRADER_ROLE() external view returns (bytes32);
    function KEEPER_ROLE() external view returns (bytes32);
    
    // New role for TerraStake integration
    function TERRASTAKE_SYNC_ROLE() external view returns (bytes32);
    function ESG_DATA_PROVIDER_ROLE() external view returns (bytes32);

    // ===============================
    // State Variables
    // ===============================
    
    // Original state variables
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
    
    // New state variables for TerraStake integration
    function terraStakeTokens(uint256 index) external view returns (address);
    function terraStakeSyncData(address terraStakeToken) external view returns (SyncData memory);
    function esgImpactData(address asset) external view returns (ESGImpactData memory);
    function dataFeeder() external view returns (IChainlinkDataFeeder);
    function terraStakeTokenCount() external view returns (uint256);

    // ===============================
    // TerraStake Integration Functions
    // ===============================
    
    /**
     * @notice Registers a TerraStake token for synchronization
     * @param terraStakeToken Address of the TerraStake token contract
     * @param syncInterval How often to sync (in seconds)
     * @param autoSync Whether to automatically sync during keeper runs
     */
    function registerTerraStakeToken(
        address terraStakeToken,
        uint256 syncInterval,
        bool autoSync
    ) external;
    
    /**
     * @notice Removes a TerraStake token from sync list
     * @param terraStakeToken Address of the TerraStake token to remove
     */
    function deregisterTerraStakeToken(address terraStakeToken) external;
    
    /**
     * @notice Manually syncs weights to a specific TerraStake token
     * @param terraStakeToken Address of the TerraStake token to sync with
     * @return success Whether the sync was successful
     */
    function syncWeightsToTerraStake(address terraStakeToken) external returns (bool success);
    
    /**
     * @notice Syncs weights to all registered TerraStake tokens
     * @return successCount Number of successful syncs
     */
    function syncWeightsToAllTerraStakeTokens() external returns (uint256 successCount);
    
    /**
     * @notice Pulls weights from TerraStake token to update AIEngine weights
     * @param terraStakeToken Address of the TerraStake token to pull data from
     * @return success Whether the operation was successful
     */
    function pullWeightsFromTerraStake(address terraStakeToken) external returns (bool success);
    
    /**
     * @notice Sets the Chainlink Data Feeder that provides sustainability metrics
     * @param newDataFeeder Address of the Chainlink Data Feeder contract
     */
    function setChainlinkDataFeeder(address newDataFeeder) external;

    // ===============================
    // ESG Data Integration
    // ===============================
    
    /**
     * @notice Integrates sustainability data from Chainlink Data Feeder
     * @param projectId ID of the sustainability project
     * @param category Category of the project
     */
    function integrateSustainabilityData(uint256 projectId, IChainlinkDataFeeder.ProjectCategory category) external;
    
    /**
     * @notice Updates ESG impact scores for a specific asset
     * @param asset Address of the asset
     * @param environmental Environmental impact score (0-100)
     * @param social Social impact score (0-100)
     * @param governance Governance quality score (0-100)
     */
    function updateESGImpactScores(
        address asset,
        uint256 environmental,
        uint256 social,
        uint256 governance
    ) external;
    
    /**
     * @notice Processes ESG data into neural weight adjustments
     * @param asset Address of the asset to adjust
     * @return adjustedSignal The new signal after ESG considerations
     */
    function processESGDataForAsset(address asset) external returns (uint256 adjustedSignal);
    
    /**
     * @notice Gets the comprehensive ESG score for an asset
     * @param asset Address of the asset
     * @return score The aggregate ESG score
     */
    function getESGScore(address asset) external view returns (uint256 score);

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
    function getAssetPrice(address asset) external view returns (uint256 price, bool isFresh);
    
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
    function triggerAdaptiveRebalance() external returns (string memory reason);
    
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
    
    /**
     * @notice Updates the TerraStake token sync interval
     * @param terraStakeToken Address of the TerraStake token
     * @param newSyncInterval New interval in seconds
     */
    function setTerraStakeSyncInterval(address terraStakeToken, uint256 newSyncInterval) external;
    
    /**
     * @notice Enables or disables auto-sync for a TerraStake token
     * @param terraStakeToken Address of the TerraStake token
     * @param autoSync Whether to automatically sync during keeper runs
     */
    function setTerraStakeAutoSync(address terraStakeToken, bool autoSync) external;

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
    
    /**
     * @notice Creates a multisig operation to add a TerraStake token for integration
     * @param terraStakeToken Address of the TerraStake token
     * @return operationId The generated operation ID
     */
    function proposeAddTerraStakeToken(address terraStakeToken) external returns (bytes32 operationId);
    
    /**
     * @notice Creates a multisig operation to remove a TerraStake token integration
     * @param terraStakeToken Address of the TerraStake token
     * @return operationId The generated operation ID
     */
    function proposeRemoveTerraStakeToken(address terraStakeToken) external returns (bytes32 operationId);

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
    
    /**
     * @notice Emergency function to pause TerraStake synchronization
     */
    function pauseTerraStakeSync() external;
    
    /**
     * @notice Emergency function to resume TerraStake synchronization
     */
    function resumeTerraStakeSync() external;
    
    /**
     * @notice Emergency function to detach from all TerraStake tokens
     */
    function emergencyDetachAllTerraStakeTokens() external;
    
    // ===============================
    // Extension Functionality for TerraStakeToken
    // ===============================
    
    /**
     * @notice Maps AIEngine metadata to TerraStakeToken DNA structure
     * @param terraStakeToken Address of the TerraStake token
     * @return adaptedConstituents List of constituents compatible with TerraStakeToken
     * @return adaptedWeights List of weights compatible with TerraStakeToken
     */
    function adaptDataForTerraStake(address terraStakeToken) 
        external 
        view 
        returns (
            address[] memory adaptedConstituents, 
            uint256[] memory adaptedWeights
        );
    
    /**
     * @notice Creates a customized rebalance recommendation for a specific TerraStake token
     * @param terraStakeToken Address of the TerraStake token
     * @return shouldRebalance Whether a rebalance is recommended
     * @return reason The reason for the recommendation
     */
    function getTerraStakeRebalanceRecommendation(address terraStakeToken) 
        external 
        view 
        returns (
            bool shouldRebalance,
            string memory reason
        );
    
    /**
     * @notice Gets combined ecosystem health metrics from AIEngine and TerraStake
     * @param terraStakeToken Address of the TerraStake token
     * @return aiDiversity AIEngine diversity index
     * @return aiVolatility AIEngine genetic volatility
     * @return terraStakeDiversity TerraStake diversity index
     * @return terraStakeOptimization TerraStake self-optimization counter
     * @return combinedHealth Aggregate health score
     */
    function getCombinedEcosystemHealth(address terraStakeToken)
        external
        view
        returns (
            uint256 aiDiversity,
            uint256 aiVolatility,
            uint256 terraStakeDiversity,
            uint256 terraStakeOptimization,
            uint256 combinedHealth
        );
        
    /**
     * @notice Gets all ESG impact data for active constituents
     * @return assets List of constituent addresses
     * @return environmentalScores List of environmental scores
     * @return socialScores List of social scores
     * @return governanceScores List of governance scores
     * @return aggregateScores List of aggregate ESG scores
     */
    function getAllESGImpactData()
        external
        view
        returns (
            address[] memory assets,
            uint256[] memory environmentalScores,
            uint256[] memory socialScores,
            uint256[] memory governanceScores,
            uint256[] memory aggregateScores
        );
    
    /**
     * @notice Integrates a specific sustainability project category for a TerraStake token
     * @param terraStakeToken Address of the TerraStake token
     * @param projectId ID of the sustainability project
     * @param category Category of the project 
     * @return success Whether the operation succeeded
     */
    function integrateProjectForTerraStake(
        address terraStakeToken,
        uint256 projectId,
        IChainlinkDataFeeder.ProjectCategory category
    ) external returns (bool success);
}
