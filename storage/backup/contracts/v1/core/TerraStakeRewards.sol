// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/ITerraStakeRewards.sol";

contract TerraStakeRewards is 
    ITerraStakeRewards,
    ERC20Upgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable 
{
    uint256 public constant MAX_MULTIPLIER = 10000; // Basis points
    uint256 public constant MIN_REWARD_RATE = 1;

    IERC20 public rewardToken;
    address public stakingContract;
    uint256 public baseRewardRate;
    uint256 public totalRewardsDistributed;
    uint256 public rewardPoolCount;
    bool public distributionPaused;

    mapping(uint256 => RewardPool) public rewardPools;
    mapping(address => mapping(uint256 => UserRewards)) public userRewards;

    // Initialization
    function initialize(
        address _rewardToken,
        address _stakingContract,
        uint256 _baseRewardRate,
        address admin
    ) external override initializer {
        require(_rewardToken != address(0), "Invalid reward token");
        require(_stakingContract != address(0), "Invalid staking contract");
        require(admin != address(0), "Invalid admin address");
        require(_baseRewardRate >= MIN_REWARD_RATE, "Reward rate too low");

        __ERC20_init("TSTAKE", "TSTAKE");
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        rewardToken = IERC20(_rewardToken);
        stakingContract = _stakingContract;
        baseRewardRate = _baseRewardRate;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // Staking Contract Management
    function setStakingContract(address _stakingContract) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_stakingContract != address(0), "Invalid staking contract");
        stakingContract = _stakingContract;
    }

    // Reward Pool Management
    function createRewardPool(
        uint256 amount,
        uint32 multiplier,
        uint48 duration
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 poolId) {
        require(amount > 0, "Invalid pool amount");
        require(multiplier > 0 && multiplier <= MAX_MULTIPLIER, "Invalid multiplier");
        require(duration > 0, "Invalid duration");

        poolId = rewardPoolCount++;
        RewardPool storage pool = rewardPools[poolId];
        pool.available = uint128(amount);
        pool.multiplier = multiplier;
        pool.endBlock = uint48(block.number + duration);
        pool.isActive = true;
        pool.lastHalvingTime = block.timestamp;

        rewardToken.transferFrom(msg.sender, address(this), amount);
        emit RewardPoolCreated(poolId, amount, multiplier);
    }

    function applyHalving(uint256 poolId) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        RewardPool storage pool = rewardPools[poolId];
        require(pool.isActive, "Inactive pool");

        uint128 oldAvailable = pool.available;
        pool.available /= 2;
        pool.halvingCount++;
        pool.lastHalvingTime = block.timestamp;

        emit HalvingApplied(poolId, oldAvailable, pool.available, pool.halvingCount, block.timestamp);
    }

    function toggleRewardPool(uint256 poolId) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        RewardPool storage pool = rewardPools[poolId];
        pool.isActive = !pool.isActive;
        emit PoolDeactivated(poolId);
    }

    function drainRewardPool(uint256 poolId, uint256 amount) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        RewardPool storage pool = rewardPools[poolId];
        require(pool.isActive, "Inactive pool");
        require(pool.available >= amount, "Insufficient balance in pool");

        pool.available -= uint128(amount);
        rewardToken.transfer(msg.sender, amount);
        emit RewardPoolDrained(poolId, amount);
    }

    function toggleDistributionStatus() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        distributionPaused = !distributionPaused;
        emit DistributionStatusChanged(distributionPaused);
    }

    // Reward Distribution
    function distributeRewards(
        uint256 poolId,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(recipients.length == amounts.length, "Mismatched array lengths");
        RewardPool storage pool = rewardPools[poolId];
        require(pool.isActive, "Inactive pool");

        for (uint256 i = 0; i < recipients.length; i++) {
            require(pool.available >= amounts[i], "Insufficient pool balance");
            pool.available -= uint128(amounts[i]);
            userRewards[recipients[i]][poolId].pending += uint128(amounts[i]);

            emit RewardsDistributed(poolId, amounts[i]);
        }
    }

    function claimRewards(uint256 poolId) external override nonReentrant whenNotPaused {
        uint256 rewards = _claimRewards(msg.sender, poolId);
        require(rewards > 0, "No rewards to claim");
        rewardToken.transfer(msg.sender, rewards);
        emit RewardsClaimed(msg.sender, poolId, rewards);
    }

    function batchClaimRewards(uint256[] calldata poolIds) external override nonReentrant whenNotPaused {
        uint256 totalClaimed = 0;
        for (uint256 i = 0; i < poolIds.length; i++) {
            totalClaimed += _claimRewards(msg.sender, poolIds[i]);
        }
        require(totalClaimed > 0, "No rewards to claim");
    }

    // Internal Reward Logic
    function _claimRewards(address user, uint256 poolId) internal returns (uint256 rewards) {
        UserRewards storage userReward = userRewards[user][poolId];
        RewardPool storage pool = rewardPools[poolId];
        require(pool.isActive, "Inactive pool");

        rewards = calculateReward(user, poolId);
        if (rewards > 0) {
            userReward.claimed += uint128(rewards);
            userReward.pending = 0;
            pool.distributed += uint128(rewards);
            totalRewardsDistributed += rewards;
        }
    }

    function calculateReward(address user, uint256 poolId) public view override returns (uint256) {
        UserRewards storage userReward = userRewards[user][poolId];
        RewardPool storage pool = rewardPools[poolId];
        if (!pool.isActive || userReward.pending == 0) return 0;
        return (userReward.pending * pool.multiplier) / MAX_MULTIPLIER;
    }

    function getPoolInfo(uint256 poolId) external view override returns (
        uint128 available,
        uint128 distributed,
        uint48 lastUpdateBlock,
        uint48 endBlock,
        uint32 multiplier,
        bool isActive,
        uint256 halvingCount
    ) {
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

    function getUserRewardInfo(address user, uint256 poolId) external view override returns (
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

    function getTotalPendingRewards(address user) external view override returns (uint256 totalPending) {
        for (uint256 i = 0; i < rewardPoolCount; i++) {
            totalPending += userRewards[user][i].pending;
        }
    }
}
