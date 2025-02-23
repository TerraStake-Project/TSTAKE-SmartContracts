// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/ITerraStakeAccessControl.sol";

/**
 * @title TerraStakeAccessControl (3B Cap Secured)
 * @notice Handles decentralized access control, liquidity enforcement, and role-based governance.
 */
contract TerraStakeAccessControl is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    ITerraStakeAccessControl
{
    // ====================================================
    // 🔹 Role Identifiers
    // ====================================================
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

    // ====================================================
    // 🔹 External Contracts
    // ====================================================
    AggregatorV3Interface private _priceFeed;
    IERC20 private _usdcToken;
    IERC20 private _wethToken;
    IERC20 private _tStakeToken;  // ✅ TSTAKE TOKEN INTEGRATION

    // ====================================================
    // 🔹 Role-Based Enforcement
    // ====================================================
    mapping(bytes32 => uint256) private _roleRequirements;  // Min TSTAKE required for roles
    mapping(bytes32 => mapping(address => uint256)) private _roleExpirations;
    mapping(bytes32 => bytes32) private _roleHierarchy;
    mapping(bytes32 => bool) private _pendingMultisigApprovals;

    // ====================================================
    // 🔹 Liquidity & Price Controls
    // ====================================================
    uint256 private _minimumLiquidity;
    uint256 private _minimumPrice;
    uint256 private _maximumPrice;
    uint256 private _priceDeviationTolerance = 500; // 5% tolerance
    bool private _emergencyLiquidityFrozen = false;

    // ====================================================
    // 🔹 Events
    // ====================================================
    event RoleGrantedWithExpiration(bytes32 indexed role, address indexed account, uint256 expirationTime);
    event RoleRequirementUpdated(bytes32 indexed role, uint256 oldRequirement, uint256 newRequirement);
    event TokenConfigurationUpdated(address indexed token, string tokenType);
    event PriceBoundsUpdated(uint256 oldMinPrice, uint256 oldMaxPrice, uint256 newMinPrice, uint256 newMaxPrice);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event EmergencyLiquidityFrozen(bool status);
    event MultisigApprovalRequested(bytes32 indexed action);
    event MultisigApprovalExecuted(bytes32 indexed action);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address priceOracle,
        address usdcToken,
        address wethToken,
        address tStakeToken,  // ✅ Added TSTAKE token
        uint256 minimumLiquidity,
        uint256 minimumPrice,
        uint256 maximumPrice
    ) external override initializer {
        require(
            admin != address(0) &&
            priceOracle != address(0) &&
            usdcToken != address(0) &&
            wethToken != address(0) &&
            tStakeToken != address(0),
            "Invalid address"
        );

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _setupRoleHierarchy();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        _priceFeed = AggregatorV3Interface(priceOracle);
        _usdcToken = IERC20(usdcToken);
        _wethToken = IERC20(wethToken);
        _tStakeToken = IERC20(tStakeToken);

        _minimumLiquidity = minimumLiquidity;
        _minimumPrice = minimumPrice;
        _maximumPrice = maximumPrice;

        emit TokenConfigurationUpdated(usdcToken, "USDC");
        emit TokenConfigurationUpdated(wethToken, "WETH");
        emit TokenConfigurationUpdated(tStakeToken, "TSTAKE");
        emit PriceBoundsUpdated(0, 0, minimumPrice, maximumPrice);
    }

    // ====================================================
    // 🔹 Role-Based Access with Expiration & Enforcement
    // ====================================================
    function grantRoleWithExpiration(bytes32 role, address account, uint256 duration) 
        external override onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused 
    {
        require(account != address(0) && duration > 0, "Invalid parameters");
        require(_validateRoleRequirements(role, account), "Insufficient TSTAKE balance");

        uint256 expiration = block.timestamp + duration;
        super.grantRole(role, account);
        _roleExpirations[role][account] = expiration;

        emit RoleGrantedWithExpiration(role, account, expiration);
    }

    function hasValidRole(bytes32 role, address account) external view override returns (bool) {
        if (!hasRole(role, account)) return false;
        if (_roleExpirations[role][account] > 0 && block.timestamp > _roleExpirations[role][account]) {
            return false;  // Role has expired
        }
        return _validateRoleRequirements(role, account);
    }

    function _validateRoleRequirements(bytes32 role, address account) internal view returns (bool) {
        uint256 requiredTStake = _roleRequirements[role];
        return requiredTStake == 0 || _tStakeToken.balanceOf(account) >= requiredTStake;
    }

    // ====================================================
    // 🔹 Emergency Liquidity Protection
    // ====================================================
    function freezeLiquidity() external onlyRole(EMERGENCY_ROLE) {
        _emergencyLiquidityFrozen = true;
        emit EmergencyLiquidityFrozen(true);
    }

    function unfreezeLiquidity() external onlyRole(GOVERNANCE_ROLE) {
        _emergencyLiquidityFrozen = false;
        emit EmergencyLiquidityFrozen(false);
    }

    function enforceLiquidityCheck(uint256 withdrawalAmount) external view {
        require(!_emergencyLiquidityFrozen, "Liquidity withdrawals are temporarily frozen");
        require(withdrawalAmount <= _minimumLiquidity, "Exceeds max liquidity withdrawal");
    }

    // ====================================================
    // 🔹 Oracle-Based Price Validation (With Tolerance)
    // ====================================================
    function validateWithOracle(uint256 expectedPrice) external view override {
        uint256 currentPrice = _getPriceFromOracle();
        uint256 lowerBound = expectedPrice - (expectedPrice * _priceDeviationTolerance / 10000);
        uint256 upperBound = expectedPrice + (expectedPrice * _priceDeviationTolerance / 10000);
        require(currentPrice >= lowerBound && currentPrice <= upperBound, "Price validation failed");
    }

    function _getPriceFromOracle() internal view returns (uint256) {
        (, int256 price,,,) = _priceFeed.latestRoundData();
        require(price > 0, "Invalid price");
        return uint256(price);
    }

    function setPriceDeviationTolerance(uint256 newTolerance) external onlyRole(GOVERNANCE_ROLE) {
        require(newTolerance <= 1000, "Tolerance too high");
        _priceDeviationTolerance = newTolerance;
    }

    // ====================================================
    // 🔹 Multisig Approval System
    // ====================================================
    function requestMultisigApproval(bytes32 action) external onlyRole(GOVERNANCE_ROLE) {
        _pendingMultisigApprovals[action] = true;
        emit MultisigApprovalRequested(action);
    }

    function executeMultisigApproval(bytes32 action) external onlyRole(MULTISIG_ADMIN_ROLE) {
        require(_pendingMultisigApprovals[action], "Approval not requested");
        _pendingMultisigApprovals[action] = false;
        emit MultisigApprovalExecuted(action);
    }
}
