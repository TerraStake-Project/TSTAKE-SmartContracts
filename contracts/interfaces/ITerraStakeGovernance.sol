// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ITerraStakeGovernance {
    // ================================
    // 🔹 Proposal Enums & Structs
    // ================================
    enum ProposalStatus { Active, Timelocked, Vetoed, Executed, VotingEnded }
    enum ProposalType { General, RewardDistribution, Buyback, LiquidityInjection, FeeAdjustment }

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

    // ================================
    // 🔹 Proposal Management
    // ================================
    function createProposal(
        bytes calldata data,
        address target,
        ProposalType proposalType,
        uint256 linkedProjectId,
        string calldata description
    ) external returns (uint256);

    function voteOnProposal(uint256 proposalId, bool support) external;
    function executeProposal(uint256 proposalId) external;
    function vetoProposal(uint256 proposalId) external;
    function finalizeVoting(uint256 proposalId) external;
    function batchProcessProposals(uint256[] calldata proposalIds) external;
    function canExecuteProposal(uint256 proposalId) external view returns (bool);

    function getProposal(uint256 proposalId) external view returns (
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

    // ================================
    // 🔹 Governance Settings & Voting
    // ================================
    function setProposalThreshold(uint256 newThreshold) external;
    function setVotingDuration(uint256 newDuration) external;
    function setMinimumHolding(uint256 newMinimumHolding) external;
    function validateGovernanceParameters() external view returns (bool);

    function getGovernanceVotes(address user) external view returns (uint256);
    function penalizeGovernor(address user) external;
    function isGovernorPenalized(address user) external view returns (bool);
    function recoverERC20(address token, uint256 amount) external;

    // ================================
    // 🔹 Dynamic Fee Governance
    // ================================
    function proposeFeeUpdate(uint256 newProjectFee, uint256 newImpactFee) external;
    function executeFeeUpdate(uint256 proposalId) external;
    function getCurrentFees() external view returns (uint256 projectFee, uint256 impactFee);

    // ================================
    // 🔹 Halving & Economic Adjustments
    // ================================
    function applyHalving() external;
    function updateHalvingPeriod(uint256 newHalvingPeriod) external;
    function getHalvingDetails() external view returns (uint256 period, uint256 lastTime, uint256 epoch);

    // ================================
    // 🔹 Buyback & Liquidity Adjustments
    // ================================
    function executeBuyback(uint256 amount) external;
    function injectLiquidity(uint256 amount) external;
    function setLiquidityPairing(bool enabled) external;
    function getLiquiditySettings() external view returns (bool isPairingEnabled);

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

    event ProposalTimelocked(uint256 indexed proposalId, uint256 unlockTime);
    event ProposalExecuted(uint256 indexed proposalId, address target, ProposalType proposalType);
    event ProposalVetoed(uint256 indexed proposalId);
    event ProposalThresholdUpdated(uint256 newThreshold);
    event VotingDurationUpdated(uint256 newDuration);
    event MinimumHoldingUpdated(uint256 newMinimumHolding);
    event GovernanceParametersUpdated(
        uint256 newVotingDuration,
        uint256 newProposalThreshold,
        uint256 newMinimumHolding
    );
    event RewardRateAdjusted(uint256 newRate, uint256 timestamp);
    event TokenRecovered(address indexed token, uint256 amount, address indexed recipient);

    event FeeUpdateProposed(uint256 indexed proposalId, uint256 newProjectFee, uint256 newImpactFee);
    event FeeUpdateExecuted(uint256 indexed proposalId, uint256 newProjectFee, uint256 newImpactFee);

    event HalvingApplied(uint256 newEpoch);
    event HalvingPeriodUpdated(uint256 newHalvingPeriod);

    event ProposalVotingEnded(uint256 indexed proposalId, uint256 votesFor, uint256 votesAgainst);
    event BuybackExecuted(uint256 usdcAmount, uint256 tStakeReceived);
    event LiquidityInjected(uint256 usdcAmount, uint256 tStakeAdded);
    event LiquidityPairingUpdated(bool isEnabled);
}
