// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

interface ITerraStakeProjects {
    function updateProjectDataFromChainlink(uint256 projectId, int256 price) external;
    function updateProjectESGData(uint256 projectId, string memory category, string memory metric, int256 value) external;
}

interface ITerraStakeToken {
    function getGovernanceStatus() external view returns (bool);
}

interface ITerraStakeLiquidityGuard {
    function validatePriceImpact(int256 price) external view returns (bool);
}

/**
 * @title ChainlinkDataFeeder
 * @notice Upgradeable oracle with financial and ESG data capabilities for the TerraStake ecosystem
 */
contract ChainlinkDataFeeder is 
    Initializable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable 
{
    // -------------------------------------------
    // 🔹 Custom Errors
    // -------------------------------------------
    error InvalidAddress();
    error FeedNotActive();
    error InvalidOracleData();
    error StaleOracleData();
    error TWAPValidationFailed();
    error NoValidDataAvailable();
    error PriceImpactTooHigh();
    error GovernanceDelayNotMet();
    error UnauthorizedAccess();
    error InvalidParameters();
    error DataValidationFailed();
    error DataStale();
    error InvalidMetric();
    error InvalidUnit();
    error Unauthorized();

    // -------------------------------------------
    // 🔹 Enums & Data Structures
    // -------------------------------------------
    enum ESGCategory { ENVIRONMENTAL, SOCIAL, GOVERNANCE }
    enum SourceType { IOT_DEVICE, MANUAL_ENTRY, THIRD_PARTY_API, SCIENTIFIC_MODEL, BLOCKCHAIN_ORACLE }

    struct ESGMetricDefinition {
        string name;
        string unit;
        string[] validationCriteria;
        address[] authorizedProviders;
        uint256 updateFrequency;
        uint256 minimumVerifications;
        ESGCategory category;
        uint8 importance;
    }

    struct ESGDataPoint {
        uint256 timestamp;
        int256 value;
        string unit;
        bytes32 dataHash;
        string rawDataURI;
        address provider;
        bool verified;
        address[] verifiers;
    }

    struct DataProvider {
        string name;
        string organization;
        string[] certifications;
        SourceType sourceType;
        bool active;
        uint256 reliabilityScore;
        uint256 lastUpdate;
    }

    struct OracleData {
        int256 price;
        uint256 timestamp;
    }

    struct FeedAnalytics {
        uint256 updateCount;
        uint256 lastValidation;
        int256[] priceHistory;
        uint256 reliabilityScore;
    }

    // -------------------------------------------
    // 🔹 Security & Governance Constants
    // -------------------------------------------
    bytes32 private constant CONTRACT_SIGNATURE = keccak256("v2.0");
    uint256 private constant STATE_SYNC_INTERVAL = 15 minutes;
    uint256 private constant ORACLE_TIMEOUT = 1 hours;
    uint256 private constant CIRCUIT_BREAKER_THRESHOLD = 3;
    uint256 private constant GOVERNANCE_CHANGE_DELAY = 1 days;
    uint256 private constant MAX_HISTORY_LENGTH = 100;

    // -------------------------------------------
    // 🔹 Roles for Security
    // -------------------------------------------
    bytes32 public constant DEVICE_MANAGER_ROLE = keccak256("DEVICE_MANAGER_ROLE");
    bytes32 public constant DATA_MANAGER_ROLE = keccak256("DATA_MANAGER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");

    // -------------------------------------------
    // 🔹 Oracle Feeds & Data Storage
    // -------------------------------------------
    mapping(address => bool) public activeFeeds;
    mapping(address => int256) public lastKnownPrice;
    mapping(address => uint256) public feedFailures;
    mapping(bytes32 => uint256) public pendingOracleChanges;
    address[] public priceOracles;

    // -------------------------------------------
    // 🔹 Oracle Price Storage (TWAP)
    // -------------------------------------------
    mapping(address => OracleData) public oracleRecords;

    // -------------------------------------------
    // 🔹 Cross-Chain Data Validation
    // -------------------------------------------
    mapping(bytes32 => int256) public crossChainData;

    // -------------------------------------------
    // 🔹 Performance Analytics
    // -------------------------------------------
    mapping(address => FeedAnalytics) public feedAnalytics;

    // -------------------------------------------
    // 🔹 ESG Metrics & Data
    // -------------------------------------------
    mapping(bytes32 => ESGMetricDefinition) public esgMetrics;
    mapping(uint256 => mapping(bytes32 => ESGDataPoint[])) public projectESGData;
    mapping(address => DataProvider) public dataProviders;
    mapping(uint256 => mapping(bytes32 => int256)) public latestVerifiedValues;
    mapping(ESGCategory => bytes32[]) public categoryMetrics;
    mapping(bytes32 => address[]) public metricVerifiers;
    mapping(string => string) public scientificStandards;
    mapping(bytes32 => mapping(address => bool)) public authorizedProviders;
    mapping(string => int256) public carbonEquivalencyFactors;
    mapping(bytes32 => int256) public conversionRates;

    // -------------------------------------------
    // 🔹 External Contract Integrations
    // -------------------------------------------
    ITerraStakeProjects public terraStakeProjects;
    ITerraStakeToken public terraStakeToken;
    ITerraStakeLiquidityGuard public liquidityGuard;

    // -------------------------------------------
    // 🔹 Events for Transparency
    // -------------------------------------------
    event DataUpdated(address indexed feed, int256 value, uint256 timestamp);
    event ProjectDataUpdated(uint256 indexed projectId, int256 value, uint256 timestamp);
    event FeedActivationUpdated(address indexed feed, bool active);
    event OracleChangeRequested(address indexed feed, uint256 unlockTime);
    event OracleChangeConfirmed(address indexed feed);
    event CircuitBreakerTriggered(address indexed feed, uint256 failureCount);
    event TWAPViolationDetected(int256 reportedPrice, int256 TWAP);
    event CrossChainDataValidated(address indexed feed, bytes32 crossChainId, bool valid);
    event PerformanceMetricsUpdated(address indexed feed, uint256 reliability, uint256 latency, uint256 deviation);
    event OracleAdded(address indexed feed);
    event OracleRemoved(address indexed feed);
    event FeedHistoryPruned(address indexed feed, uint256 newSize);
    event ModuleUpdated(string module, address oldAddress, address newAddress);
    event ESGMetricRegistered(bytes32 indexed metricId, string name, ESGCategory category);
    event DataProviderRegistered(address indexed provider, string name, SourceType sourceType);
    event DataProviderStatusUpdated(address indexed provider, bool active);
    event ESGDataSubmitted(uint256 indexed projectId, bytes32 indexed metricId, int256 value, address provider);
    event ESGDataVerified(uint256 indexed projectId, bytes32 indexed metricId, bytes32 dataHash, address verifier);
    event ConversionRateUpdated(string fromUnit, string toUnit, int256 rate);
    event ProviderReliabilityUpdated(address indexed provider, uint256 score);
    event ESGProjectAssessment(uint256 indexed projectId, ESGCategory category, uint256 score);
    event ScientificStandardUpdated(string metricName, string standard);
    event TerraStakeProjectsUpdated(address indexed newContract);
    event ContractUpgraded(address indexed implementation);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializer (replaces constructor for upgradeable contracts)
     * @param _terraStakeProjects TerraStake projects contract address
     * @param _terraStakeToken TerraStake token contract address
     * @param _liquidityGuard TerraStake liquidity guard contract address
     * @param _oracles Initial oracle feed addresses
     */
    function initialize(
        address _terraStakeProjects,
        address _terraStakeToken,
        address _liquidityGuard,
        address[] memory _oracles
    ) public initializer {
        if (_terraStakeProjects == address(0)) revert InvalidAddress();
        if (_terraStakeToken == address(0)) revert InvalidAddress();
        if (_liquidityGuard == address(0)) revert InvalidAddress();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        terraStakeProjects = ITerraStakeProjects(_terraStakeProjects);
        terraStakeToken = ITerraStakeToken(_terraStakeToken);
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);

        for (uint256 i = 0; i < _oracles.length; i++) {
            if (_oracles[i] == address(0)) revert InvalidAddress();
            priceOracles.push(_oracles[i]);
            activeFeeds[_oracles[i]] = true;
            emit OracleAdded(_oracles[i]);
        }

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DATA_MANAGER_ROLE, msg.sender);
        _grantRole(DEVICE_MANAGER_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        _grantRole(VERIFIER_ROLE, msg.sender);

        // Initialize default carbon equivalency factors (multiplied by 1000 for precision)
        carbonEquivalencyFactors["CO2"] = 1000;  // Direct CO2 = 1x
        carbonEquivalencyFactors["CH4"] = 25000; // Methane = 25x
        carbonEquivalencyFactors["N2O"] = 298000; // Nitrous Oxide = 298x
    }

    // -------------------------------------------
    // 🔹 UUPS Upgrade Control
    // -------------------------------------------
    /**
     * @notice Function that authorizes an upgrade
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        emit ContractUpgraded(newImplementation);
    }

    // -------------------------------------------
    // 🔹 ESG Metric Registration
    // -------------------------------------------
    /**
     * @notice Register a new ESG metric
     * @param name Metric name
     * @param unit Measurement unit
     * @param validationCriteria Criteria for validating submitted data
     * @param updateFrequency How often the metric should be updated (in seconds)
     * @param minimumVerifications Minimum number of verifiers needed
     * @param category ESG category (Environmental, Social, Governance)
     * @param importance Importance weight (1-10)
     */
    function registerESGMetric(
        string calldata name,
        string calldata unit,
        string[] calldata validationCriteria,
        uint256 updateFrequency,
        uint256 minimumVerifications,
        ESGCategory category,
        uint8 importance
    ) external onlyRole(GOVERNANCE_ROLE) {
        bytes32 metricId = keccak256(abi.encodePacked(name, unit));
        
        if (bytes(esgMetrics[metricId].name).length > 0) revert InvalidMetric();
        if (importance == 0 || importance > 10) revert InvalidParameters();
        
        esgMetrics[metricId].name = name;
        esgMetrics[metricId].unit = unit;
        esgMetrics[metricId].updateFrequency = updateFrequency;
        esgMetrics[metricId].minimumVerifications = minimumVerifications;
        esgMetrics[metricId].category = category;
        esgMetrics[metricId].importance = importance;
        
        for (uint256 i = 0; i < validationCriteria.length; i++) {
            esgMetrics[metricId].validationCriteria.push(validationCriteria[i]);
        }
        
        categoryMetrics[category].push(metricId);
        
        emit ESGMetricRegistered(metricId, name, category);
    }
    
    /**
     * @notice Register a data provider for ESG metrics
     * @param provider Provider address
     * @param name Provider name
     * @param organization Provider organization
     * @param certifications Provider certifications
     * @param sourceType Source type (IoT, manual, etc.)
     */
    function registerDataProvider(
        address provider,
        string calldata name,
        string calldata organization,
        string[] calldata certifications,
        SourceType sourceType
    ) external onlyRole(GOVERNANCE_ROLE) {
        if (provider == address(0)) revert InvalidAddress();
        
        DataProvider storage dp = dataProviders[provider];
        dp.name = name;
        dp.organization = organization;
        dp.sourceType = sourceType;
        dp.active = true;
        dp.lastUpdate = block.timestamp;
        
        for (uint256 i = 0; i < certifications.length; i++) {
            dp.certifications.push(certifications[i]);
        }
        
        emit DataProviderRegistered(provider, name, sourceType);
    }

    /**
     * @notice Authorize a provider to submit data for a specific metric
     * @param metricId Metric ID
     * @param provider Provider address
     */
function authorizeProviderForMetric(bytes32 metricId, address provider) external onlyRole(GOVERNANCE_ROLE) {
        if (provider == address(0)) revert InvalidAddress();
        if (bytes(esgMetrics[metricId].name).length == 0) revert InvalidMetric();
        
        authorizedProviders[metricId][provider] = true;
        if (!_contains(esgMetrics[metricId].authorizedProviders, provider)) {
            esgMetrics[metricId].authorizedProviders.push(provider);
        }
    }

    // -------------------------------------------
    // 🔹 ESG Data Submission and Verification
    // -------------------------------------------
    /**
     * @notice Submit ESG data for a project
     * @param projectId Project ID
     * @param metricId Metric ID
     * @param value Data value
     * @param unit Measurement unit
     * @param rawDataURI URI to raw data source
     */
    function submitESGData(
        uint256 projectId,
        bytes32 metricId,
        int256 value,
        string calldata unit,
        string calldata rawDataURI
    ) external nonReentrant {
        if (bytes(esgMetrics[metricId].name).length == 0) revert InvalidMetric();
        if (!authorizedProviders[metricId][msg.sender] && !hasRole(DATA_MANAGER_ROLE, msg.sender)) revert Unauthorized();
        if (!dataProviders[msg.sender].active) revert Unauthorized();
        
        // Ensure unit matches or perform conversion
        if (!_compareStrings(unit, esgMetrics[metricId].unit)) {
            bytes32 conversionKey = keccak256(abi.encodePacked(unit, esgMetrics[metricId].unit));
            int256 conversionRate = conversionRates[conversionKey];
            if (conversionRate == 0) revert InvalidUnit();
            value = (value * conversionRate) / 1000; // Apply conversion with 3 decimals precision
        }
        
        bytes32 dataHash = keccak256(abi.encodePacked(projectId, metricId, value, block.timestamp));
        
        ESGDataPoint memory dataPoint = ESGDataPoint({
            timestamp: block.timestamp,
            value: value,
            unit: esgMetrics[metricId].unit,
            dataHash: dataHash,
            rawDataURI: rawDataURI,
            provider: msg.sender,
            verified: false,
            verifiers: new address[](0)
        });
        
        projectESGData[projectId][metricId].push(dataPoint);
        dataProviders[msg.sender].lastUpdate = block.timestamp;
        
        emit ESGDataSubmitted(projectId, metricId, value, msg.sender);
    }
    
    /**
     * @notice Verify ESG data submission
     * @param projectId Project ID
     * @param metricId Metric ID
     * @param dataIndex Index of the data point in the array
     */
    function verifyESGData(
        uint256 projectId,
        bytes32 metricId,
        uint256 dataIndex
    ) external nonReentrant onlyRole(VERIFIER_ROLE) {
        if (bytes(esgMetrics[metricId].name).length == 0) revert InvalidMetric();
        if (projectESGData[projectId][metricId].length <= dataIndex) revert InvalidParameters();
        
        ESGDataPoint storage dataPoint = projectESGData[projectId][metricId][dataIndex];
        
        if (dataPoint.verified) return; // Already verified
        
        // Check if already verified by this verifier
        for (uint256 i = 0; i < dataPoint.verifiers.length; i++) {
            if (dataPoint.verifiers[i] == msg.sender) return;
        }
        
        // Add verifier
        dataPoint.verifiers.push(msg.sender);
        
        // Check if we've reached minimum verifications
        if (dataPoint.verifiers.length >= esgMetrics[metricId].minimumVerifications) {
            dataPoint.verified = true;
            latestVerifiedValues[projectId][metricId] = dataPoint.value;
            
            // Update project data in TerraStakeProjects contract
            terraStakeProjects.updateProjectESGData(
                projectId, 
                _getCategoryName(esgMetrics[metricId].category),
                esgMetrics[metricId].name,
                dataPoint.value
            );
        }
        
        emit ESGDataVerified(projectId, metricId, dataPoint.dataHash, msg.sender);
    }

    /**
     * @notice Get ESG category name as string
     * @param category ESG category enum
     * @return categoryName String representation of category
     */
    function _getCategoryName(ESGCategory category) internal pure returns (string memory) {
        if (category == ESGCategory.ENVIRONMENTAL) return "Environmental";
        if (category == ESGCategory.SOCIAL) return "Social";
        if (category == ESGCategory.GOVERNANCE) return "Governance";
        return "";
    }

    /**
     * @notice Set conversion rate between units
     * @param fromUnit Source unit
     * @param toUnit Target unit
     * @param rate Conversion rate (multiplied by 1000 for precision)
     */
    function setConversionRate(string calldata fromUnit, string calldata toUnit, int256 rate) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        if (rate <= 0) revert InvalidParameters();
        bytes32 conversionKey = keccak256(abi.encodePacked(fromUnit, toUnit));
        conversionRates[conversionKey] = rate;
        emit ConversionRateUpdated(fromUnit, toUnit, rate);
    }

    // -------------------------------------------
    // 🔹 ESG Data Analytics & Scoring
    // -------------------------------------------
    /**
     * @notice Convert a value from one unit to another
     * @param value Value to convert
     * @param fromUnit Source unit
     * @param toUnit Target unit
     * @return convertedValue Converted value
     */
    function convertUnit(int256 value, string memory fromUnit, string memory toUnit) 
        public 
        view 
        returns (int256) 
    {
        if (_compareStrings(fromUnit, toUnit)) return value;
        
        bytes32 conversionKey = keccak256(abi.encodePacked(fromUnit, toUnit));
        int256 rate = conversionRates[conversionKey];
        
        if (rate == 0) revert InvalidUnit();
        return (value * rate) / 1000;
    }
    
    /**
     * @notice Calculate the carbon equivalent of a given value
     * @param value Value to convert
     * @param sourceMetric Source metric (e.g., CH4, N2O)
     * @return equivalent Carbon equivalent value
     */
    function getCarbonEquivalent(int256 value, string memory sourceMetric) 
        public 
        view 
        returns (int256) 
    {
        int256 factor = carbonEquivalencyFactors[sourceMetric];
        if (factor == 0) return value; // Default 1:1 ratio if no factor exists
        return (value * factor) / 1000;
    }
    
    /**
     * @notice Calculate ESG score for a project in a specific category
     * @param projectId Project ID
     * @param category ESG category
     * @return score Category score (0-100)
     */
    function calculateESGScore(uint256 projectId, ESGCategory category) 
        public 
        view 
        returns (uint256) 
    {
        bytes32[] memory metrics = categoryMetrics[category];
        if (metrics.length == 0) return 0;
        
        uint256 totalWeight = 0;
        uint256 weightedSum = 0;
        
        for (uint256 i = 0; i < metrics.length; i++) {
            bytes32 metricId = metrics[i];
            int256 value = latestVerifiedValues[projectId][metricId];
            
            // Skip if no data available
            if (value == 0) continue;
            
            uint8 importance = esgMetrics[metricId].importance;
            totalWeight += importance;
            
            // Normalize value to 0-100 scale based on metric type
            uint256 normalizedValue;
            
            if (category == ESGCategory.ENVIRONMENTAL) {
                // For environmental metrics, lower is better (e.g., emissions)
                // Assume max possible value is 1000 for normalization
                normalizedValue = value <= 0 ? 100 : uint256(1000 - (value > 1000 ? 1000 : uint256(value))) / 10;
            } else {
                // For social and governance, higher is better
                normalizedValue = value >= 100 ? 100 : uint256(value);
            }
            
            weightedSum += normalizedValue * importance;
        }
        
        if (totalWeight == 0) return 0;
        return weightedSum / totalWeight;
    }
    
    /**
     * @notice Perform full ESG assessment on a project
     * @param projectId Project ID
     */
    function performESGAssessment(uint256 projectId) external nonReentrant {
        uint256 environmentalScore = calculateESGScore(projectId, ESGCategory.ENVIRONMENTAL);
        uint256 socialScore = calculateESGScore(projectId, ESGCategory.SOCIAL);
        uint256 governanceScore = calculateESGScore(projectId, ESGCategory.GOVERNANCE);
        
        emit ESGProjectAssessment(projectId, ESGCategory.ENVIRONMENTAL, environmentalScore);
        emit ESGProjectAssessment(projectId, ESGCategory.SOCIAL, socialScore);
        emit ESGProjectAssessment(projectId, ESGCategory.GOVERNANCE, governanceScore);
    }

    // -------------------------------------------
    // 🔹 Multi-Oracle TWAP Validation
    // -------------------------------------------
    function _validatePriceWithTWAP(address feed, int256 reportedPrice) internal returns (bool) {
        OracleData storage oracle = oracleRecords[feed];
        if (oracle.timestamp == 0) {
            oracle.price = reportedPrice;
            oracle.timestamp = block.timestamp;
            return true;
        }

        uint256 timeElapsed = block.timestamp - oracle.timestamp;
        int256 TWAP = (oracle.price + reportedPrice) / 2;

        if (timeElapsed >= STATE_SYNC_INTERVAL && TWAP < (reportedPrice * 95) / 100) {
            emit TWAPViolationDetected(reportedPrice, TWAP);
            return false;
        }

        oracle.price = reportedPrice;
        oracle.timestamp = block.timestamp;
        return true;
    }

    function calculateExtendedTWAP(address feed, uint256 period) external view returns (int256) {
        if (!activeFeeds[feed]) revert FeedNotActive();
        return oracleRecords[feed].price / int256(period);
    }

    // -------------------------------------------
    // 🔹 Data Fetching & Validation
    // -------------------------------------------
    /**
     * @notice Update price data from an oracle feed
     * @param feed Oracle feed address
     */
    function updateData(address feed) external nonReentrant onlyRole(DATA_MANAGER_ROLE) {
        if (!activeFeeds[feed]) revert FeedNotActive();

        AggregatorV3Interface priceFeed = AggregatorV3Interface(feed);
        (, int256 answer, , uint256 updatedAt, ) = priceFeed.latestRoundData();

        if (answer <= 0) revert InvalidOracleData();
        if (block.timestamp - updatedAt > ORACLE_TIMEOUT) revert StaleOracleData();
        if (!_validatePriceWithTWAP(feed, answer)) revert TWAPValidationFailed();

        lastKnownPrice[feed] = answer;
        feedAnalytics[feed].updateCount++;
        feedAnalytics[feed].lastValidation = block.timestamp;
        
        // Manage price history array length
        if (feedAnalytics[feed].priceHistory.length >= MAX_HISTORY_LENGTH) {
            _pruneHistory(feed);
        }
        
        feedAnalytics[feed].priceHistory.push(answer);
        emit DataUpdated(feed, answer, updatedAt);

        // Check for circuit breaker reset
        if (feedFailures[feed] > 0) {
            feedFailures[feed] = 0;
        }
    }

    function _pruneHistory(address feed) internal {
        FeedAnalytics storage analytics = feedAnalytics[feed];
        
        // Create a new array with only the most recent half of elements
        uint256 newSize = MAX_HISTORY_LENGTH / 2;
        int256[] memory newHistory = new int256[](newSize);
        
        for (uint256 i = 0; i < newSize; i++) {
            newHistory[i] = analytics.priceHistory[analytics.priceHistory.length - newSize + i];
        }
        
        // Replace the old array
        delete analytics.priceHistory;
        for (uint256 i = 0; i < newSize; i++) {
            analytics.priceHistory.push(newHistory[i]);
        }
        
        emit FeedHistoryPruned(feed, newSize);
    }

    /**
     * @notice Update price data with robust error handling
     * @param feed Oracle feed address
     */
    function updateDataWithErrorHandling(address feed) external nonReentrant onlyRole(DATA_MANAGER_ROLE) {
        if (!activeFeeds[feed]) revert FeedNotActive();

        try AggregatorV3Interface(feed).latestRoundData() returns (
            uint80, 
            int256 answer, 
            uint256, 
            uint256 updatedAt, 
            uint80
        ) {
            if (answer <= 0) {
                _handleOracleFailure(feed);
                return;
            }
            
            if (block.timestamp - updatedAt > ORACLE_TIMEOUT) {
                _handleOracleFailure(feed);
                return;
            }
            
            if (!_validatePriceWithTWAP(feed, answer)) {
                _handleOracleFailure(feed);
                return;
            }

            // Successfully processed data
            lastKnownPrice[feed] = answer;
            feedAnalytics[feed].updateCount++;
            feedAnalytics[feed].lastValidation = block.timestamp;
            
            if (feedAnalytics[feed].priceHistory.length >= MAX_HISTORY_LENGTH) {
                _pruneHistory(feed);
            }
            
            feedAnalytics[feed].priceHistory.push(answer);
            emit DataUpdated(feed, answer, updatedAt);
            
            // Reset failure count on success
            if (feedFailures[feed] > 0) {
                feedFailures[feed] = 0;
            }
        } catch {
            _handleOracleFailure(feed);
        }
    }

    function _handleOracleFailure(address feed) internal {
        feedFailures[feed]++;
if (feedFailures[feed] >= CIRCUIT_BREAKER_THRESHOLD) {
            emit CircuitBreakerTriggered(feed, feedFailures[feed]);
            
            // Optionally deactivate the feed
            if (priceOracles.length > 1) {
                activeFeeds[feed] = false;
                emit FeedActivationUpdated(feed, false);
            }
        }
    }

    /**
     * @notice Validate data across chains
     * @param feed Oracle feed address
     * @param crossChainId ID for cross-chain identification
     * @return Whether the data is valid
     */
    function validateCrossChainData(address feed, bytes32 crossChainId) external nonReentrant returns (bool) {
        if (!activeFeeds[feed]) revert FeedNotActive();
        int256 reportedPrice = lastKnownPrice[feed];
        int256 crossChainPrice = crossChainData[crossChainId];
        bool valid = (reportedPrice == crossChainPrice);
        emit CrossChainDataValidated(feed, crossChainId, valid);
        return valid;
    }

    /**
     * @notice Update project data using oracle information
     * @param projectId Project ID
     */
    function updateProjectData(uint256 projectId) external nonReentrant onlyRole(DATA_MANAGER_ROLE) {
        int256 price = lastKnownPrice[priceOracles[0]];
        if (price <= 0) revert NoValidDataAvailable();
        if (!liquidityGuard.validatePriceImpact(price)) revert PriceImpactTooHigh();
        terraStakeProjects.updateProjectDataFromChainlink(projectId, price);
        emit ProjectDataUpdated(projectId, price, block.timestamp);
    }

    // -------------------------------------------
    // 🔹 Oracle Management
    // -------------------------------------------
    /**
     * @notice Request to add a new oracle
     * @param newOracle Address of the new oracle
     */
    function requestOracleAddition(address newOracle) external onlyRole(GOVERNANCE_ROLE) {
        if (newOracle == address(0)) revert InvalidAddress();
        
        bytes32 changeId = keccak256(abi.encodePacked("add", newOracle));
        pendingOracleChanges[changeId] = block.timestamp + GOVERNANCE_CHANGE_DELAY;
        
        emit OracleChangeRequested(newOracle, pendingOracleChanges[changeId]);
    }
    
    /**
     * @notice Confirm addition of a new oracle after delay
     * @param newOracle Address of the new oracle
     */
    function confirmOracleAddition(address newOracle) external onlyRole(GOVERNANCE_ROLE) {
        bytes32 changeId = keccak256(abi.encodePacked("add", newOracle));
        
        if (block.timestamp < pendingOracleChanges[changeId]) revert GovernanceDelayNotMet();
        
        priceOracles.push(newOracle);
        activeFeeds[newOracle] = true;
        
        delete pendingOracleChanges[changeId];
        
        emit OracleAdded(newOracle);
        emit OracleChangeConfirmed(newOracle);
    }
    
    /**
     * @notice Request to remove an oracle
     * @param oracle Address of the oracle to remove
     */
    function requestOracleRemoval(address oracle) external onlyRole(GOVERNANCE_ROLE) {
        if (!activeFeeds[oracle]) revert FeedNotActive();
        
        bytes32 changeId = keccak256(abi.encodePacked("remove", oracle));
        pendingOracleChanges[changeId] = block.timestamp + GOVERNANCE_CHANGE_DELAY;
        
        emit OracleChangeRequested(oracle, pendingOracleChanges[changeId]);
    }
    
    /**
     * @notice Confirm removal of an oracle after delay
     * @param oracle Address of the oracle to remove
     */
    function confirmOracleRemoval(address oracle) external onlyRole(GOVERNANCE_ROLE) {
        bytes32 changeId = keccak256(abi.encodePacked("remove", oracle));
        
        if (block.timestamp < pendingOracleChanges[changeId]) revert GovernanceDelayNotMet();
        
        // Remove from priceOracles array
        for (uint256 i = 0; i < priceOracles.length; i++) {
            if (priceOracles[i] == oracle) {
                // Swap with the last element and pop
                priceOracles[i] = priceOracles[priceOracles.length - 1];
                priceOracles.pop();
                break;
            }
        }
        
        activeFeeds[oracle] = false;
        delete pendingOracleChanges[changeId];
        
        emit OracleRemoved(oracle);
        emit OracleChangeConfirmed(oracle);
    }
    
    /**
     * @notice Set the active status of a feed
     * @param feed Feed address
     * @param active Active status
     */
    function setFeedActive(address feed, bool active) external onlyRole(DEVICE_MANAGER_ROLE) {
        if (feed == address(0)) revert InvalidAddress();
        
        bool isOracle = false;
        for (uint256 i = 0; i < priceOracles.length; i++) {
            if (priceOracles[i] == feed) {
                isOracle = true;
                break;
            }
        }
        
        if (!isOracle) revert FeedNotActive();
        
        activeFeeds[feed] = active;
        emit FeedActivationUpdated(feed, active);
    }
    
    // -------------------------------------------
    // 🔹 Cross-Chain Data Management
    // -------------------------------------------
    /**
     * @notice Set cross-chain data
     * @param crossChainId Cross-chain identifier
     * @param price Price value
     */
    function setCrossChainData(bytes32 crossChainId, int256 price) external onlyRole(DATA_MANAGER_ROLE) {
        crossChainData[crossChainId] = price;
    }
    
    /**
     * @notice Set multiple cross-chain data points
     * @param ids Array of cross-chain identifiers
     * @param prices Array of prices
     */
    function batchSetCrossChainData(bytes32[] calldata ids, int256[] calldata prices) external onlyRole(DATA_MANAGER_ROLE) {
        if (ids.length != prices.length) revert InvalidParameters();
        
        for (uint256 i = 0; i < ids.length; i++) {
            crossChainData[ids[i]] = prices[i];
        }
    }
    
    // -------------------------------------------
    // 🔹 Performance Analytics Management
    // -------------------------------------------
    /**
     * @notice Update reliability score for a feed
     * @param feed Feed address
     * @param score Reliability score
     */
    function updateReliabilityScore(address feed, uint256 score) external onlyRole(DEVICE_MANAGER_ROLE) {
        if (!activeFeeds[feed]) revert FeedNotActive();
        
        feedAnalytics[feed].reliabilityScore = score;
        
        emit PerformanceMetricsUpdated(
            feed, 
            score,
            block.timestamp - feedAnalytics[feed].lastValidation,
            _calculatePriceDeviation(feed)
        );
    }
    
    /**
     * @notice Calculate price deviation between latest and previous price
     * @param feed Feed address
     * @return Deviation as a percentage (multiplied by 10000)
     */
    function _calculatePriceDeviation(address feed) internal view returns (uint256) {
        FeedAnalytics storage analytics = feedAnalytics[feed];
        if (analytics.priceHistory.length < 2) return 0;
        
        int256 latestPrice = analytics.priceHistory[analytics.priceHistory.length - 1];
        int256 previousPrice = analytics.priceHistory[analytics.priceHistory.length - 2];
        
        if (previousPrice == 0) return 0;
        
        int256 deviation = ((latestPrice - previousPrice) * 10000) / previousPrice;
        return deviation < 0 ? uint256(-deviation) : uint256(deviation);
    }
    
    /**
     * @notice Get price history for a feed
     * @param feed Feed address
     * @return Array of historical prices
     */
    function getPriceHistory(address feed) external view returns (int256[] memory) {
        if (!activeFeeds[feed]) revert FeedNotActive();
        return feedAnalytics[feed].priceHistory;
    }
    
    /**
     * @notice Get price deviation statistics
     * @param feed Feed address
     * @return min Minimum price
     * @return max Maximum price
     * @return average Average price
     */
    function getPriceDeviationStats(address feed) external view returns (
        int256 min,
        int256 max,
        int256 average
    ) {
        if (!activeFeeds[feed]) revert FeedNotActive();
        
        FeedAnalytics storage analytics = feedAnalytics[feed];
        if (analytics.priceHistory.length == 0) {
            return (0, 0, 0);
        }
        
        min = type(int256).max;
        max = type(int256).min;
        int256 sum = 0;
        
        for (uint256 i = 0; i < analytics.priceHistory.length; i++) {
            int256 price = analytics.priceHistory[i];
            if (price < min) min = price;
            if (price > max) max = price;
            sum += price;
        }
        
        average = sum / int256(analytics.priceHistory.length);
        return (min, max, average);
    }
    
    // -------------------------------------------
    // 🔹 ESG Provider Management
    // -------------------------------------------
    /**
     * @notice Set the active status of a data provider
     * @param provider Provider address
     * @param active Active status
     */
    function setDataProviderStatus(address provider, bool active) external onlyRole(GOVERNANCE_ROLE) {
        if (provider == address(0)) revert InvalidAddress();
        if (bytes(dataProviders[provider].name).length == 0) revert InvalidParameters();
        
        dataProviders[provider].active = active;
        emit DataProviderStatusUpdated(provider, active);
    }
    
    /**
     * @notice Update reliability score for a provider
     * @param provider Provider address
     * @param score Reliability score (0-100)
     */
    function updateProviderReliability(address provider, uint256 score) external onlyRole(GOVERNANCE_ROLE) {
        if (provider == address(0)) revert InvalidAddress();
        if (score > 100) revert InvalidParameters();
        if (bytes(dataProviders[provider].name).length == 0) revert InvalidParameters();
        
        dataProviders[provider].reliabilityScore = score;
        emit ProviderReliabilityUpdated(provider, score);
    }
    
    /**
     * @notice Update scientific standard for a metric
     * @param metricName Metric name
     * @param standard Scientific standard reference
     */
    function updateScientificStandard(string calldata metricName, string calldata standard) external onlyRole(GOVERNANCE_ROLE) {
        scientificStandards[metricName] = standard;
        emit ScientificStandardUpdated(metricName, standard);
    }
    
    /**
     * @notice Update carbon equivalency factor
     * @param sourceMetric Source metric (e.g., CH4)
     * @param factor Equivalency factor (multiplied by 1000)
     */
    function updateCarbonEquivalencyFactor(string calldata sourceMetric, int256 factor) external onlyRole(GOVERNANCE_ROLE) {
        if (factor <= 0) revert InvalidParameters();
        carbonEquivalencyFactors[sourceMetric] = factor;
    }
    
    // -------------------------------------------
    // 🔹 Integration Management
    // -------------------------------------------
    /**
     * @notice Update TerraStake Projects contract
     * @param _newProjects New projects contract address
     */
    function updateTerraStakeProjects(address _newProjects) external onlyRole(GOVERNANCE_ROLE) {
        if (_newProjects == address(0)) revert InvalidAddress();
        address oldProjects = address(terraStakeProjects);
        terraStakeProjects = ITerraStakeProjects(_newProjects);
        emit ModuleUpdated("terraStakeProjects", oldProjects, _newProjects);
    }
    
    /**
     * @notice Update TerraStake Token contract
     * @param _newToken New token contract address
     */
    function updateTerraStakeToken(address _newToken) external onlyRole(GOVERNANCE_ROLE) {
        if (_newToken == address(0)) revert InvalidAddress();
        address oldToken = address(terraStakeToken);
        terraStakeToken = ITerraStakeToken(_newToken);
        emit ModuleUpdated("terraStakeToken", oldToken, _newToken);
    }
    
    /**
     * @notice Update Liquidity Guard contract
     * @param _newGuard New liquidity guard contract address
     */
    function updateLiquidityGuard(address _newGuard) external onlyRole(GOVERNANCE_ROLE) {
        if (_newGuard == address(0)) revert InvalidAddress();
        address oldGuard = address(liquidityGuard);
        liquidityGuard = ITerraStakeLiquidityGuard(_newGuard);
        emit ModuleUpdated("liquidityGuard", oldGuard, _newGuard);
    }
    
    // -------------------------------------------
    // 🔹 Emergency Functions
    // -------------------------------------------
    /**
     * @notice Emergency reset of circuit breaker
     * @param feed Feed address
     */
    function emergencyResetCircuitBreaker(address feed) external onlyRole(GOVERNANCE_ROLE) {
        if (!activeFeeds[feed]) revert FeedNotActive();
        feedFailures[feed] = 0;
    }
    
    /**
     * @notice Emergency setting of last known price
     * @param feed Feed address
     * @param price Price value
     */
    function emergencySetLastKnownPrice(address feed, int256 price) external onlyRole(GOVERNANCE_ROLE) {
        if (!activeFeeds[feed]) revert FeedNotActive();
        if (price <= 0) revert InvalidOracleData();
        
        lastKnownPrice[feed] = price;
        oracleRecords[feed].price = price;
        oracleRecords[feed].timestamp = block.timestamp;
        
        emit DataUpdated(feed, price, block.timestamp);
    }
    
    // -------------------------------------------
    // 🔹 View Functions
    // -------------------------------------------
    /**
     * @notice Get all active oracles
     * @return Array of active oracle addresses
     */
    function getActiveOracles() external view returns (address[] memory) {
        uint256 activeCount = 0;
        
        // Count active oracles
        for (uint256 i = 0; i < priceOracles.length; i++) {
            if (activeFeeds[priceOracles[i]]) {
activeCount++;
            }
        }
        
        // Create array of active oracles
        address[] memory result = new address[](activeCount);
        uint256 resultIndex = 0;
        
        for (uint256 i = 0; i < priceOracles.length; i++) {
            if (activeFeeds[priceOracles[i]]) {
                result[resultIndex] = priceOracles[i];
                resultIndex++;
            }
        }
        
        return result;
    }
    
    /**
     * @notice Get comprehensive oracle status
     * @param feed Feed address
     * @return isActive Whether the feed is active
     * @return price Latest price
     * @return lastUpdate Last update timestamp
     * @return failureCount Number of consecutive failures
     * @return reliabilityScore Reliability score
     */
    function getOracleStatus(address feed) external view returns (
        bool isActive,
        int256 price,
        uint256 lastUpdate,
        uint256 failureCount,
        uint256 reliabilityScore
    ) {
        return (
            activeFeeds[feed],
            lastKnownPrice[feed],
            oracleRecords[feed].timestamp,
            feedFailures[feed],
            feedAnalytics[feed].reliabilityScore
        );
    }
    
    /**
     * @notice Get oracle data
     * @param feed Feed address
     * @return price Latest price
     * @return timestamp Last update timestamp
     * @return active Whether the feed is active
     * @return updateCount Number of updates
     */
    function getOracleData(address feed) external view returns (
        int256 price, 
        uint256 timestamp, 
        bool active, 
        uint256 updateCount
    ) {
        OracleData storage oracle = oracleRecords[feed];
        FeedAnalytics storage analytics = feedAnalytics[feed];
        
        return (
            oracle.price,
            oracle.timestamp,
            activeFeeds[feed],
            analytics.updateCount
        );
    }
    
    /**
     * @notice Get contract version signature
     * @return Version signature
     */
    function getContractVersion() external pure returns (bytes32) {
        return CONTRACT_SIGNATURE;
    }
    
    /**
     * @notice Get all metrics in a category
     * @param category ESG category
     * @return Array of metric IDs
     */
    function getCategoryMetrics(ESGCategory category) external view returns (bytes32[] memory) {
        return categoryMetrics[category];
    }
    
    /**
     * @notice Get all data for a project in a category
     * @param projectId Project ID
     * @param category ESG category
     * @return metricIds Array of metric IDs
     * @return values Array of latest verified values
     */
    function getProjectCategoryData(uint256 projectId, ESGCategory category) 
        external 
        view 
        returns (bytes32[] memory metricIds, int256[] memory values) 
    {
        bytes32[] memory metrics = categoryMetrics[category];
        metricIds = new bytes32[](metrics.length);
        values = new int256[](metrics.length);
        
        for (uint256 i = 0; i < metrics.length; i++) {
            metricIds[i] = metrics[i];
            values[i] = latestVerifiedValues[projectId][metrics[i]];
        }
        
        return (metricIds, values);
    }
    
    // -------------------------------------------
    // 🔹 Utility Functions
    // -------------------------------------------
    /**
     * @notice Helper function to compare strings
     * @param a First string
     * @param b Second string
     * @return Whether the strings are equal
     */
    function _compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }
    
    /**
     * @notice Check if an address exists in an array
     * @param addresses Array of addresses
     * @param addr Address to check
     * @return Whether the address exists in the array
     */
    function _contains(address[] memory addresses, address addr) internal pure returns (bool) {
        for (uint256 i = 0; i < addresses.length; i++) {
            if (addresses[i] == addr) {
                return true;
            }
        }
        return false;
    }
}
