// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITerraStakeRewards {
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

    event RewardPoolCreated(uint256 indexed poolId, uint256 amount, uint32 multiplier);
    event RewardsFunded(uint256 indexed projectId, uint256 amount); // Add this
    event RewardsDistributed(uint256 indexed poolId, address indexed recipient, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 indexed poolId, uint256 amount);
    event HalvingApplied(uint256 poolId, uint128 oldAvailable, uint128 newAvailable, uint256 halvingCount, uint256 timestamp);

    function createRewardPool(uint256 amount, uint32 multiplier, uint48 duration) external returns (uint256);
    function fundProjectRewards(uint256 projectId, uint256 amount) external;
    function distributeRewards(uint256 poolId, address[] calldata recipients, uint256[] calldata amounts) external;
    function claimRewards(uint256 poolId) external;
    function batchClaimRewards(uint256[] calldata poolIds) external;
    function applyHalving(uint256 poolId) external;

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
    function isProjectHasPool(uint256 projectId) external view returns (bool);
}
