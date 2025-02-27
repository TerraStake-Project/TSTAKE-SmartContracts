// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./interfaces/ITerraStakeSlashing.sol";
import "./interfaces/ITerraStakeGovernance.sol";
import "./interfaces/ITerraStakeStaking.sol";

/**
 * @title TerraStakeSlashing
 * @author TerraStake Protocol Team
 * @notice Handles slashing of validators in the TerraStake ecosystem, governed by DAO
 */
contract TerraStakeSlashing is 
    Initializable, 
    AccessControlEnumerableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable,
    ITerraStakeSlashing
{
    // -------------------------------------------
    // 🔹 Constants
    // -------------------------------------------
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    uint256 public constant MIN_SLASH_PERCENTAGE = 1; // 1%
    uint256 public constant MAX_SLASH_PERCENTAGE = 100; // 100%
    uint256 public constant QUORUM_PERCENTAGE = 10; // 10% of total votes required

    // -------------------------------------------
    // 🔹 State Variables
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
    
    // Emergency state
    bool public emergencyPaused;
    
    // -------------------------------------------
    // 🔹 Events
    // -------------------------------------------
    event SlashProposalCreated(
        uint256 indexed proposalId,
        address indexed validator,
        uint256 slashPercentage,
        string evidence,
        uint256 timestamp
    );
    
    event ValidatorSlashed(
        address indexed validator,
        uint256 slashedAmount,
        uint256 redistributed,
        uint256 burned,
        uint256 sentToTreasury,
        uint256 timestamp
    );
    
    event SlashParametersUpdated(
        uint256 redistributionPercentage,
        uint256 burnPercentage,
        uint256 treasuryPercentage
    );
    
    event EmergencyPauseToggled(bool paused);
    
    // -------------------------------------------
    // 🔹 Errors
    // -------------------------------------------
    error Unauthorized();
    error InvalidParameters();
    error SlashingCoolingOffPeriod();
    error EmergencyPaused();
    error ProposalDoesNotExist();
    error InvalidSlashingAmount();
    error SlashProposalAlreadyExecuted();
    error GovernanceQuorumNotMet();
    
    // -------------------------------------------
    // 🔹 Initializer & Upgrade Control
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
    // 🔹 Slashing Proposal Management
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
        uint256 validatorStake = stakingContract.getValidatorStake(validator);
        if (validatorStake == 0) revert InvalidParameters();
        
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
        
        string memory description = string(abi.encodePacked(
            "Slashing proposal for validator ", 
            addressToString(validator), 
            " with ", 
            uintToString(slashPercentage),
            "% penalty."
        ));
        
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
        uint256 slashAmount = (currentStake * proposal.slashPercentage) / 100;
        
        // Slash the validator through staking contract
        stakingContract.slash(proposal.validator, slashAmount);
        
        // Calculate distribution
        uint256 toRedistribute = (slashAmount * redistributionPercentage) / 100;
        uint256 toBurn = (slashAmount * burnPercentage) / 100;
        uint256 toTreasury = (slashAmount * treasuryPercentage) / 100;
        
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
    // 🔹 Parameter Management
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
        if (_redistributionPercentage + _burnPercentage + _treasuryPercentage != 100) 
            revert InvalidParameters();
        
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
    }
    
    /**
     * @notice Update treasury wallet (only through governance)
     * @param _treasuryWallet New treasury wallet address
     */
    function updateTreasuryWallet(address _treasuryWallet) external onlyRole(GOVERNANCE_ROLE) {
        if (_treasuryWallet == address(0)) revert InvalidParameters();
        treasuryWallet = _treasuryWallet;
    }
    
    // -------------------------------------------
    // 🔹 Emergency Functions
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
        IERC20(token).transfer(treasuryWallet, amount);
    }
    
    // -------------------------------------------
    // 🔹 View Functions
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
     * @return ids Array of active proposal IDs
     */
    function getActiveSlashProposals() external view returns (uint256[] memory) {
        uint256 count = 0;
        
        // Count active proposals
        for (uint256 i = 1; i <= slashProposalCount; i++) {
            if (!slashProposals[i].executed) {
                count++;
            }
        }
        
        // Collect active proposal IDs
        uint256[] memory activeIds = new uint256[](count);
        uint256 index = 0;
        
        for (uint256 i = 1; i <= slashProposalCount; i++) {
            if (!slashProposals[i].executed) {
                activeIds[index] = i;
                index++;
            }
        }
        
        return activeIds;
    }
    
    /**
     * @notice Check if a validator can be slashed
     * @param validator Validator address
     * @return True if validator can be slashed
     */
    function canSlashValidator(address validator) external view returns (bool) {
        return block.timestamp >= lastSlashTime[validator] + coolingOffPeriod;
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
        total = (validatorStake * slashPercentage) / 100;
        
        toRedistribute = (total * redistributionPercentage) / 100;
        toBurn = (total * burnPercentage) / 100;
        toTreasury = (total * treasuryPercentage) / 100;
        
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
    // 🔹 Helper Functions
    // -------------------------------------------
    
    /**
     * @notice Convert address to string
     * @param addr Address to convert
     * @return string representation
     */
    function addressToString(address addr) internal pure returns (string memory) {
        bytes memory addressBytes = abi.encodePacked(addr);
        bytes memory stringBytes = new bytes(42);
        
        stringBytes[0] = '0';
        stringBytes[1] = 'x';
        
        for (uint256 i = 0; i < 20; i++) {
            bytes1 leftNibble = bytes1(uint8(addressBytes[i]) / 16);
            bytes1 rightNibble = bytes1(uint8(addressBytes[i]) % 16);
            
            stringBytes[2 + i * 2] = leftNibble < 10 
                ? bytes1(uint8(leftNibble) + 48) 
                : bytes1(uint8(leftNibble) + 87);
            stringBytes[2 + i * 2 + 1] = rightNibble < 10 
                ? bytes1(uint8(rightNibble) + 48) 
                : bytes1(uint8(rightNibble) + 87);
        }
        
        return string(stringBytes);
    }
    
    /**
     * @notice Convert uint to string
     * @param value Uint to convert
     * @return string representation
     */
    function uintToString(uint256 value) internal pure returns (string memory) {
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
    
    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[45] private __gap;
}
