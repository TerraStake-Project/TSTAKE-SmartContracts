// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITerraStakeLiquidityGuard {
    // ================================
    // 🔹 Governance & Roles
    // ================================
    function GOVERNANCE_ROLE() external view returns (bytes32);
    function EMERGENCY_ROLE() external view returns (bytes32);

    // ================================
    // 🔹 Token & Liquidity References
    // ================================
    function tStakeToken() external view returns (address);
    function usdcToken() external view returns (address);
    function positionManager() external view returns (address);
    function uniswapPool() external view returns (address);

    // ================================
    // 🔹 Liquidity Management Variables
    // ================================
    function reinjectionThreshold() external view returns (uint256);
    function autoLiquidityInjectionRate() external view returns (uint256);
    function maxLiquidityPerAddress() external view returns (uint256);
    function liquidityRemovalCooldown() external view returns (uint256);

    // ================================
    // 🔹 Circuit Breakers & Risk Limits
    // ================================
    function getVolumeLimit() external view returns (uint256);
    function getPriceImpactLimit() external view returns (uint256);
    function getStateValidation() external view returns (bytes32);
    function getCircuitBreakerStatus() external view returns (bool);
    function isLiquidityPaused() external view returns (bool);

    // ================================
    // 🔹 Liquidity Management Functions
    // ================================
    function injectLiquidity(uint256 amount) external;

    function updateReinjectionThreshold(uint256 newThreshold) external;

    function updateAutoLiquidityInjectionRate(uint256 newRate) external;

    function updateLiquidityCap(uint256 newCap) external;

    function updateLiquidityCooldown(uint256 newCooldown) external;

    function requestCooldownChange(uint256 newCooldown) external;

    function confirmCooldownChange(uint256 newCooldown) external;

    function lockLiquidity(
        uint256 tokenId,
        uint256 unlockStart,
        uint256 unlockEnd,
        uint256 releaseRate
    ) external;

    function withdrawLiquidity(uint256 tokenId, uint256 amount) external;

    function pauseLiquidityOperations() external;

    function resumeLiquidityOperations() external;

    function whitelistAddress(address user, bool status) external;

    // ================================
    // 🔹 Risk Monitoring & Circuit Breakers
    // ================================
    function checkPriceDeviation() external view returns (bool);
    function validateStateSync() external returns (bool);
    function getVolumeUsage() external view returns (uint256);
    function enforceCircuitBreaker() external;

    // ================================
    // 🔹 View Functions
    // ================================
    function userLiquidity(address user) external view returns (uint256);

    function lastLiquidityRemoval(address user) external view returns (uint256);

    function liquidityLocks(uint256 tokenId)
        external
        view
        returns (
            uint256 unlockStart,
            uint256 unlockEnd,
            uint256 releaseRate,
            bool isLocked
        );

    function liquidityWhitelist(address user) external view returns (bool);

    // ================================
    // 🔹 Events for Transparency
    // ================================
    event LiquidityAdded(address indexed provider, uint256 amountTSTAKE, uint256 amountUSDC);
    event LiquidityRemoved(address indexed provider, uint256 amountTSTAKE, uint256 amountUSDC);
    event LiquidityInjected(uint256 amount);
    event LiquidityLocked(uint256 indexed tokenId, uint256 unlockStart, uint256 unlockEnd, uint256 releaseRate);
    event LiquidityReinjectionThresholdUpdated(uint256 newThreshold);
    event LiquidityInjectionRateUpdated(uint256 newRate);
    event LiquidityCapUpdated(uint256 newCap);
    event CooldownUpdated(uint256 newCooldown);
    event LiquidityOperationsPaused();
    event LiquidityOperationsResumed();
    
    event CircuitBreakerTriggered(uint256 timestamp);
    event PriceDeviationDetected(uint256 deviation);
    event StateValidationComplete(bytes32 stateHash);
    event VolumeLimitUpdated(uint256 newLimit);
    event CircuitBreakerEnforced(uint256 timestamp);
}

