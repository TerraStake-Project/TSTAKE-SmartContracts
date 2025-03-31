// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

// Required imports for types used in the interface
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@api3/contracts/v0.8/interfaces/IAirnodeRrpV0.sol";
import "../interfaces/ITerraStakeProjects.sol";
import "../interfaces/ITerraStakeToken.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";
import "../interfaces/ITerraStakeGovernance.sol";

/**
 * @title IAPI3DataFeeder
 * @notice Interface for the API3DataFeeder contract
 * @dev Defines all external functions, events, and data structures
 */
interface IAPI3DataFeeder {
    // ===========================================
    // Errors
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
    // Enums & Structs
    // ===========================================
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

    struct ProjectData {
        ProjectCategory category;
        uint32 lastUpdated;
        bytes32 dataHash;
        int256 price;
        uint32 priceTimestamp;
        bool isActive;
        uint8 dataQualityScore;
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
        uint8 importance;
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
        uint8 reliabilityScore;
        bool active;
        ProjectCategory[] specializations;
    }

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
    // External Contract References
    // ===========================================
    function governance() external view returns (ITerraStakeGovernance);
    function terraStakeProjects() external view returns (ITerraStakeProjects);
    function terraStakeToken() external view returns (ITerraStakeToken);
    function liquidityGuard() external view returns (ITerraStakeLiquidityGuard);
    function airnodeRrp() external view returns (IAirnodeRrpV0);

    // ===========================================
    // Role Constants
    // ===========================================
    function DATA_PROVIDER_ROLE() external view returns (bytes32);
    function GOVERNANCE_ROLE() external view returns (bytes32);
    function UPGRADER_ROLE() external view returns (bytes32);
    function VERIFIER_ROLE() external view returns (bytes32);
    function AIRNODE_MANAGER_ROLE() external view returns (bytes32);
    function EMERGENCY_ROLE() external view returns (bytes32);

    // ===========================================
    // Initialization
    // ===========================================
    function initialize(
        address _admin,
        address _governanceContract,
        address _projectsContract,
        address _tokenContract,
        address _liquidityGuardContract,
        address _airnodeRrpAddress
    ) external;

    // ===========================================
    // Governance Functions
    // ===========================================
    function executeGovernanceProposal(
        uint256 proposalId,
        uint8 proposalType,
        bytes calldata proposalData
    ) external;

    // ===========================================
    // Core Data Functions
    // ===========================================
    function updateProjectPrice(
        uint256 projectId,
        int256 price,
        address api3Proxy
    ) external;

    function submitESGData(
        uint256 projectId,
        bytes32 metricId,
        int256 value,
        string calldata unit,
        string calldata rawDataURI,
        string calldata metadata
    ) external;

    function verifyESGData(
        uint256 projectId,
        bytes32 metricId,
        uint256 dataIndex
    ) external;

    function registerProject(
        uint256 projectId,
        ProjectCategory category
    ) external;

    // ===========================================
    // Airnode Functions
    // ===========================================
    function requestAirnodeData(
        bytes32 airnodeId,
        uint256 projectId,
        bytes calldata parameters
    ) external returns (bytes32 requestId);

    function fulfillAirnodeRequest(
        bytes32 requestId,
        bytes calldata data
    ) external;

    // ===========================================
    // Cross-Chain Functions
    // ===========================================
    function syncCrossChainState(
        uint16 srcChainId,
        CrossChainState memory state
    ) external;

    // ===========================================
    // Emergency Controls
    // ===========================================
    function setEmergencyState(
        bool shutdown,
        string calldata reason
    ) external;

    function resetCircuitBreaker(
        address feed
    ) external;

    // ===========================================
    // View Functions
    // ===========================================
    function getLatestPrice(
        uint256 projectId
    ) external view returns (int256 price, uint256 timestamp, uint8 dataQualityScore);

    function calculateTWAP(
        address oracleAddress,
        uint256 period
    ) external view returns (int256 twap);

    function getESGData(
        uint256 projectId,
        bytes32 metricId
    ) external view returns (ESGDataPoint[] memory dataPoints);

    function getLatestVerifiedESGData(
        uint256 projectId,
        bytes32 metricId
    ) external view returns (int256 value, uint256 timestamp, uint256 verifications);

    function getAllMetrics() external view returns (bytes32[] memory);

    function getAllProjects() external view returns (uint256[] memory);

    function getProjectDetails(
        uint256 projectId
    ) external view returns (
        ProjectCategory category,
        uint256 lastUpdated,
        int256 price,
        uint256 priceTimestamp,
        bool isActive,
        uint8 dataQualityScore
    );

    function getMetricDetails(
        bytes32 metricId
    ) external view returns (
        string memory name,
        string memory unit,
        ESGCategory category,
        uint8 importance,
        bool isActive
    );

    function getPriceHistory(
        address oracleAddress
    ) external view returns (int256[] memory prices, uint32[] memory timestamps);

    function getProviderDetails(
        address provider
    ) external view returns (
        string memory name,
        string memory organization,
        uint8 reliabilityScore,
        bool active
    );

    // ===========================================
    // State Access Functions
    // ===========================================
    function projectData(uint256 projectId) external view returns (ProjectData memory);
    function registeredProjects(uint256 index) external view returns (uint256);
    function isRegisteredProject(uint256 projectId) external view returns (bool);
    function esgMetrics(bytes32 metricId) external view returns (ESGMetricDefinition memory);
    function registeredMetrics(uint256 index) external view returns (bytes32);
    function latestVerifiedDataIndex(uint256 projectId, bytes32 metricId) external view returns (uint256);
    function dataProviders(address provider) external view returns (DataProvider memory);
    function airnodeConfigs(bytes32 airnodeId) external view returns (AirnodeConfig memory);
    function activeAirnodes(uint256 index) external view returns (bytes32);
    function priceOracles(uint256 index) external view returns (address);
    function activeFeeds(address feed) external view returns (bool);
    function circuitBreakers(address feed) external view returns (CircuitBreakerState memory);
    function pendingRequests(bytes32 requestId) external view returns (bytes32);
    function executedProposals(uint256 proposalId) external view returns (bool);
    function verifiedStateHashes(bytes32 stateHash) external view returns (bool);
    function currentChainState() external view returns (CrossChainState memory);
    function emergencyShutdown() external view returns (bool);
    function lastEmergencyStateChange() external view returns (uint32);
    function systemVersion() external view returns (uint16);
    function lastSystemUpdate() external view returns (uint32);
    function minReportInterval() external view returns (uint256);
    function maxPriceDeviation() external view returns (uint256);
    function governanceDelay() external view returns (uint256);
    function thresholdForConsensus() external view returns (uint256);

    // ===========================================
    // Fallback & Receive
    // ===========================================
    fallback() external payable;
    receive() external payable;
}