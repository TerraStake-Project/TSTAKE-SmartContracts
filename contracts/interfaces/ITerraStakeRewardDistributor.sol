// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ITerraStakeRewardDistributor {
    // ================================
    // 🔹 Reward Distribution Functions
    // ================================
    function distributeReward(address user, uint256 amount) external;
    function distributePenaltyRewards(uint256 amount) external;

    // ================================
    // 🔹 Liquidity Management
    // ================================
    function injectLiquidity(uint256 amount) external;

    // ================================
    // 🔹 Halving & APR Adjustments
    // ================================
    function applyHalving() external;
    function updateHalvingPeriod(uint256 newPeriod) external;
    function updateAPRBoostMultiplier(uint256 newMultiplier) external;
    function halvingReductionRate() external view returns (uint256);

    // ================================
    // 🔹 View Functions
    // ================================
    function totalDistributed() external view returns (uint256);
    function halvingEpoch() external view returns (uint256);
    function lastHalvingTime() external view returns (uint256);

    // ================================
    // 🔹 Governance & Security
    // ================================
    function requestEmergencyWithdraw(address recipient, uint256 amount) external;
    function executeEmergencyWithdraw() external;

    // ================================
    // 🔹 Events
    // ================================
    event RewardDistributed(address indexed user, uint256 amount);
    event HalvingApplied(uint256 newRewardRate, uint256 halvingEpoch);
    event LiquidityInjected(uint256 amount);
}

