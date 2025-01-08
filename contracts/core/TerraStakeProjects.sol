// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// --------------------------------------------------------------
//                  Interfaces & Structs (Stubs)
// --------------------------------------------------------------

// You may have these in their own files in real usage. 
// For the sake of a single, compilable example, 
// they are included here.

interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface ITerraStakeStaking {
    function updateProjectStakingData(uint256 projectId, uint32 stakingMultiplier) external;
}

interface ITerraStakeRewards {
    function isProjectHasPool(uint256 projectId) external view returns (bool);

    // Add a createProjectPool function here if your real contract uses it
    function createProjectPool(
        uint256 projectId, 
        uint256 initialFunds, 
        uint32 multiplier, 
        uint48 duration
    ) external;

    function fundProjectRewards(uint256 projectId, uint256 amount) external;
}

interface ITerraStakeProjects {
    // ------------------------------------------------------
    // Enums
    // ------------------------------------------------------
    enum ProjectState { Proposed, Active, Completed, Paused }
    enum ProjectCategory { RenewableEnergy, Conservation, CommunityDevelopment, Education }

    // ------------------------------------------------------
    // Structs
    // ------------------------------------------------------
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
        uint256 totalStaked;
        uint256 rewardPool;
        bool isActive;
        uint48 startBlock;
        uint48 endBlock;
        address owner;
        uint256 lastReportedValue;
        uint256 lastRewardUpdate;
        uint256 accumulatedRewards;
    }

    struct ValidationData {
        address validator;
        uint256 validationDate;
        bytes32 validationReportHash;
    }

    struct VerificationData {
        address vvb;
        uint256 verificationDate;
        bytes32 verificationReportHash;
    }

    struct ImpactRequirement {
        uint256 minImpact;
        uint256 maxImpact;
        // add more fields as needed
    }

    struct GeneralMetadata {
        string website;
        string contactEmail;
        // add more fields as needed
    }

    // ------------------------------------------------------
    // Events
    // ------------------------------------------------------
    event ContractsSet(address stakingContract, address rewardsContract);
    event ProjectAdded(uint256 indexed projectId, string name, ProjectCategory category);
    event VerificationSubmitted(uint256 indexed projectId, address validator, bytes32 reportHash);
    event FeeStructureUpdated(uint256 registrationFee, uint256 categoryChangeFee, uint256 verificationFee);
    event ProjectStateChanged(uint256 indexed projectId, ProjectState oldState, ProjectState newState);

    // ------------------------------------------------------
    // Required Functions
    // ------------------------------------------------------
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

    function submitVerification(uint256 projectId, bytes32 reportHash) external;

    function updateFeeStructure(
        uint256 registrationFee, 
        uint256 categoryChangeFee, 
        uint256 verificationFee
    ) external;

    function updateProjectState(uint256 projectId, ProjectState newState) external;

    // Missing in your original contract => required by interface
    function submitValidation(uint256 projectId, bytes32 reportHash) external;
    function updateProjectDocumentation(uint256 projectId, bytes32[] calldata documentHashes) external;
    function reportMetric(uint256 projectId, string calldata metricType, string calldata metricValue) external;
    function setCategoryMultiplier(ProjectCategory category, uint256 multiplier) external;
    function setImpactRequirement(ProjectCategory category, ImpactRequirement calldata requirement) external;
    function addComment(uint256 projectId, string calldata message) external;
    function getProjectCount() external view returns (uint256);
    function getProjectDetails(uint256 projectId) external view returns (ProjectData memory);
    function getProjectState(uint256 projectId) external view returns (ProjectStateData memory);
    function getCategoryRequirements(ProjectCategory category) external view returns (ImpactRequirement memory);
    function getValidationReport(uint256 projectId) external view returns (ValidationData memory);
    function getVerificationReport(uint256 projectId) external view returns (VerificationData memory);
    function isProjectActive(uint256 projectId) external view returns (bool);
    function getComments(uint256 projectId) 
        external 
        view 
        returns (string[] memory messages, address[] memory commenters);
    function getGeneralMetadata(uint256 projectId) external view returns (GeneralMetadata memory);
    function setGeneralMetadata(uint256 projectId, GeneralMetadata calldata data) external;
}

// --------------------------------------------------------------
//                OpenZeppelin Upgradeable Imports
// --------------------------------------------------------------
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// --------------------------------------------------------------
//                 TerraStakeProjects Implementation
// --------------------------------------------------------------
contract TerraStakeProjects is 
    Initializable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable, 
    ITerraStakeProjects 
{
    // ------------------------------------------------------
    // Custom Errors
    // ------------------------------------------------------
    error UnauthorizedAccess();
    error InvalidProjectId();
    error InvalidProjectState();
    error ProjectAlreadyExists();
    error InvalidParameters();
    error InsufficientFunds();
    error ContractNotSet();
    error NotActive();
    error NoVerificationFeePaid();

    // ------------------------------------------------------
    // Roles
    // ------------------------------------------------------
    bytes32 public constant PROJECT_MANAGER_ROLE = keccak256("PROJECT_MANAGER_ROLE");
    bytes32 public constant VALIDATOR_ROLE       = keccak256("VALIDATOR_ROLE");
    bytes32 public constant REWARD_MANAGER_ROLE  = keccak256("REWARD_MANAGER_ROLE");

    // ------------------------------------------------------
    // External Contracts
    // ------------------------------------------------------
    ITerraStakeStaking public stakingContract;
    ITerraStakeRewards public rewardsContract;
    IERC20 public tstakeToken;

    // ------------------------------------------------------
    // Fees
    // ------------------------------------------------------
    uint256 public registrationFee;      // e.g. 200 TSTAKE
    uint256 public categoryChangeFee;    // (introduced for interface compatibility)
    uint256 public verificationFee;      // e.g. 100 TSTAKE

    // ------------------------------------------------------
    // Project Data
    // ------------------------------------------------------
    uint256 public projectCount;
    mapping(uint256 => ProjectData) public projectMetadata;
    mapping(uint256 => ProjectStateData) public projectStateData;
    mapping(uint256 => VerificationData) public verifications;
    mapping(uint256 => ValidationData) public validations;

    // Optionally store per-project documentation, comments, etc.
    mapping(uint256 => bytes32[]) public projectDocuments;
    mapping(uint256 => string[]) private projectComments;
    mapping(uint256 => address[]) private projectCommenters;

    // For category requirements
    mapping(ProjectCategory => ImpactRequirement) private categoryRequirements;

    // For general metadata
    mapping(uint256 => GeneralMetadata) private generalMetadata;

    // ------------------------------------------------------
    // Constructor
    // ------------------------------------------------------
    /// @dev Disable initializer in constructor for upgradeable pattern
    constructor() {
        _disableInitializers();
    }

    // ------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------
    modifier validProjectId(uint256 projectId) {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        _;
    }

    modifier contractsSet() {
        if (
            address(stakingContract) == address(0) || 
            address(rewardsContract) == address(0)
        ) {
            revert ContractNotSet();
        }
        _;
    }

    // ------------------------------------------------------
    // Initialization (Upgradeable)
    // ------------------------------------------------------
    function initialize(
        address admin, 
        address _tstakeToken
    ) external initializer {
        if (admin == address(0) || _tstakeToken == address(0)) revert UnauthorizedAccess();

        __AccessControl_init();
        __ReentrancyGuard_init();

        tstakeToken = IERC20(_tstakeToken);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PROJECT_MANAGER_ROLE, admin);
        _grantRole(VALIDATOR_ROLE, admin);
        _grantRole(REWARD_MANAGER_ROLE, admin);

        // Example fee defaults
        registrationFee = 200 * 10**18;      // 200 TSTAKE
        categoryChangeFee = 50 * 10**18;     // 50 TSTAKE (example)
        verificationFee = 100 * 10**18;      // 100 TSTAKE
    }

    // ------------------------------------------------------
    // Set External Contracts
    // ------------------------------------------------------
    function setContracts(
        address _stakingContract, 
        address _rewardsContract
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_stakingContract == address(0) || _rewardsContract == address(0)) {
            revert ContractNotSet();
        }
        stakingContract = ITerraStakeStaking(_stakingContract);
        rewardsContract = ITerraStakeRewards(_rewardsContract);

        emit ContractsSet(_stakingContract, _rewardsContract);
    }

    // ------------------------------------------------------
    // Add a New Project
    // ------------------------------------------------------
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
    ) external 
      override 
      nonReentrant 
      onlyRole(PROJECT_MANAGER_ROLE) 
      contractsSet 
    {
        // Validate parameters
        if (stakingMultiplier == 0 || startBlock >= endBlock) {
            revert InvalidParameters();
        }

        // Collect registration fee
        bool feeTransferred = tstakeToken.transferFrom(
            msg.sender, 
            address(this), 
            registrationFee
        );
        if (!feeTransferred) {
            revert InsufficientFunds();
        }

        // Assign a new project ID
        uint256 projectId = projectCount++;
        if (projectMetadata[projectId].exists) {
            revert ProjectAlreadyExists();
        }

        // Initialize project metadata
        projectMetadata[projectId] = ProjectData({
            name: name,
            description: description,
            location: location,
            impactMetrics: impactMetrics,
            ipfsHash: ipfsHash,
            exists: true
        });

        // Initialize project state data
        projectStateData[projectId] = ProjectStateData({
            category: category,
            state: ProjectState.Proposed,
            stakingMultiplier: stakingMultiplier,
            totalStaked: 0,
            rewardPool: 0,
            isActive: false,
            startBlock: startBlock,
            endBlock: endBlock,
            owner: msg.sender,
            lastReportedValue: 0,
            lastRewardUpdate: block.timestamp,
            accumulatedRewards: 0
        });

        // Notify staking contract about the new project
        stakingContract.updateProjectStakingData(projectId, stakingMultiplier);

        emit ProjectAdded(projectId, name, category);
    }

    // ------------------------------------------------------
    // Submit Verification Report
    // ------------------------------------------------------
    function submitVerification(uint256 projectId, bytes32 reportHash) 
        external 
        override 
        nonReentrant 
        onlyRole(VALIDATOR_ROLE) 
        validProjectId(projectId) 
        contractsSet 
    {
        // Collect verification fee
        if (!tstakeToken.transferFrom(msg.sender, address(this), verificationFee)) {
            revert NoVerificationFeePaid();
        }

        // Store verification data
        verifications[projectId] = VerificationData({
            vvb: msg.sender,
            verificationDate: block.timestamp,
            verificationReportHash: reportHash
        });

        // If the project does not have a pool in Rewards contract, create a new one
        if (!rewardsContract.isProjectHasPool(projectId)) {
            // Example hard-coded multiplier & duration
            uint32 multiplier = 10000;
            uint48 duration = 20000;

            // Approve & create
            tstakeToken.approve(address(rewardsContract), verificationFee);
            rewardsContract.createProjectPool(projectId, verificationFee, multiplier, duration);

        } else {
            // Otherwise, simply fund existing reward pool
            tstakeToken.approve(address(rewardsContract), verificationFee);
            rewardsContract.fundProjectRewards(projectId, verificationFee);
        }

        emit VerificationSubmitted(projectId, msg.sender, reportHash);
    }

    // ------------------------------------------------------
    // Update Fee Structure (Matches Interface Signature)
    // ------------------------------------------------------
    function updateFeeStructure(
        uint256 _registrationFee, 
        uint256 _categoryChangeFee, 
        uint256 _verificationFee
    ) external override onlyRole(PROJECT_MANAGER_ROLE) {
        registrationFee = _registrationFee;
        categoryChangeFee = _categoryChangeFee;
        verificationFee = _verificationFee;

        emit FeeStructureUpdated(_registrationFee, _categoryChangeFee, _verificationFee);
    }

    // ------------------------------------------------------
    // Update Project State
    // ------------------------------------------------------
    function updateProjectState(
        uint256 projectId, 
        ProjectState newState
    ) 
        external 
        override 
        validProjectId(projectId) 
        onlyRole(PROJECT_MANAGER_ROLE) 
    {
        ProjectState oldState = projectStateData[projectId].state;
        projectStateData[projectId].state = newState;
        projectStateData[projectId].isActive = (newState == ProjectState.Active);

        emit ProjectStateChanged(projectId, oldState, newState);
    }

    // ------------------------------------------------------
    // Below: Stubs to Satisfy ITerraStakeProjects Interface
    // ------------------------------------------------------

    // 1. submitValidation
    function submitValidation(uint256 projectId, bytes32 reportHash) 
        external 
        override 
        validProjectId(projectId) 
        onlyRole(VALIDATOR_ROLE) 
    {
        // Example storing validation data
        validations[projectId] = ValidationData({
            validator: msg.sender,
            validationDate: block.timestamp,
            validationReportHash: reportHash
        });
        // In real usage, do something with the validation...
    }

    // 2. updateProjectDocumentation
    function updateProjectDocumentation(uint256 projectId, bytes32[] calldata documentHashes)
        external
        override
        validProjectId(projectId)
        onlyRole(PROJECT_MANAGER_ROLE)
    {
        // Example: append new documents
        for (uint i = 0; i < documentHashes.length; i++) {
            projectDocuments[projectId].push(documentHashes[i]);
        }
    }

    // 3. reportMetric
    function reportMetric(
        uint256 projectId, 
        string calldata /*metricType*/, 
        string calldata /*metricValue*/
    ) external override validProjectId(projectId) onlyRole(PROJECT_MANAGER_ROLE) {
        // Example placeholder: just increment lastReportedValue
        projectStateData[projectId].lastReportedValue += 1;
    }

    // 4. setCategoryMultiplier
    function setCategoryMultiplier(ProjectCategory /*category*/, uint256 /*multiplier*/)
        external
        override
        onlyRole(PROJECT_MANAGER_ROLE)
    {
        // Example: no-op or store the multiplier in a mapping
        // If you have category-based multipliers, implement logic here
    }

    // 5. setImpactRequirement
    function setImpactRequirement(
        ProjectCategory category,
        ImpactRequirement calldata requirement
    ) external override onlyRole(PROJECT_MANAGER_ROLE) {
        categoryRequirements[category] = requirement;
    }

    // 6. addComment
    function addComment(uint256 projectId, string calldata message)
        external
        override
        validProjectId(projectId)
    {
        // Add the comment to the arrays
        projectComments[projectId].push(message);
        projectCommenters[projectId].push(msg.sender);
    }

    // 7. getProjectCount
    function getProjectCount() external view override returns (uint256) {
        return projectCount;
    }

    // 8. getProjectDetails
    function getProjectDetails(uint256 projectId)
        external
        view
        override
        validProjectId(projectId)
        returns (ProjectData memory)
    {
        return projectMetadata[projectId];
    }

    // 9. getProjectState
    function getProjectState(uint256 projectId)
        external
        view
        override
        validProjectId(projectId)
        returns (ProjectStateData memory)
    {
        return projectStateData[projectId];
    }

    // 10. getCategoryRequirements
    function getCategoryRequirements(ProjectCategory category)
        external
        view
        override
        returns (ImpactRequirement memory)
    {
        return categoryRequirements[category];
    }

    // 11. getValidationReport
    function getValidationReport(uint256 projectId)
        external
        view
        override
        validProjectId(projectId)
        returns (ValidationData memory)
    {
        return validations[projectId];
    }

    // 12. getVerificationReport
    function getVerificationReport(uint256 projectId)
        external
        view
        override
        validProjectId(projectId)
        returns (VerificationData memory)
    {
        return verifications[projectId];
    }

    // 13. isProjectActive
    function isProjectActive(uint256 projectId)
        external
        view
        override
        validProjectId(projectId)
        returns (bool)
    {
        return projectStateData[projectId].isActive;
    }

    // 14. getComments
    function getComments(uint256 projectId)
        external
        view
        override
        validProjectId(projectId)
        returns (string[] memory messages, address[] memory commenters)
    {
        return (projectComments[projectId], projectCommenters[projectId]);
    }

    // 15. getGeneralMetadata
    function getGeneralMetadata(uint256 projectId)
        external
        view
        override
        validProjectId(projectId)
        returns (GeneralMetadata memory)
    {
        return generalMetadata[projectId];
    }

    // 16. setGeneralMetadata
    function setGeneralMetadata(uint256 projectId, GeneralMetadata calldata data)
        external
        override
        validProjectId(projectId)
        onlyRole(PROJECT_MANAGER_ROLE)
    {
        generalMetadata[projectId] = data;
    }
}
