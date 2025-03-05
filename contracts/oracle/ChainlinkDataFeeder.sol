// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable-5.2/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable-5.2/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable-5.2/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable-5.2/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-5.2/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

interface ITerraStakeProjects {
    function updateProjectDataFromChainlink(uint256 projectId, int256 price) external;
    function updateProjectESGData(uint256 projectId, string memory category, string memory metric, int256 value) external;
    function getProjectCategory(uint256 projectId) external view returns (uint8);
}

interface ITerraStakeToken {
    function getGovernanceStatus() external view returns (bool);
}

interface ITerraStakeLiquidityGuard {
    function validatePriceImpact(int256 price) external view returns (bool);
}

/**
 * @title ChainlinkDataFeeder
 * @notice Upgradeable oracle with comprehensive sustainability data capabilities for the TerraStake ecosystem
 * @dev Fully compatible with OpenZeppelin 5.2.x and supports 12 project categories
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
    error CategoryNotSupported();
    error MetricAlreadyExists();

    // -------------------------------------------
    // 🔹 Enums & Data Structures
    // -------------------------------------------
    enum ProjectCategory {
        CarbonCredit,
        RenewableEnergy,
        OceanCleanup,
        Reforestation,
        Biodiversity,
        SustainableAg,
        WasteManagement,
        WaterConservation,
        PollutionControl,
        HabitatRestoration,
        GreenBuilding,
        CircularEconomy
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
        bool isActive;
        ProjectCategory[] applicableCategories;
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
        string metadata;
    }

    struct DataProvider {
        string name;
        string organization;
        string[] certifications;
        SourceType sourceType;
        bool active;
        uint256 reliabilityScore;
        uint256 lastUpdate;
        ProjectCategory[] specializations;
        uint256 verifiedDataCount;
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
        mapping(ProjectCategory => uint256) categoryUpdateCount;
    }

    // Project category specific data structures
    struct CarbonCreditData {
        int256 creditAmount;       // in tCO2e
        int256 vintageYear;
        string protocol;           // e.g., "Verra", "Gold Standard"
        string methodology;
        int256 verificationStatus; // 0-100% verified
        int256 permanence;         // years of carbon sequestration
        int256 additionalityScore; // 0-100
        int256 leakageRisk;        // 0-100
        string registryLink;
        int256 creditPrice;        // in USD per tCO2e
    }

    struct RenewableEnergyData {
        int256 capacityMW;         // Megawatts
        int256 generationMWh;      // Megawatt hours
        int256 carbonOffset;       // tCO2e avoided
        string energyType;         // "Solar", "Wind", "Hydro", etc.
        int256 efficiencyRating;   // 0-100
        int256 capacityFactor;     // 0-100
        int256 gridIntegration;    // 0-100
        int256 storageCapacity;    // in MWh
        int256 landUseHectares;
        int256 lcoe;               // Levelized Cost of Energy (USD/MWh)
    }

    struct OceanCleanupData {
        int256 plasticCollectedKg;
        int256 areaCleanedKm2;
        int256 biodiversityImpact; // -100 to 100
        int256 carbonImpact;       // tCO2e
        string cleanupMethod;
        int256 recyclingRate;      // 0-100
        int256 preventionMeasures; // 0-100
        int256 communityEngagement;// 0-100
        int256 marineLifeSaved;
        int256 coastalProtection;  // 0-100
    }

    struct ReforestationData {
        int256 areaReforesedHa;
        int256 treeQuantity;
        int256 survivalRate;       // 0-100
        int256 carbonSequestration;// tCO2e
        string speciesPlanted;
        int256 biodiversityScore;  // 0-100
        int256 soilQualityImprovement; // 0-100
        int256 waterRetention;     // 0-100
        int256 communityBenefit;   // 0-100
        int256 monitoringFrequency;// days between monitoring
    }

    struct BiodiversityData {
        int256 speciesProtected;
        int256 habitatAreaHa;
        int256 populationIncrease; // percentage
        int256 ecosystemServices;  // USD value
        string keySpecies;
        int256 threatReduction;    // 0-100
        int256 geneticDiversity;   // 0-100
        int256 resilienceScore;    // 0-100
        int256 invasiveSpeciesControl; // 0-100
        int256 legalProtectionLevel; // 0-100
    }

    struct SustainableAgData {
        int256 landAreaHa;
        int256 yieldIncrease;      // percentage
        int256 waterSavingsCubicM;
        int256 carbonSequestration;// tCO2e
        string farmingPractices;
        int256 soilHealthScore;    // 0-100
        int256 pesticideReduction; // percentage
        int256 organicCertification; // 0-100
        int256 biodiversityIntegration; // 0-100
        int256 economicViability;  // 0-100
    }

    struct WasteManagementData {
        int256 wasteProcessedTons;
        int256 recyclingRate;      // percentage
        int256 landfillDiversionRate; // percentage
        int256 compostingVolume;   // cubic meters
        string wasteTypes;
        int256 energyGenerated;    // kWh
        int256 ghgReduction;       // tCO2e
        int256 contaminationRate;  // percentage
        int256 collectionEfficiency; // 0-100
        int256 circularEconomyScore; // 0-100
    }

    struct WaterConservationData {
        int256 waterSavedCubicM;
        int256 waterQualityImprovement; // percentage
        int256 watershedAreaProtected; // hectares
        int256 energySavingsKWh;
        string conservationMethod;
        int256 rechargeBenefits;   // 0-100
        int256 communityAccess;    // percentage improvement
        int256 droughtResilience;  // 0-100
        int256 pollutantReduction; // percentage
        int256 ecosystemBenefit;   // 0-100
    }

    struct PollutionControlData {
        int256 emissionsReducedTons;
        int256 airQualityImprovement; // percentage
        int256 waterQualityImprovement; // percentage
        int256 healthImpact;       // DALYs averted
        string pollutantType;
        int256 remedationEfficiency; // 0-100
        int256 monitoringCoverage; // 0-100
        int256 complianceRate;     // 0-100
        int256 communitySatisfaction; // 0-100
        int256 technologyInnovation; // 0-100
    }

    struct HabitatRestorationData {
        int256 areaRestoredHa;
        int256 speciesReintroduced;
        int256 ecologicalConnectivity; // 0-100
        int256 carbonSequestration; // tCO2e
        string habitatType;
        int256 soilImprovement;    // 0-100
        int256 waterQualityImprovement; // 0-100
        int256 successRate;        // 0-100
        int256 indigenousKnowledge; // 0-100
        int256 longTermSustainability; // 0-100
    }

    struct GreenBuildingData {
        int256 energyEfficiencyImprovement; // percentage
        int256 waterEfficiencyImprovement; // percentage
        int256 wasteReduction;     // percentage
        int256 carbonFootprintReduction; // tCO2e
        string certificationLevel; // "LEED Platinum", "BREEAM Excellent", etc.
        int256 renewableEnergyUse; // percentage
        int256 indoorAirQuality;   // 0-100
        int256 materialSustainability; // 0-100
        int256 occupantWellbeing;  // 0-100
        int256 adaptabilityScore;  // 0-100
    }

    struct CircularEconomyData {
        int256 materialReuseRate;  // percentage
        int256 productLifeExtension; // percentage
        int256 wasteReduction;     // percentage
        int256 resourceEfficiencyGain; // percentage
        string circularStrategies;
        int256 repairabilityScore; // 0-100
        int256 designForDisassembly; // 0-100
        int256 sustainableSourcing; // 0-100
        int256 businessModelInnovation; // 0-100
        int256 valueRetention;     // 0-100
    }

    // -------------------------------------------
    // 🔹 Security & Governance Constants
    // -------------------------------------------
    bytes32 private constant CONTRACT_SIGNATURE = keccak256("v3.0");
    uint256 private constant STATE_SYNC_INTERVAL = 15 minutes;
    uint256 private constant ORACLE_TIMEOUT = 1 hours;
    uint256 private constant CIRCUIT_BREAKER_THRESHOLD = 3;
    uint256 private constant GOVERNANCE_CHANGE_DELAY = 1 days;
    uint256 private constant MAX_HISTORY_LENGTH = 100;
    uint256 private constant DATA_VALIDITY_PERIOD = 30 days;

    // -------------------------------------------
    // 🔹 Roles for Security
    // -------------------------------------------
    bytes32 public constant DEVICE_MANAGER_ROLE = keccak256("DEVICE_MANAGER_ROLE");
    bytes32 public constant DATA_MANAGER_ROLE = keccak256("DATA_MANAGER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant CATEGORY_MANAGER_ROLE = keccak256("CATEGORY_MANAGER_ROLE");

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
    mapping(address => DataProvider) public dataProviders
    // -------------------------------------------
    // 🔹 Project Category Data Mappings
    // -------------------------------------------
    mapping(uint256 => CarbonCreditData) public carbonCreditProjects;
    mapping(uint256 => RenewableEnergyData) public renewableEnergyProjects;
    mapping(uint256 => OceanCleanupData) public oceanCleanupProjects;
    mapping(uint256 => ReforestationData) public reforestationProjects;
    mapping(uint256 => BiodiversityData) public biodiversityProjects;
    mapping(uint256 => SustainableAgData) public sustainableAgProjects;
    mapping(uint256 => WasteManagementData) public wasteManagementProjects;
    mapping(uint256 => WaterConservationData) public waterConservationProjects;
    mapping(uint256 => PollutionControlData) public pollutionControlProjects;
    mapping(uint256 => HabitatRestorationData) public habitatRestorationProjects;
    mapping(uint256 => GreenBuildingData) public greenBuildingProjects;
    mapping(uint256 => CircularEconomyData) public circularEconomyProjects;

    // -------------------------------------------
    // 🔹 System Contracts
    // -------------------------------------------
    ITerraStakeProjects public terraStakeProjects;
    ITerraStakeToken public terraStakeToken;
    ITerraStakeLiquidityGuard public liquidityGuard;

    // -------------------------------------------
    // 🔹 Events
    // -------------------------------------------
    event PriceUpdated(uint256 indexed projectId, int256 price, uint256 timestamp);
    event FeedActivated(address indexed feed);
    event FeedDeactivated(address indexed feed);
    event ESGMetricRegistered(bytes32 indexed metricId, string name, ESGCategory category);
    event ESGDataUpdated(uint256 indexed projectId, bytes32 indexed metricId, int256 value);
    event DataProviderRegistered(address indexed provider, string name, string organization);
    event DataVerified(uint256 indexed projectId, bytes32 indexed metricId, address indexed verifier);
    event CategoryDataUpdated(uint256 indexed projectId, ProjectCategory indexed category);
    event OracleFailure(address indexed oracle, uint256 failureCount);
    event ContractUpgraded(address indexed implementation);
    event CrossChainDataValidated(bytes32 indexed dataHash, int256 value);
    event CircuitBreakerTriggered(address indexed feed);
    event CircuitBreakerReset(address indexed feed);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with initial roles and systems
     * @param _admin Administrator address
     * @param _projectsContract TerraStake Projects contract address
     * @param _tokenContract TerraStake Token contract address
     * @param _liquidityGuardContract TerraStake Liquidity Guard contract address
     */
    function initialize(
        address _admin,
        address _projectsContract,
        address _tokenContract, 
        address _liquidityGuardContract
    ) external initializer {
        if (_admin == address(0) || 
            _projectsContract == address(0) || 
            _tokenContract == address(0) || 
            _liquidityGuardContract == address(0)) revert InvalidAddress();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(DEVICE_MANAGER_ROLE, _admin);
        _grantRole(DATA_MANAGER_ROLE, _admin);
        _grantRole(GOVERNANCE_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
        _grantRole(VERIFIER_ROLE, _admin);
        _grantRole(CATEGORY_MANAGER_ROLE, _admin);

        terraStakeProjects = ITerraStakeProjects(_projectsContract);
        terraStakeToken = ITerraStakeToken(_tokenContract);
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuardContract);
    }

    /**
     * @notice Adds a Chainlink price feed oracle
     * @param oracle Address of the Chainlink price feed oracle
     */
    function addPriceOracle(address oracle) external onlyRole(DEVICE_MANAGER_ROLE) {
        if (oracle == address(0)) revert InvalidAddress();
        
        if (!activeFeeds[oracle]) {
            activeFeeds[oracle] = true;
            priceOracles.push(oracle);
            emit FeedActivated(oracle);
        }
    }

    /**
     * @notice Deactivates a price feed oracle
     * @param oracle Address of the Chainlink price feed oracle to deactivate
     */
    function deactivatePriceOracle(address oracle) external onlyRole(DEVICE_MANAGER_ROLE) {
        if (!activeFeeds[oracle]) revert FeedNotActive();
        
        activeFeeds[oracle] = false;
        feedFailures[oracle] = 0;
        emit FeedDeactivated(oracle);
    }

    /**
     * @notice Updates price data for a specific project from Chainlink oracle
     * @param projectId The ID of the project to update
     * @param oracle The address of the Chainlink oracle to use
     */
    function updateProjectPrice(uint256 projectId, address oracle) external nonReentrant {
        if (!activeFeeds[oracle]) revert FeedNotActive();
        if (feedFailures[oracle] >= CIRCUIT_BREAKER_THRESHOLD) revert FeedNotActive();

        try AggregatorV3Interface(oracle).latestRoundData() returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            if (answer <= 0) revert InvalidOracleData();
            if (block.timestamp - updatedAt > ORACLE_TIMEOUT) revert StaleOracleData();
            if (roundId <= answeredInRound) revert InvalidOracleData();
            
            // Validate price impact
            if (!liquidityGuard.validatePriceImpact(answer)) revert PriceImpactTooHigh();
            
            // Update oracle record and project data
            oracleRecords[oracle] = OracleData(answer, updatedAt);
            lastKnownPrice[oracle] = answer;
            
            // Update project price through TerraStake Projects contract
            terraStakeProjects.updateProjectDataFromChainlink(projectId, answer);
            
            // Update analytics
            FeedAnalytics storage analytics = feedAnalytics[oracle];
            analytics.updateCount++;
            analytics.lastValidation = block.timestamp;
            
            if (analytics.priceHistory.length < MAX_HISTORY_LENGTH) {
                analytics.priceHistory.push(answer);
            } else {
                // Circular buffer approach
                for (uint i = 0; i < MAX_HISTORY_LENGTH - 1; i++) {
                    analytics.priceHistory[i] = analytics.priceHistory[i + 1];
                }
                analytics.priceHistory[MAX_HISTORY_LENGTH - 1] = answer;
            }
            
            // Track category-specific updates
            uint8 category = terraStakeProjects.getProjectCategory(projectId);
            if (category < uint8(type(ProjectCategory).max)) {
                analytics.categoryUpdateCount[ProjectCategory(category)]++;
            }
            
            emit PriceUpdated(projectId, answer, updatedAt);
            
            // Reset failure counter on success
            feedFailures[oracle] = 0;
        } catch {
            // Increment failure counter
            feedFailures[oracle]++;
            emit OracleFailure(oracle, feedFailures[oracle]);
            
            // Trigger circuit breaker if threshold reached
            if (feedFailures[oracle] >= CIRCUIT_BREAKER_THRESHOLD) {
                emit CircuitBreakerTriggered(oracle);
            }
            
            revert InvalidOracleData();
        }
    }

    /**
     * @notice Registers a new ESG metric definition
     * @param name Metric name
     * @param unit Unit of measurement
     * @param validationCriteria Array of validation criteria
     * @param authorizedProviders Array of authorized provider addresses
     * @param updateFrequency Required update frequency in seconds
     * @param minimumVerifications Minimum number of verifications required
     * @param category ESG category (Environmental, Social, Governance)
     * @param importance Importance score (0-10)
     * @param applicableCategories Array of project categories where metric is applicable
     * @return metricId The unique identifier for the registered metric
     */
    function registerESGMetric(
        string memory name,
        string memory unit,
        string[] memory validationCriteria,
        address[] memory authorizedProviders,
        uint256 updateFrequency,
        uint256 minimumVerifications,
        ESGCategory category,
        uint8 importance,
        ProjectCategory[] memory applicableCategories
    ) external onlyRole(DATA_MANAGER_ROLE) returns (bytes32) {
        if (bytes(name).length == 0 || bytes(unit).length == 0) revert InvalidParameters();
        if (authorizedProviders.length == 0) revert InvalidParameters();
        if (importance > 10) revert InvalidParameters();
        
        bytes32 metricId = keccak256(abi.encodePacked(name, block.timestamp));
        
        if (bytes(esgMetrics[metricId].name).length != 0) revert MetricAlreadyExists();
        
        esgMetrics[metricId] = ESGMetricDefinition({
            name: name,
            unit: unit,
            validationCriteria: validationCriteria,
            authorizedProviders: authorizedProviders,
            updateFrequency: updateFrequency,
            minimumVerifications: minimumVerifications,
            category: category,
            importance: importance,
            isActive: true,
            applicableCategories: applicableCategories
        });
        
        emit ESGMetricRegistered(metricId, name, category);
        return metricId;
    }

    /**
     * @notice Updates ESG data for a specific project
     * @param projectId The ID of the project
     * @param metricId The ID of the ESG metric
     * @param value The new value for the metric
     * @param rawDataURI URI to raw data source
     * @param metadata Additional metadata about this data point
     */
    function updateESGData(
        uint256 projectId,
        bytes32 metricId,
        int256 value,
        string memory rawDataURI,
        string memory metadata
    ) external nonReentrant {
        ESGMetricDefinition storage metric = esgMetrics[metricId];
        
        if (!metric.isActive) revert InvalidMetric();
        
        bool isAuthorized = false;
        for (uint i = 0; i < metric.authorizedProviders.length; i++) {
            if (metric.authorizedProviders[i] == msg.sender) {
                isAuthorized = true;
                break;
            }
        }
        
        if (!isAuthorized && !hasRole(DATA_MANAGER_ROLE, msg.sender)) revert Unauthorized();
        
        bytes32 dataHash = keccak256(abi.encodePacked(
            projectId, metricId, value, block.timestamp, msg.sender, rawDataURI
        ));
        
        ESGDataPoint memory dataPoint = ESGDataPoint({
            timestamp: block.timestamp,
            value: value,
            unit: metric.unit,
            dataHash: dataHash,
            rawDataURI: rawDataURI,
            provider: msg.sender,
            verified: false,
            verifiers: new address[](0),
            metadata: metadata
        });
        
        projectESGData[projectId][metricId].push(dataPoint);
        
        // Update data provider statistics
        if (dataProviders[msg.sender].active) {
            dataProviders[msg.sender].lastUpdate = block.timestamp;
            dataProviders[msg.sender].verifiedDataCount++;
        }
        
        // Update project data in TerraStake Projects contract
        terraStakeProjects.updateProjectESGData(projectId, metric.name, metric.unit, value);
        
        emit ESGDataUpdated(projectId, metricId, value);
    }

    /**
     * @notice Verifies an ESG data point
     * @param projectId The ID of the project
     * @param metricId The ID of the ESG metric
     * @param dataIndex The index of the data point in the array
     */
    function verifyESGData(
        uint256 projectId,
        bytes32 metricId,
        uint256 dataIndex
    ) external onlyRole(VERIFIER_ROLE) {
        if (dataIndex >= projectESGData[projectId][metricId].length) revert InvalidParameters();
        
        ESGDataPoint storage dataPoint = projectESGData[projectId][metricId][dataIndex];
        
        // Check if already verified by this verifier
        for (uint i = 0; i < dataPoint.verifiers.length; i++) {
            if (dataPoint.verifiers[i] == msg.sender) revert InvalidParameters();
        }
        
        // Add verifier
        dataPoint.verifiers.push(msg.sender);
        
        // Mark as verified if minimum verifications are reached
        if (dataPoint.verifiers.length >= esgMetrics[metricId].minimumVerifications) {
            dataPoint.verified = true;
        }
        
        emit DataVerified(projectId, metricId, msg.sender);
    }

    /**
     * @notice Registers a new data provider
     * @param provider Address of the provider
     * @param name Name of the provider
     * @param organization Organization the provider belongs to
     * @param certifications Array of certifications
     * @param sourceType Type of data source
     * @param specializations Array of project categories the provider specializes in
     */
    function registerDataProvider(
        address provider,
        string memory name,
        string memory organization,
        string[] memory certifications,
        SourceType sourceType,
        ProjectCategory[] memory specializations
    ) external onlyRole(DEVICE_MANAGER_ROLE) {
        if (provider == address(0)) revert InvalidAddress();
        if (bytes(name).length == 0 || bytes(organization).length == 0) revert InvalidParameters();
        
        dataProviders[provider] = DataProvider({
            name: name,
            organization: organization,
            certifications: certifications,
            sourceType: sourceType,
            active: true,
            reliabilityScore: 80, // Initial score
            lastUpdate: block.timestamp,
            specializations: specializations,
            verifiedDataCount: 0
        });
        
        emit DataProviderRegistered(provider, name, organization);
    }

    /**
     * @notice Updates data for a Carbon Credit project
     * @param projectId The ID of the carbon credit project
     * @param data The new carbon credit data
     */
    function updateCarbonCreditData(uint256 projectId, CarbonCreditData calldata data) 
        external onlyRole(CATEGORY_MANAGER_ROLE) 
    {
        // Verify project category
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.CarbonCredit)) 
            revert CategoryNotSupported();
        
        carbonCreditProjects[projectId] = data;
        emit CategoryDataUpdated(projectId, ProjectCategory.CarbonCredit);
    }

    /**
     * @notice Updates data for a Renewable Energy project
     * @param projectId The ID of the renewable energy project
     * @param data The new renewable energy data
     */
    function updateRenewableEnergyData(uint256 projectId, RenewableEnergyData calldata data) 
        external onlyRole(CATEGORY_MANAGER_ROLE) 
    {
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.RenewableEnergy)) 
            revert CategoryNotSupported();
        
        renewableEnergyProjects[projectId] = data;
        emit CategoryDataUpdated(projectId, ProjectCategory.RenewableEnergy);
    }

    /**
     * @notice Updates data for an Ocean Cleanup project
     * @param projectId The ID of the ocean cleanup project
     * @param data The new ocean cleanup data
     */
    function updateOceanCleanupData(uint256 projectId, OceanCleanupData calldata data) 
        external onlyRole(CATEGORY_MANAGER_ROLE) 
    {
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.OceanCleanup)) 
            revert CategoryNotSupported();
        
        oceanCleanupProjects[projectId] = data;
        emit CategoryDataUpdated(projectId, ProjectCategory.OceanCleanup);
    }

    /**
     * @notice Updates data for a Reforestation project
     * @param projectId The ID of the reforestation project
     * @param data The new reforestation data
     */
    function updateReforestationData(uint256 projectId, ReforestationData calldata data) 
        external onlyRole(CATEGORY_MANAGER_ROLE) 
    {
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.Reforestation)) 
            revert CategoryNotSupported();
        
        reforestationProjects[projectId] = data;
        emit CategoryDataUpdated(projectId, ProjectCategory.Reforestation);
    }

    /**
     * @notice Updates data for a Biodiversity project
     * @param projectId The ID of the biodiversity project
     * @param data The new biodiversity data
     */
    function updateBiodiversityData(uint256 projectId, BiodiversityData calldata data) 
        external onlyRole(CATEGORY_MANAGER_ROLE) 
    {
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.Biodiversity)) 
            revert CategoryNotSupported();
        
        biodiversityProjects[projectId] = data;
        emit CategoryDataUpdated(projectId, ProjectCategory.Biodiversity);
    }

    /**
     * @notice Updates data for a Sustainable Agriculture project
     * @param projectId The ID of the sustainable agriculture project
     * @param data The new sustainable agriculture data
     */
    function updateSustainableAgData(uint256 projectId, SustainableAgData calldata data) 
        external onlyRole(CATEGORY_MANAGER_ROLE) 
    {
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.SustainableAg)) 
            revert CategoryNotSupported();
        
        sustainableAgProjects[projectId] = data;
        emit CategoryDataUpdated(projectId, ProjectCategory.SustainableAg);
    }

    /**
     * @notice Updates data for a Waste Management project
     * @param projectId The ID of the waste management project
     * @param data The new waste management data
     */
    function updateWasteManagementData(uint256 projectId, WasteManagementData calldata data) 
        external onlyRole(CATEGORY_MANAGER_ROLE) 
    {
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.WasteManagement)) 
            revert CategoryNotSupported();
        
        wasteManagementProjects[projectId] = data;
        emit CategoryDataUpdated(projectId, ProjectCategory.WasteManagement);
    }

    /**
     * @notice Updates data for a Water Conservation project
     * @param projectId The ID of the water conservation project
     * @param data The new water conservation data
     */
    function updateWaterConservationData(uint256 projectId, WaterConservationData calldata data) 
        external onlyRole(CATEGORY_MANAGER_ROLE) 
    {
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.WaterConservation)) 
            revert CategoryNotSupported();
        
        waterConservationProjects[projectId] = data;
        emit CategoryDataUpdated(projectId, ProjectCategory.WaterConservation);
    }

    /**
     * @notice Updates data for a Pollution Control project
     * @param projectId The ID of the pollution control project
     * @param data The new pollution control data
     */
    function updatePollutionControlData(uint256 projectId, PollutionControlData calldata data) 
        external onlyRole(CATEGORY_MANAGER_ROLE) 
    {
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.PollutionControl)) 
            revert CategoryNotSupported();
        
        pollutionControlProjects[projectId] = data;
        emit CategoryDataUpdated(projectId, ProjectCategory.PollutionControl);
    }

    /**
     * @notice Updates data for a Habitat Restoration project
     * @param projectId The ID of the habitat restoration project
     * @param data The new habitat restoration data
     */
    function updateHabitatRestorationData(uint256 projectId, HabitatRestorationData calldata data) 
        external onlyRole(CATEGORY_MANAGER_ROLE) 
    {
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.HabitatRestoration)) 
            revert CategoryNotSupported();
        
        habitatRestorationProjects[projectId] = data;
        emit CategoryDataUpdated(projectId, ProjectCategory.HabitatRestoration);
    }

    /**
     * @notice Updates data for a Green Building project
     * @param projectId The ID of the green building project
     * @param data The new green building data
     */
    function updateGreenBuildingData(uint256 projectId, GreenBuildingData calldata data) 
        external onlyRole(CATEGORY_MANAGER_ROLE) 
    {
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.GreenBuilding)) 
            revert CategoryNotSupported();
        
        greenBuildingProjects[projectId] = data;
        emit CategoryDataUpdated(projectId, ProjectCategory.GreenBuilding);
    }

    /**
     * @notice Updates data for a Circular Economy project
     * @param projectId The ID of the circular economy project
     * @param data The new circular economy data
     */
    function updateCircularEconomyData(uint256 projectId, CircularEconomyData calldata data) 
        external onlyRole(CATEGORY_MANAGER_ROLE) 
    {
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.CircularEconomy)) 
            revert CategoryNotSupported();
        
        circularEconomyProjects[projectId] = data;
        emit CategoryDataUpdated(projectId, ProjectCategory.CircularEconomy);
    }

    /**
     * @notice Gets the latest price from a specific oracle
     * @param oracle The address of the Chainlink oracle
     * @return price The latest price
     * @return timestamp The timestamp of the latest price
     */
    function getLatestPrice(address oracle) external view returns (int256 price, uint256 timestamp) {
        if (!activeFeeds[oracle]) revert FeedNotActive();
        
        OracleData memory data = oracleRecords[oracle];
        if (data.timestamp == 0) revert NoValidDataAvailable();
        if (block.timestamp - data.timestamp > ORACLE_TIMEOUT) revert StaleOracleData();
        
        return (data.price, data.timestamp);
    }

    /**
     * @notice Gets the latest ESG data for a specific project and metric
     * @param projectId The ID of the project
     * @param metricId The ID of the ESG metric
     * @return timestamp The timestamp of the latest data
     * @return value The latest value
     * @return verified Whether the data is verified
     */
    function getLatestESGData(uint256 projectId, bytes32 metricId) 
        external view 
        returns (uint256 timestamp, int256 value, bool verified) 
    {
        if (projectESGData[projectId][metricId].length == 0) revert NoValidDataAvailable();
        
        ESGDataPoint memory latestData = projectESGData[projectId][metricId][
            projectESGData[projectId][metricId].length - 1
        ];
        
        if (block.timestamp - latestData.timestamp > DATA_VALIDITY_PERIOD) revert DataStale();
        
        return (latestData.timestamp, latestData.value, latestData.verified);
    }

    /**
     * @notice Gets project data based on category
     * @param projectId The ID of the project
     * @return category The project category
     * @return data The project data (encoded)
     */
    function getProjectCategoryData(uint256 projectId) 
        external view 
        returns (ProjectCategory category, bytes memory data) 
    {
        uint8 categoryId = terraStakeProjects.getProjectCategory(projectId);
        if (categoryId > uint8(type(ProjectCategory).max)) revert CategoryNotSupported();
        
        category = ProjectCategory(categoryId);
        
        if (category == ProjectCategory.CarbonCredit) {
            data = abi.encode(carbonCreditProjects[projectId]);
        } else if (category == ProjectCategory.RenewableEnergy) {
            data = abi.encode(renewableEnergyProjects[projectId]);
        } else if (category == ProjectCategory.OceanCleanup) {
            data = abi.encode(oceanCleanupProjects[projectId]);
        } else if (category == ProjectCategory.Reforestation) {
            data = abi.encode(reforestationProjects[projectId]);
        } else if (category == ProjectCategory.Biodiversity) {
            data = abi.encode(biodiversityProjects[projectId]);
        } else if (category == ProjectCategory.SustainableAg) {
            data = abi.encode(sustainableAgProjects[projectId]);
        } else if (category == ProjectCategory.WasteManagement) {
            data = abi.encode(wasteManagementProjects[projectId]);
        } else if (category == ProjectCategory.WaterConservation) {
            data = abi.encode(waterConservationProjects[projectId]);
        } else if (category == ProjectCategory.PollutionControl) {
            data = abi.encode(pollutionControlProjects[projectId]);
        } else if (category == ProjectCategory.HabitatRestoration) {
            data = abi.encode(habitatRestorationProjects[projectId]);
        } else if (category == ProjectCategory.GreenBuilding) {
            data = abi.encode(greenBuildingProjects[projectId]);
        } else if (category == ProjectCategory.CircularEconomy) {
            data = abi.encode(circularEconomyProjects[projectId]);
        }
    }

    /**
     * @notice Resets circuit breaker for a feed
     * @param oracle The address of the oracle feed
     */
    function resetCircuitBreaker(address oracle) external onlyRole(DEVICE_MANAGER_ROLE) {
        if (feedFailures[oracle] < CIRCUIT_BREAKER_THRESHOLD) revert InvalidParameters();
        
        feedFailures[oracle] = 0;
        emit CircuitBreakerReset(oracle);
    }

    /**
     * @notice Updates a system contract address
     * @param contractType The type of contract to update (0=Projects, 1=Token, 2=LiquidityGuard)
     * @param newAddress The new contract address
     */
    function updateSystemContract(uint8 contractType, address newAddress) external onlyRole(GOVERNANCE_ROLE) {
        if (newAddress == address(0)) revert InvalidAddress();
        
        // Governance check
        if (!terraStakeToken.getGovernanceStatus()) revert UnauthorizedAccess();
        
        bytes32 changeId = keccak256(abi.encodePacked(contractType, newAddress, block.timestamp));
        
        // Initialize delay for governance change
        if (pendingOracleChanges[changeId] == 0) {
            pendingOracleChanges[changeId] = block.timestamp + GOVERNANCE_CHANGE_DELAY;
            return;
        }
        
        // Verify delay has passed
        if (block.timestamp < pendingOracleChanges[changeId]) revert GovernanceDelayNotMet();
        
        // Update appropriate contract reference
        if (contractType == 0) {
            terraStakeProjects = ITerraStakeProjects(newAddress);
        } else if (contractType == 1) {
            terraStakeToken = ITerraStakeToken(newAddress);
        } else if (contractType == 2) {
            liquidityGuard = ITerraStakeLiquidityGuard(newAddress);
        } else {
            revert InvalidParameters();
        }
        
        // Clear pending change
        delete pendingOracleChanges[changeId];
    }

    /**
     * @notice Cross-chain data validation
     * @param dataHash The hash of the data
     * @param value The value to validate
     */
    function validateCrossChainData(bytes32 dataHash, int256 value) external onlyRole(VERIFIER_ROLE) {
        crossChainData[dataHash] = value;
        emit CrossChainDataValidated(dataHash, value);
    }

    /**
     * @notice Callback for UUPS upgrades
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        emit ContractUpgraded(newImplementation);
    }

    /**
     * @notice Gets all active price oracles
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
        
        // Create return array with active oracles only
        address[] memory active = new address[](activeCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < priceOracles.length; i++) {
            if (activeFeeds[priceOracles[i]]) {
                active[index] = priceOracles[i];
                index++;
            }
        }
        
        return active;
    }

    /**
     * @notice Utility function to decode Carbon Credit data
     * @param projectId The ID of the project
     * @return data The Carbon Credit data structure
     */
    function getCarbonCreditData(uint256 projectId) external view returns (CarbonCreditData memory data) {
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.CarbonCredit)) 
            revert CategoryNotSupported();
            
        return carbonCreditProjects[projectId];
    }

    /**
     * @notice Utility function to decode Renewable Energy data
     * @param projectId The ID of the project
     * @return data The Renewable Energy data structure
     */
    function getRenewableEnergyData(uint256 projectId) external view returns (RenewableEnergyData memory data) {
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.RenewableEnergy)) 
            revert CategoryNotSupported();
            
        return renewableEnergyProjects[projectId];
    }

    /**
     * @notice Utility function to decode Ocean Cleanup data
     * @param projectId The ID of the project
     * @return data The Ocean Cleanup data structure
     */
    function getOceanCleanupData(uint256 projectId) external view returns (OceanCleanupData memory data) {
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.OceanCleanup)) 
            revert CategoryNotSupported();
            
        return oceanCleanupProjects[projectId];
    }

    /**
     * @notice Utility function to decode Reforestation data
     * @param projectId The ID of the project
     * @return data The Reforestation data structure
     */
    function getReforestationData(uint256 projectId) external view returns (ReforestationData memory data) {
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.Reforestation)) 
            revert CategoryNotSupported();
            
        return reforestationProjects[projectId];
    }

    /**
     * @notice Utility function to decode Biodiversity data
     * @param projectId The ID of the project
     * @return data The Biodiversity data structure
     */
    function getBiodiversityData(uint256 projectId) external view returns (BiodiversityData memory data) {
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.Biodiversity)) 
            revert CategoryNotSupported();
            
        return biodiversityProjects[projectId];
    }

    /**
     * @notice Utility function to decode Sustainable Agriculture data
     * @param projectId The ID of the project
     * @return data The Sustainable Agriculture data structure
     */
    function getSustainableAgData(uint256 projectId) external view returns (SustainableAgData memory data) {
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.SustainableAg)) 
            revert CategoryNotSupported();
            
        return sustainableAgProjects[projectId];
    }

    /**
     * @notice Utility function to decode Waste Management data
     * @param projectId The ID of the project
     * @return data The Waste Management data structure
     */
    function getWasteManagementData(uint256 projectId) external view returns (WasteManagementData memory data) {
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.WasteManagement)) 
            revert CategoryNotSupported();
            
        return wasteManagementProjects[projectId];
    }

    /**
     * @notice Utility function to decode Water Conservation data
     * @param projectId The ID of the project
     * @return data The Water Conservation data structure
     */
    function getWaterConservationData(uint256 projectId) external view returns (WaterConservationData memory data) {
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.WaterConservation)) 
            revert CategoryNotSupported();
            
        return waterConservationProjects[projectId];
    }

    /**
     * @notice Utility function to decode Pollution Control data
     * @param projectId The ID of the project
     * @return data The Pollution Control data structure
     */
    function getPollutionControlData(uint256 projectId) external view returns (PollutionControlData memory data) {
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.PollutionControl)) 
            revert CategoryNotSupported();
            
        return pollutionControlProjects[projectId];
    }

    /**
     * @notice Utility function to decode Habitat Restoration data
     * @param projectId The ID of the project
     * @return data The Habitat Restoration data structure
     */
    function getHabitatRestorationData(uint256 projectId) external view returns (HabitatRestorationData memory data) {
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.HabitatRestoration)) 
            revert CategoryNotSupported();
            
        return habitatRestorationProjects[projectId];
    }

    /**
     * @notice Utility function to decode Green Building data
     * @param projectId The ID of the project
     * @return data The Green Building data structure
     */
    function getGreenBuildingData(uint256 projectId) external view returns (GreenBuildingData memory data) {
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.GreenBuilding)) 
            revert CategoryNotSupported();
            
        return greenBuildingProjects[projectId];
    }

    /**
     * @notice Utility function to decode Circular Economy data
     * @param projectId The ID of the project
     * @return data The Circular Economy data structure
     */
    function getCircularEconomyData(uint256 projectId) external view returns (CircularEconomyData memory data) {
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.CircularEconomy)) 
            revert CategoryNotSupported();
            
        return circularEconomyProjects[projectId];
    }

    /**
     * @notice Gets ESG metrics applicable to a specific project category
     * @param category The project category
     * @return metricIds Array of applicable metric IDs
     */
    function getCategoryMetrics(ProjectCategory category) external view returns (bytes32[] memory) {
        bytes32[] memory applicableMetrics = new bytes32[](50); // Maximum expected size
        uint256 count = 0;
        
        // Collect all metrics that apply to this category
        bytes32[] memory allMetricIds = new bytes32[](50); // Arbitrary limit
        uint256 metricCount = 0;
        
        // This is just a placeholder - in a real implementation, you would have a way to enumerate all metrics
        // For this example, we're assuming that metric IDs are tracked elsewhere and accessible
        
        for (uint256 i = 0; i < metricCount; i++) {
            bytes32 metricId = allMetricIds[i];
            ESGMetricDefinition storage metric = esgMetrics[metricId];
            
            for (uint j = 0; j < metric.applicableCategories.length; j++) {
                if (metric.applicableCategories[j] == category && metric.isActive) {
                    applicableMetrics[count] = metricId;
                    count++;
                    break;
                }
            }
        }
        
        // Create correctly sized return array
        bytes32[] memory result = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = applicableMetrics[i];
        }
        
        return result;
    }

    /**
     * @notice Returns the contract signature (version identifier)
     * @return Signature bytes32 hash
     */
    function getContractSignature() external pure returns (bytes32) {
        return CONTRACT_SIGNATURE;
    }
}
