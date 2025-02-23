// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/IRewardDistributor.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/**
 * @title TerraStakeGovernance (DAO-Managed)
 * @notice Official TerraStake DAO governance contract for managing TSTAKE rewards, staking policies, liquidity, and voting.
 * @dev Supports Quadratic Voting, Buyback Mechanism, Liquidity Injection, Reward Halving, and Proposal Execution.
 */
contract TerraStakeGovernance is 
    Initializable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    // -------------------------------------------
    // 🔹 Proposal Enums & Structs
    // -------------------------------------------
    enum ProposalStatus { Active, Timelocked, Vetoed, Executed, VotingEnded }
    enum ProposalType { General, RewardDistribution, Buyback, LiquidityInjection }

    struct Proposal {
        bytes data;
        address target;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 endBlock;
        uint256 timelockEndTime;
        bool executed;
        bool vetoed;
        ProposalType proposalType;
        uint256 linkedProjectId;
        string description;
    }

    struct GovernanceAnalytics {
        uint256 totalProposalsExecuted;
        uint256 totalVotesCast;
        uint256 participationRate;
        mapping(address => uint256) voterInfluence;
    }

    // -------------------------------------------
    // 🔹 Governance & State Variables
    // -------------------------------------------
    uint256 public proposalCount;
    uint256 public votingDuration;
    uint256 public proposalThreshold;
    uint256 public minimumHolding;
    uint256 public totalVotesCast;
    uint256 public totalProposalsExecuted;

    // **Quadratic Voting & Penalty Variables**
    uint256 public constant PENALTY_FOR_VIOLATION = 5; // 5% stake slashing for governance abuse
    mapping(address => uint256) public governanceVotes;
    mapping(address => bool) public penalizedGovernors;

    // **Halving & Governance-Driven Staking**
    uint256 public halvingPeriod;
    uint256 public lastHalvingTime;
    uint256 public halvingEpoch;
    uint256 public constant AUTO_HALVING_THRESHOLD = 60; // 60% unclaimed rewards trigger halving

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(bytes32 => bool) public executedHashes;

    // **Uniswap & External Contract References**
    ITerraStakeStaking public stakingContract;
    IRewardDistributor public rewardDistributor;
    ITerraStakeLiquidityGuard public liquidityGuard;
    ISwapRouter public uniswapRouter;
    IQuoter public uniswapQuoter;
    IUniswapV3Pool public uniswapPool;
    IERC1155 public nftContract;
    AggregatorV3Interface public priceFeed;
    address public treasuryWallet;

    uint24 public constant POOL_FEE = 3000; // Uniswap V3 Fee Tier
    uint256 public constant TIMELOCK_DURATION = 2 days; // Timelock period for critical proposals

    // -------------------------------------------
    // 🔹 Events
    // -------------------------------------------
    event ProposalCreated(
        uint256 indexed proposalId,
        bytes data,
        uint256 endBlock,
        address target,
        ProposalType proposalType,
        uint256 linkedProjectId,
        string description
    );

    event ProposalTimelocked(uint256 indexed proposalId, uint256 unlockTime);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalVetoed(uint256 indexed proposalId);
    event ProposalThresholdUpdated(uint256 newThreshold);
    event VotingDurationUpdated(uint256 newDuration);
    event MinimumHoldingUpdated(uint256 newMinimumHolding);
    event HalvingApplied(uint256 newEpoch);
    event HalvingPeriodUpdated(uint256 newHalvingPeriod);
    event VotingPowerCalculated(address indexed user, uint256 power);
    event NFTGovernanceBoostApplied(address indexed user, uint256 power);
    event BuybackExecuted(uint256 usdcAmount, uint256 tStakeReceived);
    event LiquidityInjected(uint256 usdcAmount, uint256 tStakeAdded);
    event GovernancePenaltyApplied(address indexed violator, uint256 slashedAmount);

    // -------------------------------------------
    // 🔹 Initialization
    // -------------------------------------------
    function initialize(
        address _stakingContract,
        address _rewardDistributor,
        address _liquidityGuard,
        address _uniswapRouter,
        address _uniswapQuoter,
        address _uniswapPool,
        address _nftContract,
        address _treasuryWallet,
        uint256 _votingDuration,
        uint256 _proposalThreshold,
        uint256 _minimumHolding,
        uint256 _halvingPeriod
    ) external initializer {
        require(_stakingContract != address(0), "Invalid staking contract");
        require(_rewardDistributor != address(0), "Invalid reward distributor");
        require(_liquidityGuard != address(0), "Invalid liquidity guard");
        require(_uniswapRouter != address(0), "Invalid Uniswap router");
        require(_uniswapQuoter != address(0), "Invalid Uniswap quoter");
        require(_uniswapPool != address(0), "Invalid Uniswap pool");
        require(_nftContract != address(0), "Invalid NFT contract");
        require(_treasuryWallet != address(0), "Invalid treasury wallet");

        __AccessControl_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);

        stakingContract = ITerraStakeStaking(_stakingContract);
        rewardDistributor = IRewardDistributor(_rewardDistributor);
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);
        uniswapRouter = ISwapRouter(_uniswapRouter);
        uniswapQuoter = IQuoter(_uniswapQuoter);
        uniswapPool = IUniswapV3Pool(_uniswapPool);
        nftContract = IERC1155(_nftContract);
        treasuryWallet = _treasuryWallet;

        votingDuration = _votingDuration;
        proposalThreshold = _proposalThreshold;
        minimumHolding = _minimumHolding;
        halvingPeriod = _halvingPeriod;

        lastHalvingTime = block.timestamp;
        halvingEpoch = 0;
    }

    // -------------------------------------------
    // 🔹 Quadratic Voting Calculation
    // -------------------------------------------
    function calculateQuadraticVotingPower(address voter) public view returns (uint256) {
        uint256 baseVotes = stakingContract.getUserStake(voter);
        uint256 nftBoost = _calculateNFTBoost(voter);
        return sqrt(baseVotes + nftBoost);
    }

    function _calculateNFTBoost(address voter) internal view returns (uint256) {
        return nftContract.balanceOf(voter, 1) * 10;
    }

    // -------------------------------------------
    // 🔹 Halving Check & Execution
    // -------------------------------------------
    function checkAndTriggerHalving() external {
        if (block.timestamp >= lastHalvingTime + halvingPeriod) {
            _applyHalving();
        }
    }

    function _applyHalving() internal {
        lastHalvingTime = block.timestamp;
        halvingEpoch++;
        emit HalvingApplied(halvingEpoch);
    }
}
