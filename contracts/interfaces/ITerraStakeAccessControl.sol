// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ITerraStakeAccessControl
 * @notice Interface for TerraStake's centralized role-based access control
 * @dev Defines the contract API for role management and security validation
 */
interface ITerraStakeAccessControl {
    // ====================================================
    //  Role Constants
    // ====================================================
    function MINTER_ROLE() external view returns (bytes32);
    function GOVERNANCE_ROLE() external view returns (bytes32);
    function EMERGENCY_ROLE() external view returns (bytes32);
    function LIQUIDITY_MANAGER_ROLE() external view returns (bytes32);
    function VESTING_MANAGER_ROLE() external view returns (bytes32);
    function UPGRADER_ROLE() external view returns (bytes32);
    function PAUSER_ROLE() external view returns (bytes32);
    function MULTISIG_ADMIN_ROLE() external view returns (bytes32);
    function REWARD_MANAGER_ROLE() external view returns (bytes32);
    function DISTRIBUTION_ROLE() external view returns (bytes32);
    
    // ====================================================
    //  Structs
    // ====================================================
    struct RoleInfo {
        bytes32 id;           // Role identifier
        bytes32 parent;       // Parent role in hierarchy (if any)
        string description;   // Human-readable description
        uint256 requirement;  // Token requirement for role
    }
    
    // ====================================================
    //  Events
    // ====================================================
    event RoleGrantedWithExpiration(bytes32 indexed role, address indexed account, uint256 expiration);
    event RoleRequirementUpdated(bytes32 indexed role, uint256 oldRequirement, uint256 newRequirement);
    event RoleRequirementSet(bytes32 indexed role, uint256 requirement);
    event RoleRevoked(bytes32 indexed role, address indexed account);
    event RoleRenounced(bytes32 indexed role, address indexed account);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event LiquidityThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event PriceBoundsUpdated(uint256 oldMinPrice, uint256 oldMaxPrice, uint256 newMinPrice, uint256 newMaxPrice);
    event RoleHierarchyUpdated(bytes32 indexed role, bytes32 indexed parentRole);
    event RoleDocumented(bytes32 indexed role, string description);
    event OracleDataAgeUpdated(uint256 oldAge, uint256 newAge);
    event TokenConfigurationUpdated(address indexed token, string tokenType);
    
    // ====================================================
    //  Functions
    // ====================================================
    function initialize(
        address admin,
        address priceOracle,
        address usdcToken,
        address wethToken,
        address tStakeToken,
        address wtstkToken,   // Added for WTSTK
        address wbtcToken,    // Added for WBTC
        uint256 minimumLiquidity,
        uint256 minimumPrice,
        uint256 maximumPrice, // Added to match implementation
        uint256 maxOracleDataAge
    ) external;
    
    // Role Management
    function grantRoleWithExpiration(bytes32 role, address account, uint256 duration) external;
    function grantRoleBatch(bytes32[] calldata roles, address account, uint256[] calldata durations) external;
    function setRoleRequirement(bytes32 role, uint256 requirement) external;
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
    function renounceOwnRole(bytes32 role) external;
    function documentRole(bytes32 role, string calldata description) external;
    function getRoleInfo(bytes32 role) external view returns (RoleInfo memory);
    function checkAndHandleExpiredRole(bytes32 role, address account) external;
    
    // Configuration Updates
    function updatePriceOracle(address newOracle) external;
    function updateLiquidityThreshold(uint256 newThreshold) external;
    function updatePriceBounds(uint256 newMinPrice, uint256 newMaxPrice) external;
    function setRoleHierarchy(bytes32 role, bytes32 parentRole) external;
    function setMaxOracleDataAge(uint256 maxAgeInSeconds) external;
    function setRoleRequirementToken(bytes32 role, address token) external; // Added for token flexibility
    
    // System Control
    function pause() external;
    function unpause() external;
    
    // Validations
    function validateWithTStakeSnapshot(address account, uint256 requiredBalance) external view;
    function validateWithOracle(uint256 expectedPrice) external view;
    function validateWithOracleAndTimestamp(uint256 expectedPrice) external view;
    function validateLiquidityThreshold() external view;
    
    // View Functions
    function roleRequirements(bytes32 role) external view returns (uint256);
    function roleExpirations(bytes32 role, address account) external view returns (uint256);
    function priceFeed() external view returns (AggregatorV3Interface);
    function usdc() external view returns (IERC20);
    function weth() external view returns (IERC20);
    function tStakeToken() external view returns (IERC20);
    function wtstk() external view returns (IERC20); // Added for WTSTK
    function wbtc() external view returns (IERC20);  // Added for WBTC
    function hasValidRole(bytes32 role, address account) external view returns (bool);
    function isActiveRole(bytes32 role, address account) external view returns (bool);
    function getRoleHierarchy(bytes32 role) external view returns (bytes32);
    function maxOracleDataAge() external view returns (uint256);
    function getMaxRoleDuration() external pure returns (uint256); // Added to match implementation
}
