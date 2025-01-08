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

    struct ValidationData {
        address vvb;
        uint256 validationDate;
        bytes32 validationReportHash;
    }

    struct VerificationData {
        address vvb;
        uint256 verificationDate;
        bytes32 verificationReportHash;
    }

    struct Comment {
        address commenter;
        string message;
        uint256 timestamp;
    }

    // Events
    event Initialized(address admin, address tstakeToken);
    event ProjectAdded(uint256 indexed projectId, string name, ProjectCategory category);
    event ProjectStateChanged(uint256 indexed projectId, ProjectState indexed oldState, ProjectState indexed newState);
    event DocumentationUpdated(uint256 indexed projectId, bytes32[] documentHashes);
    event ValidationSubmitted(uint256 indexed projectId, address indexed vvb, bytes32 reportHash);
    event VerificationSubmitted(uint256 indexed projectId, address indexed vvb, bytes32 reportHash);
    event MetricsReported(uint256 indexed projectId, string metricType, string metricValue);
    event CategoryMultiplierUpdated(ProjectCategory indexed category, uint256 multiplier);
    event ImpactRequirementUpdated(ProjectCategory indexed category, uint256 minimumImpact);
    event ContractsSet(address stakingContract, address rewardsContract);
    event CommentAdded(uint256 indexed projectId, address indexed commenter, string message);
    event FeeStructureUpdated(uint256 registrationFee, uint256 verificationFee, uint256 categoryChangeFee);

    // Initialization
    function initialize(address admin, address _tstakeToken) external;

    // Project Management
    function addProject(
        string memory name,
        string memory description,
        string memory location,
        string memory impactMetrics,
        bytes32 ipfsHash,
        ProjectCategory category,
        uint32 stakingMultiplier,
        uint48 startBlock,
        uint48 endBlock
    ) external;

    function updateProjectState(uint256 projectId, ProjectState newState) external;

    function updateProjectDocumentation(uint256 projectId, bytes32[] calldata documentHashes) external;

    function submitValidation(uint256 projectId, bytes32 reportHash) external;

    function submitVerification(uint256 projectId, bytes32 reportHash) external;

    function reportMetric(uint256 projectId, string calldata metricType, string calldata metricValue) external;

    // Governance Functions
    function setCategoryMultiplier(ProjectCategory category, uint256 multiplier) external;

    function setImpactRequirement(
        ProjectCategory category,
        uint256 minimumImpact,
        uint256 verificationFrequency,
        string[] calldata requiredDocuments,
        uint256 qualityThreshold,
        uint256 minimumScale
    ) external;

    function updateFeeStructure(uint256 registrationFee, uint256 categoryChangeFee, uint256 verificationFee) external;

    function addComment(uint256 projectId, string calldata message) external;

    // View Functions
    function getProjectDetails(uint256 projectId) external view returns (ProjectData memory);

    function getProjectState(uint256 projectId) external view returns (ProjectStateData memory);

    function getCategoryRequirements(ProjectCategory category) external view returns (ImpactRequirement memory);

    function getValidationReport(uint256 projectId) external view returns (ValidationData memory);

    function getVerificationReport(uint256 projectId) external view returns (VerificationData memory);

    function isProjectActive(uint256 projectId) external view returns (bool);

    function getProjectCount() external view returns (uint256);

    function getComments(uint256 projectId) external view returns (
        string[] memory messages, 
        address[] memory commenters, 
        uint256[] memory timestamps
    );

    function getGeneralMetadata(uint256 projectId) external view returns (GeneralMetadata memory);

    function setGeneralMetadata(uint256 projectId, GeneralMetadata calldata data) external;
}
