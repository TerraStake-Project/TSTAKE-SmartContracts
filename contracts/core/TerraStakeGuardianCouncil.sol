// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "../interfaces/ITerraStakeGuardianCouncil.sol";


/**
 * @title TerraStakeGuardianCouncil
 * @author TerraStake Protocol Team
 * @notice Guardian council management and multi-signature verification for
 * the TerraStake Protocol's emergency governance actions
 */
contract TerraStakeGuardianCouncil is 
    Initializable, 
    AccessControlEnumerableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable
{
    using ECDSA for bytes32;
    
    // -------------------------------------------
    //  Constants
    // -------------------------------------------
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    
    // Emergency operation types
    bytes4 public constant EMERGENCY_PAUSE = bytes4(keccak256("EMERGENCY_PAUSE"));
    bytes4 public constant EMERGENCY_UNPAUSE = bytes4(keccak256("EMERGENCY_UNPAUSE"));
    bytes4 public constant REMOVE_VALIDATOR = bytes4(keccak256("REMOVE_VALIDATOR"));
    bytes4 public constant REDUCE_THRESHOLD = bytes4(keccak256("REDUCE_THRESHOLD"));
    bytes4 public constant GUARDIAN_OVERRIDE = bytes4(keccak256("GUARDIAN_OVERRIDE"));
    
    // -------------------------------------------
    //  State Variables
    // -------------------------------------------
    
    // Guardian configuration
    uint256 public GUARDIAN_QUORUM;
    uint256 public currentNonce;
    uint256 public signatureTimeout;
    mapping(address => bool) public guardianCouncil;
    address[] public guardianList;
    
    // Guardian management
    uint256 public lastGuardianUpdate;
    uint256 public guardianUpdateCooldown;
    
    // Override tracking
    mapping(bytes32 => bool) public usedOperationHashes;
    
    // Contract references for emergency actions
    mapping(bytes4 => address[]) public emergencyTargets;
    
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
    //  Initializer & Upgrade Control
    // -------------------------------------------
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @notice Initialize the guardian council contract
     * @param _initialAdmin Initial admin address
     * @param _initialGuardians Array of initial guardian addresses
     */
    function initialize(
        address _initialAdmin,
        address[] calldata _initialGuardians
    ) external initializer {
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        // Grant admin roles
        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        _grantRole(UPGRADER_ROLE, _initialAdmin);
        _grantRole(GOVERNANCE_ROLE, _initialAdmin);
        
        // Set up initial guardians
        require(_initialGuardians.length >= 3, "Minimum 3 guardians required");
        
        for (uint256 i = 0; i < _initialGuardians.length; i++) {
            address guardian = _initialGuardians[i];
            require(guardian != address(0), "Invalid guardian address");
            
            _grantRole(GUARDIAN_ROLE, guardian);
            guardianCouncil[guardian] = true;
            guardianList.push(guardian);
        }
        
        // Set initial parameters
        GUARDIAN_QUORUM = _initialGuardians.length * 2 / 3 + 1; // >66% of guardians
        currentNonce = 1;
        signatureTimeout = 1 days;
        guardianUpdateCooldown = 7 days;
    }
    
    /**
     * @notice Authorize contract upgrades, restricted to the upgrader role
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
    
    // -------------------------------------------
    //  Guardian Management Functions
    // -------------------------------------------
    
    /**
     * @notice Add a new guardian to the council
     * @param guardian Address of the new guardian
     */
    function addGuardian(address guardian) external onlyRole(GOVERNANCE_ROLE) {
        // Check cooldown period
        if (block.timestamp < lastGuardianUpdate + guardianUpdateCooldown) {
            revert CooldownActive();
        }
        
        if (guardian == address(0)) revert InvalidParameters();
        if (guardianCouncil[guardian]) revert InvalidParameters();
        
        // Add to guardian council
        guardianCouncil[guardian] = true;
        guardianList.push(guardian);
        
        // Grant role
        _grantRole(GUARDIAN_ROLE, guardian);
        
        // Update guardian status
        lastGuardianUpdate = block.timestamp;
        
        emit GuardianAdded(guardian);
    }
    
    /**
     * @notice Remove a guardian from the council
     * @param guardian Address of the guardian to remove
     */
    function removeGuardian(address guardian) external onlyRole(GOVERNANCE_ROLE) {
        // Check cooldown period
        if (block.timestamp < lastGuardianUpdate + guardianUpdateCooldown) {
            revert CooldownActive();
        }
        
        if (!guardianCouncil[guardian]) revert InvalidParameters();
        
        // Ensure we maintain minimum number of guardians (at least 3)
        if (guardianList.length <= 3) revert InvalidParameters();
        
        // Remove from guardian council
        guardianCouncil[guardian] = false;
        
        // Remove from guardian list (by swapping with last element)
        for (uint256 i = 0; i < guardianList.length; i++) {
            if (guardianList[i] == guardian) {
                guardianList[i] = guardianList[guardianList.length - 1];
                guardianList.pop();
                break;
            }
        }
        
        // Revoke role
        _revokeRole(GUARDIAN_ROLE, guardian);
        
        // Update guardian status
        lastGuardianUpdate = block.timestamp;
        
        // Update quorum if needed to maintain >66% requirement
        uint256 minimumQuorum = guardianList.length * 2 / 3 + 1;
        if (GUARDIAN_QUORUM > guardianList.length || GUARDIAN_QUORUM < minimumQuorum) {
            uint256 oldQuorum = GUARDIAN_QUORUM;
            GUARDIAN_QUORUM = minimumQuorum;
            emit GuardianQuorumUpdated(oldQuorum, GUARDIAN_QUORUM);
        }
        
        emit GuardianRemoved(guardian);
    }
    
    /**
     * @notice Update the guardian quorum threshold
     * @param newQuorum New quorum value
     */
    function updateGuardianQuorum(uint256 newQuorum) external onlyRole(GOVERNANCE_ROLE) {
        // Check cooldown period
        if (block.timestamp < lastGuardianUpdate + guardianUpdateCooldown) {
            revert CooldownActive();
        }
        
        // Calculate minimum and maximum allowed values (between 60% and 90%)
        uint256 minQuorum = guardianList.length * 6 / 10 + 1; // >60%
        uint256 maxQuorum = guardianList.length * 9 / 10 + 1; // >90%
        
        // Enforce quorum bounds
        if (newQuorum < minQuorum) revert QuorumTooLow();
        if (newQuorum > maxQuorum) revert QuorumTooHigh();
        // Quorum can't exceed guardian count
        if (newQuorum > guardianList.length) revert QuorumTooHigh();
        
        uint256 oldQuorum = GUARDIAN_QUORUM;
        GUARDIAN_QUORUM = newQuorum;
        lastGuardianUpdate = block.timestamp;
        
        emit GuardianQuorumUpdated(oldQuorum, newQuorum);
    }
    
    /**
     * @notice Update signature timeout period
     * @param newTimeout New timeout value in seconds
     */
    function updateSignatureTimeout(uint256 newTimeout) external onlyRole(GOVERNANCE_ROLE) {
        // Timeout must be between 1 hour and 7 days
        if (newTimeout < 1 hours || newTimeout > 7 days) revert InvalidParameters();
        
        signatureTimeout = newTimeout;
        
        emit SignatureTimeoutUpdated(newTimeout);
    }
    
    /**
     * @notice Update guardian management cooldown period
     * @param newCooldown New cooldown value in seconds
     */
    function updateGuardianUpdateCooldown(uint256 newCooldown) external onlyRole(GOVERNANCE_ROLE) {
        // Cooldown must be between 1 day and 30 days
        if (newCooldown < 1 days || newCooldown > 30 days) revert InvalidParameters();
        
        guardianUpdateCooldown = newCooldown;
        
        emit GuardianUpdateCooldownUpdated(newCooldown);
    }
    
    // -------------------------------------------
    //  Emergency Target Management
    // -------------------------------------------
    
    /**
     * @notice Add a target contract for emergency operations
     * @param operationType Type of operation (EMERGENCY_PAUSE, etc.)
     * @param target Address of the target contract
     */
    function addEmergencyTarget(bytes4 operationType, address target) external onlyRole(GOVERNANCE_ROLE) {
        if (target == address(0)) revert InvalidParameters();
        
        // Check if target already exists for this operation type
        address[] storage targets = emergencyTargets[operationType];
        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i] == target) revert InvalidParameters();
        }
        
        // Add target
        emergencyTargets[operationType].push(target);
        
        emit EmergencyTargetAdded(operationType, target);
    }
    
    /**
     * @notice Remove a target contract for emergency operations
     * @param operationType Type of operation (EMERGENCY_PAUSE, etc.)
     * @param target Address of the target contract
     */
    function removeEmergencyTarget(bytes4 operationType, address target) external onlyRole(GOVERNANCE_ROLE) {
        address[] storage targets = emergencyTargets[operationType];
        bool found = false;
        
        // Find and remove target
        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i] == target) {
                targets[i] = targets[targets.length - 1];
                targets.pop();
                found = true;
                break;
            }
        }
        
        if (!found) revert EmergencyTargetNotFound();
        
        emit EmergencyTargetRemoved(operationType, target);
    }
    
    // -------------------------------------------
    //  Signature Verification and Guardian Override
    // -------------------------------------------
    
    /**
     * @notice Increment the nonce to invalidate any pending signatures
     * @dev Can be called by any guardian to prevent replay attacks
     */
    function incrementNonce() external onlyRole(GUARDIAN_ROLE) {
        currentNonce++;
        emit NonceIncremented(currentNonce);
    }
    
    /**
     * @notice Validate guardian signatures for an operation
     * @param operation Type of operation
     * @param target Target contract address
     * @param data Call data for the operation
     * @param signatures Array of guardian signatures
     * @param timestamp Timestamp when signatures were collected
     * @return True if signatures are valid and meet quorum
     */
    function validateGuardianSignatures(
        bytes4 operation,
        address target,
        bytes memory data,
        bytes[] calldata signatures,
        uint256 timestamp
    ) public view returns (bool) {
        // Check signature count meets quorum
        if (signatures.length < GUARDIAN_QUORUM) return false;
        
        // Check timestamp is not too old
        if (block.timestamp > timestamp + signatureTimeout) return false;
        if (timestamp > block.timestamp) return false; // No future timestamps
        
        // Hash the operation details with current nonce to prevent replay
        bytes32 messageHash = keccak256(abi.encodePacked(
            operation,
            target,
            data,
            currentNonce,
            timestamp
        ));
        
        // Prefix the hash according to EIP-191
        bytes32 prefixedHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            messageHash
        ));
        
        // Track signers to prevent duplicate signatures
        address[] memory signers = new address[](signatures.length);
        uint256 validSignatureCount = 0;
        
        // Validate each signature
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = prefixedHash.recover(signatures[i]);
            
            // Check if signer is a guardian and not a duplicate
            if (guardianCouncil[signer]) {
                // Check for duplicates
                 bool isDuplicate = false;
                for (uint256 j = 0; j < validSignatureCount; j++) {
                    if (signers[j] == signer) {
                        isDuplicate = true;
                        break;
                    }
                }
                
                // Count valid, non-duplicate signatures
                if (!isDuplicate) {
                    signers[validSignatureCount] = signer;
                    validSignatureCount++;
                }
            }
        }
        
        // Return true if we have enough valid signatures
        return validSignatureCount >= GUARDIAN_QUORUM;
    }
    
    /**
     * @notice Execute an operation with guardian override
     * @param operation Type of operation
     * @param target Target contract address
     * @param data Call data for the operation
     * @param signatures Array of guardian signatures
     * @param timestamp Timestamp when signatures were collected
     */
    function guardianOverride(
        bytes4 operation,
        address target,
        bytes calldata data,
        bytes[] calldata signatures,
        uint256 timestamp
    ) external nonReentrant {
        // Create operation hash to track execution
        bytes32 operationHash = keccak256(abi.encodePacked(
            operation,
            target,
            data,
            currentNonce
        ));
        
        // Ensure operation hasn't been executed already
        if (usedOperationHashes[operationHash]) revert OperationAlreadyExecuted();
        
        // Validate signatures
        if (!validateGuardianSignatures(operation, target, data, signatures, timestamp)) {
            revert InvalidSignatures();
        }
        
        // Check if timestamp is expired
        if (block.timestamp > timestamp + signatureTimeout) revert SignatureTimedOut();
        
        // Mark operation as executed
        usedOperationHashes[operationHash] = true;
        
        // Execute the call
        (bool success, ) = target.call(data);
        
        if (!success) revert EmergencyActionFailed();
        
        // Increment nonce to prevent replay
        currentNonce++;
        
        emit GuardianOverride(operation, target, data);
        emit NonceIncremented(currentNonce);
    }
    
    /**
     * @notice Execute emergency pause on all registered targets
     * @param signatures Array of guardian signatures
     * @param timestamp Timestamp when signatures were collected
     */
    function executeEmergencyPause(
        bytes[] calldata signatures,
        uint256 timestamp
    ) external nonReentrant {
        address[] storage targets = emergencyTargets[EMERGENCY_PAUSE];
        if (targets.length == 0) revert EmergencyTargetNotFound();
        
        // Prepare the pause function call
        bytes memory pauseCall = abi.encodeWithSignature("pause()");
        
        // For each target, validate signatures and execute pause
        for (uint256 i = 0; i < targets.length; i++) {
            address target = targets[i];
            
            // Create unique operation hash
            bytes32 operationHash = keccak256(abi.encodePacked(
                EMERGENCY_PAUSE,
                target,
                pauseCall,
                currentNonce
            ));
            
            // Skip if already executed
            if (usedOperationHashes[operationHash]) continue;
            
            // Validate signatures
            if (!validateGuardianSignatures(EMERGENCY_PAUSE, target, pauseCall, signatures, timestamp)) {
                emit EmergencyActionAttempt(EMERGENCY_PAUSE, false);
                continue;
            }
            
            // Mark operation as executed
            usedOperationHashes[operationHash] = true;
            
            // Execute the pause call
            (bool success, ) = target.call(pauseCall);
            
            emit EmergencyActionAttempt(EMERGENCY_PAUSE, success);
        }
        
        // Increment nonce to prevent replay
        currentNonce++;
        emit NonceIncremented(currentNonce);
    }
    
    /**
     * @notice Execute emergency unpause on all registered targets
     * @param signatures Array of guardian signatures
     * @param timestamp Timestamp when signatures were collected
     */
    function executeEmergencyUnpause(
        bytes[] calldata signatures,
        uint256 timestamp
    ) external nonReentrant {
        address[] storage targets = emergencyTargets[EMERGENCY_UNPAUSE];
        if (targets.length == 0) revert EmergencyTargetNotFound();
        
        // Prepare the unpause function call
        bytes memory unpauseCall = abi.encodeWithSignature("unpause()");
        
        // For each target, validate signatures and execute unpause
        for (uint256 i = 0; i < targets.length; i++) {
            address target = targets[i];
            
            // Create unique operation hash
            bytes32 operationHash = keccak256(abi.encodePacked(
                EMERGENCY_UNPAUSE,
                target,
                unpauseCall,
                currentNonce
            ));
            
            // Skip if already executed
            if (usedOperationHashes[operationHash]) continue;
            
            // Validate signatures
            if (!validateGuardianSignatures(EMERGENCY_UNPAUSE, target, unpauseCall, signatures, timestamp)) {
                emit EmergencyActionAttempt(EMERGENCY_UNPAUSE, false);
                continue;
            }
            
            // Mark operation as executed
            usedOperationHashes[operationHash] = true;
            
            // Execute the unpause call
            (bool success, ) = target.call(unpauseCall);
            
            emit EmergencyActionAttempt(EMERGENCY_UNPAUSE, success);
        }
        
        // Increment nonce to prevent replay
        currentNonce++;
        emit NonceIncremented(currentNonce);
    }
    
    /**
     * @notice Execute validator removal
     * @param validator Address of validator to remove
     * @param signatures Array of guardian signatures
     * @param timestamp Timestamp when signatures were collected
     */
    function executeRemoveValidator(
        address validator,
        bytes[] calldata signatures,
        uint256 timestamp
    ) external nonReentrant {
        address[] storage targets = emergencyTargets[REMOVE_VALIDATOR];
        if (targets.length == 0) revert EmergencyTargetNotFound();
        
        // Prepare the removeValidator function call
        bytes memory removeCall = abi.encodeWithSignature("removeValidator(address)", validator);
        
        // Execute for all registered validator manager contracts
        for (uint256 i = 0; i < targets.length; i++) {
            address target = targets[i];
            
            // Create unique operation hash
            bytes32 operationHash = keccak256(abi.encodePacked(
                REMOVE_VALIDATOR,
                target,
                removeCall,
                currentNonce
            ));
            
            // Skip if already executed
            if (usedOperationHashes[operationHash]) continue;
            
            // Validate signatures
            if (!validateGuardianSignatures(REMOVE_VALIDATOR, target, removeCall, signatures, timestamp)) {
                emit EmergencyActionAttempt(REMOVE_VALIDATOR, false);
                continue;
            }
            
            // Mark operation as executed
            usedOperationHashes[operationHash] = true;
            
            // Execute the remove call
            (bool success, ) = target.call(removeCall);
            
            emit EmergencyActionAttempt(REMOVE_VALIDATOR, success);
        }
        
        // Increment nonce to prevent replay
        currentNonce++;
        emit NonceIncremented(currentNonce);
    }
    
    // -------------------------------------------
    //  View Functions
    // -------------------------------------------
    
    /**
     * @notice Get list of all guardians
     * @return List of guardian addresses
     */
    function getAllGuardians() external view returns (address[] memory) {
        return guardianList;
    }
    
    /**
     * @notice Get count of guardians
     * @return Number of guardians
     */
    function getGuardianCount() external view returns (uint256) {
        return guardianList.length;
    }
    
    /**
     * @notice Check if guardian management is on cooldown
     * @return True if cooldown is active
     */
    function isGuardianUpdateOnCooldown() external view returns (bool) {
        return block.timestamp < lastGuardianUpdate + guardianUpdateCooldown;
    }
    
    /**
     * @notice Get emergency targets for a specific operation type
     * @param operationType Type of operation
     * @return Array of target addresses
     */
    function getEmergencyTargets(bytes4 operationType) external view returns (address[] memory) {
        return emergencyTargets[operationType];
    }
    
    /**
     * @notice Check if an operation has been executed
     * @param operation Type of operation
     * @param target Target contract address
     * @param data Call data for the operation
     * @return True if operation has been executed
     */
    function isOperationExecuted(
        bytes4 operation,
        address target,
        bytes calldata data
    ) external view returns (bool) {
        bytes32 operationHash = keccak256(abi.encodePacked(
            operation,
            target,
            data,
            currentNonce
        ));
        
        return usedOperationHashes[operationHash];
    }
}
