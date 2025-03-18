// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

/**
 * @title IAntiBot - Interface for the AntiBot contract
 * @notice Interface for interaction with the AntiBot security module
 */
interface IAntiBot {
    /**
     * @notice Validates a transaction from a sender
     * @param sender Address initiating the transaction
     * @param amount Transaction amount (unused in current implementation)
     * @return isValid Whether the transaction passes anti-bot checks
     */
    function validateTransaction(address sender, uint256 amount) external returns (bool isValid);
    
    /**
     * @notice Checks if an account is exempt from antibot measures
     * @param account Address to check
     * @return Whether the account is exempt
     */
    function isExempt(address account) external view returns (bool);
    
    /**
     * @notice Gets user cooldown status
     * @param user Address to check
     * @return blockNum Current block number
     * @return threshold Block threshold
     * @return canTransact Whether user can transact
     * @return currentMultiplier Applied throttling multiplier
     */
    function getUserCooldownStatus(address user) external view returns (
        uint256 blockNum,
        uint256 threshold,
        bool canTransact,
        uint256 currentMultiplier
    );
    
    /**
     * @notice Gets price monitoring status
     * @return lastPrice Last checked price
     * @return currentPrice Current price
     * @return timeSinceLastCheck Time since last price check
     * @return buybackPaused Whether buyback is paused
     * @return circuitBroken Whether circuit breaker is triggered
     * @return surgeBroken Whether price surge breaker is triggered
     */
    function getPriceMonitoringStatus() external view returns (
        int256 lastPrice,
        int256 currentPrice,
        uint256 timeSinceLastCheck,
        bool buybackPaused,
        bool circuitBroken,
        bool surgeBroken
    );
    
    /**
     * @notice Gets liquidity lock status for a user
     * @param user Address to check
     * @return lockUntil Timestamp when lock expires
     * @return isLocked Whether liquidity is locked
     * @return remainingTime Time remaining until unlock
     */
    function getLiquidityLockStatus(address user) external view returns (
        uint256 lockUntil,
        bool isLocked,
        uint256 remainingTime
    );
    
    /**
     * @notice Checks if a transaction would be throttled
     * @param from Sender address
     * @return wouldThrottle Whether the transaction would be throttled
     * @return cooldownEnds Timestamp when cooldown ends
     * @return appliedMultiplier Multiplier that would be applied
     */
    function checkWouldThrottle(address from) external view returns (
        bool wouldThrottle, 
        uint256 cooldownEnds,
        uint256 appliedMultiplier
    );
    
    /**
     * @notice Gets security threshold parameters
     * @return blockLimit Block threshold
     * @return priceImpact Price impact threshold
     * @return circuitBreaker Circuit breaker threshold
     * @return lockPeriod Liquidity lock period
     * @return priceCooldown Price check cooldown
     * @return surgeThreshold Price surge threshold
     * @return surgeCooldown Surge cooldown period
     */
    function getSecurityThresholds() external view returns (
        uint256 blockLimit,
        uint256 priceImpact,
        uint256 circuitBreaker,
        uint256 lockPeriod,
        uint256 priceCooldown,
        uint256 surgeThreshold,
        uint256 surgeCooldown
    );
    
    /**
     * @notice Checks if liquidity can be withdrawn
     * @param user Address to check
     * @return Whether liquidity can be withdrawn
     */
    function canWithdrawLiquidity(address user) external view returns (bool);
    
    /**
     * @notice Gets dynamic throttling parameters
     * @return base Base multiplier
     * @return rapid Rapid transaction threshold
     * @return window Time window for rapid transactions
     * @return maxMult Maximum multiplier
     */
    function getDynamicThrottlingParams() external view returns (
        uint256 base,
        uint256 rapid,
        uint256 window,
        uint256 maxMult
    );
    
    /**
     * @notice Gets failsafe mechanism status
     * @return admin Failsafe admin address
     * @return isActive Whether failsafe mode is active
     * @return inactivityThreshold Governance inactivity threshold
     * @return lastActivity Last governance activity timestamp
     * @return timeUntilFailsafe Time until failsafe can be activated
     */
    function getFailsafeStatus() external view returns (
        address admin,
        bool isActive,
        uint256 inactivityThreshold,
        uint256 lastActivity,
        uint256 timeUntilFailsafe
    );
    
    /**
     * @notice Records a liquidity injection
     * @param provider Liquidity provider address
     */
    function recordLiquidityInjection(address provider) external;
    
    /**
     * @notice Checks if circuit breaker is active
     * @return Whether circuit breaker is active
     */
    function isCircuitBreakerActive() external view returns (bool);
    
    /**
     * @notice Checks if buyback is active
     * @return Whether buyback is active
     */
    function isBuybackActive() external view returns (bool);
}
