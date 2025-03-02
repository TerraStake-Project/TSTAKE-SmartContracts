// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title ITerraStakeMetadataRenderer
 * @notice Interface for the TerraStakeMetadataRenderer contract that generates visual NFT metadata
 * @dev Designed for upgradeability using UUPS pattern
 */
interface ITerraStakeMetadataRenderer {
    /**
     * @notice Role constant for contracts allowed to interact with projects
     * @return The keccak256 hash of "PROJECTS_CONTRACT_ROLE"
     */
    function PROJECTS_CONTRACT_ROLE() external view returns (bytes32);

    /**
     * @notice Role constant for addresses allowed to upgrade the contract
     * @return The keccak256 hash of "UPGRADER_ROLE"
     */
    function UPGRADER_ROLE() external view returns (bytes32);

    /**
     * @notice Default admin role constant
     * @return The bytes32 representation of the default admin role
     */
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);

    /**
     * @notice Update the color palette for a category
     * @param category The category index
     * @param colors New comma-separated color values
     */
    function setCategoryColors(uint8 category, string calldata colors) external;
    
    /**
     * @notice Update the icon for a category
     * @param category The category index
     * @param svgPath New SVG path data
     */
    function setCategoryIcon(uint8 category, string calldata svgPath) external;
    
    /**
     * @notice Generate dynamic SVG based on impact metrics
     * @param category The project category
     * @param impactValue The primary impact metric value
     * @param impactName The name of the impact metric
     * @param impactScale The calculated impact scale
     * @return SVG image data as a Base64-encoded string
     */
    function generateSVG(
        uint8 category,
        uint256 impactValue,
        string memory impactName,
        string memory impactScale
    ) external view returns (string memory);
    
    /**
     * @notice Get the current color palette for a category
     * @param category The category index
     * @return The comma-separated color values
     */
    function categoryColors(uint8 category) external view returns (string memory);
    
    /**
     * @notice Get the current icon for a category
     * @param category The category index
     * @return The SVG path data
     */
    function categoryIcons(uint8 category) external view returns (string memory);

    /**
     * @notice Function to initialize the contract when used with a proxy
     * @param admin Address that will have administrative rights
     * @dev This replaces the constructor for upgradeable contracts
     */
    function initialize(address admin) external;
    
    /**
     * @notice Authorizes an upgrade to a new implementation
     * @param newImplementation Address of the new implementation
     * @dev Only callable by addresses with the upgrader role
     */
    function upgradeTo(address newImplementation) external;
    
    /**
     * @notice Authorizes an upgrade to a new implementation and calls a function
     * @param newImplementation Address of the new implementation
     * @param data Function call data to be used in upgradeToAndCall
     * @dev Only callable by addresses with the upgrader role
     */
    function upgradeToAndCall(address newImplementation, bytes memory data) external payable;
    
    /**
     * @notice Checks if the contract supports an interface
     * @param interfaceId Interface identifier (ERC165)
     * @return True if the interface is supported
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
    
    /**
     * @notice Grants the upgrader role to an account
     * @param account Address receiving the role
     * @dev Only callable by admin
     */
    function grantUpgraderRole(address account) external;
    
    /**
     * @notice Revokes the upgrader role from an account
     * @param account Address losing the role
     * @dev Only callable by admin
     */
    function revokeUpgraderRole(address account) external;

    /**
     * @notice Grants a role to an account
     * @param role The role being granted
     * @param account The account receiving the role
     * @dev Only callable by role admin
     */
    function grantRole(bytes32 role, address account) external;

    /**
     * @notice Revokes a role from an account
     * @param role The role being revoked
     * @param account The account losing the role
     * @dev Only callable by role admin
     */
    function revokeRole(bytes32 role, address account) external;

    /**
     * @notice Renounces a role
     * @param role The role being renounced
     * @param account The account renouncing the role
     */
    function renounceRole(bytes32 role, address account) external;

    /**
     * @notice Checks if an account has a specific role
     * @param role The role to check
     * @param account The account to check
     * @return True if the account has the role
     */
    function hasRole(bytes32 role, address account) external view returns (bool);

    /**
     * @notice Gets the admin role for a specific role
     * @param role The role to get the admin for
     * @return The admin role
     */
    function getRoleAdmin(bytes32 role) external view returns (bytes32);
    
    // Events
    
    /**
     * @notice Emitted when a category's colors are updated
     * @param category The category that was updated
     * @param colors The new colors assigned
     */
    event CategoryColorsUpdated(uint8 indexed category, string colors);
    
    /**
     * @notice Emitted when a category's icon is updated
     * @param category The category that was updated
     * @param svgPath The new SVG path assigned
     */
    event CategoryIconUpdated(uint8 indexed category, string svgPath);
    
    /**
     * @notice Emitted when an upgrade is performed
     * @param implementation The address of the new implementation
     */
    event Upgraded(address indexed implementation);
    
    /**
     * @notice Emitted when a role is granted
     * @param role The role that was granted
     * @param account The account that received the role
     * @param sender The account that granted the role
     */
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    
    /**
     * @notice Emitted when a role is revoked
     * @param role The role that was revoked
     * @param account The account that lost the role
     * @param sender The account that revoked the role
     */
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    /**
     * @notice Emitted when the implementation is initialized
     * @param version Version number
     */
    event Initialized(uint8 version);
}
