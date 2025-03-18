// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "../interfaces/ITerraStakeProjects.sol";
import "../interfaces/ITerraStakeToken.sol";
import "../interfaces/ITerraStakeToken.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";

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
    //  Custom Errors
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
    error CircuitBreakerNotTriggered();
    error AlreadyProcessed();
    error NoDataAvailable();

    // -------------------------------------------
    //  Enums & Data Structures
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

    struct CrossChainDataPoint {
        uint256 sourceChainId;
        int256 value;
        uint256 timestamp;
        address validator;
        uint256 validationTime;
        bool validated;
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
    //  Roles for Security
    // -------------------------------------------
    bytes32 public constant DEVICE_MANAGER_ROLE = keccak256("DEVICE_MANAGER_ROLE");
    bytes32 public constant DATA_MANAGER_ROLE = keccak256("DATA_MANAGER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant CATEGORY_MANAGER_ROLE = keccak256("CATEGORY_MANAGER_ROLE");

    // -------------------------------------------
    //  Oracle Feeds & Data Storage
    // -------------------------------------------
    mapping(address => bool) public activeFeeds;
    mapping(address => int256) public lastKnownPrice;
    mapping(address => uint256) public feedFailures;
    mapping(bytes32 => uint256) public pendingOracleChanges;
    address[] public priceOracles;

    // -------------------------------------------
    //  Oracle Price Storage (TWAP)
    // -------------------------------------------
    mapping(address => OracleData) public oracleRecords;

    // -------------------------------------------
    //  Cross-Chain Data Validation
    // -------------------------------------------
    mapping(bytes32 => int256) public crossChainData;

    // -------------------------------------------
    //  Performance Analytics
    // -------------------------------------------
    mapping(address => FeedAnalytics) public feedAnalytics;

    // -------------------------------------------
    //  ESG Metrics & Data
    // -------------------------------------------
    mapping(bytes32 => ESGMetricDefinition) public esgMetrics;
    mapping(uint256 => mapping(bytes32 => ESGDataPoint[])) public projectESGData;
    mapping(address => DataProvider) public dataProviders;

    // -------------------------------------------
    //  Project Category Data Mappings
    // -------------------------------------------
    // Mappings for storing project data by category
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
    //  System Contracts
    // -------------------------------------------
    ITerraStakeProjects public terraStakeProjects;
    ITerraStakeToken public terraStakeToken;
    ITerraStakeLiquidityGuard public liquidityGuard;

    // -------------------------------------------
    //  Events
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
        // Verify project category
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.RenewableEnergy)) 
            revert CategoryNotSupported();
        
        renewableEnergyProjects[projectId] = data;
        emit CategoryDataUpdated(projectId, ProjectCategory.RenewableEnergy);
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
    function updateSustainableAgricultureData(uint256 projectId, SustainableAgData calldata data) 
        external onlyRole(CATEGORY_MANAGER_ROLE) 
    {
        if (terraStakeProjects.getProjectCategory(projectId) != uint8(ProjectCategory.SustainableAgriculture)) 
            revert CategoryNotSupported();
        
        sustainableAgProjects[projectId] = data;
        emit CategoryDataUpdated(projectId, ProjectCategory.SustainableAgriculture);
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
     * @notice Resets the circuit breaker for a feed
     * @param oracle Address of the oracle feed
     */
    function resetCircuitBreaker(address oracle) external onlyRole(GOVERNANCE_ROLE) {
        if (feedFailures[oracle] < CIRCUIT_BREAKER_THRESHOLD) revert CircuitBreakerNotTriggered();
        
        feedFailures[oracle] = 0;
        emit CircuitBreakerReset(oracle);
    }

    /**
     * @notice Updates the reliability score for a data provider
     * @param provider Address of the provider
     * @param newScore New reliability score (0-100)
     */
    function updateProviderReliabilityScore(address provider, uint8 newScore) 
        external onlyRole(GOVERNANCE_ROLE) 
    {
        if (newScore > 100) revert InvalidParameters();
        if (!dataProviders[provider].active) revert InvalidAddress();
        
        dataProviders[provider].reliabilityScore = newScore;
    }

    /**
     * @notice Validates and records cross-chain data
     * @param dataHash Hash of the original data
     * @param sourceChainId ID of the source chain
     * @param value Data value
     * @param timestamp Timestamp of the data
     */
    function validateCrossChainData(
        bytes32 dataHash,
        uint256 sourceChainId,
        int256 value,
        uint256 timestamp
    ) external onlyRole(VERIFIER_ROLE) {
        if (block.timestamp < timestamp) revert InvalidParameters();
        if (crossChainData[dataHash].validated) revert AlreadyProcessed();
        
        crossChainData[dataHash] = CrossChainDataPoint({
            sourceChainId: sourceChainId,
            value: value,
            timestamp: timestamp,
            validator: msg.sender,
            validationTime: block.timestamp,
            validated: true
        });
        
        emit CrossChainDataValidated(dataHash, value);
    }

    /**
     * @notice Get the latest ESG data point for a project and metric
     * @param projectId The project ID
     * @param metricId The metric ID
     * @return dataPoint The latest ESG data point
     */
    function getLatestESGData(uint256 projectId, bytes32 metricId) 
        external view returns (ESGDataPoint memory dataPoint) 
    {
        uint256 dataLength = projectESGData[projectId][metricId].length;
        
        if (dataLength == 0) revert NoDataAvailable();
        
        return projectESGData[projectId][metricId][dataLength - 1];
    }

    /**
     * @notice Get the count of ESG data points for a project and metric
     * @param projectId The project ID
     * @param metricId The metric ID
     * @return count The count of data points
     */
    function getESGDataCount(uint256 projectId, bytes32 metricId) 
        external view returns (uint256 count) 
    {
        return projectESGData[projectId][metricId].length;
    }

    /**
     * @notice Get analytics for a price feed
     * @param oracle The oracle address
     * @return analytics The feed analytics data
     */
    function getFeedAnalytics(address oracle) 
        external view returns (FeedAnalytics memory) 
    {
        return feedAnalytics[oracle];
    }

    /**
     * @notice Get the price history for a feed
     * @param oracle The oracle address
     * @return priceHistory Array of historical prices
     */
    function getPriceHistory(address oracle) 
        external view returns (int256[] memory) 
    {
        return feedAnalytics[oracle].priceHistory;
    }

    /**
     * @notice Get carbon credit data for a project
     * @param projectId The project ID
     * @return data The carbon credit data
     */
    function getCarbonCreditData(uint256 projectId) 
        external view returns (CarbonCreditData memory) 
    {
        return carbonCreditProjects[projectId];
    }

    /**
     * @notice Get renewable energy data for a project
     * @param projectId The project ID
     * @return data The renewable energy data
     */
    function getRenewableEnergyData(uint256 projectId) 
        external view returns (RenewableEnergyData memory) 
    {
        return renewableEnergyProjects[projectId];
    }

    /**
     * @notice Get the list of active price oracles
     * @return oracles Array of active oracle addresses
     */
    function getActiveOracles() external view returns (address[] memory oracles) {
        uint256 activeCount = 0;
        
        // Count active oracles
        for (uint256 i = 0; i < priceOracles.length; i++) {
            if (activeFeeds[priceOracles[i]]) {
                activeCount++;
            }
        }
        
        oracles = new address[](activeCount);
        uint256 index = 0;
        
        // Fill array with active oracles
        for (uint256 i = 0; i < priceOracles.length; i++) {
            if (activeFeeds[priceOracles[i]]) {
                oracles[index] = priceOracles[i];
                index++;
            }
        }
        
        return oracles;
    }

    /**
     * @notice Get ESG metric definition by ID
     * @param metricId The metric ID
     * @return metric The ESG metric definition
     */
    function getESGMetric(bytes32 metricId) 
        external view returns (ESGMetricDefinition memory) 
    {
        return esgMetrics[metricId];
    }

    /**
     * @notice Get data provider information
     * @param provider The provider address
     * @return providerData The data provider information
     */
    function getDataProvider(address provider) 
        external view returns (DataProvider memory) 
    {
        return dataProviders[provider];
    }

    /**
     * @notice Required function for UUPS upgradeability pattern
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {
        emit ContractUpgraded(newImplementation);
    }
}