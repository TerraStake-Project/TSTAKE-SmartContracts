// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "../interfaces/ITerraStakeStaking.sol";

contract TerraStakeStaking is 
    ITerraStakeStaking, 
    ReentrancyGuardUpgradeable, 
    PausableUpgradeable, 
    AccessControlUpgradeable 
{
    IERC20 public stakingToken;
    IERC20 public rewardToken;

    uint256 public rewardRate;
    uint256 public lockPeriod;
    uint256 public maxStake;
    uint256 public minRewardRate;
    uint256 public maxRewardRate;
    uint256 public autoUpdateInterval;
    uint256 public updateIncentiveRate;
    uint256 public gracePeriod;

    uint256 public totalStaked;
    uint256[] public activeProjects;

    mapping(address => mapping(uint256 => StakingPosition)) public stakingPositions;
    mapping(uint256 => ProjectData) public projects;
    mapping(address => uint256) public userStakeCap;

    bytes32 public constant PROJECT_MANAGER_ROLE = keccak256("PROJECT_MANAGER_ROLE");
    bytes32 public constant STAKING_MANAGER_ROLE = keccak256("STAKING_MANAGER_ROLE");

    event UserStakeCapped(address indexed user, uint256 cap);
    event GracePeriodConfigured(uint256 newGracePeriod);
    event StakeSlashed(address indexed user, uint256 indexed projectId, uint256 slashAmount);
    event RewardsHalved(uint256 indexed projectId, uint256 oldReward, uint256 newReward);
    event ProjectEnforcedUnstake(uint256 indexed projectId, uint256 totalUnstaked);
    event RewardRateUpdated(uint256 newRate);

    function initialize(InitializeParams calldata params) external override initializer {
        require(params.stakingToken != address(0), "Invalid staking token");
        require(params.rewardToken != address(0), "Invalid reward token");
        require(params.admin != address(0), "Invalid admin address");

        __ReentrancyGuard_init();
        __Pausable_init();
        __AccessControl_init();

        stakingToken = IERC20(params.stakingToken);
        rewardToken = IERC20(params.rewardToken);
        rewardRate = params.rewardRate;
        lockPeriod = params.lockPeriod;
        maxStake = params.maxStake;
        minRewardRate = params.minRewardRate;
        maxRewardRate = params.maxRewardRate;
        autoUpdateInterval = params.autoUpdateInterval;
        updateIncentiveRate = params.updateIncentiveRate;
        gracePeriod = params.gracePeriod;

        _grantRole(DEFAULT_ADMIN_ROLE, params.admin);
        _grantRole(PROJECT_MANAGER_ROLE, params.admin);
        _grantRole(STAKING_MANAGER_ROLE, params.admin);
    }

    function stake(uint256 projectId, uint256 amount) external override nonReentrant whenNotPaused {
        require(amount > 0, "Invalid stake amount");
        require(amount <= maxStake, "Exceeds max stake limit");

        ProjectData storage project = projects[projectId];
        require(project.isActive && !project.isPaused, "Project not active");

        StakingPosition storage position = stakingPositions[msg.sender][projectId];
        _claimRewards(projectId);

        position.amount += uint128(amount);
        position.lastCheckpoint = uint128(block.timestamp);
        position.stakingStart = uint48(block.timestamp);

        project.totalStaked += uint128(amount);
        totalStaked += amount;

        stakingToken.transferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, projectId, amount);
    }

    function unstake(uint256 projectId) external override nonReentrant whenNotPaused {
        StakingPosition storage position = stakingPositions[msg.sender][projectId];
        require(position.amount > 0, "No stake found");

        uint256 timeSinceStake = block.timestamp - position.stakingStart;
        bool withinGracePeriod = timeSinceStake <= gracePeriod;

        uint256 penalty = withinGracePeriod ? 0 : (position.amount * projects[projectId].penaltyRate) / 10000;
        uint256 unstakeAmount = position.amount - penalty;

        position.amount = 0;
        position.rewardDebt = 0;

        projects[projectId].totalStaked -= uint128(unstakeAmount);
        totalStaked -= unstakeAmount;

        stakingToken.transfer(msg.sender, unstakeAmount);
        emit Unstaked(msg.sender, projectId, unstakeAmount, penalty);
    }

    function claimRewards(uint256 projectId) external override nonReentrant whenNotPaused {
        uint256 rewards = _claimRewards(projectId);
        require(rewards > 0, "No rewards available");

        rewardToken.transfer(msg.sender, rewards);
        emit RewardsClaimed(msg.sender, projectId, rewards);
    }

    function configureProject(
        uint256 projectId,
        uint32 stakingMultiplier,
        uint32 withdrawalLimit,
        uint32 rewardUpdateInterval
    ) external override onlyRole(PROJECT_MANAGER_ROLE) {
        ProjectData storage project = projects[projectId];
        project.stakingMultiplier = stakingMultiplier;
        project.withdrawalLimit = withdrawalLimit;
        project.rewardUpdateInterval = rewardUpdateInterval;

        emit ProjectUpdated(projectId, stakingMultiplier);
    }

    function toggleProjectStatus(uint256 projectId, bool isPaused) external override onlyRole(PROJECT_MANAGER_ROLE) {
        ProjectData storage project = projects[projectId];
        project.isPaused = isPaused;
        emit ProjectStatusToggled(projectId, isPaused);
    }

    function updateGracePeriod(uint256 newGracePeriod) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        gracePeriod = newGracePeriod;
        emit GracePeriodConfigured(newGracePeriod);
    }

    function updatePenaltyRate(uint256 projectId, uint32 newRate) external override onlyRole(PROJECT_MANAGER_ROLE) {
        ProjectData storage project = projects[projectId];
        project.penaltyRate = newRate;
        emit PenaltyRateUpdated(projectId, newRate);
    }

    function recoverERC20(address token, uint256 amount) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(token).transfer(msg.sender, amount);
        emit TokenRecovered(token, amount, msg.sender);
    }

    function getActiveProjects() external view override returns (uint256[] memory) {
        return activeProjects;
    }

    function getAllProjectData() external view override returns (ProjectData[] memory allProjects) {
        uint256 length = activeProjects.length;
        allProjects = new ProjectData[](length);

        for (uint256 i = 0; i < length; i++) {
            allProjects[i] = projects[activeProjects[i]];
        }
    }

    function getTotalRewards(address user) external view override returns (uint256 totalRewards) {
        for (uint256 i = 0; i < activeProjects.length; i++) {
            totalRewards += _calculateRewards(user, activeProjects[i]);
        }
        return totalRewards;
    }

    function calculateProjectedRewards(
        address user,
        uint256 projectId,
        uint256 duration
    ) external view override returns (uint256) {
        StakingPosition storage position = stakingPositions[user][projectId];
        ProjectData storage project = projects[projectId];

        if (position.amount == 0) return 0;

        return (position.amount * rewardRate * project.stakingMultiplier * duration) / (365 days * 10000);
    }

    function getProjectDetails(uint256 projectId) 
        external 
        view 
        override 
        returns (
            uint32 stakingMultiplier,
            uint32 withdrawalLimit,
            uint32 penaltyRate,
            uint32 rewardUpdateInterval,
            uint128 projectTotalStaked,
            uint128 rewardPool,
            bool isActive,
            bool isPaused
        )
    {
        ProjectData storage project = projects[projectId];
        return (
            project.stakingMultiplier,
            project.withdrawalLimit,
            project.penaltyRate,
            project.rewardUpdateInterval,
            project.totalStaked,
            project.rewardPool,
            project.isActive,
            project.isPaused
        );
    }

    function getStakingPosition(address user, uint256 projectId) 
        external 
        view 
        override 
        returns (
            uint128 amount, 
            uint128 rewardDebt, 
            uint128 lastCheckpoint, 
            uint48 stakingStart
        )
    {
        StakingPosition storage position = stakingPositions[user][projectId];
        return (
            position.amount,
            position.rewardDebt,
            position.lastCheckpoint,
            position.stakingStart
        );
    }

    function updateProjectStakingData(uint256 projectId, uint32 stakingMultiplier) 
        external 
        override 
        onlyRole(PROJECT_MANAGER_ROLE) 
    {
        ProjectData storage project = projects[projectId];
        project.stakingMultiplier = stakingMultiplier;
        emit ProjectUpdated(projectId, stakingMultiplier);
    }

    function _claimRewards(uint256 projectId) internal returns (uint256 rewards) {
        StakingPosition storage position = stakingPositions[msg.sender][projectId];
        ProjectData storage project = projects[projectId];

        rewards = _calculateRewards(msg.sender, projectId);
        require(project.rewardPool >= rewards, "Insufficient reward pool");

        project.rewardPool -= uint128(rewards);
        position.rewardDebt += uint128(rewards);
        position.lastCheckpoint = uint128(block.timestamp);
    }

    function _calculateRewards(address user, uint256 projectId) internal view returns (uint256) {
        StakingPosition storage position = stakingPositions[user][projectId];
        ProjectData storage project = projects[projectId];

        if (position.amount == 0) return 0;

        uint256 timeElapsed = block.timestamp - position.lastCheckpoint;
        return (position.amount * rewardRate * project.stakingMultiplier * timeElapsed) / (365 days * 10000);
    }
}
