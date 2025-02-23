// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITerraStakeGovernance {
    // ================================
    // 🔹 Proposal Struct & Enum
    // ================================
    enum ProposalStatus { Active, Vetoed, Executed, VotingEnded, Timelocked }
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

    // ================================
    // 🔹 Governance & Role-Based Access
    // ================================
    function GOVERNANCE_ROLE() external view returns (bytes32);
    function VETO_ROLE() external view returns (bytes32);
    function PENALTY_MANAGER_ROLE() external view returns (bytes32);

    // ================================
    // 🔹 Proposal & Voting State Variables
    // ================================
    function proposalCount() external view returns (uint256);
    function votingDuration() external view returns (uint256);
    function proposalThreshold() external view returns (uint256);
    function minimumHolding() external view returns (uint256);

    // ================================
    // 🔹 Timelock Settings
    // ================================
    function timelockDuration() external view returns (uint256);
    function isTimelockEnabled() external view returns (bool);

    // ================================
    // 🔹 Halving & Reward Management
    // ================================
    function halvingPeriod() external view returns (uint256);
    function lastHalvingTime() external view returns (uint256);
    function halvingEpoch() external view returns (uint256);
    function AUTO_HALVING_THRESHOLD() external pure returns (uint256);

    // ================================
    // 🔹 Uniswap, Treasury & LiquidityGuard Variables
    // ================================
    function uniswapRouter() external view returns (address);
    function uniswapQuoter() external view returns (address);
    function uniswapPool() external view returns (address);
    function treasuryWallet() external view returns (address);
    function liquidityGuard() external view returns (address);
    function POOL_FEE() external view returns (uint24);

    // ================================
    // 🔹 Proposal Management
    // ================================
    function createProposal(
        bytes calldata data,
        address target,
        ProposalType proposalType,
        uint256 linkedProjectId,
        string calldata description
    ) external;

    function vote(uint256 proposalId, bool support) external;

    function executeProposal(uint256 proposalId) external;

    function vetoProposal(uint256 proposalId) external;

    function queueProposal(uint256 proposalId) external;

    function unqueueProposal(uint256 proposalId) external;

    // ================================
    // 🔹 Voting Power Calculation
    // ================================
    function calculateVotingPower(address user) external view returns (uint256);

    function getStakeAgeMultiplier(address user) external view returns (uint256);

    // ================================
    // 🔹 Liquidity & Buyback Functions
    // ================================
    function executeBuyback(uint256 usdcAmount) external;

    function injectLiquidity(uint256 usdcAmount, uint256 tStakeAmount) external;

    function isBuybackAllowed() external view returns (bool);

    function estimateTStakeForBuyback(uint256 usdcAmount) external view returns (uint256);

    // ================================
    // 🔹 Governance Penalty Management
    // ================================
    function applyPenalty(address user, uint256 penaltyAmount) external;

    function getPenaltyStatus(address user) external view returns (bool);

    function removePenalty(address user) external;

    // ================================
    // 🔹 View Functions
    // ================================
    function proposals(uint256 proposalId) external view returns (
        bytes memory data,
        address target,
        uint256 votesFor,
        uint256 votesAgainst,
        uint256 endBlock,
        uint256 timelockEndTime,
        bool executed,
        bool vetoed,
        ProposalType proposalType,
        uint256 linkedProjectId,
        string memory description
    );

    function hasVoted(uint256 proposalId, address user) external view returns (bool);

    function executedHashes(bytes32 executionHash) external view returns (bool);

    function governanceVotes(address user) external view returns (uint256);

    function stakingContract() external view returns (address);

    function rewardDistributor() external view returns (address);

    function nftContract() external view returns (address);

    // ================================
    // 🔹 Advanced Governance Analytics
    // ================================
    function totalProposalsExecuted() external view returns (uint256);
    function totalVotesCast() external view returns (uint256);
    function participationRate() external view returns (uint256);
    function voterInfluence(address user) external view returns (uint256);

    // ================================
    // 🔹 Events
    // ================================
    event ProposalCreated(
        uint256 indexed proposalId,
        bytes data,
        uint256 endBlock,
        address target,
        ProposalType proposalType,
        uint256 linkedProjectId,
        string description
    );

    event ProposalQueued(uint256 indexed proposalId, uint256 timelockEndTime);
    event ProposalUnqueued(uint256 indexed proposalId);

    event Voted(
        uint256 indexed proposalId,
        address indexed voter,
        bool support,
        uint256 votingPower
    );

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

    event GovernancePenaltyApplied(address indexed user, uint256 penaltyAmount);
    event GovernancePenaltyRemoved(address indexed user);
}
