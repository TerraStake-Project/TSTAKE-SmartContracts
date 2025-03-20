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
        CircularEconomy,
        CommunityDevelopment
    }
    
    /**
     * @notice Represents the possible states of a project
     */
    enum ProjectState {
        Proposed,
        Pending,
        Active,
        Paused,
        Completed,
        Cancelled,
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
        uint48 startBlock;
        uint48 endBlock;
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
        uint256 projectId;
        address reporter;
        uint48 timestamp;
        string title;
        string details;
        bytes32 ipfsHash;
        uint256 metricValue;
        bool validated;
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

    // Custom data structure to store real-world category information
    struct CategoryInfo {
        string name;
        string description;
        string[] standardBodies;
        string[] metricUnits;
        string verificationStandard;
        uint256 impactWeight;
        string[] keyMetrics;
        string esgFocus;
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
    event ImpactReportSubmitted(uint256 indexed projectId, uint256 indexed reportId, address reporter, bytes32 reportHash, uint256 impactMetricValue);
    
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

    event ProjectStakingFinalized(uint256 indexed projectId, bool isCompleted, uint256 timestamp);
    event StakingMultiplierUpdated(uint256 indexed projectId, uint32 oldMultiplier, uint32 newMultiplier);
    event MinimumStakeAmountSet(uint256 amount);
    event FeesWithdrawn(address recipient, uint256 amount);
    
    // Project metadata update event
    event ProjectMetadataUpdated(uint256 indexed projectId, string name, bytes32 ipfsHash);
    
    // Fee management events
    event TokensBurned(uint256 amount);
    
    // Emergency events
    event EmergencyModeActivated(address operator);
    event EmergencyModeDeactivated(address operator);
    
    // Fee updates
    event FeeCollected(uint256 projectId, FeeType feeType, uint256 feeAmount);
    event BuybackExecuted(uint256 amount);
    
    // Project events
    event ImpactReportSubmitted(uint256 indexed projectId, uint256 reportId, bytes32 reportHash, uint256 measuredValue);
    event ImpactReportValidated(uint256 indexed projectId, uint256 reportId, address validator, bool approved);
    event RewardsDistributed(uint256 indexed projectId, uint256 amount);
    event ProjectStaked(uint256 indexed projectId, address indexed staker, uint256 amount);
    event ProjectUnstaked(uint256 indexed projectId, address indexed staker, uint256 amount);
    event RewardsClaimed(uint256 indexed projectId, address indexed staker, uint256 amount);
    event ProjectDocumentAdded(uint256 indexed projectId, uint256 documentId, string name, bytes32 ipfsHash);
    event TokenRecovered(address tokenAddress, address to, uint256 amount);
    event ProjectVerified(uint256 indexed projectId, address verifier, bytes32 verificationDataHash);
    event ImpactRequirementsUpdated(uint256 indexed projectId);
    event CategoryRequirementsUpdated(ProjectCategory indexed category);
    event TreasuryAddressChanged(address oldTreasury, address newTreasury);
    event RewardPoolIncreased(uint256 indexed projectId, uint256 amount, address contributor);
    event CategoryInfoUpdated(ProjectCategory category, string name, uint8 impactWeight);

    // NFT related events
    event ImpactNFTMinted(uint256 indexed projectId, bytes32 indexed reportHash, address recipient);
    event NFTContractSet(address indexed nftContract);

    // Governance events
    event ContractPaused(address admin);
    event ContractUnpaused(address admin);

    // ====================================================
    //  Errors
    // ====================================================
    error InvalidAddress();
    error NameRequired();
    error InvalidProjectId();
    error StateUnchanged();
    error NotAuthorized();
    error FeeTransferFailed();
    error PageDoesNotExist();
    error InvalidCategory();
    error ProjectNotActive();
    error ProjectNotVerified();
    error RECNotFound();
    error RECNotActive();
    error NotRECOwner();
    error CannotRevokeOwnerPermissions();
    error EmergencyModeActive();
    error CallerNotStakingContract();
    error InvalidReportId();
    error ReportAlreadyVerified();
    error ZeroAmount();
    error TokenNotConfigured();
    error TokenTransferFailed();
    error InsufficientStake();
    error NoRewardsAvailable();
    error NoBuybackFunds();
    error ExceedsRecoverableAmount();
    error InvalidPermission();
    error InvalidAmount();
    error StakeTransferFailed();
    error NotStaking();
    error MinStakingPeriodNotMet();
    error UnstakeTransferFailed();
    error NoRewardsToClaim();
    error RewardTransferFailed();
    error ProjectEndingTooSoon();
    error ReportingTooFrequent();
    error InvalidReportStatus();
    error TransferFailed();
    error InvalidPermissionType();
    error EmptyProjectName();
    error EmptyProjectDescription();
    error EmptyProjectLocation();
    error EmptyImpactMetrics();
    error InvalidIpfsHash();
    error InvalidStakingMultiplier();
    error InvalidBlockRange();
    error ProjectInTerminalState();
    error InvalidStateTransition();
    error ReportAlreadyValidated();
    error StakeTooSmall();
    error InsufficientFees();
    error CannotRecoverPrimaryToken();
    error InvalidImpactWeight();
    
    // ====================================================
    //  Core Functions
    // ====================================================
        
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
     * @notice Adds a comment to a project
     * @param projectId ID of the project
     * @param message Comment content
     */
    function addComment(uint256 projectId, string calldata message) external;
    
    /**
     * @notice Submit impact report for a project
     * @param projectId ID of the project
     * @param reportTitle Title of the report
     * @param reportDetails Details of the report
     * @param ipfsReportHash IPFS hash of the full report
     * @param impactMetricValue Value of the impact metric
     */
    function submitImpactReport(
        uint256 projectId,
        string calldata reportTitle,
        string calldata reportDetails,
        bytes32 ipfsReportHash,
        uint256 impactMetricValue
    ) external;
    
    /**
     * @notice Update the fee structure
     * @param projectSubmissionFee Fee for submitting a project
     * @param impactReportingFee Fee for submitting an impact report
     * @param verificationFee Fee for verification
     * @param categoryChangeFee Fee for changing a project's category
     */
    function updateFeeStructure(
        uint256 projectSubmissionFee,
        uint256 impactReportingFee,
        uint256 verificationFee,
        uint256 categoryChangeFee
    ) external;
    
    
    /**
     * @notice Function to check if a project exists
     * @param projectId The ID of the project to check
     * @return bool True if the project exists, false otherwise
     */
    function projectExists(uint256 projectId) external view returns (bool);
    function getProjectCount() external view returns (uint256);
    
    function incrementStakerCount(uint256 projectId) external;
    function decrementStakerCount(uint256 projectId) external;
}
