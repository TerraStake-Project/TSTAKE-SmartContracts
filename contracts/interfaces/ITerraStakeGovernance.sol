// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./ITerraStakeTreasuryManager.sol";
import "./ITerraStakeValidatorSafety.sol";
import "./ITerraStakeGuardianCouncil.sol";

/**
 * @title ITerraStakeGovernance
 * @notice Interface for the main governance contract of the TerraStake Protocol
 * @dev Integrates treasury management, validator safety, and guardian council functions
 */
interface ITerraStakeGovernance {
    // -------------------------------------------
    //  Enums
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
    
    // Vote types
    enum VoteType {
        Against,
        For,
        Abstain
    }
    
    // -------------------------------------------
    //  Structs
    // -------------------------------------------
    struct Proposal {
        uint256 id;
        address proposer;
        string description;
        uint8 proposalType;
        uint256 createTime;
        uint256 voteStart;
        uint256 voteEnd;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
        bool canceled;
    }

    struct ExtendedProposalData {
        bytes customData;
        uint256 timelockExpiry;
    }

    struct Receipt {
        bool hasVoted;
        VoteType support;
        uint256 votes;
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
    
    // -------------------------------------------
    //  Events
    // -------------------------------------------
    
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string description,
        uint8 proposalType,
        uint256 voteStart,
        uint256 voteEnd
    );
    
    event ProposalCanceled(uint256 indexed proposalId);
    event ProposalQueued(uint256 indexed proposalId, uint256 queueTime);
    event ProposalExecuted(uint256 indexed proposalId);
    
    event VoteReason(
        uint256 indexed proposalId,
        address indexed voter,
        string reason
    );
    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        bool support,
        uint256 weight
    );
    
    event ValidatorSupport(
        address indexed validator,
        uint256 indexed proposalId,
        bool support
    );
    
    event GovernanceParametersUpdated(string parameter, uint256 oldValue, uint256 newValue);
    event ModuleUpdated(string moduleName, address oldModule, address newModule);
    event FeeStructureUpdated(
        uint256 projectSubmissionFee,
        uint256 impactReportingFee,
        uint256 buybackPercentage,
        uint256 liquidityPairingPercentage,
        uint256 burnPercentage,
        uint256 treasuryPercentage
    );
    event BuybackExecuted(uint256 amount0, uint256 amount1);
    event LiquidityAdded(uint256 amount0, uint256 amount1);
    event TokensBurned(uint256 amount);
    event HalvingInitiated(uint256 halvingEpoch);
    event ValidatorRewardRateUpdated(uint256 newRewardRate);
    event TreasuryWalletUpdated(address newTreasuryWallet);
    event LiquidityPairingToggled(bool enabled);
    event GovernorPenalized(address governor, string reason);
    event GovernorRestored(address governor);
    event EmergencyPauseActivated(address[] addresses);
    event EmergencyPauseDeactivated(address[] addresses);
    event EmergencyTokenRecovery(address token, uint256 amount, address recipient);
    event TStakeReceived(address sender, uint256 amount);

    // Validator safety events
    event GovernanceTierUpdated(uint8 tier, uint256 validatorCount);
    event BootstrapModeConfigured(uint256 duration);
    event BootstrapModeExited();
    event EmergencyThresholdReduction(uint256 newThreshold, uint256 duration);
    event ThresholdResetScheduled(uint256 resetTime);
    event ValidatorHealthCheck(uint256 validatorCount, uint256 totalStaked, uint256 avgStakePerValidator, uint8 governanceTier);
    event GuardianAdded(address guardian);
    event GuardianRemoved(address guardian);
    event ValidatorProposalCreated(uint256 proposalId, uint256 newThreshold);
    event ValidatorRecruitmentInitiated(uint256 incentiveAmount, uint256 targetCount);

    
    // -------------------------------------------
    //  Errors
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
    error GovernanceThresholdNotMet();
    error ProposalNotReady();
    error ProposalDoesNotExist();
    error InvalidVote();
    error TimelockNotExpired();
    error ProposalAlreadyExecuted();
    error GovernanceViolation();
    error InsufficientValidators();
    error ProposalTypeNotAllowed();
    error InvalidGuardianSignatures();
    error NonceAlreadyExecuted();
    
    // -------------------------------------------
    //  Constants
    // -------------------------------------------
    
    function GOVERNANCE_ROLE() external view returns (bytes32);
    function UPGRADER_ROLE() external view returns (bytes32);
    function GUARDIAN_ROLE() external view returns (bytes32);
    function VALIDATOR_ROLE() external view returns (bytes32);
    
    // -------------------------------------------
    //  State Variables
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
    
    function receipts(uint256 proposalId, address voter) external view returns (
        bool hasVoted,
        VoteType support,
        uint256 votes
    );
    
    function latestProposalIds(address proposer) external view returns (uint256);

    function applyHalving() external;
    function recordVote(uint256 proposalId, address voter, uint256 votingPower, bool support) external;

    // -------------------------------------------
    //  Proposal Creation and Management
    // -------------------------------------------
    
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        uint8 proposalType
    ) external returns (uint256);
    
    function castVote(
        uint256 proposalId,
        uint8 support,
        string memory reason
    ) external;
    
    function validatorSupport(uint256 proposalId, bool support) external;
    
    function queueProposal(uint256 proposalId) external;
    
    function executeProposal(uint256 proposalId) external;
    
    function cancelProposal(uint256 proposalId) external;
    
    // -------------------------------------------
    //  Governance Parameter Management
    // -------------------------------------------
    
    function updateProposalThreshold(uint256 newThreshold) external;
    
    function updateVotingDelay(uint256 newVotingDelay) external;
    
    function updateVotingPeriod(uint256 newVotingPeriod) external;
    
    function updateExecutionDelay(uint256 newExecutionDelay) external;
    
    function updateExecutionPeriod(uint256 newExecutionPeriod) external;
    
    // -------------------------------------------
    //  Module Management
    // -------------------------------------------
    
    function updateTreasuryManager(address newTreasuryManager) external;
    
    function updateValidatorSafety(address newValidatorSafety) external;
    
    function updateGuardianCouncil(address newGuardianCouncil) external;
    
    // -------------------------------------------
    //  Emergency Controls
    // -------------------------------------------
    
    function pause() external;
    
    function unpause() external;
    
    // -------------------------------------------
    //  View Functions
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
