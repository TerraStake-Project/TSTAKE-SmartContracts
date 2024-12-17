    // SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/ITerraStakeProjects.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/ITerraStakeRewards.sol";

contract TerraStakeProjects is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    // Custom Errors
    error UnauthorizedAccess();
    error InvalidProjectId();
    error InvalidProjectState();
    error ProjectAlreadyExists();
    error InvalidParameters();
    error InsufficientFunds();
    error ContractNotSet();

    // Roles
    bytes32 public constant PROJECT_MANAGER_ROLE = keccak256("PROJECT_MANAGER_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    bytes32 public constant FEED_UPDATE_ROLE = keccak256("FEED_UPDATE_ROLE");
    bytes32 public constant REWARD_MANAGER_ROLE = keccak256("REWARD_MANAGER_ROLE");

    // Fee Structure
    uint256 public registrationFee;
    uint256 public verificationFee;

    // Metadata Structs
    struct Methodology {
        string name;
        string description;
        string version;
        bytes32 externalReference;
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

    // Contract References
    ITerraStakeStaking public stakingContract;
    ITerraStakeRewards public rewardsContract;
    IERC20 public rewardToken;

    // Mappings
    mapping(uint256 => Methodology) public methodologies;
    mapping(uint256 => ValidationData) public validations;
    mapping(uint256 => VerificationData) public verifications;
    mapping(uint256 => ITerraStakeProjects.GeneralMetadata) public generalProjectMetadata;
    mapping(uint256 => ITerraStakeProjects.ProjectData) public projectMetadata;
    mapping(uint256 => ITerraStakeProjects.ProjectStateData) public projectStateData;
    mapping(ITerraStakeProjects.ProjectCategory => ITerraStakeProjects.ImpactRequirement) public categoryRequirements;
    mapping(uint256 => Comment[]) private projectComments;

    // State Variables
    uint256 public projectCount;

    // Events
    event ProjectAdded(uint256 indexed projectId, string name, ITerraStakeProjects.ProjectCategory category);
    event ProjectUpdated(uint256 indexed projectId, string name);
    event ProjectStateChanged(uint256 indexed projectId, ITerraStakeProjects.ProjectState indexed oldState, ITerraStakeProjects.ProjectState indexed newState);
    event ValidationSubmitted(uint256 indexed projectId, address indexed vvb, bytes32 reportHash);
    event VerificationSubmitted(uint256 indexed projectId, address indexed vvb, bytes32 reportHash);
    event MetricsReported(uint256 indexed projectId, string metricType, string metricValue);
    event DocumentationUpdated(uint256 indexed projectId, bytes32[] documentHashes);
    event CategoryMultiplierUpdated(ITerraStakeProjects.ProjectCategory indexed category, uint256 multiplier);
    event ImpactRequirementUpdated(ITerraStakeProjects.ProjectCategory indexed category, uint256 minimumImpact);
    event ContractsSet(address stakingContract, address rewardsContract);
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

    function initialize(address admin, address _rewardToken) external initializer {
        if (admin == address(0) || _rewardToken == address(0)) revert UnauthorizedAccess();

        __AccessControl_init();
        __ReentrancyGuard_init();

        rewardToken = IERC20(_rewardToken);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PROJECT_MANAGER_ROLE, admin);
        _grantRole(VALIDATOR_ROLE, admin);
        _grantRole(REWARD_MANAGER_ROLE, admin);

        _initializeFees();
    }

    function _initializeFees() internal {
        registrationFee = 1000 ether;
        verificationFee = 500 ether;
    }
    function addProject(
        string memory name,
        string memory description,
        string memory location,
        string memory impactMetrics,
        bytes32 ipfsHash,
        ITerraStakeProjects.ProjectCategory category,
        uint32 stakingMultiplier,
        uint48 startBlock,
        uint48 endBlock
    ) external payable onlyRole(PROJECT_MANAGER_ROLE) contractsSet {
        if (stakingMultiplier == 0 || startBlock >= endBlock) revert InvalidParameters();
        if (msg.value < registrationFee) revert InsufficientFunds();

        uint256 projectId = projectCount++;
        if (projectMetadata[projectId].exists) revert ProjectAlreadyExists();

        projectMetadata[projectId] = ITerraStakeProjects.ProjectData({
            name: name,
            description: description,
            location: location,
            impactMetrics: impactMetrics,
            ipfsHash: ipfsHash,
            exists: true
        });

        projectStateData[projectId] = ITerraStakeProjects.ProjectStateData({
            category: category,
            state: ITerraStakeProjects.ProjectState.Proposed,
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

    function updateProjectState(
        uint256 projectId, 
        ITerraStakeProjects.ProjectState newState
    ) external validProjectId(projectId) onlyRole(PROJECT_MANAGER_ROLE) {
        ITerraStakeProjects.ProjectState oldState = projectStateData[projectId].state;
        projectStateData[projectId].state = newState;
        emit ProjectStateChanged(projectId, oldState, newState);
    }

    function updateProjectDocumentation(
        uint256 projectId,
        bytes32[] calldata documentHashes
    ) external validProjectId(projectId) onlyRole(PROJECT_MANAGER_ROLE) {
        emit DocumentationUpdated(projectId, documentHashes);
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

    function submitVerification(
        uint256 projectId,
        bytes32 reportHash
    ) external onlyRole(VALIDATOR_ROLE) validProjectId(projectId) {
        verifications[projectId] = VerificationData({
            vvb: msg.sender,
            verificationDate: block.timestamp,
            verificationReportHash: reportHash
        });
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

    function setImpactRequirement(
        ITerraStakeProjects.ProjectCategory category,
        uint256 minimumImpact,
        uint256 verificationFrequency,
        string[] calldata requiredDocuments,
        uint256 qualityThreshold,
        uint256 minimumScale
    ) external onlyRole(PROJECT_MANAGER_ROLE) {
        categoryRequirements[category] = ITerraStakeProjects.ImpactRequirement({
            minimumImpact: minimumImpact,
            verificationFrequency: verificationFrequency,
            requiredDocuments: requiredDocuments,
            qualityThreshold: qualityThreshold,
            minimumScale: minimumScale
        });
        emit ImpactRequirementUpdated(category, minimumImpact);
    }
    function updateFeeStructure(
        uint256 _registrationFee,
        uint256 _verificationFee
    ) external onlyRole(REWARD_MANAGER_ROLE) {
        registrationFee = _registrationFee;
        verificationFee = _verificationFee;
    }

    function setContracts(
        address _stakingContract, 
        address _rewardsContract
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_stakingContract == address(0) || _rewardsContract == address(0)) revert ContractNotSet();
        stakingContract = ITerraStakeStaking(_stakingContract);
        rewardsContract = ITerraStakeRewards(_rewardsContract);
        emit ContractsSet(_stakingContract, _rewardsContract);
    }
    function getProjectDetails(
        uint256 projectId
    ) external view validProjectId(projectId) returns (ITerraStakeProjects.ProjectData memory) {
        return projectMetadata[projectId];
    }

    function getProjectState(
        uint256 projectId
    ) external view validProjectId(projectId) returns (ITerraStakeProjects.ProjectStateData memory) {
        return projectStateData[projectId];
    }

    function getCategoryRequirements(
        ITerraStakeProjects.ProjectCategory category
    ) external view returns (ITerraStakeProjects.ImpactRequirement memory) {
        return categoryRequirements[category];
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

    function getProjectCount() external view returns (uint256) {
        return projectCount;
    }
}
