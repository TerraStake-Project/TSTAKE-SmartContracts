// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

/**
 * @title ITerraStakeValidatorSafety
 * @author TerraStake Protocol Team
 * @notice Interface for the validator management and safety module for the TerraStake Protocol
 */
interface ITerraStakeValidatorSafety {
    // -------------------------------------------
    //  Events
    // -------------------------------------------
    
    event ValidatorAdded(address indexed validator);
    event ValidatorRemoved(address indexed validator);
    event ValidatorThresholdUpdated(uint256 newThreshold);
    event ValidatorQuorumUpdated(uint256 newQuorum);
    event GovernanceTierUpdated(uint8 tierId, uint256 newThreshold);
    event ValidatorCooldownUpdated(uint256 newCooldown);
    event RiskScoreUpdated(address indexed validator, uint256 newScore);
    event RiskScoreThresholdUpdated(uint256 newThreshold);
    event EmergencyModeActivated(address activator);
    event EmergencyModeDeactivated(address deactivator);
    event EmergencyCooldownUpdated(uint256 newCooldown);
    event EmergencyValidatorThresholdReduction(uint256 oldThreshold, uint256 newThreshold);
    event ValidatorActivityRecorded(address indexed validator, address recorder);
    event ValidatorInactivityThresholdUpdated(uint256 newThreshold);
    event OperationScheduled(bytes32 indexed operationId, uint256 executionTime);
    event OperationExecuted(bytes32 indexed operationId);
    event OperationCancelled(bytes32 indexed operationId);
    event ValidatorSuspended(address indexed validator, uint256 riskScore);
    event AutoSuspendModeUpdated(bool enabled);
    event TimelockPeriodUpdated(uint256 newPeriod);
    
    // -------------------------------------------
    //  Errors
    // -------------------------------------------
    
    error Unauthorized();
    error InvalidParameters();
    error CooldownActive();
    error ValidatorNotActive();
    error ValidatorAlreadyActive();
    error EmergencyModeActive();
    error EmergencyModeNotActive();
    error EmergencyCooldownActive();
    error ThresholdTooLow();
    error QuorumTooHigh();
    error ExceedsActiveValidatorCount();
    error ZeroAddressNotAllowed();
    error OperationNotScheduled();
    error TimelockNotExpired();
    error InsufficientActiveValidators();
    
    // -------------------------------------------
    //  View Functions
    // -------------------------------------------
    
    function GOVERNANCE_ROLE() external view returns (bytes32);
    function UPGRADER_ROLE() external view returns (bytes32);
    function GUARDIAN_ROLE() external view returns (bytes32);
    function VALIDATOR_ROLE() external view returns (bytes32);
    
    function validatorThreshold() external view returns (uint256);
    function validatorQuorum() external view returns (uint256);
    function validatorCooldownPeriod() external view returns (uint256);
    function lastValidatorConfigUpdate() external view returns (uint256);
    
    function governanceTier1Threshold() external view returns (uint256);
    function governanceTier2Threshold() external view returns (uint256);
    function governanceTier3Threshold() external view returns (uint256);
    
    function riskScoreThreshold() external view returns (uint256);
    function validatorRiskScores(address validator) external view returns (uint256);
    function lastValidatorActivity(address validator) external view returns (uint256);
    
    function isActiveValidator(address validator) external view returns (bool);
    function validatorSet(uint256 index) external view returns (address);
    function activeValidatorCount() external view returns (uint256);
    
    function emergencyMode() external view returns (bool);
    function emergencyModeActivationTime() external view returns (uint256);
    function emergencyModeCooldown() external view returns (uint256);
    function validatorInactivityThreshold() external view returns (uint256);
    function timelockPeriod() external view returns (uint256);
    function pendingOperations(bytes32 operationId) external view returns (uint256);
    function autoSuspendHighRiskValidators() external view returns (bool);
    
    function isHighRiskValidator(address validator) external view returns (bool);
    function getActiveValidators() external view returns (address[] memory);
    function getValidatorInactivityDuration(address validator) external view returns (uint256);
    function isValidatorConfigCooldownActive() external view returns (bool);
    function getGovernanceTier(uint256 tokenAmount) external view returns (uint8);
    function isEmergencyCooldownActive() external view returns (bool);
    function getHighRiskValidatorCount() external view returns (uint256);
    function getInactiveValidators() external view returns (address[] memory);
    function getOperationStatus(bytes32 operationId) external view returns (bool pending, uint256 executionTime);
    function hasSufficientValidators() external view returns (bool);
    function getSystemStatus() external view returns (
        bool isEmergency,
        uint256 validatorCount,
        uint256 minValidators,
        uint256 highRiskCount
    );
    
    // -------------------------------------------
    //  State-Changing Functions
    // -------------------------------------------
    
    function initialize(address _initialAdmin) external;
    
    function scheduleAddValidator(address validator) external;
    function addValidator(address validator) external;
    function scheduleRemoveValidator(address validator) external;
    function removeValidator(address validator) external;
    function scheduleUpdateValidatorThreshold(uint256 newThreshold) external;
    function updateValidatorThreshold(uint256 newThreshold) external;
    function scheduleUpdateValidatorQuorum(uint256 newQuorum) external;
    function updateValidatorQuorum(uint256 newQuorum) external;
    function updateGovernanceTier(uint8 tierId, uint256 newThreshold) external;
    function updateValidatorCooldown(uint256 newCooldown) external;
    function updateValidatorInactivityThreshold(uint256 newThreshold) external;
    function setAutoSuspendHighRiskValidators(bool enabled) external;
    
    function updateRiskScore(address validator, uint256 newScore) external;
    function updateRiskScoreThreshold(uint256 newThreshold) external;
    function recordValidatorActivity(address validator) external;
    
    function activateEmergencyMode() external;
    function deactivateEmergencyMode() external;
    function updateEmergencyCooldown(uint256 newCooldown) external;
    function emergencyReduceValidatorThreshold(uint256 newThreshold) external;
    
    function cancelOperation(bytes32 operationId) external;
    function updateTimelockPeriod(uint256 newPeriod) external;
}
