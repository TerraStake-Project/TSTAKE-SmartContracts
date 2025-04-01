// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.21;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@api3/contracts/v0.8/interfaces/IProxy.sol";

import "../interfaces/IAIEngine.sol";
import "../interfaces/ITerraStakeNeural.sol";

/**
 * @title TerraStakeNeural
 * @notice AI-driven portfolio management system with decentralized oracle integration
 * @dev Implements neural network-inspired weight management with API3 oracle support
 * @custom:security-contact security@terrastake.io
 */
contract TerraStakeNeural is
    ITerraStakeNeural,
    Initializable,
    AccessControlEnumerableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // ================================
    // Constants
    // ================================
    uint256 public constant override MAX_SIGNAL_VALUE = 1e30;
    uint256 public constant override MAX_EMA_SMOOTHING = 100;
    uint256 public constant override DEFAULT_EMA_SMOOTHING = 20;
    uint256 public constant override MIN_DIVERSITY_INDEX = 1000;
    uint256 public constant override MAX_DIVERSITY_INDEX = 8000;
    uint256 public constant override MIN_CONSTITUENTS = 3;
    uint256 public constant override MAX_CONSTITUENTS = 50;
    uint256 public constant override MAX_BATCH_SIZE = 100;
    uint256 public constant override MAX_PRICE_STALENESS = 24 hours;
    uint256 public constant override PRICE_UPDATE_COOLDOWN = 5 minutes;
    uint256 public constant override DEFAULT_REBALANCE_INTERVAL = 7 days;
    uint256 public constant override MAX_VOLATILITY_THRESHOLD = 5000; // 50%
    uint256 public constant override MIN_VOLATILITY_THRESHOLD = 200; // 2%
    uint256 public constant override VOLATILITY_THRESHOLD = 1500; // 15% default
    uint256 public constant MIN_DELAY = 1 days; // Time lock delay

    // ================================
    // Roles
    // ================================
    bytes32 public constant override ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant override NEURAL_INDEXER_ROLE = keccak256("NEURAL_INDEXER_ROLE");
    bytes32 public constant override AI_MANAGER_ROLE = keccak256("AI_MANAGER_ROLE");
    bytes32 public constant override UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ================================
    // Events
    // ================================
    // Enhanced events with additional data
    event TWAPPriceUpdated(uint256 newPrice, uint256 timestamp, string source);
    event CircuitBreaker(string reason, uint256 lastPrice, uint256 currentPrice);
    event PriceDeviationDetected(uint256 deviation, uint256 oldPrice, uint256 newPrice);
    event ParameterUpdateScheduled(string parameter, uint256 newValue, uint256 effectiveTime);

    // ================================
    // Data Structures
    // ================================
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

    // ================================
    // State Variables
    // ================================
    mapping(address => NeuralWeight) public assetNeuralWeights;
    mapping(address => ConstituentData) public constituents;
    address[] public constituentList;

    // Price data
    mapping(address => IProxy) public priceFeedProxies;
    uint256 public override lastTWAPPrice;
    uint256 public lastPriceUpdateTime;

    // Ecosystem metrics
    uint256 public override diversityIndex;
    uint256 public override geneticVolatility;
    uint256 public override adaptiveVolatilityThreshold;
    uint256 public override rebalanceInterval;
    uint256 public override lastRebalanceTime;
    uint256 public override selfOptimizationCounter;
    uint256 public override lastAdaptiveLearningUpdate;
    uint256 public override rebalancingFrequencyTarget;

    // Integration settings
    IAIEngine public aiEngine;
    bool public override useAIEngine;
    bool public override syncWithAIEngine;

    // Time lock for critical operations
    mapping(bytes32 => uint256) public operationTimestamps;

    // ================================
    // Initialization
    // ================================
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the TerraStakeNeural contract
     * @param _admin Admin address
     * @param _aiEngine Optional AI Engine address (can be address(0))
     * @custom:reverts ZeroAddress If admin address is zero
     */
    function initialize(
        address _admin,
        address _aiEngine
    ) public initializer {
        __AccessControlEnumerable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        if (_admin == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(NEURAL_INDEXER_ROLE, _admin);
        _grantRole(AI_MANAGER_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);

        if (_aiEngine != address(0)) {
            aiEngine = IAIEngine(_aiEngine);
            useAIEngine = true;
            syncWithAIEngine = true;
        }

        rebalanceInterval = DEFAULT_REBALANCE_INTERVAL;
        adaptiveVolatilityThreshold = 1500; // 15% default
        lastRebalanceTime = block.timestamp;
        lastAdaptiveLearningUpdate = block.timestamp;
        rebalancingFrequencyTarget = 12; // 12 rebalances per year by default
    }

    // ================================
    // Configuration Functions
    // ================================

    /**
     * @notice Set the AI Engine address
     * @param _aiEngine New AI Engine address (set to address(0) to disable)
     * @dev Requires ADMIN_ROLE
     * @custom:emits ConfigUpdated On successful update
     */
    function setAIEngine(address _aiEngine) external override onlyRole(ADMIN_ROLE) {
        if (_aiEngine == address(0)) {
            useAIEngine = false;
            syncWithAIEngine = false;
        } else {
            aiEngine = IAIEngine(_aiEngine);
        }
        
        emit ConfigUpdated("aiEngine", uint256(uint160(_aiEngine)));
    }

    /**
     * @notice Toggle AI Engine usage
     * @param _useAIEngine Whether to use the AI Engine
     * @dev Requires ADMIN_ROLE
     * @custom:reverts InvalidParameters If AI Engine not set but trying to enable
     * @custom:emits ConfigUpdated On successful update
     */
    function toggleAIEngine(bool _useAIEngine) external override onlyRole(ADMIN_ROLE) {
        if (address(aiEngine) == address(0) && _useAIEngine) {
            revert InvalidParameters("useAIEngine", "AI Engine not set");
        }
        useAIEngine = _useAIEngine;
        emit ConfigUpdated("useAIEngine", _useAIEngine ? 1 : 0);
    }

    /**
     * @notice Toggle syncing with AI Engine
     * @param _syncWithAIEngine Whether to sync with the AI Engine
     * @dev Requires ADMIN_ROLE
     * @custom:reverts InvalidParameters If AI Engine not set but trying to enable sync
     * @custom:emits ConfigUpdated On successful update
     */
    function toggleSyncWithAIEngine(bool _syncWithAIEngine) external override onlyRole(ADMIN_ROLE) {
        if (address(aiEngine) == address(0) && _syncWithAIEngine) {
            revert InvalidParameters("syncWithAIEngine", "AI Engine not set");
        }
        syncWithAIEngine = _syncWithAIEngine;
        emit ConfigUpdated("syncWithAIEngine", _syncWithAIEngine ? 1 : 0);
    }

    /**
     * @notice Set the rebalance interval
     * @param _rebalanceInterval New rebalance interval in seconds
     * @dev Requires ADMIN_ROLE
     * @custom:reverts InvalidParameters If interval outside valid range (1-30 days)
     * @custom:emits ConfigUpdated On successful update
     */
    function setRebalanceInterval(uint256 _rebalanceInterval) external override onlyRole(ADMIN_ROLE) {
        if (_rebalanceInterval < 1 days || _rebalanceInterval > 30 days) {
            revert InvalidParameters("rebalanceInterval", "Invalid interval range");
        }
        rebalanceInterval = _rebalanceInterval;
        emit ConfigUpdated("rebalanceInterval", _rebalanceInterval);
    }

    /**
     * @notice Set the adaptive volatility threshold
     * @param _threshold New threshold (in basis points, e.g. 1000 = 10%)
     * @dev Requires AI_MANAGER_ROLE
     * @custom:reverts InvalidParameters If threshold outside valid range
     * @custom:emits AdaptiveThresholdUpdated On successful update
     * @custom:sync If enabled, updates AIEngine with new threshold
     */
    function setVolatilityThreshold(uint256 _threshold) external override onlyRole(AI_MANAGER_ROLE) {
        if (_threshold < MIN_VOLATILITY_THRESHOLD || _threshold > MAX_VOLATILITY_THRESHOLD) {
            revert InvalidParameters("threshold", "Invalid threshold range");
        }
        adaptiveVolatilityThreshold = _threshold;
        
        if (address(aiEngine) != address(0) && useAIEngine) {
            try aiEngine.setAdaptiveVolatilityThreshold(_threshold) {
                emit AIEngineOperationExecuted("setVolatilityThreshold", true);
            } catch {
                emit AIEngineOperationExecuted("setVolatilityThreshold", false);
            }
        }
        
        emit AdaptiveThresholdUpdated(_threshold);
    }

    /**
     * @notice Update price feed for an asset
     * @param asset Asset address
     * @param priceFeed Price feed address
     * @dev Requires ADMIN_ROLE
     * @custom:reverts ZeroAddress If asset or priceFeed is zero
     * @custom:reverts InvalidConstituent If asset is not an active constituent
     * @custom:reverts InvalidPriceFeed If priceFeed doesn't implement IProxy interface
     * @custom:emits PriceFeedUpdated On successful update
     * @custom:sync If enabled, updates AIEngine with new price feed
     */
    function updatePriceFeed(address asset, address priceFeed) external override onlyRole(ADMIN_ROLE) {
        if (asset == address(0)) revert ZeroAddress();
        if (!constituents[asset].isActive) revert InvalidConstituent(asset);
        if (priceFeed == address(0)) revert ZeroAddress();
        
        // Validate that the price feed implements the IProxy interface
        try IProxy(priceFeed).supportsInterface(type(IProxy).interfaceId) returns (bool supported) {
            if (!supported) revert InvalidPriceFeed();
        } catch {
            revert InvalidPriceFeed();
        }

        priceFeedProxies[asset] = IProxy(priceFeed);
        
        if (address(aiEngine) != address(0) && syncWithAIEngine) {
            try aiEngine.updatePriceFeed(asset, priceFeed) {
                emit AIEngineOperationExecuted("updatePriceFeed", true);
            } catch {
                emit AIEngineOperationExecuted("updatePriceFeed", false);
            }
        }
        
        emit PriceFeedUpdated(asset, priceFeed);
    }

    // ================================
    // Time Lock Functions
    // ================================

    /**
     * @notice Schedule a parameter update with time lock
     * @param parameter Name of the parameter to update
     * @param newValue New value for the parameter
     * @dev Requires ADMIN_ROLE
     * @custom:emits ParameterUpdateScheduled When update is scheduled
     */
    function scheduleParameterUpdate(
        string memory parameter, 
        uint256 newValue
    ) external onlyRole(ADMIN_ROLE) {
        bytes32 operationId = keccak256(abi.encode(parameter, newValue));
        operationTimestamps[operationId] = block.timestamp + MIN_DELAY;
        emit ParameterUpdateScheduled(parameter, newValue, operationTimestamps[operationId]);
    }

    /**
     * @notice Execute a previously scheduled parameter update
     * @param parameter Name of the parameter to update
     * @param newValue New value for the parameter
     * @dev Requires ADMIN_ROLE
     * @custom:reverts If time lock delay has not passed
     */
    function executeParameterUpdate(
        string memory parameter, 
        uint256 newValue
    ) external onlyRole(ADMIN_ROLE) {
        bytes32 operationId = keccak256(abi.encode(parameter, newValue));
        uint256 scheduledTime = operationTimestamps[operationId];
        
        if (scheduledTime == 0 || block.timestamp < scheduledTime) {
            revert InvalidParameters("timelock", "Delay not passed");
        }
        
        // Clear the scheduled operation
        operationTimestamps[operationId] = 0;
        
        // Execute the parameter update
        bytes32 paramHash = keccak256(bytes(parameter));
        
        if (paramHash == keccak256(bytes("rebalanceInterval"))) {
            setRebalanceInterval(newValue);
        } else if (paramHash == keccak256(bytes("volatilityThreshold"))) {
            setVolatilityThreshold(newValue);
        } else if (paramHash == keccak256(bytes("rebalancingFrequencyTarget"))) {
            rebalancingFrequencyTarget = newValue;
            emit ConfigUpdated("rebalancingFrequencyTarget", newValue);
        } else {
            revert InvalidParameters("parameter", "Unknown parameter");
        }
    }

    // ================================
    // Constituent Management
    // ================================

    /**
     * @notice Add a new constituent with initial weight
     * @param asset Asset address
     * @param initialWeight Initial weight
     * @dev Requires ADMIN_ROLE
     * @custom:reverts ZeroAddress If asset is zero
     * @custom:reverts InvalidParameters If asset already active or max constituents reached
     * @custom:emits ConstituentAdded On successful addition
     */
    function addConstituent(address asset, uint256 initialWeight)
        external
        override
        onlyRole(ADMIN_ROLE)
        whenNotPaused
    {
        _addConstituent(asset, initialWeight, address(0));
    }

    /**
     * @notice Add a constituent with price feed
     * @param asset Asset address
     * @param initialWeight Initial weight
     * @param priceFeed API3 price feed address
     * @dev Requires ADMIN_ROLE
     * @custom:reverts ZeroAddress If asset or priceFeed is zero
     * @custom:reverts InvalidPriceFeed If priceFeed doesn't implement IProxy interface
     * @custom:emits ConstituentAdded On successful addition
     * @custom:emits PriceFeedUpdated If price feed is provided
     */
    function addConstituentWithPriceFeed(
        address asset,
        uint256 initialWeight,
        address priceFeed
    ) external override onlyRole(ADMIN_ROLE) whenNotPaused {
        if (priceFeed == address(0)) revert ZeroAddress();
        
        // Validate that the price feed implements the IProxy interface
        try IProxy(priceFeed).supportsInterface(type(IProxy).interfaceId) returns (bool supported) {
            if (!supported) revert InvalidPriceFeed();
        } catch {
            revert InvalidPriceFeed();
        }
        
        _addConstituent(asset, initialWeight, priceFeed);
    }

    /**
     * @notice Internal function to add constituent
     * @param asset Asset address
     * @param initialWeight Initial weight
     * @param priceFeed Price feed address (optional)
     */
    function _addConstituent(address asset, uint256 initialWeight, address priceFeed) internal {
        if (asset == address(0)) revert ZeroAddress();
        if (constituents[asset].isActive) revert InvalidParameters("asset", "Already active");
        if (constituentList.length >= MAX_CONSTITUENTS) revert InvalidParameters("constituents", "Max reached");

        // Add to AI Engine if enabled
        if (address(aiEngine) != address(0) && syncWithAIEngine) {
            address feedToUse = priceFeed != address(0) ? priceFeed : address(0x1);
            try aiEngine.addConstituent(asset, feedToUse) {
                emit AIEngineOperationExecuted("addConstituent", true);
            } catch {
                emit AIEngineOperationExecuted("addConstituent", false);
                emit SyncFailed("addConstituent", asset);
            }
        }

        // Set price feed if provided
        if (priceFeed != address(0)) {
            priceFeedProxies[asset] = IProxy(priceFeed);
            emit PriceFeedUpdated(asset, priceFeed);
        }

        // Initialize constituent
        constituents[asset] = ConstituentData({
            isActive: true,
            activationTime: block.timestamp,
            evolutionScore: 0
        });
        constituentList.push(asset);

        // Initialize neural weight
        assetNeuralWeights[asset] = NeuralWeight({
            currentWeight: initialWeight,
            rawSignal: initialWeight,
            lastUpdateTime: block.timestamp,
            emaSmoothingFactor: DEFAULT_EMA_SMOOTHING
        });

        emit ConstituentAdded(asset, block.timestamp);
        _updateDiversityIndex();
    }

    /**
     * @notice Remove a constituent
     * @param asset Asset address
     * @dev Requires ADMIN_ROLE
     * @custom:reverts InvalidParameters If asset is not active
     * @custom:emits ConstituentRemoved On successful removal
     * @custom:sync If enabled, deactivates constituent in AIEngine
     */
    function removeConstituent(address asset)
        external
        override
        onlyRole(ADMIN_ROLE)
        whenNotPaused
    {
        if (!constituents[asset].isActive) revert InvalidParameters("asset", "Not active");

        // Remove from AI Engine if enabled
        if (address(aiEngine) != address(0) && useAIEngine) {
            try aiEngine.deactivateConstituent(asset) {
                emit AIEngineOperationExecuted("removeConstituent", true);
            } catch {
                emit AIEngineOperationExecuted("removeConstituent", false);
                emit SyncFailed("removeConstituent", asset);
            }
        }

        constituents[asset].isActive = false;
        emit ConstituentRemoved(asset, block.timestamp);
        _updateDiversityIndex();
    }

    /**
     * @notice Get list of active constituents
     * @return activeList Array of active constituent addresses
     */
    function getActiveConstituents() external view override returns (address[] memory) {
        uint256 activeCount = 0;
        uint256 constituentCount = constituentList.length;
        
        // First count active constituents
        for (uint256 i = 0; i < constituentCount; i++) {
            if (constituents[constituentList[i]].isActive) {
                activeCount++;
            }
        }
        
        // Then create and populate the array
        address[] memory activeList = new address[](activeCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < constituentCount; i++) {
            if (constituents[constituentList[i]].isActive) {
                activeList[index] = constituentList[i];
                index++;
            }
        }
        
        return activeList;
    }

    /**
     * @notice Get total number of constituents (both active and inactive)
     * @return count Total number of constituents
     */
    function getTotalConstituentCount() external view override returns (uint256) {
        return constituentList.length;
    }

    /**
     * @notice Get detailed information about a constituent
     * @param asset Asset address
     * @return isActive Whether the constituent is active
     * @return activationTime When the constituent was activated
     * @return evolutionScore Current evolution score
     * @return priceFeed Address of the price feed
     */
    function getConstituentData(address asset) external view returns (
        bool isActive,
        uint256 activationTime,
        uint256 evolutionScore,
        address priceFeed
    ) {
        ConstituentData storage data = constituents[asset];
        return (
            data.isActive,
            data.activationTime,
            data.evolutionScore,
            address(priceFeedProxies[asset])
        );
    }

    // ================================
    // Neural Weight Management
    // ================================

    /**
     * @notice Update neural weight for an asset
     * @dev Uses formula: newEMA = (signal * factor + oldEMA * (100 - factor)) / 100
     * @param asset The asset to update
     * @param newRawSignal The new signal value (1e18 precision)
     * @param smoothingFactor Weighting factor between 1-100 (higher = more responsive)
     * @custom:reverts InvalidParameters If asset not active, signal too large, or invalid factor
     * @custom:emits NeuralWeightUpdated On successful update
     * @custom:sync If enabled, updates AIEngine with new weight
     */
    function updateNeuralWeight(
        address asset,
        uint256 newRawSignal,
        uint256 smoothingFactor
    ) external override onlyRole(NEURAL_INDEXER_ROLE) whenNotPaused {
        _updateNeuralWeight(asset, newRawSignal, smoothingFactor);
    }

    /**
     * @notice Batch update neural weights
     * @param assets Array of asset addresses
     * @param newRawSignals Array of new raw signals
     * @param smoothingFactors Array of smoothing factors
     * @dev Requires NEURAL_INDEXER_ROLE
     * @custom:reverts ArrayLengthMismatch If input arrays have different lengths
     * @custom:reverts InvalidParameters If batch size exceeds maximum
     */
    function batchUpdateNeuralWeights(
        address[] calldata assets,
        uint256[] calldata newRawSignals,
        uint256[] calldata smoothingFactors
    ) external override onlyRole(NEURAL_INDEXER_ROLE) whenNotPaused {
        if (assets.length != newRawSignals.length || assets.length != smoothingFactors.length) {
            revert ArrayLengthMismatch();
        }
        if (assets.length > MAX_BATCH_SIZE) {
            revert InvalidParameters("batchSize", "Too large");
        }

        for (uint256 i = 0; i < assets.length; i++) {
            if (constituents[assets[i]].isActive) {
                _updateNeuralWeight(assets[i], newRawSignals[i], smoothingFactors[i]);
            }
        }
    }

    /**
     * @notice Internal neural weight update function
     * @param asset Asset address
     * @param newRawSignal New raw signal value
     * @param smoothingFactor EMA smoothing factor
     */
    function _updateNeuralWeight(
        address asset,
        uint256 newRawSignal,
        uint256 smoothingFactor
    ) internal {
        if (!constituents[asset].isActive) revert InvalidParameters("asset", "Not active");
        if (newRawSignal > MAX_SIGNAL_VALUE) revert InvalidParameters("signal", "Too large");
        if (smoothingFactor == 0 || smoothingFactor > MAX_EMA_SMOOTHING) {
            revert InvalidParameters("smoothingFactor", "Invalid value");
        }

        NeuralWeight storage weight = assetNeuralWeights[asset];
        
        // Initialize if first update
        if (weight.lastUpdateTime == 0) {
            weight.currentWeight = newRawSignal;
        } else {
            // Apply EMA
            weight.currentWeight = (newRawSignal * smoothingFactor + 
                                  weight.currentWeight * (MAX_EMA_SMOOTHING - smoothingFactor)) / 
                                  MAX_EMA_SMOOTHING;
        }

        weight.rawSignal = newRawSignal;
        weight.lastUpdateTime = block.timestamp;
        weight.emaSmoothingFactor = smoothingFactor;

        // Sync with AI Engine if enabled
        if (address(aiEngine) != address(0) && syncWithAIEngine) {
            try aiEngine.updateNeuralWeight(asset, newRawSignal, smoothingFactor) {
                emit AIEngineOperationExecuted("updateNeuralWeight", true);
            } catch {
                emit AIEngineOperationExecuted("updateNeuralWeight", false);
                emit SyncFailed("updateNeuralWeight", asset);
            }
        }

        emit NeuralWeightUpdated(asset, weight.currentWeight, newRawSignal, smoothingFactor);
        _updateDiversityIndex();
    }

    /**
     * @notice Get neural weight details for an asset
     * @param asset Asset address
     * @return weight Current weight
     * @return signal Raw signal
     * @return lastUpdate Last update timestamp
     * @return smoothingFactor EMA smoothing factor
     */
    function getNeuralWeight(address asset) 
        external 
        view 
        override
        returns (
            uint256 weight,
            uint256 signal,
            uint256 lastUpdate,
            uint256 smoothingFactor
        )
    {
        NeuralWeight storage neuralWeight = assetNeuralWeights[asset];
        return (
            neuralWeight.currentWeight,
            neuralWeight.rawSignal,
            neuralWeight.lastUpdateTime,
            neuralWeight.emaSmoothingFactor
        );
    }

    /**
     * @notice Batch get neural weights for multiple assets
     * @param assets Array of asset addresses
     * @return weights Array of current weights
     * @return signals Array of raw signals
     * @return updateTimes Array of last update timestamps
     */
    function batchGetNeuralWeights(address[] calldata assets) 
        external 
        view 
        override
        returns (
            uint256[] memory weights,
            uint256[] memory signals,
            uint256[] memory updateTimes
        )
    {
        weights = new uint256[](assets.length);
        signals = new uint256[](assets.length);
        updateTimes = new uint256[](assets.length);
        
        for (uint256 i = 0; i < assets.length; i++) {
            NeuralWeight storage weight = assetNeuralWeights[assets[i]];
            weights[i] = weight.currentWeight;
            signals[i] = weight.rawSignal;
            updateTimes[i] = weight.lastUpdateTime;
        }
        
        return (weights, signals, updateTimes);
    }

    // ================================
    // Evolution & Scoring
    // ================================

    /**
     * @notice Update evolution score for an asset
     * @param asset Asset address
     * @param newScore New evolution score
     * @dev Requires AI_MANAGER_ROLE
     * @custom:reverts InvalidConstituent If asset is not active
     * @custom:sync If enabled, updates AIEngine with new score
     */
    function updateEvolutionScore(address asset, uint256 newScore) 
        external 
        override
        onlyRole(AI_MANAGER_ROLE) 
        whenNotPaused 
    {
        if (!constituents[asset].isActive) revert InvalidConstituent(asset);
        
        constituents[asset].evolutionScore = newScore;
        
        // Sync with AI Engine if enabled
        if (address(aiEngine) != address(0) && syncWithAIEngine) {
            try aiEngine.updateEvolutionScore(asset, newScore) {
                emit AIEngineOperationExecuted("updateEvolutionScore", true);
            } catch {
                emit AIEngineOperationExecuted("updateEvolutionScore", false);
                emit SyncFailed("updateEvolutionScore", asset);
            }
        }
    }

    /**
     * @notice Get evolution score for an asset
     * @param asset Asset address
     * @return score Evolution score
     */
    function getEvolutionScore(address asset) external view override returns (uint256) {
        return constituents[asset].evolutionScore;
    }

    // ================================
    // Rebalancing Logic
    // ================================

    /**
     * @notice Check if rebalance should be triggered
     * @return shouldRebalance Whether rebalance is needed
     * @return reason Human-readable reason
     */
    function shouldAdaptiveRebalance() public view override returns (bool, string memory) {
        // Try AI Engine first if enabled
        if (address(aiEngine) != address(0) && useAIEngine) {
            try aiEngine.shouldAdaptiveRebalance() returns (bool shouldRebalance, string memory reason) {
                return (shouldRebalance, reason);
            } catch {
                // Fall through to local logic
            }
        }

        // Local rebalance conditions
        if (block.timestamp >= lastRebalanceTime + rebalanceInterval) {
            return (true, "Time-based rebalance");
        }

        if (diversityIndex > MAX_DIVERSITY_INDEX) {
            return (true, "Diversity too concentrated");
        }

        if (diversityIndex < MIN_DIVERSITY_INDEX && diversityIndex > 0) {
            return (true, "Diversity too dispersed");
        }

        if (geneticVolatility > adaptiveVolatilityThreshold) {
            return (true, "Volatility threshold breach");
        }

        return (false, "No rebalance needed");
    }

    /**
     * @notice Get rebalance status information
     * @return needed Whether rebalance is needed
     * @return reason Reason for rebalance
     * @return nextPossible Timestamp when next time-based rebalance is possible
     */
    function getRebalanceStatus() external view returns (
        bool needed,
        string memory reason,
        uint256 nextPossible
    ) {
        (needed, reason) = shouldAdaptiveRebalance();
        nextPossible = lastRebalanceTime + rebalanceInterval;
        return (needed, reason, nextPossible);
    }

    /**
     * @notice Trigger adaptive rebalance
     * @return reason Reason for rebalance
     * @dev Requires NEURAL_INDEXER_ROLE
     * @custom:reverts InvalidParameters If rebalance not needed
     * @custom:emits AdaptiveRebalanceTriggered On successful trigger
     * @custom:sync If enabled, notifies AIEngine about rebalance
     */
    function triggerAdaptiveRebalance()
        external
        override
        onlyRole(NEURAL_INDEXER_ROLE)
        whenNotPaused
        returns (string memory)
    {
        // Fetch latest price data
        fetchAIPriceData();

        (bool doRebalance, string memory reason) = shouldAdaptiveRebalance();
        if (!doRebalance) revert InvalidParameters("rebalance", "Not needed");

        lastRebalanceTime = block.timestamp;

        // Notify AI Engine if enabled
        if (address(aiEngine) != address(0) && useAIEngine) {
            try aiEngine.notifyRebalance(reason) {
                emit AIEngineOperationExecuted("notifyRebalance", true);
            } catch {
                emit AIEngineOperationExecuted("notifyRebalance", false);
            }
        }

        emit AdaptiveRebalanceTriggered(reason, block.timestamp);
        return reason;
    }

    /**
     * @notice Execute self-optimization routine
     * @dev Requires AI_MANAGER_ROLE
     * @custom:emits SelfOptimizationExecuted On successful execution
     * @custom:sync If enabled, executes self-optimization in AIEngine
     */
    function executeSelfOptimization() external override onlyRole(AI_MANAGER_ROLE) whenNotPaused {
        // Increment counter
        selfOptimizationCounter++;
        
        // Execute optimization logic
        if (address(aiEngine) != address(0) && useAIEngine) {
            try aiEngine.executeSelfOptimization() {
                emit AIEngineOperationExecuted("executeSelfOptimization", true);
            } catch {
                emit AIEngineOperationExecuted("executeSelfOptimization", false);
            }
        }
        
        // Adjust adaptive parameters based on performance
        _adjustAdaptiveParameters();
        
        emit SelfOptimizationExecuted(selfOptimizationCounter, block.timestamp);
    }
    
    /**
     * @notice Internal function to adjust adaptive parameters
     */
    function _adjustAdaptiveParameters() internal {
        // This would contain the logic to adjust parameters based on performance
        // For now, we'll just update the timestamp
        lastAdaptiveLearningUpdate = block.timestamp;
    }

    // ================================
    // Price Data Management
    // ================================

    /**
     * @notice Fetch and update price data from oracles
     * @dev Public function that consolidates price data
     * @custom:emits PriceUpdated For each valid price update
     * @custom:emits TWAPPriceUpdated When TWAP price is updated
     * @custom:emits CircuitBreaker If no valid prices are available
     * @custom:emits PriceDeviationDetected If price deviation exceeds threshold
     */
    function fetchAIPriceData() public override whenNotPaused {
        if (block.timestamp < lastPriceUpdateTime + PRICE_UPDATE_COOLDOWN) {
            return;
        }

        uint256 totalPrices;
        uint256 validCount;
        uint256 aiPrice;
        string memory priceSource = "Oracles";
        
        // Get prices from API3 oracles
        uint256 constituentCount = constituentList.length;
        for (uint256 i = 0; i < constituentCount; i++) {
            address asset = constituentList[i];
            if (constituents[asset].isActive && address(priceFeedProxies[asset]) != address(0)) {
                try priceFeedProxies[asset].read() returns (int256 price, uint256 timestamp) {
                    if (price > 0 && block.timestamp - timestamp <= MAX_PRICE_STALENESS) {
                        totalPrices += uint256(price);
                        validCount++;
                        emit PriceUpdated(asset, uint256(price));
                    }
                } catch {
                    continue;
                }
            }
        }

        // Get price from AI Engine if available
        if (address(aiEngine) != address(0) && useAIEngine) {
            try aiEngine.getCurrentPrice() returns (uint256 price) {
                if (price > 0) {
                    totalPrices += price;
                    validCount++;
                    aiPrice = price;
                    priceSource = "AIEngine";
                }
            } catch {
                // Continue without AI price
            }
        }

        // Circuit breaker logic
        if (validCount == 0) {
            emit CircuitBreaker("NoValidPrices", lastTWAPPrice, 0);
            if (lastTWAPPrice > 0 && block.timestamp - lastPriceUpdateTime > 2 hours) {
                _pause();
                return;
            }
        }

        if (validCount > 0) {
            uint256 avgPrice = totalPrices / validCount;
            
            // Check for significant price deviation
            if (lastTWAPPrice > 0) {
                uint256 deviation;
                
                if (avgPrice > lastTWAPPrice) {
                    deviation = (avgPrice - lastTWAPPrice) * 10000 / lastTWAPPrice;
                } else {
                    deviation = (lastTWAPPrice - avgPrice) * 10000 / lastTWAPPrice;
                }
                
                if (deviation > MAX_VOLATILITY_THRESHOLD) {
                    emit PriceDeviationDetected(deviation, lastTWAPPrice, avgPrice);
                }
            }
            
            lastTWAPPrice = avgPrice;
            lastPriceUpdateTime = block.timestamp;

            // Sync with AI Engine if we didn't get its price
            if (address(aiEngine) != address(0) && useAIEngine && aiPrice == 0) {
                try aiEngine.updateTWAPPrice(avgPrice) {
                    emit AIEngineOperationExecuted("updateTWAPPrice", true);
                } catch {
                    emit AIEngineOperationExecuted("updateTWAPPrice", false);
                }
            }

            emit TWAPPriceUpdated(avgPrice, block.timestamp, priceSource);
        }
    }

    /**
     * @notice Update TWAP price
     * @param price New TWAP price
     * @dev Requires NEURAL_INDEXER_ROLE
     * @custom:reverts InvalidParameters If price is zero
     * @custom:emits TWAPPriceUpdated On successful update
     * @custom:sync If enabled, updates AIEngine with new price
     */
    function updateTWAPPrice(uint256 price) external override onlyRole(NEURAL_INDEXER_ROLE) whenNotPaused {
        if (price == 0) revert InvalidParameters("price", "Cannot be zero");
        
        lastTWAPPrice = price;
        lastPriceUpdateTime = block.timestamp;
        
        // Sync with AI Engine if enabled
        if (address(aiEngine) != address(0) && syncWithAIEngine) {
            try aiEngine.updateTWAPPrice(price) {
                emit AIEngineOperationExecuted("updateTWAPPrice", true);
            } catch {
                emit AIEngineOperationExecuted("updateTWAPPrice", false);
            }
        }
        
        emit TWAPPriceUpdated(price, block.timestamp, "Manual");
    }

    /**
     * @notice Get current price
     * @return price Current TWAP price
     */
    function getCurrentPrice() external view override returns (uint256) {
        return lastTWAPPrice;
    }

    /**
     * @notice Get price feed address for an asset
     * @param asset Asset address
     * @return priceFeed Price feed address
     */
    function getAssetPriceFeed(address asset) external view override returns (address) {
        return address(priceFeedProxies[asset]);
    }

    // ================================
    // Diversity Index Management
    // ================================

    /**
     * @notice Update the diversity index
     * @dev Internal function that calculates HHI
     * @custom:emits DiversityIndexUpdated On successful update
     * @custom:sync If enabled, updates AIEngine with new diversity index
     */
    function _updateDiversityIndex() internal {
        uint256 activeCount;
        uint256 totalWeight;
        
        // First pass: count active and sum weights
        uint256 constituentCount = constituentList.length;
        for (uint256 i = 0; i < constituentCount; i++) {
            address asset = constituentList[i];
            if (constituents[asset].isActive) {
                activeCount++;
                totalWeight += assetNeuralWeights[asset].currentWeight;
            }
        }

        // Check minimum diversity
        if (activeCount < MIN_CONSTITUENTS && constituentCount >= MIN_CONSTITUENTS) {
            revert InsufficientGeneticDiversity();
        }

        // Calculate HHI if we have weights
        uint256 sumSquared;
        if (totalWeight > 0) {
            for (uint256 i = 0; i < constituentCount; i++) {
                address asset = constituentList[i];
                if (constituents[asset].isActive) {
                    uint256 share = (assetNeuralWeights[asset].currentWeight * 10000) / totalWeight;
                    sumSquared += (share * share);
                }
            }
            diversityIndex = sumSquared;
        } else {
            diversityIndex = activeCount > 0 ? 10000 / activeCount : 0;
        }

        // Sync with AI Engine if enabled
        if (address(aiEngine) != address(0) && useAIEngine) {
            try aiEngine.updateDiversityIndex(diversityIndex) {
                emit AIEngineOperationExecuted("updateDiversityIndex", true);
            } catch {
                emit AIEngineOperationExecuted("updateDiversityIndex", false);
            }
        }

        emit DiversityIndexUpdated(diversityIndex);
    }

    /**
     * @notice Recalculate diversity index
     * @dev Public function to force recalculation
     * @custom:reverts InsufficientGeneticDiversity If active constituents below minimum
     * @custom:emits DiversityIndexUpdated On successful update
     */
    function recalculateDiversityIndex() external override onlyRole(NEURAL_INDEXER_ROLE) whenNotPaused {
        _updateDiversityIndex();
    }

    /**
     * @notice Reset optimization cycle
     * @dev Requires AI_MANAGER_ROLE
     * @custom:emits ConfigUpdated On successful reset
     * @custom:sync If enabled, resets optimization cycle in AIEngine
     */
    function resetOptimizationCycle() external override onlyRole(AI_MANAGER_ROLE) whenNotPaused {
        selfOptimizationCounter = 0;
        lastAdaptiveLearningUpdate = block.timestamp;
        
        // Sync with AI Engine if enabled
        if (address(aiEngine) != address(0) && useAIEngine) {
            try aiEngine.resetOptimizationCycle() {
                emit AIEngineOperationExecuted("resetOptimizationCycle", true);
            } catch {
                emit AIEngineOperationExecuted("resetOptimizationCycle", false);
            }
        }
        
        emit ConfigUpdated("optimizationCycle", 0);
    }

    /**
     * @notice Manually sync with AI Engine
     * @dev Requires ADMIN_ROLE
     * @custom:reverts InvalidParameters If AI Engine not set
     * @custom:emits AIEngineOperationExecuted For each sync operation
     * @custom:emits SyncFailed For each failed sync operation
     */
    function manualSyncWithAIEngine() external override onlyRole(ADMIN_ROLE) whenNotPaused {
        if (address(aiEngine) == address(0)) {
            revert InvalidParameters("aiEngine", "Not set");
        }
        
        // Sync diversity index
        try aiEngine.updateDiversityIndex(diversityIndex) {
            emit AIEngineOperationExecuted("updateDiversityIndex", true);
        } catch {
            emit AIEngineOperationExecuted("updateDiversityIndex", false);
        }
        
        // Sync active constituents
        uint256 constituentCount = constituentList.length;
        for (uint256 i = 0; i < constituentCount; i++) {
            address asset = constituentList[i];
            if (constituents[asset].isActive) {
                try aiEngine.addConstituent(asset, address(priceFeedProxies[asset])) {
                    emit AIEngineOperationExecuted("addConstituent", true);
                } catch {
                    emit AIEngineOperationExecuted("addConstituent", false);
                    emit SyncFailed("addConstituent", asset);
                }
                
                // Sync neural weights
                NeuralWeight storage weight = assetNeuralWeights[asset];
                try aiEngine.updateNeuralWeight(
                    asset, 
                    weight.rawSignal, 
                    weight.emaSmoothingFactor
                ) {
                    emit AIEngineOperationExecuted("updateNeuralWeight", true);
                } catch {
                    emit AIEngineOperationExecuted("updateNeuralWeight", false);
                    emit SyncFailed("updateNeuralWeight", asset);
                }
                
                // Sync evolution scores
                try aiEngine.updateEvolutionScore(asset, constituents[asset].evolutionScore) {
                    emit AIEngineOperationExecuted("updateEvolutionScore", true);
                } catch {
                    emit AIEngineOperationExecuted("updateEvolutionScore", false);
                    emit SyncFailed("updateEvolutionScore", asset);
                }
            }
        }
        
        // Sync TWAP price
        if (lastTWAPPrice > 0) {
            try aiEngine.updateTWAPPrice(lastTWAPPrice) {
                emit AIEngineOperationExecuted("updateTWAPPrice", true);
            } catch {
                emit AIEngineOperationExecuted("updateTWAPPrice", false);
            }
        }
        
        emit ConfigUpdated("manualSync", block.timestamp);
    }

    // ================================
    // View Functions
    // ================================

    /**
     * @notice Get active constituents count
     * @return count Number of active constituents
     */
    function getActiveConstituentsCount() external view override returns (uint256) {
        if (address(aiEngine) != address(0) && useAIEngine) {
            try aiEngine.activeConstituentCount() returns (uint256 count) {
                return count;
            } catch {
                // Fall through
            }
        }

        uint256 count;
        uint256 constituentCount = constituentList.length;
        for (uint256 i = 0; i < constituentCount; i++) {
            if (constituents[constituentList[i]].isActive) {
                count++;
            }
        }
        return count;
    }

    /**
     * @notice Get ecosystem health metrics
     * @return diversityIdx Current diversity index
     * @return geneticVol Current genetic volatility
     * @return activeConstituents Number of active constituents
     * @return adaptiveThreshold Current adaptive threshold
     * @return currentPrice Current TWAP price
     * @return selfOptCounter Self-optimization counter
     */
    function getEcosystemHealthMetrics() external view override returns (
        uint256 diversityIdx,
        uint256 geneticVol,
        uint256 activeConstituents,
        uint256 adaptiveThreshold,
        uint256 currentPrice,
        uint256 selfOptCounter
    ) {
        if (address(aiEngine) != address(0) && useAIEngine) {
            try aiEngine.getEcosystemHealthMetrics() returns (
                uint256 aiDiversity,
                uint256 aiVolatility,
                uint256 aiActive,
                uint256 aiThreshold,
                uint256 aiPrice,
                uint256 aiCounter
            ) {
                return (
                    aiDiversity,
                    aiVolatility,
                    aiActive,
                    aiThreshold,
                    aiPrice,
                    aiCounter
                );
            } catch {
                // Fall through
            }
        }

        uint256 activeCount;
        uint256 constituentCount = constituentList.length;
        for (uint256 i = 0; i < constituentCount; i++) {
            if (constituents[constituentList[i]].isActive) {
                activeCount++;
            }
        }

        return (
            diversityIndex,
            geneticVolatility,
            activeCount,
            adaptiveVolatilityThreshold,
            lastTWAPPrice,
            selfOptimizationCounter
        );
    }

    // ================================
    // Upgrade Functions
    // ================================

    /**
     * @dev Authorize upgrade
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}

    /**
     * @notice Pause contract functionality
     * @dev Requires ADMIN_ROLE
     */
    function pause() external override onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause contract functionality
     * @dev Requires ADMIN_ROLE
     */
    function unpause() external override onlyRole(ADMIN_ROLE) {
        _unpause();
    }
}                    