// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";

/**
 * @title AIEngine
 * @author TerraStake Protocol
 * @notice AI-driven portfolio rebalancing engine with Chainlink integration
 * @dev Uses Exponential Moving Average (EMA) for asset weight calculation
 */
contract AIEngine is 
    Initializable, 
    AccessControlEnumerableUpgradeable, 
    PausableUpgradeable,
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable, 
    AutomationCompatibleInterface 
{
    // ================================
    //  Constants
    // ================================
    
    /// @notice Maximum allowed signal value
    uint256 public constant MAX_SIGNAL_VALUE = 1e30;
    
    /// @notice Maximum EMA smoothing factor (1-100 scale)
    uint256 public constant MAX_EMA_SMOOTHING = 100;
    
    /// @notice Default rebalance interval (1 day)
    uint256 public constant DEFAULT_REBALANCE_INTERVAL = 1 days;
    
    /// @notice Minimum diversity index considered healthy
    uint256 public constant MIN_DIVERSITY_INDEX = 500;
    
    /// @notice Maximum diversity index considered healthy
    uint256 public constant MAX_DIVERSITY_INDEX = 2500;
    
    // ================================
    //  Roles
    // ================================
    
    /// @notice Role for managing neural weights and rebalancing
    bytes32 public constant AI_ADMIN_ROLE = keccak256("AI_ADMIN_ROLE");
    
    /// @notice Role for emergency operations and pausing
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    /// @notice Role for upgrading the contract
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    
    /// @notice Role for Chainlink automation
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    // ================================
    //  Chainlink Integration
    // ================================
    
    /// @notice Chainlink Price Feed interface
    AggregatorV3Interface public priceFeed;
    
    /// @notice Latest price from Chainlink
    uint256 public lastPrice;
    
    /// @notice Last price update timestamp
    uint256 public lastPriceUpdateTime;
    
    /// @notice Maximum price staleness allowed (24 hours)
    uint256 public constant MAX_PRICE_STALENESS = 24 hours;

    // ================================
    //  Data Structures
    // ================================
    
    /**
     * @notice Neural weight parameters using EMA methodology
     * @param currentWeight EMA-based weight value (1e18 scale)
     * @param rawSignal Raw input signal from AI system
     * @param lastUpdateTime Timestamp of last weight update
     * @param emaSmoothingFactor Smoothing factor used in EMA calculation (1-100 scale)
     */
    struct NeuralWeight {
        uint256 currentWeight;
        uint256 rawSignal;
        uint256 lastUpdateTime;
        uint256 emaSmoothingFactor;
    }

    /**
     * @notice DNA constituent metadata
     * @param isActive Whether the constituent is currently active
     * @param activationTime Timestamp when the constituent was activated
     * @param evolutionScore Score representing constituent performance
     */
    struct Constituent {
        bool isActive;
        uint256 activationTime;
        uint256 evolutionScore;
        uint256 index;
    }

    // ================================
    //  State Variables
    // ================================
    
    /// @notice Maps assets to their neural weights
    mapping(address => NeuralWeight) public assetNeuralWeights;
    
    /// @notice Maps assets to their constituent data
    mapping(address => Constituent) public constituents;
    
    /// @notice List of all constituent assets
    address[] public constituentList;
    
    /// @notice Count of active constituents
    uint256 public activeConstituentCount;
    
    /// @notice Diversity index (measures concentration, lower is more diverse)
    uint256 public diversityIndex;
    
    /// @notice Genetic volatility metric of the portfolio
    uint256 public geneticVolatility;
    
    /// @notice Interval between scheduled rebalances
    uint256 public rebalanceInterval;
    
    /// @notice Timestamp of the last rebalance
    uint256 public lastRebalanceTime;
    
    /// @notice Threshold for volatility-based rebalancing
    uint256 public adaptiveVolatilityThreshold;
    
    /// @notice Multi-sig requirement for sensitive operations
    uint256 public requiredApprovals;
    
    /// @notice Maps operation hashes to approval counts
    mapping(bytes32 => uint256) public operationApprovals;
    
    /// @notice Maps operation hashes and approvers to approval status
    mapping(bytes32 => mapping(address => bool)) public hasApproved;

    // ================================
    //  Events
    // ================================
    
    /// @notice Emitted when a neural weight is updated
    event NeuralWeightUpdated(address indexed asset, uint256 weight, uint256 rawSignal, uint256 smoothingFactor);
    
    /// @notice Emitted when diversity index is updated
    event DiversityIndexUpdated(uint256 newIndex);
    
    /// @notice Emitted when a rebalance is triggered
    event AdaptiveRebalanceTriggered(string reason, uint256 timestamp);
    
    /// @notice Emitted when a constituent is added
    event ConstituentAdded(address indexed asset, uint256 timestamp);
    
    /// @notice Emitted when a constituent is deactivated
    event ConstituentDeactivated(address indexed asset, uint256 timestamp);
    
    /// @notice Emitted when an operation is approved
    event OperationApproved(bytes32 indexed operationId, address indexed approver, uint256 currentApprovals);
    
    /// @notice Emitted when the contract configuration is updated
    event ConfigUpdated(string parameter, uint256 newValue);
    
    /// @notice Emitted when price is updated from Chainlink
    event PriceUpdated(uint256 price, uint256 timestamp);

    // ================================
    //  Modifiers
    // ================================
    
    /**
     * @notice Ensures the asset is a valid constituent
     * @param asset Address of the asset to check
     */
    modifier validConstituent(address asset) {
        require(constituents[asset].isActive, "Asset not active constituent");
        _;
    }
    
    /**
     * @notice Checks that Chainlink price feed is reasonably fresh
     */
    modifier freshPrice() {
        require(
            lastPriceUpdateTime > 0 && 
            block.timestamp - lastPriceUpdateTime <= MAX_PRICE_STALENESS,
            "Price data stale"
        );
        _;
    }
    
    /**
     * @notice Verifies operation has required approvals
     * @param operationId Hash of the operation
     */
    modifier withApprovals(bytes32 operationId) {
        require(operationApprovals[operationId] >= requiredApprovals, "Insufficient approvals");
        _;
        
        // Reset approvals after execution
        delete operationApprovals[operationId];
    }

    // ================================
    //  Initialization
    // ================================
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with default settings
     * @param _priceFeed Address of the Chainlink price feed
     */
    function initialize(address _priceFeed) public initializer {
        __AccessControlEnumerable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(AI_ADMIN_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        _grantRole(KEEPER_ROLE, msg.sender);
        
        require(_priceFeed != address(0), "Invalid price feed address");
        priceFeed = AggregatorV3Interface(_priceFeed);
        
        rebalanceInterval = DEFAULT_REBALANCE_INTERVAL;
        adaptiveVolatilityThreshold = 15;
        lastRebalanceTime = block.timestamp;
        requiredApprovals = 2; // Default to 2 approvals required
        
        // Initialize with first price fetch
        fetchLatestPrice();
    }

    // ================================
    //  Constituent Management
    // ================================
    
    /**
     * @notice Adds a new constituent to the system
     * @param asset Address of the asset to add
     */
    function addConstituent(address asset) external onlyRole(AI_ADMIN_ROLE) nonReentrant whenNotPaused {
        require(asset != address(0), "Cannot add zero address");
        require(!constituents[asset].isActive, "Asset already active");
        
        if (constituents[asset].activationTime == 0) {
            // New constituent
            constituents[asset].index = constituentList.length;
            constituentList.push(asset);
        }
        
        constituents[asset].isActive = true;
        constituents[asset].activationTime = block.timestamp;
        constituents[asset].evolutionScore = 0;
        
        activeConstituentCount++;
        
        emit ConstituentAdded(asset, block.timestamp);
    }
    
    /**
     * @notice Deactivates a constituent from the system
     * @param asset Address of the asset to deactivate
     */
    function deactivateConstituent(address asset) 
        external 
        onlyRole(AI_ADMIN_ROLE) 
        nonReentrant 
        validConstituent(asset) 
        whenNotPaused 
    {
        constituents[asset].isActive = false;
        activeConstituentCount--;
        
        emit ConstituentDeactivated(asset, block.timestamp);
        
        // Update diversity index after deactivation
        _updateDiversityIndex();
    }
    
    /**
     * @notice Returns all active constituents
     * @return activeAssets Array of active constituent addresses
     */
    function getActiveConstituents() external view returns (address[] memory activeAssets) {
        activeAssets = new address[](activeConstituentCount);
        
        uint256 activeIndex = 0;
        for (uint256 i = 0; i < constituentList.length; i++) {
            address asset = constituentList[i];
            if (constituents[asset].isActive) {
                activeAssets[activeIndex] = asset;
                activeIndex++;
            }
        }
        
        return activeAssets;
    }

    // ================================
    //  Neural Weight Management
    // ================================
    
    /**
     * @notice Updates the neural weight for a specific asset
     * @param asset Address of the asset to update
     * @param newRawSignal New raw signal from AI system
     * @param smoothingFactor EMA smoothing factor (1-100)
     */
    function updateNeuralWeight(
        address asset, 
        uint256 newRawSignal, 
        uint256 smoothingFactor
    ) 
        public 
        onlyRole(AI_ADMIN_ROLE) 
        validConstituent(asset) 
        whenNotPaused 
    {
        require(smoothingFactor > 0 && smoothingFactor <= MAX_EMA_SMOOTHING, "Invalid smoothing factor");
        require(newRawSignal <= MAX_SIGNAL_VALUE, "Signal exceeds maximum");
        
        NeuralWeight storage w = assetNeuralWeights[asset];
        
        // Update neural weight with EMA calculation
        w.rawSignal = newRawSignal;
        
        // If this is the first update, set directly
        if (w.lastUpdateTime == 0) {
            w.currentWeight = newRawSignal;
        } else {
            // Apply EMA formula: newEMA = (signal * α) + (oldEMA * (1-α))
            w.currentWeight = (newRawSignal * smoothingFactor + w.currentWeight * (MAX_EMA_SMOOTHING - smoothingFactor)) / MAX_EMA_SMOOTHING;
        }
        
        w.lastUpdateTime = block.timestamp;
        w.emaSmoothingFactor = smoothingFactor;
        
        emit NeuralWeightUpdated(asset, w.currentWeight, newRawSignal, smoothingFactor);
        
        // Update diversity index after weight change
        _updateDiversityIndex();
    }
    
    /**
     * @notice Updates neural weights for multiple assets
     * @param assets Array of asset addresses to update
     * @param newRawSignals Array of new raw signals
     * @param smoothingFactors Array of smoothing factors
     */
    function batchUpdateNeuralWeights(
        address[] calldata assets,
        uint256[] calldata newRawSignals,
        uint256[] calldata smoothingFactors
    ) 
        external 
        onlyRole(AI_ADMIN_ROLE) 
        whenNotPaused 
    {
        require(
            assets.length == newRawSignals.length && 
            assets.length == smoothingFactors.length,
            "Arrays length mismatch"
        );
        
        for (uint256 i = 0; i < assets.length; i++) {
            if (constituents[assets[i]].isActive) {
                updateNeuralWeight(assets[i], newRawSignals[i], smoothingFactors[i]);
            }
        }
    }

    // ================================
    //  Diversity Index Management
    // ================================
    
    /**
     * @notice Updates the diversity index calculation
     * @dev Calculates the concentration index (HHI-like) for portfolio diversity
     */
    function _updateDiversityIndex() internal {
        if (activeConstituentCount == 0) {
            diversityIndex = 0;
            emit DiversityIndexUpdated(diversityIndex);
            return;
        }
        
        uint256 totalWeight = 0;
        uint256 sumSquared = 0;
        
        // First pass: calculate total weight
        for (uint256 i = 0; i < constituentList.length; i++) {
            address asset = constituentList[i];
            if (constituents[asset].isActive) {
                totalWeight += assetNeuralWeights[asset].currentWeight;
            }
        }
        
        // Guard against division by zero
        if (totalWeight == 0) {
            diversityIndex = 0;
            emit DiversityIndexUpdated(diversityIndex);
            return;
        }
        
        // Second pass: calculate concentration index
        for (uint256 i = 0; i < constituentList.length; i++) {
            address asset = constituentList[i];
            if (constituents[asset].isActive) {
                uint256 weight = assetNeuralWeights[asset].currentWeight;
                uint256 percentShare = (weight * 10000) / totalWeight;
                sumSquared += (percentShare * percentShare);
            }
        }
        
        // Update the diversity index
        diversityIndex = sumSquared;
        
        emit DiversityIndexUpdated(diversityIndex);
    }
    
    /**
     * @notice Manually triggers a diversity index recalculation
     */
    function recalculateDiversityIndex() external onlyRole(AI_ADMIN_ROLE) whenNotPaused {
        _updateDiversityIndex();
    }

    // ================================
    //  Chainlink Integration
    // ================================
    
    /**
     * @notice Fetches the latest price from Chainlink
     * @return Latest price from the price feed
     */
    function fetchLatestPrice() public returns (uint256) {
        // Attempt to get the latest round data
        (
            uint80 roundId,
            int256 price,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();
        
        // Validation checks
        require(price > 0, "Negative or zero price");
        require(updatedAt > 0, "Round not complete");
        require(answeredInRound >= roundId, "Stale price data");
        
        // Update state
        lastPrice = uint256(price);
        lastPriceUpdateTime = block.timestamp;
        
        emit PriceUpdated(lastPrice, lastPriceUpdateTime);
        
        return lastPrice;
    }
    
    /**
     * @notice Gets the latest price without updating state
     * @return price Latest price and whether it's fresh
     * @return isFresh Boolean indicating if the price is fresh
     */
    function getLatestPrice() external view returns (uint256 price, bool isFresh) {
        return (
            lastPrice, 
            lastPriceUpdateTime > 0 && 
            block.timestamp - lastPriceUpdateTime <= MAX_PRICE_STALENESS
        );
    }
    
    /**
     * @notice Updates the Chainlink price feed address
     * @param newPriceFeed New price feed address
     */
    function updatePriceFeedAddress(address newPriceFeed) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        require(newPriceFeed != address(0), "Invalid price feed address");
        
        // Get operation ID for multi-sig approval
        bytes32 operationId = keccak256(abi.encode(
            "updatePriceFeed",
            newPriceFeed,
            block.timestamp
        ));
        
        // Require multi-sig approval
        require(operationApprovals[operationId] >= requiredApprovals, "Insufficient approvals");
        
        // Reset approvals
        delete operationApprovals[operationId];
        
        // Update price feed
        priceFeed = AggregatorV3Interface(newPriceFeed);
        
        // Fetch initial price
        fetchLatestPrice();
    }

    // ================================
    //  Rebalancing Logic
    // ================================
    
    /**
     * @notice Checks if an adaptive rebalance should be triggered
     * @return shouldRebalance Boolean indicating if rebalance is needed
     * @return reason String description of the rebalance reason
     */
    function shouldAdaptiveRebalance() public view returns (bool shouldRebalance, string memory reason) {
        // Time-based rebalance condition
        if (block.timestamp >= lastRebalanceTime + rebalanceInterval) {
            return (true, "Time-based rebalance");
        }
        
        // Diversity-based rebalance condition
        if (diversityIndex > MAX_DIVERSITY_INDEX) {
            return (true, "Diversity too concentrated");
        }
        
        if (diversityIndex < MIN_DIVERSITY_INDEX && diversityIndex > 0) {
            return (true, "Diversity too dispersed");
        }
        
        // Volatility-based rebalance condition
        if (geneticVolatility > adaptiveVolatilityThreshold) {
            return (true, "Volatility threshold breach");
        }
        
        return (false, "No rebalance needed");
    }
    
    /**
     * @notice Triggers an adaptive rebalance if conditions are met
     */
    function triggerAdaptiveRebalance() external onlyRole(AI_ADMIN_ROLE) nonReentrant whenNotPaused {
        (bool doRebalance, string memory reason) = shouldAdaptiveRebalance();
        require(doRebalance, "Rebalance not needed");
        
        lastRebalanceTime = block.timestamp;
        
        emit AdaptiveRebalanceTriggered(reason, block.timestamp);
    }
    
    /**
     * @notice Updates genetic volatility metric
     * @param newVolatility New volatility value
     */
    function updateGeneticVolatility(uint256 newVolatility) external onlyRole(AI_ADMIN_ROLE) whenNotPaused {
        geneticVolatility = newVolatility;
        
        // Check if volatility should trigger rebalance
        if (geneticVolatility > adaptiveVolatilityThreshold) {
            if (block.timestamp >= lastRebalanceTime + (rebalanceInterval / 4)) {
                lastRebalanceTime = block.timestamp;
                emit AdaptiveRebalanceTriggered("Volatility threshold breach", block.timestamp);
            }
        }
    }

    // ================================
    //  Chainlink Keeper Methods
    // ================================
    
    /**
     * @notice Checks if upkeep is needed (Chainlink Keeper compatible)
     * @return upkeepNeeded Whether upkeep is needed
     * @return performData Data needed for performing upkeep
     */
    function checkUpkeep(bytes calldata) 
        external 
        view 
        override 
        returns (bool upkeepNeeded, bytes memory performData) 
    {
        // Check if contract is paused
        if (paused()) {
            return (false, "");
        }
        
        // Check if rebalance is needed
        (bool shouldRebalance, ) = shouldAdaptiveRebalance();
        
        // Check if price needs updating
        bool needsPriceUpdate = lastPriceUpdateTime == 0 || 
            (block.timestamp - lastPriceUpdateTime > MAX_PRICE_STALENESS / 2);
        
        upkeepNeeded = shouldRebalance || needsPriceUpdate;
        
        // Encode which actions need to be performed
        performData = abi.encode(shouldRebalance, needsPriceUpdate);
        
        return (upkeepNeeded, performData);
    }
    
    /**
     * @notice Performs upkeep (Chainlink Keeper compatible)
     * @param performData Data specifying what upkeep to perform
     */
    function performUpkeep(bytes calldata performData) 
        external 
        override 
        nonReentrant 
    {
        require(
            hasRole(KEEPER_ROLE, msg.sender) || 
            msg.sender == tx.origin, // Allow EOAs to manually trigger
            "Not authorized for upkeep"
        );
        
        require(!paused(), "Contract is paused");
        
        (bool doRebalance, bool updatePrice) = abi.decode(performData, (bool, bool));
        
        // Update price if needed
        if (updatePrice) {
            fetchLatestPrice();
        }
        
        // Perform rebalance if needed
        if (doRebalance) {
            (bool shouldRebalance, string memory reason) = shouldAdaptiveRebalance();
            if (shouldRebalance) {
                lastRebalanceTime = block.timestamp;
                emit AdaptiveRebalanceTriggered(reason, block.timestamp);
            }
        }
    }
    
    /**
     * @notice Performs a fresh price check and rebalance assessment (manual keeper)
     */
    function manualKeeper() external nonReentrant whenNotPaused {
        // Fetch price
        fetchLatestPrice();
        
        // Check for rebalance
        (bool doRebalance, string memory reason) = shouldAdaptiveRebalance();
        if (doRebalance) {
            lastRebalanceTime = block.timestamp;
            emit AdaptiveRebalanceTriggered(reason, block.timestamp);
        }
    }

    // ================================
    //  Configuration Management
    // ================================
    
    /**
     * @notice Updates the rebalance interval
     * @param newInterval New interval in seconds
     */
    function setRebalanceInterval(uint256 newInterval) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newInterval >= 1 hours, "Interval too short");
        require(newInterval <= 30 days, "Interval too long");
        
        rebalanceInterval = newInterval;
        
        emit ConfigUpdated("rebalanceInterval", newInterval);
    }
    
    /**
     * @notice Updates the adaptive volatility threshold
     * @param newThreshold New threshold value
     */
    function setVolatilityThreshold(uint256 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newThreshold > 0, "Threshold must be positive");
        require(newThreshold <= 100, "Threshold too high");
        
        adaptiveVolatilityThreshold = newThreshold;
        
        emit ConfigUpdated("volatilityThreshold", newThreshold);
    }
    
    /**
     * @notice Updates the required approvals for multi-sig operations
     * @param newRequiredApprovals New number of required approvals
     */
    function setRequiredApprovals(uint256 newRequiredApprovals) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRequiredApprovals > 0, "Must require at least 1 approval");
        uint256 adminCount = getRoleMemberCount(AI_ADMIN_ROLE);
        require(newRequiredApprovals <= adminCount, "Cannot exceed admin count");
        
        requiredApprovals = newRequiredApprovals;
        
        emit ConfigUpdated("requiredApprovals", newRequiredApprovals);
    }

    // ================================
    //  Multi-signature Functionality
    // ================================
    
    /**
     * @notice Approves an operation for multi-sig execution
     * @param operationId Hash of the operation
     */
    function approveOperation(bytes32 operationId) external onlyRole(AI_ADMIN_ROLE) {
        require(!hasApproved[operationId][msg.sender], "Already approved");
        
        hasApproved[operationId][msg.sender] = true;
        operationApprovals[operationId]++;
        
        emit OperationApproved(operationId, msg.sender, operationApprovals[operationId]);
    }
    
    /**
     * @notice Revokes approval for an operation
     * @param operationId Hash of the operation
     */
    function revokeApproval(bytes32 operationId) external {
        require(hasApproved[operationId][msg.sender], "Not previously approved");
        
        hasApproved[operationId][msg.sender] = false;
        operationApprovals[operationId]--;
        
        emit OperationApproved(operationId, msg.sender, operationApprovals[operationId]);
    }
    
    /**
     * @notice Gets operation hash for a specific action
     * @param action String identifier for the action
     * @param data Additional data to include in hash
     * @return bytes32 Hash representing the operation
     */
    function getOperationId(string calldata action, bytes calldata data) external view returns (bytes32) {
        return keccak256(abi.encode(action, data, block.timestamp));
    }

    // ================================
    //  Emergency & Safety Controls
    // ================================
    
    /**
     * @notice Pauses all state-changing operations
     */
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpauses the contract
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Emergency reset of all neural weights
     */
    function emergencyResetWeights() external nonReentrant {
        bytes32 operationId = keccak256(abi.encode(
            "emergencyResetWeights",
            block.timestamp
        ));
        
        require(
            hasRole(EMERGENCY_ROLE, msg.sender) && 
            operationApprovals[operationId] >= requiredApprovals,
            "Insufficient approvals"
        );
        
        // Reset approvals
        delete operationApprovals[operationId];
        
        // Reset all neural weights
        for (uint256 i = 0; i < constituentList.length; i++) {
            address asset = constituentList[i];
            if (constituents[asset].isActive) {
                delete assetNeuralWeights[asset];
            }
        }
        
        // Reset indicators
        diversityIndex = 0;
        geneticVolatility = 0;
    }

    // ================================
    //  Upgradeability
    // ================================
    
    /**
     * @notice Authorizes an upgrade to a new implementation
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        // Implementation validation could be added here
    }
}
