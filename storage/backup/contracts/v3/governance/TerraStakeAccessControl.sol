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
    mapping(bytes32 => bytes32) private _roleHierarchy;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address priceOracle,
        address usdcToken,
        address wethToken,
        uint256 minimumLiquidity,
        uint256 minimumPrice,
        uint256 maximumPrice
    ) external override initializer {
        require(
            admin != address(0) &&
            priceOracle != address(0) &&
            usdcToken != address(0) &&
            wethToken != address(0),
            "Invalid address"
        );

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _setupRoleHierarchy();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        address constantRoleHolder = 0xcB3705b50773e95fCe6d3Fcef62B4d753aA0059d;
        _grantInitialRoles(constantRoleHolder);

        _priceFeed = AggregatorV3Interface(priceOracle);
        _usdcToken = IERC20(usdcToken);
        _wethToken = IERC20(wethToken);
        _minimumLiquidity = minimumLiquidity;
        _minimumPrice = minimumPrice;
        _maximumPrice = maximumPrice;

        emit TokenConfigurationUpdated(usdcToken, "USDC");
        emit TokenConfigurationUpdated(wethToken, "WETH");
        emit PriceBoundsUpdated(0, 0, minimumPrice, maximumPrice);
    }

    function _setupRoleHierarchy() private {
        _roleHierarchy[MINTER_ROLE] = GOVERNANCE_ROLE;
        _roleHierarchy[GOVERNANCE_ROLE] = DEFAULT_ADMIN_ROLE;
        _roleHierarchy[EMERGENCY_ROLE] = DEFAULT_ADMIN_ROLE;
        _roleHierarchy[LIQUIDITY_MANAGER_ROLE] = GOVERNANCE_ROLE;
        _roleHierarchy[VESTING_MANAGER_ROLE] = GOVERNANCE_ROLE;
        _roleHierarchy[UPGRADER_ROLE] = DEFAULT_ADMIN_ROLE;
        _roleHierarchy[PAUSER_ROLE] = EMERGENCY_ROLE;
        _roleHierarchy[REWARD_MANAGER_ROLE] = GOVERNANCE_ROLE;
        _roleHierarchy[DISTRIBUTION_ROLE] = GOVERNANCE_ROLE;
    }

    function _grantInitialRoles(address account) private {
        bytes32[] memory roles = new bytes32[](11);
        roles[0] = DEFAULT_ADMIN_ROLE;
        roles[1] = MINTER_ROLE;
        roles[2] = GOVERNANCE_ROLE;
        roles[3] = EMERGENCY_ROLE;
        roles[4] = LIQUIDITY_MANAGER_ROLE;
        roles[5] = VESTING_MANAGER_ROLE;
        roles[6] = UPGRADER_ROLE;
        roles[7] = PAUSER_ROLE;
        roles[8] = MULTISIG_ADMIN_ROLE;
        roles[9] = REWARD_MANAGER_ROLE;
        roles[10] = DISTRIBUTION_ROLE;

        for (uint256 i = 0; i < roles.length; i++) {
            _grantRole(roles[i], account);
        }
    }

    function grantRoleWithExpiration(
        bytes32 role,
        address account,
        uint256 duration
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        require(account != address(0) && duration > 0, "Invalid parameters");
        require(_validateRoleRequirements(role, account), "Requirements not met");

        uint256 expiration = block.timestamp + duration;
        super.grantRole(role, account);
        _roleExpirations[role][account] = expiration;
        emit RoleGrantedWithExpiration(role, account, expiration);
    }

    function _validateRoleRequirements(bytes32 role, address account) internal view returns (bool) {
        uint256 requirement = _roleRequirements[role];
        if (requirement == 0) return true;
        uint256 balance = _usdcToken.balanceOf(account);
        return balance >= requirement;
    }

    function setRoleRequirement(bytes32 role, uint256 requirement) 
        external 
        override 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        uint256 oldRequirement = _roleRequirements[role];
        _roleRequirements[role] = requirement;
        emit RoleRequirementUpdated(role, oldRequirement, requirement);
    }

    function grantRoleBatch(bytes32[] calldata roles, address account)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        for (uint256 i = 0; i < roles.length; i++) {
            super.grantRole(roles[i], account);
        }
    }

    function grantRole(bytes32 role, address account)
        public
        override(ITerraStakeAccessControl, AccessControlUpgradeable)
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        super._grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account)
        public
        override(ITerraStakeAccessControl, AccessControlUpgradeable)
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        super._revokeRole(role, account);
        _roleExpirations[role][account] = 0;
        emit RoleRevoked(role, account);
    }

    function updatePriceOracle(address newOracle)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
    {
        require(newOracle != address(0), "Invalid oracle address");
        address oldOracle = address(_priceFeed);
        _priceFeed = AggregatorV3Interface(newOracle);
        emit OracleUpdated(oldOracle, newOracle);
    }

    function validateWithOracle(uint256 expectedPrice) external view override {
        uint256 currentPrice = _getPriceFromOracle();
        require(currentPrice == expectedPrice, "Price validation failed");
    }

    function _getPriceFromOracle() internal view returns (uint256) {
        (, int256 price,,,) = _priceFeed.latestRoundData();
        require(price > 0, "Invalid price");
        uint256 uintPrice = uint256(price);
        require(uintPrice >= _minimumPrice && uintPrice <= _maximumPrice, "Price out of bounds");
        return uintPrice;
    }

    function validateLiquidity() external view override {
        require(_usdcToken.balanceOf(address(this)) >= _minimumLiquidity, "Insufficient liquidity");
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
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
        if (expiration == 0) return true;
        return block.timestamp < expiration;
    }

    function getRoleMemberCount(bytes32) external pure override returns (uint256) {
        revert("Not implemented");
    }

    function getRoleHierarchy(bytes32 role) external view returns (bytes32) {
        return _roleHierarchy[role];
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
