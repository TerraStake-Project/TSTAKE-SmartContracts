// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/ITerraStakeProjects.sol";

/**
 * @title TerraStakeProjects (3B Cap Secured)
 * @notice Manages projects, staking, impact tracking, and governance-driven fees.
 */
contract TerraStakeProjects is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, ITerraStakeProjects {
    // ====================================================
    // 🔑 Roles
    // ====================================================
    bytes32 public constant PROJECT_MANAGER_ROLE = keccak256("PROJECT_MANAGER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant STAKER_ROLE = keccak256("STAKER_ROLE");

    // ====================================================
    // 📌 State Variables
    // ====================================================
    IERC20 public tStakeToken;
    uint256 public projectCount;
    
    uint256 public projectSubmissionFee;   // Fee for adding a project (in TSTAKE)
    uint256 public impactReportingFee;     // Fee for reporting impact (in TSTAKE)
    
    address public treasury;               // Treasury wallet for fee collection
    address public liquidityPool;          // Liquidity pool for automated pairing

    mapping(uint256 => ProjectData) public projectMetadata;
    mapping(uint256 => ProjectStateData) public projectStateData;
    mapping(uint256 => ValidationData) public projectValidations;
    mapping(uint256 => VerificationData) public projectVerifications;
    mapping(uint256 => GeneralMetadata) public projectMetadataDetails;
    mapping(uint256 => Comment[]) public projectComments;
    mapping(uint256 => string[]) public projectDocumentCIDs;
    mapping(uint256 => ProjectAnalytics) public projectAnalytics;
    mapping(uint256 => ImpactReport[]) public projectImpactReports;

    // ====================================================
    // 🔹 Events
    // ====================================================
    event ProjectAdded(uint256 indexed projectId, string name, ProjectCategory category);
    event ProjectStateChanged(uint256 indexed projectId, ProjectState indexed oldState, ProjectState indexed newState);
    event ImpactReportSubmitted(uint256 indexed projectId, bytes32 reportHash);
    event CommentAdded(uint256 indexed projectId, address indexed commenter, string message);
    event MetricsReported(uint256 indexed projectId, string metricType, string metricValue);
    event FeeStructureUpdated(uint256 newProjectFee, uint256 newImpactFee);
    event LiquidityBuybackExecuted(uint256 buybackAmount, uint256 liquidityAdded);

    // ====================================================
    // 🚀 Initialization
    // ====================================================
    function initialize(
        address admin, 
        address _tstakeToken, 
        address _treasury, 
        address _liquidityPool
    ) external override initializer {
        require(admin != address(0) && _tstakeToken != address(0), "Invalid addresses");

        __AccessControl_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PROJECT_MANAGER_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(STAKER_ROLE, admin);

        tStakeToken = IERC20(_tstakeToken);
        treasury = _treasury;
        liquidityPool = _liquidityPool;

        projectSubmissionFee = 6100 * 10**18; // $6,100 in TSTAKE
        impactReportingFee = 2200 * 10**18;   // $2,200 in TSTAKE

        emit FeeStructureUpdated(projectSubmissionFee, impactReportingFee);
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

        // Fee Collection (50% Burn, 45% Treasury, 5% Buyback)
        require(tStakeToken.transferFrom(msg.sender, address(this), projectSubmissionFee), "Fee transfer failed");
        uint256 burnAmount = (projectSubmissionFee * 50) / 100;
        uint256 treasuryAmount = (projectSubmissionFee * 45) / 100;
        uint256 buybackAmount = (projectSubmissionFee * 5) / 100;

        tStakeToken.transfer(treasury, treasuryAmount);
        _executeBuyback(buybackAmount);

        // Store Project Data
        uint256 newProjectId = projectCount++;
        projectMetadata[newProjectId] = ProjectData(name, description, location, impactMetrics, ipfsHash, true);
        projectStateData[newProjectId] = ProjectStateData(category, ProjectState.Proposed, stakingMultiplier, 0, 0, false, startBlock, endBlock, msg.sender, 0, block.timestamp, 0);

        emit ProjectAdded(newProjectId, name, category);
    }

    function submitImpactReport(
        uint256 projectId,
        uint256 periodStart,
        uint256 periodEnd,
        uint256[] memory metrics,
        bytes32 reportHash
    ) external override onlyRole(STAKER_ROLE) {
        require(projectMetadata[projectId].exists, "Invalid project ID");

        // Fee Collection (50% Burn, 45% Treasury, 5% Buyback)
        require(tStakeToken.transferFrom(msg.sender, address(this), impactReportingFee), "Fee transfer failed");
        uint256 burnAmount = (impactReportingFee * 50) / 100;
        uint256 treasuryAmount = (impactReportingFee * 45) / 100;
        uint256 buybackAmount = (impactReportingFee * 5) / 100;

        tStakeToken.transfer(treasury, treasuryAmount);
        _executeBuyback(buybackAmount);

        projectImpactReports[projectId].push(ImpactReport(periodStart, periodEnd, metrics, reportHash));
        emit ImpactReportSubmitted(projectId, reportHash);
    }

    function _executeBuyback(uint256 amount) private {
        if (amount > 0) {
            tStakeToken.transfer(liquidityPool, amount);
            emit LiquidityBuybackExecuted(amount, amount);
        }
    }

    function updateFeeStructure(uint256 newProjectFee, uint256 newImpactFee) external onlyRole(GOVERNANCE_ROLE) {
        projectSubmissionFee = newProjectFee;
        impactReportingFee = newImpactFee;
        emit FeeStructureUpdated(newProjectFee, newImpactFee);
    }
}
