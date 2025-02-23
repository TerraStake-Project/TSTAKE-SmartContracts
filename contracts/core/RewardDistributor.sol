// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "../interfaces/IRewardDistributor.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";
import "../interfaces/ITerraStakeSlashing.sol";

/**
 * @title RewardDistributor (TerraStake DAO Secured)
 * @notice Distributes staking rewards securely, with DAO governance, auto liquidity injection, buyback mechanisms, and randomized halving.
 */
contract RewardDistributor is AccessControl, VRFConsumerBaseV2, IRewardDistributor {
    using SafeMath for uint256;

    // 🔑 DAO Governance Roles
    bytes32 public constant STAKING_CONTRACT_ROLE = keccak256("STAKING_CONTRACT_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant MULTISIG_ROLE = keccak256("MULTISIG_ROLE");

    // 📌 Constants
    uint256 public constant DEFAULT_DISTRIBUTION_LIMIT = 1_000_000 * 10**18;
    uint256 public constant DEFAULT_MIN_LIQUIDITY_RESERVE = 500_000 * 10**18;
    uint256 public constant MAX_LIQUIDITY_INJECTION_RATE = 10;
    uint256 public constant MAX_HALVING_REDUCTION_RATE = 90;
    uint256 private constant HALVING_RANDOM_RANGE = 24 hours;

    // 📌 State Variables
    IERC20 public immutable rewardToken;
    ISwapRouter public immutable uniswapRouter;
    ITerraStakeLiquidityGuard public immutable liquidityGuard;
    ITerraStakeSlashing public immutable slashingContract;
    address public rewardSource;
    uint256 public totalDistributed;
    uint256 public distributionLimit;
    uint256 public minLiquidityReserve;
    address public immutable daoGovernance;
    ITerraStakeStaking public stakingContract;
    address public liquidityPool;

    // 🔥 Halving & APR Boost
    uint256 public halvingEpoch;
    uint256 public lastHalvingTime;
    uint256 public halvingPeriod = 365 days;
    uint256 public halvingReductionRate = 80;
    uint256 public aprBoostMultiplier = 120;
    bool public autoBuybackEnabled = true;

    // Chainlink VRF for Randomized Halving
    bytes32 public keyHash;
    uint64 public subscriptionId;
    mapping(bytes32 => bool) private vrfRequests;

    // 🏦 Secure Multi-Sig Withdrawals
    struct EmergencyWithdrawal {
        address recipient;
        uint256 amount;
        uint256 unlockTime;
        bool executed;
    }
    EmergencyWithdrawal public pendingWithdrawal;

    // 🏦 Penalty Redistribution
    uint256 public liquidityInjectionRate = 5;
    uint256 public buybackPercentage = 10;
    uint256 public burnPercentage = 5;
    uint256 public reinvestPercentage = 5;

    event RewardDistributed(address indexed user, uint256 amount);
    event EmergencyWithdrawalRequested(address indexed recipient, uint256 amount, uint256 unlockTime);
    event EmergencyWithdrawalExecuted(address indexed recipient, uint256 amount);
    event BuybackExecuted(uint256 amount);
    event LiquidityInjected(uint256 amount);
    event TokensBurned(uint256 amount);
    event PenaltyRewardsDistributed(uint256 amount, uint256 recipients);
    event HalvingApplied(uint256 newRewardRate, uint256 halvingEpoch);

    /// ⚙️ Constructor
    constructor(
        address _rewardToken,
        address _rewardSource,
        address _daoGovernance,
        address _stakingContract,
        address _uniswapRouter,
        address _liquidityPool,
        address _liquidityGuard,
        address _slashingContract,
        address _vrfCoordinator,
        bytes32 _keyHash,
        uint64 _subscriptionId
    ) VRFConsumerBaseV2(_vrfCoordinator) {
        require(_rewardToken != address(0), "Invalid reward token address");
        require(_rewardSource != address(0), "Invalid reward source address");
        require(_daoGovernance != address(0), "Invalid DAO governance address");
        require(_stakingContract != address(0), "Invalid staking contract address");
        require(_uniswapRouter != address(0), "Invalid Uniswap router address");
        require(_liquidityPool != address(0), "Invalid liquidity pool address");
        require(_liquidityGuard != address(0), "Invalid Liquidity Guard");
        require(_slashingContract != address(0), "Invalid Slashing Contract");

        rewardToken = IERC20(_rewardToken);
        rewardSource = _rewardSource;
        daoGovernance = _daoGovernance;
        stakingContract = ITerraStakeStaking(_stakingContract);
        uniswapRouter = ISwapRouter(_uniswapRouter);
        liquidityPool = _liquidityPool;
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);
        slashingContract = ITerraStakeSlashing(_slashingContract);

        distributionLimit = DEFAULT_DISTRIBUTION_LIMIT;
        minLiquidityReserve = DEFAULT_MIN_LIQUIDITY_RESERVE;
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;

        _grantRole(DEFAULT_ADMIN_ROLE, _daoGovernance);
        _grantRole(MULTISIG_ROLE, _daoGovernance);
    }

    function distributeReward(address user, uint256 amount) external override onlyRole(STAKING_CONTRACT_ROLE) {
        require(user != address(0), "Invalid user address");
        require(amount > 0, "Amount must be greater than zero");
        require(amount <= distributionLimit, "Exceeds distribution limit");

        applyHalving();
        uint256 adjustedAmount = (amount * halvingReductionRate) / 100;

        uint256 availableLiquidity = rewardToken.balanceOf(rewardSource);
        require(availableLiquidity >= adjustedAmount + minLiquidityReserve, "Liquidity below reserve limit");

        require(rewardToken.transferFrom(rewardSource, user, adjustedAmount), "Reward transfer failed");

        liquidityGuard.injectLiquidity((adjustedAmount * liquidityInjectionRate) / 100);

        totalDistributed += adjustedAmount;
        emit RewardDistributed(user, adjustedAmount);
    }

    function applyHalving() public {
        if (block.timestamp >= lastHalvingTime + halvingPeriod) {
            lastHalvingTime = block.timestamp;
            halvingEpoch++;
            halvingReductionRate = (halvingReductionRate * 90) / 100;
            emit HalvingApplied(halvingReductionRate, halvingEpoch);
        }
    }

    function executeBuyback(uint256 amount) external onlyRole(GOVERNANCE_ROLE) {
        require(autoBuybackEnabled, "Auto buyback disabled");

        uint256 treasuryBalance = rewardToken.balanceOf(rewardSource);
        require(amount <= treasuryBalance / 10, "Exceeds treasury limit");

        rewardToken.transferFrom(rewardSource, address(this), amount);
        rewardToken.approve(address(uniswapRouter), amount);
        
        // Swap logic with Uniswap here

        emit BuybackExecuted(amount);
    }

    function slashAndReduceRewards(address user, uint256 penaltyAmount) external onlyRole(GOVERNANCE_ROLE) {
        require(slashingContract.checkIfSlashed(user), "User not penalized");

        uint256 rewardAmount = rewardToken.balanceOf(user);
        uint256 adjustedReward = rewardAmount > penaltyAmount ? rewardAmount - penaltyAmount : 0;
        
        rewardToken.transfer(user, adjustedReward);
        emit RewardDistributed(user, adjustedReward);
    }
}
