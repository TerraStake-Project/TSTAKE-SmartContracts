// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "../interfaces/ITerraStakeValidatorSafety.sol";

/**
 * @title TerraStakeValidatorSafety
 * @author TerraStake Protocol Team
 * @notice Validator management and safety module for the TerraStake Protocol
 * handling validator thresholds, governance tiers, and emergency safety procedures
 */
contract TerraStakeValidatorSafety is 
    Initializable, 
    AccessControlEnumerableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable,
    ITerraStakeValidatorSafety
{
    // -------------------------------------------
    //  Constants
    // -------------------------------------------
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    
    // -------------------------------------------
    //  State Variables
    // -------------------------------------------
    
    // Validator configuration
    uint256 public validatorThreshold;
    uint256 public validatorQuorum;
    uint256 public validatorCooldownPeriod;
    uint256 public lastValidatorConfigUpdate;
        
    // Risk parameters
    uint256 public riskScoreThreshold;
    mapping(address => uint256) public validatorRiskScores;
    mapping(address => uint256) public lastValidatorActivity;
    
    // Validator set tracking
    mapping(address => bool) public isActiveValidator;
    address[] public validatorSet;
    uint256 public activeValidatorCount;
    mapping(address => uint256) private validatorIndices; // Track index in validatorSet
    
    // Emergency parameters
    bool public emergencyMode;
    uint256 public emergencyModeActivationTime;
    uint256 public emergencyModeCooldown;
    
    // Inactivity threshold for validators
    uint256 public validatorInactivityThreshold;
    
    // Timelock for critical operations
    uint256 public timelockPeriod;
    mapping(bytes32 => uint256) public pendingOperations;
    
    // Automatic risk handling
    bool public autoSuspendHighRiskValidators;
    
    // -------------------------------------------
    //  Modifiers
    // -------------------------------------------
    
    /**
     * @notice Checks if emergency mode is NOT active
     */
    modifier notInEmergencyMode() {
        if (emergencyMode) revert EmergencyModeActive();
        _;
    }
    
    /**
     * @notice Checks if emergency mode IS active
     */
    modifier onlyInEmergencyMode() {
        if (!emergencyMode) revert EmergencyModeNotActive();
        _;
    }
    
    /**
     * @notice Checks if an operation has passed its timelock period
     * @param operationId The hash identifying the operation
     */
    modifier timelockElapsed(bytes32 operationId) {
        if (pendingOperations[operationId] == 0) revert OperationNotScheduled();
        if (block.timestamp < pendingOperations[operationId]) revert TimelockNotExpired();
        _;
        
        // Clean up the operation after execution
        delete pendingOperations[operationId];
        emit OperationExecuted(operationId);
    }
    
    /**
     * @notice Ensures there are sufficient active validators for safe operation
     */
    modifier sufficientValidators() {
        if (activeValidatorCount < validatorThreshold) revert InsufficientActiveValidators();
        _;
    }
    
    // -------------------------------------------
    //  Initializer & Upgrade Control
    // -------------------------------------------
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @notice Initialize the validator safety module
     * @param _initialAdmin Initial admin address
     */
    function initialize(address _initialAdmin) external initializer {
        if (_initialAdmin == address(0)) revert ZeroAddressNotAllowed();
        
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        _grantRole(UPGRADER_ROLE, _initialAdmin);
        _grantRole(GOVERNANCE_ROLE, _initialAdmin);
        _grantRole(GUARDIAN_ROLE, _initialAdmin);
        
        // Set default values
        validatorThreshold = 5; // Require at least 5 validators
        validatorQuorum = 3; // Require at least 3 validators for consensus
        validatorCooldownPeriod = 7 days;
        riskScoreThreshold = 80; // Risk score from 0-100, 80+ is high risk
        validatorInactivityThreshold = 7 days; // Default inactivity threshold
        timelockPeriod = 2 days; // Default timelock for critical operations
        autoSuspendHighRiskValidators = true; // Auto-suspend high risk validators by default
                
        // Set emergency parameters
        emergencyMode = false;
        emergencyModeCooldown = 30 days;
    }
    
    /**
     * @notice Authorize contract upgrades, restricted to the upgrader role
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
    
    // -------------------------------------------
    //  Timelock Management
    // -------------------------------------------
    
    /**
     * @notice Schedule an operation with a timelock
     * @param operationId Unique identifier for the operation
     */
    function scheduleOperation(bytes32 operationId) internal {
        pendingOperations[operationId] = block.timestamp + timelockPeriod;
        emit OperationScheduled(operationId, pendingOperations[operationId]);
    }
    
    /**
     * @notice Cancel a scheduled operation
     * @param operationId Unique identifier for the operation
     */
    function cancelOperation(bytes32 operationId) external onlyRole(GOVERNANCE_ROLE) {
        if (pendingOperations[operationId] == 0) revert OperationNotScheduled();
        delete pendingOperations[operationId];
        emit OperationCancelled(operationId);
    }
    
    /**
     * @notice Update the timelock period
     * @param newPeriod New timelock period in seconds
     */
    function updateTimelockPeriod(uint256 newPeriod) external onlyRole(GOVERNANCE_ROLE) notInEmergencyMode {
        if (newPeriod < 1 hours) revert InvalidParameters(); // Minimum 1 hour
        timelockPeriod = newPeriod;
        emit TimelockPeriodUpdated(newPeriod);
    }
    
    // -------------------------------------------
    //  Validator Management Functions
    // -------------------------------------------
    
    /**
     * @notice Schedule addition of a new validator to the network
     * @param validator Address of the new validator
     */
    function scheduleAddValidator(address validator) external onlyRole(GOVERNANCE_ROLE) notInEmergencyMode {
        if (validator == address(0)) revert ZeroAddressNotAllowed();
        if (isActiveValidator[validator]) revert ValidatorAlreadyActive();
        
        bytes32 operationId = keccak256(abi.encode("ADD_VALIDATOR", validator, block.timestamp));
        scheduleOperation(operationId);
    }
    
    /**
     * @notice Add a new validator to the network after timelock period
     * @param validator Address of the new validator
     */
    function addValidator(address validator) external 
        nonReentrant 
        onlyRole(GOVERNANCE_ROLE) 
        notInEmergencyMode 
        timelockElapsed(keccak256(abi.encode("ADD_VALIDATOR", validator, block.timestamp - timelockPeriod)))
    {
        if (validator == address(0)) revert ZeroAddressNotAllowed();
        if (isActiveValidator[validator]) revert ValidatorAlreadyActive();
        
        // Add to active validators
        isActiveValidator[validator] = true;
        validatorIndices[validator] = validatorSet.length;
        validatorSet.push(validator);
        activeValidatorCount++;
        
        // Grant validator role
        _grantRole(VALIDATOR_ROLE, validator);
        
        // Initialize tracking
        lastValidatorActivity[validator] = block.timestamp;
        validatorRiskScores[validator] = 0; // Start with zero risk
        
        emit ValidatorAdded(validator);
    }
    
    /**
     * @notice Schedule removal of a validator from the network
     * @param validator Address of the validator to remove
     */
    function scheduleRemoveValidator(address validator) external onlyRole(GOVERNANCE_ROLE) {
        if (!isActiveValidator[validator]) revert ValidatorNotActive();
        
        // Check if we'll still have enough validators after removal
        if (activeValidatorCount <= validatorThreshold) revert ThresholdTooLow();
        
        bytes32 operationId = keccak256(abi.encode("REMOVE_VALIDATOR", validator, block.timestamp));
        scheduleOperation(operationId);
    }
    
    /**
     * @notice Remove a validator from the network after timelock period
     * @param validator Address of the validator to remove
     */
    function removeValidator(address validator) external 
        nonReentrant 
        onlyRole(GOVERNANCE_ROLE)
        timelockElapsed(keccak256(abi.encode("REMOVE_VALIDATOR", validator, block.timestamp - timelockPeriod)))
    {
        if (!isActiveValidator[validator]) revert ValidatorNotActive();
        
        // Check if we'll still have enough validators after removal
        if (activeValidatorCount <= validatorThreshold) revert ThresholdTooLow();
        
        // Remove from active validators
        isActiveValidator[validator] = false;
        activeValidatorCount--;
        
        // Remove validator role
        _revokeRole(VALIDATOR_ROLE, validator);
        
        // Properly remove validator from array by swapping with last element and popping
        uint256 indexToRemove = validatorIndices[validator];
        uint256 lastIndex = validatorSet.length - 1;
        
        if (indexToRemove != lastIndex) {
            address lastValidator = validatorSet[lastIndex];
            validatorSet[indexToRemove] = lastValidator;
            validatorIndices[lastValidator] = indexToRemove;
        }
        
        validatorSet.pop();
        delete validatorIndices[validator];
        
        emit ValidatorRemoved(validator);
    }
    
    /**
     * @notice Schedule validator threshold update
     * @param newThreshold New minimum number of validators required
     */
    function scheduleUpdateValidatorThreshold(uint256 newThreshold) external onlyRole(GOVERNANCE_ROLE) notInEmergencyMode {
        // Ensure cooldown has passed
        if (block.timestamp < lastValidatorConfigUpdate + validatorCooldownPeriod) {
            revert CooldownActive();
        }
        
        // Threshold must be at least 3 for reasonable security
        if (newThreshold < 3) revert ThresholdTooLow();
        
        // Threshold must be lower than or equal to current active validator count
        if (newThreshold > activeValidatorCount) revert InvalidParameters();
        
        bytes32 operationId = keccak256(abi.encode("UPDATE_VALIDATOR_THRESHOLD", newThreshold, block.timestamp));
        scheduleOperation(operationId);
    }
    
    /**
     * @notice Update validator threshold after timelock period
     * @param newThreshold New minimum number of validators required
     */
    function updateValidatorThreshold(uint256 newThreshold) external 
        nonReentrant 
        onlyRole(GOVERNANCE_ROLE) 
        notInEmergencyMode
        timelockElapsed(keccak256(abi.encode("UPDATE_VALIDATOR_THRESHOLD", newThreshold, block.timestamp - timelockPeriod)))
        sufficientValidators
    {
        // Threshold must be at least 3 for reasonable security
        if (newThreshold < 3) revert ThresholdTooLow();
        
        // Threshold must be lower than or equal to current active validator count
        if (newThreshold > activeValidatorCount) revert InvalidParameters();
        
        validatorThreshold = newThreshold;
        lastValidatorConfigUpdate = block.timestamp;
        
        emit ValidatorThresholdUpdated(newThreshold);
    }
    
    /**
     * @notice Schedule validator quorum update
     * @param newQuorum New quorum threshold for validator consensus
     */
    function scheduleUpdateValidatorQuorum(uint256 newQuorum) external onlyRole(GOVERNANCE_ROLE) notInEmergencyMode {
        // Ensure cooldown has passed
        if (block.timestamp < lastValidatorConfigUpdate + validatorCooldownPeriod) {
            revert CooldownActive();
        }
        
        // Quorum must be at least 2
        if (newQuorum < 2) revert ThresholdTooLow();
        
        // Quorum must not exceed validator threshold
        if (newQuorum > validatorThreshold) revert QuorumTooHigh();
        
        bytes32 operationId = keccak256(abi.encode("UPDATE_VALIDATOR_QUORUM", newQuorum, block.timestamp));
        scheduleOperation(operationId);
    }
    
    /**
     * @notice Update validator quorum after timelock period
     * @param newQuorum New quorum threshold for validator consensus
     */
    function updateValidatorQuorum(uint256 newQuorum) external 
        nonReentrant 
        onlyRole(GOVERNANCE_ROLE) 
        notInEmergencyMode
        timelockElapsed(keccak256(abi.encode("UPDATE_VALIDATOR_QUORUM", newQuorum, block.timestamp - timelockPeriod)))
        sufficientValidators
    {
        // Quorum must be at least 2
        if (newQuorum < 2) revert ThresholdTooLow();
        
        // Quorum must not exceed validator threshold
        if (newQuorum > validatorThreshold) revert QuorumTooHigh();
        
        validatorQuorum = newQuorum;
        lastValidatorConfigUpdate = block.timestamp;
        
        emit ValidatorQuorumUpdated(newQuorum);
    }
    
    /**
     * @notice Update validator cooldown period
     * @param newCooldown New cooldown period in seconds
     */
    function updateValidatorCooldown(uint256 newCooldown) external 
        nonReentrant 
        onlyRole(GOVERNANCE_ROLE)
        notInEmergencyMode 
    {
        // Ensure cooldown is reasonable (at least 1 day, at most 30 days)
        if (newCooldown < 1 days || newCooldown > 30 days) revert InvalidParameters();
        
        validatorCooldownPeriod = newCooldown;
        
        emit ValidatorCooldownUpdated(newCooldown);
    }
    
    /**
     * @notice Update validator inactivity threshold
     * @param newThreshold New inactivity threshold in seconds
     */
    function updateValidatorInactivityThreshold(uint256 newThreshold) external 
        nonReentrant 
        onlyRole(GOVERNANCE_ROLE)
        notInEmergencyMode 
    {
        // Ensure threshold is reasonable (at least 1 day)
        if (newThreshold < 1 days) revert InvalidParameters();
        
        validatorInactivityThreshold = newThreshold;
        
        emit ValidatorInactivityThresholdUpdated(newThreshold);
    }
    
    /**
     * @notice Toggle automatic suspension of high risk validators
     * @param enabled True to enable automatic suspension, false to disable
     */
    function setAutoSuspendHighRiskValidators(bool enabled) external 
        nonReentrant 
        onlyRole(GOVERNANCE_ROLE)
        notInEmergencyMode 
    {
        autoSuspendHighRiskValidators = enabled;
        emit AutoSuspendModeUpdated(enabled);
    }
    
    // -------------------------------------------
    //  Risk Management Functions
    // -------------------------------------------
    
    /**
     * @notice Update risk score for a validator
     * @param validator Validator address
     * @param newScore New risk score (0-100)
     */
    function updateRiskScore(address validator, uint256 newScore) external 
        nonReentrant 
        onlyRole(GOVERNANCE_ROLE)
        sufficientValidators 
    {
        if (!isActiveValidator[validator]) revert ValidatorNotActive();
        if (newScore > 100) revert InvalidParameters(); // Score must be 0-100
        
        validatorRiskScores[validator] = newScore;
        
        // If score exceeds threshold and auto-suspend is enabled, suspend the validator
        if (newScore >= riskScoreThreshold && autoSuspendHighRiskValidators) {
            // Make sure we maintain sufficient validators after suspension
            if (activeValidatorCount <= validatorThreshold) {
                // Can't suspend - would breach threshold
                emit ValidatorSuspended(validator, newScore); // Log attempt but don't suspend
            } else {
                // Remove from active validators but keep in the system
                isActiveValidator[validator] = false;
                activeValidatorCount--;
                
                emit ValidatorSuspended(validator, newScore);
            }
        }
        
        emit RiskScoreUpdated(validator, newScore);
    }
    
    /**
     * @notice Update the risk score threshold
     * @param newThreshold New risk score threshold (0-100)
     */
    function updateRiskScoreThreshold(uint256 newThreshold) external 
        nonReentrant 
        onlyRole(GOVERNANCE_ROLE)
        notInEmergencyMode 
    {
        if (newThreshold > 100) revert InvalidParameters(); // Threshold must be 0-100
        
        riskScoreThreshold = newThreshold;
        
        emit RiskScoreThresholdUpdated(newThreshold);
    }
    
    /**
     * @notice Records validator activity to track engagement
     * @param validator Validator address
     */
    function recordValidatorActivity(address validator) external nonReentrant {
        // Only validators can record their own activity or governance/guardian role can record for any validator
        bool isAuthorized = (msg.sender == validator && 
                            hasRole(VALIDATOR_ROLE, validator)) || 
                            hasRole(GOVERNANCE_ROLE, msg.sender) || 
                            hasRole(GUARDIAN_ROLE, msg.sender);
        
        if (!isAuthorized) revert Unauthorized();
        if (!isActiveValidator[validator]) revert ValidatorNotActive();
        
        lastValidatorActivity[validator] = block.timestamp;
        
        emit ValidatorActivityRecorded(validator, msg.sender);
    }
    
    // -------------------------------------------
    //  Emergency Functions
    // -------------------------------------------
    
    /**
     * @notice Activate emergency mode
     * @dev Can only be called by guardian role
     */
    function activateEmergencyMode() external 
        nonReentrant 
        onlyRole(GUARDIAN_ROLE) 
        notInEmergencyMode 
    {
        // Check if emergency cooldown has passed since last deactivation
        if (emergencyModeActivationTime > 0) {
            if (block.timestamp < emergencyModeActivationTime + emergencyModeCooldown) {
                revert EmergencyCooldownActive();
            }
        }
        
        emergencyMode = true;
        emergencyModeActivationTime = block.timestamp;
        
        emit EmergencyModeActivated(msg.sender);
    }
    
    /**
     * @notice Deactivate emergency mode
     * @dev Can only be called by governance role
     */
    function deactivateEmergencyMode() external 
        nonReentrant 
        onlyRole(GOVERNANCE_ROLE) 
        onlyInEmergencyMode 
    {
        emergencyMode = false;
        
        emit EmergencyModeDeactivated(msg.sender);
    }
    
    /**
     * @notice Update emergency mode cooldown
     * @param newCooldown New cooldown period in seconds
     */
    function updateEmergencyCooldown(uint256 newCooldown) external 
        nonReentrant 
        onlyRole(GOVERNANCE_ROLE)
        notInEmergencyMode 
    {
        // Ensure cooldown is reasonable (at least 1 day)
        if (newCooldown < 1 days) revert InvalidParameters();
        
        emergencyModeCooldown = newCooldown;
        
        emit EmergencyCooldownUpdated(newCooldown);
    }
    
    /**
     * @notice Emergency function to reduce validator threshold
     * @param newThreshold New validator threshold
     * @dev This is needed in case too many validators go offline
     */
    function emergencyReduceValidatorThreshold(uint256 newThreshold) 
        external 
        nonReentrant
        onlyRole(GUARDIAN_ROLE) 
        onlyInEmergencyMode 
    {
        // Must maintain minimum security with at least 2 validators
        if (newThreshold < 2) revert ThresholdTooLow();
        
        // Threshold must be lower than or equal to current active validator count
        if (newThreshold > activeValidatorCount) revert ExceedsActiveValidatorCount();
        
        // Record the change
        uint256 oldThreshold = validatorThreshold;
        validatorThreshold = newThreshold;
        
        emit EmergencyValidatorThresholdReduction(oldThreshold, newThreshold);
    }
    
    // -------------------------------------------
    //  View Functions
    // -------------------------------------------
    
    /**
     * @notice Check if a validator has high risk
     * @param validator Validator address
     * @return True if validator has high risk score
     */
    function isHighRiskValidator(address validator) external view returns (bool) {
        if (!isActiveValidator[validator]) return false;
        return validatorRiskScores[validator] >= riskScoreThreshold;
    }
    
    /**
     * @notice Get a list of all active validator addresses
     * @return Array of active validator addresses
     */
    function getActiveValidators() external view returns (address[] memory) {
        address[] memory activeValidators = new address[](activeValidatorCount);
        
        uint256 counter = 0;
        for (uint256 i = 0; i < validatorSet.length && counter < activeValidatorCount; i++) {
            address validator = validatorSet[i];
            if (isActiveValidator[validator]) {
                activeValidators[counter] = validator;
                counter++;
            }
        }
        
        return activeValidators;
    }
    
    /**
     * @notice Get validator inactivity duration
     * @param validator Validator address
     * @return Time in seconds since last activity
     */
    function getValidatorInactivityDuration(address validator) external view returns (uint256) {
        if (!isActiveValidator[validator]) revert ValidatorNotActive();
        return block.timestamp - lastValidatorActivity[validator];
    }
    
    /**
     * @notice Check if the validator configuration is currently in cooldown
     * @return True if cooldown is active
     */
    function isValidatorConfigCooldownActive() external view returns (bool) {
        return block.timestamp < lastValidatorConfigUpdate + validatorCooldownPeriod;
    }
    
    /**
     * @notice Check if emergency mode cooldown is active
     * @return True if emergency cooldown is active
     */
    function isEmergencyCooldownActive() external view returns (bool) {
        if (emergencyModeActivationTime == 0) return false;
        return block.timestamp < emergencyModeActivationTime + emergencyModeCooldown;
    }
    
    /**
     * @notice Get count of high risk validators
     * @return Count of validators with risk scores above threshold
     */
    function getHighRiskValidatorCount() external view returns (uint256) {
        uint256 count = 0;
        
        // Single pass through validator set checking both activity and risk
        for (uint256 i = 0; i < validatorSet.length; i++) {
            address validator = validatorSet[i];
            if (isActiveValidator[validator] && validatorRiskScores[validator] >= riskScoreThreshold) {
                count++;
            }
        }
        
        return count;
    }
    
    /**
     * @notice Get inactive validators (no activity in configured threshold period)
     * @return Array of inactive validator addresses
     */
    function getInactiveValidators() external view returns (address[] memory) {
        uint256 inactiveCount = 0;
        
        // First, count inactive validators in a single pass
        for (uint256 i = 0; i < validatorSet.length; i++) {
            address validator = validatorSet[i];
            if (isActiveValidator[validator]) {
                uint256 inactiveDuration = block.timestamp - lastValidatorActivity[validator];
                if (inactiveDuration > validatorInactivityThreshold) {
                    inactiveCount++;
                }
            }
        }
        
        // Only allocate the array once we know the exact size
        address[] memory result = new address[](inactiveCount);
        
        // Fill the array in a second pass if we have any inactive validators
        if (inactiveCount > 0) {
            uint256 resultIndex = 0;
            for (uint256 i = 0; i < validatorSet.length; i++) {
                address validator = validatorSet[i];
                if (isActiveValidator[validator]) {
                    uint256 inactiveDuration = block.timestamp - lastValidatorActivity[validator];
                    if (inactiveDuration > validatorInactivityThreshold) {
                        result[resultIndex] = validator;
                        resultIndex++;
                    }
                }
            }
        }
        
        return result;
    }
    
    /**
     * @notice Check if a timelock operation is pending and when it can be executed
     * @param operationId Unique identifier for the operation
     * @return pending Whether the operation is pending
     * @return executionTime When the operation can be executed (0 if not pending)
     */
    function getOperationStatus(bytes32 operationId) external view returns (bool pending, uint256 executionTime) {
        executionTime = pendingOperations[operationId];
        pending = executionTime > 0;
        return (pending, executionTime);
    }
    
    /**
     * @notice Check if the contract has sufficient active validators
     * @return True if there are enough active validators
     */
    function hasSufficientValidators() external view returns (bool) {
        return activeValidatorCount >= validatorThreshold;
    }
    
    /**
     * @notice Get current system status information
     * @return isEmergency Whether emergency mode is active
     * @return validatorCount Current number of active validators
     * @return minValidators Minimum number of validators required
     * @return highRiskCount Number of high risk validators
     */
    function getSystemStatus() external view returns (
        bool isEmergency,
        uint256 validatorCount,
        uint256 minValidators,
        uint256 highRiskCount
    ) {
        isEmergency = emergencyMode;
        validatorCount = activeValidatorCount;
        minValidators = validatorThreshold;
        
        // Count high risk validators
        highRiskCount = 0;
        for (uint256 i = 0; i < validatorSet.length; i++) {
            address validator = validatorSet[i];
            if (isActiveValidator[validator] && validatorRiskScores[validator] >= riskScoreThreshold) {
                highRiskCount++;
            }
        }
        
        return (isEmergency, validatorCount, minValidators, highRiskCount);
    }
}


