// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TerraStakeAccessControl is Initializable, AccessControlUpgradeable {
    // Role identifiers
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PROJECT_MANAGER_ROLE = keccak256("PROJECT_MANAGER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant VETO_ROLE = keccak256("VETO_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MULTISIG_ADMIN_ROLE = keccak256("MULTISIG_ADMIN_ROLE");
    bytes32 public constant REWARD_MANAGER_ROLE = keccak256("REWARD_MANAGER_ROLE");
    bytes32 public constant DISTRIBUTION_ROLE = keccak256("DISTRIBUTION_ROLE");
    bytes32 public constant VESTING_MANAGER_ROLE = keccak256("VESTING_MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // Role management mappings
    mapping(bytes32 => uint256) public roleRequirements;
    mapping(bytes32 => mapping(address => uint256)) public roleExpirations;
    mapping(bytes32 => uint256) private _roleMemberCount;

    // Oracle and token references
    AggregatorV3Interface public priceFeed;
    IERC20 public usdc;
    IERC20 public weth;

    // Custom errors
    error Unauthorized();
    error InvalidAddress();
    error RoleExpired();
    error InsufficientRequirement();
    error OracleValidationFailed();

    // Events
    event MultiSigRoleGranted(bytes32 indexed role, address indexed account, uint256 timestamp);
    event RoleRequirementSet(bytes32 indexed role, uint256 requirement);
    event RoleExpirationSet(bytes32 indexed role, address indexed account, uint256 expirationTime);
    event RoleRevoked(bytes32 indexed role, address indexed account);
    event PriceOracleUpdated(address indexed oldOracle, address indexed newOracle);

    /**
     * @dev Initialize the contract with initial roles and references.
     */
    function initialize(
        address admin,
        address priceOracle,
        address usdcToken,
        address wethToken
    ) external initializer {
        if (admin == address(0)) revert InvalidAddress();
        if (priceOracle == address(0)) revert InvalidAddress();
        if (usdcToken == address(0)) revert InvalidAddress();
        if (wethToken == address(0)) revert InvalidAddress();

        __AccessControl_init();

        // Assign initial roles to admin
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(PROJECT_MANAGER_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(VETO_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(MULTISIG_ADMIN_ROLE, admin);
        _grantRole(REWARD_MANAGER_ROLE, admin);
        _grantRole(DISTRIBUTION_ROLE, admin);

        // Increment role member counts
        _incrementRoleMemberCount(DEFAULT_ADMIN_ROLE);
        _incrementRoleMemberCount(MINTER_ROLE);
        _incrementRoleMemberCount(PROJECT_MANAGER_ROLE);
        _incrementRoleMemberCount(GOVERNANCE_ROLE);
        _incrementRoleMemberCount(VETO_ROLE);
        _incrementRoleMemberCount(UPGRADER_ROLE);
        _incrementRoleMemberCount(PAUSER_ROLE);
        _incrementRoleMemberCount(MULTISIG_ADMIN_ROLE);
        _incrementRoleMemberCount(REWARD_MANAGER_ROLE);
        _incrementRoleMemberCount(DISTRIBUTION_ROLE);

        // Set token and oracle references
        priceFeed = AggregatorV3Interface(priceOracle);
        usdc = IERC20(usdcToken);
        weth = IERC20(wethToken);
    }

    /**
     * @dev Grants a role to an account with a specified expiration time.
     */
    function grantRoleWithExpiration(bytes32 role, address account, uint256 duration)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (account == address(0)) revert InvalidAddress();
        grantRole(role, account);

        uint256 expirationTime = block.timestamp + duration;
        roleExpirations[role][account] = expirationTime;

        emit RoleExpirationSet(role, account, expirationTime);
    }

    /**
     * @dev Validates the price using the oracle.
     */
    function validateWithOracle(uint256 expectedPrice) public view {
        (, int256 answer, , , ) = priceFeed.latestRoundData();
        if (answer <= 0 || uint256(answer) != expectedPrice) revert OracleValidationFailed();
    }

    /**
     * @dev Grants multiple roles to a single account in one transaction.
     */
    function grantRoleBatch(bytes32[] calldata roles, address account)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (account == address(0)) revert InvalidAddress();

        for (uint256 i = 0; i < roles.length; i++) {
            grantRole(roles[i], account);
        }
    }

    /**
     * @dev Sets the requirement for a role.
     */
    function setRoleRequirement(bytes32 role, uint256 requirement)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        roleRequirements[role] = requirement;
        emit RoleRequirementSet(role, requirement);
    }

    /**
     * @dev Grants a role and increments the role member count.
     */
    function grantRole(bytes32 role, address account)
        public
        override(AccessControlUpgradeable)
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (account == address(0)) revert InvalidAddress();
        if (!hasRole(role, account)) {
            _incrementRoleMemberCount(role);
        }
        super.grantRole(role, account);
    }

    /**
     * @dev Revokes a role and decrements the role member count.
     */
    function revokeRole(bytes32 role, address account)
        public
        override(AccessControlUpgradeable)
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (account == address(0)) revert InvalidAddress();
        if (hasRole(role, account)) {
            _decrementRoleMemberCount(role);
            emit RoleRevoked(role, account);
        }
        super.revokeRole(role, account);
    }

    /**
     * @dev Checks if a role is valid and not expired for a given account.
     */
    function hasValidRole(bytes32 role, address account) public view returns (bool) {
        if (!hasRole(role, account)) return false;

        uint256 expiration = roleExpirations[role][account];
        if (expiration == 0) return true;
        return block.timestamp <= expiration;
    }

    /**
     * @dev Returns the number of members for a given role.
     */
    function getRoleMemberCount(bytes32 role) public view returns (uint256) {
        return _roleMemberCount[role];
    }

    /**
     * @dev Updates the price oracle.
     */
    function updatePriceOracle(address newOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newOracle == address(0)) revert InvalidAddress();

        address oldOracle = address(priceFeed);
        priceFeed = AggregatorV3Interface(newOracle);

        emit PriceOracleUpdated(oldOracle, newOracle);
    }

    /**
     * @dev Increments the member count for a role.
     */
    function _incrementRoleMemberCount(bytes32 role) private {
        _roleMemberCount[role] += 1;
    }

    /**
     * @dev Decrements the member count for a role.
     */
    function _decrementRoleMemberCount(bytes32 role) private {
        _roleMemberCount[role] -= 1;
    }
}
