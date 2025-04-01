// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "../interfaces/ITerraStakeGuardianCouncil.sol";

/**
 * @title TerraStakeGuardianCouncil v2.1
 * @notice Fully decentralized and economy-friendly Guardian Council for emergency actions.
 * @dev Uses multi-signature approvals, on-chain voting, and timelocks to ensure fair governance.
 */
contract TerraStakeGuardianCouncil is 
    Initializable, 
    AccessControlEnumerableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable
{
    using ECDSA for bytes32;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // Actions Guardians can perform
    bytes4 public constant FREEZE_VALIDATOR = 0x3d18f5f9;
    bytes4 public constant UNFREEZE_VALIDATOR = 0x7e9e7d8e;

    uint96 public quorumNeeded;
    uint96 public nonce;
    uint64 public proposalExpiry;
    uint64 public changeCooldown;
    uint64 public lastChangeTime;
    uint64 public timelockDuration;

    mapping(address => bool) public guardianCouncil;
    address[] public guardianList;

    struct GuardianProposal {
        bytes4 action;
        address target;
        uint256 createdAt;
        uint256 executeAfter;
        bool executed;
    }

    mapping(bytes32 => GuardianProposal) public proposals;
    mapping(bytes32 => mapping(address => bool)) public proposalVotes;

    event GuardianAdded(address indexed guardian);
    event GuardianRemoved(address indexed guardian);
    event QuorumUpdated(uint256 oldQuorum, uint256 newQuorum);
    event ProposalCreated(bytes32 proposalId, bytes4 action, address target, uint256 createdAt);
    event ProposalExecuted(bytes32 proposalId, bool success);
    event ProposalVoted(bytes32 proposalId, address voter);
    event SignatureExpiryUpdated(uint256 newExpiry);
    event ChangeCooldownUpdated(uint256 newCooldown);
    event TimelockUpdated(uint256 newDuration);

    error InvalidAddress();
    error InvalidQuorum();
    error DuplicateGuardian();
    error NotGuardian();
    error MinimumGuardians();
    error CooldownActive();
    error ProposalNotFound();
    error ProposalExpired();
    error AlreadyExecuted();
    error AlreadyVoted();
    error TimelockNotPassed();
    error InvalidAction();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract with admin and initial guardians
     * @param admin The address of the admin
     * @param initialGuardians Array of initial guardian addresses
     * @dev Requires at least 3 guardians to start
     */
    function initialize(address admin, address[] calldata initialGuardians) external initializer {
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        if (admin == address(0)) revert InvalidAddress();
        if (initialGuardians.length < 3) revert MinimumGuardians();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);

        for (uint256 i = 0; i < initialGuardians.length; i++) {
            address guardian = initialGuardians[i];
            if (guardian == address(0)) revert InvalidAddress();
            if (guardianCouncil[guardian]) revert DuplicateGuardian();

            guardianCouncil[guardian] = true;
            guardianList.push(guardian);
            _grantRole(GUARDIAN_ROLE, guardian);
        }

        quorumNeeded = uint96((initialGuardians.length * 2) / 3 + 1);
        nonce = 1;
        proposalExpiry = 2 days;
        changeCooldown = 7 days;
        timelockDuration = 1 days;
    }

    /**
     * @notice Authorize contract upgrades
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    /**
     * @notice Propose a new action to be executed
     * @param action The action to perform (FREEZE_VALIDATOR or UNFREEZE_VALIDATOR)
     * @param target The target address for the action
     * @return proposalId The ID of the created proposal
     */
    function proposeAction(bytes4 action, address target) external onlyRole(GUARDIAN_ROLE) returns (bytes32 proposalId) {
        if (action != FREEZE_VALIDATOR && action != UNFREEZE_VALIDATOR) revert InvalidAction();
        if (target == address(0)) revert InvalidAddress();

        proposalId = keccak256(abi.encode(action, target, nonce++));
        if (proposals[proposalId].createdAt > 0) revert("Proposal already exists");

        proposals[proposalId] = GuardianProposal({
            action: action,
            target: target,
            createdAt: block.timestamp,
            executeAfter: block.timestamp + timelockDuration,
            executed: false
        });

        emit ProposalCreated(proposalId, action, target, block.timestamp);
    }

    /**
     * @notice Vote on an existing proposal
     * @param proposalId The ID of the proposal to vote on
     */
    function voteOnProposal(bytes32 proposalId) external onlyRole(GUARDIAN_ROLE) {
        GuardianProposal storage proposal = proposals[proposalId];
        if (proposal.createdAt == 0) revert ProposalNotFound();
        if (proposal.executed) revert AlreadyExecuted();
        if (proposalVotes[proposalId][msg.sender]) revert AlreadyVoted();
        if (block.timestamp > proposal.createdAt + proposalExpiry) revert ProposalExpired();

        proposalVotes[proposalId][msg.sender] = true;
        emit ProposalVoted(proposalId, msg.sender);

        uint256 voteCount = 0;
        for (uint256 i = 0; i < guardianList.length; i++) {
            if (proposalVotes[proposalId][guardianList[i]]) voteCount++;
        }

        if (voteCount >= quorumNeeded && block.timestamp >= proposal.executeAfter) {
            _executeProposal(proposalId);
        }
    }

    /**
     * @notice Execute a proposal that has reached quorum
     * @param proposalId The ID of the proposal to execute
     */
    function executeProposal(bytes32 proposalId) external onlyRole(GUARDIAN_ROLE) {
        GuardianProposal storage proposal = proposals[proposalId];
        if (proposal.createdAt == 0) revert ProposalNotFound();
        if (proposal.executed) revert AlreadyExecuted();
        if (block.timestamp < proposal.executeAfter) revert TimelockNotPassed();
        if (block.timestamp > proposal.createdAt + proposalExpiry) revert ProposalExpired();

        uint256 voteCount = 0;
        for (uint256 i = 0; i < guardianList.length; i++) {
            if (proposalVotes[proposalId][guardianList[i]]) voteCount++;
        }
        if (voteCount < quorumNeeded) revert("Quorum not reached");

        _executeProposal(proposalId);
    }

    /**
     * @dev Internal function to execute a proposal
     * @param proposalId The ID of the proposal to execute
     */
    function _executeProposal(bytes32 proposalId) internal {
        GuardianProposal storage proposal = proposals[proposalId];
        proposal.executed = true;
        
        (bool success, ) = proposal.target.call(abi.encodeWithSelector(proposal.action));
        emit ProposalExecuted(proposalId, success);
    }

    /**
     * @notice Add a new guardian to the council
     * @param guardian The address of the new guardian
     */
    function addGuardian(address guardian) external onlyRole(GOVERNANCE_ROLE) {
        uint64 _now = uint64(block.timestamp);
        if (_now < lastChangeTime + changeCooldown) revert CooldownActive();
        if (guardian == address(0)) revert InvalidAddress();
        if (guardianCouncil[guardian]) revert DuplicateGuardian();

        guardianCouncil[guardian] = true;
        guardianList.push(guardian);
        _grantRole(GUARDIAN_ROLE, guardian);
        
        lastChangeTime = _now;
        quorumNeeded = uint96((guardianList.length * 2) / 3 + 1);

        emit GuardianAdded(guardian);
        emit QuorumUpdated(quorumNeeded - 1, quorumNeeded);
    }

    /**
     * @notice Remove a guardian from the council
     * @param guardian The address of the guardian to remove
     */
    function removeGuardian(address guardian) external onlyRole(GOVERNANCE_ROLE) {
        uint64 _now = uint64(block.timestamp);
        if (_now < lastChangeTime + changeCooldown) revert CooldownActive();
        if (!guardianCouncil[guardian]) revert NotGuardian();
        if (guardianList.length <= 3) revert MinimumGuardians();

        guardianCouncil[guardian] = false;
        for (uint256 i = 0; i < guardianList.length; i++) {
            if (guardianList[i] == guardian) {
                guardianList[i] = guardianList[guardianList.length - 1];
                guardianList.pop();
                break;
            }
        }

        _revokeRole(GUARDIAN_ROLE, guardian);
        lastChangeTime = _now;
        uint96 oldQuorum = quorumNeeded;
        quorumNeeded = uint96((guardianList.length * 2) / 3 + 1);

        emit GuardianRemoved(guardian);
        emit QuorumUpdated(oldQuorum, quorumNeeded);
    }

    /**
     * @notice Update the quorum needed for proposals
     * @param newQuorum The new quorum value
     */
    function updateQuorum(uint96 newQuorum) external onlyRole(GOVERNANCE_ROLE) {
        uint256 minQuorum = (guardianList.length * 2) / 3 + 1;
        if (newQuorum < minQuorum || newQuorum > guardianList.length) revert InvalidQuorum();
        
        uint96 oldQuorum = quorumNeeded;
        quorumNeeded = newQuorum;
        emit QuorumUpdated(oldQuorum, newQuorum);
    }

    /**
     * @notice Update the proposal expiry duration
     * @param newExpiry The new expiry duration in seconds
     */
    function updateProposalExpiry(uint64 newExpiry) external onlyRole(GOVERNANCE_ROLE) {
        proposalExpiry = newExpiry;
        emit SignatureExpiryUpdated(newExpiry);
    }

    /**
     * @notice Update the cooldown period between guardian changes
     * @param newCooldown The new cooldown duration in seconds
     */
    function updateChangeCooldown(uint64 newCooldown) external onlyRole(GOVERNANCE_ROLE) {
        changeCooldown = newCooldown;
        emit ChangeCooldownUpdated(newCooldown);
    }

    /**
     * @notice Update the timelock duration for proposals
     * @param newDuration The new timelock duration in seconds
     */
    function updateTimelockDuration(uint64 newDuration) external onlyRole(GOVERNANCE_ROLE) {
        timelockDuration = newDuration;
        emit TimelockUpdated(newDuration);
    }

    /**
     * @notice Get all guardian addresses
     * @return Array of guardian addresses
     */
    function getAllGuardians() external view returns (address[] memory) {
        return guardianList;
    }

    /**
     * @notice Get proposal details
     * @param proposalId The ID of the proposal
     * @return The proposal details
     */
    function getProposal(bytes32 proposalId) external view returns (GuardianProposal memory) {
        return proposals[proposalId];
    }

    /**
     * @notice Check if an address is a guardian
     * @param user The address to check
     * @return True if the address is a guardian
     */
    function isGuardian(address user) external view returns (bool) {
        return guardianCouncil[user];
    }

    /**
     * @notice Get the current vote count for a proposal
     * @param proposalId The ID of the proposal
     * @return The number of votes received
     */
    function getVoteCount(bytes32 proposalId) external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < guardianList.length; i++) {
            if (proposalVotes[proposalId][guardianList[i]]) {
                count++;
            }
        }
        return count;
    }
}