// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import "../interfaces/ITerraStakeStaking.sol";

/**
 * @title TerraStakeGovernance
 * @notice A stake-based governance contract, which can be deployed on Arbitrum or any EVM chain.
 *         - Proposers must meet a proposalThreshold in staked TSTAKE to create proposals.
 *         - Voters must hold a minimumHolding in staked TSTAKE to vote.
 *         - "Passing" proposals require votesFor > votesAgainst after voting ends.
 *         - VETO_ROLE can veto proposals that are not executed yet.
 *         - One-time execution enforced via executedHashes[keccak256(data)].
 */
contract TerraStakeGovernance is 
    Initializable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    // ------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------
    error UnauthorizedAccess();
    error InvalidProposalData();
    error ProposalAlreadyExecuted();
    error ProposalAlreadyVetoed();
    error VotingPeriodEnded();
    error VotingPowerNotSufficient();
    error AlreadyVoted();
    error InvalidProposalId();
    error VotingPeriodNotEnded();
    error ProposalThresholdNotMet(uint256 staked, uint256 threshold);
    error MinimumHoldingNotMet(uint256 staked, uint256 required);

    // ------------------------------------------------------------------------
    // Roles
    // ------------------------------------------------------------------------
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant VETO_ROLE       = keccak256("VETO_ROLE");

    // ------------------------------------------------------------------------
    // Admin Address (Hardcoded)
    // ------------------------------------------------------------------------
    address public constant MAIN_ADMIN = 0xcB3705b50773e95fCe6d3Fcef62B4d753aA0059d;

    // ------------------------------------------------------------------------
    // Proposal Struct
    // ------------------------------------------------------------------------
    struct Proposal {
        bytes data;         // Encoded call data for target
        address target;     // Address to call
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 endBlock;   // End of voting period
        bool executed;
        bool vetoed;
        uint256 proposalType;
        uint256 linkedProjectId;
        string description;
    }

    // ------------------------------------------------------------------------
    // State Variables
    // ------------------------------------------------------------------------
    uint256 public proposalCount;
    uint256 public votingDuration;      // e.g., 6400 blocks (~1 day on Arbitrum)
    uint256 public proposalThreshold;   // e.g., 10_000e18 TSTAKE required to propose
    uint256 public minimumHolding;      // e.g., 1_000e18 TSTAKE required to vote

    // proposals[proposalId] => Proposal
    mapping(uint256 => Proposal) public proposals;
    // hasVoted[proposalId][voter] => bool
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    // executedHashes[keccak256(data)] => bool
    // ensures identical data won't be executed multiple times
    mapping(bytes32 => bool) public executedHashes;

    // External interface for staking
    ITerraStakeStaking public stakingContract;

    // Optional price feed (for future expansions or off-chain checks)
    AggregatorV3Interface public priceFeed;

    uint256 public version; // Contract version, increments on upgrade if desired

    // ------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------
    event ProposalCreated(
        uint256 indexed proposalId,
        bytes data,
        uint256 endBlock,
        address target,
        uint256 proposalType,
        uint256 linkedProjectId,
        string description
    );
    event Voted(uint256 indexed proposalId, address indexed voter, bool support);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalVetoed(uint256 indexed proposalId);

    // ------------------------------------------------------------------------
    // Initialization
    // ------------------------------------------------------------------------
    /**
     * @notice Initialize the governance contract
     * @param _stakingContract Address of the TerraStakeStaking contract
     * @param _priceFeed Chainlink aggregator for TSTAKE if needed (otherwise can be unused)
     * @param _votingDuration Number of blocks voting is open
     * @param _proposalThreshold Minimum staked TSTAKE required to create proposals
     * @param _minimumHolding Minimum staked TSTAKE required to vote
     */
    function initialize(
        address _stakingContract,
        address _priceFeed,
        uint256 _votingDuration,
        uint256 _proposalThreshold,
        uint256 _minimumHolding
    ) external initializer {
        require(MAIN_ADMIN != address(0), "Invalid admin address");
        require(_stakingContract != address(0), "Invalid staking contract");

        __AccessControl_init();
        __ReentrancyGuard_init();

        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, MAIN_ADMIN);
        _grantRole(GOVERNANCE_ROLE, MAIN_ADMIN);
        _grantRole(VETO_ROLE, MAIN_ADMIN);

        // Store external references
        stakingContract = ITerraStakeStaking(_stakingContract);
        priceFeed = AggregatorV3Interface(_priceFeed); // can be zero if not used

        // Set governance parameters
        votingDuration   = _votingDuration;
        proposalThreshold= _proposalThreshold;
        minimumHolding   = _minimumHolding;

        version = 1; // Initial version
    }

    // ------------------------------------------------------------------------
    // Proposal Creation
    // ------------------------------------------------------------------------
    /**
     * @notice Create a proposal if you meet the proposalThreshold
     * @param data Encoded call data for the target
     * @param target Address to call on proposal execution
     * @param proposalType Type or category of proposal for off-chain usage
     * @param linkedProjectId If proposal is linked to a project ID, store it
     * @param description A human-readable description of the proposal
     */
    function createProposal(
        bytes calldata data,
        address target,
        uint256 proposalType,
        uint256 linkedProjectId,
        string calldata description
    ) external onlyRole(GOVERNANCE_ROLE) {
        // Check the caller's staked TSTAKE
        uint256 staked = _calculateVotingPower(msg.sender);
        if (staked < proposalThreshold) {
            revert ProposalThresholdNotMet(staked, proposalThreshold);
        }

        require(target != address(0), "Invalid target address");

        uint256 proposalId = proposalCount++;
        proposals[proposalId] = Proposal({
            data: data,
            target: target,
            votesFor: 0,
            votesAgainst: 0,
            endBlock: block.number + votingDuration,
            executed: false,
            vetoed: false,
            proposalType: proposalType,
            linkedProjectId: linkedProjectId,
            description: description
        });

        emit ProposalCreated(
            proposalId,
            data,
            block.number + votingDuration,
            target,
            proposalType,
            linkedProjectId,
            description
        );
    }

    // ------------------------------------------------------------------------
    // Voting
    // ------------------------------------------------------------------------
    /**
     * @notice Vote for or against a proposal, assuming you meet minimumHolding
     * @param proposalId The ID of the proposal
     * @param support True = vote for, False = vote against
     */
    function vote(uint256 proposalId, bool support) external {
        Proposal storage proposal = proposals[proposalId];
        if (block.number > proposal.endBlock) revert VotingPeriodEnded();
        if (hasVoted[proposalId][msg.sender]) revert AlreadyVoted();

        uint256 staked = _calculateVotingPower(msg.sender);
        // Must meet minimumHolding to vote
        if (staked < minimumHolding) {
            revert MinimumHoldingNotMet(staked, minimumHolding);
        }

        hasVoted[proposalId][msg.sender] = true;

        if (support) {
            proposal.votesFor += staked;
        } else {
            proposal.votesAgainst += staked;
        }

        emit Voted(proposalId, msg.sender, support);
    }

    // ------------------------------------------------------------------------
    // Execution
    // ------------------------------------------------------------------------
    /**
     * @notice Execute a proposal if it passes (votesFor > votesAgainst) after voting ends
     * @param proposalId The ID of the proposal
     */
    function executeProposal(uint256 proposalId) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        if (block.number <= proposal.endBlock) revert VotingPeriodNotEnded();
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (proposal.vetoed) revert ProposalAlreadyVetoed();
        if (proposal.votesFor <= proposal.votesAgainst) revert("Proposal did not pass");

        bytes32 executionHash = keccak256(proposal.data);
        if (executedHashes[executionHash]) revert("Proposal data already executed");

        executedHashes[executionHash] = true;

        // Low-level call
        (bool success, ) = proposal.target.call(proposal.data);
        require(success, "Execution failed");

        proposal.executed = true;
        emit ProposalExecuted(proposalId);
    }

    // ------------------------------------------------------------------------
    // Veto
    // ------------------------------------------------------------------------
    /**
     * @notice VETO_ROLE can veto a proposal before it is executed
     * @param proposalId The ID of the proposal
     */
    function vetoProposal(uint256 proposalId) external onlyRole(VETO_ROLE) {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (proposal.vetoed) revert ProposalAlreadyVetoed();

        proposal.vetoed = true;
        emit ProposalVetoed(proposalId);
    }

    // ------------------------------------------------------------------------
    // Governance Parameter Updates
    // ------------------------------------------------------------------------
    /**
     * @notice Update governance configuration (only GOVERNANCE_ROLE)
     * @param newVotingDuration New block duration for voting
     * @param newProposalThreshold New TSTAKE threshold for proposal creation
     * @param newMinimumHolding New TSTAKE threshold for voting
     */
    function updateGovernanceParameters(
        uint256 newVotingDuration,
        uint256 newProposalThreshold,
        uint256 newMinimumHolding
    ) external onlyRole(GOVERNANCE_ROLE) {
        votingDuration   = newVotingDuration;
        proposalThreshold= newProposalThreshold;
        minimumHolding   = newMinimumHolding;
    }

    // ------------------------------------------------------------------------
    // Internal & View Helpers
    // ------------------------------------------------------------------------
    /**
     * @dev Returns the TSTAKE staked by `voter`, used to weigh votes and check threshold
     */
    function _calculateVotingPower(address voter) internal view returns (uint256) {
        return stakingContract.totalStakedByUser(voter);
    }
}
