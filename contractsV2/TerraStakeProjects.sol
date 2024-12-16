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
    // Roles
    bytes32 public constant PROJECT_MANAGER_ROLE = keccak256("PROJECT_MANAGER_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    bytes32 public constant REWARD_MANAGER_ROLE = keccak256("REWARD_MANAGER_ROLE");

    // Fee Structure
    uint256 public registrationFee;
    uint256 public verificationFee;
    uint256 public categoryChangeFee;

    // Contract References
    ITerraStakeStaking public stakingContract;
    ITerraStakeRewards public rewardsContract;
    IERC20 public rewardToken;

    // Mappings
    mapping(uint256 => ProjectData) public projectMetadata;
    mapping(uint256 => ProjectStateData) public projectStateData;
    mapping(uint256 => GeneralMetadata) public generalMetadata;
    mapping(ProjectCategory => ImpactRequirement) public categoryRequirements;
    mapping(ProjectCategory => uint256) public categoryMultipliers;
    mapping(uint256 => bytes32[]) public projectDocumentation;
    mapping(ProjectCategory => uint256[]) public projectsByCategory;

    uint256 public projectCount;

    // Events
    event ProjectAdded(uint256 indexed projectId, string name, ProjectCategory category);
    event ProjectUpdated(uint256 indexed projectId, string name);
    event ProjectStateChanged(uint256 indexed projectId, ProjectState oldState, ProjectState newState);
    event DocumentationUpdated(uint256 indexed projectId, bytes32[] documentHashes);
    event MetricsReported(uint256 indexed projectId, string metricType, string metricValue);
    event CategoryMultiplierUpdated(ProjectCategory indexed category, uint256 multiplier);
    event ImpactRequirementUpdated(ProjectCategory indexed category, uint256 minimumImpact);
    event FeeStructureUpdated(uint256 registrationFee, uint256 verificationFee, uint256 categoryChangeFee);
    event ContractsSet(address stakingContract, address rewardsContract);

    constructor() {
        _disableInitializers();
    }

    modifier validProjectId(uint256 projectId) {
        require(projectMetadata[projectId].exists, "Invalid project ID");
        _;
    }

    modifier contractsSet() {
        require(address(stakingContract) != address(0) && address(rewardsContract) != address(0), "Contracts not set");
        _;
    }

    function initialize(address admin, address _rewardToken) external initializer {
        require(admin != address(0) && _rewardToken != address(0), "Invalid addresses");

        __AccessControl_init();
        __ReentrancyGuard_init();

        rewardToken = IERC20(_rewardToken);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PROJECT_MANAGER_ROLE, admin);
        _grantRole(VALIDATOR_ROLE, admin);
        _grantRole(REWARD_MANAGER_ROLE, admin);

        _initializeFeeStructure();
    }

    function _initializeFeeStructure() internal {
        registrationFee = 1 ether;
        verificationFee = 0.5 ether;
        categoryChangeFee = 0.2 ether;
    }

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
    ) external payable onlyRole(PROJECT_MANAGER_ROLE) contractsSet {
        require(msg.value >= registrationFee, "Insufficient registration fee");
        require(bytes(name).length > 0, "Project name required");
        require(startBlock < endBlock, "Invalid project duration");
        require(stakingMultiplier > 0, "Staking multiplier required");

        uint256 projectId = projectCount++;

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

        projectsByCategory[category].push(projectId);

        stakingContract.updateProjectStakingData(projectId, stakingMultiplier);

        emit ProjectAdded(projectId, name, category);
    }

    function updateProjectState(uint256 projectId, ProjectState newState) external validProjectId(projectId) onlyRole(PROJECT_MANAGER_ROLE) {
        ProjectStateData storage projectState = projectStateData[projectId];
        require(newState != projectState.state, "State already set");

        ProjectState oldState = projectState.state;
        projectState.state = newState;

        if (newState == ProjectState.Active) {
            projectState.isActive = true;
        } else if (newState == ProjectState.Suspended || newState == ProjectState.Archived) {
            projectState.isActive = false;
        }

        emit ProjectStateChanged(projectId, oldState, newState);
    }

    function reportMetric(uint256 projectId, string calldata metricType, string calldata metricValue)
        external
        validProjectId(projectId)
        onlyRole(VALIDATOR_ROLE)
    {
        emit MetricsReported(projectId, metricType, metricValue);
    }

    function updateProjectDocumentation(uint256 projectId, bytes32[] calldata documentHashes)
        external
        validProjectId(projectId)
        onlyRole(PROJECT_MANAGER_ROLE)
    {
        projectDocumentation[projectId] = documentHashes;
        emit DocumentationUpdated(projectId, documentHashes);
    }

    function setCategoryMultiplier(ProjectCategory category, uint256 multiplier) external onlyRole(PROJECT_MANAGER_ROLE) {
        require(multiplier > 0, "Multiplier must be greater than zero");
        categoryMultipliers[category] = multiplier;
        emit CategoryMultiplierUpdated(category, multiplier);
    }

    function setImpactRequirement(
        ProjectCategory category,
        uint256 minimumImpact,
        uint256 verificationFrequency,
        string[] calldata requiredDocuments,
        uint256 qualityThreshold,
        uint256 minimumScale
    ) external onlyRole(PROJECT_MANAGER_ROLE) {
        categoryRequirements[category] = ImpactRequirement({
            minimumImpact: minimumImpact,
            verificationFrequency: verificationFrequency,
            requiredDocuments: requiredDocuments,
            qualityThreshold: qualityThreshold,
            minimumScale: minimumScale
        });
        emit ImpactRequirementUpdated(category, minimumImpact);
    }

    function updateFeeStructure(uint256 _registrationFee, uint256 _verificationFee, uint256 _categoryChangeFee)
        external
        onlyRole(REWARD_MANAGER_ROLE)
    {
        registrationFee = _registrationFee;
        verificationFee = _verificationFee;
        categoryChangeFee = _categoryChangeFee;

        emit FeeStructureUpdated(_registrationFee, _verificationFee, _categoryChangeFee);
    }

    function setContracts(address _stakingContract, address _rewardsContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_stakingContract != address(0) && _rewardsContract != address(0), "Invalid contract addresses");

        stakingContract = ITerraStakeStaking(_stakingContract);
        rewardsContract = ITerraStakeRewards(_rewardsContract);

        emit ContractsSet(_stakingContract, _rewardsContract);
    }

    // View Functions
    function getProjectDetails(uint256 projectId) external view validProjectId(projectId) returns (ProjectData memory) {
        return projectMetadata[projectId];
    }

    function getProjectState(uint256 projectId) external view validProjectId(projectId) returns (ProjectStateData memory) {
        return projectStateData[projectId];
    }

    function getCategoryRequirements(ProjectCategory category) external view returns (ImpactRequirement memory) {
        return categoryRequirements[category];
    }

    function getProjectsByCategory(ProjectCategory category) external view returns (uint256[] memory) {
        return projectsByCategory[category];
    }

    function getProjectCount() external view returns (uint256) {
        return projectCount;
    }
}
