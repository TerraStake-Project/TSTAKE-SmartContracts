// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "../interfaces/ITerraStakeRewards.sol";

contract TerraStakeRewards is
    ITerraStakeRewards,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    uint256 public constant MAX_MULTIPLIER = 10000; // Basis points
    uint256 public constant MIN_REWARD_RATE = 1;

    IERC20 public rewardToken;
    address public stakingContract;
    uint256 public baseRewardRate;
    uint256 public totalRewardsDistributed;
    uint256 public rewardPoolCount;

    // Halving mechanism
    uint256 public constant AVERAGE_BLOCK_TIME = 13; // Ethereum average block time in seconds
    uint256 public constant TWO_YEARS_BLOCKS = (2 * 365 * 24 * 60 * 60) / AVERAGE_BLOCK_TIME; // Approx. 2 years in blocks
    uint256 public halvingInterval;
    uint256 public lastHalvingBlock;
    uint256 public userRewardCap;

    mapping(uint256 => RewardPool) public rewardPools;
    mapping(address => mapping(uint256 => UserRewards)) public userRewards;
    mapping(uint256 => bool) public projectHasPool;

    modifier onlyStakingContract() {
        require(msg.sender == stakingContract, "Caller is not staking contract");
        _;
    }

    function initialize(
        address _rewardToken,
        address _stakingContract,
        uint256 _baseRewardRate,
        uint256 _userRewardCap,
        address admin
    ) external initializer {
        require(_rewardToken != address(0), "Invalid reward token");
        require(_stakingContract != address(0), "Invalid staking contract");
        require(admin != address(0), "Invalid admin address");
        require(_baseRewardRate >= MIN_REWARD_RATE, "Reward rate too low");

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        rewardToken = IERC20(_rewardToken);
        stakingContract = _stakingContract;
        baseRewardRate = _baseRewardRate;
        halvingInterval = TWO_YEARS_BLOCKS; // Approx. blocks for 2 years
        lastHalvingBlock = block.number;
        userRewardCap = _userRewardCap;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setStakingContract(address _stakingContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_stakingContract != address(0), "Invalid staking contract");
        stakingContract = _stakingContract;
    }

    function createRewardPool(
        uint256 amount,
        uint32 multiplier,
        uint48 duration
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 poolId) {
        require(amount > 0, "Invalid amount");
        require(multiplier > 0 && multiplier <= MAX_MULTIPLIER, "Invalid multiplier");
        require(duration > 0, "Invalid duration");

        poolId = rewardPoolCount++;
        RewardPool storage pool = rewardPools[poolId];
        pool.available = uint128(amount);
        pool.multiplier = multiplier;
        pool.endBlock = uint48(block.number + duration);
        pool.isActive = true;

        require(rewardToken.transferFrom(msg.sender, address(this), amount), "Reward transfer failed");
        emit RewardPoolCreated(poolId, amount, multiplier);
    }

    function fundProjectRewards(
        uint256 projectId,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(amount > 0, "Invalid amount");
        require(projectHasPool[projectId], "Project does not have a pool");

        RewardPool storage pool = rewardPools[projectId];
        require(pool.isActive, "Inactive pool");

        pool.available += uint128(amount);
        require(rewardToken.transferFrom(msg.sender, address(this), amount), "Reward transfer failed");

        emit RewardsFunded(projectId, amount);
    }

    function createProjectPool(
        uint256 projectId,
        uint256 amount,
        uint32 multiplier,
        uint48 duration
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(amount > 0, "Invalid amount");
        require(multiplier > 0 && multiplier <= MAX_MULTIPLIER, "Invalid multiplier");
        require(duration > 0, "Invalid duration");
        require(!projectHasPool[projectId], "Project already has a pool");

        projectHasPool[projectId] = true;

        RewardPool storage pool = rewardPools[projectId];
        pool.available = uint128(amount);
        pool.multiplier = multiplier;
        pool.endBlock = uint48(block.number + duration);
        pool.isActive = true;

        require(rewardToken.transferFrom(msg.sender, address(this), amount), "Reward transfer failed");
        emit RewardPoolCreated(projectId, amount, multiplier);
    }

    function applyHalving(uint256 poolId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(block.number >= lastHalvingBlock + halvingInterval, "Halving interval not reached");
        RewardPool storage pool = rewardPools[poolId];
        require(pool.isActive, "Inactive pool");

        uint128 oldAvailable = pool.available;
        pool.available /= 2;
        pool.halvingCount++;
        lastHalvingBlock = block.number;
        emit HalvingApplied(poolId, oldAvailable, pool.available, pool.halvingCount, block.timestamp);
    }

    function distributeRewards(
        uint256 poolId,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external onlyStakingContract nonReentrant {
        require(recipients.length == amounts.length, "Mismatched arrays");
        RewardPool storage pool = rewardPools[poolId];
        require(pool.isActive, "Inactive pool");

        for (uint256 i = 0; i < recipients.length; i++) {
            require(pool.available >= amounts[i], "Insufficient pool balance");
            pool.available -= uint128(amounts[i]);
            userRewards[recipients[i]][poolId].pending += uint128(amounts[i]);

            emit RewardsDistributed(poolId, recipients[i], amounts[i]);
        }
    }

    function claimRewards(uint256 poolId) external nonReentrant whenNotPaused {
        uint256 rewards = _claimRewards(msg.sender, poolId);
        require(rewards > 0, "No rewards");
        require(rewards <= userRewardCap, "Reward exceeds cap");

        require(rewardToken.transfer(msg.sender, rewards), "Transfer failed");
        emit RewardsClaimed(msg.sender, poolId, rewards);
    }

    function _claimRewards(address user, uint256 poolId) internal returns (uint256) {
        UserRewards storage userReward = userRewards[user][poolId];
        RewardPool storage pool = rewardPools[poolId];
        require(pool.isActive, "Inactive pool");

        uint256 rewards = userReward.pending;
        if (rewards == 0) return 0;

        userReward.pending = 0;
        userReward.claimed += uint128(rewards);
        pool.distributed += uint128(rewards);
        totalRewardsDistributed += rewards;
        return rewards;
    }

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
        )
    {
        RewardPool storage pool = rewardPools[poolId];
        return (
            pool.available,
            pool.distributed,
            pool.lastUpdateBlock,
            pool.endBlock,
            pool.multiplier,
            pool.isActive,
            pool.halvingCount
        );
    }

    function getUserRewardInfo(
        address user,
        uint256 poolId
    ) external view returns (
        uint128 pending,
        uint128 claimed,
        uint48 lastClaimBlock,
        uint32 multiplier,
        uint256 stakingStart
    ) {
        UserRewards storage userReward = userRewards[user][poolId];
        return (
            userReward.pending,
            userReward.claimed,
            userReward.lastClaimBlock,
            userReward.multiplier,
            userReward.stakingStart
        );
    }

    // ------------------------------------------------------------------------
    // MISSING FUNCTIONS FROM ITerraStakeRewards INTERFACE
    // ------------------------------------------------------------------------

    /**
     * @dev Claims rewards from multiple pools in a single call.
     *      You can decide whether to do a single cumulative transfer
     *      or do one per pool. This example does one per pool.
     */
    function batchClaimRewards(uint256[] calldata poolIds)
        external
        override
        nonReentrant
        whenNotPaused
    {
        for (uint256 i = 0; i < poolIds.length; i++) {
            uint256 rewards = _claimRewards(msg.sender, poolIds[i]);
            if (rewards > 0) {
                require(rewards <= userRewardCap, "Reward exceeds cap");
                require(rewardToken.transfer(msg.sender, rewards), "Transfer failed");
                emit RewardsClaimed(msg.sender, poolIds[i], rewards);
            }
        }
    }

    /**
     * @dev Returns the total pending (unclaimed) rewards for `user` across
     *      all reward pools up to `rewardPoolCount - 1`. If you also use
     *      `createProjectPool()` with IDs outside that range, consider
     *      extending logic here accordingly.
     */
    function getTotalPendingRewards(address user)
        external
        view
        override
        returns (uint256 total)
    {
        // Summation of pending rewards in standard (non-project) pools
        for (uint256 i = 0; i < rewardPoolCount; i++) {
            total += userRewards[user][i].pending;
        }

        // If project-based pools have IDs outside [0..rewardPoolCount-1],
        // you'll need logic here to include those as well.

        return total;
    }

    /**
     * @dev Returns whether a project already has a reward pool.
     */
    function isProjectHasPool(uint256 projectId)
        external
        view
        override
        returns (bool)
    {
        return projectHasPool[projectId];
    }
}
