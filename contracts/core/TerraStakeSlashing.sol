// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/ITerraStakeSlashing.sol";
import "../interfaces/ITerraStakeGovernance.sol";
import "../interfaces/ITerraStakeStaking.sol";


/**
 * @title TerraStakeSlashing
 * @author TerraStake Protocol Team
 * @notice Handles slashing of validators in the TerraStake ecosystem, governed by DAO
 */
contract TerraStakeSlashing is 
    ITerraStakeSlashing,
    Initializable, 
    AccessControlEnumerableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // -------------------------------------------
    //  Constants
    // -------------------------------------------
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    uint256 public constant MIN_SLASH_PERCENTAGE = 1; // 1%
    uint256 public constant MAX_SLASH_PERCENTAGE = 100; // 100%
    uint256 public constant QUORUM_PERCENTAGE = 10; // 10% of total votes required
    uint256 public constant PERCENTAGE_DENOMINATOR = 100;

    // -------------------------------------------
    //  State Variables
    // -------------------------------------------
    
    // Core contracts
    ITerraStakeStaking public stakingContract;
    ITerraStakeGovernance public governanceContract;
    IERC20 public tStakeToken;
    
    // Slashing parameters
    uint256 public redistributionPercentage; // percentage of slashed amount redistributed to other stakers
    uint256 public burnPercentage; // percentage of slashed amount burned
    uint256 public treasuryPercentage; // percentage of slashed amount sent to treasury
    
    // Slashing tracking
    uint256 public totalSlashedAmount;
    uint256 public slashProposalCount;
    uint256 public coolingOffPeriod; // time before a validator can be slashed again
    address public treasuryWallet;
    
    // Slashing proposal storage
    mapping(uint256 => SlashProposal) public slashProposals;
    mapping(address => uint256) public lastSlashTime;
    mapping(address => uint256) public totalSlashedForValidator;
    
    // Validator status tracking
    mapping(address => bool) public isActiveValidator;
    
    // Emergency state
    bool public emergencyPaused;
    
    // -------------------------------------------
    //  Errors
    // -------------------------------------------
    error Unauthorized();
    error InvalidParameters();
    error SlashingCoolingOffPeriod();
    error EmergencyPaused();
    error ProposalDoesNotExist();
    error InvalidSlashingAmount();
    error SlashProposalAlreadyExecuted();
    error GovernanceQuorumNotMet();
    error ValidatorNotActive();
    error InvalidPercentageSum();
    error ZeroAddressNotAllowed();
    error SlashAmountTooSmall();
    error InsufficientValidatorStake();
    
    // -------------------------------------------
    //  Initializer & Upgrade Control
    // -------------------------------------------
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @notice Initialize the slashing contract
     * @param _stakingContract Address of the staking contract
     * @param _governanceContract Address of the governance contract
     * @param _tStakeToken Address of the TStake token
     * @param _initialAdmin Initial admin address
     * @param _treasuryWallet Address of the treasury wallet
     */
    function initialize(
        address _stakingContract,
        address _governanceContract,
        address _tStakeToken,
        address _initialAdmin,
        address _treasuryWallet
    ) external initializer {
        if (_stakingContract == address(0) || 
            _governanceContract == address(0) ||
            _tStakeToken == address(0) ||
            _initialAdmin == address(0) ||
            _treasuryWallet == address(0)) {
            revert ZeroAddressNotAllowed();
        }
        
        // Initialize base contracts
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        _grantRole(UPGRADER_ROLE, _initialAdmin);
        _grantRole(GOVERNANCE_ROLE, _governanceContract);
        _grantRole(EMERGENCY_ROLE, _initialAdmin);
        
        // Initialize contract references
        stakingContract = ITerraStakeStaking(_stakingContract);
        governanceContract = ITerraStakeGovernance(_governanceContract);
        tStakeToken = IERC20(_tStakeToken);
        treasuryWallet = _treasuryWallet;
        
        // Initialize slashing parameters
        redistributionPercentage = 50; // 50% redistributed to stakers
        burnPercentage = 30; // 30% burned
        treasuryPercentage = 20; // 20% to treasury
        coolingOffPeriod = 7 days; // 7 day cooling off period
        
        // Initialize tracking
        totalSlashedAmount = 0;
        slashProposalCount = 0;
        emergencyPaused = false;
    }
    
    /**
     * @notice Authorize contract upgrades, restricted to the upgrader role
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
    
    // -------------------------------------------
    //  Slashing Proposal Management
    // -------------------------------------------
    
    /**
     * @notice Create a proposal to slash a validator
     * @param validator Address of the validator to slash
     * @param slashPercentage Percentage of validator's stake to slash
     * @param evidence String evidence for the slashing
     * @return proposalId ID of the created slash proposal
     */
    function createSlashProposal(
        address validator,
        uint256 slashPercentage,
        string calldata evidence
    ) external nonReentrant returns (uint256) {
        if (emergencyPaused) revert EmergencyPaused();
        
        // Validate parameters
        if (validator == address(0)) revert InvalidParameters();
        if (slashPercentage < MIN_SLASH_PERCENTAGE || slashPercentage > MAX_SLASH_PERCENTAGE) 
            revert InvalidSlashingAmount();
        
        // Get validator's staked amount from staking contract
        uint256 validatorStake = stakingContract.getUserTotalStake(validator);

        // Check if validator is active
        if (!isActiveValidator[validator]) {
            // Try to refresh validator status from staking contract
            if (validatorStake == 0) revert ValidatorNotActive();
            
            // If validator has stake but wasn't marked as active, mark them now
            isActiveValidator[validator] = true;
        }
        
        if (validatorStake == 0) revert InsufficientValidatorStake();
        
        // Create the slash proposal
        slashProposalCount++;
        uint256 proposalId = slashProposalCount;
        
        // Build slash proposal
        slashProposals[proposalId] = SlashProposal({
            id: proposalId,
            validator: validator,
            slashPercentage: slashPercentage,
            totalStake: validatorStake,
            executed: false,
            proposer: msg.sender,
            proposedTime: block.timestamp,
            evidence: evidence,
            executionTime: 0
        });
        
        // Create governance proposal for this slash
        bytes memory callData = abi.encodeWithSelector(
            this.executeSlashing.selector,
            proposalId
        );
        
        bytes32 proposalHash = keccak256(abi.encode(
            "SLASH",
            validator, 
            slashPercentage, 
            block.timestamp
        ));
        
        string memory description = _formatProposalDescription(validator, slashPercentage);
        
        // Submit to governance contract
        governanceContract.createStandardProposal(
            proposalHash,
            description,
            callData,
            address(this)
        );
        
        emit SlashProposalCreated(
            proposalId,
            validator,
            slashPercentage,
            evidence,
            block.timestamp
        );
        
        return proposalId;
    }
    
    /**
     * @notice Execute slashing from a passed governance proposal
     * @param proposalId ID of the slash proposal to execute
     */
    function executeSlashing(uint256 proposalId) external nonReentrant {
        if (emergencyPaused) revert EmergencyPaused();
        if (!hasRole(GOVERNANCE_ROLE, msg.sender)) revert Unauthorized();
        if (proposalId == 0 || proposalId > slashProposalCount) revert ProposalDoesNotExist();
        
        SlashProposal storage proposal = slashProposals[proposalId];
        if (proposal.executed) revert SlashProposalAlreadyExecuted();
        
        // Check cooling off period
        if (block.timestamp < lastSlashTime[proposal.validator] + coolingOffPeriod) 
            revert SlashingCoolingOffPeriod();
        
        // Calculate slash amount
        uint256 currentStake = stakingContract.getValidatorStake(proposal.validator);
        uint256 slashAmount = (currentStake * proposal.slashPercentage) / PERCENTAGE_DENOMINATOR;
        
        if (slashAmount == 0) revert SlashAmountTooSmall();
        
        // Slash the validator through staking contract
        stakingContract.slash(proposal.validator, slashAmount);
        
        // Calculate distribution
        uint256 toRedistribute = (slashAmount * redistributionPercentage) / PERCENTAGE_DENOMINATOR;
        uint256 toBurn = (slashAmount * burnPercentage) / PERCENTAGE_DENOMINATOR;
        uint256 toTreasury = slashAmount - toRedistribute - toBurn; // Ensure no rounding errors
        
        // Redistribute slashed tokens
        if (toRedistribute > 0) {
            stakingContract.distributeSlashedTokens(toRedistribute);
        }
        
        // Burn tokens
        if (toBurn > 0) {
            stakingContract.burnSlashedTokens(toBurn);
        }
        
        // Send to treasury
        if (toTreasury > 0) {
            stakingContract.sendSlashedTokensToTreasury(toTreasury, treasuryWallet);
        }
        
        // Update tracking
        proposal.executed = true;
        proposal.executionTime = block.timestamp;
        lastSlashTime[proposal.validator] = block.timestamp;
        totalSlashedForValidator[proposal.validator] += slashAmount;
        totalSlashedAmount += slashAmount;
        
        emit ValidatorSlashed(
            proposal.validator,
            slashAmount,
            toRedistribute,
            toBurn,
            toTreasury,
            block.timestamp
        );
    }
    
    // -------------------------------------------
    //  Parameter Management
    // -------------------------------------------
    
    /**
     * @notice Update slashing parameters (only through governance)
     * @param _redistributionPercentage New redistribution percentage
     * @param _burnPercentage New burn percentage
     * @param _treasuryPercentage New treasury percentage
     */
    function updateSlashParameters(
        uint256 _redistributionPercentage,
        uint256 _burnPercentage,
        uint256 _treasuryPercentage
    ) external onlyRole(GOVERNANCE_ROLE) {
        // Ensure percentages add up to 100%
        if (_redistributionPercentage + _burnPercentage + _treasuryPercentage != PERCENTAGE_DENOMINATOR) 
            revert InvalidPercentageSum();
        
        redistributionPercentage = _redistributionPercentage;
        burnPercentage = _burnPercentage;
        treasuryPercentage = _treasuryPercentage;
        
        emit SlashParametersUpdated(
            _redistributionPercentage,
            _burnPercentage,
            _treasuryPercentage
        );
    }
    
    /**
     * @notice Update cooling off period (only through governance)
     * @param _coolingOffPeriod New cooling off period in seconds
     */
    function updateCoolingOffPeriod(uint256 _coolingOffPeriod) external onlyRole(GOVERNANCE_ROLE) {
         coolingOffPeriod = _coolingOffPeriod;
        emit CoolingOffPeriodUpdated(_coolingOffPeriod);
    }
    
    /**
     * @notice Update treasury wallet (only through governance)
     * @param _treasuryWallet New treasury wallet address
     */
    function updateTreasuryWallet(address _treasuryWallet) external onlyRole(GOVERNANCE_ROLE) {
        if (_treasuryWallet == address(0)) revert ZeroAddressNotAllowed();
        treasuryWallet = _treasuryWallet;
        emit TreasuryWalletUpdated(_treasuryWallet);
    }
    
    /**
     * @notice Update validator active status
     * @param validator Validator address
     * @param active Whether validator is active
     */
    function updateValidatorStatus(address validator, bool active) external onlyRole(GOVERNANCE_ROLE) {
        if (validator == address(0)) revert ZeroAddressNotAllowed();
        isActiveValidator[validator] = active;
        emit ValidatorStatusUpdated(validator, active);
    }
    
    // -------------------------------------------
    //  Emergency Functions
    // -------------------------------------------
    
    /**
     * @notice Toggle emergency pause (only emergency role)
     * @param paused Whether to pause or unpause
     */
    function toggleEmergencyPause(bool paused) external onlyRole(EMERGENCY_ROLE) {
        emergencyPaused = paused;
        emit EmergencyPauseToggled(paused);
    }
    
    /**
     * @notice Recover accidentally sent tokens (only admin)
     * @param token Token address
     * @param amount Amount to recover
     */
    function recoverERC20(address token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddressNotAllowed();
        IERC20(token).safeTransfer(treasuryWallet, amount);
    }
    
    // -------------------------------------------
    //  View Functions
    // -------------------------------------------
    
    /**
     * @notice Get slash proposal details
     * @param proposalId ID of the proposal
     * @return Slash proposal details
     */
    function getSlashProposal(uint256 proposalId) external view returns (SlashProposal memory) {
        if (proposalId == 0 || proposalId > slashProposalCount) revert ProposalDoesNotExist();
        return slashProposals[proposalId];
    }
    
    /**
     * @notice Get slash history for a validator
     * @param validator Validator address
     * @return totalSlashed Total amount slashed from validator
     * @return lastSlashed Last time validator was slashed
     * @return canBeSlashed Whether validator can be slashed now
     */
    function getValidatorSlashInfo(address validator) external view returns (
        uint256 totalSlashed,
        uint256 lastSlashed,
        bool canBeSlashed
    ) {
        totalSlashed = totalSlashedForValidator[validator];
        lastSlashed = lastSlashTime[validator];
        canBeSlashed = block.timestamp >= lastSlashTime[validator] + coolingOffPeriod;
        
        return (totalSlashed, lastSlashed, canBeSlashed);
    }

    function getUserSlashedRewards(address user) external view returns (
        uint256 totalSlashed,
        uint256 lastSlashTime
    ) {
        totalSlashed = totalSlashedForValidator[user];
        lastSlashTime = lastSlashTime[user];
        return (totalSlashed, lastSlashTime);
    }
    
    /**
     * @notice Get current slashing parameters
     * @return redistribution Percentage for redistribution
     * @return burn Percentage for burning
     * @return treasury Percentage for treasury
     * @return cooling Cooling off period in seconds
     */
    function getSlashParameters() external view returns (
        uint256 redistribution,
        uint256 burn,
        uint256 treasury,
        uint256 cooling
    ) {
        return (
            redistributionPercentage,
            burnPercentage,
            treasuryPercentage,
            coolingOffPeriod
        );
    }
    
    /**
     * @notice Get all active slash proposals
     * @return activeProposals Array of active proposal details
     */
    function getActiveSlashProposals() external view returns (SlashProposal[] memory) {
        uint256 activeCount = 0;
        
        // First, count active proposals
        for (uint256 i = 1; i <= slashProposalCount; i++) {
            if (!slashProposals[i].executed) {
                activeCount++;
            }
        }
        
        // Now create and populate the array in one pass
        SlashProposal[] memory activeProposals = new SlashProposal[](activeCount);
        
        if (activeCount > 0) {
            uint256 index = 0;
            for (uint256 i = 1; i <= slashProposalCount; i++) {
                if (!slashProposals[i].executed) {
                    activeProposals[index] = slashProposals[i];
                    index++;
                }
            }
        }
        
        return activeProposals;
    }
    
    /**
     * @notice Check if a validator can be slashed
     * @param validator Validator address
     * @return canSlash True if validator can be slashed
     * @return isActive True if validator is active
     */
    function canSlashValidator(address validator) external view returns (bool canSlash, bool isActive) {
        isActive = isActiveValidator[validator];
        
        // If not marked as active, check staking contract
        if (!isActive) {
            uint256 stake = stakingContract.getValidatorStake(validator);
            isActive = stake > 0;
        }
        
        canSlash = isActive && block.timestamp >= lastSlashTime[validator] + coolingOffPeriod;
        return (canSlash, isActive);
    }
    
    /**
     * @notice Calculate potential slash amounts for a given validator and percentage
     * @param validator Validator address
     * @param slashPercentage Percentage to slash
     * @return total Total amount to slash
     * @return toRedistribute Amount to redistribute
     * @return toBurn Amount to burn
     * @return toTreasury Amount to send to treasury
     */
    function calculateSlashAmounts(address validator, uint256 slashPercentage) external view returns (
        uint256 total,
        uint256 toRedistribute,
        uint256 toBurn,
        uint256 toTreasury
    ) {
        uint256 validatorStake = stakingContract.getValidatorStake(validator);
        total = (validatorStake * slashPercentage) / PERCENTAGE_DENOMINATOR;
        
        toRedistribute = (total * redistributionPercentage) / PERCENTAGE_DENOMINATOR;
        toBurn = (total * burnPercentage) / PERCENTAGE_DENOMINATOR;
        toTreasury = total - toRedistribute - toBurn; // Using subtraction prevents rounding errors
        
        return (total, toRedistribute, toBurn, toTreasury);
    }
    
    /**
     * @notice Get system-wide slashing statistics
     * @return totalProposals Total number of slash proposals
     * @return totalExecuted Total executed slash proposals
     * @return totalAmountSlashed Total amount of tokens slashed
     */
    function getSlashingStats() external view returns (
        uint256 totalProposals,
        uint256 totalExecuted,
        uint256 totalAmountSlashed
    ) {
        uint256 executed = 0;
        
        for (uint256 i = 1; i <= slashProposalCount; i++) {
            if (slashProposals[i].executed) {
                executed++;
            }
        }
        
        return (slashProposalCount, executed, totalSlashedAmount);
    }
    
    // -------------------------------------------
    //  Internal Helper Functions
    // -------------------------------------------
    
    /**
     * @notice Format proposal description
     * @param validator Validator address
     * @param percentage Slash percentage
     * @return description Formatted description string
     */
    function _formatProposalDescription(address validator, uint256 percentage) internal pure returns (string memory) {
        // For gas efficiency, this only formats a simple description. More extensive formatting should be done off-chain.
        return string(abi.encodePacked("Slash validator ", _addressToHexString(validator), " at ", _uintToString(percentage), "% penalty"));
    }
    
    /**
     * @notice Convert address to hex string
     * @param addr Address to convert
     * @return result Hex string representation
     */
    function _addressToHexString(address addr) internal pure returns (string memory) {
        return _bytesToHexString(abi.encodePacked(addr));
    }
    
    /**
     * @notice Convert bytes to hex string
     * @param buffer Bytes to convert
     * @return result Hex string representation
     */
    function _bytesToHexString(bytes memory buffer) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory result = new bytes(2 + buffer.length * 2);
        result[0] = "0";
        result[1] = "x";
        
        for (uint256 i = 0; i < buffer.length; i++) {
            result[2 + i * 2] = hexChars[uint8(buffer[i] >> 4)];
            result[3 + i * 2] = hexChars[uint8(buffer[i] & 0x0f)];
        }
        
        return string(result);
    }
    
    /**
     * @notice Convert uint to string
     * @param value Uint to convert
     * @return result String representation
     */
    function _uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        
        uint256 temp = value;
        uint256 digits;
        
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        
        bytes memory buffer = new bytes(digits);
        
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        
        return string(buffer);
    }
}
