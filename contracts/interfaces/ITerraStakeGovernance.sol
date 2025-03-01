// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/ITerraStakeTreasuryManager.sol";
import "../interfaces/ITerraStakeValidatorSafety.sol";
import "../interfaces/ITerraStakeGuardianCouncil.sol";

/**
 * @title ITerraStakeGovernance
 * @notice Interface for the main governance contract of the TerraStake Protocol
 * @dev Integrates treasury management, validator safety, and guardian council functions
 */
interface ITerraStakeGovernance {
    // -------------------------------------------
    // 🔹 Enums
    // -------------------------------------------
    
    // Proposal states
    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }
    
    // Proposal types
    enum ProposalType {
        Standard,
        Parameter,
        Emergency,
        Upgrade
    }
    
    // Vote types
    enum VoteType {
        Against,
        For,
        Abstain
    }
    
    // -------------------------------------------
    // 🔹 Structs
    // -------------------------------------------
    
    struct Receipt {
        bool hasVoted;
        VoteType support;
        uint256 votes;
    }
    
    // -------------------------------------------
    // 🔹 Events
    // -------------------------------------------
    
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        address[] targets,
        uint256[] values,
        bytes[] calldatas,
        uint256 startBlock,
        uint256 endBlock,
        string description,
        ProposalType proposalType
    );
    
    event ProposalCanceled(uint256 indexed proposalId);
    event ProposalQueued(uint256 indexed proposalId, uint256 queueTime);
    event ProposalExecuted(uint256 indexed proposalId);
    
    event VoteCast(
        address indexed voter,
        uint256 indexed proposalId,
        uint8 support,
        uint256 weight,
        string reason
    );
    
    event ValidatorSupport(
        address indexed validator,
        uint256 indexed proposalId,
        bool support
    );
    
    event GovernanceParameterUpdated(string parameter, uint256 oldValue, uint256 newValue);
    event ModuleUpdated(string moduleName, address oldModule, address newModule);
    
    // -------------------------------------------
    // 🔹 Errors
    // -------------------------------------------
    
    error Unauthorized();
    error InvalidParameters();
    error InvalidProposalState();
    error ProposalNotActive();
    error ProposalExpired();
    error AlreadyVoted();
    error InsufficientVotingPower();
    error InvalidTargetCount();
    error EmptyProposal();
    error TooManyActions();
    error InvalidState();
    
    // -------------------------------------------
    // 🔹 Constants
    // -------------------------------------------
    
    function GOVERNANCE_ROLE() external view returns (bytes32);
    function UPGRADER_ROLE() external view returns (bytes32);
    function GUARDIAN_ROLE() external view returns (bytes32);
    function VALIDATOR_ROLE() external view returns (bytes32);
    
    // -------------------------------------------
    // 🔹 State Variables
    // -------------------------------------------
    
    function treasuryManager() external view returns (ITerraStakeTreasuryManager);
    function validatorSafety() external view returns (ITerraStakeValidatorSafety);
    function guardianCouncil() external view returns (ITerraStakeGuardianCouncil);
    function tStakeToken() external view returns (IERC20);
    
    function proposalThreshold() external view returns (uint256);
    function votingDelay() external view returns (uint256);
    function votingPeriod() external view returns (uint256);
    function executionDelay() external view returns (uint256);
    function executionPeriod() external view returns (uint256);
    function proposalCount() external view returns (uint256);
    
    function proposals(uint256 proposalId) external view returns (
        uint256 id,
        address proposer,
        ProposalType proposalType,
        uint256 startBlock,
        uint256 endBlock,
        uint256 forVotes,
        uint256 againstVotes,
        uint256 abstainVotes,
        bool canceled,
        bool executed,
        uint256 queueTime
    );
    
    function receipts(uint256 proposalId, address voter) external view returns (
        bool hasVoted,
        VoteType support,
        uint256 votes
    );
    
    function latestProposalIds(address proposer) external view returns (uint256);
    
    // -------------------------------------------
    // 🔹 Initialization
    // -------------------------------------------
    
    function initialize(
        address _treasuryManager,
        address _validatorSafety,
        address _guardianCouncil,
        address _tStakeToken,
        address _initialAdmin
    ) external;
    
    // -------------------------------------------
    // 🔹 Proposal Creation and Management
    // -------------------------------------------
    
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        ProposalType proposalType
    ) external returns (uint256);
    
    function castVote(
        uint256 proposalId,
        uint8 support,
        string memory reason
    ) external;
    
    function validatorSupport(uint256 proposalId, bool support) external;
    
    function queueProposal(uint256 proposalId) external;
    
    function executeProposal(uint256 proposalId) external payable;
    
    function cancelProposal(uint256 proposalId) external;
    
    // -------------------------------------------
    // 🔹 Governance Parameter Management
    // -------------------------------------------
    
    function updateProposalThreshold(uint256 newThreshold) external;
    
    function updateVotingDelay(uint256 newVotingDelay) external;
    
    function updateVotingPeriod(uint256 newVotingPeriod) external;
    
    function updateExecutionDelay(uint256 newExecutionDelay) external;
    
    function updateExecutionPeriod(uint256 newExecutionPeriod) external;
    
    // -------------------------------------------
    // 🔹 Module Management
    // -------------------------------------------
    
    function updateTreasuryManager(address newTreasuryManager) external;
    
    function updateValidatorSafety(address newValidatorSafety) external;
    
    function updateGuardianCouncil(address newGuardianCouncil) external;
    
    // -------------------------------------------
    // 🔹 Emergency Controls
    // -------------------------------------------
    
    function pause() external;
    
    function unpause() external;
    
    // -------------------------------------------
    // 🔹 View Functions
    // -------------------------------------------
    
    function getProposalState(uint256 proposalId) external view returns (ProposalState);
    
    function getProposalDetails(uint256 proposalId) external view returns (
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    );
    
    function getProposalVotes(uint256 proposalId) external view returns (
        uint256 againstVotes,
        uint256 forVotes,
        uint256 abstainVotes,
        uint256 validatorSupport
    );
    
    function hasProposalSucceeded(uint256 proposalId) external view returns (bool);
}
