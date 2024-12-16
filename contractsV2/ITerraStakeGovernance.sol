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
        uint256 proposalType; // 0: Regular, 1: Enhanced (e.g., project-specific proposals)
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
    event Voted(uint256 indexed proposalId, address indexed voter, bool support, uint256 votingPower);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalVetoed(uint256 indexed proposalId);
    event ProposalThresholdUpdated(uint256 newThreshold);
    event VotingDurationUpdated(uint256 newDuration);
    event MinimumHoldingUpdated(uint256 newMinimumHolding);

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

    /// @notice Create a new proposal
    /// @param data The calldata to be executed if the proposal passes
    /// @param target The contract address the proposal interacts with
    /// @param proposalType The type of proposal (0: Regular, 1: Project-specific)
    /// @param linkedProjectId ID of the associated project, if applicable
    function createProposal(bytes calldata data, address target, uint256 proposalType, uint256 linkedProjectId) external;

    /// @notice Vote on a proposal
    /// @param proposalId The ID of the proposal being voted on
    /// @param support Whether the voter supports the proposal (true: for, false: against)
    function vote(uint256 proposalId, bool support) external;

    /// @notice Execute a passed proposal
    /// @param proposalId The ID of the proposal to execute
    function executeProposal(uint256 proposalId) external;

    /// @notice Veto a proposal
    /// @param proposalId The ID of the proposal to veto
    function vetoProposal(uint256 proposalId) external;

    /// @notice Validate the price from an oracle to ensure data integrity
    /// @param expectedPrice The price expected for validation
    function validateOraclePrice(uint256 expectedPrice) external view;

    /// @notice Update the staking contract address
    /// @param stakingContract The new staking contract address
    function updateStakingContract(address stakingContract) external;

    /// @notice Update the ITO contract address
    /// @param itoContract The new ITO contract address
    function updateITOContract(address itoContract) external;

    /// @notice Update the proposal threshold
    /// @param newThreshold The new proposal threshold
    function updateProposalThreshold(uint256 newThreshold) external;

    /// @notice Update the voting duration
    /// @param newDuration The new voting duration in blocks
    function updateVotingDuration(uint256 newDuration) external;

    /// @notice Update the minimum holding required for voting
    /// @param newMinimumHolding The new minimum holding
    function updateMinimumHolding(uint256 newMinimumHolding) external;

    // View Functions
    /// @notice Get the status of a proposal
    /// @param proposalId The ID of the proposal
    /// @return The status of the proposal as a string
    function getProposalStatus(uint256 proposalId) external view returns (string memory);

    /// @notice Get the total number of proposals
    /// @return The count of proposals
    function proposalCount() external view returns (uint256);

    /// @notice Get the voting duration
    /// @return The voting duration in blocks
    function votingDuration() external view returns (uint256);

    /// @notice Get the proposal threshold
    /// @return The minimum staked amount required to submit a proposal
    function proposalThreshold() external view returns (uint256);

    /// @notice Get the minimum holding for voting
    /// @return The minimum holding required to vote
    function minimumHolding() external view returns (uint256);

    /// @notice Calculate the voting power of a user
    /// @param user The address of the user
    /// @return The calculated voting power
    function calculateVotingPower(address user) external view returns (uint256);

    /// @notice Retrieve detailed proposal data
    /// @param proposalId The ID of the proposal
    /// @return The full proposal data
    function getProposalDetails(uint256 proposalId) external view returns (Proposal memory);

    /// @notice Retrieve the linked project ID for a proposal
    /// @param proposalId The ID of the proposal
    /// @return The linked project ID, or 0 if not applicable
    function getLinkedProjectId(uint256 proposalId) external view returns (uint256);
}
