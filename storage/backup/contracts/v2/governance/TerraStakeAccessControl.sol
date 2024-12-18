// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TerraStakeAccessControl is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    // Role identifiers
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant LIQUIDITY_MANAGER_ROLE = keccak256("LIQUIDITY_MANAGER_ROLE");
    bytes32 public constant VESTING_MANAGER_ROLE = keccak256("VESTING_MANAGER_ROLE");

    // Oracle and token references
    AggregatorV3Interface public tStakePriceFeed; // Chainlink TSTAKE/USDC price feed
    AggregatorV3Interface public ethPriceFeed;    // Optional ETH/USD price feed
    IERC20 public tStakeToken;
    IERC20 public usdcToken;

    // Minimum liquidity and price thresholds
    uint256 public minimumLiquidity; 
    uint256 public minimumPrice;     
    uint256 public maximumPrice;     

    // Role expiration mapping
    mapping(bytes32 => mapping(address => uint256)) public roleExpirations;

    // Custom Errors
    error InvalidAddress();
    error OracleValidationFailed();
    error PriceOutOfBounds(uint256 price, uint256 minPrice, uint256 maxPrice);
    error InsufficientLiquidity(uint256 liquidity, uint256 required);
    error RoleExpired(bytes32 role, address account);

    // Events
    event PriceValidated(uint256 price, uint256 minPrice, uint256 maxPrice);
    event LiquidityValidated(uint256 liquidity, uint256 required);
    event MinimumLiquidityUpdated(uint256 oldLiquidity, uint256 newLiquidity);
    event PriceBoundsUpdated(uint256 oldMinPrice, uint256 oldMaxPrice, uint256 newMinPrice, uint256 newMaxPrice);
    event OracleUpdated(address oldOracle, address newOracle);
    event RoleGrantedWithExpiration(bytes32 indexed role, address indexed account, uint256 expirationTime);

    function initialize(
        address admin,
        address _tStakePriceFeed,
        address _ethPriceFeed,
        address _tStakeToken,
        address _usdcToken,
        uint256 _minimumLiquidity,
        uint256 _minimumPrice,
        uint256 _maximumPrice
    ) external initializer {
        if (
            admin == address(0) || 
            _tStakePriceFeed == address(0) || 
            _tStakeToken == address(0) || 
            _usdcToken == address(0)
        ) revert InvalidAddress();

        __AccessControl_init();
        __ReentrancyGuard_init();

        // Assign admin roles
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        // Set token and price feed references
        tStakePriceFeed = AggregatorV3Interface(_tStakePriceFeed);
        ethPriceFeed = AggregatorV3Interface(_ethPriceFeed);
        tStakeToken = IERC20(_tStakeToken);
        usdcToken = IERC20(_usdcToken);

        // Set liquidity and price bounds
        minimumLiquidity = _minimumLiquidity;
        minimumPrice = _minimumPrice;
        maximumPrice = _maximumPrice;
    }

    // --- PRICE AND LIQUIDITY VALIDATIONS ---

    // Removed `view` because events are emitted, which changes state
    function validatePrice() public {
        uint256 price = _getPriceFromOracle(tStakePriceFeed);
        if (price < minimumPrice || price > maximumPrice) {
            revert PriceOutOfBounds(price, minimumPrice, maximumPrice);
        }

        emit PriceValidated(price, minimumPrice, maximumPrice);
    }

    // Removed `view` because events are emitted
    function validateLiquidity() public {
        uint256 usdcBalance = usdcToken.balanceOf(address(tStakeToken));
        if (usdcBalance < minimumLiquidity) revert InsufficientLiquidity(usdcBalance, minimumLiquidity);

        emit LiquidityValidated(usdcBalance, minimumLiquidity);
    }

    // Removed `view` because events are emitted indirectly via validatePrice & validateLiquidity
    function validateTStake() public {
        validatePrice();
        validateLiquidity();
    }

    function _getPriceFromOracle(AggregatorV3Interface oracle) internal view returns (uint256) {
        (, int256 price, , , ) = oracle.latestRoundData();
        if (price <= 0) revert OracleValidationFailed();
        return uint256(price);
    }

    // --- ROLE MANAGEMENT WITH EXPIRATIONS ---
    function grantRoleWithExpiration(
        bytes32 role,
        address account,
        uint256 duration
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert InvalidAddress();

        uint256 expirationTime = block.timestamp + duration;
        roleExpirations[role][account] = expirationTime;

        grantRole(role, account);
        emit RoleGrantedWithExpiration(role, account, expirationTime);
    }

    function hasValidRole(bytes32 role, address account) public view returns (bool) {
        if (!hasRole(role, account)) return false;

        uint256 expiration = roleExpirations[role][account];
        if (expiration == 0) return true; // No expiration set
        if (block.timestamp > expiration) return false; // Role expired

        return true;
    }

    function revokeRole(bytes32 role, address account) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        super.revokeRole(role, account);
        roleExpirations[role][account] = 0;
    }

    // --- ADMIN OPERATIONS ---
    function updatePriceBounds(uint256 newMinPrice, uint256 newMaxPrice) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMinPrice == 0 || newMaxPrice <= newMinPrice) revert InvalidAddress();

        uint256 oldMinPrice = minimumPrice;
        uint256 oldMaxPrice = maximumPrice;

        minimumPrice = newMinPrice;
        maximumPrice = newMaxPrice;

        emit PriceBoundsUpdated(oldMinPrice, oldMaxPrice, newMinPrice, newMaxPrice);
    }

    function updateMinimumLiquidity(uint256 newLiquidity) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldLiquidity = minimumLiquidity;
        minimumLiquidity = newLiquidity;

        emit MinimumLiquidityUpdated(oldLiquidity, newLiquidity);
    }

    function updatePriceFeed(address newOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newOracle == address(0)) revert InvalidAddress();

        address oldOracle = address(tStakePriceFeed);
        tStakePriceFeed = AggregatorV3Interface(newOracle);

        emit OracleUpdated(oldOracle, newOracle);
    }
}
