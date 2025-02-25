// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ITerraStakeProjects {
    // ====================================================
    // 🔹 Project Categories (DO NOT CHANGE ORDER)
    // ====================================================
    enum ProjectCategory {
        CarbonCredit,        // Carbon offset and reduction projects
        RenewableEnergy,     // Solar, wind, hydro, including RECs
        OceanCleanup,        // Marine conservation and plastic removal
        Reforestation,       // Tree planting and forest protection
        Biodiversity,        // Species and ecosystem protection
        SustainableAg,       // Regenerative farming practices
        WasteManagement,     // Recycling and waste reduction
        WaterConservation,   // Water efficiency and protection
        PollutionControl,    // Air and environmental quality
        HabitatRestoration,  // Ecosystem recovery projects
        GreenBuilding,       // Energy-efficient infrastructure & sustainable construction
        CircularEconomy      // Waste-to-energy, recycling loops, regenerative economy
    }

    enum ProjectState {
        Proposed,
        UnderReview,
        Active,
        Suspended,
        Completed,
        Archived
    }

    // ====================================================
    // 🔹 Data Structures
    // ====================================================

    /// @dev Core project data including metadata and identification
    struct ProjectData {
        string name;
        string description;
        string location;
        string impactMetrics;
        bytes32 ipfsHash;
        bool exists;
    }

    /// @dev Stores staking and status details for each project
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

    /// @dev Defines impact tracking requirements for project validation
    struct ImpactRequirement {
        uint256 minimumImpact;
        uint256 verificationFrequency;
        string[] requiredDocuments;
        uint256 qualityThreshold;
        uint256 minimumScale;
    }

    /// @dev General project metadata for governance and compliance
    struct GeneralMetadata {
        uint48 startDate;
        uint48 endDate;
        uint256 budgetAllocation;
        string riskAssessment;
        string complianceDocumentation;
    }

    /// @dev Stores validation reports and timestamps for project approvals
    struct ValidationData {
        address validator;
        uint256 validationDate;
        bytes32 validationReportHash;
    }

    /// @dev Verification reports for projects to ensure compliance and updates
    struct VerificationData {
        address verifier;
        uint256 verificationDate;
        bytes32 verificationReportHash;
    }

    /// @dev Governance comments and discussions on project progress
    struct Comment {
        address commenter;
        string message;
        uint256 timestamp;
    }

    /// @dev Analytics structure for evaluating project success and efficiency
    struct ProjectAnalytics {
        uint256 totalImpact;
        uint256 carbonOffset;
        uint256 stakingEfficiency;
        uint256 communityEngagement;
    }

    /// @dev Detailed impact reports for long-term tracking
    struct ImpactReport {
        uint256 periodStart;
        uint256 periodEnd;
        uint256[] metrics;
        bytes32 reportHash;
    }

    /// @dev Renewable Energy Certificates (REC) tracking
    struct RECData {
        bytes32 recId;
        uint256 vintage;
        uint256 serialNumber;
        uint256 mWhGenerated;
        uint256 startTime;
        uint256 endTime;
        string facilityId;
        string gridRegion;
        uint256 capacity;
        string certifier;
        bytes32 certHash;
        uint256 validUntil;
        uint8 resourceType;
        bool isRetired;
    }

    // ====================================================
    // 🔹 Fee Management (Dynamic & Voted Adjustments)
    // ====================================================
    struct FeeStructure {
        uint256 projectSubmissionFee;
        uint256 impactReportingFee;
        uint256 categoryChangeFee;
        uint256 verificationFee;
    }

    // ====================================================
    // 🔹 Events
    // ====================================================

    /// @dev Contract initialization event
    event Initialized(address admin, address tstakeToken);

    /// @dev Project management events
    event ProjectAdded(uint256 indexed projectId, string name, ProjectCategory category);
    event ProjectStateChanged(uint256 indexed projectId, ProjectState indexed oldState, ProjectState indexed newState);
    event DocumentationUpdated(uint256 indexed projectId, string[] ipfsHashes);
    event CommentAdded(uint256 indexed projectId, address indexed commenter, string message);

    /// @dev Governance-related events
    event ValidationSubmitted(uint256 indexed projectId, address indexed validator, bytes32 reportHash);
    event VerificationSubmitted(uint256 indexed projectId, address indexed verifier, bytes32 reportHash);
    event MetricsReported(uint256 indexed projectId, string metricType, string metricValue);
    event CategoryMultiplierUpdated(ProjectCategory indexed category, uint256 multiplier);
    event ImpactRequirementUpdated(ProjectCategory indexed category, uint256 minimumImpact);
    event FeeStructureUpdated(uint256 projectSubmissionFee, uint256 impactReportingFee, uint256 verificationFee, uint256 categoryChangeFee);
    event ContractsSet(address stakingContract, address rewardsContract);

    /// @dev Analytics & reporting events
    event ProjectDataUpdated(uint256 indexed projectId, int256 newDataValue);
    event AnalyticsUpdated(uint256 indexed projectId, uint256 totalImpact);
    event ImpactReportSubmitted(uint256 indexed projectId, bytes32 reportHash);

    /// @dev REC Management events
    event RECReportSubmitted(uint256 indexed projectId, bytes32 recId);
    event RECVerified(bytes32 indexed recId, bool valid);

    // ====================================================
    // 🔹 Functions
    // ====================================================

    // 🔹 Initialization
    function initialize(address admin, address _tstakeToken) external;

    // 🔹 Project Management
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

    function uploadProjectDocuments(uint256 projectId, string[] calldata ipfsHashes) external;

    function getProjectDocuments(uint256 projectId) external view returns (string[] memory);

    // 🔹 Governance Functions
    function submitValidation(uint256 projectId, bytes32 reportHash) external;

    function submitVerification(uint256 projectId, bytes32 reportHash) external;

    function reportMetric(uint256 projectId, string calldata metricType, string calldata metricValue) external;

    function setCategoryMultiplier(ProjectCategory category, uint256 multiplier) external;

    function setImpactRequirement(
        ProjectCategory category,
        uint256 minimumImpact,
        uint256 verificationFrequency,
        string[] calldata requiredDocuments,
        uint256 qualityThreshold,
        uint256 minimumScale
    ) external;

    function updateFeeStructure(uint256 projectSubmissionFee, uint256 categoryChangeFee, uint256 impactReportingFee, uint256 verificationFee) external;

    function addComment(uint256 projectId, string calldata message) external;

    // 🔹 Project Analytics & Reporting
    function updateProjectAnalytics(
        uint256 projectId,
        uint256 totalImpact,
        uint256 carbonOffset,
        uint256 stakingEfficiency,
        uint256 communityEngagement
    ) external;

    function submitImpactReport(
        uint256 projectId,
        uint256 periodStart,
        uint256 periodEnd,
        uint256[] memory metrics,
        bytes32 reportHash
    ) external;

    function getProjectAnalytics(uint256 projectId) external view returns (ProjectAnalytics memory);

    function getImpactReports(uint256 projectId) external view returns (ImpactReport[] memory);

    // 🔹 Renewable Energy Certificate (REC) Management
    function submitRECReport(uint256 projectId, RECData memory rec) external;

    function getREC(uint256 projectId) external view returns (RECData memory);

    function verifyREC(bytes32 recId) external view returns (bool);
}
