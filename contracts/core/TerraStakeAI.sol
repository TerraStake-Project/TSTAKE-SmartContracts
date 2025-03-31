// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@api3/contracts/v0.8/interfaces/IProxy.sol";
import "../interfaces/ITerraStakeStaking.sol";

/**
 * @title TerraStakeAI
 * @notice AI-driven optimization layer for TerraStakeStaking, dynamically adjusting APR, penalties, and liquidity.
 * @dev Uses API3 dAPIs for market data and integrates with TerraStakeStaking for staking optimization.
 */
contract TerraStakeAI is
    Initializable,
    AccessControlEnumerableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // Custom Errors
    error UnauthorizedCaller(address caller, bytes32 requiredRole);
    error ZeroAddress();
    error InvalidParameter(string parameter, uint256 provided);
    error StaleOracleData(uint256 lastUpdate, uint256 currentTime);
    error OracleFetchFailed(address oracle, string reason);
    error HighVolatilityDetected(uint256 volatility, uint256 threshold);
    error OperationPaused(string operation);

    // Constants
    uint256 public constant MAX_APR = 50; // 50% max APR
    uint256 public constant MIN_APR = 5; // 5% min APR
    uint256 public constant MAX_PENALTY = 30; // 30% max penalty
    uint256 public constant MIN_PENALTY = 5; // 5% min penalty
    uint256 public constant MAX_PRICE_DEVIATION = 2000; // 20% in basis points
    uint256 public constant MAX_LIQUIDITY_INJECTION = 500000 * 10**18; // 500K USDC max injection
    uint256 public constant VOLATILITY_THRESHOLD = 15; // Adaptive threshold

    // Roles
    bytes32 public constant AI_ADMIN_ROLE = keccak256("AI_ADMIN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // State Variables
    ITerraStakeStaking public terraStakeStaking;
    IProxy public priceOracle;
    address public usdcLiquidityPool;
    
    uint256 public dynamicAPR;
    uint256 public dynamicPenalty;
    uint256 public lastAPRUpdateTime;
    uint256 public lastPenaltyUpdateTime;
    uint256 public lastLiquidityInjectionTime;
    
    uint256 public marketVolatility;
    uint256 public liquidityInjectionRate;
    
    // Events
    event APRUpdated(uint256 newAPR, uint256 timestamp);
    event PenaltyUpdated(uint256 newPenalty, uint256 timestamp);
    event LiquidityInjected(uint256 amount, uint256 timestamp);
    event VolatilityDetected(uint256 volatility, uint256 threshold);

    // Initialization
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _terraStakeStaking,
        address _priceOracle,
        address _usdcLiquidityPool,
        address _admin
    ) public initializer {
        __AccessControlEnumerable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        if (_terraStakeStaking == address(0)) revert ZeroAddress();
        if (_priceOracle == address(0)) revert ZeroAddress();
        if (_usdcLiquidityPool == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();

        terraStakeStaking = ITerraStakeStaking(_terraStakeStaking);
        priceOracle = IProxy(_priceOracle);
        usdcLiquidityPool = _usdcLiquidityPool;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(AI_ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);

        dynamicAPR = 10; // Start at 10%
        dynamicPenalty = 10; // Start at 10%
        liquidityInjectionRate = 5; // 5% liquidity management
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // ===============================
    // AI-Driven Staking Adjustments
    // ===============================

    function updateAPR() external onlyRole(AI_ADMIN_ROLE) whenNotPaused {
        uint256 price = fetchLatestPrice();
        uint256 newAPR = dynamicAPR;

        if (price < 1_000_000) {
            newAPR = MIN_APR;
        } else if (price > 10_000_000) {
            newAPR = MAX_APR;
        } else {
            newAPR = 10 + (price / 1_000_000);
        }

        if (newAPR > MAX_APR) newAPR = MAX_APR;
        if (newAPR < MIN_APR) newAPR = MIN_APR;

        dynamicAPR = newAPR;
        lastAPRUpdateTime = block.timestamp;

        emit APRUpdated(newAPR, block.timestamp);
    }

    function updatePenalty() external onlyRole(AI_ADMIN_ROLE) whenNotPaused {
        uint256 volatility = marketVolatility;
        uint256 newPenalty = dynamicPenalty;

        if (volatility > VOLATILITY_THRESHOLD) {
            newPenalty = MAX_PENALTY;
            emit HighVolatilityDetected(volatility, VOLATILITY_THRESHOLD);
        } else {
            newPenalty = MIN_PENALTY + (volatility / 2);
        }

        if (newPenalty > MAX_PENALTY) newPenalty = MAX_PENALTY;
        if (newPenalty < MIN_PENALTY) newPenalty = MIN_PENALTY;

        dynamicPenalty = newPenalty;
        lastPenaltyUpdateTime = block.timestamp;

        emit PenaltyUpdated(newPenalty, block.timestamp);
    }

    function injectLiquidity() external onlyRole(AI_ADMIN_ROLE) whenNotPaused {
        uint256 amount = (terraStakeStaking.totalStakedTokens() * liquidityInjectionRate) / 100;
        if (amount > MAX_LIQUIDITY_INJECTION) amount = MAX_LIQUIDITY_INJECTION;

        terraStakeStaking.receiveLiquidityInjection(usdcLiquidityPool, amount);
        lastLiquidityInjectionTime = block.timestamp;

        emit LiquidityInjected(amount, block.timestamp);
    }

    // ===============================
    // Oracle & Volatility Tracking
    // ===============================

    function fetchLatestPrice() public returns (uint256) {
        (int224 price, uint256 updatedAt) = priceOracle.read();
        if (price <= 0) revert OracleFetchFailed(address(priceOracle), "Invalid price");
        if (updatedAt == 0 || block.timestamp - updatedAt > 24 hours) {
            revert StaleOracleData(updatedAt, block.timestamp);
        }

        return uint256(price);
    }

    function updateMarketVolatility(uint256 newVolatility) external onlyRole(AI_ADMIN_ROLE) {
        marketVolatility = newVolatility;
    }

    // ===============================
    // Emergency & Safety Controls
    // ===============================

    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(AI_ADMIN_ROLE) {
        _unpause();
    }
}
