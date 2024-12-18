// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITerraStakeStaking {
    struct InitializeParams {
        address stakingToken;
        address rewardToken;
        uint256 rewardRate; // base reward rate per token per second
        uint256 lockPeriod; // lock period in seconds
        uint256 maxStake;   // maximum stake amount per user
        uint256 minRewardRate;
        uint256 maxRewardRate;
        uint256 autoUpdateInterval; // interval in seconds for automatic updates
        uint256 updateIncentiveRate; // reward for updating project state
        uint256 gracePeriod; // grace period for penalty-free withdrawal
        address admin;       // admin address
    }

    struct StakingPosition {
        uint128 amount;
        uint128 rewardDebt;
        uint128 lastCheckpoint;
        uint128 accumulatedRewards;
        uint48 stakingStart;
    }

    struct ProjectData {
        bool isActive;
        bool isPaused;
        uint128 totalStaked;
        uint128 rewardPool;
        uint32 stakingMultiplier;
        uint32 withdrawalLimit;
        uint32 penaltyRate;
        uint32 rewardUpdateInterval;
    }

    // Events
    event Staked(address indexed user, uint256 projectId, uint256 amount);
    event Unstaked(address indexed user, uint256 projectId, uint256 amount, uint256 penalty);
    event RewardsClaimed(address indexed user, uint256 projectId, uint256 amount);
    event ProjectCreated(uint256 indexed projectId, uint32 stakingMultiplier);
    event ProjectUpdated(uint256 indexed projectId, uint32 stakingMultiplier);
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);
    event RewardPoolUpdated(uint256 indexed projectId, uint256 amount);
    event PenaltyRateUpdated(uint256 projectId, uint32 newRate);
    event GracePeriodUpdated(uint256 newGracePeriod);
    event TokenRecovered(address indexed token, uint256 amount, address indexed to);
    event ProjectStatusToggled(uint256 indexed projectId, bool isPaused);

    // Core Functions
    function initialize(InitializeParams calldata params) external;

    function stake(uint256 projectId, uint256 amount) external;

    function unstake(uint256 projectId) external;

    function claimRewards(uint256 projectId) external;

    function configureProject(
        uint256 projectId,
        uint32 stakingMultiplier,
        uint32 withdrawalLimit,
        uint32 rewardUpdateInterval
    ) external;

    function updatePenaltyRate(uint256 projectId, uint32 newRate) external;

    function updateGracePeriod(uint256 newGracePeriod) external;

    function recoverERC20(address token, uint256 amount) external;

    function toggleProjectStatus(uint256 projectId, bool isPaused) external;

    function updateProjectStakingData(uint256 projectId, uint32 stakingMultiplier) external;

    // View Functions
    function getStakingPosition(address user, uint256 projectId) 
        external 
        view 
        returns (
            uint128 amount, 
            uint128 rewardDebt, 
            uint128 lastCheckpoint, 
            uint48 stakingStart
        );

    function getProjectDetails(uint256 projectId)
        external
        view
        returns (
            uint32 stakingMultiplier,
            uint32 withdrawalLimit,
            uint32 penaltyRate,
            uint32 rewardUpdateInterval,
            uint128 totalStaked,
            uint128 rewardPool,
            bool isActive,
            bool isPaused
        );

    function getTotalRewards(address user) external view returns (uint256 totalRewards);

    function getActiveProjects() external view returns (uint256[] memory);

    function calculateProjectedRewards(
        address user, 
        uint256 projectId, 
        uint256 duration
    ) external view returns (uint256 projectedRewards);

    function getAllProjectData() 
        external 
        view 
        returns (ProjectData[] memory allProjects);
}
