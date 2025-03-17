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
        bool canTransact,
        uint256 currentMultiplier
    );
    
    function getPriceMonitoringStatus() external view returns (
        int256 lastPrice,
        int256 currentPrice,
        uint256 timeSinceLastCheck,
        bool buybackPaused,
        bool circuitBroken,
        bool surgeBroken
    );
    
    function getLiquidityLockStatus(address user) external view returns (
        uint256 lockUntil,
        bool isLocked,
        uint256 remainingTime
    );
    
    function checkWouldThrottle(address from) external view returns (
        bool wouldThrottle, 
        uint256 cooldownEnds,
        uint256 appliedMultiplier
    );
    
    function getSecurityThresholds() external view returns (
        uint256 blockLimit,
        uint256 priceImpact,
        uint256 circuitBreaker,
        uint256 lockPeriod,
        uint256 priceCooldown,
        uint256 surgeThreshold,
        uint256 surgeCooldown
    );
    
    // Liquidity functions
    function canWithdrawLiquidity(address user) external view returns (bool);
    
    // Dynamic throttling parameters
    function getDynamicThrottlingParams() external view returns (
        uint256 base,
        uint256 rapid,
        uint256 window,
        uint256 maxMult
    );
    
    // Failsafe mechanism status
    function getFailsafeStatus() external view returns (
        address admin,
        bool isActive,
        uint256 inactivityThreshold,
        uint256 lastActivity,
        uint256 timeUntilFailsafe
    );
}