// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IChainlinkDataFeeder {
    // ------------------------------------------------------------------------
    // 🔹 Enums & Structs
    // ------------------------------------------------------------------------
    enum ProjectCategory { 
        RENEWABLES, 
        CARBON_CREDITS, 
        ESG_SCORING, 
        ENERGY_STORAGE, 
        WATER_MANAGEMENT 
    }

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

    // ------------------------------------------------------------------------
    // 🔹 Events for Transparency & Monitoring
    // ------------------------------------------------------------------------
    event DataUpdated(address indexed feed, int256 value, uint256 timestamp);
    event ProjectDataUpdated(uint256 indexed projectId, int256 value, uint256 timestamp);
    event FeedActivationUpdated(address indexed feed, bool active);
    event OracleChangeRequested(address indexed feed, uint256 unlockTime);
    event OracleChangeConfirmed(address indexed feed);
    event CircuitBreakerTriggered(address indexed feed, uint256 failureCount);
    event TWAPViolationDetected(int256 reportedPrice, int256 TWAP);
    event CrossChainDataValidated(address indexed feed, bytes32 crossChainId, bool valid);
    event PerformanceMetricsUpdated(address indexed feed, uint256 reliability, uint256 latency, uint256 deviation);
    event GovernanceStatusChecked(bool status);
    event PriceImpactValidated(address feed, bool isValid);
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

    // ------------------------------------------------------------------------
    // 🔹 Governance Roles for Access Control
    // ------------------------------------------------------------------------
    function DEFAULT_ADMIN_ROLE() external pure returns (bytes32);
    function DEVICE_MANAGER_ROLE() external pure returns (bytes32);
    function DATA_MANAGER_ROLE() external pure returns (bytes32);
    function GOVERNANCE_ROLE() external pure returns (bytes32);
    function UPGRADER_ROLE() external pure returns (bytes32);
    function VERIFIER_ROLE() external pure returns (bytes32);

    // ------------------------------------------------------------------------
    // 🔹 Oracle Data & Feeds Management
    // ------------------------------------------------------------------------
    function lastKnownPrice(address feed) external view returns (int256);
    function activeFeeds(address feed) external view returns (bool);
    function feedFailures(address feed) external view returns (uint256);
    function pendingOracleChanges(bytes32 requestId) external view returns (uint256);
    function terraStakeProjects() external view returns (address);
    function terraStakeToken() external view returns (address);
    function liquidityGuard() external view returns (address);
    function priceOracles(uint256 index) external view returns (address);
    function priceOraclesLength() external view returns (uint256);
    function oracleRecords(address feed) external view returns (int256 price, uint256 timestamp);

    // ------------------------------------------------------------------------
    // 🔹 Oracle Data Analytics & Performance Tracking
    // ------------------------------------------------------------------------
    function feedAnalytics(address feed) external view returns (
        uint256 updateCount,
        uint256 lastValidation,
        uint256 reliabilityScore
    );

    function getFeedPerformanceMetrics(address feed) external view returns (
        uint256 reliability,
        uint256 latency,
        uint256 deviation
    );

    function getPriceHistory(address feed) external view returns (int256[] memory);
    function getPriceDeviationStats(address feed) external view returns (int256 min, int256 max, int256 average);
    function getActiveOracles() external view returns (address[] memory);
    function getOracleStatus(address feed) external view returns (
        bool isActive,
        int256 price,
        uint256 lastUpdate,
        uint256 failureCount,
        uint256 reliabilityScore
    );
    function getOracleData(address feed) external view returns (
        int256 price, 
        uint256 timestamp, 
        bool active, 
        uint256 updateCount
    );

    // ------------------------------------------------------------------------
    // 🔹 Cross-Chain Data Validation
    // ------------------------------------------------------------------------
    function crossChainData(bytes32 crossChainId) external view returns (int256);
    function validateCrossChainData(address feed, bytes32 crossChainId) external returns (bool);
    function setCrossChainData(bytes32 crossChainId, int256 price) external;
    function batchSetCrossChainData(bytes32[] calldata ids, int256[] calldata prices) external;

    // ------------------------------------------------------------------------
    // 🔹 Project Category Support
    // ------------------------------------------------------------------------
    function setCategoryFeed(ProjectCategory category, address feed, bool active) external;
    function categoryFeeds(ProjectCategory category, address feed) external view returns (bool);
    function categoryThresholds(ProjectCategory category) external view returns (int256);
    function validateCategoryData(ProjectCategory category, int256 value) external view returns (bool);

    // ------------------------------------------------------------------------
    // 🔹 ESG Metric Registration and Management
    // ------------------------------------------------------------------------
    function registerESGMetric(
        string calldata name,
        string calldata unit,
        string[] calldata validationCriteria,
        uint256 updateFrequency,
        uint256 minimumVerifications,
        ESGCategory category,
        uint8 importance
    ) external;

    function registerDataProvider(
        address provider,
        string calldata name,
        string calldata organization,
        string[] calldata certifications,
        SourceType sourceType
    ) external;

    function authorizeProviderForMetric(bytes32 metricId, address provider) external;
    
    function submitESGData(
        uint256 projectId,
        bytes32 metricId,
        int256 value,
        string calldata unit,
        string calldata rawDataURI
    ) external;

    function verifyESGData(
        uint256 projectId,
        bytes32 metricId,
        uint256 dataIndex
    ) external;

    function esgMetrics(bytes32 metricId) external view returns (
        string memory name,
        string memory unit,
        uint256 updateFrequency,
        uint256 minimumVerifications,
        ESGCategory category,
        uint8 importance
    );

    function dataProviders(address provider) external view returns (
        string memory name,
        string memory organization,
        SourceType sourceType,
        bool active,
        uint256 reliabilityScore,
        uint256 lastUpdate
    );

    function latestVerifiedValues(uint256 projectId, bytes32 metricId) external view returns (int256);
    function authorizedProviders(bytes32 metricId, address provider) external view returns (bool);
    
    // ------------------------------------------------------------------------
    // 🔹 ESG Data Conversion and Validation
    // ------------------------------------------------------------------------
    function setConversionRate(string calldata fromUnit, string calldata toUnit, int256 rate) external;
    function convertUnit(int256 value, string memory fromUnit, string memory toUnit) external view returns (int256);
    function getCarbonEquivalent(int256 value, string memory sourceMetric) external view returns (int256);
    function calculateESGScore(uint256 projectId, ESGCategory category) external view returns (uint256 score);
    function performESGAssessment(uint256 projectId) external;
    function carbonEquivalencyFactors(string calldata metric) external view returns (int256);
    function scientificStandards(string calldata metric) external view returns (string memory);
    function categoryMetrics(ESGCategory category, uint256 index) external view returns (bytes32);
    function getCategoryMetrics(ESGCategory category) external view returns (bytes32[] memory);
    
    function getProjectCategoryData(uint256 projectId, ESGCategory category) 
        external 
        view 
        returns (bytes32[] memory metricIds, int256[] memory values);

    // ------------------------------------------------------------------------
    // 🔹 Initialization & Configuration
    // ------------------------------------------------------------------------
    function initialize(
        address _terraStakeProjects,
        address _terraStakeToken,
        address _liquidityGuard,
        address[] calldata _oracles
    ) external;

    // ------------------------------------------------------------------------
    // 🔹 Data Feeds Management & Oracle Updates
    // ------------------------------------------------------------------------
    function updateData(address feed) external;
    function updateDataWithErrorHandling(address feed) external;
    function updateProjectData(uint256 projectId) external;
    function setFeedActive(address feed, bool active) external;
    function getLatestPrice(address feed) external view returns (int256);
    function validateDataFeed(address feed) external returns (bool);

    // ------------------------------------------------------------------------
    // 🔹 Multi-Oracle TWAP Validation
    // ------------------------------------------------------------------------
    function calculateExtendedTWAP(address feed, uint256 period) external view returns (int256);

    // ------------------------------------------------------------------------
    // 🔹 Governance-Controlled Oracle Management (Timelock Protected)
    // ------------------------------------------------------------------------
    function requestOracleAddition(address newOracle) external;
    function confirmOracleAddition(address newOracle) external;
    function requestOracleRemoval(address oracle) external;
    function confirmOracleRemoval(address oracle) external;

    // ------------------------------------------------------------------------
    // 🔹 Admin Functions
    // ------------------------------------------------------------------------
    function updateTerraStakeProjects(address _newProjects) external;
    function updateTerraStakeToken(address _newToken) external;
    function updateLiquidityGuard(address _newGuard) external;
    function setDataProviderStatus(address provider, bool active) external;
    function updateProviderReliability(address provider, uint256 score) external;
    function updateScientificStandard(string calldata metricName, string calldata standard) external;
    function updateCarbonEquivalencyFactor(string calldata sourceMetric, int256 factor) external;
    function emergencyResetCircuitBreaker(address feed) external;
    function emergencySetLastKnownPrice(address feed, int256 price) external;
    function updateReliabilityScore(address feed, uint256 score) external;

    // ------------------------------------------------------------------------
    // 🔹 Data Validation & Governance Integration
    // ------------------------------------------------------------------------
    function validateDataWithLiquidityGuard(int256 price) external view returns (bool);
    function checkGovernanceStatus() external view returns (bool);

    // ------------------------------------------------------------------------
    // 🔹 Data Validation & Chainlink Round Data
    // ------------------------------------------------------------------------
    function getFeedLatestRoundData(address feed) external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );

    // ------------------------------------------------------------------------
    // 🔹 Versioning & State Validation
    // ------------------------------------------------------------------------
    function getContractVersion() external pure returns (bytes32);
}
