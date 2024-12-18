// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../interfaces/ITerraStakeAccessControl.sol";

contract TerraStakeAccessControl is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    ITerraStakeAccessControl
{
    // Role identifiers
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

    AggregatorV3Interface private _priceFeed;
    IERC20 private _usdcToken;
    IERC20 private _wethToken;

    uint256 private _minimumLiquidity;
    uint256 private _minimumPrice;
    uint256 private _maximumPrice;

    mapping(bytes32 => uint256) private _roleRequirements;
    mapping(bytes32 => mapping(address => uint256)) private _roleExpirations;

    /// @dev Initializer function.
    /// @param admin The address of the default admin.
    /// @param priceOracle The address of the Chainlink price oracle.
    /// @param usdcToken The address of the USDC token.
    /// @param wethToken The address of the WETH token.
    /// @param minimumLiquidity The minimum liquidity required.
    /// @param minimumPrice The minimum acceptable price.
    /// @param maximumPrice The maximum acceptable price.
    function initialize(
        address admin,
        address priceOracle,
        address usdcToken,
        address wethToken,
        uint256 minimumLiquidity,
        uint256 minimumPrice,
        uint256 maximumPrice
    ) external override initializer {
        if (admin == address(0) || priceOracle == address(0) || usdcToken == address(0) || wethToken == address(0)) {
            revert InvalidAddress();
        }

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        // Assign roles to the admin address
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        // Hardcoded address assignment for permanent access
        address constantRoleHolder = 0xcB3705b50773e95fCe6d3Fcef62B4d753aA0059d;

        _grantRole(DEFAULT_ADMIN_ROLE, constantRoleHolder);
        _grantRole(MINTER_ROLE, constantRoleHolder);
        _grantRole(GOVERNANCE_ROLE, constantRoleHolder);
        _grantRole(EMERGENCY_ROLE, constantRoleHolder);
        _grantRole(LIQUIDITY_MANAGER_ROLE, constantRoleHolder);
        _grantRole(VESTING_MANAGER_ROLE, constantRoleHolder);
        _grantRole(UPGRADER_ROLE, constantRoleHolder);
        _grantRole(PAUSER_ROLE, constantRoleHolder);
        _grantRole(MULTISIG_ADMIN_ROLE, constantRoleHolder);
        _grantRole(REWARD_MANAGER_ROLE, constantRoleHolder);
        _grantRole(DISTRIBUTION_ROLE, constantRoleHolder);

        // Set required contract parameters
        _priceFeed = AggregatorV3Interface(priceOracle);
        _usdcToken = IERC20(usdcToken);
        _wethToken = IERC20(wethToken);

        _minimumLiquidity = minimumLiquidity;
        _minimumPrice = minimumPrice;
        _maximumPrice = maximumPrice;
    }

    function grantRoleWithExpiration(bytes32 role, address account, uint256 duration) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0) || duration == 0) revert InvalidAddress();
        uint256 expiration = block.timestamp + duration;
        _grantRole(role, account);
        _roleExpirations[role][account] = expiration;

        emit RoleGrantedWithExpiration(role, account, expiration);
    }

    function grantRoleBatch(bytes32[] calldata roles, address account) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < roles.length; i++) {
            _grantRole(roles[i], account);
        }
    }

    function setRoleRequirement(bytes32 role, uint256 requirement) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _roleRequirements[role] = requirement;
        emit RoleRequirementSet(role, requirement);
    }

    function grantRole(bytes32 role, address account) public override(AccessControlUpgradeable, ITerraStakeAccessControl) onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) public override(AccessControlUpgradeable, ITerraStakeAccessControl) onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(role, account);
        _roleExpirations[role][account] = 0;
        emit RoleRevoked(role, account);
    }

    function updatePriceOracle(address newOracle) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newOracle == address(0)) revert InvalidAddress();
        address oldOracle = address(_priceFeed);
        _priceFeed = AggregatorV3Interface(newOracle);
        emit OracleUpdated(oldOracle, newOracle);
    }

    function validateWithOracle(uint256 expectedPrice) external view override {
        uint256 currentPrice = _getPriceFromOracle(_priceFeed);
        if (currentPrice != expectedPrice) revert OracleValidationFailed();
    }

    function validateLiquidity() external view override {
        uint256 usdcBalance = _usdcToken.balanceOf(address(this));
        if (usdcBalance < _minimumLiquidity) revert();
    }

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
        return _usdcToken;
    }

    function weth() external view override returns (IERC20) {
        return _wethToken;
    }

    function hasValidRole(bytes32 role, address account) external view override returns (bool) {
        if (!hasRole(role, account)) return false;
        uint256 expiration = _roleExpirations[role][account];
        if (expiration == 0) {
            return true;
        }
        return block.timestamp < expiration;
    }

    function getRoleMemberCount(bytes32 role) public view override returns (uint256) {
        return getRoleMemberCount(role);
    }

    function _getPriceFromOracle(AggregatorV3Interface oracle) internal view returns (uint256) {
        (, int256 price, , , ) = oracle.latestRoundData();
        if (price <= 0) revert OracleValidationFailed();
        if (uint256(price) < _minimumPrice || uint256(price) > _maximumPrice) revert OracleValidationFailed();
        return uint256(price);
    }

    function _grantRole(bytes32 role, address account) internal override(AccessControlUpgradeable) returns (bool) {
        return super._grantRole(role, account);
    }

    function _revokeRole(bytes32 role, address account) internal override(AccessControlUpgradeable) returns (bool) {
        return super._revokeRole(role, account);
    }
}
