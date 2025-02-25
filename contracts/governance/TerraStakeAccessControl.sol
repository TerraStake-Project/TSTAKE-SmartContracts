// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TerraStakeAccessControl
 * @notice Centralized Role-Based Access Control for TerraStake
 * @dev Implements hierarchical permissioning, role time-locks, and governance-controlled security measures.
 */
contract TerraStakeAccessControl is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // ====================================================
    // 🔹 State Variables
    // ====================================================
    IERC20 private _tStakeToken;
    
    // Role definitions (Optimized for Gas Efficiency)
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant LIQUIDITY_MANAGER_ROLE = keccak256("LIQUIDITY_MANAGER_ROLE");
    bytes32 public constant VESTING_MANAGER_ROLE = keccak256("VESTING_MANAGER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MULTISIG_ADMIN_ROLE = keccak256("MULTISIG_ADMIN_ROLE");
    bytes32 public constant REWARD_MANAGER_ROLE = keccak256("REWARD_MANAGER_ROLE");
    bytes32 public constant DISTRIBUTION_ROLE = keccak256("DISTRIBUTION_ROLE");

    struct RoleData {
        uint256 requirement;      // Minimum TSTAKE balance required
        uint256 expiration;       // Role expiration timestamp
        bytes32 parentRole;       // Hierarchical parent role (if required)
        bool isActive;            // Role activation status
    }

    // Role storage mapping
    mapping(bytes32 => mapping(address => RoleData)) private _roleData;
    mapping(bytes32 => uint256) private _roleTimelock;

    // ====================================================
    // 🔹 Events
    // ====================================================
    event RoleConfigured(bytes32 indexed role, uint256 requirement, bytes32 parentRole);
    event RoleGrantedWithMetadata(bytes32 indexed role, address indexed account, uint256 expiration, uint256 requirement);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed revoker);
    event RoleTimelockUpdated(bytes32 indexed role, uint256 timelockDuration);

    // ====================================================
    // 🔹 Modifiers
    // ====================================================
    modifier validRole(bytes32 role) {
        require(_isValidRole(role), "Invalid role identifier");
        _;
    }

    modifier activeRole(bytes32 role, address account) {
        require(_isActiveRole(role, account), "Role not active");
        _;
    }

    modifier roleTimelocked(bytes32 role) {
        require(
            block.timestamp >= _roleTimelock[role],
            "Role change timelocked"
        );
        _;
    }

    // ====================================================
    // 🔹 Constructor & Initializer
    // ====================================================
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address tStakeToken) external initializer {
        require(admin != address(0) && tStakeToken != address(0), "Invalid addresses");

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _tStakeToken = IERC20(tStakeToken);
        _setupInitialRoles(admin);
    }

    // ====================================================
    // 🔹 Core Role Management Functions
    // ====================================================
    function configureRole(
        bytes32 role,
        uint256 requirement,
        bytes32 parentRole
    ) external onlyRole(DEFAULT_ADMIN_ROLE) validRole(role) {
        require(
            parentRole == bytes32(0) || _isValidRole(parentRole),
            "Invalid parent role"
        );

        _roleData[role][address(0)] = RoleData({
            requirement: requirement,
            expiration: 0,
            parentRole: parentRole,
            isActive: true
        });

        emit RoleConfigured(role, requirement, parentRole);
    }

    function grantRole(
        bytes32 role,
        address account,
        uint256 duration
    ) external onlyRole(DEFAULT_ADMIN_ROLE) validRole(role) roleTimelocked(role) nonReentrant {
        require(account != address(0), "Invalid account");
        require(duration > 0, "Invalid duration");

        RoleData storage roleConfig = _roleData[role][address(0)];
        require(roleConfig.isActive, "Role not active");

        if (roleConfig.requirement > 0) {
            require(
                _tStakeToken.balanceOf(account) >= roleConfig.requirement,
                "Insufficient TSTAKE balance"
            );
        }

        _roleData[role][account] = RoleData({
            requirement: roleConfig.requirement,
            expiration: block.timestamp + duration,
            parentRole: roleConfig.parentRole,
            isActive: true
        });

        _grantRole(role, account);
        _roleTimelock[role] = block.timestamp + 1 days; // 1-Day timelock for new grants

        emit RoleGrantedWithMetadata(role, account, block.timestamp + duration, roleConfig.requirement);
    }

    function revokeRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) validRole(role) roleTimelocked(role) {
        _roleData[role][account].isActive = false;
        _revokeRole(role, account);
        _roleTimelock[role] = block.timestamp + 1 days; // Timelock prevents immediate reassignments

        emit RoleRevoked(role, account, msg.sender);
    }

    // ====================================================
    // 🔹 Role Validation & Security
    // ====================================================
    function validateRole(bytes32 role, address account) external view returns (bool) {
        return _isActiveRole(role, account);
    }

    function getRoleData(bytes32 role, address account) external view returns (uint256, uint256, bytes32, bool) {
        RoleData storage data = _roleData[role][account];
        return (data.requirement, data.expiration, data.parentRole, data.isActive);
    }

    function updateRoleTimelock(bytes32 role, uint256 timelockDuration) external onlyRole(GOVERNANCE_ROLE) {
        require(timelockDuration <= 7 days, "Timelock too long");
        _roleTimelock[role] = block.timestamp + timelockDuration;
        emit RoleTimelockUpdated(role, timelockDuration);
    }

    // ====================================================
    // 🔹 Internal Helper Functions
    // ====================================================
    function _setupInitialRoles(address admin) private {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function _isValidRole(bytes32 role) private pure returns (bool) {
        return role != bytes32(0);
    }

    function _isActiveRole(bytes32 role, address account) private view returns (bool) {
        if (!hasRole(role, account)) return false;

        RoleData storage data = _roleData[role][account];
        return data.isActive && (data.expiration == 0 || block.timestamp < data.expiration);
    }
}
