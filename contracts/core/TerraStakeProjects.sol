// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/ITerraStakeProjects.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/ITerraStakeRewards.sol";

contract TerraStakeProjects is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, ITerraStakeProjects {
    // Errors
    error UnauthorizedAccess();
    error InvalidProjectId();
    error InvalidProjectState();
    error ProjectAlreadyExists();
    error InvalidParameters();
    error InsufficientFunds();
    error ContractNotSet();
    error NotActive();
    error NoVerificationFeePaid();

    // Roles
    bytes32 public constant PROJECT_MANAGER_ROLE = keccak256("PROJECT_MANAGER_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    bytes32 public constant REWARD_MANAGER_ROLE = keccak256("REWARD_MANAGER_ROLE");

    // Contracts
    ITerraStakeStaking public stakingContract;
    ITerraStakeRewards public rewardsContract;
    IERC20 public tstakeToken;

    // Project Management
    uint256 public registrationFee;
    uint256 public verificationFee;
    uint256 public projectCount;

    mapping(uint256 => ProjectData) public projectMetadata;
    mapping(uint256 => GeneralMetadata) private generalMetadataMapping;
    mapping(uint256 => ProjectStateData) public projectStateData;
    mapping(ProjectCategory => ImpactRequirement) public categoryRequirements;
    mapping(uint256 => Comment[]) private projectComments;

    mapping(uint256 => ValidationData) public validations;
    mapping(uint256 => VerificationData) public verifications;

    constructor() {
        _disableInitializers();
    }

    modifier validProjectId(uint256 projectId) {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        _;
    }

    modifier contractsSet() {
        if (address(stakingContract) == address(0) || address(rewardsContract) == address(0)) {
            revert ContractNotSet();
        }
        _;
    }

    /// @notice Initialize the project contract
    function initialize(address admin, address _tstakeToken) external override initializer {
        if (admin == address(0) || _tstakeToken == address(0)) revert UnauthorizedAccess();

        __AccessControl_init();
        __ReentrancyGuard_init();

        tstakeToken = IERC20(_tstakeToken);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PROJECT_MANAGER_ROLE, admin);
        _grantRole(VALIDATOR_ROLE, admin);
        _grantRole(REWARD_MANAGER_ROLE, admin);

        registrationFee = 200 * 10**18; // 200 TSTAKE
        verificationFee = 100 * 10**18; // 100 TSTAKE
    }

    // Set General Metadata for a project
    function setGeneralMetadata(uint256 projectId, GeneralMetadata calldata metadata) external override onlyRole(PROJECT_MANAGER_ROLE) {
        require(projectMetadata[projectId].exists, "Project does not exist");
        generalMetadataMapping[projectId] = metadata;
    }

    // Report metrics for a project
    function reportMetric(
        uint256 projectId,
        string calldata metricType,
        string calldata metricValue
    ) external override onlyRole(PROJECT_MANAGER_ROLE) {
        require(projectMetadata[projectId].exists, "Project does not exist");
        emit MetricsReported(projectId, metricType, metricValue);
    }

    /// @notice Set staking and reward contracts
    function setContracts(address _stakingContract, address _rewardsContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_stakingContract == address(0) || _rewardsContract == address(0)) revert ContractNotSet();
        stakingContract = ITerraStakeStaking(_stakingContract);
        rewardsContract = ITerraStakeRewards(_rewardsContract);
        emit ContractsSet(_stakingContract, _rewardsContract);
    }

    // View Functions
    function getCategoryRequirements(ProjectCategory category)
        external
        view
        override
        returns (ImpactRequirement memory)
    {
        return categoryRequirements[category];
    }

    function getGeneralMetadata(uint256 projectId) external view override returns (GeneralMetadata memory) {
        return generalMetadataMapping[projectId];
    }

    function getProjectCount() external view override returns (uint256) {
        return projectCount;
    }

    function getProjectDetails(uint256 projectId) external view override returns (ProjectData memory) {
        require(projectMetadata[projectId].exists, "Project does not exist");
        return projectMetadata[projectId];
    }

    function getProjectState(uint256 projectId) external view override returns (ProjectStateData memory) {
        require(projectMetadata[projectId].exists, "Project does not exist");
        return projectStateData[projectId];
    }

    function getValidationReport(
        uint256 projectId
    ) external view validProjectId(projectId) returns (ValidationData memory) {
        return validations[projectId];
    }

    function getVerificationReport(
        uint256 projectId
    ) external view validProjectId(projectId) returns (VerificationData memory) {
        return verifications[projectId];
    }

    function isProjectActive(
        uint256 projectId
    ) external view validProjectId(projectId) returns (bool) {
        return projectStateData[projectId].isActive;
    }

    /// @notice Add a new project
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
    ) external override nonReentrant onlyRole(PROJECT_MANAGER_ROLE) contractsSet {
        if (stakingMultiplier == 0 || startBlock >= endBlock) revert InvalidParameters();

        if (!tstakeToken.transferFrom(msg.sender, address(this), registrationFee)) {
            revert InsufficientFunds();
        }

        uint256 projectId = projectCount++;
        if (projectMetadata[projectId].exists) revert ProjectAlreadyExists();

        projectMetadata[projectId] = ProjectData({
            name: name,
            description: description,
            location: location,
            impactMetrics: impactMetrics,
            ipfsHash: ipfsHash,
            exists: true
        });

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

        stakingContract.updateProjectStakingData(projectId, stakingMultiplier);

        emit ProjectAdded(projectId, name, category);
    }

    // Update Fee Structure
    function updateFeeStructure(
        uint256 _registrationFee,
        uint256 _categoryChangeFee,
        uint256 _verificationFee
    ) external override onlyRole(PROJECT_MANAGER_ROLE) {
        emit FeeStructureUpdated(_registrationFee, _verificationFee, _categoryChangeFee);
    }

    /// @notice Update project state
    function updateProjectState(uint256 projectId, ProjectState newState) external override validProjectId(projectId) onlyRole(PROJECT_MANAGER_ROLE) {
        ProjectState oldState = projectStateData[projectId].state;
        projectStateData[projectId].state = newState;
        projectStateData[projectId].isActive = (newState == ProjectState.Active);
        emit ProjectStateChanged(projectId, oldState, newState);
    }

    function submitValidation(
        uint256 projectId,
        bytes32 reportHash
    ) external onlyRole(VALIDATOR_ROLE) validProjectId(projectId) {
        validations[projectId] = ValidationData({
            vvb: msg.sender,
            validationDate: block.timestamp,
            validationReportHash: reportHash
        });
        emit ValidationSubmitted(projectId, msg.sender, reportHash);
    }

    /// @notice Submit verification report and fund rewards
    function submitVerification(uint256 projectId, bytes32 reportHash) external override nonReentrant onlyRole(VALIDATOR_ROLE) validProjectId(projectId) contractsSet {
        if (!tstakeToken.transferFrom(msg.sender, address(this), verificationFee)) {
            revert NoVerificationFeePaid();
        }

        verifications[projectId] = VerificationData({
            vvb: msg.sender,
            verificationDate: block.timestamp,
            verificationReportHash: reportHash
        });

        if (!rewardsContract.isProjectHasPool(projectId)) {
            uint32 multiplier = 10000;
            uint48 duration = 20000;
            tstakeToken.approve(address(rewardsContract), verificationFee);
            rewardsContract.createProjectPool(projectId, verificationFee, multiplier, duration);
        } else {
            tstakeToken.approve(address(rewardsContract), verificationFee);
            rewardsContract.fundProjectRewards(projectId, verificationFee);
        }

        emit VerificationSubmitted(projectId, msg.sender, reportHash);
    }

    function setCategoryMultiplier(
        ITerraStakeProjects.ProjectCategory category, 
        uint256 multiplier
    ) external onlyRole(PROJECT_MANAGER_ROLE) {
        if (multiplier == 0) revert InvalidParameters();
        categoryRequirements[category].qualityThreshold = multiplier;
        emit CategoryMultiplierUpdated(category, multiplier);
    }

    /// @notice Update project documentation
    function updateProjectDocumentation(uint256 projectId, bytes32[] calldata documentHashes) external override validProjectId(projectId) onlyRole(PROJECT_MANAGER_ROLE) {
        emit DocumentationUpdated(projectId, documentHashes);
    }

    // Set Impact Requirement
    function setImpactRequirement(
        ProjectCategory category,
        uint256 minimumImpact,
        uint256 verificationFrequency,
        string[] calldata requiredDocuments,
        uint256 qualityThreshold,
        uint256 minimumScale
    ) external override onlyRole(PROJECT_MANAGER_ROLE) {
        categoryRequirements[category] = ImpactRequirement({
            minimumImpact: minimumImpact,
            verificationFrequency: verificationFrequency,
            requiredDocuments: requiredDocuments,
            qualityThreshold: qualityThreshold,
            minimumScale: minimumScale
        });
        emit ImpactRequirementUpdated(category, minimumImpact);
    }

    /// @notice Add a comment to a project
    function addComment(uint256 projectId, string calldata message) external override validProjectId(projectId) {
        projectComments[projectId].push(Comment({
            commenter: msg.sender,
            message: message,
            timestamp: block.timestamp
        }));
        emit CommentAdded(projectId, msg.sender, message);
    }

    /// @notice Get all comments on a project
    function getComments(uint256 projectId) external view override validProjectId(projectId) returns (string[] memory messages, address[] memory commenters, uint256[] memory timestamps) {
        Comment[] storage comments = projectComments[projectId];
        messages = new string[](comments.length);
        commenters = new address[](comments.length);
        timestamps = new uint256[](comments.length);
        for (uint256 i = 0; i < comments.length; i++) {
            messages[i] = comments[i].message;
            commenters[i] = comments[i].commenter;
            timestamps[i] = comments[i].timestamp;
        }
    }
}
