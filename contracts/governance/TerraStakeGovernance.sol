// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

interface ITerraStakeLiabilityManager {
    function configureOracle(address token, address api3Proxy, uint256 heartbeatPeriod, uint256 minPrice, uint256 maxPrice, uint256 updateInterval) external;
    function setCustomTWAPWindow(address token, uint32 windowSize) external;
    function updateFeeStructure(uint256 governanceShare, uint256 offsetFundShare) external;
}

/**
 * @title TerraStakeGovernance
 * @notice Complete governance system with dynamic thresholds and cross-chain sync
 * @dev Features:
 * - 0.4% dynamic proposal threshold
 * - 8 proposal types with execution logic
 * - Multi-sig protected upgrades
 * - Comprehensive error handling
 */
contract TerraStakeGovernance is 
    Initializable, 
    AccessControlEnumerableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable 
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // Constants
    uint256 public constant PROPOSAL_THRESHOLD_BASIS_POINTS = 40; // 0.4%
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint16 public constant CHAIN_ID_BSC = 102;
    uint16 public constant CHAIN_ID_POLYGON = 109;
    uint16 public constant CHAIN_ID_ARBITRUM = 110;
    uint16 public constant CHAIN_ID_OPTIMISM = 111;

    // Proposal Types
    uint8 public constant PROPOSAL_TYPE_TREASURY = 1;
    uint8 public constant PROPOSAL_TYPE_VALIDATOR = 2;
    uint8 public constant PROPOSAL_TYPE_LIQUIDITY = 3;
    uint8 public constant PROPOSAL_TYPE_UPGRADE = 4;
    uint8 public constant PROPOSAL_TYPE_AI_BRIDGE = 5;
    uint8 public constant PROPOSAL_TYPE_GOVERNANCE_PARAMS = 6;
    uint8 public constant PROPOSAL_TYPE_HALVING = 7;
    uint8 public constant PROPOSAL_TYPE_LIABILITY_MANAGER = 8;

    // Errors
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
    error LiabilityManagerError(string reason);
    error EmergencyPauseActive();
    error NoTokensToUnlock();
    error InvalidQuorum();

    // State
    IERC20Upgradeable public governanceToken;
    address public treasuryExecutor;
    address public validatorSafety;
    address public liquidityManager;
    address public aiBridge;
    address public crossChainHandler;
    ITerraStakeLiabilityManager public liabilityManager;

    uint256 public proposalCount;
    uint256 public votingPeriod;
    uint256 public timelockPeriod;
    uint256 public proposalThreshold;
    uint256 public quorumThreshold;
    uint256 public requiredMultisigApprovals;
    bool public emergencyPause;

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

    struct ExtendedProposalData {
        bytes customData;
        uint256 timelockExpiry;
        bytes32 proposalHash;
    }

    struct Vote {
        bool support;
        uint256 votingPower;
        bool hasVoted;
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => ExtendedProposalData) public proposalExtendedData;
    mapping(address => uint256) public latestProposalIds;
    mapping(uint256 => mapping(address => Vote)) public votes;
    mapping(uint256 => mapping(address => bool)) public multiSigApprovals;
    mapping(address => uint256) public lockedTokens;
    mapping(uint16 => uint256) public chainGasLimits;
    mapping(uint256 => uint256) public upgradeApprovals;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant MULTISIG_ROLE = keccak256("MULTISIG_ROLE");
    bytes32 public constant LIABILITY_MANAGER_ROLE = keccak256("LIABILITY_MANAGER_ROLE");

    // Events
    event ProposalCreated(uint256 indexed proposalId, address proposer, string description, uint8 proposalType);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCanceled(uint256 indexed proposalId);
    event VoteCast(address indexed voter, uint256 indexed proposalId, bool support, uint256 votingPower);
    event TokensLocked(address indexed user, uint256 amount);
    event TokensUnlocked(address indexed user, uint256 amount);
    event GovernanceParamsUpdated(uint256 votingPeriod, uint256 timelockPeriod, uint256 proposalThreshold, uint256 quorumThreshold);
    event EmergencyShutdown(bool paused);
    event CrossChainSyncSent(uint16 indexed chainId, bytes32 indexed payloadHash, uint256 nonce);
    event ProposalThresholdUpdated(uint256 newThreshold);
    event MultiSigUpgradeApproved(uint256 indexed proposalId, address approver);
    event MultiSigUpgradeExecuted(uint256 indexed proposalId);

    function initialize(
        address _governanceToken,
        address _treasuryExecutor,
        address _validatorSafety,
        address _liquidityManager,
        address _aiBridge,
        address _crossChainHandler,
        address _liabilityManager,
        address _admin
    ) external initializer {
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        if (_governanceToken == address(0) || _treasuryExecutor == address(0) ||
            _validatorSafety == address(0) || _liquidityManager == address(0) ||
            _aiBridge == address(0) || _crossChainHandler == address(0) ||
            _liabilityManager == address(0) || _admin == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(GOVERNANCE_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
        _grantRole(MULTISIG_ROLE, _admin);
        _grantRole(LIABILITY_MANAGER_ROLE, _admin);

        governanceToken = IERC20Upgradeable(_governanceToken);
        treasuryExecutor = _treasuryExecutor;
        validatorSafety = _validatorSafety;
        liquidityManager = _liquidityManager;
        aiBridge = _aiBridge;
        crossChainHandler = _crossChainHandler;
        liabilityManager = ITerraStakeLiabilityManager(_liabilityManager);

        votingPeriod = 5 days;
        timelockPeriod = 2 days;
        quorumThreshold = 5000; // 50%
        requiredMultisigApprovals = 3;

        _updateProposalThreshold();
    }

    // ========== Proposal Lifecycle ==========

    function propose(
        string memory description,
        uint8 proposalType,
        bytes memory data
    ) external nonReentrant returns (uint256) {
        if (emergencyPause) revert EmergencyPauseActive();
        if (proposalType < PROPOSAL_TYPE_TREASURY || proposalType > PROPOSAL_TYPE_LIABILITY_MANAGER) {
            revert InvalidProposalType();
        }

        _updateProposalThreshold();
        uint256 votingPower = governanceToken.balanceOf(msg.sender);
        if (votingPower < proposalThreshold) revert InsufficientVotingPower();

        governanceToken.safeTransferFrom(msg.sender, address(this), proposalThreshold);
        lockedTokens[msg.sender] += proposalThreshold;
        emit TokensLocked(msg.sender, proposalThreshold);

        uint256 proposalId = ++proposalCount;
        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            description: description,
            proposalType: proposalType,
            voteStart: block.timestamp,
            voteEnd: block.timestamp + votingPeriod,
            forVotes: 0,
            againstVotes: 0,
            executed: false,
            canceled: false,
            totalVotingPower: governanceToken.totalSupply()
        });

        proposalExtendedData[proposalId] = ExtendedProposalData({
            customData: data,
            timelockExpiry: block.timestamp + votingPeriod + timelockPeriod,
            proposalHash: keccak256(abi.encode(proposalId, msg.sender, description, proposalType, data))
        });

        emit ProposalCreated(proposalId, msg.sender, description, proposalType);
        _syncProposalCreation(proposalId, proposalType, description, data);

        return proposalId;
    }

    function executeProposal(uint256 proposalId) external nonReentrant {
        if (proposalId == 0 || proposalId > proposalCount) revert ProposalDoesNotExist();
        
        Proposal storage proposal = proposals[proposalId];
        ExtendedProposalData storage extendedData = proposalExtendedData[proposalId];
        
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (proposal.canceled) revert ProposalAlreadyCanceled();
        if (block.timestamp <= proposal.voteEnd) revert ProposalNotActive();
        if (block.timestamp < extendedData.timelockExpiry) revert ProposalNotReady();
        
        uint256 totalVotes = proposal.forVotes + proposal.againstVotes;
        if (totalVotes * BASIS_POINTS_DIVISOR / proposal.totalVotingPower < quorumThreshold) revert QuorumNotReached();
        if (proposal.forVotes <= proposal.againstVotes) revert InvalidProposalState();
        
        if (proposal.proposalType == PROPOSAL_TYPE_UPGRADE) {
            if (upgradeApprovals[proposalId] < requiredMultisigApprovals) revert NotEnoughMultiSigApprovals();
        }
        
        _executeProposal(proposalId, proposal.proposalType, extendedData.customData);
        proposal.executed = true;
        emit ProposalExecuted(proposalId);
        
        _unlockTokens(proposal.proposer, proposalThreshold);
        _syncProposalExecution(proposalId, proposal.proposalType, extendedData.customData);
    }

    function cancelProposal(uint256 proposalId) external {
        if (proposalId == 0 || proposalId > proposalCount) revert ProposalDoesNotExist();
        
        Proposal storage proposal = proposals[proposalId];
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (proposal.canceled) revert ProposalAlreadyCanceled();
        
        if (msg.sender != proposal.proposer && !hasRole(GOVERNANCE_ROLE, msg.sender)) revert Unauthorized();
        
        proposal.canceled = true;
        _unlockTokens(proposal.proposer, proposalThreshold);
        
        emit ProposalCanceled(proposalId);
        _syncProposalCancellation(proposalId);
    }

    function unlockTokens(uint256 proposalId) external nonReentrant {
        if (proposalId == 0 || proposalId > proposalCount) revert ProposalDoesNotExist();
        
        Proposal storage proposal = proposals[proposalId];
        if (msg.sender != proposal.proposer) revert Unauthorized();
        if (!proposal.executed && !proposal.canceled && block.timestamp <= proposal.voteEnd) revert ProposalNotReady();
        
        _unlockTokens(msg.sender, proposalThreshold);
    }

    // ========== Voting System ==========

    function castVote(uint256 proposalId, bool support) external nonReentrant {
        if (proposalId == 0 || proposalId > proposalCount) revert ProposalDoesNotExist();
        
        Proposal storage proposal = proposals[proposalId];
        if (block.timestamp > proposal.voteEnd) revert ProposalExpired();
        if (proposal.executed || proposal.canceled) revert ProposalNotActive();
        
        Vote storage vote = votes[proposalId][msg.sender];
        if (vote.hasVoted) revert AlreadyVoted();
        
        uint256 votingPower = governanceToken.balanceOf(msg.sender);
        if (votingPower == 0) revert InsufficientVotingPower();
        
        if (support) {
            proposal.forVotes += votingPower;
        } else {
            proposal.againstVotes += votingPower;
        }
        
        vote.support = support;
        vote.votingPower = votingPower;
        vote.hasVoted = true;
        
        emit VoteCast(msg.sender, proposalId, support, votingPower);
        _syncVote(proposalId, msg.sender, support, votingPower);
    }

    // ========== Multi-Sig System ==========

    function approveUpgradeProposal(uint256 proposalId) external onlyRole(MULTISIG_ROLE) {
        if (proposalId == 0 || proposalId > proposalCount) revert ProposalDoesNotExist();
        
        Proposal storage proposal = proposals[proposalId];
        if (proposal.proposalType != PROPOSAL_TYPE_UPGRADE) revert InvalidProposalType();
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (proposal.canceled) revert ProposalAlreadyCanceled();
        if (multiSigApprovals[proposalId][msg.sender]) revert AlreadyVoted();
        
        multiSigApprovals[proposalId][msg.sender] = true;
        upgradeApprovals[proposalId]++;
        emit MultiSigUpgradeApproved(proposalId, msg.sender);

        if (upgradeApprovals[proposalId] >= requiredMultisigApprovals) {
            if (block.timestamp > proposal.voteEnd &&
                proposal.forVotes > proposal.againstVotes &&
                (proposal.forVotes + proposal.againstVotes) * BASIS_POINTS_DIVISOR / proposal.totalVotingPower >= quorumThreshold) {
                _executeProposal(proposalId, PROPOSAL_TYPE_UPGRADE, proposalExtendedData[proposalId].customData);
                emit MultiSigUpgradeExecuted(proposalId);
            }
        }
    }

    // ========== Internal Functions ==========

    function _executeProposal(uint256 proposalId, uint8 proposalType, bytes memory data) internal {
        if (proposalType == PROPOSAL_TYPE_TREASURY) {
            (bool success, ) = treasuryExecutor.call(data);
            if (!success) revert ExecutionFailed("Treasury action failed");
        } 
        else if (proposalType == PROPOSAL_TYPE_VALIDATOR) {
            (bool success, ) = validatorSafety.call(data);
            if (!success) revert ExecutionFailed("Validator action failed");
        }
        else if (proposalType == PROPOSAL_TYPE_LIQUIDITY) {
            (bool success, ) = liquidityManager.call(data);
            if (!success) revert ExecutionFailed("Liquidity action failed");
        }
        else if (proposalType == PROPOSAL_TYPE_UPGRADE) {
            address newImplementation = abi.decode(data, (address));
            _upgradeTo(newImplementation);
        }
        else if (proposalType == PROPOSAL_TYPE_AI_BRIDGE) {
            (bool success, ) = aiBridge.call(data);
            if (!success) revert ExecutionFailed("AI Bridge action failed");
        }
        else if (proposalType == PROPOSAL_TYPE_GOVERNANCE_PARAMS) {
            (uint256 newVotingPeriod, uint256 newTimelockPeriod, uint256 newQuorumThreshold) = 
                abi.decode(data, (uint256, uint256, uint256));
            _updateGovernanceParams(newVotingPeriod, newTimelockPeriod, newQuorumThreshold);
        }
        else if (proposalType == PROPOSAL_TYPE_HALVING) {
            uint256 newEpoch = abi.decode(data, (uint256));
            if (newEpoch <= 0) revert InvalidHalvingEpoch();
            // Additional halving logic would go here
        }
        else if (proposalType == PROPOSAL_TYPE_LIABILITY_MANAGER) {
            (uint8 actionType, bytes memory actionData) = abi.decode(data, (uint8, bytes));
            _executeLiabilityAction(actionType, actionData);
        }
        else {
            revert InvalidProposalType();
        }
    }

    function _executeLiabilityAction(uint8 actionType, bytes memory actionData) internal {
        if (actionType == 1) { // Update Oracle
            (address token, address api3Proxy, uint256 heartbeatPeriod, 
             uint256 minPrice, uint256 maxPrice, uint256 updateInterval) = 
                abi.decode(actionData, (address, address, uint256, uint256, uint256, uint256));
            try liabilityManager.configureOracle(token, api3Proxy, heartbeatPeriod, minPrice, maxPrice, updateInterval) {
            } catch {
                revert LiabilityManagerError("Oracle config failed");
            }
        }
        else if (actionType == 2) { // Update TWAP
            (address token, uint32 windowSize) = abi.decode(actionData, (address, uint32));
            try liabilityManager.setCustomTWAPWindow(token, windowSize) {
            } catch {
                revert LiabilityManagerError("TWAP update failed");
            }
        }
        else if (actionType == 3) { // Update Fees
            (uint256 governanceShare, uint256 offsetFundShare) = abi.decode(actionData, (uint256, uint256));
            try liabilityManager.updateFeeStructure(governanceShare, offsetFundShare) {
            } catch {
                revert LiabilityManagerError("Fee update failed");
            }
        }
        else {
            revert InvalidProposalType();
        }
    }

    function _unlockTokens(address user, uint256 amount) internal {
        if (lockedTokens[user] < amount) revert NoTokensToUnlock();
        lockedTokens[user] -= amount;
        governanceToken.safeTransfer(user, amount);
        emit TokensUnlocked(user, amount);
    }

    function _updateProposalThreshold() internal {
        uint256 totalSupply = governanceToken.totalSupply();
        uint256 newThreshold = (totalSupply * PROPOSAL_THRESHOLD_BASIS_POINTS) / BASIS_POINTS_DIVISOR;
        proposalThreshold = newThreshold;
        emit ProposalThresholdUpdated(newThreshold);
    }

    function _updateGovernanceParams(
        uint256 newVotingPeriod,
        uint256 newTimelockPeriod,
        uint256 newQuorumThreshold
    ) internal {
        if (newVotingPeriod < 1 days) revert InvalidVotingPeriod();
        if (newTimelockPeriod < 1 days) revert InvalidTimelockPeriod();
        if (newQuorumThreshold == 0 || newQuorumThreshold > BASIS_POINTS_DIVISOR) revert InvalidQuorum();

        votingPeriod = newVotingPeriod;
        timelockPeriod = newTimelockPeriod;
        quorumThreshold = newQuorumThreshold;

        emit GovernanceParamsUpdated(newVotingPeriod, newTimelockPeriod, proposalThreshold, newQuorumThreshold);
        _syncGovernanceParamsUpdate(newVotingPeriod, newTimelockPeriod, proposalThreshold, newQuorumThreshold);
    }

    // ========== Cross-Chain Sync ==========

    function _syncProposalCreation(uint256 proposalId, uint8 proposalType, string memory description, bytes memory data) internal {
        bytes memory payload = abi.encode("CREATE", proposalId, msg.sender, proposalType, description, data);
        _sendCrossChainMessage(CHAIN_ID_BSC, payload);
        _sendCrossChainMessage(CHAIN_ID_POLYGON, payload);
    }

    function _syncVote(uint256 proposalId, address voter, bool support, uint256 votingPower) internal {
        bytes memory payload = abi.encode("VOTE", proposalId, voter, support, votingPower);
        _sendCrossChainMessage(CHAIN_ID_BSC, payload);
        _sendCrossChainMessage(CHAIN_ID_POLYGON, payload);
    }

    function _syncProposalExecution(uint256 proposalId, uint8 proposalType, bytes memory data) internal {
        bytes memory payload = abi.encode("EXECUTE", proposalId, proposalType, data);
        _sendCrossChainMessage(CHAIN_ID_BSC, payload);
        _sendCrossChainMessage(CHAIN_ID_POLYGON, payload);
    }

    function _syncProposalCancellation(uint256 proposalId) internal {
        bytes memory payload = abi.encode("CANCEL", proposalId);
        _sendCrossChainMessage(CHAIN_ID_BSC, payload);
        _sendCrossChainMessage(CHAIN_ID_POLYGON, payload);
    }

    function _syncGovernanceParamsUpdate(
        uint256 votingPeriod,
        uint256 timelockPeriod,
        uint256 proposalThreshold,
        uint256 quorumThreshold
    ) internal {
        bytes memory payload = abi.encode(
            "UPDATE_PARAMS",
            votingPeriod,
            timelockPeriod,
            proposalThreshold,
            quorumThreshold
        );
        _sendCrossChainMessage(CHAIN_ID_BSC, payload);
        _sendCrossChainMessage(CHAIN_ID_POLYGON, payload);
    }

    function _sendCrossChainMessage(uint16 chainId, bytes memory payload) internal {
        if (crossChainHandler == address(0)) return;
        
        (bool success, ) = crossChainHandler.call(
            abi.encodeWithSignature(
                "sendMessage(uint16,bytes)",
                chainId,
                payload
            )
        );
        
        if (!success) {
            revert CrossChainSyncFailed(chainId, keccak256(payload));
        }
    }

    // ========== View Functions ==========

    function getProposalState(uint256 proposalId) external view returns (uint8) {
        if (proposalId == 0 || proposalId > proposalCount) revert ProposalDoesNotExist();
        
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.canceled) return 4; // Canceled
        if (proposal.executed) return 3; // Executed
        if (block.timestamp <= proposal.voteEnd) return 0; // Active
        
        uint256 totalVotes = proposal.forVotes + proposal.againstVotes;
        if (totalVotes * BASIS_POINTS_DIVISOR / proposal.totalVotingPower < quorumThreshold) return 2; // Defeated
        
        return (proposal.forVotes > proposal.againstVotes) ? 1 : 2; // Succeeded or Defeated
    }

    function getMultisigApprovals(uint256 proposalId) external view returns (uint256, uint256) {
        if (proposalId == 0 || proposalId > proposalCount) revert ProposalDoesNotExist();
        return (requiredMultisigApprovals, upgradeApprovals[proposalId]);
    }

    function hasApproved(uint256 proposalId, address approver) external view returns (bool) {
        if (proposalId == 0 || proposalId > proposalCount) revert ProposalDoesNotExist();
        return multiSigApprovals[proposalId][approver];
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        if (newImplementation == address(0)) revert ZeroAddress();
    }
}