// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./ITerraStakeTreasuryManager.sol";
import "./ITerraStakeValidatorSafety.sol";
import "./ITerraStakeGuardianCouncil.sol";
import "./ITreasuryExecutor.sol";
import "./ILiquidityManager.sol";
import "./ITerraStakeAIBridge.sol";
import "./ICrossChainHandler.sol";

/**
 * @title ITerraStakeGovernance
 * @notice Interface for the TerraStake Governance contract with halving and cross-chain sync
 * @dev Synced with TerraStakeGovernance contract, supports TerraStakeToken halving and CrossChainHandler v2.2.1
 */
interface ITerraStakeGovernance {
    // -------------------------------------------
    // Enums
    // -------------------------------------------
    /**
     * @notice Proposal states as implemented in TerraStakeGovernance
     * @dev Simplified to match getProposalState return values
     */
    enum ProposalState {
        Active,      // 0: Voting period active
        Succeeded,   // 1: Passed quorum and majority
        Defeated,    // 2: Failed quorum or majority
        Executed,    // 3: Successfully executed
        Canceled     // 4: Canceled by proposer or governance
    }

    // -------------------------------------------
    // Structs
    // -------------------------------------------
    /**
     * @notice Core proposal data
     * @param id Unique proposal identifier
     * @param proposer Address of the proposer
     * @param description Proposal description
     * @param proposalType Type of proposal (1-7)
     * @param voteStart Voting start timestamp
     * @param voteEnd Voting end timestamp
     * @param forVotes Total votes in favor
     * @param againstVotes Total votes against
     * @param executed Whether the proposal has been executed
     * @param canceled Whether the proposal has been canceled
     * @param totalVotingPower Total voting power at proposal creation
     */
    struct Proposal {
        uint256 id;
        address proposer;
        string description;
        uint8 proposalType;
        uint256 voteStart;
        uint256 voteEnd;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
        bool canceled;
        uint256 totalVotingPower;
    }

    /**
     * @notice Extended proposal data
     * @param customData Encoded data for execution
     * @param timelockExpiry Timestamp when execution is allowed
     * @param proposalHash Hash of proposal details
     */
    struct ExtendedProposalData {
        bytes customData;
        uint256 timelockExpiry;
        bytes32 proposalHash;
    }

    /**
     * @notice Vote data for a voter
     * @param support True for yes, false for no
     * @param votingPower Amount of voting power used
     * @param hasVoted Whether the voter has voted
     */
    struct Vote {
        bool support;
        uint256 votingPower;
        bool hasVoted;
    }

    // -------------------------------------------
    // Events
    // -------------------------------------------
    event ProposalCreated(uint256 indexed proposalId, address proposer, string description, uint8 proposalType);
    event ProposalApproved(uint256 indexed proposalId);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCanceled(uint256 indexed proposalId);
    event VoteCast(address indexed voter, uint256 indexed proposalId, bool support, uint256 votingPower);
    event MultiSigUpgradeApproved(uint256 indexed proposalId, address approver);
    event MultiSigUpgradeExecuted(uint256 indexed proposalId);
    event TokensLocked(address indexed user, uint256 amount);
    event TokensUnlocked(address indexed user, uint256 amount);
    event GovernanceParamsUpdated(uint256 votingPeriod, uint256 timelockPeriod, uint256 proposalThreshold, uint256 quorumThreshold);
    event CrossChainSyncSent(uint16 indexed chainId, bytes32 indexed payloadHash, uint256 nonce);
    event HalvingTriggered(uint256 indexed proposalId, uint256 newEpoch);

    // -------------------------------------------
    // Errors
    // -------------------------------------------
    error Unauthorized();
    error InvalidProposalState();
    error ProposalNotActive();
    error ProposalExpired();
    error AlreadyVoted();
    error InsufficientVotingPower();
    error ProposalNotReady();
    error ProposalDoesNotExist();
    error ProposalAlreadyExecuted();
    error QuorumNotReached();
    error InvalidVotingPeriod();
    error InvalidTimelockPeriod();
    error ExecutionFailed(string reason);
    error NotEnoughMultiSigApprovals();
    error ProposalAlreadyCanceled();
    error ZeroAddress();
    error InvalidProposalType();
    error InvalidThreshold();
    error CrossChainSyncFailed(uint16 chainId, bytes32 payloadHash);
    error InvalidHalvingEpoch();

    // -------------------------------------------
    // Constants
    // -------------------------------------------
    function GOVERNANCE_ROLE() external view returns (bytes32);
    function UPGRADER_ROLE() external view returns (bytes32);
    function MULTISIG_ROLE() external view returns (bytes32);

    function PROPOSAL_TYPE_TREASURY() external view returns (uint8);
    function PROPOSAL_TYPE_VALIDATOR() external view returns (uint8);
    function PROPOSAL_TYPE_LIQUIDITY() external view returns (uint8);
    function PROPOSAL_TYPE_UPGRADE() external view returns (uint8);
    function PROPOSAL_TYPE_AI_BRIDGE() external view returns (uint8);
    function PROPOSAL_TYPE_GOVERNANCE_PARAMS() external view returns (uint8);
    function PROPOSAL_TYPE_HALVING() external view returns (uint8);

    function CHAIN_ID_BSC() external view returns (uint16);
    function CHAIN_ID_POLYGON() external view returns (uint16);

    // -------------------------------------------
    // State Variables
    // -------------------------------------------
    function governanceToken() external view returns (IERC20);
    function treasuryExecutor() external view returns (ITreasuryExecutor);
    function validatorSafety() external view returns (IValidatorSafety);
    function liquidityManager() external view returns (ILiquidityManager);
    function aiBridge() external view returns (ITerraStakeAIBridge);
    function crossChainHandler() external view returns (ICrossChainHandler);

    function proposalCount() external view returns (uint256);
    function proposals(uint256 proposalId) external view returns (
        uint256 id,
        address proposer,
        string memory description,
        uint8 proposalType,
        uint256 voteStart,
        uint256 voteEnd,
        uint256 forVotes,
        uint256 againstVotes,
        bool executed,
        bool canceled,
        uint256 totalVotingPower
    );
    function proposalExtendedData(uint256 proposalId) external view returns (
        bytes memory customData,
        uint256 timelockExpiry,
        bytes32 proposalHash
    );
    function latestProposalIds(address proposer) external view returns (uint256);
    function votes(uint256 proposalId, address voter) external view returns (
        bool support,
        uint256 votingPower,
        bool hasVoted
    );
    function multiSigApprovals(uint256 proposalId, address approver) external view returns (bool);
    function upgradeApprovals(uint256 proposalId) external view returns (uint256);
    function lockedTokens(address user) external view returns (uint256);

    function votingPeriod() external view returns (uint256);
    function timelockPeriod() external view returns (uint256);
    function proposalThreshold() external view returns (uint256);
    function quorumThreshold() external view returns (uint256);
    function requiredMultisigApprovals() external view returns (uint256);

    function currentChainState() external view returns (ICrossChainHandler.CrossChainState memory);

    // -------------------------------------------
    // Initialization
    // -------------------------------------------
    /**
     * @notice Initializes the governance contract
     * @param _governanceToken Address of the governance token (TerraStakeToken)
     * @param _treasuryExecutor Address of the treasury executor
     * @param _validatorSafety Address of the validator safety
     * @param _liquidityManager Address of the liquidity manager
     * @param _aiBridge Address of the AI bridge
     * @param _crossChainHandler Address of the cross-chain handler
     * @param _admin Initial admin address
     */
    function initialize(
        address _governanceToken,
        address _treasuryExecutor,
        address _validatorSafety,
        address _liquidityManager,
        address _aiBridge,
        address _crossChainHandler,
        address _admin
    ) external;

    // -------------------------------------------
    // Proposal Management
    // -------------------------------------------
    /**
     * @notice Creates a new governance proposal
     * @param description Proposal description
     * @param proposalType Type of proposal (1-7)
     * @param data Custom data for execution
     * @return proposalId ID of the created proposal
     */
    function propose(
        string memory description,
        uint8 proposalType,
        bytes memory data
    ) external returns (uint256);

    /**
     * @notice Casts a vote on a proposal
     * @param proposalId ID of the proposal
     * @param support True for yes, false for no
     */
    function castVote(uint256 proposalId, bool support) external;

    /**
     * @notice Executes a proposal after voting and timelock
     * @param proposalId ID of the proposal
     */
    function executeProposal(uint256 proposalId) external;

    /**
     * @notice Approves an upgrade proposal by a multisig member
     * @param proposalId ID of the upgrade proposal
     */
    function approveUpgradeProposal(uint256 proposalId) external;

    /**
     * @notice Cancels a proposal
     * @param proposalId ID of the proposal
     */
    function cancelProposal(uint256 proposalId) external;

    /**
     * @notice Unlocks tokens after proposal execution or cancellation
     * @param proposalId ID of the proposal
     */
    function unlockTokens(uint256 proposalId) external;

    // -------------------------------------------
    // Governance Parameter Management
    // -------------------------------------------
    /**
     * @notice Updates governance parameters
     * @param _votingPeriod New voting period
     * @param _timelockPeriod New timelock period
     * @param _proposalThreshold New proposal threshold
     * @param _quorumThreshold New quorum threshold (basis points)
     */
    function updateGovernanceParams(
        uint256 _votingPeriod,
        uint256 _timelockPeriod,
        uint256 _proposalThreshold,
        uint256 _quorumThreshold
    ) external;

    /**
     * @notice Updates the required number of multisig approvals
     * @param _requiredApprovals New number of required approvals
     */
    function updateRequiredMultisigApprovals(uint256 _requiredApprovals) external;

    // -------------------------------------------
    // Cross-Chain Sync
    // -------------------------------------------
    /**
     * @notice Updates state from cross-chain messages
     * @param srcChainId Source chain ID
     * @param state New cross-chain state (e.g., halving data)
     */
    function updateFromCrossChain(uint16 srcChainId, ICrossChainHandler.CrossChainState memory state) external;

    // -------------------------------------------
    // View Functions
    // -------------------------------------------
    /**
     * @notice Gets the state of a proposal
     * @param proposalId ID of the proposal
     * @return State (0=Active, 1=Succeeded, 2=Defeated, 3=Executed, 4=Canceled)
     */
    function getProposalState(uint256 proposalId) external view returns (ProposalState);

    /**
     * @notice Gets detailed information about a proposal
     * @param proposalId ID of the proposal
     * @return proposer Proposer address
     * @return description Proposal description
     * @return proposalType Type of proposal
     * @return voteStart Voting start timestamp
     * @return voteEnd Voting end timestamp
     * @return forVotes Votes in favor
     * @return againstVotes Votes against
     * @return executed Execution status
     * @return canceled Cancellation status
     * @return totalVotingPower Total voting power
     * @return customData Execution data
     * @return timelockExpiry Timelock expiry timestamp
     */
    function getProposalDetails(uint256 proposalId) external view returns (
        address proposer,
        string memory description,
        uint8 proposalType,
        uint256 voteStart,
        uint256 voteEnd,
        uint256 forVotes,
        uint256 againstVotes,
        bool executed,
        bool canceled,
        uint256 totalVotingPower,
        bytes memory customData,
        uint256 timelockExpiry
    );

    /**
     * @notice Gets the current chain state (halving data)
     * @return Current CrossChainState
     */
    function getCurrentChainState() external view returns (ICrossChainHandler.CrossChainState memory);
}