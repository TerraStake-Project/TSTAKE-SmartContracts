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
    UUPSUpgradeable
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
    
    // Governance tiers
    uint256 public governanceTier1Threshold;
    uint256 public governanceTier2Threshold;
    uint256 public governanceTier3Threshold;
    
    // Risk parameters
    uint256 public riskScoreThreshold;
    mapping(address => uint256) public validatorRiskScores;
    mapping(address => uint256) public lastValidatorActivity;
    
    // Validator set tracking
    mapping(address => bool) public isActiveValidator;
    address[] public validatorSet;
    uint256 public activeValidatorCount;
    
    // Emergency parameters
    bool public emergencyMode;
    uint256 public emergencyModeActivationTime;
    uint256 public emergencyModeCooldown;
    
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
        
        // Set governance tier thresholds
        governanceTier1Threshold = 50_000 * 10**18; // 50,000 tokens
        governanceTier2Threshold = 100_000 * 10**18; // 100,000 tokens
        governanceTier3Threshold = 250_000 * 10**18; // 250,000 tokens
        
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
    //  Validator Management Functions
    // -------------------------------------------
    
    /**
     * @notice Add a new validator to the network
     * @param validator Address of the new validator
     */
    function addValidator(address validator) external onlyRole(GOVERNANCE_ROLE) notInEmergencyMode {
        if (validator == address(0)) revert InvalidParameters();
        if (isActiveValidator[validator]) revert ValidatorAlreadyActive();
        
        // Add to active validators
        isActiveValidator[validator] = true;
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
     * @notice Remove a validator from the network
     * @param validator Address of the validator to remove
     */
    function removeValidator(address validator) external onlyRole(GOVERNANCE_ROLE) {
        if (!isActiveValidator[validator]) revert ValidatorNotActive();
        
        // Check if we'll still have enough validators after removal
        if (activeValidatorCount <= validatorThreshold) revert ThresholdTooLow();
        
        // Remove from active validators
        isActiveValidator[validator] = false;
        activeValidatorCount--;
        
        // Remove validator role
        _revokeRole(VALIDATOR_ROLE, validator);
        
        // We don't remove from the array to keep gas costs lower,
        // we just track active status separately
        
        emit ValidatorRemoved(validator);
    }
    
    /**
     * @notice Update validator threshold
     * @param newThreshold New minimum number of validators required
     */
    function updateValidatorThreshold(uint256 newThreshold) external onlyRole(GOVERNANCE_ROLE) notInEmergencyMode {
        // Ensure cooldown has passed
        if (block.timestamp < lastValidatorConfigUpdate + validatorCooldownPeriod) {
            revert CooldownActive();
        }
        
        // Threshold must be at least 3 for reasonable security
        if (newThreshold < 3) revert ThresholdTooLow();
        
        // Threshold must be lower than or equal to current active validator count
        if (newThreshold > activeValidatorCount) revert InvalidParameters();
        
        validatorThreshold = newThreshold;
        lastValidatorConfigUpdate = block.timestamp;
        
        emit ValidatorThresholdUpdated(newThreshold);
    }
    
    /**
     * @notice Update validator quorum
     * @param newQuorum New quorum threshold for validator consensus
     */
    function updateValidatorQuorum(uint256 newQuorum) external onlyRole(GOVERNANCE_ROLE) notInEmergencyMode {
        // Ensure cooldown has passed
        if (block.timestamp < lastValidatorConfigUpdate + validatorCooldownPeriod) {
            revert CooldownActive();
        }
        
        // Quorum must be at least 2
        if (newQuorum < 2) revert ThresholdTooLow();
        
        // Quorum must not exceed validator threshold
        if (newQuorum > validatorThreshold) revert QuorumTooHigh();
        
        validatorQuorum = newQuorum;
        lastValidatorConfigUpdate = block.timestamp;
        
        emit ValidatorQuorumUpdated(newQuorum);
    }
    
    /**
     * @notice Update governance tier thresholds
     * @param tierId Tier ID (1, 2, or 3)
     * @param newThreshold New token threshold for this tier
     */
    function updateGovernanceTier(uint8 tierId, uint256 newThreshold) external onlyRole(GOVERNANCE_ROLE) {
        if (tierId < 1 || tierId > 3) revert InvalidParameters();
        
        if (tierId == 1) {
            governanceTier1Threshold = newThreshold;
        } else if (tierId == 2) {
            // Ensure tier 2 is higher than tier 1
            if (newThreshold <= governanceTier1Threshold) revert InvalidParameters();
            governanceTier2Threshold = newThreshold;
        } else if (tierId == 3) {
            // Ensure tier 3 is higher than tier 2
            if (newThreshold <= governanceTier2Threshold) revert InvalidParameters();
            governanceTier3Threshold = newThreshold;
        }
        
        emit GovernanceTierUpdated(tierId, newThreshold);
    }
    
    /**
     * @notice Update validator cooldown period
     * @param newCooldown New cooldown period in seconds
     */
    function updateValidatorCooldown(uint256 newCooldown) external onlyRole(GOVERNANCE_ROLE) {
        // Ensure cooldown is reasonable (at least 1 day, at most 30 days)
        if (newCooldown < 1 days || newCooldown > 30 days) revert InvalidParameters();
        
        validatorCooldownPeriod = newCooldown;
        
        emit ValidatorCooldownUpdated(newCooldown);
    }
    
    // -------------------------------------------
    //  Risk Management Functions
    // -------------------------------------------
    
    /**
     * @notice Update risk score for a validator
     * @param validator Validator address
     * @param newScore New risk score (0-100)
     */
    function updateRiskScore(address validator, uint256 newScore) external onlyRole(GOVERNANCE_ROLE) {
        if (!isActiveValidator[validator]) revert ValidatorNotActive();
        if (newScore > 100) revert InvalidParameters(); // Score must be 0-100
        
        validatorRiskScores[validator] = newScore;
        
        // If score exceeds threshold, this is high risk
        if (newScore >= riskScoreThreshold) {
            // Consider adding automatic actions for high-risk validators
        }
        
        emit RiskScoreUpdated(validator, newScore);
    }
    
    /**
     * @notice Update the risk score threshold
     * @param newThreshold New risk score threshold (0-100)
     */
    function updateRiskScoreThreshold(uint256 newThreshold) external onlyRole(GOVERNANCE_ROLE) {
        if (newThreshold > 100) revert InvalidParameters(); // Threshold must be 0-100
        
        riskScoreThreshold = newThreshold;
        
        emit RiskScoreThresholdUpdated(newThreshold);
    }
    
    /**
     * @notice Records validator activity to track engagement
     * @param validator Validator address
     */
    function recordValidatorActivity(address validator) external {
        // Only validators can record their own activity
        if (!hasRole(VALIDATOR_ROLE, validator)) revert Unauthorized();
        if (msg.sender != validator) revert Unauthorized();
        
        lastValidatorActivity[validator] = block.timestamp;
    }
    
    // -------------------------------------------
    //  Emergency Functions
    // -------------------------------------------
    
    /**
     * @notice Activate emergency mode
     * @dev Can only be called by guardian role
     */
    function activateEmergencyMode() external onlyRole(GUARDIAN_ROLE) notInEmergencyMode {
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
    function deactivateEmergencyMode() external onlyRole(GOVERNANCE_ROLE) onlyInEmergencyMode {
        emergencyMode = false;
        
        emit EmergencyModeDeactivated(msg.sender);
    }
    
    /**
     * @notice Update emergency mode cooldown
     * @param newCooldown New cooldown period in seconds
     */
    function updateEmergencyCooldown(uint256 newCooldown) external onlyRole(GOVERNANCE_ROLE) {
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
        onlyRole(GUARDIAN_ROLE) 
        onlyInEmergencyMode 
    {
        // Must maintain minimum security with at least 2 validators
        if (newThreshold < 2) revert ThresholdTooLow();
        
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
     * @notice Get governance tier for a token amount
     * @param tokenAmount Amount of tokens
     * @return Governance tier (0-3, where 0 means below tier 1)
     */
    function getGovernanceTier(uint256 tokenAmount) external view returns (uint8) {
        if (tokenAmount >= governanceTier3Threshold) {
            return 3;
        } else if (tokenAmount >= governanceTier2Threshold) {
            return 2;
        } else if (tokenAmount >= governanceTier1Threshold) {
            return 1;
        } else {
            return 0;
        }
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
        
        for (uint256 i = 0; i < validatorSet.length; i++) {
            address validator = validatorSet[i];
            if (isActiveValidator[validator] && validatorRiskScores[validator] >= riskScoreThreshold) {
                count++;
            }
        }
        
        return count;
    }
    
    /**
     * @notice Get inactive validators (no activity in last 7 days)
     * @return Array of inactive validator addresses
     */
    function getInactiveValidators() external view returns (address[] memory) {
        // Pre-allocate maximum possible size
        address[] memory inactiveValidators = new address[](activeValidatorCount);
        
        uint256 inactiveCount = 0;
        uint256 inactivityThreshold = 7 days;
        
        for (uint256 i = 0; i < validatorSet.length; i++) {
            address validator = validatorSet[i];
            if (isActiveValidator[validator]) {
                uint256 inactiveDuration = block.timestamp - lastValidatorActivity[validator];
                if (inactiveDuration > inactivityThreshold) {
                    inactiveValidators[inactiveCount] = validator;
                    inactiveCount++;
                }
            }
        }
        
        // Create correctly sized array with only inactive validators
        address[] memory result = new address[](inactiveCount);
        for (uint256 i = 0; i < inactiveCount; i++) {
            result[i] = inactiveValidators[i];
        }
        
        return result;
    }
}
