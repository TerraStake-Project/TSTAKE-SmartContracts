// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITerraStakeRewards {
    // ================================
    // 🔹 Data Structures
    // ================================
    struct RewardPool {
        uint128 available;
        uint128 distributed;
        uint48 endBlock;
        uint48 lastUpdateBlock;
        uint32 multiplier;
        bool isActive;
        uint256 halvingCount;
    }

    struct UserRewards {
        uint128 pending;
        uint128 claimed;
        uint48 lastClaimBlock;
        uint32 multiplier;
        uint256 stakingStart;
    }

    // ================================
    // 🔹 Events for Transparency
    // ================================
    event RewardPoolCreated(uint256 indexed poolId, uint256 amount, uint32 multiplier);
    event RewardsFunded(uint256 indexed projectId, uint256 amount);
    event RewardsDistributed(uint256 indexed poolId, address indexed recipient, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 indexed poolId, uint256 amount);
    event HalvingApplied(uint256 indexed poolId, uint128 oldAvailable, uint128 newAvailable, uint256 halvingCount, uint256 timestamp);
    event RewardPoolDeactivated(uint256 indexed poolId);
    event UserCapUpdated(uint256 newCap);
    event StakingContractUpdated(address newStakingContract);
    event GovernanceTimelockSet(bytes32 indexed setting, uint256 newValue, uint256 unlockTime);
    event GovernanceTimelockExecuted(bytes32 indexed setting, uint256 oldValue, uint256 newValue);

    // ================================
    // 🔹 Reward Pool Management
    // ================================
    function createRewardPool(uint256 amount, uint32 multiplier, uint48 duration) external returns (uint256);
    function deactivateRewardPool(uint256 poolId) external;
    function fundProjectRewards(uint256 projectId, uint256 amount) external;

    // ================================
    // 🔹 Reward Distribution & Claims
    // ================================
    function batchClaimRewards(uint256[] calldata poolIds) external;
    
    // ================================
    // 🔹 Halving & Adjustments
    // ================================
    function applyHalving(uint256 poolId) external;
    function setUserRewardCap(uint256 newCap) external;

    // ================================
    // 🔹 View Functions for Transparency
    // ================================
    function getPoolInfo(uint256 poolId) external view returns (
        uint128 available,
        uint128 distributed,
        uint48 lastUpdateBlock,
        uint48 endBlock,
        uint32 multiplier,
        bool isActive,
        uint256 halvingCount
    );

    function getUserRewardInfo(address user, uint256 poolId) external view returns (
        uint128 pending,
        uint128 claimed,
        uint48 lastClaimBlock,
        uint32 multiplier,
        uint256 stakingStart
    );

    function getTotalPendingRewards(address user) external view returns (uint256);

    // ================================
    // 🔹 Governance & Security
    // ================================
    function setGovernanceTimelock(bytes32 setting, uint256 newValue) external;
    function executeGovernanceTimelock(bytes32 setting, uint256 newValue) external;

    // ================================
    // 🔹 Administrative Functions
    // ================================
    function setStakingContract(address _stakingContract) external;
}
