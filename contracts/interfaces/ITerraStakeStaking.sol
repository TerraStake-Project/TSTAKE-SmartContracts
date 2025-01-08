// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITerraStakeStaking {
    struct InitializeParams {
        address stakingToken;          // Address of the staking token
        uint256 rewardRate;            // Reward rate per second
        uint256 lockPeriod;            // Lock period for staking (in seconds)
        uint256 maxStake;              // Maximum amount a user can stake
        uint256 gracePeriod;           // Grace period for unstaking without penalty
        address admin;                 // Admin address
    }

    struct StakingPosition {
        uint128 amount;                // Total staked amount
        uint128 rewardDebt;            // Rewards already claimed or pending
        uint128 lastCheckpoint;        // Last checkpoint for reward calculations
        uint48 stakingStart;           // Timestamp when the staking started
    }

    struct ProjectData {
        bool isActive;                 // Whether the project is active
        bool isPaused;
        uint128 totalStaked;           // Total staked in the project
        uint128 rewardPool;
        uint32 stakingMultiplier;      // Multiplier applied to rewards for this project
        uint32 withdrawalLimit;        // Maximum withdrawal limit
        uint32 penaltyRate;            // Penalty rate for early unstaking
        uint32 rewardUpdateInterval;
    }

    // Events
    event Staked(address indexed user, uint256 projectId, uint256 amount);
    event Unstaked(address indexed user, uint256 projectId, uint256 amount, uint256 penalty);
    event RewardsClaimed(address indexed user, uint256 projectId, uint256 amount);
    event ProjectUpdated(uint256 indexed projectId, uint32 stakingMultiplier);
    event PenaltyRateUpdated(uint256 projectId, uint32 newRate);
    event GracePeriodUpdated(uint256 newGracePeriod);
    event MaxStakeUpdated(uint256 newMaxStake);
    event RewardDistributorUpdated(address indexed oldDistributor, address indexed newDistributor);

    // Core Functions
    function initialize(InitializeParams calldata params, address rewardDistributor) external;

    function stake(uint256 projectId, uint256 amount) external;
    function unstake(uint256 projectId) external;
    function claimRewards(uint256 projectId) external;

    // Governance Functions
    function configureProject(
        uint256 projectId,
        uint32 stakingMultiplier,
        uint32 withdrawalLimit,
        uint32 rewardUpdateInterval
    ) external;

    function updatePenaltyRate(uint256 projectId, uint32 newRate) external;
    function updateGracePeriod(uint256 newGracePeriod) external;
    function updateMaxStake(uint256 newMaxStake) external;

    function updateRewardDistributor(address newDistributor) external;

    function updateProjectStakingData(uint256 projectId, uint32 stakingMultiplier) external;

    // View Functions
    function getStakingPosition(address user, uint256 projectId)
        external
        view
        returns (uint128 amount, uint128 rewardDebt, uint128 lastCheckpoint, uint48 stakingStart);

    function getProjectDetails(uint256 projectId)
        external
        view
        returns (
            uint32 stakingMultiplier,
            uint32 withdrawalLimit,
            uint32 penaltyRate,
            uint32 rewardUpdateInterval,
            uint128 totalStaked_,
            uint128 rewardPool,
            bool isActive,
            bool isPaused
        );

    function calculateProjectedRewards(
        address user,
        uint256 projectId,
        uint256 duration
    ) external view returns (uint256 projectedRewards);

    // New View Functions (optional for enhanced detail)
    function getRewardDistributor() external view returns (address);

    function getTotalStaked() external view returns (uint256);
    function totalStakedByUser(address user) external view returns(uint256);
}