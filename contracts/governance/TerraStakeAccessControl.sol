// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/ITerraStakeAccessControl.sol";

/**
 * @title TerraStakeAccessControl
 * @notice Optimized Role-Based Access Control for TerraStake on Arbitrum
 * @dev Implements hierarchical permissioning with WTSTK and WBTC support
 */
contract TerraStakeAccessControl is
    ITerraStakeAccessControl,
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    // ====================================================
    //  Constants
    // ====================================================
    uint256 private constant MAX_ROLE_DURATION = 100 * 365 days;
    
    // ====================================================
    //  State Variables
    // ====================================================
    IERC20 public tStakeToken;
    IERC20 public usdc;
    IERC20 public weth;
    IERC20 public wtstk;  // Wrapped Terra Stake Token
    IERC20 public wbtc;   // Wrapped Bitcoin
    AggregatorV3Interface public priceFeed;
    
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
    
    uint256 public minimumLiquidity;
    uint256 public minimumPrice;
    uint256 public maximumPrice;
    uint256 public maxOracleDataAge;
    
    mapping(bytes32 => uint256) public roleRequirements;
    mapping(bytes32 => mapping(address => uint256)) public roleExpirations;
    mapping(bytes32 => bytes32) private roleHierarchy;
    mapping(bytes32 => RoleInfo) private roleInfo;
    mapping(bytes32 => IERC20) private roleRequirementToken;
    
    // ====================================================
    //  Errors
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
    //  Constructor & Initializer
    // ====================================================
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address priceOracle,
        address usdcToken,
        address wethToken,
        address _tStakeToken,
        address _wtstkToken,
        address _wbtcToken,
        uint256 _minimumLiquidity,
        uint256 _minimumPrice,
        uint256 _maximumPrice,
        uint256 _maxOracleDataAge
    ) external initializer {
        if (admin == address(0) || _tStakeToken == address(0) || 
            priceOracle == address(0) || usdcToken == address(0) || 
            wethToken == address(0) || _wtstkToken == address(0) || 
            _wbtcToken == address(0)) revert InvalidAddress();
            
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        
        tStakeToken = IERC20(_tStakeToken);
        usdc = IERC20(usdcToken);
        weth = IERC20(wethToken);
        wtstk = IERC20(_wtstkToken);
        wbtc = IERC20(_wbtcToken);
        priceFeed = AggregatorV3Interface(priceOracle);
        minimumLiquidity = _minimumLiquidity;
        minimumPrice = _minimumPrice;
        maximumPrice = _maximumPrice;
        maxOracleDataAge = _maxOracleDataAge;
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        
        roleRequirementToken[MINTER_ROLE] = tStakeToken;
        roleRequirementToken[GOVERNANCE_ROLE] = tStakeToken;
        roleRequirementToken[EMERGENCY_ROLE] = tStakeToken;
        roleRequirementToken[LIQUIDITY_MANAGER_ROLE] = tStakeToken;
        roleRequirementToken[VESTING_MANAGER_ROLE] = tStakeToken;
        roleRequirementToken[UPGRADER_ROLE] = tStakeToken;
        roleRequirementToken[PAUSER_ROLE] = tStakeToken;
        roleRequirementToken[MULTISIG_ADMIN_ROLE] = tStakeToken;
        roleRequirementToken[REWARD_MANAGER_ROLE] = tStakeToken;
        roleRequirementToken[DISTRIBUTION_ROLE] = tStakeToken;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ====================================================
    //  Core Role Management Functions
    // ====================================================
    function grantRoleWithExpiration(
        bytes32 role, 
        address account, 
        uint256 duration
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant whenNotPaused {
        if (account == address(0)) revert InvalidAddress();
        if (duration == 0) revert InvalidDuration();
        if (duration > MAX_ROLE_DURATION) revert DurationTooLong(duration, MAX_ROLE_DURATION);
        
        uint256 expiration = block.timestamp + duration;
        if (hasRole(role, account)) {
            roleExpirations[role][account] = expiration;
            emit RoleGrantedWithExpiration(role, account, expiration);
            return;
        }
        
        uint256 required = roleRequirements[role];
        if (required > 0) {
            IERC20 token = roleRequirementToken[role];
            if (token == IERC20(address(0))) token = tStakeToken;
            if (token.balanceOf(account) < required) {
                revert InsufficientTStakeBalance(account, required);
            }
        }
        
        bytes32 parent = roleHierarchy[role];
        if (parent != bytes32(0) && !hasRole(parent, account)) {
            revert InvalidHierarchy(role, parent);
        }
        
        roleExpirations[role][account] = expiration;
        _grantRole(role, account);
        emit RoleGrantedWithExpiration(role, account, expiration);
    }
    
    function grantRoleBatch(
        bytes32[] calldata roles, 
        address account, 
        uint256[] calldata durations
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant whenNotPaused {
        if (roles.length != durations.length) revert InvalidParameters();
        if (account == address(0)) revert InvalidAddress();
        
        for (uint256 i = 0; i < roles.length; i++) {
            bytes32 role = roles[i];
            uint256 duration = durations[i];
            if (duration == 0) revert InvalidDuration();
            if (duration > MAX_ROLE_DURATION) revert DurationTooLong(duration, MAX_ROLE_DURATION);
            
            uint256 expiration = block.timestamp + duration;
            if (hasRole(role, account)) {
                roleExpirations[role][account] = expiration;
                emit RoleGrantedWithExpiration(role, account, expiration);
                continue;
            }
            
            uint256 required = roleRequirements[role];
            if (required > 0) {
                IERC20 token = roleRequirementToken[role];
                if (token == IERC20(address(0))) token = tStakeToken;
                if (token.balanceOf(account) < required) {
                    revert InsufficientTStakeBalance(account, required);
                }
            }
            
            bytes32 parent = roleHierarchy[role];
            if (parent != bytes32(0) && !hasRole(parent, account)) {
                revert InvalidHierarchy(role, parent);
            }
            
            roleExpirations[role][account] = expiration;
            _grantRole(role, account);
            emit RoleGrantedWithExpiration(role, account, expiration);
        }
    }
    
    function setRoleRequirement(
        bytes32 role, 
        uint256 requirement
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        uint256 oldRequirement = roleRequirements[role];
        roleRequirements[role] = requirement;
        
        if (roleInfo[role].id == role) {
            roleInfo[role].requirement = requirement;
        }
        
        emit RoleRequirementUpdated(role, oldRequirement, requirement);
    }
    
    function grantRole(
        bytes32 role, 
        address account
    ) public override(ITerraStakeAccessControl, AccessControlUpgradeable) onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant whenNotPaused {
        uint256 standardDuration = 365 days;
        
        if (hasRole(role, account)) {
            roleExpirations[role][account] = block.timestamp + standardDuration;
            emit RoleGrantedWithExpiration(role, account, block.timestamp + standardDuration);
            return;
        }
        
        if (account == address(0)) revert InvalidAddress();
        if (standardDuration > MAX_ROLE_DURATION) revert DurationTooLong(standardDuration, MAX_ROLE_DURATION);
        
        uint256 required = roleRequirements[role];
        if (required > 0) {
            IERC20 token = roleRequirementToken[role];
            if (token == IERC20(address(0))) token = tStakeToken;
            if (token.balanceOf(account) < required) {
                revert InsufficientTStakeBalance(account, required);
            }
        }
        
        bytes32 parent = roleHierarchy[role];
        if (parent != bytes32(0) && !hasRole(parent, account)) {
            revert InvalidHierarchy(role, parent);
        }
        
        roleExpirations[role][account] = block.timestamp + standardDuration;
        _grantRole(role, account);
        emit RoleGrantedWithExpiration(role, account, block.timestamp + standardDuration);
    }
    
    function revokeRole(
        bytes32 role, 
        address account
    ) public override(ITerraStakeAccessControl, AccessControlUpgradeable) onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (!hasRole(role, account)) revert RoleNotAssigned(role, account);
        
        _revokeRole(role, account);
        roleExpirations[role][account] = 0;
        emit RoleRevoked(role, account);
    }
    
    function renounceOwnRole(bytes32 role) external nonReentrant {
        if (!hasRole(role, msg.sender)) revert RoleNotAssigned(role, msg.sender);
        
        _revokeRole(role, msg.sender);
        roleExpirations[role][msg.sender] = 0;
        emit RoleRenounced(role, msg.sender);
    }
    
    function checkAndHandleExpiredRole(bytes32 role, address account) external override nonReentrant {
        if (!hasRole(role, account)) revert RoleNotAssigned(role, account);
        
        uint256 expiration = roleExpirations[role][account];
        if (expiration != 0 && block.timestamp > expiration) {
            _revokeRole(role, account);
            roleExpirations[role][account] = 0;
            emit RoleRevoked(role, account);
        }
    }
    
    // ====================================================
    //  Role Documentation Functions
    // ====================================================
    function documentRole(
        bytes32 role,
        string calldata description
    ) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        roleInfo[role] = RoleInfo({
            id: role,
            parent: roleHierarchy[role],
            description: description,
            requirement: roleRequirements[role]
        });
        emit RoleDocumented(role, description);
    }
    
    function getRoleInfo(bytes32 role) external view returns (RoleInfo memory) {
        return roleInfo[role];
    }
    
    // ====================================================
    //  Oracle and Configuration Updates
    // ====================================================
    function updatePriceOracle(
        address newOracle
    ) external override onlyRole(GOVERNANCE_ROLE) nonReentrant {
        if (newOracle == address(0)) revert InvalidAddress();
        
        address oldOracle = address(priceFeed);
        priceFeed = AggregatorV3Interface(newOracle);
        emit OracleUpdated(oldOracle, newOracle);
    }
    
    function updateLiquidityThreshold(uint256 newThreshold) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        uint256 oldThreshold = minimumLiquidity;
        minimumLiquidity = newThreshold;
        emit LiquidityThresholdUpdated(oldThreshold, newThreshold);
    }
    
    function updatePriceBounds(
        uint256 newMinPrice,
        uint256 newMaxPrice
    ) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        if (newMinPrice >= newMaxPrice) revert InvalidParameters();
        
        uint256 oldMinPrice = minimumPrice;
        uint256 oldMaxPrice = maximumPrice;
        minimumPrice = newMinPrice;
        maximumPrice = newMaxPrice;
        emit PriceBoundsUpdated(oldMinPrice, oldMaxPrice, newMinPrice, newMaxPrice);
    }
    
    function setRoleHierarchy(
        bytes32 role,
        bytes32 parentRole
    ) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        roleHierarchy[role] = parentRole;
        
        if (roleInfo[role].id == role) {
            roleInfo[role].parent = parentRole;
        }
        emit RoleHierarchyUpdated(role, parentRole);
    }
    
    function setMaxOracleDataAge(uint256 maxAgeInSeconds) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        uint256 oldAge = maxOracleDataAge;
        maxOracleDataAge = maxAgeInSeconds;
        emit OracleDataAgeUpdated(oldAge, maxAgeInSeconds);
    }
    
    function setRoleRequirementToken(
        bytes32 role,
        address token
    ) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        if (token != address(tStakeToken) && token != address(usdc) && 
            token != address(weth) && token != address(wtstk) && 
            token != address(wbtc)) revert InvalidAddress();
        roleRequirementToken[role] = IERC20(token);
        emit TokenConfigurationUpdated(token, "roleRequirement");
    }
    
    // ====================================================
    //  Pausing Functions
    // ====================================================
    function pause() external override onlyRole(PAUSER_ROLE) nonReentrant {
        _pause();
    }
    
    function unpause() external override onlyRole(GOVERNANCE_ROLE) nonReentrant {
        _unpause();
    }
    
    // ====================================================
    //  Validation Functions
    // ====================================================
    function validateWithTStakeSnapshot(
        address account,
        uint256 requiredBalance
    ) external view override {
        IERC20 token = roleRequirementToken[DEFAULT_ADMIN_ROLE]; // Example: use admin role’s token
        if (token == IERC20(address(0))) token = tStakeToken;
        if (token.balanceOf(account) < requiredBalance) {
            revert InsufficientTStakeBalance(account, requiredBalance);
        }
    }
    
    function validateWithOracle(
        uint256 expectedPrice
    ) external view override {
        (, int256 price, , ,) = priceFeed.latestRoundData();
        
        if (price <= 0) revert OracleValidationFailed();
        
        uint256 priceUint = uint256(price);
        if (priceUint < minimumPrice || priceUint > maximumPrice) {
            revert PriceOutOfBounds(priceUint, minimumPrice, maximumPrice);
        }
        
        uint256 lowerBound = expectedPrice * 95 / 100;
        uint256 upperBound = expectedPrice * 105 / 100;
        
        if (priceUint < lowerBound || priceUint > upperBound) {
            revert PriceOutOfBounds(priceUint, lowerBound, upperBound);
        }
    }
    
    function validateWithOracleAndTimestamp(
        uint256 expectedPrice
    ) external view override {
        (
            uint80 roundId,
            int256 price,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();
        
        if (maxOracleDataAge > 0 && block.timestamp - updatedAt > maxOracleDataAge) {
            revert StaleOracleData(updatedAt, block.timestamp);
        }
        
        if (answeredInRound < roundId) {
            revert InvalidOracleRound(answeredInRound, roundId);
        }
        
        if (price <= 0) revert OracleValidationFailed();
        
        uint256 priceUint = uint256(price);
        if (priceUint < minimumPrice || priceUint > maximumPrice) {
            revert PriceOutOfBounds(priceUint, minimumPrice, maximumPrice);
        }
        
        uint256 lowerBound = expectedPrice * 95 / 100;
        uint256 upperBound = expectedPrice * 105 / 100;
        
        if (priceUint < lowerBound || priceUint > upperBound) {
            revert PriceOutOfBounds(priceUint, lowerBound, upperBound);
        }
    }
    
    function validateLiquidityThreshold() external view override {
        uint256 totalLiquidity = tStakeToken.balanceOf(address(this)) + 
                                wtstk.balanceOf(address(this)); // Include WTSTK
        if (totalLiquidity < minimumLiquidity) {
            revert LiquidityThresholdNotMet();
        }
    }
    
    // ====================================================
    //  View Functions
    // ====================================================    
    function hasValidRole(bytes32 role, address account) external view override returns (bool) {
        return hasRole(role, account) && isActiveRole(role, account);
    }
    
    function isActiveRole(bytes32 role, address account) public view override returns (bool) {
        if (!hasRole(role, account)) return false;
        
        uint256 expiration = roleExpirations[role][account];
        if (expiration != 0 && block.timestamp > expiration) {
            return false;
        }
        return true;
    }
    
    function getRoleHierarchy(bytes32 role) external view override returns (bytes32) {
        return roleHierarchy[role];
    }
    
    function getMaxRoleDuration() external pure returns (uint256) {
        return MAX_ROLE_DURATION;
    }
}
