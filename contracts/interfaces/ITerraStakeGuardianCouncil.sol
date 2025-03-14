// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

/**
 * @title ITerraStakeGuardianCouncil
 * @author TerraStake Protocol Team
 * @notice Interface for the guardian council management and multi-signature verification
 * for the TerraStake Protocol's emergency governance actions
 */
interface ITerraStakeGuardianCouncil {
    // -------------------------------------------
    //  Constants
    // -------------------------------------------
    function GOVERNANCE_ROLE() external view returns (bytes32);
    function UPGRADER_ROLE() external view returns (bytes32);
    function GUARDIAN_ROLE() external view returns (bytes32);
    
    function EMERGENCY_PAUSE() external view returns (bytes4);
    function EMERGENCY_UNPAUSE() external view returns (bytes4);
    function REMOVE_VALIDATOR() external view returns (bytes4);
    function REDUCE_THRESHOLD() external view returns (bytes4);
    function GUARDIAN_OVERRIDE() external view returns (bytes4);
    
    // -------------------------------------------
    //  Events
    // -------------------------------------------
    event GuardianAdded(address indexed guardian);
    event GuardianRemoved(address indexed guardian);
    event GuardianQuorumUpdated(uint256 oldQuorum, uint256 newQuorum);
    event SignatureTimeoutUpdated(uint256 newTimeout);
    event GuardianUpdateCooldownUpdated(uint256 newCooldown);
    event EmergencyTargetAdded(bytes4 operationType, address target);
    event EmergencyTargetRemoved(bytes4 operationType, address target);
    event NonceIncremented(uint256 newNonce);
    event GuardianOverride(bytes4 operation, address target, bytes data);
    event EmergencyActionAttempt(bytes4 operationType, bool success);
    
    // -------------------------------------------
    //  Errors
    // -------------------------------------------
    error Unauthorized();
    error InvalidParameters();
    error CooldownActive();
    error InvalidSignatures();
    error SignatureTimedOut();
    error QuorumTooHigh();
    error QuorumTooLow();
    error OperationAlreadyExecuted();
    error EmergencyTargetNotFound();
    error EmergencyActionFailed();
    
    // -------------------------------------------
    //  View Functions
    // -------------------------------------------
    function GUARDIAN_QUORUM() external view returns (uint256);
    function currentNonce() external view returns (uint256);
    function signatureTimeout() external view returns (uint256);
    function guardianCouncil(address) external view returns (bool);
    function guardianList(uint256) external view returns (address);
    
    function lastGuardianUpdate() external view returns (uint256);
    function guardianUpdateCooldown() external view returns (uint256);
    
    function usedOperationHashes(bytes32) external view returns (bool);
    function emergencyTargets(bytes4, uint256) external view returns (address);
    
    function getAllGuardians() external view returns (address[] memory);
    function getGuardianCount() external view returns (uint256);
    function isGuardianUpdateOnCooldown() external view returns (bool);
    function getEmergencyTargets(bytes4 operationType) external view returns (address[] memory);
    function isOperationExecuted(
        bytes4 operation,
        address target,
        bytes calldata data
    ) external view returns (bool);
    
    function validateGuardianSignatures(
        bytes4 operation,
        address target,
        bytes calldata data,
        bytes[] calldata signatures,
        uint256 timestamp
    ) external view returns (bool);
    
    // -------------------------------------------
    //  State-Changing Functions
    // -------------------------------------------
    function initialize(
        address _initialAdmin,
        address[] calldata _initialGuardians
    ) external;
    
    function addGuardian(address guardian) external;
    function removeGuardian(address guardian) external;
    function updateGuardianQuorum(uint256 newQuorum) external;
    function updateSignatureTimeout(uint256 newTimeout) external;
    function updateGuardianUpdateCooldown(uint256 newCooldown) external;
    
    function addEmergencyTarget(bytes4 operationType, address target) external;
    function removeEmergencyTarget(bytes4 operationType, address target) external;
    
    function incrementNonce() external;
    
    function guardianOverride(
        bytes4 operation,
        address target,
        bytes calldata data,
        bytes[] calldata signatures,
        uint256 timestamp
    ) external;
    
    function executeEmergencyPause(
        bytes[] calldata signatures,
        uint256 timestamp
    ) external;
    
    function executeEmergencyUnpause(
        bytes[] calldata signatures,
        uint256 timestamp
    ) external;
    
    function executeRemoveValidator(
        address validator,
        bytes[] calldata signatures,
        uint256 timestamp
    ) external;
}
