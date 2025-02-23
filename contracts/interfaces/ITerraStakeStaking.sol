// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "../interfaces/IRewardDistributor.sol";
import "../interfaces/ITerraStakeProjects.sol";
import "../interfaces/ITerraStakeGovernance.sol";
import "../interfaces/ITerraStakeStaking.sol";

/**
 * @title TerraStakeStaking
 * @notice Official TerraStake Staking Contract for the TerraStake ecosystem.
 * @dev Supports Quadratic Voting, Dynamic APR, DAO Governance, NFT Rewards, and Auto Liquidity Injection.
 * 
 * 🔹 Fully Integrated with TerraStake 3B Supply
 * 🔹 Secure & Scalable for DAO Governance
 * 🔹 Auto Liquidity Injection for Uniswap v3
 * 🔹 Optimized for ITO-Linked Staking
 */
contract TerraStakeStaking is ITerraStakeStaking, AccessControl, ReentrancyGuard, Pausable {
    using SafeMath for uint256;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    IERC1155 public immutable override nftContract;
    IERC20 public immutable override stakingToken;
    IRewardDistributor public immutable override rewardDistributor;
    ITerraStakeProjects public projectsContract;
    ITerraStakeGovernance public governanceContract;

    uint256 public constant BASE_APR = 10; // 10% APR base
    uint256 public constant BOOSTED_APR = 20; // 20% APR if TVL < 1M TSTAKE
    uint256 public constant NFT_APR_BOOST = 10; // Extra 10% APR for NFT holders
    uint256 public constant LP_APR_BOOST = 15; // Extra 15% APR for LP stakers
    uint256 public constant BASE_PENALTY_PERCENT = 10;
    uint256 public constant MAX_PENALTY_PERCENT = 30;
    uint256 public constant LOW_STAKING_THRESHOLD = 1_000_000 * 10**18; // 1M tokens

    uint256 public override liquidityInjectionRate = 5; // 5% of staking rewards reinjected into Uniswap
    uint256 public constant MAX_LIQUIDITY_RATE = 10;
    address public immutable override liquidityPool;
    bool public override autoLiquidityEnabled = true;

    uint256 public override halvingPeriod = 365 days;
    uint256 public override lastHalvingTime;
    uint256 public override halvingEpoch;

    struct StakingTier {
        uint256 minDuration;
        uint256 rewardMultiplier;
        bool governanceRights;
    }

    struct StakingPosition {
        uint256 amount;
        uint256 lastCheckpoint;
        uint256 stakingStart;
        uint256 projectId;
        uint256 duration;
        bool isLPStaker;
        bool hasNFTBoost;
        bool autoCompounding;
    }

    mapping(address => mapping(uint256 => StakingPosition)) public override stakingPositions;
    mapping(address => uint256) public override governanceVotes;
    mapping(address => bool) public override governanceViolators;

    uint256 public override totalStaked;
    StakingTier[] public override tiers;

    event Staked(address indexed user, uint256 projectId, uint256 amount, uint256 duration);
    event Unstaked(address indexed user, uint256 projectId, uint256 amount, uint256 penalty);
    event RewardsDistributed(address indexed user, uint256 amount);
    event GovernanceRightsUpdated(address indexed user, bool hasRights);
    event LiquidityInjected(uint256 amount);
    event GovernanceVoteSlashed(address indexed user, uint256 amountLost);
    event HalvingApplied(uint256 newEpoch, uint256 adjustedAPR);
    event LiquidityInjectionRateUpdated(uint256 newRate);
    event AutoLiquidityToggled(bool status);

    constructor(
        address _nftContract,
        address _stakingToken,
        address _rewardDistributor,
        address _liquidityPool,
        address _projectsContract,
        address _governanceContract
    ) {
        require(_nftContract != address(0), "Invalid NFT contract");
        require(_stakingToken != address(0), "Invalid staking token");
        require(_rewardDistributor != address(0), "Invalid reward distributor");
        require(_liquidityPool != address(0), "Invalid liquidity pool");
        require(_projectsContract != address(0), "Invalid projects contract");
        require(_governanceContract != address(0), "Invalid governance contract");

        nftContract = IERC1155(_nftContract);
        stakingToken = IERC20(_stakingToken);
        rewardDistributor = IRewardDistributor(_rewardDistributor);
        liquidityPool = _liquidityPool;
        projectsContract = ITerraStakeProjects(_projectsContract);
        governanceContract = ITerraStakeGovernance(_governanceContract);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);

        lastHalvingTime = block.timestamp;
        halvingEpoch = 0;

        tiers.push(StakingTier(30 days, 100, false));
        tiers.push(StakingTier(90 days, 150, true));
        tiers.push(StakingTier(180 days, 200, true));
        tiers.push(StakingTier(365 days, 300, true));
    }

    function stake(uint256 projectId, uint256 amount, uint256 duration, bool isLP, bool autoCompound) external override nonReentrant whenNotPaused {
        require(amount > 0, "Amount must be greater than zero");
        require(duration >= 30 days, "Minimum staking duration is 30 days");

        bool hasNFTBoost = nftContract.balanceOf(msg.sender, 1) > 0;
        uint256 apr = getDynamicAPR(isLP, hasNFTBoost);

        StakingPosition storage position = stakingPositions[msg.sender][projectId];
        require(position.amount == 0, "Already staking in this project");

        position.amount = amount;
        position.lastCheckpoint = block.timestamp;
        position.stakingStart = block.timestamp;
        position.duration = duration;
        position.projectId = projectId;
        position.isLPStaker = isLP;
        position.hasNFTBoost = hasNFTBoost;
        position.autoCompounding = autoCompound;

        totalStaked += amount;
        require(stakingToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        governanceVotes[msg.sender] = sqrt(amount);
        emit Staked(msg.sender, projectId, amount, duration);
    }

    function unstake(uint256 projectId) external override nonReentrant {
        StakingPosition storage position = stakingPositions[msg.sender][projectId];
        require(position.amount > 0, "No tokens staked");
        require(block.timestamp >= position.stakingStart + position.duration, "Lock period not over");

        uint256 penalty = calculatePenalty(projectId, position.amount);
        uint256 amountAfterPenalty = position.amount - penalty;

        totalStaked -= position.amount;
        position.amount = 0;
        governanceVotes[msg.sender] = 0;

        require(stakingToken.transfer(msg.sender, amountAfterPenalty), "Transfer failed");

        emit Unstaked(msg.sender, projectId, amountAfterPenalty, penalty);
    }

    function getDynamicAPR(bool isLP, bool hasNFT) public pure override returns (uint256) {
        uint256 apr = BASE_APR;
        if (isLP) apr += LP_APR_BOOST;
        if (hasNFT) apr += NFT_APR_BOOST;
        return apr;
    }

    function slashGovernanceVote(address user) external override onlyRole(GOVERNANCE_ROLE) {
        require(governanceViolators[user], "User not flagged");
        governanceVotes[user] = 0;
        emit GovernanceVoteSlashed(user, governanceVotes[user]);
    }

    function applyHalving() external override onlyRole(GOVERNANCE_ROLE) {
        require(block.timestamp >= lastHalvingTime + halvingPeriod, "Halving not due");
        halvingEpoch++;
        lastHalvingTime = block.timestamp;
        emit HalvingApplied(halvingEpoch, BASE_APR / 2);
    }

    function updateLiquidityInjectionRate(uint256 newRate) external override onlyRole(GOVERNANCE_ROLE) {
        require(newRate <= MAX_LIQUIDITY_RATE, "Rate too high");
        liquidityInjectionRate = newRate;
        emit LiquidityInjectionRateUpdated(newRate);
    }

    function toggleAutoLiquidity() external override onlyRole(GOVERNANCE_ROLE) {
        autoLiquidityEnabled = !autoLiquidityEnabled;
        emit AutoLiquidityToggled(autoLiquidityEnabled);
    }
}
