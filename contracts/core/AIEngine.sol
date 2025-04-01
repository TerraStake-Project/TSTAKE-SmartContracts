// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@api3/contracts/v0.8/interfaces/IProxy.sol";

/**
 * @title AIEngine
 * @notice AI-driven asset management with ML predictions and liquidity optimization for TerraStakeToken
 * @dev Uses API3 dAPIs for price and ML prediction data, with dynamic staking reward adjustments
 */
contract AIEngine is
    Initializable,
    AccessControlEnumerableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // ===========================
    // Custom Errors
    // ===========================
    error Unauthorized(address caller, bytes32 requiredRole);
    error ZeroAddress();
    error InvalidParameters(string paramName, string reason);
    error StaleOracleData(uint256 lastUpdate, uint256 currentTime);
    error InvalidOracleData(address oracle, string reason);
    error HighVolatility(uint256 volatility, uint256 threshold);
    error GovernanceThresholdNotMet(address proposer, uint256 required, uint256 actual);
    error UnsupportedChain(uint16 chainId);

    // ===========================
    // Constants
    // ===========================
    uint256 private constant MAX_SIGNAL_VALUE = 1e30;
    uint256 private constant MAX_EMA_SMOOTHING = 100;
    uint256 private constant DEFAULT_REBALANCE_INTERVAL = 1 days;
    uint256 private constant MAX_PRICE_STALENESS = 24 hours;
    uint256 private constant MAX_PRICE_DEVIATION = 2000; // 20% in basis points
    uint256 private constant MIN_DIVERSITY_INDEX = 500;
    uint256 private constant MAX_DIVERSITY_INDEX = 2500;
    uint256 private constant MAX_TIMELOCK = 7 days;
    uint256 private constant MAX_REWARD_MULTIPLIER = 500; // 5x in basis points (100 = 1x)
    uint256 private constant MIN_REWARD_MULTIPLIER = 50;  // 0.5x in basis points

    // ===========================
    // Roles
    // ===========================
    bytes32 public constant AI_ADMIN_ROLE = keccak256("AI_ADMIN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant CROSS_CHAIN_OPERATOR_ROLE = keccak256("CROSS_CHAIN_OPERATOR_ROLE");

    // ===========================
    // Structs
    // ===========================
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

    // ===========================
    // State Variables
    // ===========================
    mapping(address => NeuralWeight) public assetNeuralWeights;
    mapping(address => Constituent) public constituents;
    address[] public constituentList;
    uint256 public activeConstituentCount;

    mapping(address => IProxy) public priceFeeds;
    IProxy public mlPredictionFeed; // Oracle for ML predictions

    uint256 public diversityIndex;
    uint256 public geneticVolatility;
    uint256 public adaptiveVolatilityThreshold;
    uint256 public rebalanceInterval;
    uint256 public lastRebalanceTime;

    uint256 public requiredApprovals;
    uint256 public operationTimelock;
    mapping(bytes32 => uint256) public operationApprovals;
    mapping(bytes32 => mapping(address => bool)) public hasApproved;
    mapping(bytes32 => uint256) public operationScheduledTime;

    mapping(uint16 => bool) public supportedChainIds;
    address public crossChainHandler;

    // Liquidity Optimization
    uint256 public baseRewardRate; // Base staking reward rate in basis points (100 = 1%)
    uint256 public liquidityAdjustmentFactor; // Factor for adjusting rewards based on liquidity (basis points)

    // ===========================
    // Events
    // ===========================
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

    // ===========================
    // Initialization
    // ===========================
    constructor() {
        _disableInitializers();
    }

    function initialize(address _crossChainHandler, address _mlPredictionFeed) public initializer {
        if (_crossChainHandler == address(0) || _mlPredictionFeed == address(0)) revert ZeroAddress();

        __AccessControlEnumerable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(AI_ADMIN_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        _grantRole(CROSS_CHAIN_OPERATOR_ROLE, msg.sender);

        rebalanceInterval = DEFAULT_REBALANCE_INTERVAL;
        adaptiveVolatilityThreshold = 15;
        lastRebalanceTime = block.timestamp;
        requiredApprovals = 2;
        operationTimelock = 1 days;
        crossChainHandler = _crossChainHandler;
        mlPredictionFeed = IProxy(_mlPredictionFeed);

        baseRewardRate = 100; // 1% default
        liquidityAdjustmentFactor = 100; // 1x default
    }

    // ===========================
    // Constituent Management
    // ===========================
    function updateConstituent(address asset, address priceFeed, bool isActive)
        external
        onlyRole(AI_ADMIN_ROLE)
        nonReentrant
        whenNotPaused
    {
        if (asset == address(0) || (isActive && priceFeed == address(0))) revert ZeroAddress();

        Constituent storage constituent = constituents[asset];
        bool wasActive = constituent.isActive;

        if (isActive && !wasActive) {
            priceFeeds[asset] = IProxy(priceFeed);
            constituent.isActive = true;
            constituent.activationTime = block.timestamp;
            constituent.evolutionScore = 0;
            constituent.lastPrice = fetchLatestPrice(asset);
            constituent.lastPriceUpdateTime = block.timestamp;
            constituent.rewardMultiplier = 100; // Default 1x
            constituentList.push(asset);
            activeConstituentCount++;
            emit ConstituentAdded(asset, block.timestamp);
        } else if (!isActive && wasActive) {
            constituent.isActive = false;
            activeConstituentCount--;
            emit ConstituentDeactivated(asset, block.timestamp);
        } else {
            revert InvalidParameters("status", "No change needed");
        }

        _updateDiversityIndex();
    }

    function getActiveConstituents() external view returns (address[] memory) {
        address[] memory activeAssets = new address[](activeConstituentCount);
        uint256 index;
        for (uint256 i = 0; i < constituentList.length && index < activeConstituentCount; i++) {
            if (constituents[constituentList[i]].isActive) {
                activeAssets[index++] = constituentList[i];
            }
        }
        return activeAssets;
    }

    // ===========================
    // Neural Weight Management
    // ===========================
    function updateNeuralWeight(address asset, uint256 newRawSignal, uint256 smoothingFactor)
        public
        onlyRole(AI_ADMIN_ROLE)
        whenNotPaused
    {
        if (!constituents[asset].isActive) revert InvalidParameters("asset", "Not active");
        if (newRawSignal > MAX_SIGNAL_VALUE) revert InvalidParameters("signal", "Exceeds max value");
        if (smoothingFactor == 0 || smoothingFactor > MAX_EMA_SMOOTHING) revert InvalidParameters("smoothing", "Invalid factor");

        NeuralWeight storage weight = assetNeuralWeights[asset];
        weight.rawSignal = newRawSignal;
        weight.currentWeight = weight.lastUpdateTime == 0
            ? newRawSignal
            : (newRawSignal * smoothingFactor + weight.currentWeight * (MAX_EMA_SMOOTHING - smoothingFactor)) / MAX_EMA_SMOOTHING;
        weight.lastUpdateTime = block.timestamp;
        weight.emaSmoothingFactor = smoothingFactor;

        emit NeuralWeightUpdated(asset, weight.currentWeight, newRawSignal, smoothingFactor);
        _updateDiversityIndex();
    }

    function batchUpdateNeuralWeights(address[] calldata assets, uint256[] calldata newRawSignals, uint256[] calldata smoothingFactors)
        external
        onlyRole(AI_ADMIN_ROLE)
        whenNotPaused
    {
        if (assets.length != newRawSignals.length || assets.length != smoothingFactors.length) 
            revert InvalidParameters("arrays", "Length mismatch");

        for (uint256 i = 0; i < assets.length; i++) {
            if (constituents[assets[i]].isActive) {
                updateNeuralWeight(assets[i], newRawSignals[i], smoothingFactors[i]);
            }
        }
    }

    // ===========================
    // AI Learning Enhancements
    // ===========================
    function updateMLPredictions(address asset) external onlyRole(AI_ADMIN_ROLE) whenNotPaused {
        if (address(mlPredictionFeed) == address(0)) revert InvalidParameters("mlFeed", "Not configured");

        (int224 prediction, uint256 updatedAt) = mlPredictionFeed.read();
        if (prediction == 0) revert InvalidOracleData(address(mlPredictionFeed), "Zero prediction");
        if (block.timestamp - updatedAt > MAX_PRICE_STALENESS) revert StaleOracleData(updatedAt, block.timestamp);

        Constituent storage constituent = constituents[asset];
        if (!constituent.isActive) revert InvalidParameters("asset", "Not active");

        constituent.predictedPriceChange = int256(prediction);
        emit PredictionUpdated(asset, int256(prediction), block.timestamp);

        // Adjust neural weight based on prediction
        NeuralWeight storage weight = assetNeuralWeights[asset];
        uint256 adjustmentFactor = prediction > 0 ? 110 : 90; // +10% or -10% based on prediction direction
        weight.currentWeight = (weight.currentWeight * adjustmentFactor) / 100;
        if (weight.currentWeight > MAX_SIGNAL_VALUE) weight.currentWeight = MAX_SIGNAL_VALUE;
        emit NeuralWeightUpdated(asset, weight.currentWeight, weight.rawSignal, weight.emaSmoothingFactor);

        _updateDiversityIndex();
        _adjustRewardMultiplier(asset);
    }

    // ===========================
    // Diversity Index
    // ===========================
    function _updateDiversityIndex() internal {
        if (activeConstituentCount == 0) {
            diversityIndex = 0;
            emit DiversityIndexUpdated(0);
            return;
        }

        uint256 totalWeight;
        uint256[] memory weights = new uint256[](activeConstituentCount);
        uint256 index;

        for (uint256 i = 0; i < constituentList.length && index < activeConstituentCount; i++) {
            address asset = constituentList[i];
            if (constituents[asset].isActive) {
                weights[index] = assetNeuralWeights[asset].currentWeight;
                totalWeight += weights[index];
                index++;
            }
        }

        if (totalWeight == 0) {
            diversityIndex = 0;
            emit DiversityIndexUpdated(0);
            return;
        }

        uint256 sumSquared;
        for (uint256 i = 0; i < activeConstituentCount; i++) {
            if (weights[i] > 0) {
                uint256 percentShare = (weights[i] * 10000) / totalWeight;
                sumSquared += percentShare * percentShare;
            }
        }

        diversityIndex = sumSquared;
        emit DiversityIndexUpdated(sumSquared);
    }

    function recalculateDiversityIndex() external onlyRole(AI_ADMIN_ROLE) whenNotPaused {
        _updateDiversityIndex();
    }

    // ===========================
    // API3 Oracle Integration
    // ===========================
    function fetchLatestPrice(address asset) public returns (uint256) {
        IProxy priceFeed = priceFeeds[asset];
        if (address(priceFeed) == address(0)) revert InvalidParameters("asset", "No price feed");

        (int224 price, uint256 updatedAt) = priceFeed.read();
        if (price <= 0) revert InvalidOracleData(address(priceFeed), "Negative or zero price");
        if (block.timestamp - updatedAt > MAX_PRICE_STALENESS) revert StaleOracleData(updatedAt, block.timestamp);

        uint256 newPrice = uint256(price);
        Constituent storage constituent = constituents[asset];
        uint256 oldPrice = constituent.lastPrice;

        if (oldPrice > 0) {
            uint256 deviation = newPrice > oldPrice
                ? ((newPrice - oldPrice) * 10000) / oldPrice
                : ((oldPrice - newPrice) * 10000) / oldPrice;
            if (deviation > MAX_PRICE_DEVIATION) {
                emit CircuitBreaker(asset, oldPrice, newPrice, deviation);
                if (deviation > MAX_PRICE_DEVIATION * 2) {
                    bytes32 operationId = keccak256(abi.encode("acceptPriceDeviation", asset, newPrice, block.timestamp));
                    if (!hasRole(EMERGENCY_ROLE, msg.sender) && operationApprovals[operationId] < requiredApprovals) {
                        revert InvalidParameters("price", "Extreme deviation requires approval");
                    }
                }
            }
        }

        constituent.lastPrice = newPrice;
        constituent.lastPriceUpdateTime = block.timestamp;
        emit PriceUpdated(asset, newPrice, block.timestamp);
        return newPrice;
    }

    function getLatestPrice(address asset) external view returns (uint256 price, bool isFresh) {
        IProxy priceFeed = priceFeeds[asset];
        if (address(priceFeed) == address(0)) return (0, false);

        (int224 priceInt, uint256 updatedAt) = priceFeed.read();
        price = priceInt > 0 ? uint256(priceInt) : 0;
        isFresh = updatedAt > 0 && block.timestamp - updatedAt <= MAX_PRICE_STALENESS;
    }

    function updatePriceFeedAddress(address asset, address newPriceFeed)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (newPriceFeed == address(0)) revert ZeroAddress();
        bytes32 operationId = keccak256(abi.encode("updatePriceFeed", asset, newPriceFeed, block.timestamp));
        if (operationApprovals[operationId] < requiredApprovals) 
            revert GovernanceThresholdNotMet(msg.sender, requiredApprovals, operationApprovals[operationId]);
        if (block.timestamp < operationScheduledTime[operationId]) 
            revert InvalidParameters("timelock", "Not elapsed");

        delete operationApprovals[operationId];
        delete operationScheduledTime[operationId];

        priceFeeds[asset] = IProxy(newPriceFeed);
        fetchLatestPrice(asset);
    }

    // ===========================
    // Liquidity Optimization
    // ===========================
    function _adjustRewardMultiplier(address asset) internal {
        Constituent storage constituent = constituents[asset];
        int256 prediction = constituent.predictedPriceChange;
        uint256 volatility = geneticVolatility;

        // Base adjustment: increase rewards for positive predictions, decrease for negative
        uint256 multiplier = baseRewardRate;
        if (prediction > 0) {
            multiplier += uint256(prediction) * liquidityAdjustmentFactor / 10000; // Scale by prediction magnitude
        } else if (prediction < 0) {
            multiplier = multiplier * (10000 - uint256(-prediction)) / 10000; // Reduce by negative prediction
        }

        // Volatility adjustment: higher volatility increases rewards to incentivize staking
        if (volatility > adaptiveVolatilityThreshold) {
            multiplier += (volatility - adaptiveVolatilityThreshold) * 10; // +10% per volatility point above threshold
        }

        // Cap the multiplier
        if (multiplier > MAX_REWARD_MULTIPLIER) multiplier = MAX_REWARD_MULTIPLIER;
        if (multiplier < MIN_REWARD_MULTIPLIER) multiplier = MIN_REWARD_MULTIPLIER;

        constituent.rewardMultiplier = multiplier;
        emit RewardMultiplierUpdated(asset, multiplier, block.timestamp);
    }

    function setLiquidityConfig(uint256 _baseRewardRate, uint256 _liquidityAdjustmentFactor) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (_baseRewardRate < 10 || _baseRewardRate > 1000) revert InvalidParameters("baseRewardRate", "Out of bounds");
        if (_liquidityAdjustmentFactor < 50 || _liquidityAdjustmentFactor > 200) 
            revert InvalidParameters("liquidityAdjustmentFactor", "Out of bounds");

        baseRewardRate = _baseRewardRate;
        liquidityAdjustmentFactor = _liquidityAdjustmentFactor;
        emit ConfigUpdated("baseRewardRate", _baseRewardRate);
        emit ConfigUpdated("liquidityAdjustmentFactor", _liquidityAdjustmentFactor);
    }

    // ===========================
    // Rebalancing Logic
    // ===========================
    function shouldRebalance() public view returns (bool, string memory) {
        if (block.timestamp >= lastRebalanceTime + rebalanceInterval) return (true, "Time-based rebalance");
        if (diversityIndex > MAX_DIVERSITY_INDEX) return (true, "Diversity too concentrated");
        if (diversityIndex < MIN_DIVERSITY_INDEX && diversityIndex > 0) return (true, "Diversity too dispersed");
        if (geneticVolatility > adaptiveVolatilityThreshold) return (true, "Volatility threshold breached");
        return (false, "No rebalance needed");
    }

    function triggerRebalance() external onlyRole(AI_ADMIN_ROLE) nonReentrant whenNotPaused returns (string memory) {
        (bool should, string memory reason) = shouldRebalance();
        if (!should) revert InvalidParameters("rebalance", "Not needed");
        lastRebalanceTime = block.timestamp;
        emit AdaptiveRebalanceTriggered(reason, block.timestamp);
        return reason;
    }

    function updateGeneticVolatility(uint256 newVolatility) external onlyRole(AI_ADMIN_ROLE) whenNotPaused {
        geneticVolatility = newVolatility;
        if (newVolatility > adaptiveVolatilityThreshold && block.timestamp >= lastRebalanceTime + (rebalanceInterval / 4)) {
            lastRebalanceTime = block.timestamp;
            emit AdaptiveRebalanceTriggered("Volatility threshold breach", block.timestamp);
        }
    }

    // ===========================
    // Configuration
    // ===========================
    function setConfig(string calldata parameter, uint256 value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 paramHash = keccak256(abi.encodePacked(parameter));
        if (paramHash == keccak256(abi.encodePacked("rebalanceInterval"))) {
            if (value < 1 hours || value > 30 days) revert InvalidParameters("interval", "Out of bounds");
            rebalanceInterval = value;
        } else if (paramHash == keccak256(abi.encodePacked("volatilityThreshold"))) {
            if (value == 0 || value > 100) revert InvalidParameters("threshold", "Out of bounds");
            adaptiveVolatilityThreshold = value;
        } else if (paramHash == keccak256(abi.encodePacked("requiredApprovals"))) {
            if (value == 0 || value > getRoleMemberCount(AI_ADMIN_ROLE)) revert InvalidParameters("approvals", "Out of bounds");
            requiredApprovals = value;
        } else if (paramHash == keccak256(abi.encodePacked("operationTimelock"))) {
            if (value > MAX_TIMELOCK) revert InvalidParameters("timelock", "Too long");
            operationTimelock = value;
        } else {
            revert InvalidParameters("parameter", "Unknown");
        }
        emit ConfigUpdated(parameter, value);
    }

    // ===========================
    // Governance
    // ===========================
    function approveOperation(bytes32 operationId) external onlyRole(AI_ADMIN_ROLE) {
        if (hasApproved[operationId][msg.sender]) revert InvalidParameters("operation", "Already approved");
        hasApproved[operationId][msg.sender] = true;
        operationApprovals[operationId]++;
        emit OperationApproved(operationId, msg.sender, operationApprovals[operationId]);
    }

    function revokeApproval(bytes32 operationId) external {
        if (!hasApproved[operationId][msg.sender]) revert InvalidParameters("operation", "Not approved");
        hasApproved[operationId][msg.sender] = false;
        operationApprovals[operationId]--;
        emit OperationApproved(operationId, msg.sender, operationApprovals[operationId]);
    }

    function scheduleOperation(bytes32 operationId) external onlyRole(AI_ADMIN_ROLE) {
        if (operationApprovals[operationId] < requiredApprovals) 
            revert GovernanceThresholdNotMet(msg.sender, requiredApprovals, operationApprovals[operationId]);
        if (operationScheduledTime[operationId] != 0) revert InvalidParameters("operation", "Already scheduled");
        operationScheduledTime[operationId] = block.timestamp + operationTimelock;
        emit OperationScheduled(operationId, operationScheduledTime[operationId]);
    }

    function getOperationId(string calldata action, bytes calldata data) external view returns (bytes32) {
        return keccak256(abi.encode(action, data, block.timestamp));
    }

    // ===========================
    // Cross-Chain Sync
    // ===========================
    function syncCrossChainState(uint16 chainId, address asset, bool isActive, uint256 weight)
        external
        onlyRole(CROSS_CHAIN_OPERATOR_ROLE)
        whenNotPaused
    {
        if (!supportedChainIds[chainId]) revert UnsupportedChain(chainId);

        Constituent storage constituent = constituents[asset];
        bool wasActive = constituent.isActive;

        if (isActive != wasActive) {
            constituent.isActive = isActive;
            if (isActive) {
                if (address(priceFeeds[asset]) == address(0)) revert InvalidParameters("asset", "No price feed");
                constituent.activationTime = block.timestamp;
                constituent.lastPrice = fetchLatestPrice(asset);
                constituent.lastPriceUpdateTime = block.timestamp;
                constituent.rewardMultiplier = 100; // Default 1x
                constituentList.push(asset);
                activeConstituentCount++;
                emit ConstituentAdded(asset, block.timestamp);
            } else {
                activeConstituentCount--;
                emit ConstituentDeactivated(asset, block.timestamp);
            }
            _updateDiversityIndex();
        }

        if (isActive) {
            NeuralWeight storage weightData = assetNeuralWeights[asset];
            weightData.currentWeight = weight;
            weightData.lastUpdateTime = block.timestamp;
        }

        emit CrossChainSyncExecuted(chainId, asset, isActive, weight);
    }

    function addSupportedChain(uint16 chainId) external onlyRole(AI_ADMIN_ROLE) {
        if (supportedChainIds[chainId]) revert InvalidParameters("chainId", "Already supported");
        supportedChainIds[chainId] = true;
    }

    function removeSupportedChain(uint16 chainId) external onlyRole(AI_ADMIN_ROLE) {
        if (!supportedChainIds[chainId]) revert InvalidParameters("chainId", "Not supported");
        supportedChainIds[chainId] = false;
    }

    function updateCrossChainHandler(address newHandler) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newHandler == address(0)) revert ZeroAddress();
        crossChainHandler = newHandler;
        emit ConfigUpdated("crossChainHandler", uint256(uint160(newHandler)));
    }

    // ===========================
    // TerraStakeToken Sync
    // ===========================
    function syncConstituentStatus(address asset, bool isActive, uint256 currentWeight)
        external
        onlyRole(AI_ADMIN_ROLE)
        whenNotPaused
    {
        Constituent storage constituent = constituents[asset];
        bool wasActive = constituent.isActive;

        if (isActive != wasActive) {
            constituent.isActive = isActive;
            if (isActive) {
                if (address(priceFeeds[asset]) == address(0)) revert InvalidParameters("asset", "No price feed");
                constituent.activationTime = block.timestamp;
                constituent.lastPrice = fetchLatestPrice(asset);
                constituent.lastPriceUpdateTime = block.timestamp;
                constituent.rewardMultiplier = 100; // Default 1x
                constituentList.push(asset);
                activeConstituentCount++;
                emit ConstituentAdded(asset, block.timestamp);
            } else {
                activeConstituentCount--;
                emit ConstituentDeactivated(asset, block.timestamp);
            }
            _updateDiversityIndex();
        }
        if (isActive) assetNeuralWeights[asset].currentWeight = currentWeight;
    }

    function getPriceDataForRebalancing()
        external
        view
        returns (address[] memory assets, uint256[] memory prices, uint256[] memory rewardMultipliers, uint256 volatility)
    {
        assets = new address[](activeConstituentCount);
        prices = new uint256[](activeConstituentCount);
        rewardMultipliers = new uint256[](activeConstituentCount);
        uint256 index;
        for (uint256 i = 0; i < constituentList.length && index < activeConstituentCount; i++) {
            address asset = constituentList[i];
            if (constituents[asset].isActive) {
                assets[index] = asset;
                prices[index] = constituents[asset].lastPrice;
                rewardMultipliers[index] = constituents[asset].rewardMultiplier;
                index++;
            }
        }
        volatility = geneticVolatility;
    }

    // ===========================
    // Emergency Controls
    // ===========================
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function emergencyResetWeights() external nonReentrant {
        bytes32 operationId = keccak256(abi.encode("emergencyResetWeights", block.timestamp));
        if (!hasRole(EMERGENCY_ROLE, msg.sender) || operationApprovals[operationId] < requiredApprovals) 
            revert GovernanceThresholdNotMet(msg.sender, requiredApprovals, operationApprovals[operationId]);

        delete operationApprovals[operationId];

        for (uint256 i = 0; i < constituentList.length; i++) {
            address asset = constituentList[i];
            if (constituents[asset].isActive) {
                delete assetNeuralWeights[asset];
                constituents[asset].rewardMultiplier = 100; // Reset to 1x
            }
        }

        diversityIndex = 0;
        geneticVolatility = 0;
        emit ConfigUpdated("emergencyReset", block.timestamp);
    }

    function clearPriceDeviationAlert(address asset) external onlyRole(EMERGENCY_ROLE) nonReentrant {
        IProxy priceFeed = priceFeeds[asset];
        if (address(priceFeed) == address(0)) revert InvalidParameters("asset", "No price feed");

        (int224 price, uint256 updatedAt) = priceFeed.read();
        if (price <= 0 || updatedAt == 0) revert InvalidOracleData(address(priceFeed), "Invalid price data");

        uint256 newPrice = uint256(price);
        constituents[asset].lastPrice = newPrice;
        constituents[asset].lastPriceUpdateTime = block.timestamp;
        emit PriceUpdated(asset, newPrice, block.timestamp);
    }

    // ===========================
    // Upgradeability
    // ===========================
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        bytes32 operationId = keccak256(abi.encode("upgrade", newImplementation, block.timestamp));
        if (operationApprovals[operationId] < requiredApprovals) 
            revert GovernanceThresholdNotMet(msg.sender, requiredApprovals, operationApprovals[operationId]);
        if (block.timestamp < operationScheduledTime[operationId]) 
            revert InvalidParameters("timelock", "Not elapsed");
        delete operationApprovals[operationId];
        delete operationScheduledTime[operationId];
    }
}