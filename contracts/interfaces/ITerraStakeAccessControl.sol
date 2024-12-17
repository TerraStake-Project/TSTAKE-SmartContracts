// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ITerraStakeAccessControl {
    // Custom Errors
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

    // Role Identifiers
    function MINTER_ROLE() external view returns (bytes32);
    function PROJECT_MANAGER_ROLE() external view returns (bytes32);
    function GOVERNANCE_ROLE() external view returns (bytes32);
    function VETO_ROLE() external view returns (bytes32);
    function UPGRADER_ROLE() external view returns (bytes32);
    function PAUSER_ROLE() external view returns (bytes32);
    function MULTISIG_ADMIN_ROLE() external view returns (bytes32);
    function REWARD_MANAGER_ROLE() external view returns (bytes32);
    function DISTRIBUTION_ROLE() external view returns (bytes32);
    function VESTING_MANAGER_ROLE() external view returns (bytes32);
    function EMERGENCY_ROLE() external view returns (bytes32);

    // Administrative Functions
    function initialize(
        address admin,
        address priceOracle,
        address usdcToken,
        address wethToken
    ) external;

    function grantRoleWithExpiration(bytes32 role, address account, uint256 duration) external;

    function grantRoleBatch(bytes32[] calldata roles, address account) external;

    function setRoleRequirement(bytes32 role, uint256 requirement) external;

    function grantRole(bytes32 role, address account) external;

    function revokeRole(bytes32 role, address account) external;

    function updatePriceOracle(address newOracle) external;

    // Validation Functions
    function validateWithOracle(uint256 expectedPrice) external view;

    // View Functions
    function roleRequirements(bytes32 role) external view returns (uint256);

    function roleExpirations(bytes32 role, address account) external view returns (uint256);

    function priceFeed() external view returns (AggregatorV3Interface);

    function usdc() external view returns (IERC20);

    function weth() external view returns (IERC20);

    function hasValidRole(bytes32 role, address account) external view returns (bool);

    function getRoleMemberCount(bytes32 role) external view returns (uint256);
}