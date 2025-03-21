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
 * @notice Advanced AI-driven asset management system with Chainlink integration
 * @dev Upgradeable contract for managing asset weights using neural network signals
 */
contract AIEngine is
    Initializable,
    AccessControlEnumerableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    AutomationCompatibleInterface
{
    // ===============================
    // Constants
    // ===============================
    uint256 public constant MAX_SIGNAL_VALUE = 1e30;
    uint256 public constant MAX_EMA_SMOOTHING = 100;
    uint256 public constant DEFAULT_REBALANCE_INTERVAL = 1 days;
    uint256 public constant MIN_DIVERSITY_INDEX = 500;
    uint256 public constant MAX_DIVERSITY_INDEX = 2500;
    uint256 public constant MAX_PRICE_STALENESS = 24 hours;
    uint256 public constant MAX_PRICE_DEVIATION = 2000; // 20% in basis points
    uint256 public constant MAX_TIMELOCK = 7 days;

    // ===============================
    // Roles
    // ===============================
    bytes32 public constant AI_ADMIN_ROLE = keccak256("AI_ADMIN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    // ===============================
    // Data Structures
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
    // State Variables
    // ===============================
    
    // Asset Management
    mapping(address => NeuralWeight) public assetNeuralWeights;
    mapping(address => Constituent) public constituents;
    address[] public constituentList;
    uint256 public activeConstituentCount;
    
    // Metrics
    uint256 public diversityIndex;
    uint256 public geneticVolatility;
    
    // Rebalancing
    uint256 public rebalanceInterval;
    uint256 public lastRebalanceTime;
    uint256 public adaptiveVolatilityThreshold;
    
    // Governance
    uint256 public requiredApprovals;
    mapping(bytes32 => uint256) public operationApprovals;
    mapping(bytes32 => mapping(address => bool)) public hasApproved;
    uint256 public operationTimelock;
    mapping(bytes32 => uint256) public operationScheduledTime;
    
    // Price Protection
    uint256 public maxPriceDeviation;
    
    // Chainlink
    mapping(address => AggregatorV3Interface) public priceFeeds;
    
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
    // Modifiers
    // ===============================
    
    /**
     * @dev Ensures the asset is an active constituent
     */
    modifier validConstituent(address asset) {
        require(constituents[asset].isActive, "Asset not active constituent");
        _;
    }

    /**
     * @dev Ensures price data for the asset is not stale
     */
    modifier freshPrice(address asset) {
        (, , , uint256 updatedAt, ) = priceFeeds[asset].latestRoundData();
        require(
            updatedAt > 0 &&
            block.timestamp - updatedAt <= MAX_PRICE_STALENESS,
            "Price data stale"
        );
        _;
    }

    /**
     * @dev Ensures operation has enough approvals and cleans up afterward
     */
    modifier withApprovals(bytes32 operationId) {
        require(operationApprovals[operationId] >= requiredApprovals, "Insufficient approvals");
        delete operationApprovals[operationId];
        _;
    }
    
    /**
     * @dev Ensures timelocked operation is ready for execution
     */
    modifier timelockElapsed(bytes32 operationId) {
        uint256 scheduledTime = operationScheduledTime[operationId];
        require(scheduledTime > 0, "Operation not scheduled");
        require(block.timestamp >= scheduledTime, "Timelock not elapsed");
        delete operationScheduledTime[operationId];
        _;
    }

    // ===============================
    // Initialization
    // ===============================
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with default settings
     */
    function initialize() public initializer {
        __AccessControlEnumerable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(AI_ADMIN_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        _grantRole(KEEPER_ROLE, msg.sender);

        rebalanceInterval = DEFAULT_REBALANCE_INTERVAL;
        adaptiveVolatilityThreshold = 15;
        lastRebalanceTime = block.timestamp;
        requiredApprovals = 2;
        operationTimelock = 1 days;
        maxPriceDeviation = 2000; // 20%
    }

    // ===============================
    // Constituent Management
    // ===============================
    
    /**
     * @notice Adds a new constituent asset to the portfolio
     * @param asset Address of the asset token
     * @param priceFeed Address of the Chainlink price feed for the asset
     */
    function addConstituent(address asset, address priceFeed) 
        external 
        onlyRole(AI_ADMIN_ROLE) 
        nonReentrant 
        whenNotPaused 
    {
        require(asset != address(0), "Cannot add zero address");
        require(!constituents[asset].isActive, "Asset already active");
        require(priceFeed != address(0), "Invalid price feed address");

        // If this is a new asset (vs reactivating a previously deactivated one)
        if (constituents[asset].activationTime == 0) {
            constituents[asset].index = constituentList.length;
            constituentList.push(asset);
        }

        // Update constituent data
        Constituent storage constituent = constituents[asset];
        constituent.isActive = true;
        constituent.activationTime = block.timestamp;
        constituent.evolutionScore = 0;
        
        // Set price feed and fetch initial price
        priceFeeds[asset] = AggregatorV3Interface(priceFeed);
        
        // Attempt to fetch price (will revert if feed has issues)
        fetchLatestPrice(asset);
        
        activeConstituentCount++;

        emit ConstituentAdded(asset, block.timestamp);
    }

    /**
     * @notice Deactivates a constituent asset
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

        _updateDiversityIndex();
    }

    /**
     * @notice Returns array of all active constituents
     * @return activeAssets Array of active constituent addresses
     */
    function getActiveConstituents() external view returns (address[] memory activeAssets) {
        uint256 count = activeConstituentCount; // Cache to avoid multiple SLOADs
        activeAssets = new address[](count);
        
        uint256 activeIndex = 0;
        for (uint256 i = 0; i < constituentList.length && activeIndex < count; i++) {
            address asset = constituentList[i];
            if (constituents[asset].isActive) {
                activeAssets[activeIndex] = asset;
                activeIndex++;
            }
        }
        
        return activeAssets;
    }

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
    )
        public
        onlyRole(AI_ADMIN_ROLE)
        validConstituent(asset)
        whenNotPaused
    {
        require(smoothingFactor > 0 && smoothingFactor <= MAX_EMA_SMOOTHING, "Invalid smoothing factor");
        require(newRawSignal <= MAX_SIGNAL_VALUE, "Signal exceeds maximum");

        NeuralWeight storage w = assetNeuralWeights[asset];
        
        // Update raw signal
        w.rawSignal = newRawSignal;

        // Calculate EMA or use raw signal for first update
        if (w.lastUpdateTime == 0) {
            w.currentWeight = newRawSignal;
        } else {
            // EMA calculation: alpha * current + (1-alpha) * previous
            w.currentWeight = (newRawSignal * smoothingFactor + 
                              w.currentWeight * (MAX_EMA_SMOOTHING - smoothingFactor)) / 
                              MAX_EMA_SMOOTHING;
        }

        // Update timestamps and factors
        w.lastUpdateTime = block.timestamp;
        w.emaSmoothingFactor = smoothingFactor;

        emit NeuralWeightUpdated(asset, w.currentWeight, newRawSignal, smoothingFactor);

        // Recalculate diversity index after weight change
        _updateDiversityIndex();
    }

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
    )
        external
        onlyRole(AI_ADMIN_ROLE)
        whenNotPaused
    {
        uint256 length = assets.length;
        require(
            length == newRawSignals.length &&
            length == smoothingFactors.length,
            "Arrays length mismatch"
        );

        // Update each asset weight individually
        for (uint256 i = 0; i < length; i++) {
            if (constituents[assets[i]].isActive) {
                updateNeuralWeight(assets[i], newRawSignals[i], smoothingFactors[i]);
            }
        }
    }

    // ===============================
    // Diversity Index Management
    // ===============================
    
    /**
     * @notice Recalculates the diversity index based on current weights
     * @dev Lower index = more diverse, Higher index = more concentrated
     */
    function _updateDiversityIndex() internal {
        uint256 activeCount = activeConstituentCount;
        
        // Early return if no active constituents
        if (activeCount == 0) {
            diversityIndex = 0;
            emit DiversityIndexUpdated(0);
            return;
        }

        uint256 totalWeight = 0;
        uint256[] memory weights = new uint256[](constituentList.length);
        
        // First pass: calculate total weight and cache weights
        for (uint256 i = 0; i < constituentList.length; i++) {
            address asset = constituentList[i];
            if (constituents[asset].isActive) {
                weights[i] = assetNeuralWeights[asset].currentWeight;
                totalWeight += weights[i];
            }
        }
        
        // Guard against division by zero
        if (totalWeight == 0) {
            diversityIndex = 0;
            emit DiversityIndexUpdated(0);
            return;
        }
        
        // Second pass: calculate concentration index
        uint256 sumSquared = 0;
        for (uint256 i = 0; i < constituentList.length; i++) {
            address asset = constituentList[i];
            if (constituents[asset].isActive && weights[i] > 0) {
                uint256 percentShare = (weights[i] * 10000) / totalWeight;
                sumSquared += (percentShare * percentShare);
            }
        }
        
        // Set new diversity index and emit event
        diversityIndex = sumSquared;
        emit DiversityIndexUpdated(sumSquared);
    }
    /**
     * @notice Manually triggers diversity index recalculation
     */
    function recalculateDiversityIndex() 
        external 
        onlyRole(AI_ADMIN_ROLE) 
        whenNotPaused 
    {
        _updateDiversityIndex();
    }

    // ===============================
    // Chainlink Integration
    // ===============================
    
    /**
     * @notice Fetches the latest price from the Chainlink price feed
     * @param asset Address of the asset to fetch price for
     * @return The latest price of the asset
     */
    function fetchLatestPrice(address asset) public returns (uint256) {
        require(address(priceFeeds[asset]) != address(0), "No price feed configured");
        
        (
            uint80 roundId,
            int256 price,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeeds[asset].latestRoundData();

        // Validate price data
        require(price > 0, "Negative or zero price");
        require(updatedAt > 0, "Round not complete");
        require(answeredInRound >= roundId, "Stale price data");
        
        uint256 priceUint = uint256(price);
        uint256 oldPrice = constituents[asset].lastPrice;

        // Check price deviation when not first price
        if (oldPrice > 0) {
            uint256 deviation;
            
            if (priceUint > oldPrice) {
                deviation = ((priceUint - oldPrice) * 10000) / oldPrice;
            } else {
                deviation = ((oldPrice - priceUint) * 10000) / oldPrice;
            }
            
            // Alert on high deviation but don't revert
            if (deviation > maxPriceDeviation) {
                emit CircuitBreaker(asset, oldPrice, priceUint, deviation);
                
                // Only require approval for very high deviations (2x the normal threshold)
                if (deviation > maxPriceDeviation * 2) {
                    bytes32 operationId = keccak256(abi.encode(
                        "acceptPriceDeviation",
                        asset,
                        priceUint,
                        block.timestamp
                    ));
                    
                    require(
                        hasRole(EMERGENCY_ROLE, msg.sender) || 
                        operationApprovals[operationId] >= requiredApprovals,
                        "Price deviation requires approval"
                    );
                }
            }
        }
        
        // Update the constituent's price data
        constituents[asset].lastPrice = priceUint;
        constituents[asset].lastPriceUpdateTime = block.timestamp;

        emit PriceUpdated(asset, priceUint, block.timestamp);

        return priceUint;
    }

    /**
     * @notice Gets the latest price without writing to state
     * @param asset Address of the asset
     * @return price The asset price
     * @return isFresh Whether the price data is fresh
     */
    function getLatestPrice(address asset) external view returns (uint256 price, bool isFresh) {
        if (address(priceFeeds[asset]) == address(0)) {
            return (0, false);
        }
        
        (
            ,
            int256 priceInt,
            ,
            uint256 updatedAt,
            
        ) = priceFeeds[asset].latestRoundData();

        price = priceInt > 0 ? uint256(priceInt) : 0;
        isFresh = updatedAt > 0 && block.timestamp - updatedAt <= MAX_PRICE_STALENESS;
        
        return (price, isFresh);
    }

    /**
     * @notice Updates the price feed address for an asset
     * @param asset Address of the asset
     * @param newPriceFeed Address of the new price feed
     */
    function updatePriceFeedAddress(address asset, address newPriceFeed)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        require(newPriceFeed != address(0), "Invalid price feed address");

        bytes32 operationId = keccak256(abi.encode(
            "updatePriceFeed",
            asset,
            newPriceFeed,
            block.timestamp
        ));

        // Require multi-sig approval and elapsed timelock
        require(operationApprovals[operationId] >= requiredApprovals, "Insufficient approvals");
        require(
            operationScheduledTime[operationId] > 0 && 
            block.timestamp >= operationScheduledTime[operationId],
            "Timelock not elapsed"
        );
        
        // Clean up approval state
        delete operationApprovals[operationId];
        delete operationScheduledTime[operationId];

        // Update price feed and fetch initial price
        priceFeeds[asset] = AggregatorV3Interface(newPriceFeed);
        fetchLatestPrice(asset);
    }

    // ===============================
    // Rebalancing Logic
    // ===============================
    
    /**
     * @notice Determines if a rebalance should be triggered
     * @return shouldRebalance Whether rebalance is needed
     * @return reason Human-readable reason for rebalance
     */
    function shouldAdaptiveRebalance() public view returns (bool shouldRebalance, string memory reason) {
        // Time-based rebalance
        if (block.timestamp >= lastRebalanceTime + rebalanceInterval) {
            return (true, "Time-based rebalance");
        }

        // Concentration-based rebalance
        uint256 currentDiversity = diversityIndex;
        if (currentDiversity > MAX_DIVERSITY_INDEX) {
            return (true, "Diversity too concentrated");
        }

        // Dispersion-based rebalance
        if (currentDiversity < MIN_DIVERSITY_INDEX && currentDiversity > 0) {
            return (true, "Diversity too dispersed");
        }

        // Volatility-based rebalance
        if (geneticVolatility > adaptiveVolatilityThreshold) {
            return (true, "Volatility threshold breach");
        }

        return (false, "No rebalance needed");
    }

    /**
     * @notice Manually triggers an adaptive rebalance
     */
    function triggerAdaptiveRebalance() 
        external 
        onlyRole(AI_ADMIN_ROLE) 
        nonReentrant 
        whenNotPaused 
        returns (string memory)
    {
        (bool doRebalance, string memory reason) = shouldAdaptiveRebalance();
        require(doRebalance, "Rebalance not needed");

        // Update rebalance timestamp
        lastRebalanceTime = block.timestamp;

        emit AdaptiveRebalanceTriggered(reason, block.timestamp);
        return reason;
    }

    /**
     * @notice Updates genetic volatility metric and handles potential rebalancing
     * @param newVolatility New volatility value
     */
    function updateGeneticVolatility(uint256 newVolatility) 
        external 
        onlyRole(AI_ADMIN_ROLE) 
        whenNotPaused 
    {
        geneticVolatility = newVolatility;

        // If volatility exceeds threshold and quarter-interval has passed, trigger rebalance
        if (geneticVolatility > adaptiveVolatilityThreshold) {
            if (block.timestamp >= lastRebalanceTime + (rebalanceInterval / 4)) {
                lastRebalanceTime = block.timestamp;
                emit AdaptiveRebalanceTriggered("Volatility threshold breach", block.timestamp);
            }
        }
    }

    // ===============================
    // Chainlink Keeper Methods
    // ===============================
    
    /**
     * @notice Chainlink Automation compatible checkUpkeep function
     * @param checkData Arbitrary data passed from caller
     * @return upkeepNeeded Whether upkeep is needed
     * @return performData Data to be used by performUpkeep
     */
    function checkUpkeep(bytes calldata checkData)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        if (paused()) {
            return (false, "");
        }

        // Check if rebalancing is needed
        (bool shouldRebalance, ) = shouldAdaptiveRebalance();

        // Check if any price feeds need updating
        bool needsPriceUpdate = false;
        address[] memory assetsToUpdate = new address[](constituentList.length);
        uint256 updateCount = 0;
        
        for (uint256 i = 0; i < constituentList.length; i++) {
            address asset = constituentList[i];
            if (constituents[asset].isActive) {
                (, , , uint256 updatedAt, ) = priceFeeds[asset].latestRoundData();
                
                // Update if no data or data older than half of max staleness
                if (updatedAt == 0 || block.timestamp - updatedAt > MAX_PRICE_STALENESS / 2) {
                    needsPriceUpdate = true;
                    assetsToUpdate[updateCount] = asset;
                    updateCount++;
                }
            }
        }

        upkeepNeeded = shouldRebalance || needsPriceUpdate;
        
        // Encode which specific actions are needed and which assets need updates
        performData = abi.encode(
            shouldRebalance, 
            needsPriceUpdate,
            updateCount > 0 ? updateCount : 0,
            assetsToUpdate
        );

        return (upkeepNeeded, performData);
    }

    /**
     * @notice Chainlink Automation compatible performUpkeep function
     * @param performData Data from checkUpkeep that determines actions
     */
    function performUpkeep(bytes calldata performData)
        external
        override
        nonReentrant
    {
        require(
            hasRole(KEEPER_ROLE, msg.sender) ||
            msg.sender == tx.origin,  // Allow EOA calls (for manual triggering)
            "Not authorized for upkeep"
        );

        require(!paused(), "Contract is paused");

        // Decode performance data
        (
            bool doRebalance, 
            bool updatePrice,
            uint256 updateCount,
            address[] memory assetsToUpdate
        ) = abi.decode(performData, (bool, bool, uint256, address[]));

        // Update prices for assets that need updates
        if (updatePrice && updateCount > 0) {
            for (uint256 i = 0; i < updateCount; i++) {
                address asset = assetsToUpdate[i];
                if (constituents[asset].isActive) {
                    try this.fetchLatestPrice(asset) {
                        // Price update successful
                    } catch {
                        // Log but continue with other assets
                        emit PriceUpdated(asset, 0, block.timestamp);
                    }
                }
            }
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
     * @notice Manual trigger for the keeper functions
     */
    function manualKeeper() 
        external 
        nonReentrant 
        whenNotPaused 
    {
        // Update all active asset prices
        for (uint256 i = 0; i < constituentList.length; i++) {
            address asset = constituentList[i];
            if (constituents[asset].isActive) {
                try this.fetchLatestPrice(asset) {
                    // Price update successful
                } catch {
                    // Log but continue with other assets
                    emit PriceUpdated(asset, 0, block.timestamp);
                }
            }
        }

        // Check and possibly trigger rebalance
        (bool doRebalance, string memory reason) = shouldAdaptiveRebalance();
        if (doRebalance) {
            lastRebalanceTime = block.timestamp;
            emit AdaptiveRebalanceTriggered(reason, block.timestamp);
        }
    }

    // ===============================
    // Configuration Management
    // ===============================
    
    /**
     * @notice Updates the rebalance interval
     * @param newInterval New interval in seconds
     */
    function setRebalanceInterval(uint256 newInterval) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        require(newInterval >= 1 hours, "Interval too short");
        require(newInterval <= 30 days, "Interval too long");

        rebalanceInterval = newInterval;

        emit ConfigUpdated("rebalanceInterval", newInterval);
    }

    /**
     * @notice Sets the volatility threshold for adaptive rebalancing
     * @param newThreshold New threshold value
     */
    function setVolatilityThreshold(uint256 newThreshold) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        require(newThreshold > 0, "Threshold must be positive");
        require(newThreshold <= 100, "Threshold too high");

        adaptiveVolatilityThreshold = newThreshold;

        emit ConfigUpdated("volatilityThreshold", newThreshold);
    }

    /**
     * @notice Sets the maximum allowed price deviation before requiring approvals
     * @param newDeviation New deviation percentage in basis points (100 = 1%)
     */
    function setMaxPriceDeviation(uint256 newDeviation) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        require(newDeviation >= 500, "Deviation too small"); // Minimum 5%
        require(newDeviation <= 5000, "Deviation too large"); // Maximum 50%

        maxPriceDeviation = newDeviation;

        emit ConfigUpdated("maxPriceDeviation", newDeviation);
    }

    /**
     * @notice Sets the number of approvals required for sensitive operations
     * @param newRequiredApprovals New number of required approvals
     */
    function setRequiredApprovals(uint256 newRequiredApprovals) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        require(newRequiredApprovals > 0, "Must require at least 1 approval");
        
        uint256 adminCount = getRoleMemberCount(AI_ADMIN_ROLE);
        require(newRequiredApprovals <= adminCount, "Cannot exceed admin count");

        requiredApprovals = newRequiredApprovals;

        emit ConfigUpdated("requiredApprovals", newRequiredApprovals);
    }

    /**
     * @notice Sets the timelock duration for sensitive operations
     * @param newTimelock New timelock duration in seconds
     */
    function setOperationTimelock(uint256 newTimelock) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        require(newTimelock <= MAX_TIMELOCK, "Timelock too long");

        operationTimelock = newTimelock;
        
        emit ConfigUpdated("operationTimelock", newTimelock);
    }

    // ===============================
    // Multi-signature Functionality
    // ===============================
    /**
     * @notice Approves a pending operation
     * @param operationId Unique identifier for the operation
     */
    function approveOperation(bytes32 operationId) 
        external 
        onlyRole(AI_ADMIN_ROLE) 
    {
        require(!hasApproved[operationId][msg.sender], "Already approved");

        hasApproved[operationId][msg.sender] = true;
        operationApprovals[operationId]++;

        emit OperationApproved(operationId, msg.sender, operationApprovals[operationId]);
    }

    /**
     * @notice Revokes approval for a pending operation
     * @param operationId Unique identifier for the operation
     */
    function revokeApproval(bytes32 operationId) 
        external 
    {
        require(hasApproved[operationId][msg.sender], "Not previously approved");

        hasApproved[operationId][msg.sender] = false;
        operationApprovals[operationId]--;

        emit OperationApproved(operationId, msg.sender, operationApprovals[operationId]);
    }

    /**
     * @notice Schedules an operation for execution after timelock
     * @param operationId Unique identifier for the operation
     */
    function scheduleOperation(bytes32 operationId) 
        external 
        onlyRole(AI_ADMIN_ROLE) 
    {
        require(operationApprovals[operationId] >= requiredApprovals, "Insufficient approvals");
        require(operationScheduledTime[operationId] == 0, "Already scheduled");
        
        operationScheduledTime[operationId] = block.timestamp + operationTimelock;
        
        emit OperationScheduled(operationId, operationScheduledTime[operationId]);
    }

    /**
     * @notice Generates a unique operation ID based on action and data
     * @param action String description of the action
     * @param data Additional data for the operation
     * @return operationId Unique identifier for the operation
     */
    function getOperationId(string calldata action, bytes calldata data) 
        external 
        view 
        returns (bytes32) 
    {
        return keccak256(abi.encode(action, data, block.timestamp));
    }

    // ===============================
    // Emergency & Safety Controls
    // ===============================
    
    /**
     * @notice Pauses all non-view functions
     */
    function pause() 
        external 
        onlyRole(EMERGENCY_ROLE) 
    {
        _pause();
    }

    /**
     * @notice Unpauses the contract
     */
    function unpause() 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        _unpause();
    }

    /**
     * @notice Emergency function to reset all neural weights
     * @dev Requires multi-sig approval for extra safety
     */
    function emergencyResetWeights() 
        external 
        nonReentrant 
    {
        bytes32 operationId = keccak256(abi.encode(
            "emergencyResetWeights",
            block.timestamp
        ));

        require(
            hasRole(EMERGENCY_ROLE, msg.sender) &&
            operationApprovals[operationId] >= requiredApprovals,
            "Insufficient approvals"
        );

        delete operationApprovals[operationId];

        // Reset neural weights for all assets
        for (uint256 i = 0; i < constituentList.length; i++) {
            address asset = constituentList[i];
            if (constituents[asset].isActive) {
                delete assetNeuralWeights[asset];
            }
        }

        // Reset global metrics
        diversityIndex = 0;
        geneticVolatility = 0;
        
        emit ConfigUpdated("emergencyReset", block.timestamp);
    }
    
    /**
     * @notice Emergency function to clear a specific price deviation alert
     * @param asset Address of the asset with price deviation
     */
    function clearPriceDeviationAlert(address asset)
        external
        onlyRole(EMERGENCY_ROLE)
        nonReentrant
    {
        // This forces acceptance of the current price regardless of deviation
        (
            ,
            int256 price,
            ,
            uint256 updatedAt,
            
        ) = priceFeeds[asset].latestRoundData();
        
        require(price > 0 && updatedAt > 0, "Invalid price data");
        
        // Update price without deviation check
        uint256 priceUint = uint256(price);
        constituents[asset].lastPrice = priceUint;
        constituents[asset].lastPriceUpdateTime = block.timestamp;
        
        emit PriceUpdated(asset, priceUint, block.timestamp);
    }

    // ===============================
    // Upgradeability
    // ===============================
    
    /**
     * @notice Authorizes an upgrade to a new implementation
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyRole(UPGRADER_ROLE) 
    {
        bytes32 operationId = keccak256(abi.encode(
            "upgrade",
            newImplementation,
            block.timestamp
        ));
        
        require(operationApprovals[operationId] >= requiredApprovals, "Insufficient approvals");
        require(
            operationScheduledTime[operationId] > 0 && 
            block.timestamp >= operationScheduledTime[operationId],
            "Timelock not elapsed"
        );
        
        // Clean up approval state
        delete operationApprovals[operationId];
        delete operationScheduledTime[operationId];
        
        // Implementation validation could be added here
    }
}
    
