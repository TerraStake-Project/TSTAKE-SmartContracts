// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

interface IAntiBot {
    // Core validation function
    function validateTransaction(address sender, uint256 amount) external returns (bool isValid);
    
    // Exemption checking
    function isExempt(address account) external view returns (bool);
    
    // Status checking functions
    function getUserCooldownStatus(address user) external view returns (
        uint256 blockNum,
        uint256 threshold,
        bool canTransact
    );
    
    function getPriceMonitoringStatus() external view returns (
        int256 lastPrice,
        int256 currentPrice,
        uint256 timeSinceLastCheck,
        bool buybackPaused,
        bool circuitBroken
    );
    
    function getLiquidityLockStatus(address user) external view returns (
        uint256 lockUntil,
        bool isLocked,
        uint256 remainingTime
    );
    
    function checkWouldThrottle(address from) external view returns (bool wouldThrottle, uint256 cooldownEnds);
    
    function getSecurityThresholds() external view returns (
        uint256 blockLimit,
        uint256 priceImpact,
        uint256 circuitBreaker,
        uint256 lockPeriod,
        uint256 priceCooldown
    );
    
    // Liquidity functions
    function canWithdrawLiquidity(address user) external view returns (bool);
    
    // Circuit breaker status
    function isCircuitBreakerTriggered() external view returns (bool);
}