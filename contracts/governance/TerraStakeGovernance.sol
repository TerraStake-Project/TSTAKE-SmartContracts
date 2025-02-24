// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/IRewardDistributor.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

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

    uint256 public constant PENALTY_FOR_VIOLATION = 5; // 5% stake slashing for governance abuse
    mapping(address => uint256) public governanceVotes;
    mapping(address => bool) public penalizedGovernors;

    uint256 public halvingPeriod;
    uint256 public lastHalvingTime;
    uint256 public halvingEpoch;
    uint256 public constant AUTO_HALVING_THRESHOLD = 60; // 60% unclaimed rewards trigger halving

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(bytes32 => bool) public executedHashes;

    ITerraStakeStaking public stakingContract;
    IRewardDistributor public rewardDistributor;
    ITerraStakeLiquidityGuard public liquidityGuard;
    ISwapRouter public uniswapRouter;
    IQuoter public uniswapQuoter;
    IUniswapV3Pool public uniswapPool;
    IERC1155 public nftContract;
    AggregatorV3Interface public priceFeed;
    address public treasuryWallet;

    uint24 public constant POOL_FEE = 3000;
    uint256 public constant TIMELOCK_DURATION = 2 days;

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
    event ProposalExecuted(uint256 indexed proposalId, address target, ProposalType proposalType);
    event ProposalVetoed(uint256 indexed proposalId);
    event ProposalThresholdUpdated(uint256 newThreshold);
    event VotingDurationUpdated(uint256 newDuration);
    event MinimumHoldingUpdated(uint256 newMinimumHolding);
    event HalvingApplied(uint256 newEpoch);
    event HalvingPeriodUpdated(uint256 newHalvingPeriod);
    event ProposalVotingEnded(uint256 indexed proposalId, uint256 votesFor, uint256 votesAgainst);
    event BuybackExecuted(uint256 usdcAmount, uint256 tStakeReceived);
    event LiquidityInjected(uint256 usdcAmount, uint256 tStakeAdded);

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

    function executeProposal(uint256 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.endBlock < block.number, "Voting ongoing");
        require(!proposal.executed, "Already executed");
        require(!proposal.vetoed, "Proposal was vetoed");
        require(proposal.votesFor > proposal.votesAgainst, "Proposal failed");
        require(block.timestamp >= proposal.timelockEndTime, "Timelock active");
        require(Address.isContract(proposal.target), "Execution target is not a contract");

        proposal.executed = true;
        totalProposalsExecuted++;

        if (proposal.proposalType == ProposalType.Buyback) {
            _executeBuyback(proposal.data);
        } else if (proposal.proposalType == ProposalType.LiquidityInjection) {
            _executeLiquidityInjection(proposal.data);
        } else {
            Address.functionCall(proposal.target, proposal.data);
        }

        emit ProposalExecuted(proposalId, proposal.target, proposal.proposalType);
    }

    function finalizeVoting(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        require(block.number > proposal.endBlock, "Voting ongoing");
        require(!proposal.executed && !proposal.vetoed, "Proposal already finalized");

        emit ProposalVotingEnded(proposalId, proposal.votesFor, proposal.votesAgainst);
    }
}
