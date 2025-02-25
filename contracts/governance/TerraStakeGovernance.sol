// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/ITerraStakeRewardDistributor.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";
import "../interfaces/ITerraStakeGovernance.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/**
 * @title TerraStakeGovernance
 * @notice Manages on-chain governance, voting, liquidity pairing, and economic adjustments in the TerraStake ecosystem.
 */
contract TerraStakeGovernance is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, ITerraStakeGovernance {
    // -------------------------------------------
    // 🔹 Roles
    // -------------------------------------------
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    // -------------------------------------------
    // 🔹 Governance State Variables
    // -------------------------------------------
    uint256 public proposalCount;
    uint256 public votingDuration;
    uint256 public proposalThreshold;
    uint256 public minimumHolding;
    uint256 public totalVotesCast;
    uint256 public totalProposalsExecuted;
    uint256 public feeUpdateCooldown;
    uint256 public lastFeeUpdateTime;
    bool public liquidityPairingEnabled;

    uint256 public constant PENALTY_FOR_VIOLATION = 5; // 5% stake slashing for governance abuse
    mapping(address => uint256) public governanceVotes;
    mapping(address => bool) public penalizedGovernors;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(bytes32 => bool) public executedHashes;

    uint256 public halvingPeriod;
    uint256 public lastHalvingTime;
    uint256 public halvingEpoch;
    uint256 public constant AUTO_HALVING_THRESHOLD = 60; // 60% unclaimed rewards trigger halving

    ITerraStakeStaking public stakingContract;
    ITerraStakeRewardDistributor public rewardDistributor;
    ITerraStakeLiquidityGuard public liquidityGuard;
    ISwapRouter public uniswapRouter;
    IQuoter public uniswapQuoter;
    IUniswapV3Pool public uniswapPool;
    IERC1155 public nftContract;
    address public treasuryWallet;
    address public usdcToken;
    address public tStakeToken;
    
    uint24 public constant POOL_FEE = 3000;
    uint256 public constant TIMELOCK_DURATION = 2 days;

    struct FeeProposal {
        uint256 projectSubmissionFee;
        uint256 impactReportingFee;
        uint256 buybackPercentage;
        uint256 liquidityPairingPercentage;
        uint256 burnPercentage;
        uint256 treasuryPercentage;
        uint256 voteEnd;
        bool executed;
    }

    FeeProposal public currentFeeStructure;
    FeeProposal public pendingFeeProposal;

    // -------------------------------------------
    // 🔹 Events
    // -------------------------------------------
    event GovernanceParametersUpdated(
        uint256 newVotingDuration,
        uint256 newProposalThreshold,
        uint256 newMinimumHolding
    );
    event RewardRateAdjusted(uint256 newRate, uint256 timestamp);
    event TokenRecovered(address indexed token, uint256 amount, address indexed recipient);

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
        address _usdcToken,
        address _tStakeToken,
        uint256 _votingDuration,
        uint256 _proposalThreshold,
        uint256 _minimumHolding,
        uint256 _halvingPeriod,
        uint256 _feeUpdateCooldown
    ) external initializer {
        require(_stakingContract != address(0), "Invalid staking contract");
        require(_rewardDistributor != address(0), "Invalid reward distributor");
        require(_liquidityGuard != address(0), "Invalid liquidity guard");
        require(_uniswapRouter != address(0), "Invalid Uniswap router");
        require(_uniswapQuoter != address(0), "Invalid Uniswap quoter");
        require(_uniswapPool != address(0), "Invalid Uniswap pool");
        require(_nftContract != address(0), "Invalid NFT contract");
        require(_treasuryWallet != address(0), "Invalid treasury wallet");
        require(_usdcToken != address(0), "Invalid USDC token");
        require(_tStakeToken != address(0), "Invalid tStake token");

        __AccessControl_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);

        stakingContract = ITerraStakeStaking(_stakingContract);
        rewardDistributor = ITerraStakeRewardDistributor(_rewardDistributor);
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);
        uniswapRouter = ISwapRouter(_uniswapRouter);
        uniswapQuoter = IQuoter(_uniswapQuoter);
        uniswapPool = IUniswapV3Pool(_uniswapPool);
        nftContract = IERC1155(_nftContract);
        treasuryWallet = _treasuryWallet;
        usdcToken = _usdcToken;
        tStakeToken = _tStakeToken;

        votingDuration = _votingDuration;
        proposalThreshold = _proposalThreshold;
        minimumHolding = _minimumHolding;
        halvingPeriod = _halvingPeriod;
        feeUpdateCooldown = _feeUpdateCooldown;

        lastHalvingTime = block.timestamp;
        halvingEpoch = 0;
        liquidityPairingEnabled = true;

        currentFeeStructure = FeeProposal(6100, 2200, 5, 10, 50, 35, 0, true);
    }

    // -------------------------------------------
    // 🔹 Batch Processing for Proposals
    // -------------------------------------------
    function batchProcessProposals(uint256[] calldata proposalIds) external {
        for (uint256 i = 0; i < proposalIds.length; i++) {
            if (canExecuteProposal(proposalIds[i])) {
                executeProposal(proposalIds[i]);
            }
        }
    }

    function canExecuteProposal(uint256 proposalId) public view returns (bool) {
        Proposal storage proposal = proposals[proposalId];
        return (
            block.number > proposal.endBlock &&
            proposal.votesFor > proposal.votesAgainst &&
            !proposal.executed &&
            !proposal.vetoed
        );
    }

    // -------------------------------------------
    // 🔹 Recovery Function
    // -------------------------------------------
    function recoverERC20(address token, uint256 amount) external onlyRole(GOVERNANCE_ROLE) {
        require(token != address(tStakeToken), "Cannot recover governance token");
        require(amount > 0, "Amount must be greater than zero");
        IERC20(token).transfer(treasuryWallet, amount);
        emit TokenRecovered(token, amount, treasuryWallet);
    }

    // -------------------------------------------
    // 🔹 Governance Checks
    // -------------------------------------------
    function validateGovernanceParameters() external view returns (bool) {
        return (
            votingDuration > 0 &&
            proposalThreshold > 0 &&
            minimumHolding > 0 &&
            treasuryWallet != address(0)
        );
    }
}
