// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITerraStakeGovernance {
    enum ProposalStatus { Active, Vetoed, Executed, VotingEnded }

    struct Proposal {
        bytes data;
        address target;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 endBlock;
        bool executed;
        bool vetoed;
        uint256 proposalType; // 0: Regular, 1: Enhanced
        uint256 linkedProjectId; // Associated project ID if applicable
    }

    // Events
    event ProposalCreated(
        uint256 indexed proposalId,
        bytes data,
        uint256 endBlock,
        address target,
        uint256 proposalType,
        uint256 linkedProjectId
    );
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

    // Core Functions
    function initialize(
        address admin,
        address stakingContract,
        address priceFeed,
        uint256 votingDuration,
        uint256 proposalThreshold,
        uint256 minimumHolding
    ) external;

    function createProposal(
        bytes calldata data,
        address target,
        uint256 proposalType,
        uint256 linkedProjectId
    ) external;

    function vote(uint256 proposalId, bool support) external;
    function executeProposal(uint256 proposalId) external;
    function vetoProposal(uint256 proposalId) external;

    function validateOraclePrice(uint256 expectedPrice) external view;

    function updateStakingContract(address stakingContract) external;
    function updateProposalThreshold(uint256 newThreshold) external;
    function updateVotingDuration(uint256 newDuration) external;
    function updateMinimumHolding(uint256 newMinimumHolding) external;

    // View Functions
    function getProposalStatus(uint256 proposalId) external view returns (ProposalStatus);
    function proposalCount() external view returns (uint256);
    function votingDuration() external view returns (uint256);
    function proposalThreshold() external view returns (uint256);
    function minimumHolding() external view returns (uint256);
    function calculateVotingPower(address user) external view returns (uint256);
    function getProposalDetails(uint256 proposalId) external view returns (Proposal memory);
    function getLinkedProjectId(uint256 proposalId) external view returns (uint256);
}
