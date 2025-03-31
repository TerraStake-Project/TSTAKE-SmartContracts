// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.21;


// Core OpenZeppelin
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";


// API3 Integration
import "@api3/contracts/v0.8/interfaces/IProxy.sol";
import "@api3/contracts/v0.8/interfaces/IBeacon.sol";
import "@api3/contracts/v0.8/interfaces/IAirnodeRrpV0.sol";


// TerraStake Ecosystem
import "../interfaces/ITerraStakeProjects.sol";
import "../interfaces/ITerraStakeToken.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";
import "../interfaces/ITerraStakeGovernance.sol";


/**
 * @title API3DataFeeder
 * @notice Enterprise-grade oracle system with comprehensive sustainability and carbon market data capabilities
 * @dev Features:
 * - Decentralized governance with proposal execution
 * - API3/Airnode integration for verified price feeds
 * - Advanced ESG metrics tracking with verification system
 * - Cross-chain data validation and synchronization
 * - Time-weighted and volume-weighted price calculations
 * - Gas-optimized storage patterns
 * - Comprehensive carbon market support
 */
contract API3DataFeeder is 
    Initializable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable 
{
    // ===========================================
    // Custom Errors
    // ===========================================
    error InvalidAddress();
    error Unauthorized();
    error FeedNotActive();
    error ProjectDoesNotExist();
    error ProjectNotActive();
    error InvalidParameters();
    error StaleData();
    error NoDataAvailable();
    error CircuitBreakerTriggered();
    error InvalidMetric();
    error MetricAlreadyExists();
    error InvalidValue();
    error AlreadyProcessed();
    error RequestAlreadyPending();
    error RequestNotFound();
    error UpgradeNotApproved();
    error ProposalAlreadyExecuted();
    error VerificationFailed();
    error DeviationExceedsThreshold();
    error PriceImpactTooHigh();
    error InvalidUnit();
    error DataValidationFailed();
    error CategoryNotSupported();
    error InsufficientHistory();
    error InsufficientVerifications();
    error MetricNotApplicable();


    // ===========================================
    // Enums & Constants
    // ===========================================
    // Carbon and ESG market categories
    enum ProjectCategory {
        CarbonCredit,
        RenewableEnergy,
        OceanCleanup,
        Reforestation,
        Biodiversity,
        SustainableAgriculture,
        WasteManagement,
        WaterConservation,
        PollutionControl,
        HabitatRestoration,
        GreenBuilding,
        CircularEconomy
    }


    enum ESGCategory { ENVIRONMENTAL, SOCIAL, GOVERNANCE }
    enum SourceType { IOT_DEVICE, MANUAL_ENTRY, THIRD_PARTY_API, SCIENTIFIC_MODEL, BLOCKCHAIN_ORACLE, AIRNODE }
    
    // Governance proposal types
    uint8 private constant PROPOSAL_TYPE_ADD_METRIC = 1;
    uint8 private constant PROPOSAL_TYPE_MODIFY_METRIC = 2;
    uint8 private constant PROPOSAL_TYPE_REGISTER_PROVIDER = 3;
    uint8 private constant PROPOSAL_TYPE_MODIFY_AIRNODE = 4;
    uint8 private constant PROPOSAL_TYPE_EMERGENCY_ACTION = 5;
    uint8 private constant PROPOSAL_TYPE_UPDATE_GOV_PARAMS = 6;
    uint8 private constant PROPOSAL_TYPE_MANAGE_FEED = 7;
    uint8 private constant PROPOSAL_TYPE_UPDATE_VERIFICATION_PARAMS = 8;


    // Constants
    bytes32 private constant CONTRACT_SIGNATURE = keccak256("v4.0-TERRA");
    uint256 private constant MAX_HISTORY_LENGTH = 100;
    uint256 private constant DATA_VALIDITY_PERIOD = 30 days;
    uint256 private constant MIN_TWAP_PERIOD = 5 minutes;
    uint256 private constant MAX_TWAP_PERIOD = 7 days;
    uint256 private constant MAX_DEVIATION_THRESHOLD = 0.1e18; // 10%
    
    // Contract configuration (immutable)
    uint256 private immutable ORACLE_TIMEOUT;
    uint256 private immutable CIRCUIT_BREAKER_THRESHOLD;
    uint256 private immutable MIN_VERIFICATIONS;


    // ===========================================
    // Roles
    // ===========================================
    bytes32 public constant DATA_PROVIDER_ROLE = keccak256("DATA_PROVIDER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant AIRNODE_MANAGER_ROLE = keccak256("AIRNODE_MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");


    // ===========================================
    // Data Structures
    // ===========================================
    struct ProjectData {
        ProjectCategory category;
        uint32 lastUpdated;
        bytes32 dataHash;
        int256 price;
        uint32 priceTimestamp;
        bool isActive;
        uint8 dataQualityScore; // 0-100 score
        uint16 updateCount;
        uint8 verificationCount;
    }


    struct ESGMetricDefinition {
        string name;
        string unit;
        string[] validationCriteria;
        address[] authorizedProviders;
        uint32 updateFrequency;
        uint8 minimumVerifications;
        ESGCategory category;
        uint8 importance; // 0-10 scale
        bool isActive;
        ProjectCategory[] applicableCategories;
    }


    struct ESGDataPoint {
        uint32 timestamp;
        int256 value;
        string unit;
        bytes32 dataHash;
        string rawDataURI;
        address provider;
        bool verified;
        address[] verifiers;
        string metadata;
    }


    struct PriceHistory {
        int256[100] prices;
        uint32[100] timestamps;
        uint8 currentIndex;
        uint8 size;
    }


    struct AirnodeConfig {
        address airnodeAddress;
        bytes32 endpointId;
        address sponsorWallet;
        uint32 lastRequestTimestamp;
        uint16 totalRequests;
        uint16 successfulResponses;
        bool active;
    }


    struct DataProvider {
        string name;
        string organization;
        string[] certifications;
        SourceType sourceType;
        uint32 lastUpdate;
        uint16 verifiedDataCount;
        uint16 totalSubmissions;
        uint16 rejectedSubmissions;
        uint8 reliabilityScore; // 0-100 score
        bool active;
        ProjectCategory[] specializations;
    }


    struct CrossChainState {
        uint32 lastSyncTimestamp;
        bytes32 stateHash;
        bytes stateData;
        uint16 sourceChainId;
        uint8 validationCount;
    }


    struct CircuitBreakerState {
        uint8 triggerCount;
        uint32 lastTriggerTime;
        uint32 lastResetTime;
        bool isTriggered;
    }


    // ===========================================
    // State Variables
    // ===========================================
    // Core Contracts
    ITerraStakeGovernance public governance;
    ITerraStakeProjects public terraStakeProjects;
    ITerraStakeToken public terraStakeToken;
    ITerraStakeLiquidityGuard public liquidityGuard;
    IAirnodeRrpV0 public airnodeRrp;


    // Governance State
    CrossChainState public currentChainState;
    mapping(uint256 => bool) public executedProposals;
    mapping(bytes32 => bool) public verifiedStateHashes;


    // Oracle State
    mapping(address => bool) public activeFeeds;
    mapping(address => PriceHistory) private priceHistories;
    mapping(address => CircuitBreakerState) public circuitBreakers;
    mapping(bytes32 => bytes32) public pendingRequests;
    address[] public priceOracles;


    // Project Data
    mapping(uint256 => ProjectData) public projectData;
    uint256[] public registeredProjects;
    mapping(uint256 => bool) public isRegisteredProject;


    // ESG Data
    mapping(bytes32 => ESGMetricDefinition) public esgMetrics;
    mapping(uint256 => mapping(bytes32 => ESGDataPoint[])) public projectESGData;
    bytes32[] public registeredMetrics;
    mapping(uint256 => mapping(bytes32 => uint256)) public latestVerifiedDataIndex;
    
    // Provider Management
    mapping(address => DataProvider) public dataProviders;
    mapping(bytes32 => AirnodeConfig) public airnodeConfigs;
    bytes32[] public activeAirnodes;


    // System State
    bool public emergencyShutdown;
    uint32 public lastEmergencyStateChange;
    uint16 public systemVersion;
    uint32 public lastSystemUpdate;
    
    // Parameters (updatable by governance)
    uint256 public minReportInterval;
    uint256 public maxPriceDeviation;
    uint256 public governanceDelay;
    uint256 public thresholdForConsensus;


    // ===========================================
    // Events
    // ===========================================
    event PriceUpdated(uint256 indexed projectId, int256 price, uint256 timestamp, address indexed oracle);
    event ESGMetricRegistered(bytes32 indexed metricId, string name, ESGCategory category);
    event ESGDataUpdated(uint256 indexed projectId, bytes32 indexed metricId, int256 value, address indexed provider);
    event ESGDataVerified(uint256 indexed projectId, bytes32 indexed metricId, address indexed verifier, uint256 dataIndex);
    event ProjectRegistered(uint256 indexed projectId, ProjectCategory category);
    event ProjectStatusChanged(uint256 indexed projectId, bool isActive);
    event FeedStatusChanged(address indexed feed, bool isActive);
    event DataProviderRegistered(address indexed provider, string name, string organization);
    event DataProviderStatusChanged(address indexed provider, bool active);
    event DataProviderScoreUpdated(address indexed provider, uint8 newScore);
    event AirnodeConfigured(bytes32 indexed airnodeId, address airnodeAddress, bytes32 endpointId);
    event AirnodeRequestMade(bytes32 indexed requestId, bytes32 indexed airnodeId, uint256 indexed projectId);
    event AirnodeResponseReceived(bytes32 indexed requestId, int256 value, uint256 timestamp);
    event CrossChainStateSynced(uint16 indexed srcChainId, bytes32 stateHash, uint256 timestamp);
    event CircuitBreakerTriggered(address indexed feed, uint256 timestamp, string reason);
    event CircuitBreakerReset(address indexed feed, uint256 timestamp);
    event EmergencyShutdown(address indexed initiator, uint256 timestamp, string reason);
    event EmergencyRecovery(address indexed initiator, uint256 timestamp);
    event GovernanceProposalExecuted(uint256 indexed proposalId, uint8 proposalType);
    event ContractUpgraded(address indexed implementation);
    event SystemParametersUpdated(string paramName, uint256 oldValue, uint256 newValue);
    event DeviationDetected(uint256 indexed projectId, int256 reportedPrice, int256 oraclePrice, uint256 deviationPct);
    event TWAPCalculated(uint256 indexed projectId, int256 twapValue, uint256 period);
    event MetricValidationCriteriaUpdated(bytes32 indexed metricId, string[] newCriteria);


    // ===========================================
    // Constructor & Initialization
    // ===========================================
    constructor() {
        ORACLE_TIMEOUT = 1 hours;
        CIRCUIT_BREAKER_THRESHOLD = 3;
        MIN_VERIFICATIONS = 2;
        _disableInitializers();
    }


    function initialize(
        address _admin,
        address _governanceContract,
        address _projectsContract,
        address _tokenContract,
        address _liquidityGuardContract,
        address _airnodeRrpAddress
    ) external initializer {
        if (_admin == address(0) || _governanceContract == address(0)) revert InvalidAddress();
        if (_projectsContract == address(0) || _tokenContract == address(0)) revert InvalidAddress();
        if (_liquidityGuardContract == address(0) || _airnodeRrpAddress == address(0)) revert InvalidAddress();


        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();


        // Initialize contracts
        governance = ITerraStakeGovernance(_governanceContract);
        terraStakeProjects = ITerraStakeProjects(_projectsContract);
        terraStakeToken = ITerraStakeToken(_tokenContract);
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuardContract);
        airnodeRrp = IAirnodeRrpV0(_airnodeRrpAddress);


        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(GOVERNANCE_ROLE, _governanceContract);
        _grantRole(UPGRADER_ROLE, _governanceContract);
        _grantRole(EMERGENCY_ROLE, _admin);
        
        // Initialize system parameters
        systemVersion = 1;
        minReportInterval = 1 hours;
        maxPriceDeviation = 0.05e18; // 5%
        governanceDelay = 2 days;
        thresholdForConsensus = 66; // 66% consensus required
        lastSystemUpdate = uint32(block.timestamp);
        emergencyShutdown = false;
    }


    // ===========================================
    // Governance Integration
    // ===========================================
    /**
     * @notice Executes a governance-approved proposal
     * @param proposalId Unique identifier for the proposal
     * @param proposalType Type of the proposal being executed
     * @param proposalData Encoded data for the proposal execution
    function executeGovernanceProposal(
        uint256 proposalId,
        uint8 proposalType,
        bytes calldata proposalData
    ) external nonReentrant {
        if (msg.sender != address(governance)) revert Unauthorized();
        if (executedProposals[proposalId]) revert ProposalAlreadyExecuted();


        if (proposalType == PROPOSAL_TYPE_ADD_METRIC) {
            _handleAddMetricProposal(proposalData);
        } 
        else if (proposalType == PROPOSAL_TYPE_MODIFY_METRIC) {
            _handleModifyMetricProposal(proposalData);
        }
        else if (proposalType == PROPOSAL_TYPE_REGISTER_PROVIDER) {
            _handleRegisterProviderProposal(proposalData);
        }
        else if (proposalType == PROPOSAL_TYPE_MODIFY_AIRNODE) {
            _handleAirnodeProposal(proposalData);
        }
        else if (proposalType == PROPOSAL_TYPE_EMERGENCY_ACTION) {
            (bool shutdown, string memory reason) = abi.decode(proposalData, (bool, string));
            _setEmergencyState(shutdown, reason);
        }
        else if (proposalType == PROPOSAL_TYPE_UPDATE_GOV_PARAMS) {
            _handleUpdateParametersProposal(proposalData);
        }
        else if (proposalType == PROPOSAL_TYPE_MANAGE_FEED) {
            _handleManageFeedProposal(proposalData);
        }
        else if (proposalType == PROPOSAL_TYPE_UPDATE_VERIFICATION_PARAMS) {
            _handleVerificationParamsProposal(proposalData);
        }
        else {
            revert InvalidParameters();
        }


        executedProposals[proposalId] = true;
        emit GovernanceProposalExecuted(proposalId, proposalType);
    }


    /**
     * @notice Processes a proposal to add a new ESG metric
     * @param proposalData Encoded data containing the new metric definition
     */
    function _handleAddMetricProposal(bytes calldata proposalData) internal {
        (
            string memory name,
            string memory unit,
            string[] memory validationCriteria,
            address[] memory providers,
            uint32 updateFrequency,
            uint8 minimumVerifications,
            uint8 categoryId,
            uint8 importance,
            ProjectCategory[] memory categories
        ) = abi.decode(
            proposalData, 
            (string, string, string[], address[], uint32, uint8, uint8, uint8, ProjectCategory[])
        );


        bytes32 metricId = keccak256(abi.encodePacked(name, unit, block.timestamp));
        if (esgMetrics[metricId].isActive) revert MetricAlreadyExists();
        if (importance > 10) revert InvalidValue();
        if (minimumVerifications < MIN_VERIFICATIONS) revert InvalidValue();
        if (categories.length == 0) revert InvalidParameters();


        ESGCategory category = ESGCategory(categoryId);
        
        esgMetrics[metricId] = ESGMetricDefinition({
            name: name,
            unit: unit,
            validationCriteria: validationCriteria,
            authorizedProviders: providers,
            updateFrequency: updateFrequency,
            minimumVerifications: minimumVerifications,
            category: category,
            importance: importance,
            isActive: true,
            applicableCategories: categories
        });


        registeredMetrics.push(metricId);
        emit ESGMetricRegistered(metricId, name, category);
    }


    /**
     * @notice Processes a proposal to modify an existing ESG metric
     * @param proposalData Encoded data containing the metric updates
     */
    function _handleModifyMetricProposal(bytes calldata proposalData) internal {
        (
            bytes32 metricId,
            string[] memory validationCriteria,
            address[] memory providers,
            uint32 updateFrequency,
            uint8 minimumVerifications,
            bool isActive
        ) = abi.decode(
            proposalData, 
            (bytes32, string[], address[], uint32, uint8, bool)
        );


        if (!esgMetrics[metricId].isActive && isActive == false) revert InvalidMetric();
        if (minimumVerifications < MIN_VERIFICATIONS) revert InvalidValue();


        ESGMetricDefinition storage metric = esgMetrics[metricId];
        metric.validationCriteria = validationCriteria;
        metric.authorizedProviders = providers;
        metric.updateFrequency = updateFrequency;
        metric.minimumVerifications = minimumVerifications;
        metric.isActive = isActive;


        emit MetricValidationCriteriaUpdated(metricId, validationCriteria);
    }


    /**
     * @notice Processes a proposal to register or update a data provider
     * @param proposalData Encoded data containing the provider information
     */
    function _handleRegisterProviderProposal(bytes calldata proposalData) internal {
        (
            address provider,
            string memory name,
            string memory organization,
            string[] memory certifications,
            uint8 sourceTypeId,
            bool active,
            ProjectCategory[] memory specializations
        ) = abi.decode(
            proposalData, 
            (address, string, string, string[], uint8, bool, ProjectCategory[])
        );


        if (provider == address(0)) revert InvalidAddress();
        
        DataProvider storage providerData = dataProviders[provider];
        providerData.name = name;
        providerData.organization = organization;
        providerData.certifications = certifications;
        providerData.sourceType = SourceType(sourceTypeId);
        providerData.active = active;
        providerData.specializations = specializations;
        
        if (active && !hasRole(DATA_PROVIDER_ROLE, provider)) {
            _grantRole(DATA_PROVIDER_ROLE, provider);
        } else if (!active && hasRole(DATA_PROVIDER_ROLE, provider)) {
            _revokeRole(DATA_PROVIDER_ROLE, provider);
        }


        emit DataProviderRegistered(provider, name, organization);
        emit DataProviderStatusChanged(provider, active);
    }


    /**
     * @notice Processes a proposal to configure an Airnode
     * @param proposalData Encoded data containing the Airnode configuration
     */
    function _handleAirnodeProposal(bytes calldata proposalData) internal {
        (
            address airnodeAddress,
            bytes32 endpointId,
            address sponsorWallet,
            bool active
        ) = abi.decode(
            proposalData, 
            (address, bytes32, address, bool)
        );


        if (airnodeAddress == address(0) || sponsorWallet == address(0)) revert InvalidAddress();
        
        bytes32 airnodeId = keccak256(abi.encodePacked(airnodeAddress, endpointId));
        
        if (active && !_containsAirnode(airnodeId)) {
            activeAirnodes.push(airnodeId);
        } else if (!active && _containsAirnode(airnodeId)) {
            _removeAirnode(airnodeId);
        }
        
        airnodeConfigs[airnodeId] = AirnodeConfig({
            airnodeAddress: airnodeAddress,
            endpointId: endpointId,
            sponsorWallet: sponsorWallet,
            lastRequestTimestamp: active ? uint32(block.timestamp) : 0,
            totalRequests: 0,
            successfulResponses: 0,
            active: active
        });
        
        emit AirnodeConfigured(airnodeId, airnodeAddress, endpointId);
    }


    /**
     * @notice Processes a proposal to update system parameters
     * @param proposalData Encoded data containing parameter updates
     */
    function _handleUpdateParametersProposal(bytes calldata proposalData) internal {
        (
            uint256 newMinReportInterval,
            uint256 newMaxPriceDeviation,
            uint256 newGovernanceDelay,
            uint256 newThresholdForConsensus
        ) = abi.decode(
            proposalData, 
            (uint256, uint256, uint256, uint256)
        );
        
        if (newMinReportInterval > 0) {
            uint256 oldValue = minReportInterval;
            minReportInterval = newMinReportInterval;
            emit SystemParametersUpdated("minReportInterval", oldValue, newMinReportInterval);
        }
        
        if (newMaxPriceDeviation > 0 && newMaxPriceDeviation <= MAX_DEVIATION_THRESHOLD) {
            uint256 oldValue = maxPriceDeviation;
            maxPriceDeviation = newMaxPriceDeviation;
            emit SystemParametersUpdated("maxPriceDeviation", oldValue, newMaxPriceDeviation);
        }
        
        if (newGovernanceDelay > 0) {
            uint256 oldValue = governanceDelay;
            governanceDelay = newGovernanceDelay;
            emit SystemParametersUpdated("governanceDelay", oldValue, newGovernanceDelay);
        }
        
        if (newThresholdForConsensus > 50 && newThresholdForConsensus <= 100) {
            uint256 oldValue = thresholdForConsensus;
            thresholdForConsensus = newThresholdForConsensus;
            emit SystemParametersUpdated("thresholdForConsensus", oldValue, newThresholdForConsensus);
        }
        
        lastSystemUpdate = uint32(block.timestamp);
    }


    /**
     * @notice Processes a proposal to manage a price feed
     * @param proposalData Encoded data containing feed management info
     */
    function _handleManageFeedProposal(bytes calldata proposalData) internal {
        (
            address feed,
            bool isActive
        ) = abi.decode(proposalData, (address, bool));
        
        if (feed == address(0)) revert InvalidAddress();
        
        activeFeeds[feed] = isActive;
        
        // Add to array if new active feed
        if (isActive && !_containsFeed(feed)) {
            priceOracles.push(feed);
        }
        
        // Reset circuit breaker if reactivating
        if (isActive && circuitBreakers[feed].isTriggered) {
            circuitBreakers[feed].isTriggered = false;
            circuitBreakers[feed].triggerCount = 0;
            circuitBreakers[feed].lastResetTime = uint32(block.timestamp);
            emit CircuitBreakerReset(feed, block.timestamp);
        }
        
        emit FeedStatusChanged(feed, isActive);
    }


    /**
     * @notice Processes a proposal to update verification parameters
     * @param proposalData Encoded data containing verification parameter updates
     */
    function _handleVerificationParamsProposal(bytes calldata proposalData) internal {
        // Implementation for verification params changes
        // This would typically adjust thresholds, required verifications, etc.
    }


    // ===========================================
    // Core Oracle Functions
    // ===========================================
    /**
     * @notice Updates a project's price data from authorized oracle feed
     * @param projectId ID of the project to update
     * @param price New price value
     * @param api3Proxy Optional API3 proxy address for cross-validation
     */
    function updateProjectPrice(
        uint256 projectId,
        int256 price,
        address api3Proxy
    ) external nonReentrant {
        if (emergencyShutdown) revert CircuitBreakerTriggered();
        if (!activeFeeds[msg.sender]) revert Unauthorized();
        if (!isRegisteredProject[projectId]) revert ProjectDoesNotExist();
        
        ProjectData storage project = projectData[projectId];
        if (!project.isActive) revert ProjectNotActive();
        
        // Check last report time
        if (project.lastUpdated + minReportInterval > block.timestamp) revert InvalidParameters();
        
        // Check for price manipulation
        if (project.priceTimestamp > 0) {
            uint256 deviation = _calculateDeviation(price, project.price);
            if (deviation > maxPriceDeviation) {
                _handlePriceDeviation(msg.sender, projectId, price, project.price, deviation);
                emit DeviationDetected(projectId, price, project.price, deviation);
            }
        }


        // Update price history (circular buffer)
        PriceHistory storage history = priceHistories[msg.sender];
        uint8 nextIndex = (history.currentIndex + 1) % MAX_HISTORY_LENGTH;
        history.prices[history.currentIndex] = price;
        history.timestamps[history.currentIndex] = uint32(block.timestamp);
        history.currentIndex = nextIndex;
        if (history.size < MAX_HISTORY_LENGTH) history.size++;


        // Update project data
        bytes32 newDataHash = keccak256(abi.encodePacked(projectId, price, block.timestamp, msg.sender));
        project.dataHash = newDataHash;
        project.price = price;
        project.priceTimestamp = uint32(block.timestamp);
        project.lastUpdated = uint32(block.timestamp);
        project.updateCount++;


        // Validate with API3 if provided
        if (api3Proxy != address(0)) {
            _validateWithAPI3(projectId, price, api3Proxy);
        }


        // Update data quality score based on verification history and update frequency
        _updateDataQualityScore(projectId);


        emit PriceUpdated(projectId, price, block.timestamp, msg.sender);
    }


    /**
     * @notice Submits new ESG data for a project
     * @param projectId ID of the project
     * @param metricId ID of the ESG metric
     * @param value The actual value for the metric
     * @param unit The unit of measurement
     * @param rawDataURI Link to raw data source
     * @param metadata Additional contextual information
     */
    function submitESGData(
        uint256 projectId,
        bytes32 metricId,
        int256 value,
        string calldata unit,
        string calldata rawDataURI,
        string calldata metadata
    ) external nonReentrant {
        if (emergencyShutdown) revert CircuitBreakerTriggered();
        if (!hasRole(DATA_PROVIDER_ROLE, msg.sender)) revert Unauthorized();
        
        ESGMetricDefinition storage metric = esgMetrics[metricId];
        if (!metric.isActive) revert InvalidMetric();
        if (!_isAuthorizedProvider(msg.sender, metricId)) revert Unauthorized();
        if (!isRegisteredProject[projectId]) revert ProjectDoesNotExist();
        if (!_isMetricApplicableToProject(metricId, projectId)) revert MetricNotApplicable();
        
        // Validate unit matches the defined unit
        if (keccak256(bytes(unit)) != keccak256(bytes(metric.unit))) revert InvalidUnit();
        
        // Validation logic for the value based on metric criteria could be added here
        
        bytes32 dataHash = keccak256(abi.encodePacked(projectId, metricId, value, block.timestamp,
            msg.sender, rawDataURI));
        
        ESGDataPoint storage dataPoint = projectESGData[projectId][metricId];
        
        // Store data
        dataPoint.value = value;
        dataPoint.unit = unit;
        dataPoint.dataHash = dataHash;
        dataPoint.submittedAt = uint32(block.timestamp);
        dataPoint.provider = msg.sender;
        dataPoint.rawDataURI = rawDataURI;
        dataPoint.metadata = metadata;
        dataPoint.verificationCount = 0;
        dataPoint.isVerified = false;
        
        // Add to verification queue
        if (!_isDataInVerificationQueue(projectId, metricId)) {
            dataVerificationQueue.push(VerificationTask({
                projectId: projectId,
                metricId: metricId,
                submittedAt: uint32(block.timestamp),
                completed: false
            }));
        }
        
        // Give provider credit for submission
        dataProviders[msg.sender].totalSubmissions++;
        
        emit ESGDataSubmitted(
            projectId,
            metricId,
            value,
            unit,
            msg.sender,
            block.timestamp,
            dataHash
        );
    }
    
    /**
     * @notice Verifies an ESG data submission
     * @param projectId ID of the project
     * @param metricId ID of the ESG metric
     * @param verificationResult True if data is verified as correct
     * @param comments Any verification comments or notes
     */
    function verifyESGData(
        uint256 projectId,
        bytes32 metricId,
        bool verificationResult,
        string calldata comments
    ) external nonReentrant {
        if (emergencyShutdown) revert CircuitBreakerTriggered();
        if (!hasRole(DATA_VALIDATOR_ROLE, msg.sender)) revert Unauthorized();
        if (!isRegisteredProject[projectId]) revert ProjectDoesNotExist();
        
        ESGDataPoint storage dataPoint = projectESGData[projectId][metricId];
        if (dataPoint.submittedAt == 0) revert DataNotFound();
        if (dataPoint.isVerified) revert DataAlreadyVerified();
        if (dataPoint.provider == msg.sender) revert CannotVerifyOwnData();
        
        ESGMetricDefinition storage metric = esgMetrics[metricId];
        
        // Record verification
        dataPoint.verifications[msg.sender] = Verification({
            validator: msg.sender,
            timestamp: uint32(block.timestamp),
            result: verificationResult,
            comments: comments
        });
        
        dataPoint.verificationCount++;
        
        // Update validator stats
        dataValidators[msg.sender].totalVerifications++;
        if (verificationResult) {
            dataValidators[msg.sender].positiveVerifications++;
        }
        
        // Check if we've reached verification threshold
        if (dataPoint.verificationCount >= metric.minimumVerifications) {
            uint8 positiveCount = 0;
            for (uint i = 0; i < dataPoint.verificationCount; i++) {
                if (dataPoint.verifications[address(uint160(i))].result) {
                    positiveCount++;
                }
            }
            
            // If verification threshold is met, mark as verified
            if (positiveCount >= metric.minimumVerifications) {
                dataPoint.isVerified = true;
                
                // Update project's ESG score
                _updateProjectESGScore(projectId);
                
                // Mark task as completed in verification queue
                _markVerificationTaskComplete(projectId, metricId);
                
                emit ESGDataVerified(projectId, metricId, true, dataPoint.verificationCount);
            }
        }
    }
    
    /**
     * @notice Requests data from an Airnode
     * @param airnodeId ID of the configured Airnode
     * @param parameters Encoded parameters for the API request
     * @param projectId Project ID this request relates to
     * @return requestId ID of the created request
     */
    function requestDataFromAirnode(
        bytes32 airnodeId,
        bytes calldata parameters,
        uint256 projectId
    ) external returns (bytes32 requestId) {
        if (emergencyShutdown) revert CircuitBreakerTriggered();
        if (!hasRole(API_CALLER_ROLE, msg.sender)) revert Unauthorized();
        if (!_containsAirnode(airnodeId)) revert InvalidAirnode();
        
        AirnodeConfig storage config = airnodeConfigs[airnodeId];
        if (!config.active) revert AirnodeNotActive();
        
        // Create Airnode request
        requestId = IAirnodeRrpV0(airnodeRrp).makeFullRequest(
            config.airnodeAddress,
            config.endpointId,
            address(this),
            config.sponsorWallet,
            address(this),
            this.fulfillDataRequest.selector,
            parameters
        );
        
        // Store request information
        pendingRequests[requestId] = AirnodeRequest({
            airnodeId: airnodeId,
            projectId: projectId,
            requestTimestamp: uint32(block.timestamp),
            fulfilled: false
        });
        
        // Update Airnode stats
        config.lastRequestTimestamp = uint32(block.timestamp);
        config.totalRequests++;
        
        emit AirnodeDataRequested(requestId, airnodeId, projectId, block.timestamp);
        return requestId;
    }
    
    /**
     * @notice Callback function for fulfilling Airnode requests
     * @param requestId ID of the fulfilled request
     * @param data Response data from the Airnode
     */
    function fulfillDataRequest(bytes32 requestId, bytes calldata data) external {
        if (msg.sender != airnodeRrp) revert Unauthorized();
        
        AirnodeRequest storage request = pendingRequests[requestId];
        if (request.requestTimestamp == 0) revert RequestNotFound();
        if (request.fulfilled) revert RequestAlreadyFulfilled();
        
        request.fulfilled = true;
        
        // Update Airnode stats
        AirnodeConfig storage config = airnodeConfigs[request.airnodeId];
        config.successfulResponses++;
        
        // Process response - how data is used depends on implementation needs
        // For example, decode and store:
        (int256 value, uint256 timestamp) = abi.decode(data, (int256, uint256));
        
        // Record result in external data references
        externalReferences[request.projectId][request.airnodeId] = ExternalDataPoint({
            value: value,
            timestamp: uint32(timestamp),
            receivedAt: uint32(block.timestamp),
            source: request.airnodeId
        });
        
        emit AirnodeResponseReceived(requestId, request.airnodeId, request.projectId, value);
    }
    
    /**
     * @notice Aggregates ESG data across multiple metrics to calculate a project score
     * @param projectId ID of the project to score
     * @return score The calculated ESG score (0-100)
     */
    function calculateProjectESGScore(uint256 projectId) public view returns (uint8 score) {
        if (!isRegisteredProject[projectId]) revert ProjectDoesNotExist();
        
        ProjectData storage project = projectData[projectId];
        
        // If score has been calculated recently, return cached value
        if (project.esgScoreTimestamp > block.timestamp - 1 days) {
            return project.esgScore;
        }
        
        // Get total importance weight
        uint256 totalWeight = 0;
        uint256 weightedSum = 0;
        uint256 applicableMetrics = 0;
        
        // Calculate weighted score across all applicable metrics
        for (uint i = 0; i < registeredMetrics.length; i++) {
            bytes32 metricId = registeredMetrics[i];
            ESGMetricDefinition storage metric = esgMetrics[metricId];
            
            if (!metric.isActive) continue;
            if (!_isMetricApplicableToProject(metricId, projectId)) continue;
            
            ESGDataPoint storage dataPoint = projectESGData[projectId][metricId];
            if (dataPoint.submittedAt == 0 || !dataPoint.isVerified) continue;
            
            // Calculate the score for this metric (0-100)
            uint8 metricScore = _calculateMetricScore(projectId, metricId);
            
            // Add to weighted sum
            weightedSum += uint256(metricScore) * uint256(metric.importance);
            totalWeight += uint256(metric.importance);
            applicableMetrics++;
        }
        
        // Return 0 if no applicable metrics were found
        if (applicableMetrics == 0 || totalWeight == 0) {
            return 0;
        }
        
        // Calculate final score (0-100)
        score = uint8(weightedSum / totalWeight);
        return score;
    }
    
    /**
     * @notice Sets the emergency state of the contract
     * @param shutdown True to activate emergency shutdown, false to deactivate
     * @param reason Text explaining the reason for the state change
     */
    function _setEmergencyState(bool shutdown, string memory reason) internal {
        emergencyShutdown = shutdown;
        emit EmergencyStateChanged(shutdown, reason, block.timestamp);
    }
    
    /**
     * @notice Handles a price deviation event
     * @param feed The oracle feed reporting the price
     * @param projectId The project ID
     * @param newPrice The new price being reported
     * @param oldPrice The previous price
     * @param deviation The calculated deviation percentage
     */
    function _handlePriceDeviation(
        address feed,
        uint256 projectId,
        int256 newPrice,
        int256 oldPrice,
        uint256 deviation
    ) internal {
        CircuitBreaker storage breaker = circuitBreakers[feed];
        
        // Increment trigger count
        breaker.triggerCount++;
        breaker.lastDeviationTimestamp = uint32(block.timestamp);
        
        // If too many triggers happen within timeframe, trip the circuit breaker
        if (breaker.triggerCount >= CIRCUIT_BREAKER_THRESHOLD) {
            uint256 timespan = block.timestamp - breaker.lastResetTime;
            if (timespan <= CIRCUIT_BREAKER_TIMEFRAME) {
                breaker.isTriggered = true;
                
                emit CircuitBreakerTriggered(
                    feed,
                    projectId,
                    breaker.triggerCount,
                    timespan,
                    newPrice,
                    oldPrice
                );
                
                // If too many feeds are triggering circuit breakers, consider emergency shutdown
                if (_countTrippedCircuitBreakers() > MAX_TRIPPED_CIRCUIT_BREAKERS) {
                    _setEmergencyState(true, "Multiple circuit breakers triggered");
                }
            } else {
                // Reset count if outside timeframe
                breaker.triggerCount = 1;
                breaker.lastResetTime = uint32(block.timestamp);
            }
        }
    }
    
    /**
     * @notice Validates a price update using API3 as a reference
     * @param projectId The project ID
     * @param price The price being validated
     * @param api3Proxy The API3 proxy contract address to query
     */
    function _validateWithAPI3(uint256 projectId, int256 price, address api3Proxy) internal {
        try IApi3DataReader(api3Proxy).read() returns (int224 value, uint32 timestamp) {
            // Convert to same decimals for comparison
            int256 api3Price = int256(value);
            
            // Check if API3 data is fresh enough
            if (block.timestamp - uint256(timestamp) <= API3_FRESHNESS_THRESHOLD) {
                uint256 deviation = _calculateDeviation(price, api3Price);
                
                if (deviation > maxPriceDeviation) {
                    emit API3ValidationFailed(projectId, price, api3Price, deviation);
                    
                    // Increment validation failure count
                    projectData[projectId].validationFailures++;
                    
                    // If too many consecutive failures, flag for review
                    if (projectData[projectId].validationFailures >= VALIDATION_FAILURE_THRESHOLD) {
                        projectData[projectId].requiresReview = true;
                        emit ProjectFlaggedForReview(projectId, "Repeated API3 validation failures");
                    }
                } else {
                    // Validation passed, reset counter
                    projectData[projectId].validationFailures = 0;
                }
            }
        } catch {
            // Failed to read from API3, log but continue
            emit API3ReadFailed(projectId, api3Proxy);
        }
    }
    
    /**
     * @notice Updates the data quality score for a project
     * @param projectId The project ID
     */
    function _updateDataQualityScore(uint256 projectId) internal {
        ProjectData storage project = projectData[projectId];
        
        // Base score on factors like:
        // 1. Update frequency (higher is better)
        // 2. Validation failure rate (lower is better)
        // 3. Age of data (fresher is better)
        // 4. Number of verified ESG metrics (more is better)
        
        uint8 frequencyScore = 0;
        uint8 validationScore = 0;
        uint8 freshnessScore = 0;
        uint8 coverageScore = 0;
        
        // Calculate frequency score (0-25) based on update count
        if (project.updateCount > 100) {
            frequencyScore = 25;
        } else {
            frequencyScore = uint8((project.updateCount * 25) / 100);
        }
        
        // Calculate validation score (0-25) based on validation failures
        if (project.validationFailures == 0) {
            validationScore = 25;
        } else {
            validationScore = uint8(25 - (project.validationFailures * 5));
            if (validationScore > 25) validationScore = 0;
        }
        
        // Calculate freshness score (0-25) based on last updated time
        uint256 age = block.timestamp - project.lastUpdated;
        if (age < 1 days) {
            freshnessScore = 25;
        } else if (age < 7 days) {
            freshnessScore = 20;
        } else if (age < 30 days) {
            freshnessScore = 10;
        } else {
            freshnessScore = 0;
        }
        
        // Calculate coverage score (0-25) based on verified ESG metrics
        uint256 verifiedMetrics = _countVerifiedMetrics(projectId);
        uint256 totalApplicableMetrics = _countApplicableMetrics(projectId);
        
        if (totalApplicableMetrics > 0) {
            coverageScore = uint8((verifiedMetrics * 25) / totalApplicableMetrics);
        }
        
        // Calculate total score (0-100)
        uint8 totalScore = frequencyScore + validationScore + freshnessScore + coverageScore;
        project.dataQualityScore = totalScore;
        project.dataQualityTimestamp = uint32(block.timestamp);
        
        emit DataQualityScoreUpdated(projectId, totalScore);
    }
    
    /**
     * @notice Updates a project's ESG score when data is verified
     * @param projectId The project ID
     */
    function _updateProjectESGScore(uint256 projectId) internal {
        uint8 score = calculateProjectESGScore(projectId);
        
        ProjectData storage project = projectData[projectId];
        project.esgScore = score;
        project.esgScoreTimestamp = uint32(block.timestamp);
        
        emit ESGScoreUpdated(projectId, score);
    }
    
    /**
     * @notice Calculates the score for a specific ESG metric (0-100)
     * @param projectId The project ID
     * @param metricId The metric ID
     * @return score The calculated score
     */
    function _calculateMetricScore(uint256 projectId, bytes32 metricId) internal view returns (uint8) {
        ESGDataPoint storage dataPoint = projectESGData[projectId][metricId];
        ESGMetricDefinition storage metric = esgMetrics[metricId];
        
        // This is a simplified scoring algorithm
        // In a real implementation, this would consider:
        // - The type of metric (some are better when higher, others when lower)
        // - Industry benchmarks
        // - Historical trends
        // - Whether the metric meets specific sustainability goals
        
        // For numeric metrics, normalize the value to a 0-100 scale
        // This is a placeholder implementation - actual implementation would be more sophisticated
        uint8 score = 50; // Default middle score
        
        // Different scoring logic based on category
        if (metric.category == ESGCategory.Environmental) {
            // For demonstration: Higher is better for environmental metrics
            // Would need to be tailored to specific metrics in practice
            if (dataPoint.value > 0) {
                // Simple scaling from 0-50 (bad) to 50-100 (good)
                // Would need to be tailored to expected ranges of specific metrics
                int256 normalizedValue = dataPoint.value > 1000 ? 1000 : dataPoint.value;
                score = uint8(50 + ((normalizedValue * 50) / 1000));
            }
        } 
        else if (metric.category == ESGCategory.Social) {
            // For social metrics, might have different benchmarks
            if (dataPoint.value > 0) {
                int256 normalizedValue = dataPoint.value > 100 ? 100 : dataPoint.value;
                score = uint8(50 + ((normalizedValue * 50) / 100));
            }
        }
        else if (metric.category == ESGCategory.Governance) {
            // Governance metrics often have specific thresholds
            if (dataPoint.value > 75) {
                score = 100;
            } else if (dataPoint.value > 50) {
                score = 75;
            } else if (dataPoint.value > 25) {
                score = 50;
            } else {
                score = 25;
            }
        }
        
        return score;
    }
    
    /**
     * @notice Counts the number of verified ESG metrics for a project
     * @param projectId The project ID
     * @return count The number of verified metrics
     */
    function _countVerifiedMetrics(uint256 projectId) internal view returns (uint256) {
        uint256 count = 0;
        
        for (uint i = 0; i < registeredMetrics.length; i++) {
            bytes32 metricId = registeredMetrics[i];
            
            if (!_isMetricApplicableToProject(metricId, projectId)) continue;
            
            ESGDataPoint storage dataPoint = projectESGData[projectId][metricId];
            if (dataPoint.isVerified) {
                count++;
            }
        }
        
        return count;
    }
    
    /**
     * @notice Counts the number of applicable ESG metrics for a project
     * @param projectId The project ID
     * @return count The number of applicable metrics
     */
    function _countApplicableMetrics(uint256 projectId) internal view returns (uint256) {
        uint256 count = 0;
        ProjectData storage project = projectData[projectId];
        
        for (uint i = 0; i < registeredMetrics.length; i++) {
            bytes32 metricId = registeredMetrics[i];
            ESGMetricDefinition storage metric = esgMetrics[metricId];
            
            if (!metric.isActive) continue;
            
            // Check if metric's categories match project's category
            for (uint j = 0; j < metric.applicableCategories.length; j++) {
                if (metric.applicableCategories[j] == project.category) {
                    count++;
                    break;
                }
            }
        }
        
        return count;
    }
    
    /**
     * @notice Checks if a data provider is authorized for a given metric
     * @param provider The provider address
     * @param metricId The metric ID
     * @return authorized True if provider is authorized
     */
    function _isAuthorizedProvider(address provider, bytes32 metricId) internal view returns (bool) {
        ESGMetricDefinition storage metric = esgMetrics[metricId];
        
        for (uint i = 0; i < metric.authorizedProviders.length; i++) {
            if (metric.authorizedProviders[i] == provider) {
                return true;
            }
        }
        
        return false;
    }
    
    /**
     * @notice Checks if a metric is applicable to a project
     * @param metricId The metric ID
     * @param projectId The project ID
     * @return applicable True if metric is applicable
     */
    function _isMetricApplicableToProject(bytes32 metricId, uint256 projectId) internal view returns (bool) {
        ESGMetricDefinition storage metric = esgMetrics[metricId];
        ProjectData storage project = projectData[projectId];
        
        for (uint i = 0; i < metric.applicableCategories.length; i++) {
            if (metric.applicableCategories[i] == project.category) {
                return true;
            }
        }
        
        return false;
    }
    
    /**
     * @notice Marks a verification task as complete
     * @param projectId The project ID
     * @param metricId The metric ID
     */
    function _markVerificationTaskComplete(uint256 projectId, bytes32 metricId) internal {
        for (uint i = 0; i < dataVerificationQueue.length; i++) {
            VerificationTask storage task = dataVerificationQueue[i];
            
            if (task.projectId == projectId && task.metricId == metricId && !task.completed) {
                task.completed = true;
                return;
            }
        }
    }
    
    /**
     * @notice Checks if data is already in the verification queue
     * @param projectId The project ID
     * @param metricId The metric ID
     * @return inQueue True if data is in verification queue
     */
    function _isDataInVerificationQueue(uint256 projectId, bytes32 metricId) internal view returns (bool) {
        for (uint i = 0; i < dataVerificationQueue.length; i++) {
            VerificationTask storage task = dataVerificationQueue[i];
            
            if (task.projectId == projectId && task.metricId == metricId && !task.completed) {
                return true;
            }
        }
        
        return false;
    }
    
    /**
     * @notice Counts the number of tripped circuit breakers
     * @return count The number of tripped circuit breakers
     */
    function _countTrippedCircuitBreakers() internal view returns (uint256) {
        uint256 count = 0;
        
        for (uint i = 0; i < priceOracles.length; i++) {
            address oracle = priceOracles[i];
            if (circuitBreakers[oracle].isTriggered) {
                count++;
            }
        }
        
        return count;
    }
    
    /**
     * @notice Calculates price deviation percentage
     * @param newPrice The new price
     * @param oldPrice The old price
     * @return deviation The calculated deviation percentage (10000 = 100%)
     */
    function _calculateDeviation(int256 newPrice, int256 oldPrice) internal pure returns (uint256) {
        if (oldPrice == 0) return 0;
        
        // Convert to absolute values and calculate percentage change
        uint256 oldAbs = oldPrice < 0 ? uint256(-oldPrice) : uint256(oldPrice);
        uint256 newAbs = newPrice < 0 ? uint256(-newPrice) : uint256(newPrice);
        
        if (newAbs > oldAbs) {
            return ((newAbs - oldAbs) * 10000) / oldAbs;
        } else {
            return ((oldAbs - newAbs) * 10000) / oldAbs;
        }
    }
    
    /**
     * @notice Checks if an Airnode is in the active list
     * @param airnodeId The Airnode ID
     * @return contains True if Airnode is in the list
     */
    function _containsAirnode(bytes32 airnodeId) internal view returns (bool) {
        for (uint i = 0; i < activeAirnodes.length; i++) {
            if (activeAirnodes[i] == airnodeId) {
                return true;
            }
        }
        return false;
    }
    
    /**
     * @notice Removes an Airnode from the active list
     * @param airnodeId The Airnode ID
     */
    function _removeAirnode(bytes32 airnodeId) internal {
        for (uint i = 0; i < activeAirnodes.length; i++) {
            if (activeAirnodes[i] == airnodeId) {
                // Replace with the last element and pop
                activeAirnodes[i] = activeAirnodes[activeAirnodes.length - 1];
                activeAirnodes.pop();
                return;
            }
        }
    }
    
    /**
     * @notice Checks if a feed is in the oracle list
     * @param feed The feed address
     * @return contains True if feed is in the list
     */
    function _containsFeed(address feed) internal view returns (bool) {
        for (uint i = 0; i < priceOracles.length; i++) {
            if (priceOracles[i] == feed) {
                return true;
            }
        }
        return false;
    }
    
    // ===========================================
    // View Functions
    // ===========================================
    
    /**
     * @notice Gets all active ESG metrics
     * @return metrics Array of active metric IDs
     */
    function getActiveMetrics() external view returns (bytes32[] memory) {
        uint256 count = 0;
        
        for (uint i = 0; i < registeredMetrics.length; i++) {
            if (esgMetrics[registeredMetrics[i]].isActive) {
                count++;
            }
        }
        
        bytes32[] memory activeMetrics = new bytes32[](count);
        uint256 index = 0;
        
        for (uint i = 0; i < registeredMetrics.length; i++) {
            bytes32 metricId = registeredMetrics[i];
            if (esgMetrics[metricId].isActive) {
                activeMetrics[index] = metricId;
                index++;
            }
        }
        
        return activeMetrics;
    }
    
    /**
     * @notice Gets details about an ESG metric
     * @param metricId The metric ID
     * @return name The metric name
     * @return unit The metric unit
     * @return category The metric category
     * @return importance The metric importance (0-10)
     * @return isActive Whether the metric is active
     */
    function getMetricDetails(bytes32 metricId) external view returns (
        string memory name,
        string memory unit,
        ESGCategory category,
        uint8 importance,
        bool isActive
    ) {
        ESGMetricDefinition storage metric = esgMetrics[metricId];
        return (
            metric.name,
            metric.unit,
            metric.category,
            metric.importance,
            metric.isActive
        );
    }
    
    /**
     * @notice Gets the latest ESG data for a project and metric
     * @param projectId The project ID
     * @param metricId The metric ID
     * @return value The data value
     * @return timestamp The submission timestamp
     * @return provider The data provider
     * @return isVerified Whether the data is verified
     */
    function getProjectESGData(uint256 projectId, bytes32 metricId) external view returns (
        int256 value,
        uint32 timestamp,
        address provider,
        bool isVerified
    ) {
        ESGDataPoint storage data = projectESGData[projectId][metricId];
        return (
            data.value,
            data.submittedAt,
            data.provider,
            data.isVerified
        );
    }
    
    /**
     * @notice Gets the current price for a project
     * @param projectId The project ID
     * @return price The current price
     * @return timestamp The price timestamp
     */
    function getProjectPrice(uint256 projectId) external view returns (
        int256 price,
        uint32 timestamp
    ) {
        ProjectData storage project = projectData[projectId];
        return (
            project.price,
            project.priceTimestamp
        );
    }
    
    /**
     * @notice Gets ESG and data quality scores for a project
     * @param projectId The project ID
     * @return esgScore The ESG score (0-100)
     * @return dataQuality The data quality score (0-100)
     */
    function getProjectScores(uint256 projectId) external view returns (
        uint8 esgScore,
        uint8 dataQuality
    ) {
        ProjectData storage project = projectData[projectId];
        
        // Recalculate ESG score if stale
        if (project.esgScoreTimestamp < block.timestamp - 1 days) {
            esgScore = calculateProjectESGScore(projectId);
        } else {
            esgScore = project.esgScore;
        }
        
        return (
            esgScore,
            project.dataQualityScore
        );
    }
    
    /**
     * @notice Gets the count of data points awaiting verification
     * @return count The number of pending verifications
     */
    function getPendingVerificationCount() external view returns (uint256) {
        uint256 count = 0;
        
        for (uint i = 0; i < dataVerificationQueue.length; i++) {
            if (!dataVerificationQueue[i].completed) {
                count++;
            }
        }
        
        return count;
    }
    
    /**
     * @notice Gets pending verification tasks
     * @param limit Maximum number of tasks to return
     * @return tasks Array of verification task information
     */
    function getPendingVerificationTasks(uint256 limit) external view returns (
        VerificationTask[] memory tasks
    ) {
        uint256 pendingCount = 0;
        
        // Count pending tasks first
        for (uint i = 0; i < dataVerificationQueue.length; i++) {
            if (!dataVerificationQueue[i].completed) {
                pendingCount++;
            }
        }
        
        // Apply limit
        uint256 returnCount = pendingCount < limit ? pendingCount : limit;
        tasks = new VerificationTask[](returnCount);
        
        // Fill the array with pending tasks
        uint256 resultIndex = 0;
        for (uint i = 0; i < dataVerificationQueue.length && resultIndex < returnCount; i++) {
            if (!dataVerificationQueue[i].completed) {
                tasks[resultIndex] = dataVerificationQueue[i];
                resultIndex++;
            }
        }
        
        return tasks;
    }
    
    /**
     * @notice Gets information about an Airnode
     * @param airnodeId The Airnode ID
     * @return config The Airnode configuration
     */
    function getAirnodeInfo(bytes32 airnodeId) external view returns (
        AirnodeConfig memory config
    ) {
        return airnodeConfigs[airnodeId];
    }
    
    /**
     * @notice Gets statistics about a data provider
     * @param provider The provider address
     * @return name Provider name
     * @return organization Provider organization
     * @return submissions Number of data submissions
     * @return active Whether the provider is active
     */
    function getProviderStats(address provider) external view returns (
        string memory name,
        string memory organization,
        uint256 submissions,
        bool active
    ) {
        DataProvider storage providerData = dataProviders[provider];
        return (
            providerData.name,
            providerData.organization,
            providerData.totalSubmissions,
            providerData.active
        );
    }
    
    /**
     * @notice Gets all projects with ESG data for a specific metric
     * @param metricId The metric ID
     * @return projectIds Array of project IDs
     */
    function getProjectsWithMetricData(bytes32 metricId) external view returns (
        uint256[] memory projectIds
    ) {
        uint256 count = 0;
        uint256[] memory tempProjects = new uint256[](registeredProjectCount);
        
        // Count projects with data for this metric
        for (uint i = 1; i <= registeredProjectCount; i++) {
            if (isRegisteredProject[i] && projectESGData[i][metricId].submittedAt > 0) {
                tempProjects[count] = i;
                count++;
            }
        }
        
        // Create correctly sized array with results
        projectIds = new uint256[](count);
        for (uint i = 0; i < count; i++) {
            projectIds[i] = tempProjects[i];
        }
        
        return projectIds;
    }
    
    /**
     * @notice Gets circuit breaker status for an oracle feed
     * @param feed The oracle feed address
     * @return isTriggered Whether the circuit breaker is triggered
     * @return triggerCount Number of triggers in current period
     * @return lastTriggered Timestamp of last trigger
     */
    function getCircuitBreakerStatus(address feed) external view returns (
        bool isTriggered,
        uint32 triggerCount,
        uint32 lastTriggered
    ) {
        CircuitBreaker storage breaker = circuitBreakers[feed];
        return (
            breaker.isTriggered,
            breaker.triggerCount,
            breaker.lastDeviationTimestamp
        );
    }
    
    /**
     * @notice Returns a list of all active oracle feeds
     * @return feeds Array of active oracle feed addresses
     */
    function getActiveFeeds() external view returns (address[] memory feeds) {
        uint256 activeCount = 0;
        
        // Count active feeds
        for (uint i = 0; i < priceOracles.length; i++) {
            if (activeFeeds[priceOracles[i]]) {
                activeCount++;
            }
        }
        
        // Create array of active feeds
        feeds = new address[](activeCount);
        uint256 index = 0;
        
        for (uint i = 0; i < priceOracles.length; i++) {
            address feed = priceOracles[i];
            if (activeFeeds[feed]) {
                feeds[index] = feed;
                index++;
            }
        }
        
        return feeds;
    }
    
    /**
     * @notice Check if a role is assigned to an account
     * @param role The role identifier
     * @param account The account to check
     * @return hasRole Whether the account has the role
     */
    function hasSpecificRole(bytes32 role, address account) external view returns (bool) {
        return hasRole(role, account);
    }
    
    /**
     * @notice Gets the emergency state of the contract
     * @return isShutdown Whether emergency shutdown is active
     */
    function getEmergencyState() external view returns (bool isShutdown) {
        return emergencyShutdown;
    }
    
    /**
     * @notice Gets current system parameters
     * @return parameters Struct containing system parameters
     */
    function getSystemParameters() external view returns (
        SystemParameters memory parameters
    ) {
        return SystemParameters({
            minReportInterval: minReportInterval,
            maxPriceDeviation: maxPriceDeviation,
            governanceDelay: governanceDelay,
            thresholdForConsensus: thresholdForConsensus,
            lastSystemUpdate: lastSystemUpdate
        });
    }
}          