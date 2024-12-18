// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/ITerraStakeITO.sol";

contract TerraStakeGovernance is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    // Errors
    error UnauthorizedAccess();
    error InvalidProposalData();
    error ProposalAlreadyExecuted();
    error ProposalAlreadyVetoed();
    error VotingPeriodEnded();
    error VotingPowerNotSufficient();
    error AlreadyVoted();
    error InvalidProposalId();
    error VotingPeriodNotEnded();

    // Roles
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant VETO_ROLE = keccak256("VETO_ROLE");

    // Admin Address
    address public constant MAIN_ADMIN = 0xcB3705b50773e95fCe6d3Fcef62B4d753aA0059d;

    // Structs
    struct Proposal {
        bytes data;
        address target;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 endBlock;
        bool executed;
        bool vetoed;
        uint256 proposalType;
        uint256 linkedProjectId;
        string description;
    }

    // State variables
    uint256 public proposalCount;
    uint256 public votingDuration;
    uint256 public proposalThreshold;
    uint256 public minimumHolding;

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(bytes32 => bool) public executedHashes;

    ITerraStakeStaking public stakingContract;
    ITerraStakeITO public itoContract;
    AggregatorV3Interface public priceFeed;

    uint256 public version;

    // Events
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

    /// @notice Initializes the contract and assigns roles
    function initialize(
        address _stakingContract,
        address _itoContract,
        address _priceFeed,
        uint256 _votingDuration,
        uint256 _proposalThreshold,
        uint256 _minimumHolding
    ) external initializer {
        require(MAIN_ADMIN != address(0), "Invalid admin address");

        __AccessControl_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, MAIN_ADMIN);
        _grantRole(GOVERNANCE_ROLE, MAIN_ADMIN);
        _grantRole(VETO_ROLE, MAIN_ADMIN);

        stakingContract = ITerraStakeStaking(_stakingContract);
        itoContract = ITerraStakeITO(_itoContract);
        priceFeed = AggregatorV3Interface(_priceFeed);

        votingDuration = _votingDuration;
        proposalThreshold = _proposalThreshold;
        minimumHolding = _minimumHolding;

        version = 1; // Initial version
    }

    function createProposal(
        bytes calldata data,
        address target,
        uint256 proposalType,
        uint256 linkedProjectId,
        string calldata description
    ) external onlyRole(GOVERNANCE_ROLE) {
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

    function vote(uint256 proposalId, bool support) external {
        Proposal storage proposal = proposals[proposalId];
        require(block.number <= proposal.endBlock, "Voting period ended");
        require(!hasVoted[proposalId][msg.sender], "Already voted");

        uint256 votingPower = _calculateVotingPower(msg.sender);
        require(votingPower > 0, "No voting power");

        hasVoted[proposalId][msg.sender] = true;

        if (support) {
            proposal.votesFor += votingPower;
        } else {
            proposal.votesAgainst += votingPower;
        }

        emit Voted(proposalId, msg.sender, support);
    }

    function executeProposal(uint256 proposalId) external onlyRole(GOVERNANCE_ROLE) {
        Proposal storage proposal = proposals[proposalId];
        require(block.number > proposal.endBlock, "Voting period not ended");
        require(!proposal.executed, "Proposal already executed");
        require(proposal.votesFor > proposal.votesAgainst, "Proposal did not pass");

        bytes32 executionHash = keccak256(proposal.data);
        require(!executedHashes[executionHash], "Already executed");

        executedHashes[executionHash] = true;

        (bool success, ) = proposal.target.call(proposal.data);
        require(success, "Execution failed");

        proposal.executed = true;
        emit ProposalExecuted(proposalId);
    }

    function vetoProposal(uint256 proposalId) external onlyRole(VETO_ROLE) {
        Proposal storage proposal = proposals[proposalId];
        require(!proposal.executed, "Proposal already executed");
        require(!proposal.vetoed, "Proposal already vetoed");

        proposal.vetoed = true;

        emit ProposalVetoed(proposalId);
    }

    function _calculateVotingPower(address voter) internal view returns (uint256) {
        return stakingContract.totalStakedByUser(voter);
    }

    function updateGovernanceParameters(
        uint256 newVotingDuration,
        uint256 newProposalThreshold,
        uint256 newMinimumHolding
    ) external onlyRole(GOVERNANCE_ROLE) {
        votingDuration = newVotingDuration;
        proposalThreshold = newProposalThreshold;
        minimumHolding = newMinimumHolding;
    }
}
