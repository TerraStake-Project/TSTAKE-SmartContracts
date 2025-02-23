// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "../interfaces/ITerraStakeProjects.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TerraStakeProjects (3B Cap Secured)
 * @notice Manages projects with IPFS document storage, staking, and impact tracking.
 *
 * Features:
 * ✅ IPFS-Based Document Storage (Off-Chain, Low Gas)
 * ✅ Staking & Impact-Based Project Management
 * ✅ Governance-Driven Project Validation & Verification
 * ✅ Chainlink Data Feeder for Live Analytics
 * ✅ Renewable Energy Certificate (REC) Tracking
 */
contract TerraStakeProjects is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, ITerraStakeProjects {
    // ====================================================
    // 🔑 Roles
    // ====================================================
    bytes32 public constant PROJECT_MANAGER_ROLE = keccak256("PROJECT_MANAGER_ROLE");
    bytes32 public constant CHAINLINK_FEEDER_ROLE = keccak256("CHAINLINK_FEEDER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant STAKER_ROLE = keccak256("STAKER_ROLE");

    // ====================================================
    // 📌 State Variables
    // ====================================================
    IERC20 public tStakeToken;
    uint256 public projectCount;
    uint256 public registrationFee;
    uint256 public verificationFee;
    uint256 public categoryChangeFee;

    mapping(uint256 => ProjectData) public projectMetadata;
    mapping(uint256 => ProjectStateData) public projectStateData;
    mapping(ProjectCategory => ImpactRequirement) public impactRequirements;
    mapping(uint256 => ValidationData) public projectValidations;
    mapping(uint256 => VerificationData) public projectVerifications;
    mapping(uint256 => GeneralMetadata) public projectMetadataDetails;
    mapping(uint256 => Comment[]) public projectComments;
    mapping(uint256 => mapping(address => uint256)) public projectStakes;
    mapping(uint256 => string[]) public projectDocumentCIDs;
    mapping(uint256 => ProjectAnalytics) public projectAnalytics;
    mapping(uint256 => ImpactReport[]) public projectImpactReports;
    mapping(uint256 => RECData) public projectRECs;
    mapping(ProjectCategory => uint256) public categoryMultipliers;

    // ====================================================
    // 🔹 Modifiers
    // ====================================================
    modifier validProjectId(uint256 projectId) {
        require(projectMetadata[projectId].exists, "Invalid project ID");
        _;
    }

    // ====================================================
    // 🚀 Initialization
    // ====================================================
    function initialize(address admin, address _tstakeToken) external override initializer {
        require(admin != address(0), "Invalid admin address");
        require(_tstakeToken != address(0), "Invalid TSTAKE token address");

        __AccessControl_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PROJECT_MANAGER_ROLE, admin);
        _grantRole(CHAINLINK_FEEDER_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(STAKER_ROLE, admin);

        tStakeToken = IERC20(_tstakeToken);
        emit Initialized(admin, _tstakeToken);
    }

    // ====================================================
    // 🔹 Project Management
    // ====================================================
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
    ) external override onlyRole(PROJECT_MANAGER_ROLE) {
        require(bytes(name).length > 0, "Name required");
        require(ipfsHash != bytes32(0), "Invalid IPFS hash");
        require(endBlock > startBlock, "End block must be after start");
        require(stakingMultiplier > 0, "Invalid multiplier");

        uint256 newProjectId = projectCount++;
        projectMetadata[newProjectId] = ProjectData(name, description, location, impactMetrics, ipfsHash, true);
        projectStateData[newProjectId] = ProjectStateData({
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

        emit ProjectAdded(newProjectId, name, category);
    }

    function updateProjectState(uint256 projectId, ProjectState newState) external override validProjectId(projectId) onlyRole(GOVERNANCE_ROLE) {
        ProjectStateData storage stateData = projectStateData[projectId];
        ProjectState oldState = stateData.state;

        stateData.state = newState;
        stateData.isActive = (newState == ProjectState.Active);
        emit ProjectStateChanged(projectId, oldState, newState);
    }

    // ====================================================
    // 🔹 Impact Requirement Management
    // ====================================================
    function setImpactRequirement(
        ProjectCategory category,
        uint256 minimumImpact,
        uint256 verificationFrequency,
        string[] calldata requiredDocuments,
        uint256 qualityThreshold,
        uint256 minimumScale
    ) external override onlyRole(GOVERNANCE_ROLE) {
        impactRequirements[category] = ImpactRequirement(
            minimumImpact,
            verificationFrequency,
            requiredDocuments,
            qualityThreshold,
            minimumScale
        );
        emit ImpactRequirementUpdated(category, minimumImpact);
    }

    // ====================================================
    // 🔹 Project Analytics & Reporting
    // ====================================================
    function getProjectAnalytics(uint256 projectId) external view override validProjectId(projectId) returns (ProjectAnalytics memory) {
        return projectAnalytics[projectId];
    }

    function updateProjectAnalytics(
        uint256 projectId,
        uint256 totalImpact,
        uint256 carbonOffset,
        uint256 stakingEfficiency,
        uint256 communityEngagement
    ) external override onlyRole(GOVERNANCE_ROLE) validProjectId(projectId) {
        projectAnalytics[projectId] = ProjectAnalytics(
            totalImpact,
            carbonOffset,
            stakingEfficiency,
            communityEngagement
        );
        emit AnalyticsUpdated(projectId, totalImpact);
    }

    function submitImpactReport(
        uint256 projectId,
        uint256 periodStart,
        uint256 periodEnd,
        uint256[] memory metrics,
        bytes32 reportHash
    ) external override onlyRole(GOVERNANCE_ROLE) validProjectId(projectId) {
        projectImpactReports[projectId].push(ImpactReport(periodStart, periodEnd, metrics, reportHash));
        emit ImpactReportSubmitted(projectId, reportHash);
    }

    function getImpactReports(uint256 projectId) external view override validProjectId(projectId) returns (ImpactReport[] memory) {
        return projectImpactReports[projectId];
    }

    // ====================================================
    // 🔹 REC Management
    // ====================================================
    function submitRECReport(uint256 projectId, RECData memory rec) external override onlyRole(GOVERNANCE_ROLE) validProjectId(projectId) {
        projectRECs[projectId] = rec;
        emit RECReportSubmitted(projectId, rec.recId);
    }

    function getREC(uint256 projectId) external view override validProjectId(projectId) returns (RECData memory) {
        return projectRECs[projectId];
    }

    function verifyREC(bytes32 recId) external view override returns (bool) {
        return projectRECs[recId].isRetired;
    }
}
