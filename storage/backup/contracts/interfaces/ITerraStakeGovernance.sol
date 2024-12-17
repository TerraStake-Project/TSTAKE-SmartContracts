// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITerraStakeGovernance {
    struct Proposal {
        bytes data;
        address target;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 endBlock;
        bool executed;
        bool vetoed;
    }

    // Events
    event ProposalCreated(uint256 indexed proposalId, bytes data, uint256 endBlock, address target);
    event Voted(uint256 indexed proposalId, address indexed voter, bool support);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalVetoed(uint256 indexed proposalId);

    // Core Functions
    function initialize(
        address admin,
        address stakingContract,
        address itoContract,
        address priceFeed,
        uint256 votingDuration,
        uint256 proposalThreshold,
        uint256 minimumHolding
    ) external;

    function createProposal(bytes calldata data, address target) external;

    function vote(uint256 proposalId, bool support) external;

    function executeProposal(uint256 proposalId) external;

    function vetoProposal(uint256 proposalId) external;

    function validateOraclePrice(uint256 expectedPrice) external view;

    function updateStakingContract(address stakingContract) external;

    function updateITOContract(address itoContract) external;

    function updateProposalThreshold(uint256 newThreshold) external;

    function updateVotingDuration(uint256 newDuration) external;

    function updateMinimumHolding(uint256 newMinimumHolding) external;

    // View Functions
    function getProposalStatus(uint256 proposalId) external view returns (string memory);

    function proposalCount() external view returns (uint256);

    function votingDuration() external view returns (uint256);

    function proposalThreshold() external view returns (uint256);

    function minimumHolding() external view returns (uint256);
}
