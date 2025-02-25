// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ITerraStakeLiquidityGuard {
    // ================================
    // 🔹 Liquidity Management Functions
    // ================================
    function injectLiquidity(uint256 amount) external;
    function updateLiquidityInjectionRate(uint256 newRate) external;
    function updateLiquidityCap(uint256 newCap) external;
    function updateReinjectionThreshold(uint256 newThreshold) external;

    // ================================
    // 🔹 Security & Governance Controls
    // ================================
    function pauseLiquidityOperations() external;
    function resumeLiquidityOperations() external;
    function whitelistAddress(address user, bool status) external;
    function isAddressWhitelisted(address user) external view returns (bool);

    // ================================
    // 🔹 Circuit Breaker Protection
    // ================================
    function triggerCircuitBreaker() external;
    function resetCircuitBreaker() external;
    function isCircuitBreakerTriggered() external view returns (bool);

    // ================================
    // 🔹 Liquidity Risk Management
    // ================================
    function setMaxDailyLiquidityWithdrawal(uint256 maxAmount) external;
    function getMaxDailyLiquidityWithdrawal() external view returns (uint256);
    function getDailyWithdrawalVolume() external view returns (uint256);

    // ================================
    // 🔹 View Functions
    // ================================
    function reinjectionThreshold() external view returns (uint256);
    function autoLiquidityInjectionRate() external view returns (uint256);
    function maxLiquidityPerAddress() external view returns (uint256);

    // ================================
    // 🔹 Events
    // ================================
    event LiquidityInjected(uint256 amount);
    event LiquidityCapUpdated(uint256 newCap);
    event LiquidityInjectionRateUpdated(uint256 newRate);
    event LiquidityReinjectionThresholdUpdated(uint256 newThreshold);
    event LiquidityPaused();
    event LiquidityResumed();
    event CircuitBreakerTriggered();
    event CircuitBreakerReset();
    event MaxDailyLiquidityWithdrawalUpdated(uint256 newLimit);
    event AddressWhitelisted(address indexed user, bool status);
}
