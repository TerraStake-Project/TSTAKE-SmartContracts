// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

/**
 * @title ITerraStakeProjects
 * @notice Interface for the TerraStakeProjects contract that manages environmental impact projects
 * @dev This interface defines all structures and functions for external interaction with the TerraStakeProjects system
 */
interface ITerraStakeProjects {
    // ====================================================
    //  Enums
    // ====================================================
    
    /**
     * @notice Represents the different categories of environmental projects
     */
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
    
    /**
     * @notice Represents the possible states of a project
     */
    enum ProjectState {
        Proposed,
        UnderReview,
        Active,
        Suspended,
        Completed,
        Archived,
        Rejected
    }
    // Report statuses
    enum ReportStatus {
        Submitted,
        Validated,
        Rejected,
        Pending
    }

    enum FeeType {
        ProjectSubmission,
        ImpactReporting,
        Verification,
        CategoryChange
    }

    enum StakingActionType {
        Stake,
        Unstake
    }

    // ====================================================
    //  Structs
    // ====================================================
    
    /**
     * @notice Core project metadata
     */
    struct ProjectMetaData {
        string name;
        string description;
        string location;
        string impactMetrics;
        bytes32 ipfsHash;
        bool exists;
        uint48 creationTime;
    }
    
    /**
     * @notice Project state and operational data
     */
    struct ProjectStateData {
        ProjectCategory category;
        ProjectState state;
        uint32 stakingMultiplier;
        uint256 totalStaked;
        uint256 rewardPool;
        bool isActive;
        uint48 startBlock;
        uint48 endBlock;
        address owner;
        int256 lastReportedValue;
        uint256 lastRewardUpdate;
        uint256 accumulatedRewards;
    }

    struct ProjectTargets {
        uint256 impactTarget;
        uint256 stakingTarget;
    }
    
    /**
     * @notice Additional project metadata fields
     */
    struct GeneralMetadata {
        string website;
        string[] team;
        string[] partners;
        string[] socialMedia;
        uint256 lastUpdated;
    }
    
    /**
     * @notice Comment structure for project discussions
     */
    struct Comment {
        address commenter;
        string message;
        uint256 timestamp;
    }
    
    /**
     * @notice Project validation data
     */
    struct ValidationData {
        address validator;
        uint48 validationTime;
        string validationNotes;
        bool isValid;
    }
    
    /**
     * @notice Project verification data
     */
    struct VerificationData {
        address verifier;
        uint256 verificationDate;
        bytes32 verificationDocumentHash;
        bool isVerified;
        string verifierNotes;
    }
    
    /**
     * @notice Project impact analytics
     */
    struct ProjectAnalytics {
        uint256 totalImpact;
        uint256 carbonOffset;
        uint256 stakingEfficiency;
        uint256 communityEngagement;
    }

    /**
     * @notice Impact report structure
     */
    struct ImpactReport {
        uint256 timestamp;
        address reporter;
        bytes32 reportDataHash;
        string reportURI;
        string description;
        uint256 measuredValue;
        string measurement;
        ReportStatus status;
        address validator;
        string validatorNotes;
        uint256 validationTime;
    }
    
    /**
     * @notice Requirements for project impact
     */
    struct ImpactRequirement {
        uint256 minimumImpact;
        uint256 verificationFrequency;
        string[] requiredDocuments;
        uint256 qualityThreshold;
        uint256 minimumScale;
    }
    
    /**
     * @notice Renewable Energy Certificate data
     */
    struct RECData {
        bytes32 recId;
        uint256 generationStart;
        uint256 generationEnd;
        uint256 energyAmount;
        string facility;
        string energySource;
        address owner;
        bool isVerified;
        bool isRetired;
        uint256 verificationDate;
        address verifier;
        uint256 retirementDate;
        address retirer;
        string retirementPurpose;
        string externalRegistryId;
    }
    
    /**
     * @notice Fee structure for various operations
     */
    struct FeeStructure {
        uint256 projectSubmissionFee;
        uint256 impactReportingFee;
        uint256 categoryChangeFee;
        uint256 verificationFee;
    }

    // Project document handling
    struct ProjectDocument {
        string name;
        string docType;
        bytes32 ipfsHash;
        uint256 timestamp;
        address uploader;
    }

    // Impact report structures
    struct ImpactRequirements {
        uint32 minStakingPeriod;
        uint32 reportingFrequency;
        uint32 verificationThreshold;
        uint32 impactDataFormat;
        bool requiresAudit;
    }

    struct ProjectVerification {
        uint256 verificationDate;
        address verifier;
        bytes32 verificationDataHash;
        bool isVerified;
        string verifierNotes;
        uint256 lastVerificationTime;
    }

    struct UserStake {
        uint256 amount;
        uint256 adjustedAmount;
        uint256 stakedAt;
        uint256 lastRewardUpdate;
        uint256 claimedRewards;
        bool isStaking;
    }

    // Custom data structure to store real-world category information
    struct CategoryInfo {
        string name;
        string description;
        string[] standardBodies;
        string[] metricUnits;
        string verificationStandard;
        uint256 impactWeight;
    }

    struct StakingAction {
        address user;
        uint256 projectId;
        uint256 amount;
        uint48 timestamp;
        StakingActionType actionType;
    }
    
    // ====================================================
    //  Events
    // ====================================================
    
    /**
     * @notice Emitted when the contract is initialized
     */
    event Initialized(address admin, address tstakeToken);
    
    /**
     * @notice Emitted when a new project is created   
     */
    event ProjectCreated(
        uint256 indexed projectId,
        address indexed creator,
        string name,
        ProjectCategory category,
        uint32 stakingMultiplier,
        uint48 startBlock,
        uint48 endBlock
    );
    
    /**
     * @notice Emitted when a project state changes
     */
    event ProjectStateChanged(uint256 indexed projectId, ProjectState oldState, ProjectState newState);
    
    /**
     * @notice Emitted when a project's metadata is updated
     */
    event ProjectMetadataUpdated(uint256 indexed projectId, string name);
    
    /**
     * @notice Emitted when a comment is added to a project
     */
    event CommentAdded(uint256 indexed projectId, address commenter, string message);
    
    /**
     * @notice Emitted when project documentation is updated
     */
    event DocumentationUpdated(uint256 indexed projectId, string[] ipfsHashes);
    
    /**
     * @notice Emitted when a validation is submitted
     */
    event ValidationSubmitted(uint256 indexed projectId, address validator, bytes32 reportHash);
    
    /**
     * @notice Emitted when a verification is submitted
     */
    event VerificationSubmitted(uint256 indexed projectId, address verifier, bytes32 reportHash);
    
    /**
     * @notice Emitted when metrics are reported for a project
     */
    event MetricsReported(uint256 indexed projectId, string metricType, string metricValue);
    
    /**
     * @notice Emitted when the category multiplier is updated
     */
    event CategoryMultiplierUpdated(ProjectCategory indexed category, uint256 multiplier);
    
    /**
     * @notice Emitted when impact requirements are updated
     */
    event ImpactRequirementUpdated(ProjectCategory indexed category, uint256 minimumImpact);
    
    /**
     * @notice Emitted when the fee structure is updated
     */
    event FeeStructureUpdated(
        uint256 projectSubmissionFee,
        uint256 impactReportingFee,
        uint256 verificationFee,
        uint256 categoryChangeFee
    );
    
    /**
     * @notice Emitted when a project's analytics are updated
     */
    event AnalyticsUpdated(uint256 indexed projectId, uint256 totalImpact);
    
    /**
     * @notice Emitted when an impact report is submitted
     */
    event ImpactReportSubmitted(uint256 indexed projectId, bytes32 reportHash);
    
    /**
     * @notice Emitted when a REC report is submitted
     */
    event RECReportSubmitted(uint256 indexed projectId, bytes32 recId);
    
    /**
     * @notice Emitted when project data is updated (typically from an oracle)
     */
    event ProjectDataUpdated(uint256 indexed projectId, int256 price);
    
    /**
     * @notice Emitted when contracts are set
     */
    event ContractsSet(address stakingContract, address rewardsContract);
    
    /**
     * @notice Emitted when a REC is verified
     */
    event RECVerified(uint256 indexed projectId, bytes32 indexed recId, address verifier);
    
    /**
     * @notice Emitted when a REC is retired
     */
    event RECRetired(uint256 indexed projectId, bytes32 indexed recId, address retirer, string purpose);
    
    /**
     * @notice Emitted when a REC is transferred
     */
    event RECTransferred(uint256 indexed projectId, bytes32 indexed recId, address from, address to);
    
    /**
     * @notice Emitted when a REC is synced with an external registry
     */
    event RECRegistrySync(uint256 indexed projectId, bytes32 indexed recId, string externalRegistryId);
    
    /**
     * @notice Emitted when a project permission is updated
     */
    event ProjectPermissionUpdated(
        uint256 indexed projectId, 
        address indexed user, 
        bytes32 permission, 
        bool granted
    );

    event ProjectTargetsSet(
        uint256 indexed projectId,
        uint256 indexed impactTarget, 
        uint256 indexed stakingTarget
    );

    event ProjectUpdated(
        uint256 indexed projectId,
        address indexed updater,
        string name,
        uint48 startBlock,
        uint48 endBlock
    );

    event ProjectCategoryChanged(
        uint256 indexed projectId,
        ProjectCategory oldCategory,
        ProjectCategory newCategory
    );

    event ProjectStakingFinalized(uint256 indexed projectId);
    event StakingMultiplierUpdated(uint256 indexed projectId, uint32 oldMultiplier, uint32 newMultiplier);
    
    // ====================================================
    //  Core Functions
    // ====================================================
    
    /**
     * @notice Initializes the contract
     * @param admin Address of the contract admin
     * @param _tstakeToken Address of the TStake token
     */
    function initialize(address admin, address _tstakeToken) external;
    
    /**
     * @notice Adds a new project
     * @param name Project name
     * @param description Project description
     * @param location Project location
     * @param impactMetrics Description of impact metrics
     * @param ipfsHash IPFS hash of additional project data
     * @param category Project category
     * @param stakingMultiplier Multiplier for staking rewards
     * @param startBlock Block number when the project starts
     * @param endBlock Block number when the project ends
     */
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
    
    /**
     * @notice Updates a project's state
     * @param projectId ID of the project
     * @param newState New state of the project
     */
    function updateProjectState(uint256 projectId, ProjectState newState) external;
    
    /**
     * @notice Uploads project documents
     * @param projectId ID of the project
     * @param ipfsHashes Array of IPFS hashes pointing to documents
     */
    function uploadProjectDocuments(uint256 projectId, string[] calldata ipfsHashes) external;
    
    /**
     * @notice Get project documents for a specific page
     * @param projectId ID of the project
     * @param page Page number
     * @return Array of document IPFS hashes
     */
    function getProjectDocuments(uint256 projectId, uint256 page) external view returns (string[] memory);
    
    /**
     * @notice Adds a comment to a project
     * @param projectId ID of the project
     * @param message Comment content
     */
    function addComment(uint256 projectId, string calldata message) external;
    
    /**
     * @notice Submit impact report for a project
     * @param projectId ID of the project
     * @param periodStart Start timestamp of the reporting period
     * @param periodEnd End timestamp of the reporting period
     * @param metrics Array of impact metrics
     * @param reportHash Hash of the full report
     */
    function submitImpactReport(
        uint256 projectId,
        uint256 periodStart,
        uint256 periodEnd,
        uint256[] memory metrics,
        bytes32 reportHash
    ) external;
    
    /**
     * @notice Submit validation for a project
     * @param projectId ID of the project
     * @param reportHash Hash of the validation report
     */
    function submitValidation(uint256 projectId, bytes32 reportHash) external;
    
    /**
     * @notice Submit verification for a project
     * @param projectId ID of the project
     * @param reportHash Hash of the verification report
     */
    function submitVerification(uint256 projectId, bytes32 reportHash) external;
    
    /**
     * @notice Report a metric for a project
     * @param projectId ID of the project
     * @param metricType Type of metric being reported
     * @param metricValue Value of the metric
     */
    function reportMetric(uint256 projectId, string calldata metricType, string calldata metricValue) external;
    
    /**
     * @notice Set multiplier for a project category
     * @param category Project category
     * @param multiplier New multiplier value
     */
    function setCategoryMultiplier(ProjectCategory category, uint256 multiplier) external;
    
    /**
     * @notice Set impact requirements for a project category
     * @param category Project category
     * @param minimumImpact Minimum impact requirement
     * @param verificationFrequency How often verification is required
     * @param requiredDocuments List of required document types
     * @param qualityThreshold Minimum quality threshold
     * @param minimumScale Minimum scale requirement
     */
    function setImpactRequirement(
        ProjectCategory category,
        uint256 minimumImpact,
        uint256 verificationFrequency,
        string[] calldata requiredDocuments,
        uint256 qualityThreshold,
        uint256 minimumScale
    ) external;
    
    /**
     * @notice Update the fee structure
     * @param projectSubmissionFee Fee for submitting a project
     * @param categoryChangeFee Fee for changing a project's category
     * @param impactReportingFee Fee for submitting an impact report
     * @param verificationFee Fee for verification
     */
    function updateFeeStructure(
        uint256 projectSubmissionFee,
        uint256 categoryChangeFee,
        uint256 impactReportingFee,
        uint256 verificationFee
    ) external;
    
    /**
     * @notice Update project analytics
     * @param projectId ID of the project
     * @param totalImpact Total impact measurement
     * @param carbonOffset Carbon offset measurement
     * @param stakingEfficiency Staking efficiency metric
     * @param communityEngagement Community engagement metric
     */
    function updateProjectAnalytics(
        uint256 projectId,
        uint256 totalImpact,
        uint256 carbonOffset,
        uint256 stakingEfficiency,
        uint256 communityEngagement
    ) external;
    
    /**
     * @notice Get analytics for a project
     * @param projectId ID of the project
     * @return Project analytics struct
     */
    function getProjectAnalytics(uint256 projectId) external view returns (ProjectAnalytics memory);
    
    /**
     * @notice Get impact reports for a project
     * @param projectId ID of the project
     * @return Array of impact reports
     */
    function getImpactReports(uint256 projectId) external view returns (ImpactReport[] memory);
    
    /**
     * @notice Submit a REC report for a renewable energy project
     * @param projectId ID of the project
     * @param rec REC data structure containing all certificate information
     */
    function submitRECReport(uint256 projectId, RECData memory rec) external;
    
    /**
     * @notice Get the most recent REC for a project
     * @param projectId ID of the project
     * @return REC data structure
     */
    function getREC(uint256 projectId) external view returns (RECData memory);
    
    /**
     * @notice Verify if a REC is valid
     * @param recId ID of the REC to verify
     * @return True if the REC is valid and not retired
     */
    function verifyREC(bytes32 recId) external view returns (bool);
    
    /**
     * @notice Verify a REC on-chain
     * @param projectId ID of the project
     * @param recId ID of the REC to verify
     */
    function verifyRECOnchain(uint256 projectId, bytes32 recId) external;
    
    /**
     * @notice Retire a REC, marking it as used for a specific purpose
     * @param projectId ID of the project
     * @param recId ID of the REC to retire
     * @param purpose Description of the retirement purpose
     */
    function retireREC(uint256 projectId, bytes32 recId, string calldata purpose) external;
    
    /**
     * @notice Transfer ownership of a REC to another address
     * @param projectId ID of the project
     * @param recId ID of the REC to transfer
     * @param to Address of the new owner
     */
    function transferREC(uint256 projectId, bytes32 recId, address to) external;
    
    /**
     * @notice Sync REC with an external registry
     * @param projectId ID of the project
     * @param recId ID of the REC
     * @param externalId ID in the external registry
     */
    function syncRECWithExternalRegistry(uint256 projectId, bytes32 recId, string calldata externalId) external;
    
    /**
     * @notice Get all RECs for a project
     * @param projectId ID of the project
     * @return Array of REC data structures
     */
    function getAllRECs(uint256 projectId) external view returns (RECData[] memory);
    
    /**
     * @notice Set project permission for a user
     * @param projectId ID of the project
     * @param user Address of the user
     * @param permission Permission identifier
     * @param granted True to grant permission, false to revoke
     */
    function setProjectPermission(
        uint256 projectId, 
        address user, 
        bytes32 permission, 
        bool granted
    ) external;
    
    /**
     * @notice Check if a user has a specific project permission
     * @param projectId ID of the project
     * @param user Address of the user
     * @param permission Permission identifier
     * @return True if the user has the permission
     */
    function hasProjectPermission(uint256 projectId, address user, bytes32 permission) 
        external 
        view 
        returns (bool);
    
    /**
     * @notice Check multiple permissions for a user on a project
     * @param projectId ID of the project
     * @param user Address of the user
     * @param permissions Array of permission identifiers
     * @return Array of booleans indicating which permissions the user has
     */
    function checkProjectPermissions(uint256 projectId, address user, bytes32[] calldata permissions)
        external
        view
        returns (bool[] memory);
    
    /**
     * @notice Update project metadata
     * @param projectId ID of the project
     * @param name Project name
     * @param description Project description
     * @param location Project location
     * @param impactMetrics Description of impact metrics
     */
    function updateProjectMetadata(
        uint256 projectId,
        string memory name,
        string memory description,
        string memory location,
        string memory impactMetrics
    ) external;
    
    /**
     * @notice Set contract addresses for the ecosystem
     * @param _stakingContract Address of the staking contract
     * @param _rewardsContract Address of the rewards contract
     */
    function setContracts(address _stakingContract, address _rewardsContract) external;
    
    /**
     * @notice Set treasury address
     * @param _treasury Address of the treasury
     */
    function setTreasury(address _treasury) external;
    
    /**
     * @notice Set liquidity pool address
     * @param _liquidityPool Address of the liquidity pool
     */
    function setLiquidityPool(address _liquidityPool) external;
    
    /**
     * @notice Get requirements for a project category
     * @param category Project category
     * @return Impact requirement structure
     */
    function getCategoryRequirements(ProjectCategory category)
        external
        view
        returns (ImpactRequirement memory);
    
    /**
     * @notice Function to check if a project exists
     * @param projectId The ID of the project to check
     * @return bool True if the project exists, false otherwise
     */
    function projectExists(uint256 projectId) external view returns (bool);

    /**
     * @notice Calculate impact for a project based on its category
     * @param projectId ID of the project
     * @param baseImpact Base impact value
     * @return Weighted impact value
     */
    function calculateCategoryImpact(uint256 projectId, uint256 baseImpact)
        external
        view
        returns (uint256);
    
    /**
     * @notice Batch get details for multiple projects
     * @param projectIds Array of project IDs
     * @return metadata Array of project metadata
     * @return state Array of project state data
     * @return analytics Array of project analytics
     */
    function batchGetProjectDetails(uint256[] calldata projectIds) 
        external 
        view 
        returns (
            ProjectMetaData[] memory metadata,
            ProjectStateData[] memory state,
            ProjectAnalytics[] memory analytics
        );
    
    /**
     * @notice Batch set permissions for multiple users on a project
     * @param projectId ID of the project
     * @param users Array of user addresses
     * @param permissions Array of permission identifiers
     * @param values Array of boolean values (grant/revoke)
     */
    function batchSetProjectPermissions(
        uint256 projectId,
        address[] calldata users,
        bytes32[] calldata permissions,
        bool[] calldata values
    ) external;
    
    function incrementStakerCount(uint256 projectId) external;
    function decrementStakerCount(uint256 projectId) external;
}
