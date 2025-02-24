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

    /**
     * @notice Basic project data.
     * @param name Project name.
     * @param description Project description.
     * @param location Project location.
     * @param impactMetrics Impact metrics as a string.
     * @param ipfsHash A legacy IPFS hash.
     * @param exists Whether the project exists.
     */
    struct ProjectData {
        string name;
        string description;
        string location;
        string impactMetrics;
        bytes32 ipfsHash;
        bool exists;
    }

    /**
     * @notice Detailed project state data.
     * @param category The project category.
     * @param state The current project state.
     * @param stakingMultiplier The staking multiplier.
     * @param totalStaked Total amount staked.
     * @param rewardPool Reward pool for stakers.
     * @param isActive Whether staking is active.
     * @param startBlock Starting block.
     * @param endBlock Ending block.
     * @param owner Project owner.
     * @param lastReportedValue The last Chainlink reported value.
     * @param lastRewardUpdate Timestamp of last reward distribution.
     * @param accumulatedRewards Total rewards distributed.
     */
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
        int256 lastReportedValue; // Added to store Chainlink feed data
        uint256 lastRewardUpdate;
        uint256 accumulatedRewards;
    }

    /**
     * @notice Impact requirements for a project category.
     * @param minimumImpact The minimum required impact value.
     * @param verificationFrequency Maximum allowed time (in seconds) since the last verification.
     * @param requiredDocuments An array of required document identifiers.
     * @param qualityThreshold The quality threshold.
     * @param minimumScale The minimum required staking amount.
     */
    struct ImpactRequirement {
        uint256 minimumImpact;
        uint256 verificationFrequency;
        string[] requiredDocuments;
        uint256 qualityThreshold;
        uint256 minimumScale;
    }

    /**
     * @notice General metadata for a project.
     * @param startDate Project start date.
     * @param endDate Project end date.
     * @param budgetAllocation Allocated budget.
     * @param riskAssessment Risk assessment summary.
     * @param complianceDocumentation Compliance documents (legacy).
     */
    struct GeneralMetadata {
        uint48 startDate;
        uint48 endDate;
        uint256 budgetAllocation;
        string riskAssessment;
        string complianceDocumentation;
    }

    /**
     * @notice Validation data.
     * @param vvb Validator address.
     * @param validationDate Timestamp of validation.
     * @param validationReportHash Hash of the validation report.
     */
    struct ValidationData {
        address vvb;
        uint256 validationDate;
        bytes32 validationReportHash;
    }

    /**
     * @notice Verification data.
     * @param vvb Verifier address.
     * @param verificationDate Timestamp of verification.
     * @param verificationReportHash Hash of the verification report.
     */
    struct VerificationData {
        address vvb;
        uint256 verificationDate;
        bytes32 verificationReportHash;
    }

    /**
     * @notice A comment on a project.
     * @param commenter Commenter's address.
     * @param message Comment text.
     * @param timestamp Timestamp of comment.
     */
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
    event DocumentAdded(uint256 indexed projectId, bytes cid);
    
    // Added Event for Chainlink Data Feeds
    event ProjectDataUpdated(uint256 indexed projectId, int256 newDataValue);

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

    // Chainlink Data Feeder Integration
    /**
     * @notice Updates a project's last reported value using Chainlink.
     * @param projectId The ID of the project to update.
     * @param dataValue The new data value from Chainlink.
     */
    function updateProjectDataFromChainlink(uint256 projectId, int256 dataValue) external;

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