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
    // Custom Errors
    error InvalidStakeAmount();
    error ProjectNotActive();
    error NoStakeFound();
    error InsufficientRewardPool();
    error RewardsAlreadyClaimed();
    error InsufficientFundsForPenalty();

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
    uint256[] private activeProjects;

    mapping(address => mapping(uint256 => ITerraStakeStaking.StakingPosition)) public stakingPositions;
    mapping(uint256 => ITerraStakeStaking.ProjectData) public projects;
    mapping(address => uint256) public userStakeCap;

    // Roles
    bytes32 public constant PROJECT_MANAGER_ROLE = keccak256("PROJECT_MANAGER_ROLE");
    bytes32 public constant STAKING_MANAGER_ROLE = keccak256("STAKING_MANAGER_ROLE");

    function initialize(InitializeParams calldata params) external override initializer {
        if (
            params.stakingToken == address(0) ||
            params.rewardToken == address(0) ||
            params.admin == address(0)
        ) revert InvalidStakeAmount();

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

    function configureProject(
        uint256 projectId,
        uint32 stakingMultiplier,
        uint32 withdrawalLimit,
        uint32 rewardUpdateInterval
    ) external override onlyRole(PROJECT_MANAGER_ROLE) {
        ITerraStakeStaking.ProjectData storage project = projects[projectId];
        project.stakingMultiplier = stakingMultiplier;
        project.withdrawalLimit = withdrawalLimit;
        project.rewardUpdateInterval = rewardUpdateInterval;

        if (!project.isActive) {
            project.isActive = true;
            activeProjects.push(projectId);
        }
    }

    function updatePenaltyRate(uint256 projectId, uint32 newRate) external override onlyRole(PROJECT_MANAGER_ROLE) {
        projects[projectId].penaltyRate = newRate;
        emit PenaltyRateUpdated(projectId, newRate);
    }

    function updateGracePeriod(uint256 newGracePeriod) external override onlyRole(STAKING_MANAGER_ROLE) {
        gracePeriod = newGracePeriod;
        emit GracePeriodUpdated(newGracePeriod);
    }

    function recoverERC20(address token, uint256 amount) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(token).transfer(msg.sender, amount);
        emit TokenRecovered(token, amount, msg.sender);
    }

    function toggleProjectStatus(uint256 projectId, bool isPaused) external override onlyRole(PROJECT_MANAGER_ROLE) {
        projects[projectId].isPaused = isPaused;
        emit ProjectStatusToggled(projectId, isPaused);
    }

    function updateProjectStakingData(uint256 projectId, uint32 stakingMultiplier) external override onlyRole(PROJECT_MANAGER_ROLE) {
        projects[projectId].stakingMultiplier = stakingMultiplier;
        emit ProjectUpdated(projectId, stakingMultiplier);
    }

    function stake(uint256 projectId, uint256 amount) external override nonReentrant whenNotPaused {
        if (amount == 0 || amount > maxStake) revert InvalidStakeAmount();

        ITerraStakeStaking.ProjectData storage project = projects[projectId];
        if (!project.isActive || project.isPaused) revert ProjectNotActive();

        ITerraStakeStaking.StakingPosition storage position = stakingPositions[msg.sender][projectId];

        uint256 rewards = _claimRewards(projectId);
        if (rewards > 0) rewardToken.transfer(msg.sender, rewards);

        position.amount += uint128(amount);
        position.lastCheckpoint = uint128(block.timestamp);
        position.stakingStart = uint48(block.timestamp);

        project.totalStaked += uint128(amount);
        totalStaked += amount;

        stakingToken.transferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, projectId, amount);
    }

    function unstake(uint256 projectId) external override nonReentrant whenNotPaused {
        ITerraStakeStaking.StakingPosition storage position = stakingPositions[msg.sender][projectId];
        if (position.amount == 0) revert NoStakeFound();

        ITerraStakeStaking.ProjectData storage project = projects[projectId];
        uint256 elapsed = block.timestamp - position.stakingStart;
        bool withinGPeriod = elapsed <= gracePeriod;

        uint256 penalty = withinGPeriod ? 0 : (position.amount * project.penaltyRate) / 10000;
        uint256 finalAmount = position.amount - penalty;

        if (penalty > 0 && stakingToken.balanceOf(address(this)) < penalty) revert InsufficientFundsForPenalty();

        project.totalStaked -= uint128(position.amount);
        totalStaked -= position.amount;

        position.amount = 0;
        position.rewardDebt = 0;
        position.lastCheckpoint = uint128(block.timestamp);

        stakingToken.transfer(msg.sender, finalAmount);
        emit Unstaked(msg.sender, projectId, finalAmount, penalty);
    }

    function claimRewards(uint256 projectId) external override nonReentrant whenNotPaused {
        uint256 rewards = _claimRewards(projectId);
        if (rewards == 0) revert RewardsAlreadyClaimed();

        rewardToken.transfer(msg.sender, rewards);
        emit RewardsClaimed(msg.sender, projectId, rewards);
    }

    // View Functions
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
        ITerraStakeStaking.StakingPosition storage pos = stakingPositions[user][projectId];
        return (pos.amount, pos.rewardDebt, pos.lastCheckpoint, pos.stakingStart);
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
            uint128 totalStaked_,
            uint128 rewardPool,
            bool isActive,
            bool isPaused
        )
    {
        ITerraStakeStaking.ProjectData storage project = projects[projectId];
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

    function getTotalRewards(address user) external view override returns (uint256 totalRewards) {
        for (uint256 i = 0; i < activeProjects.length; i++) {
            totalRewards += _calculateRewards(user, activeProjects[i]);
        }
    }

    function getActiveProjects() external view override returns (uint256[] memory) {
        return activeProjects;
    }

    function calculateProjectedRewards(
        address user,
        uint256 projectId,
        uint256 duration
    ) external view override returns (uint256 projectedRewards) {
        ITerraStakeStaking.StakingPosition storage position = stakingPositions[user][projectId];
        if (position.amount == 0) {
            return 0;
        }

        ITerraStakeStaking.ProjectData storage project = projects[projectId];
        projectedRewards = (position.amount * rewardRate * project.stakingMultiplier * duration) / (365 days * 10000);
    }

    function getAllProjectData() external view override returns (ITerraStakeStaking.ProjectData[] memory allProjects) {
        allProjects = new ITerraStakeStaking.ProjectData[](activeProjects.length);
        for (uint256 i = 0; i < activeProjects.length; i++) {
            allProjects[i] = projects[activeProjects[i]];
        }
    }

    // Internal Functions
    function _claimRewards(uint256 projectId) internal returns (uint256 rewards) {
        ITerraStakeStaking.StakingPosition storage position = stakingPositions[msg.sender][projectId];
        ITerraStakeStaking.ProjectData storage project = projects[projectId];

        rewards = _calculateRewards(msg.sender, projectId);

        if (rewards > 0) {
            if (project.rewardPool < rewards) revert InsufficientRewardPool();
            project.rewardPool -= uint128(rewards);
            position.rewardDebt += uint128(rewards);
            position.accumulatedRewards += uint128(rewards);
            position.lastCheckpoint = uint128(block.timestamp);
        }
    }

    function _calculateRewards(address user, uint256 projectId) internal view returns (uint256) {
        ITerraStakeStaking.StakingPosition storage position = stakingPositions[user][projectId];
        ITerraStakeStaking.ProjectData storage project = projects[projectId];

        if (position.amount == 0) return 0;

        uint256 timeElapsed = block.timestamp - position.lastCheckpoint;
        return (position.amount * rewardRate * project.stakingMultiplier * timeElapsed) / (365 days * 10000);
    }
}
