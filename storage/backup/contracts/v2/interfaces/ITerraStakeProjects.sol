// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITerraStakeProjects {
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
        HabitatRestoration
    }

    enum ProjectState {
        Proposed,
        UnderReview,
        Active,
        Suspended,
        Completed,
        Archived
    }

    struct ProjectData {
        string name;
        string description;
        string location;
        string impactMetrics;
        bytes32 ipfsHash;
        bool exists;
    }

    struct ProjectStateData {
        ProjectCategory category;
        ProjectState state;
        uint32 stakingMultiplier;
        uint128 totalStaked;
        uint128 rewardPool;
        bool isActive;
        uint48 startBlock;
        uint48 endBlock;
        address owner;
        int256 lastReportedValue;
        uint256 lastRewardUpdate;
        uint256 accumulatedRewards;
    }

    struct ImpactRequirement {
        uint256 minimumImpact;
        uint256 verificationFrequency;
        string[] requiredDocuments;
        uint256 qualityThreshold;
        uint256 minimumScale;
    }

    struct GeneralMetadata {
        uint48 startDate;
        uint48 endDate;
        uint256 budgetAllocation;
        string riskAssessment;
        string complianceDocumentation;
    }

    // Events
    event ProjectAdded(uint256 indexed projectId, string name, ProjectCategory category);
    event ProjectUpdated(uint256 indexed projectId, string name);
    event ProjectStateChanged(uint256 indexed projectId, ProjectState indexed oldState, ProjectState indexed newState);
    event ProjectDataUpdated(uint256 indexed projectId, string impactMetrics, bytes32 ipfsHash);
    event DocumentationUpdated(uint256 indexed projectId, bytes32[] documentHashes);
    event MetricsReported(uint256 indexed projectId, string metricType, string metricValue);
    event RewardPoolUpdated(uint256 indexed projectId, uint128 amount);
    event StakingMultiplierUpdated(uint256 indexed projectId, uint32 newMultiplier);
    event CategoryMultiplierUpdated(ProjectCategory indexed category, uint256 multiplier);
    event ImpactRequirementUpdated(ProjectCategory indexed category, uint256 minimumImpact);
    event ContractsSet(address stakingContract, address rewardsContract);
    event FeeStructureUpdated(uint256 registrationFee, uint256 verificationFee, uint256 categoryChangeFee); // Added event

    // Core Functions
    function initialize(address admin, address rewardToken) external;

    function addProject(
        string calldata name,
        string calldata description,
        string calldata location,
        string calldata impactMetrics,
        bytes32 ipfsHash,
        ProjectCategory category,
        uint32 stakingMultiplier,
        uint48 startBlock,
        uint48 endBlock
    ) external payable;

    function validateProjectImpact(
        uint256 projectId,
        uint256 impactValue,
        uint256 dataQuality,
        uint256 projectScale
    ) external;

    function updateProject(
        uint256 projectId,
        string calldata name,
        string calldata description,
        string calldata location,
        string calldata impactMetrics,
        bytes32 ipfsHash
    ) external;

    function updateProjectState(uint256 projectId, ProjectState newState) external;

    function setCategoryMultiplier(ProjectCategory category, uint256 multiplier) external;

    function setImpactRequirement(
        ProjectCategory category,
        uint256 minimumImpact,
        uint256 verificationFrequency,
        string[] calldata requiredDocuments,
        uint256 qualityThreshold,
        uint256 minimumScale
    ) external;

    function updateFeeStructure(
        uint256 registrationFee,
        uint256 categoryChangeFee,
        uint256 verificationFee
    ) external;

    function setGeneralMetadata(
        uint256 projectId,
        GeneralMetadata calldata metadata
    ) external;

    function addOracle(uint256 projectId, address oracle) external;

    function reportMetric(
        uint256 projectId,
        string calldata metricType,
        string calldata metricValue
    ) external;

    function updateProjectDocumentation(
        uint256 projectId,
        bytes32[] calldata documentHashes
    ) external;

    // View Functions
    function getProjectDetails(uint256 projectId) external view returns (ProjectData memory);

    function getProjectState(uint256 projectId) external view returns (ProjectStateData memory);

    function getProjectsByCategory(ProjectCategory category) external view returns (uint256[] memory);

    function getCategoryMultiplier(ProjectCategory category) external view returns (uint256);

    function getCategoryRequirements(ProjectCategory category) external view returns (ImpactRequirement memory);

    function getProjectCount() external view returns (uint256);

    function isProjectActive(uint256 projectId) external view returns (bool);

    function getGeneralMetadata(uint256 projectId) external view returns (GeneralMetadata memory);
}
