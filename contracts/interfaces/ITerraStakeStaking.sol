// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ITerraStakeStaking {
    // ================================
    // 🔹 Token & Liquidity Management
    // ================================
    function stakingToken() external view returns (address);
    function nftContract() external view returns (address);
    function rewardDistributor() external view returns (ITerraStakeRewardDistributor);
    function liquidityPool() external view returns (address);

    function liquidityInjectionRate() external view returns (uint256);
    function autoLiquidityEnabled() external view returns (bool);
    function updateLiquidityInjectionRate(uint256 newRate) external;
    function toggleAutoLiquidity() external;

    // ================================
    // 🔹 Staking Functions
    // ================================
    function stake(
        uint256 projectId,
        uint256 amount,
        uint256 duration,
        bool isLP,
        bool autoCompound
    ) external;

    function unstake(uint256 projectId) external;

    function distributeRewards(uint256 projectId) external;

    function getDynamicAPR(bool isLP, bool hasNFT) external pure returns (uint256);

    // ================================
    // 🔹 Governance & Voting
    // ================================
    function governanceVotes(address user) external view returns (uint256);
    function governanceViolators(address user) external view returns (bool);

    function slashGovernanceVote(address user) external;

    // ================================
    // 🔹 Governance Reward Management
    // ================================
    function distributeGovernanceReward(address user, uint256 amount) external;
    function claimGovernanceRewards() external;

    function getPendingGovernanceRewards(address user) 
        external 
        view 
        returns (uint256 totalPending, uint256 totalClaimable);

    // ================================
    // 🔹 Halving Mechanism
    // ================================
    function halvingPeriod() external view returns (uint256);
    function lastHalvingTime() external view returns (uint256);
    function halvingEpoch() external view returns (uint256);
    function applyHalving() external;

    // ================================
    // 🔹 View Functions
    // ================================
    function totalStaked() external view returns (uint256);

    function stakingPositions(address user, uint256 projectId)
        external
        view
        returns (
            uint256 amount,
            uint256 lastCheckpoint,
            uint256 stakingStart,
            uint256 projectId_,
            uint256 duration,
            bool isLPStaker,
            bool hasNFTBoost,
            bool autoCompounding
        );

    function tiers(uint256 index)
        external
        view
        returns (
            uint256 minDuration,
            uint256 rewardMultiplier,
            bool governanceRights
        );

    // ================================
    // 🔹 Security Functions
    // ================================
    function pause() external;
    function unpause() external;

    // ================================
    // 🔹 Events
    // ================================
    event Staked(address indexed user, uint256 projectId, uint256 amount, uint256 duration);
    event Unstaked(address indexed user, uint256 projectId, uint256 amount, uint256 penalty);
    event RewardsDistributed(address indexed user, uint256 amount);
}
