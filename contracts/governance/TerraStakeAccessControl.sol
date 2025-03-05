// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts-upgradeable-5.0/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable-5.0/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable-5.0/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable-5.0/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-5.0/token/ERC20/IERC20.sol";
import "./interfaces/ITerraStakeAccessControl.sol";

/**
 * @title TerraStakeAccessControl
 * @notice Centralized Role-Based Access Control for TerraStake
 * @dev Implements hierarchical permissioning, role time-locks, and governance-controlled security measures.
 */
contract TerraStakeAccessControl is
    ITerraStakeAccessControl,
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // ====================================================
    // 🔹 Constants
    // ====================================================
    // Maximum role duration set to 100 years to prevent timestamp overflow
    uint256 private constant MAX_ROLE_DURATION = 100 * 365 days;
    
    // ====================================================
    // 🔹 State Variables
    // ====================================================
    IERC20 private _tStakeToken;
    IERC20 private _usdc;
    IERC20 private _weth;
    AggregatorV3Interface private _priceFeed;
    
    // Role definitions (Optimized for Gas Efficiency)
    bytes32 public constant override MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant override GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant override EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant override LIQUIDITY_MANAGER_ROLE = keccak256("LIQUIDITY_MANAGER_ROLE");
    bytes32 public constant override VESTING_MANAGER_ROLE = keccak256("VESTING_MANAGER_ROLE");
    bytes32 public constant override UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant override PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant override MULTISIG_ADMIN_ROLE = keccak256("MULTISIG_ADMIN_ROLE");
    bytes32 public constant override REWARD_MANAGER_ROLE = keccak256("REWARD_MANAGER_ROLE");
    bytes32 public constant override DISTRIBUTION_ROLE = keccak256("DISTRIBUTION_ROLE");
    
    // Price and liquidity constraints
    uint256 private _minimumLiquidity;
    uint256 private _minimumPrice;
    uint256 private _maximumPrice;
    uint256 private _maxOracleDataAge;
    
    // Role configuration mappings
    mapping(bytes32 => uint256) private _roleRequirements;
    mapping(bytes32 => mapping(address => uint256)) private _roleExpirations;
    mapping(bytes32 => bytes32) private _roleHierarchy;
    
    // Role hierarchy documentation
    mapping(bytes32 => RoleInfo) private _roleInfo;
    
    // ====================================================
    // 🔹 Errors
    // ====================================================
    error InvalidAddress();
    error InvalidDuration();
    error InvalidParameters();
    error InsufficientTStakeBalance(address account, uint256 requiredBalance);
    error InvalidHierarchy(bytes32 role, bytes32 parentRole);
    error RoleAlreadyAssigned(bytes32 role, address account);
    error OracleValidationFailed();
    error PriceOutOfBounds(uint256 price, uint256 minPrice, uint256 maxPrice);
    error LiquidityThresholdNotMet();
    error RoleNotAssigned(bytes32 role, address account);
    error StaleOracleData(uint256 lastUpdate, uint256 currentTime);
    error InvalidOracleRound(uint80 answeredInRound, uint80 roundId);
    error DurationTooLong(uint256 duration, uint256 maxDuration);

    // ====================================================
    // 🔹 Constructor & Initializer
    // ====================================================
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address priceOracle,
        address usdcToken,
        address wethToken,
        address tStakeToken,
        uint256 minimumLiquidity,
        uint256 minimumPrice,
        uint256 maximumPrice,
        uint256 maxOracleDataAge
    ) external override initializer {
        if (admin == address(0) || tStakeToken == address(0) || 
            priceOracle == address(0) || usdcToken == address(0) || 
            wethToken == address(0)) revert InvalidAddress();
            
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        
        _tStakeToken = IERC20(tStakeToken);
        _usdc = IERC20(usdcToken);
        _weth = IERC20(wethToken);
        _priceFeed = AggregatorV3Interface(priceOracle);
        _minimumLiquidity = minimumLiquidity;
        _minimumPrice = minimumPrice;
        _maximumPrice = maximumPrice;
        _maxOracleDataAge = maxOracleDataAge;
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ====================================================
    // 🔹 Core Role Management Functions
    // ====================================================
    function grantRoleWithExpiration(
        bytes32 role, 
        address account, 
        uint256 duration
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant whenNotPaused {
        if (account == address(0)) revert InvalidAddress();
        if (duration == 0) revert InvalidDuration();
        if (duration > MAX_ROLE_DURATION) revert DurationTooLong(duration, MAX_ROLE_DURATION);
        
        // Check if account already has this role
        if (hasRole(role, account)) {
            // Update expiration time instead of granting again
            _roleExpirations[role][account] = block.timestamp + duration;
            emit RoleGrantedWithExpiration(role, account, block.timestamp + duration);
            return;
        }
        
        // Token requirement validation
        if (_roleRequirements[role] > 0) {
            uint256 requiredBalance = _roleRequirements[role];
            uint256 currentBalance = _tStakeToken.balanceOf(account);
            if (currentBalance < requiredBalance) {
                revert InsufficientTStakeBalance(account, requiredBalance);
            }
        }
        
        // Hierarchy validation
        bytes32 parentRole = _roleHierarchy[role];
        if (parentRole != bytes32(0) && !hasRole(parentRole, account)) {
            revert InvalidHierarchy(role, parentRole);
        }
        
        // Set expiration
        _roleExpirations[role][account] = block.timestamp + duration;
        
        // Grant role
        _grantRole(role, account);
        
        emit RoleGrantedWithExpiration(role, account, block.timestamp + duration);
    }
    
    function grantRoleBatch(
        bytes32[] calldata roles, 
        address account, 
        uint256[] calldata durations
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant whenNotPaused {
        if (roles.length != durations.length) revert InvalidParameters();
        if (account == address(0)) revert InvalidAddress();
        
        for (uint256 i = 0; i < roles.length; i++) {
            // Call internal version to avoid repeated access control checks
            _grantRoleWithExpiration(roles[i], account, durations[i]);
        }
    }
    
    // Internal helper function for batch operations
    function _grantRoleWithExpiration(bytes32 role, address account, uint256 duration) internal {
        if (duration == 0) revert InvalidDuration();
        if (duration > MAX_ROLE_DURATION) revert DurationTooLong(duration, MAX_ROLE_DURATION);
        
        // Check if account already has this role
        if (hasRole(role, account)) {
            // Update expiration time instead of granting again
            _roleExpirations[role][account] = block.timestamp + duration;
            emit RoleGrantedWithExpiration(role, account, block.timestamp + duration);
            return;
        }
        
        // Token requirement validation
        if (_roleRequirements[role] > 0) {
            uint256 requiredBalance = _roleRequirements[role];
            uint256 currentBalance = _tStakeToken.balanceOf(account);
            if (currentBalance < requiredBalance) {
                revert InsufficientTStakeBalance(account, requiredBalance);
            }
        }
        
        // Hierarchy validation
        bytes32 parentRole = _roleHierarchy[role];
        if (parentRole != bytes32(0) && !hasRole(parentRole, account)) {
            revert InvalidHierarchy(role, parentRole);
        }
        
        // Set expiration
        _roleExpirations[role][account] = block.timestamp + duration;
        
        // Grant role
        _grantRole(role, account);
        
        emit RoleGrantedWithExpiration(role, account, block.timestamp + duration);
    }
    
    function setRoleRequirement(
        bytes32 role, 
        uint256 requirement
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        uint256 oldRequirement = _roleRequirements[role];
        _roleRequirements[role] = requirement;
        
        // Update the role info documentation as well
        if (_roleInfo[role].id == role) {
            _roleInfo[role].requirement = requirement;
        }
        
        emit RoleRequirementUpdated(role, oldRequirement, requirement);
    }
    
    function grantRole(
        bytes32 role, 
        address account
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant whenNotPaused {
        // For consistency, we'll use a standard duration of 1 year
        uint256 standardDuration = 365 days;
        
        // For consistency, we'll update the expiration if the role is already granted
        if (hasRole(role, account)) {
            _roleExpirations[role][account] = block.timestamp + standardDuration;
            emit RoleGrantedWithExpiration(role, account, block.timestamp + standardDuration);
            return;
        }
        
        // Default to a year if granting without expiration
        _grantRoleWithExpiration(role, account, standardDuration);
    }
    
    function revokeRole(
        bytes32 role, 
        address account
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (!hasRole(role, account)) revert RoleNotAssigned(role, account);
        
        _revokeRole(role, account);
        _roleExpirations[role][account] = 0;
                emit RoleRevoked(role, account);
    }
    /**
     * @notice Allows users to renounce their own roles
     * @dev Does not require admin permission since users are giving up privileges
     * @param role The role to renounce
     */
    function renounceOwnRole(bytes32 role) external nonReentrant {
        if (!hasRole(role, msg.sender)) revert RoleNotAssigned(role, msg.sender);
        
        _revokeRole(role, msg.sender);
        _roleExpirations[role][msg.sender] = 0;
        
        emit RoleRenounced(role, msg.sender);
    }
    /**
     * @notice Checks if a role is expired and automatically revokes it if needed
     * @param role The role to check
     * @param account The address to check
     */
    function checkAndHandleExpiredRole(bytes32 role, address account) external override nonReentrant {
        if (!hasRole(role, account)) revert RoleNotAssigned(role, account);
        
        uint256 expiration = _roleExpirations[role][account];
        
        // If the role has an expiration and it's in the past, revoke it
        if (expiration != 0 && block.timestamp > expiration) {
            _revokeRole(role, account);
            _roleExpirations[role][account] = 0;
            
            emit RoleRevoked(role, account);
        }
    }
    // ====================================================
    // 🔹 Role Documentation Functions
    // ====================================================
    
    /**
     * @notice Documents a role with its description and relationship
     * @param role The role to document
     * @param description Human-readable description of the role's purpose
     */
    function documentRole(
        bytes32 role,
        string calldata description
    ) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        _roleInfo[role] = RoleInfo({
            id: role,
            parent: _roleHierarchy[role],
            description: description,
            requirement: _roleRequirements[role]
        });
        
        emit RoleDocumented(role, description);
    }
    /**
     * @notice Get detailed information about a role
     * @param role The role to query
     * @return Role information including hierarchy and description
     */
    function getRoleInfo(bytes32 role) external view returns (RoleInfo memory) {
        return _roleInfo[role];
    }
    // ====================================================
    // 🔹 Oracle and Configuration Updates
    // ====================================================
    function updatePriceOracle(
        address newOracle
    ) external override onlyRole(GOVERNANCE_ROLE) nonReentrant {
        if (newOracle == address(0)) revert InvalidAddress();
        
        address oldOracle = address(_priceFeed);
        _priceFeed = AggregatorV3Interface(newOracle);
        
        emit OracleUpdated(oldOracle, newOracle);
    }
    
    function updateLiquidityThreshold(uint256 newThreshold) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        uint256 oldThreshold = _minimumLiquidity;
        _minimumLiquidity = newThreshold;
        
        emit LiquidityThresholdUpdated(oldThreshold, newThreshold);
    }
    
    function updatePriceBounds(
        uint256 newMinPrice,
        uint256 newMaxPrice
    ) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        if (newMinPrice >= newMaxPrice) revert InvalidParameters();
        
        uint256 oldMinPrice = _minimumPrice;
        uint256 oldMaxPrice = _maximumPrice;
        _minimumPrice = newMinPrice;
        _maximumPrice = newMaxPrice;
        
        emit PriceBoundsUpdated(oldMinPrice, oldMaxPrice, newMinPrice, newMaxPrice);
    }
    
    function setRoleHierarchy(
        bytes32 role,
        bytes32 parentRole
    ) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        _roleHierarchy[role] = parentRole;
        
        // Update the role info documentation as well
        if (_roleInfo[role].id == role) {
            _roleInfo[role].parent = parentRole;
        }
        
        emit RoleHierarchyUpdated(role, parentRole);
    }
    /**
     * @notice Set the maximum allowed age for oracle data
     * @param maxAgeInSeconds Maximum age in seconds for oracle data to be considered valid
     */
    function setMaxOracleDataAge(uint256 maxAgeInSeconds) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        uint256 oldAge = _maxOracleDataAge;
        _maxOracleDataAge = maxAgeInSeconds;
        
        emit OracleDataAgeUpdated(oldAge, maxAgeInSeconds);
    }
    /**
     * @notice Update token configuration for the system
     * @param token The token address to configure
     * @param tokenType The type identifier for the token (e.g. "staking", "reward", "governance")
     */
    function updateTokenConfiguration(address token, string calldata tokenType) external override onlyRole(GOVERNANCE_ROLE) nonReentrant {
        if (token == address(0)) revert InvalidAddress();
        
        // Determine which token to update based on the type
        bytes32 tokenTypeHash = keccak256(abi.encodePacked(tokenType));
        
        if (tokenTypeHash == keccak256(abi.encodePacked("staking"))) {
            _tStakeToken = IERC20(token);
        } else if (tokenTypeHash == keccak256(abi.encodePacked("usdc"))) {
            _usdc = IERC20(token);
        } else if (tokenTypeHash == keccak256(abi.encodePacked("weth"))) {
            _weth = IERC20(token);
        } else {
            revert InvalidParameters();
        }
        
        emit TokenConfigurationUpdated(token, tokenType);
    }
    // ====================================================
    // 🔹 Pausing Functions
    // ====================================================
    function pause() external override onlyRole(PAUSER_ROLE) nonReentrant {
        _pause();
    }
    
    function unpause() external override onlyRole(GOVERNANCE_ROLE) nonReentrant {
        _unpause();
    }
    // ====================================================
    // 🔹 Validation Functions
    // ====================================================
    function validateWithTStakeSnapshot(
        address account,
        uint256 requiredBalance
    ) external view override {
        if (_tStakeToken.balanceOf(account) < requiredBalance) {
            revert InsufficientTStakeBalance(account, requiredBalance);
        }
    }
    
    function validateWithOracle(
        uint256 expectedPrice
    ) external view override {
        (, int256 price, , ,) = _priceFeed.latestRoundData();
        
        if (price <= 0) revert OracleValidationFailed();
        
        uint256 priceUint = uint256(price);
        if (priceUint < _minimumPrice || priceUint > _maximumPrice) {
            revert PriceOutOfBounds(priceUint, _minimumPrice, _maximumPrice);
        }
        
        // Allow 5% deviation
        uint256 lowerBound = expectedPrice * 95 / 100;
        uint256 upperBound = expectedPrice * 105 / 100;
        
        if (priceUint < lowerBound || priceUint > upperBound) {
            revert PriceOutOfBounds(priceUint, lowerBound, upperBound);
        }
    }
    /**
     * @notice Enhanced oracle validation with timestamp and round checks
     * @param expectedPrice The expected price for validation
     */
    function validateWithOracleAndTimestamp(
        uint256 expectedPrice
    ) external view override {
        (
            uint80 roundId,
            int256 price,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = _priceFeed.latestRoundData();
        
        // Validate data freshness
        if (_maxOracleDataAge > 0 && block.timestamp - updatedAt > _maxOracleDataAge) {
            revert StaleOracleData(updatedAt, block.timestamp);
        }
        
        // Validate round consistency
        if (answeredInRound < roundId) {
            revert InvalidOracleRound(answeredInRound, roundId);
        }
        
        if (price <= 0) revert OracleValidationFailed();
        
        uint256 priceUint = uint256(price);
        if (priceUint < _minimumPrice || priceUint > _maximumPrice) {
            revert PriceOutOfBounds(priceUint, _minimumPrice, _maximumPrice);
        }
        
        // Allow 5% deviation
        uint256 lowerBound = expectedPrice * 95 / 100;
        uint256 upperBound = expectedPrice * 105 / 100;
        
        if (priceUint < lowerBound || priceUint > upperBound) {
            revert PriceOutOfBounds(priceUint, lowerBound, upperBound);
        }
    }
    
    function validateLiquidityThreshold() external view override {
        uint256 totalLiquidity = _tStakeToken.balanceOf(address(this));
        if (totalLiquidity < _minimumLiquidity) {
            revert LiquidityThresholdNotMet();
        }
    }
    // ====================================================
    // 🔹 View Functions
    // ====================================================
    function roleRequirements(bytes32 role) external view override returns (uint256) {
        return _roleRequirements[role];
    }
    
    function roleExpirations(bytes32 role, address account) external view override returns (uint256) {
        return _roleExpirations[role][account];
    }
    
    function priceFeed() external view override returns (AggregatorV3Interface) {
        return _priceFeed;
    }
    
    function usdc() external view override returns (IERC20) {
        return _usdc;
    }
    
    function weth() external view override returns (IERC20) {
        return _weth;
    }
    
    function tStakeToken() external view override returns (IERC20) {
        return _tStakeToken;
    }
    
    function hasValidRole(bytes32 role, address account) external view override returns (bool) {
        return hasRole(role, account) && isActiveRole(role, account);
    }
    
    function isActiveRole(bytes32 role, address account) public view override returns (bool) {
        if (!hasRole(role, account)) return false;
        
        uint256 expiration = _roleExpirations[role][account];
        if (expiration != 0 && block.timestamp > expiration) {
            return false;
        }
        
        return true;
    }
    
    function getRoleHierarchy(bytes32 role) external view override returns (bytes32) {
        return _roleHierarchy[role];
    }
    /**
     * @notice Returns the maximum allowed age for oracle data
     * @return Maximum age in seconds
     */
    function maxOracleDataAge() external view override returns (uint256) {
        return _maxOracleDataAge;
    }
    
    /**
     * @notice Returns the maximum allowed role duration
     * @return Maximum role duration in seconds
     */
    function getMaxRoleDuration() external pure returns (uint256) {
        return MAX_ROLE_DURATION;
    }
}
