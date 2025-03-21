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
import "../interfaces/ITerraStakeRewardDistributor.sol";
import "../interfaces/ITerraStakeTreasuryManager.sol";

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

    // Constants
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
   
    uint256 public constant MIN_SLASH_PERCENTAGE = 1; // 1%
    uint256 public constant MAX_SLASH_PERCENTAGE = 100; // 100%
    uint256 public constant QUORUM_PERCENTAGE = 10; // 10% of total votes required
    uint256 public constant PERCENTAGE_DENOMINATOR = 100;

    // State Variables
    // Core contracts
    ITerraStakeStaking public stakingContract;
    ITerraStakeGovernance public governanceContract;
    ITerraStakeRewardDistributor public rewardDistributor; // Added
    ITerraStakeTreasuryManager public treasuryManager; // Updated
    IERC20 public tStakeToken;
   
    // Slashing parameters
    uint256 public redistributionPercentage;
    uint256 public burnPercentage;
    uint256 public treasuryPercentage;
   
    // Slashing tracking
    uint256 public totalSlashedAmount;
    uint256 public slashProposalCount;
    uint256 public coolingOffPeriod;
   
    // Slashing proposal storage
    mapping(uint256 => SlashProposal) public slashProposals;
    mapping(address => uint256) public lastSlashTime;
    mapping(address => uint256) public totalSlashedForValidator;
   
    // Validator status tracking
    mapping(address => bool) public isActiveValidator;
   
    // Emergency state
    bool public isPaused; // Updated

    // Errors
    error Unauthorized();
    error InvalidParameters();
    error SlashingCoolingOffPeriod();
    error CircuitBreakerActive();
    error ProposalDoesNotExist();
    error InvalidSlashingAmount();
    error SlashProposalAlreadyExecuted();
    error GovernanceQuorumNotMet();
    error ValidatorNotActive();
    error InvalidPercentageSum();
    error ZeroAddressNotAllowed();
    error SlashAmountTooSmall();
    error InsufficientValidatorStake();

    // Initializer & Upgrade Control
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _stakingContract,
        address _governanceContract,
        address _rewardDistributor, // Added
        address _tStakeToken,
        address _initialAdmin,
        address _treasuryManager // Updated
    ) external initializer {
        if (_stakingContract == address(0) ||
            _governanceContract == address(0) ||
            _rewardDistributor == address(0) || // Added
            _tStakeToken == address(0) ||
            _initialAdmin == address(0) ||
            _treasuryManager == address(0)) {
            revert ZeroAddressNotAllowed();
        }
       
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
       
        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        _grantRole(UPGRADER_ROLE, _initialAdmin);
        _grantRole(GOVERNANCE_ROLE, _governanceContract);
        _grantRole(EMERGENCY_ROLE, _initialAdmin);
       
        stakingContract = ITerraStakeStaking(_stakingContract);
        governanceContract = ITerraStakeGovernance(_governanceContract);
        rewardDistributor = ITerraStakeRewardDistributor(_rewardDistributor); // Added
        treasuryManager = ITerraStakeTreasuryManager(_treasuryManager); // Updated
        tStakeToken = IERC20(_tStakeToken);
       
        redistributionPercentage = 50;
        burnPercentage = 30;
        treasuryPercentage = 20;
        coolingOffPeriod = 7 days;
       
        totalSlashedAmount = 0;
        slashProposalCount = 0;
        isPaused = false; // Updated
    }
   
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // Slashing Proposal Management
    function createSlashProposal(
        address validator,
        uint256 slashPercentage,
        string calldata evidence
    ) external nonReentrant returns (uint256) {
        if (isPaused) revert CircuitBreakerActive();
       
        if (validator == address(0)) revert InvalidParameters();
        if (slashPercentage < MIN_SLASH_PERCENTAGE || slashPercentage > MAX_SLASH_PERCENTAGE)
            revert InvalidSlashingAmount();
       
        uint256 validatorStake = stakingContract.getUserTotalStake(validator);

        if (!isActiveValidator[validator]) {
            if (validatorStake == 0) revert ValidatorNotActive();
            isActiveValidator[validator] = true;
        }
       
        if (validatorStake == 0) revert InsufficientValidatorStake();
       
        slashProposalCount++;
        uint256 proposalId = slashProposalCount;
       
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
   
    function executeSlashing(uint256 proposalId) external nonReentrant {
        if (isPaused) revert CircuitBreakerActive();
        if (!hasRole(GOVERNANCE_ROLE, msg.sender)) revert Unauthorized();
        if (proposalId == 0 || proposalId > slashProposalCount) revert ProposalDoesNotExist();
       
        SlashProposal storage proposal = slashProposals[proposalId];
        if (proposal.executed) revert SlashProposalAlreadyExecuted();
       
        if (block.timestamp < lastSlashTime[proposal.validator] + coolingOffPeriod)
            revert SlashingCoolingOffPeriod();
       
        uint256 currentStake = stakingContract.getUserTotalStake(proposal.validator);
        uint256 slashAmount = (currentStake * proposal.slashPercentage) / PERCENTAGE_DENOMINATOR;
       
        if (slashAmount == 0) revert SlashAmountTooSmall();
       
        stakingContract.slash(proposal.validator, slashAmount);
       
        uint256 toRedistribute = (slashAmount * redistributionPercentage) / PERCENTAGE_DENOMINATOR;
        uint256 toBurn = (slashAmount * burnPercentage) / PERCENTAGE_DENOMINATOR;
        uint256 toTreasury = slashAmount - toRedistribute - toBurn;
       
        if (toRedistribute > 0) {
            rewardDistributor.redistributePenalty(proposal.validator, toRedistribute); // Updated
        }
       
        if (toBurn > 0) {
            stakingContract.burnSlashedTokens(toBurn);
        }
       
        if (toTreasury > 0) {
            tStakeToken.safeApprove(address(treasuryManager), toTreasury); // Updated
            treasuryManager.deposit(address(tStakeToken), toTreasury); // Updated
        }
       
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
   
    // Parameter Management
    function updateSlashParameters(
        uint256 _redistributionPercentage,
        uint256 _burnPercentage,
        uint256 _treasuryPercentage
    ) external onlyRole(GOVERNANCE_ROLE) {
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
   
    function updateCoolingOffPeriod(uint256 _coolingOffPeriod) external onlyRole(GOVERNANCE_ROLE) {
        coolingOffPeriod = _coolingOffPeriod;
        emit CoolingOffPeriodUpdated(_coolingOffPeriod);
    }
   
    function updateTreasuryManager(address _treasuryManager) external onlyRole(GOVERNANCE_ROLE) {
        if (_treasuryManager == address(0)) revert ZeroAddressNotAllowed();
        treasuryManager = ITerraStakeTreasuryManager(_treasuryManager);
        emit TreasuryManagerUpdated(_treasuryManager);
    }
   
    function updateValidatorStatus(address validator, bool active) external onlyRole(GOVERNANCE_ROLE) {
        if (validator == address(0)) revert ZeroAddressNotAllowed();
        isActiveValidator[validator] = active;
        emit ValidatorStatusUpdated(validator, active);
    }
   
    // Emergency Functions
    function setPaused(bool paused) external onlyRole(EMERGENCY_ROLE) {
        isPaused = paused;
        emit Paused(paused);
    }
   
    function recoverERC20(address token, uint256 amount, address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || recipient == address(0)) revert ZeroAddressNotAllowed();
        IERC20(token).safeTransfer(recipient, amount);
    }
   
    // View Functions
    function getSlashProposal(uint256 proposalId) external view returns (SlashProposal memory) {
        if (proposalId == 0 || proposalId > slashProposalCount) revert ProposalDoesNotExist();
        return slashProposals[proposalId];
    }
   
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
        uint256 lastSlashTimeByUser
    ) {
        totalSlashed = totalSlashedForValidator[user];
        lastSlashTimeByUser = lastSlashTime[user];
        return (totalSlashed, lastSlashTimeByUser);
    }
   
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
   
    function getActiveSlashProposals() external view returns (SlashProposal[] memory) {
        uint256 activeCount = 0;
       
        for (uint256 i = 1; i <= slashProposalCount; i++) {
            if (!slashProposals[i].executed) {
                activeCount++;
            }
        }
       
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
   
    function canSlashValidator(address validator) external view returns (bool canSlash, bool isActive) {
        isActive = isActiveValidator[validator];
       
        if (!isActive) {
            uint256 stake = stakingContract.getUserTotalStake(validator);
            isActive = stake > 0;
        }
       
        canSlash = isActive && block.timestamp >= lastSlashTime[validator] + coolingOffPeriod;
        return (canSlash, isActive);
    }
   
    function calculateSlashAmounts(address validator, uint256 slashPercentage) external view returns (
        uint256 total,
        uint256 toRedistribute,
        uint256 toBurn,
        uint256 toTreasury
    ) {
        uint256 validatorStake = stakingContract.getUserTotalStake(validator);
        total = (validatorStake * slashPercentage) / PERCENTAGE_DENOMINATOR;
       
        toRedistribute = (total * redistributionPercentage) / PERCENTAGE_DENOMINATOR;
        toBurn = (total * burnPercentage) / PERCENTAGE_DENOMINATOR;
        toTreasury = total - toRedistribute - toBurn;
       
        return (total, toRedistribute, toBurn, toTreasury);
    }
   
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
   
    // Internal Helper Functions
    function _formatProposalDescription(address validator, uint256 percentage) internal pure returns (string memory) {
        return string(abi.encodePacked("Slash validator ", _addressToHexString(validator), " at ", _uintToString(percentage), "% penalty"));
    }
   
    function _addressToHexString(address addr) internal pure returns (string memory) {
        return _bytesToHexString(abi.encodePacked(addr));
    }
   
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