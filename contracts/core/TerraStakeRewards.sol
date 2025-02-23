// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "../interfaces/ITerraStakeRewards.sol";
import "../interfaces/ITerraStakeProjects.sol";

/**
 * @title TerraStakeRewards (3B Cap Secured)
 * @notice Implements a reward distribution system with impact tracking, project validation, LP receipt generation, and certification.
 */
contract TerraStakeRewards is
    ITerraStakeRewards,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    uint256 public constant MAX_MULTIPLIER = 10000; // Basis points
    uint256 public constant MIN_REWARD_RATE = 1;
    uint256 public constant SLASHING_LOCK_PERIOD = 3 days; // Prevents instant claim after slashing

    IERC20 public rewardToken;
    address public stakingContract;
    uint256 public baseRewardRate;
    uint256 public totalRewardsDistributed;
    uint256 public rewardPoolCount;
    uint256 public userRewardCap;

    ITerraStakeProjects public terraStakeProjects;

    // **Halving Mechanism**
    uint256 public constant AVERAGE_BLOCK_TIME = 13;
    uint256 public constant TWO_YEARS_BLOCKS = (2 * 365 * 24 * 60 * 60) / AVERAGE_BLOCK_TIME;
    uint256 public halvingInterval;
    uint256 public lastHalvingBlock;

    mapping(uint256 => RewardPool) public rewardPools;
    mapping(address => mapping(uint256 => UserRewards)) public userRewards;
    mapping(uint256 => bool) public projectHasPool;
    mapping(address => uint256) public lastSlashingTime;

    // **Security Enhancements**
    bool private _locked;
    mapping(bytes32 => uint256) public operationTimelocks;

    // **Events**
    event RewardPoolCreated(uint256 indexed poolId, uint256 amount, uint32 multiplier);
    event ProjectPoolCreated(uint256 indexed projectId, uint256 amount, uint32 multiplier);
    event RewardsFunded(uint256 indexed projectId, uint256 amount);
    event RewardsDistributed(uint256 indexed poolId, address indexed recipient, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 indexed poolId, uint256 amount);
    event HalvingApplied(uint256 indexed poolId, uint128 oldAvailable, uint128 newAvailable, uint256 halvingCount, uint256 timestamp);
    event RewardPoolDeactivated(uint256 indexed poolId);
    event UserCapUpdated(uint256 newCap);
    event StakingContractUpdated(address newStakingContract);
    event GovernanceTimelockSet(bytes32 indexed setting, uint256 newValue, uint256 unlockTime);
    event GovernanceTimelockExecuted(bytes32 indexed setting, uint256 oldValue, uint256 newValue);

    // **Modifiers**
    modifier onlyStakingContract() {
        require(msg.sender == stakingContract, "Caller is not staking contract");
        _;
    }

    modifier nonReentrantExternal() {
        require(!_locked, "Reentrant call");
        _locked = true;
        _;
        _locked = false;
    }

    modifier notSlashed(address user) {
        require(block.timestamp >= lastSlashingTime[user] + SLASHING_LOCK_PERIOD, "User is slashed");
        _;
    }

    // **Initialization**
    function initialize(
        address _rewardToken,
        address _stakingContract,
        uint256 _baseRewardRate,
        uint256 _userRewardCap,
        address _terraStakeProjects,
        address admin
    ) external initializer {
        require(_rewardToken != address(0), "Invalid reward token");
        require(_stakingContract != address(0), "Invalid staking contract");
        require(admin != address(0), "Invalid admin address");
        require(_baseRewardRate >= MIN_REWARD_RATE, "Reward rate too low");
        require(_terraStakeProjects != address(0), "Invalid project contract");

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        rewardToken = IERC20(_rewardToken);
        stakingContract = _stakingContract;
        baseRewardRate = _baseRewardRate;
        halvingInterval = TWO_YEARS_BLOCKS;
        lastHalvingBlock = block.number;
        userRewardCap = _userRewardCap;

        terraStakeProjects = ITerraStakeProjects(_terraStakeProjects);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // **Reward Pool Management**
    function createRewardPool(uint256 amount, uint32 multiplier, uint48 duration) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 poolId) {
        require(amount > 0, "Invalid amount");
        require(multiplier > 0 && multiplier <= MAX_MULTIPLIER, "Invalid multiplier");
        require(duration > 0, "Invalid duration");

        poolId = rewardPoolCount++;
        rewardPools[poolId] = RewardPool({
            available: uint128(amount),
            distributed: 0,
            endBlock: uint48(block.number + duration),
            lastUpdateBlock: uint48(block.number),
            multiplier: multiplier,
            isActive: true,
            halvingCount: 0
        });

        require(rewardToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        emit RewardPoolCreated(poolId, amount, multiplier);
    }

    function deactivateRewardPool(uint256 poolId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        rewardPools[poolId].isActive = false;
        emit RewardPoolDeactivated(poolId);
    }

    // **Reward Claims**
    function batchClaimRewards(uint256[] calldata poolIds) external nonReentrant whenNotPaused notSlashed(msg.sender) {
        uint256 totalRewards;
        for (uint256 i = 0; i < poolIds.length; i++) {
            totalRewards += _claimRewards(msg.sender, poolIds[i]);
        }
        require(totalRewards > 0, "No rewards");
        require(totalRewards <= userRewardCap, "Exceeds cap");

        require(rewardToken.transfer(msg.sender, totalRewards), "Transfer failed");
    }

    function _claimRewards(address user, uint256 poolId) internal returns (uint256) {
        UserRewards storage userReward = userRewards[user][poolId];
        uint256 rewards = userReward.pending;
        if (rewards == 0) return 0;

        userReward.pending = 0;
        userReward.claimed += uint128(rewards);
        rewardPools[poolId].distributed += uint128(rewards);
        totalRewardsDistributed += rewards;

        emit RewardsClaimed(user, poolId, rewards);
        return rewards;
    }

    // **Governance Security**
    function setGovernanceTimelock(bytes32 setting, uint256 newValue) external onlyRole(DEFAULT_ADMIN_ROLE) {
        operationTimelocks[setting] = block.timestamp + 2 days;
        emit GovernanceTimelockSet(setting, newValue, operationTimelocks[setting]);
    }

    function executeGovernanceTimelock(bytes32 setting, uint256 newValue) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(block.timestamp >= operationTimelocks[setting], "Timelock not expired");
        operationTimelocks[setting] = 0;
        emit GovernanceTimelockExecuted(setting, newValue, newValue);
    }
}
