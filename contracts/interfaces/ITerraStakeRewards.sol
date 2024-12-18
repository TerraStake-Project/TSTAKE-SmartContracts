// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITerraStakeRewards {
    struct RewardPool {
        uint128 available;         // Tokens available for rewards
        uint128 distributed;       // Tokens already distributed
        uint48 lastUpdateBlock;    // Last block when rewards were updated
        uint48 endBlock;           // End block of the reward pool
        uint32 multiplier;         // Reward multiplier in basis points
        bool isActive;             // Is the pool active
        uint256 halvingCount;
        uint256 lastHalvingTime;
    }

    struct UserRewards {
        uint128 pending;           // Pending rewards to claim
        uint128 claimed;           // Already claimed rewards
        uint48 lastClaimBlock;
        uint32 multiplier;
        uint256 stakingStart;
    }

    // Initialization
    /// @notice Initializes the contract
    /// @param _rewardToken Address of the reward token
    /// @param _stakingContract Address of the associated staking contract
    /// @param _baseRewardRate Base reward rate
    /// @param _halvingInterval Blocks between halving events
    /// @param admin Address of the admin
    function initialize(
        address _rewardToken,
        address _stakingContract,
        uint256 _baseRewardRate,
        uint256 _halvingInterval,
        uint256 _userRewardCap,
        address admin
    ) external;

    /// @notice Updates the associated staking contract
    /// @param _stakingContract Address of the new staking contract
    function setStakingContract(address _stakingContract) external;

    // Pool Management
    /// @notice Creates a new reward pool
    /// @param amount Amount of tokens for the pool
    /// @param multiplier Multiplier for the pool rewards
    /// @param duration Duration of the reward pool in blocks
    /// @return poolId ID of the created reward pool
    function createRewardPool(
        uint256 amount,
        uint32 multiplier,
        uint48 duration
    ) external returns (uint256 poolId);

    // Pool Management
    /// @notice Creates a new project pool
    /// @param projectId ID of the project
    /// @param multiplier Multiplier for the pool rewards
    /// @param duration Duration of the project pool in blocks
    function createProjectPool(
        uint256 projectId,
        uint256 verificationFee,
        uint32 multiplier,
        uint48 duration
    ) external;

    function fundProjectRewards(
        uint256 projectId,
        uint256 verificationFee
    ) external;

    /// @notice Distributes rewards to multiple recipients from a pool
    /// @param poolId ID of the reward pool
    /// @param recipients Addresses to receive the rewards
    /// @param amounts Reward amounts for each recipient
    function distributeRewards(
        uint256 poolId,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external;

    // Halving Mechanism
    /// @notice Applies the halving mechanism to reduce base reward rate
    function applyHalving(uint256 poolId) external;

    // Claiming Rewards
    /// @notice Claims rewards from a specific pool
    /// @param poolId ID of the reward pool
    function claimRewards(uint256 poolId) external;

    /// @notice Claims rewards from multiple pools
    /// @param poolIds IDs of the reward pools
    function batchClaimRewards(uint256[] calldata poolIds) external;

    // View Functions
    /// @notice Retrieves information about a reward pool
    /// @param poolId ID of the reward pool
    /// @return available Tokens available for rewards
    /// @return distributed Tokens already distributed
    /// @return lastUpdateBlock Last block when rewards were updated
    /// @return endBlock End block of the reward pool
    /// @return multiplier Reward multiplier in basis points
    /// @return isActive Indicates if the pool is active
    function getPoolInfo(uint256 poolId)
        external
        view
        returns (
            uint128 available,
            uint128 distributed,
            uint48 lastUpdateBlock,
            uint48 endBlock,
            uint32 multiplier,
            bool isActive,
            uint256 halvingCount
        );

    /// @notice Retrieves reward details for a user from a specific pool
    /// @param user Address of the user
    /// @param poolId ID of the reward pool
    /// @return pending Pending rewards for the user
    /// @return claimed Already claimed rewards for the user
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

    /// @notice Calculates the total pending rewards for a user across all pools
    /// @param user Address of the user
    /// @return totalPending Total pending rewards for the user
    function getTotalPendingRewards(address user) external view returns (uint256);

    function isProjectHasPool(uint256 projectId) external view returns (bool);

    // Events
    /// @notice Emitted when a new reward pool is created
    /// @param poolId ID of the created reward pool
    /// @param amount Amount of tokens in the reward pool
    /// @param multiplier Reward multiplier for the pool
    event RewardPoolCreated(uint256 indexed poolId, uint256 amount, uint32 multiplier);

    /// @notice Emitted when rewards are distributed from a pool
    /// @param poolId ID of the reward pool
    /// @param recipient Address of the reward recipient
    /// @param amount Amount of rewards distributed
    event RewardsDistributed(uint256 indexed poolId, address indexed recipient, uint256 amount);

    /// @notice Emitted when a user claims rewards from a pool
    /// @param user Address of the user
    /// @param poolId ID of the reward pool
    /// @param amount Amount of rewards claimed
    event RewardsClaimed(address indexed user, uint256 indexed poolId, uint256 amount);

    /// @notice Emitted when the halving mechanism is applied
    event HalvingApplied(uint256 indexed poolId, uint256 oldAvailableRewards, uint256 newAvailableRewards, uint256 halvingCount, uint256 timestamp);
}
