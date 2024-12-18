// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ITerraStakeRewards {
    // Structs
    struct RewardPool {
        uint128 available;
        uint128 distributed;
        uint48 lastUpdateBlock;
        uint48 endBlock;
        uint32 multiplier;
        bool isActive;
        uint256 halvingCount;
        uint256 lastHalvingTime;
    }

    struct UserRewards {
        uint128 pending;
        uint128 claimed;
        uint48 lastClaimBlock;
        uint32 multiplier;
        uint256 stakingStart;
    }

    // Functions
    function initialize(
        address _rewardToken,
        address _stakingContract,
        uint256 _baseRewardRate,
        address admin
    ) external;

    function setStakingContract(address _stakingContract) external;

    function createRewardPool(uint256 amount, uint32 multiplier, uint48 duration) external returns (uint256 poolId);

    function applyHalving(uint256 poolId) external;

    function claimRewards(uint256 poolId) external;

    function batchClaimRewards(uint256[] calldata poolIds) external;

    function distributeRewards(
        uint256 poolId,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external;

    function calculateReward(address user, uint256 poolId) external view returns (uint256);

    function toggleDistributionStatus() external;

    function toggleRewardPool(uint256 poolId) external;

    function drainRewardPool(uint256 poolId, uint256 amount) external;

    function getTotalPendingRewards(address user) external view returns (uint256);

    function getPoolInfo(uint256 poolId) external view returns (
        uint128 available,
        uint128 distributed,
        uint48 lastUpdateBlock,
        uint48 endBlock,
        uint32 multiplier,
        bool isActive,
        uint256 halvingCount
    );

    function getUserRewardInfo(
        address user,
        uint256 poolId
    ) external view returns (
        uint128 pending,
        uint128 claimed,
        uint48 lastClaimBlock,
        uint32 multiplier,
        uint256 stakingStart
    );

    // Events
    event RewardPoolCreated(uint256 indexed poolId, uint256 amount, uint256 multiplier);
    event RewardsClaimed(address indexed user, uint256 indexed poolId, uint256 amount);
    event HalvingApplied(uint256 indexed poolId, uint256 oldAvailableRewards, uint256 newAvailableRewards, uint256 halvingCount, uint256 timestamp);
    event DistributionStatusChanged(bool isPaused);
    event RewardPoolDrained(uint256 indexed poolId, uint256 amount);
    event RewardsDistributed(uint256 indexed poolId, uint256 amount);
    event PoolDeactivated(uint256 indexed poolId);
}
