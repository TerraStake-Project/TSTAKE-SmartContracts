// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ITerraStakeAccessControl {
    // Custom Errors
    error Unauthorized();
    error InvalidAddress();
    error RoleExpired(bytes32 role, address account);
    error OracleValidationFailed();
    error InsufficientRequirements(bytes32 role, address account);
    error InvalidHierarchy(bytes32 role, bytes32 parentRole);
    error InvalidDuration();
    error PriceOutOfBounds(uint256 price, uint256 min, uint256 max);

    // Events
    event RoleGrantedWithExpiration(bytes32 indexed role, address indexed account, uint256 expirationTime);
    event RoleRequirementSet(bytes32 indexed role, uint256 requirement);
    event RoleRevoked(bytes32 indexed role, address indexed account);
    event PriceBoundsUpdated(uint256 oldMinPrice, uint256 oldMaxPrice, uint256 newMinPrice, uint256 newMaxPrice);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event RoleHierarchyUpdated(bytes32 indexed role, bytes32 indexed parentRole);
    event TokenConfigurationUpdated(address indexed token, string tokenType);
    event RoleRequirementUpdated(bytes32 indexed role, uint256 oldRequirement, uint256 newRequirement);
    event LiquidityThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    // Role Identifiers
    function MINTER_ROLE() external pure returns (bytes32);
    function GOVERNANCE_ROLE() external pure returns (bytes32);
    function EMERGENCY_ROLE() external pure returns (bytes32);
    function LIQUIDITY_MANAGER_ROLE() external pure returns (bytes32);
    function VESTING_MANAGER_ROLE() external pure returns (bytes32);
    function UPGRADER_ROLE() external pure returns (bytes32);
    function PAUSER_ROLE() external pure returns (bytes32);
    function MULTISIG_ADMIN_ROLE() external pure returns (bytes32);
    function REWARD_MANAGER_ROLE() external pure returns (bytes32);
    function DISTRIBUTION_ROLE() external pure returns (bytes32);

    // Administrative Functions
    function initialize(
        address admin,
        address priceOracle,
        address usdcToken,
        address wethToken,
        uint256 minimumLiquidity,
        uint256 minimumPrice,
        uint256 maximumPrice
    ) external;

    function grantRoleWithExpiration(bytes32 role, address account, uint256 duration) external;
    function grantRoleBatch(bytes32[] calldata roles, address account) external;
    function setRoleRequirement(bytes32 role, uint256 requirement) external;
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
    function updatePriceOracle(address newOracle) external;
    function pause() external;
    function unpause() external;

    // Validation Functions
    function validateWithOracle(uint256 expectedPrice) external view;
    function validateLiquidity() external view;

    // View Functions
    function roleRequirements(bytes32 role) external view returns (uint256);
    function roleExpirations(bytes32 role, address account) external view returns (uint256);
    function priceFeed() external view returns (AggregatorV3Interface);
    function usdc() external view returns (IERC20);
    function weth() external view returns (IERC20);
    function hasValidRole(bytes32 role, address account) external view returns (bool);
    function getRoleMemberCount(bytes32 role) external view returns (uint256);
    function getRoleHierarchy(bytes32 role) external view returns (bytes32);
}
