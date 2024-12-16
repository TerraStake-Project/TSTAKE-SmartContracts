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

    uint256 public rewardRate; // Reward rate per second per token
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

    // User-specific stake caps
    mapping(address => uint256) public userStakeCap;

    // Role Definitions
    bytes32 public constant PROJECT_MANAGER_ROLE = keccak256("PROJECT_MANAGER_ROLE");
    bytes32 public constant STAKING_MANAGER_ROLE = keccak256("STAKING_MANAGER_ROLE");

    // Events
    event ProjectActivated(uint256 indexed projectId);
    event ProjectDeactivated(uint256 indexed projectId);
    event StakeSlashed(address indexed user, uint256 indexed projectId, uint256 slashAmount);
    event RewardsHalved(uint256 indexed projectId, uint256 oldReward, uint256 newReward);
    event ProjectForceUnstaked(uint256 indexed projectId, uint256 totalUnstaked);
    event RewardRateUpdated(uint256 indexed projectId, uint256 oldRate, uint256 newRate);

    // Custom Errors
    error InvalidStakeAmount();
    error ExceedsMaxStakeLimit();
    error ProjectNotActive();
    error NoStakeFound();
    error InsufficientRewardPool();
    error RewardsAlreadyClaimed();
    error InsufficientFundsForPenalty();

    function initialize(InitializeParams calldata params) external override initializer {
        if (params.stakingToken == address(0) || params.rewardToken == address(0) || params.admin == address(0)) 
            revert InvalidStakeAmount();

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

    // Stake functionality
    function stake(uint256 projectId, uint256 amount) external override nonReentrant whenNotPaused {
        if (amount == 0 || amount > maxStake) revert InvalidStakeAmount();

        ProjectData storage project = projects[projectId];
        if (!project.isActive || project.isPaused) revert ProjectNotActive();

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
        if (position.amount == 0) revert NoStakeFound();

        uint256 elapsed = block.timestamp - position.stakingStart;
        bool withinGracePeriod = elapsed <= gracePeriod;

        uint256 penalty = withinGracePeriod ? 0 : (position.amount * projects[projectId].penaltyRate) / 10000;
        uint256 finalAmount = position.amount - penalty;

        if (penalty > 0 && stakingToken.balanceOf(address(this)) < penalty) revert InsufficientFundsForPenalty();

        position.amount = 0;
        position.rewardDebt = 0;
        position.lastCheckpoint = uint128(block.timestamp);

        projects[projectId].totalStaked -= uint128(finalAmount);
        totalStaked -= finalAmount;

        stakingToken.transfer(msg.sender, finalAmount);
        emit Unstaked(msg.sender, projectId, finalAmount, penalty);
    }

    // Claim rewards
    function claimRewards(uint256 projectId) external override nonReentrant whenNotPaused {
        uint256 rewards = _claimRewards(projectId);
        if (rewards == 0) revert RewardsAlreadyClaimed();

        rewardToken.transfer(msg.sender, rewards);
        emit RewardsClaimed(msg.sender, projectId, rewards);
    }

    // Reward calculation logic
    function _claimRewards(uint256 projectId) internal returns (uint256 rewards) {
        StakingPosition storage position = stakingPositions[msg.sender][projectId];
        ProjectData storage project = projects[projectId];

        rewards = _calculateRewards(msg.sender, projectId);

        if (project.rewardPool < rewards) revert InsufficientRewardPool();

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

    // Grace period and penalty configuration
    function updateGracePeriod(uint256 newGracePeriod) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        gracePeriod = newGracePeriod;
        emit GracePeriodConfigured(newGracePeriod);
    }

    function updatePenaltyRate(uint256 projectId, uint32 newRate) external override onlyRole(PROJECT_MANAGER_ROLE) {
        ProjectData storage project = projects[projectId];
        project.penaltyRate = newRate;
        emit PenaltyRateUpdated(projectId, newRate);
    }

    // Project management
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

    function activateProject(uint256 projectId) external onlyRole(PROJECT_MANAGER_ROLE) {
        ProjectData storage project = projects[projectId];
        project.isActive = true;
        activeProjects.push(projectId);
        emit ProjectActivated(projectId);
    }

    function deactivateProject(uint256 projectId) external onlyRole(PROJECT_MANAGER_ROLE) {
        ProjectData storage project = projects[projectId];
        project.isActive = false;

        for (uint256 i = 0; i < activeProjects.length; i++) {
            if (activeProjects[i] == projectId) {
                activeProjects[i] = activeProjects[activeProjects.length - 1];
                activeProjects.pop();
                break;
            }
        }
        emit ProjectDeactivated(projectId);
    }

    // View functions for project and staking data
    function getActiveProjects() external view override returns (uint256[] memory) {
        return activeProjects;
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
}
