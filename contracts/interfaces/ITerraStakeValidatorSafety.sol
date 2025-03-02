// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title ITerraStakeValidatorSafety
 * @author TerraStake Protocol Team
 * @notice Interface for the validator management and safety module for the TerraStake Protocol
 */
interface ITerraStakeValidatorSafety {
    // -------------------------------------------
    // 🔹 Events
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
    
    // -------------------------------------------
    // 🔹 Errors
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
    
    // -------------------------------------------
    // 🔹 View Functions
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
    
    function isHighRiskValidator(address validator) external view returns (bool);
    function getActiveValidators() external view returns (address[] memory);
    function getValidatorInactivityDuration(address validator) external view returns (uint256);
    function isValidatorConfigCooldownActive() external view returns (bool);
    function getGovernanceTier(uint256 tokenAmount) external view returns (uint8);
    function isEmergencyCooldownActive() external view returns (bool);
    function getHighRiskValidatorCount() external view returns (uint256);
    function getInactiveValidators() external view returns (address[] memory);
    
    // -------------------------------------------
    // 🔹 State-Changing Functions
    // -------------------------------------------
    
    function initialize(address _initialAdmin) external;
    
    function addValidator(address validator) external;
    function removeValidator(address validator) external;
    function updateValidatorThreshold(uint256 newThreshold) external;
    function updateValidatorQuorum(uint256 newQuorum) external;
    function updateGovernanceTier(uint8 tierId, uint256 newThreshold) external;
    function updateValidatorCooldown(uint256 newCooldown) external;
    
    function updateRiskScore(address validator, uint256 newScore) external;
    function updateRiskScoreThreshold(uint256 newThreshold) external;
    function recordValidatorActivity(address validator) external;
    
    function activateEmergencyMode() external;
    function deactivateEmergencyMode() external;
    function updateEmergencyCooldown(uint256 newCooldown) external;
    function emergencyReduceValidatorThreshold(uint256 newThreshold) external;
}
