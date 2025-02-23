// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IRewardDistributor {
    // ================================
    // 🔹 Governance & Roles
    // ================================
    function STAKING_CONTRACT_ROLE() external view returns (bytes32);
    function GOVERNANCE_ROLE() external view returns (bytes32);
    function MULTISIG_ROLE() external view returns (bytes32);

    // ================================
    // 🔹 Core Token & Liquidity Variables
    // ================================
    function rewardToken() external view returns (address);
    function uniswapRouter() external view returns (address);
    function rewardSource() external view returns (address);
    function stakingContract() external view returns (address);
    function liquidityPool() external view returns (address);
    function daoGovernance() external view returns (address);
    function liquidityGuard() external view returns (address);
    function slashingContract() external view returns (address);

    function totalDistributed() external view returns (uint256);
    function distributionLimit() external view returns (uint256);
    function minLiquidityReserve() external view returns (uint256);

    // ================================
    // 🔹 Halving & APR Boost Variables
    // ================================
    function halvingEpoch() external view returns (uint256);
    function lastHalvingTime() external view returns (uint256);
    function halvingPeriod() external view returns (uint256);
    function halvingReductionRate() external view returns (uint256);
    function aprBoostMultiplier() external view returns (uint256);
    function autoBuybackEnabled() external view returns (bool);

    // ================================
    // 🔹 Liquidity & Penalty Distribution Variables
    // ================================
    function liquidityInjectionRate() external view returns (uint256);
    function buybackPercentage() external view returns (uint256);
    function burnPercentage() external view returns (uint256);
    function reinvestPercentage() external view returns (uint256);
    function LOW_STAKING_THRESHOLD() external view returns (uint256);

    // ================================
    // 🔹 Reward & Liquidity Functions
    // ================================
    function distributeReward(address user, uint256 amount) external;

    function distributePenaltyRewards(uint256 amount) external;

    function toggleAutoBuyback() external;

    function calculateReward(uint256 baseReward) external view returns (uint256);

    function executeBuyback(uint256 amount) external;

    function burnTokens(uint256 amount) external;

    function injectLiquidity(uint256 amount) external;

    // ================================
    // 🔹 Halving & APR Boost Functions
    // ================================
    function applyHalving() external;

    function updateHalvingPeriod(uint256 newPeriod) external;

    function updateAPRBoostMultiplier(uint256 newMultiplier) external;

    function updateHalvingReductionRate(uint256 newRate) external;

    function requestHalvingUpdate() external;

    function confirmHalvingUpdate() external;

    // ================================
    // 🔹 Chainlink VRF for Secure Halving Updates
    // ================================
    function requestRandomHalving() external returns (bytes32 requestId);

    function fulfillRandomHalving(bytes32 requestId, uint256 randomness) external;

    function pendingHalvingRequests(bytes32 requestId) external view returns (bool);

    // ================================
    // 🔹 Emergency Functions (Multi-Sig Secured)
    // ================================
    function requestEmergencyWithdraw(address recipient, uint256 amount) external;

    function executeEmergencyWithdraw() external;

    // ================================
    // 🔹 Events for Transparency & Governance
    // ================================
    event RewardDistributed(address indexed user, uint256 amount);
    event RewardSourceUpdated(address indexed oldSource, address indexed newSource);
    event DistributionLimitUpdated(uint256 oldLimit, uint256 newLimit);
    event MinLiquidityReserveUpdated(uint256 oldReserve, uint256 newReserve);
    event EmergencyWithdrawalRequested(address indexed recipient, uint256 amount, uint256 unlockTime);
    event EmergencyWithdrawExecuted(address indexed recipient, uint256 amount);
    event APRBoostApplied(uint256 totalStaked, uint256 newAPR);
    event HalvingApplied(uint256 newRewardRate, uint256 halvingEpoch);
    event HalvingPeriodUpdated(uint256 newPeriod);
    event APRBoostMultiplierUpdated(uint256 newMultiplier);
    event HalvingReductionRateUpdated(uint256 newRate);
    event BuybackExecuted(uint256 amount);
    event PenaltyRewardsDistributed(uint256 amount, uint256 recipients);
    event AutoBuybackToggled(bool status);
    event LiquidityInjected(uint256 amount);
    event TokensBurned(uint256 amount);
    event SlashingEnforced(address indexed user, uint256 penaltyAmount);
    event HalvingUpdateRequested(bytes32 requestId);
    event HalvingUpdateConfirmed(uint256 newReductionRate);
}
