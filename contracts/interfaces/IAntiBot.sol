// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

/**
 * @title IAntiBot - Interface for TerraStake AntiBot Security Module v4.0
 * @notice Defines the public interface for the AntiBot contract, providing protection against
 * front-running, flash crashes, sandwich attacks, and excessive transactions
 */
interface IAntiBot {
 
    // ================================
    // Events
    // ================================
    event AntibotStatusUpdated(bool isEnabled);
    event BlockThresholdUpdated(uint256 newThreshold);
    event BuybackPaused(bool status);
    event CircuitBreakerTriggered(bool status, int256 priceChange);
    event CircuitBreakerReset(bytes32 indexed callerRole);
    event EmergencyCircuitBreakerReset(address indexed admin, bytes32 indexed callerRole);
    event AddressExempted(address indexed account);
    event ExemptionRevoked(address indexed account, bytes32 indexed callerRole);
    event TrustedContractAdded(address indexed contractAddress);
    event TrustedContractRemoved(address indexed contractAddress, bytes32 indexed callerRole);
    event PriceImpactThresholdUpdated(uint256 newThreshold);
    event CircuitBreakerThresholdUpdated(uint256 newThreshold);
    event LiquidityLockPeriodUpdated(uint256 newPeriod);
    event GovernanceExemptionRequested(address indexed account, uint256 unlockTime);
    event GovernanceExemptionApproved(address indexed account, bytes32 indexed callerRole);
    event PriceMonitoringUpdated(uint256 timestamp, int256 oldPrice, int256 newPrice);
    event PriceCheckCooldownUpdated(uint256 newCooldown);
    event PriceSurgeDetected(bool status, int256 priceChange);
    event PriceSurgeReset(bytes32 indexed callerRole);
    event FailsafeModeActivated(address indexed activator);
    event FailsafeModeDeactivated(address indexed deactivator);
    event DynamicThrottlingUpdated(uint256 baseMultiplier, uint256 rapidThreshold, uint256 window, uint256 maxMultiplier);
    event PriceSurgeThresholdUpdated(uint256 newThreshold, uint256 newCooldown);
    event GovernanceInactivityThresholdUpdated(uint256 newThreshold);
    event UserThrottled(address indexed user, uint256 multiplier, uint256 cooldownEnds);
    event OracleAdded(address indexed oracle);
    event OracleRemoved(address indexed oracle);
    event MinimumOracleResponsesUpdated(uint8 count);
    event RateLimitConfigUpdated(uint128 capacity, uint128 refillRate);
    event SuspiciousPatternDetected(address indexed user, uint64 patternCount);
    event TWAPUpdated(int256 price);

    // ================================
    // Structs
    // ================================
    struct GovernanceRequest {
        address account;
        uint64 unlockTime;
    }

    // ================================
    // State Variables
    // ================================
    function isAntibotEnabled() external view returns (bool);
    function isBuybackPaused() external view returns (bool);
    function isCircuitBreakerTriggered() external view returns (bool);
    function isPriceSurgeActive() external view returns (bool);
    function failsafeMode() external view returns (bool);
    function governanceExemptionCount() external view returns (uint8);
    function minimumOracleResponses() external view returns (uint8);
    function oracleCount() external view returns (uint8);
    function blockThreshold() external view returns (uint256);
    function priceImpactThreshold() external view returns (uint256);
    function circuitBreakerThreshold() external view returns (uint256);
    function liquidityLockPeriod() external view returns (uint256);
    function priceCheckCooldown() external view returns (uint256);
    function lastPriceCheckTime() external view returns (uint256);
    function baseMultiplier() external view returns (uint256);
    function rapidTransactionThreshold() external view returns (uint256);
    function rapidTransactionWindow() external view returns (uint256);
    function maxMultiplier() external view returns (uint256);
    function priceSurgeThreshold() external view returns (uint256);
    function surgeCooldownPeriod() external view returns (uint256);
    function lastSurgeTime() external view returns (uint256);
    function governanceInactivityThreshold() external view returns (uint256);
    function lastGovernanceActivity() external view returns (uint256);
    function lastCheckedPrice() external view returns (int256);
    function pendingExemptions(address account) external view returns (GovernanceRequest memory);
    function backupOracles(address oracle) external view returns (bool);
    function priceOracle() external view returns (address);

    // ================================
    // Initialization
    // ================================
    /**
     * @notice Initializes the AntiBot contract
     * @param governanceContract Address of the governance contract
     * @param stakingContract Address of the staking contract
     * @param _priceOracle Address of the primary price oracle
     */
    function initialize(
        address governanceContract,
        address stakingContract,
        address _priceOracle
    ) external;

    // ================================
    // Price Monitoring
    // ================================
    /**
     * @notice Checks current price impact and updates circuit breakers
     */
    function checkPriceImpact() external;

    /**
     * @notice Calculates the Time-Weighted Average Price
     * @return Current TWAP value
     */
    function calculateTWAP() external view returns (int256);

    /**
     * @notice Resets the circuit breaker
     */
    function resetCircuitBreaker() external;

    /**
     * @notice Performs an emergency reset of the circuit breaker
     */
    function emergencyResetCircuitBreaker() external;

    /**
     * @notice Resets the price surge breaker
     */
    function resetPriceSurgeBreaker() external;

    // ================================
    // Oracle Management
    // ================================
    /**
     * @notice Adds a backup oracle
     * @param oracle Address of the oracle to add
     */
    function addOracle(address oracle) external;

    /**
     * @notice Removes a backup oracle
     * @param oracle Address of the oracle to remove
     */
    function removeOracle(address oracle) external;

    /**
     * @notice Sets the minimum required oracle responses for consensus
     * @param count Minimum number of oracle responses required
     */
    function setMinimumOracleResponses(uint8 count) external;

    // ================================
    // Configuration Management
    // ================================
    /**
     * @notice Updates the block threshold for throttling
     * @param newThreshold New block threshold value
     */
    function updateBlockThreshold(uint256 newThreshold) external;

    /**
     * @notice Updates dynamic throttling parameters
     * @param _base Base multiplier for throttling
     * @param _rapid Rapid transaction threshold
     * @param _window Time window for rapid transactions
     * @param _max Maximum multiplier
     */
    function updateDynamicThrottling(
        uint256 _base,
        uint256 _rapid,
        uint256 _window,
        uint256 _max
    ) external;

    /**
     * @notice Updates price-related thresholds
     * @param _impact Price impact threshold percentage
     * @param _surge Price surge threshold percentage
     * @param _circuit Circuit breaker threshold percentage
     */
    function updatePriceThresholds(
        uint256 _impact,
        uint256 _surge,
        uint256 _circuit
    ) external;

    /**
     * @notice Updates price check cooldown period
     * @param cooldown New cooldown period in seconds
     */
    function updatePriceCheckCooldown(uint256 cooldown) external;

    /**
     * @notice Updates surge cooldown period
     * @param period New surge cooldown period in seconds
     */
    function updateSurgeCooldownPeriod(uint256 period) external;

    /**
     * @notice Updates the primary price oracle
     * @param newOracle Address of the new price oracle
     */
    function updatePriceOracle(address newOracle) external;

    /**
     * @notice Updates default rate limit parameters
     * @param _capacity Maximum tokens per period
     * @param _refillRate Tokens refilled per second
     */
    function updateRateLimitParams(uint256 _capacity, uint256 _refillRate) external;

    /**
     * @notice Sets custom rate limit for a specific address
     * @param user Address to set custom rate limit for
     * @param capacity Maximum tokens per period
     * @param refillRate Tokens refilled per second
     */
    function setCustomRateLimit(address user, uint256 capacity, uint256 refillRate) external;

    /**
     * @notice Resets rate limit for a specific address to defaults
     * @param user Address to reset rate limit for
     */
    function resetRateLimit(address user) external;

    // ================================
    // Failsafe Management
    // ================================
    /**
     * @notice Activates failsafe mode
     */
    function activateFailsafeMode() external;

    /**
     * @notice Deactivates failsafe mode
     */
    function deactivateFailsafeMode() external;

    /**
     * @notice Updates governance inactivity threshold
     * @param threshold New threshold in seconds
     */
    function updateGovernanceInactivityThreshold(uint256 threshold) external;

    // ================================
    // Utility Functions
    // ================================
    /**
     * @notice Gets the current throttling multiplier for a user
     * @param user Address to check
     * @return Current throttling multiplier
     */
    function getThrottlingMultiplier(address user) external view returns (uint256);

    /**
     * @notice Gets the current rate limit status for a user
     * @param user Address to check
     * @return available Current available tokens
     * @return capacity Maximum capacity
     * @return refillRate Tokens per second refill rate
     */
    function getRateLimitStatus(address user) external view returns (
        uint256 available,
        uint256 capacity,
        uint256 refillRate
    );

    /**
     * @notice Gets the current circuit breaker status
     * @return circuitBreakerActive Whether circuit breaker is triggered
     * @return priceSurgeActive Whether price surge is active
     * @return buybackPaused Whether buyback is paused
     * @return lastPrice Last checked price
     * @return lastCheck Last price check timestamp
     */
    function getCircuitBreakerStatus() external view returns (
        bool circuitBreakerActive,
        bool priceSurgeActive,
        bool buybackPaused,
        int256 lastPrice,
        uint256 lastCheck
    );

    /**
     * @notice Gets the price history
     * @return timestamps Array of observation timestamps
     * @return prices Array of observed prices
     */
    function getPriceHistory() external view returns (
        uint256[] memory timestamps,
        int256[] memory prices
    );

    function checkThrottle(address from) external view returns (bool);
    function isBot(address account) external view returns (bool);
}