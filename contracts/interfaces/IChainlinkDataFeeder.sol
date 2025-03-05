// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

/**
 * @title IChainlinkDataFeeder
 * @notice Interface for the ChainlinkDataFeeder Oracle contract
 * @dev Comprehensive interface supporting all 12 sustainability project categories
 */
interface IChainlinkDataFeeder {
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

    // -------------------------------------------
    // 🔹 Core Oracle Functions
    // -------------------------------------------
    function addPriceOracle(address oracle) external;
    function deactivatePriceOracle(address oracle) external;
    function updateProjectPrice(uint256 projectId, address oracle) external;
    function getLatestPrice(address oracle) external view returns (int256 price, uint256 timestamp);
    function getActiveOracles() external view returns (address[] memory);
    function resetCircuitBreaker(address oracle) external;

    // -------------------------------------------
    // 🔹 ESG Metrics & Data Management
    // -------------------------------------------
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
    ) external returns (bytes32);

    function updateESGData(
        uint256 projectId,
        bytes32 metricId,
        int256 value,
        string memory rawDataURI,
        string memory metadata
    ) external;

    function verifyESGData(
        uint256 projectId,
        bytes32 metricId,
        uint256 dataIndex
    ) external;

    function getLatestESGData(uint256 projectId, bytes32 metricId) 
        external view 
        returns (uint256 timestamp, int256 value, bool verified);

    function getCategoryMetrics(ProjectCategory category) external view returns (bytes32[] memory);

    // -------------------------------------------
    // 🔹 Data Provider Management
    // -------------------------------------------
    function registerDataProvider(
        address provider,
        string memory name,
        string memory organization,
        string[] memory certifications,
        SourceType sourceType,
        ProjectCategory[] memory specializations
    ) external;

    // -------------------------------------------
    // 🔹 Project Category Data Update Functions
    // -------------------------------------------
    function updateCarbonCreditData(uint256 projectId, CarbonCreditData calldata data) external;
    function updateRenewableEnergyData(uint256 projectId, RenewableEnergyData calldata data) external;
    function updateOceanCleanupData(uint256 projectId, OceanCleanupData calldata data) external;
    function updateReforestationData(uint256 projectId, ReforestationData calldata data) external;
    function updateBiodiversityData(uint256 projectId, BiodiversityData calldata data) external;
    function updateSustainableAgData(uint256 projectId, SustainableAgData calldata data) external;
    function updateWasteManagementData(uint256 projectId, WasteManagementData calldata data) external;
    function updateWaterConservationData(uint256 projectId, WaterConservationData calldata data) external;
    function updatePollutionControlData(uint256 projectId, PollutionControlData calldata data) external;
    function updateHabitatRestorationData(uint256 projectId, HabitatRestorationData calldata data) external;
    function updateGreenBuildingData(uint256 projectId, GreenBuildingData calldata data) external;
    function updateCircularEconomyData(uint256 projectId, CircularEconomyData calldata data) external;

    // -------------------------------------------
    // 🔹 Project Category Data Query Functions
    // -------------------------------------------
    function getCarbonCreditData(uint256 projectId) external view returns (CarbonCreditData memory data);
    function getRenewableEnergyData(uint256 projectId) external view returns (RenewableEnergyData memory data);
    function getOceanCleanupData(uint256 projectId) external view returns (OceanCleanupData memory data);
    function getReforestationData(uint256 projectId) external view returns (ReforestationData memory data);
    function getBiodiversityData(uint256 projectId) external view returns (BiodiversityData memory data);
    function getSustainableAgData(uint256 projectId) external view returns (SustainableAgData memory data);
    function getWasteManagementData(uint256 projectId) external view returns (WasteManagementData memory data);
    function getWaterConservationData(uint256 projectId) external view returns (WaterConservationData memory data);
    function getPollutionControlData(uint256 projectId) external view returns (PollutionControlData memory data);
    function getHabitatRestorationData(uint256 projectId) external view returns (HabitatRestorationData memory data);
    function getGreenBuildingData(uint256 projectId) external view returns (GreenBuildingData memory data);
    function getCircularEconomyData(uint256 projectId) external view returns (CircularEconomyData memory data);
    
    // -------------------------------------------
    // 🔹 Generic Project Data Functions
    // -------------------------------------------
    function getProjectCategoryData(uint256 projectId) 
        external view 
        returns (ProjectCategory category, bytes memory data);

    // -------------------------------------------
    // 🔹 Cross-chain & Governance Functions
    // -------------------------------------------
    function validateCrossChainData(bytes32 dataHash, int256 value) external;
    function updateSystemContract(uint8 contractType, address newAddress) external;
    function getContractSignature() external pure returns (bytes32);
}
