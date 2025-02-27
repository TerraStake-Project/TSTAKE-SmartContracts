// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import "../interfaces/ITerraStakeGovernance.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/ITerraStakeRewardDistributor.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";

/**
 * @title TerraStakeGovernance
 * @author TerraStake Protocol Team
 * @notice Governance contract for the TerraStake Protocol with advanced voting, 
 * proposal management, treasury control, economic adjustments, and validator safety
 */
contract TerraStakeGovernance is 
    Initializable, 
    AccessControlEnumerableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable,
    ITerraStakeGovernance
{
    using ECDSA for bytes32;

    // -------------------------------------------
    // 🔹 Constants
    // -------------------------------------------
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    
    uint8 public constant PROPOSAL_TYPE_STANDARD = 0;
    uint8 public constant PROPOSAL_TYPE_FEE_UPDATE = 1;
    uint8 public constant PROPOSAL_TYPE_PARAM_UPDATE = 2;
    uint8 public constant PROPOSAL_TYPE_CONTRACT_UPDATE = 3;
    uint8 public constant PROPOSAL_TYPE_PENALTY = 4;
    uint8 public constant PROPOSAL_TYPE_EMERGENCY = 5;
    uint8 public constant PROPOSAL_TYPE_VALIDATOR = 6;
    
    uint256 public constant TIMELOCK_DURATION = 2 days;
    uint256 public constant PENALTY_FOR_VIOLATION = 5; // 5% of stake
    uint256 public constant TWO_YEARS = 730 days;
    uint24 public constant POOL_FEE = 3000; // 0.3% pool fee for Uniswap v3
    
    // Validator safety thresholds
    uint256 public constant CRITICAL_VALIDATOR_THRESHOLD = 3;  // Absolute minimum
    uint256 public constant REDUCED_VALIDATOR_THRESHOLD = 7;   // Limited governance
    uint256 public constant OPTIMAL_VALIDATOR_THRESHOLD = 15;  // Full governance
    uint8 public constant GUARDIAN_QUORUM = 3;                 // Minimum guardians for override
    
    // -------------------------------------------
    // 🔹 State Variables
    // -------------------------------------------
    
    // Core contracts
    ITerraStakeStaking public stakingContract;
    ITerraStakeRewardDistributor public rewardDistributor;
    ITerraStakeLiquidityGuard public liquidityGuard;
    ISwapRouter public uniswapRouter;
    IERC20 public tStakeToken;
    IERC20 public usdcToken;
    
    // Governance parameters
    uint256 public votingDuration;
    uint256 public proposalThreshold;
    uint256 public minimumHolding;
    uint256 public feeUpdateCooldown;
    address public treasuryWallet;
    
    // Fee structure
    FeeProposal public currentFeeStructure;
    uint256 public lastFeeUpdateTime;
    
    // Halving state
    uint256 public lastHalvingTime;
    uint256 public halvingEpoch;
    
    // Liquidity pairing
    bool public liquidityPairingEnabled;
    
    // Governance tracking
    uint256 public proposalCount;
    uint256 public totalVotesCast;
    uint256 public totalProposalsExecuted;
    
    // Governance penalties
    mapping(address => bool) public penalizedGovernors;
    
    // Proposal storage
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => ExtendedProposalData) public proposalExtendedData;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(bytes32 => bool) public executedHashes;
    
    // Validator safety mechanism
    uint8 public governanceTier; // 0=Emergency, 1=Reduced, 2=Full
    bool public bootstrapMode;
    uint256 public bootstrapEndTime;
    uint256 public temporaryThresholdEndTime;
    uint256 public originalValidatorThreshold;
    mapping(address => bool) public guardianCouncil;
    uint8 public guardianCount;
    
    // Execution nonces to prevent replay attacks
    mapping(uint256 => bool) public executedNonces;
    uint256 public currentNonce;

    // -------------------------------------------
    // 🔹 Events
    // -------------------------------------------
    
    // Validator safety events
    event GovernanceTierUpdated(uint8 tier, uint256 validatorCount);
    event BootstrapModeConfigured(uint256 duration);
    event BootstrapModeExited();
    event EmergencyThresholdReduction(uint256 newThreshold, uint256 duration);
    event ThresholdResetScheduled(uint256 resetTime);
    event ValidatorHealthCheck(uint256 validatorCount, uint256 totalStaked, uint256 avgStakePerValidator, uint8 governanceTier);
    event GuardianAdded(address guardian);
    event GuardianRemoved(address guardian);
    event GuardianOverrideExecuted(address executor, bytes4 operation, address target);
    event ValidatorProposalCreated(uint256 proposalId, uint256 newThreshold);
    event ValidatorRecruitmentInitiated(uint256 incentiveAmount, uint256 targetCount);
    
    // -------------------------------------------
    // 🔹 Errors
    // -------------------------------------------
    error GovernanceThresholdNotMet();
    error ProposalNotReady();
    error ProposalDoesNotExist();
    error InvalidVote();
    error TimelockNotExpired();
    error ProposalAlreadyExecuted();
    error InvalidProposalState();
    error InvalidParameters();
    error GovernanceViolation();
    error Unauthorized();
    error InsufficientValidators();
    error ProposalTypeNotAllowed();
    error InvalidGuardianSignatures();
    error NonceAlreadyExecuted();
    
    // -------------------------------------------
    // 🔹 Modifiers
    // -------------------------------------------
    
    /**
     * @notice Validator count safety check for critical functions
     */
    modifier validatorSafetyCheck() {
        if (!bootstrapMode) {
            uint256 validatorCount = stakingContract.getValidatorCount();
            if (validatorCount < CRITICAL_VALIDATOR_THRESHOLD) {
                revert InsufficientValidators();
            }
        }
        _;
    }
    
    /**
     * @notice Check if proposal type is allowed in current governance tier
     */
    modifier allowedProposalType(uint8 proposalType) {
        if (!isProposalTypeAllowed(proposalType)) {
            revert ProposalTypeNotAllowed();
        }
        _;
    }
    
    // -------------------------------------------
    // 🔹 Initializer & Upgrade Control
    // -------------------------------------------
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @notice Initialize the governance contract
     * @param _stakingContract Address of the staking contract
     * @param _rewardDistributor Address of the reward distributor
     * @param _liquidityGuard Address of the liquidity guard
     * @param _tStakeToken Address of the TStake token
     * @param _usdcToken Address of the USDC token
     * @param _uniswapRouter Address of the Uniswap V3 router
     * @param _initialAdmin Initial admin address
     * @param _treasuryWallet Address of the treasury wallet
     */
    function initialize(
        address _stakingContract,
        address _rewardDistributor,
        address _liquidityGuard,
        address _tStakeToken,
        address _usdcToken,
        address _uniswapRouter,
        address _initialAdmin,
        address _treasuryWallet
    ) external initializer {
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        _grantRole(UPGRADER_ROLE, _initialAdmin);
        _grantRole(GOVERNANCE_ROLE, _initialAdmin);
        _grantRole(GUARDIAN_ROLE, _initialAdmin);
        
        // Initialize contract references
        stakingContract = ITerraStakeStaking(_stakingContract);
        rewardDistributor = ITerraStakeRewardDistributor(_rewardDistributor);
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);
        tStakeToken = IERC20(_tStakeToken);
        usdcToken = IERC20(_usdcToken);
        uniswapRouter = ISwapRouter(_uniswapRouter);
        treasuryWallet = _treasuryWallet;
        
        // Initialize governance parameters
        votingDuration = 5 days;
        proposalThreshold = 1000 * 10**18; // 1000 TStake tokens
        minimumHolding = 100 * 10**18; // 100 TStake tokens
        feeUpdateCooldown = 30 days;
        
        // Set initial fee structure
        currentFeeStructure = FeeProposal({
            projectSubmissionFee: 500 * 10**6, // 500 USDC
            impactReportingFee: 100 * 10**6, // 100 USDC
            buybackPercentage: 30, // 30%
            liquidityPairingPercentage: 30, // 30%
            burnPercentage: 20, // 20%
            treasuryPercentage: 20, // 20%
            voteEnd: 0,
            executed: true
        });
        
        // Initialize halving state
        lastHalvingTime = block.timestamp;
        halvingEpoch = 0;
        
        // Enable liquidity pairing by default
        liquidityPairingEnabled = true;
        
        // Initialize validator safety mechanisms
        bootstrapMode = true;
        bootstrapEndTime = block.timestamp + 90 days; // 3 month bootstrap period by default
        guardianCount = 1; // Initial admin is first guardian
        guardianCouncil[_initialAdmin] = true;
        
        // Store original validator threshold
        originalValidatorThreshold = stakingContract.validatorThreshold();
        
        // Set initial governance tier
        governanceTier = 0; // Start in emergency tier until sufficient validators
        
        // Initialize nonce
        currentNonce = 1;
    }
    
    /**
     * @notice Authorize contract upgrades, restricted to the upgrader role
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
    
    // -------------------------------------------
    // 🔹 Validator Safety Mechanisms
    // -------------------------------------------
    
    /**
     * @notice Updates governance tier based on validator count
     * @return The updated governance tier
     */
    function updateGovernanceTier() public returns (uint8) {
        uint256 validatorCount = stakingContract.getValidatorCount();
        
        uint8 newTier;
        if (validatorCount < CRITICAL_VALIDATOR_THRESHOLD) {
            newTier = 0; // Emergency tier
        } else if (validatorCount < OPTIMAL_VALIDATOR_THRESHOLD) {
            newTier = 1; // Reduced tier
        } else {
            newTier = 2; // Full tier
        }
        
        if (newTier != governanceTier) {
            governanceTier = newTier;
            emit GovernanceTierUpdated(governanceTier, validatorCount);
        }
        
        return governanceTier;
    }
    
    /**
     * @notice Validates if proposal type is allowed in current governance tier
     * @param proposalType The type of proposal to validate
     * @return True if proposal type is allowed
     */
    function isProposalTypeAllowed(uint8 proposalType) public view returns (bool) {
        // Always ensure governance tier is up to date
        uint256 validatorCount = stakingContract.getValidatorCount();
        uint8 effectiveTier;
        
        if (validatorCount < CRITICAL_VALIDATOR_THRESHOLD) {
            effectiveTier = 0; // Emergency tier
        } else if (validatorCount < OPTIMAL_VALIDATOR_THRESHOLD) {
            effectiveTier = 1; // Reduced tier
        } else {
            effectiveTier = 2; // Full tier
        }
        
        if (effectiveTier == 0) {
            // Emergency tier: Only emergency, validator-related, and penalty proposals
            return proposalType == PROPOSAL_TYPE_EMERGENCY ||
                   proposalType == PROPOSAL_TYPE_VALIDATOR ||
                   proposalType == PROPOSAL_TYPE_PENALTY;
        } else if (effectiveTier == 1) {
            // Reduced tier: All except contract updates
            return proposalType != PROPOSAL_TYPE_CONTRACT_UPDATE;
        }
        
        // Full tier: All proposal types allowed
        return true;
    }
    
    /**
     * @notice Configure bootstrap mode for initial validator set building
     * @param duration How long bootstrap mode should last
     */
    function setValidatorBootstrap(uint256 duration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(bootstrapMode, "Bootstrap mode already ended");
        bootstrapEndTime = block.timestamp + duration;
emit BootstrapModeConfigured(duration);
    }
    
    /**
     * @notice Exit bootstrap mode when sufficient validators exist
     */
    function exitBootstrapMode() external {
        require(bootstrapMode, "Already exited bootstrap mode");
        require(
            block.timestamp > bootstrapEndTime || 
            stakingContract.getValidatorCount() >= OPTIMAL_VALIDATOR_THRESHOLD,
            "Cannot exit bootstrap: insufficient validators or time"
        );
        bootstrapMode = false;
        emit BootstrapModeExited();
    }

    /**
     * @notice Temporarily reduce validator threshold to encourage participation
     * @param newThreshold Temporary validator threshold
     * @param duration How long the reduction should last
     */
    function emergencyReduceValidatorThreshold(
        uint256 newThreshold,
        uint256 duration
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(
            stakingContract.getValidatorCount() < CRITICAL_VALIDATOR_THRESHOLD,
            "Not in emergency state"
        );
        
        // Store original threshold if not already stored
        if (temporaryThresholdEndTime == 0) {
            originalValidatorThreshold = stakingContract.validatorThreshold();
        }
        
        // Implement temporary reduction via stakingContract
        bytes memory callData = abi.encodeWithSelector(
            ITerraStakeStaking.setValidatorThreshold.selector,
            newThreshold
        );
        
        (bool success, ) = address(stakingContract).call(callData);
        require(success, "Threshold update failed");
        
        // Schedule return to normal threshold
        _scheduleThresholdReset(duration);
        
        emit EmergencyThresholdReduction(newThreshold, duration);
    }
    
    /**
     * @notice Schedule threshold reset after temporary reduction expires
     * @param duration Duration of temporary threshold reduction
     */
    function _scheduleThresholdReset(uint256 duration) internal {
        temporaryThresholdEndTime = block.timestamp + duration;
        emit ThresholdResetScheduled(temporaryThresholdEndTime);
    }
    
    /**
     * @notice Reset validator threshold to original value after temporary reduction expires
     */
    function resetValidatorThreshold() external {
        require(temporaryThresholdEndTime > 0, "No threshold reset scheduled");
        require(block.timestamp >= temporaryThresholdEndTime, "Temporary threshold still active");
        
        bytes memory callData = abi.encodeWithSelector(
            ITerraStakeStaking.setValidatorThreshold.selector,
            originalValidatorThreshold
        );
        
        (bool success, ) = address(stakingContract).call(callData);
        require(success, "Threshold reset failed");
        
        temporaryThresholdEndTime = 0;
    }
    
    /**
     * @notice Emits validator health status for offchain monitoring
     */
    function checkValidatorHealth() external {
        uint256 validatorCount = stakingContract.getValidatorCount();
        uint256 totalStaked = stakingContract.totalStakedTokens();
        uint256 avgStakePerValidator = validatorCount > 0 ? totalStaked / validatorCount : 0;
        
        emit ValidatorHealthCheck(
            validatorCount,
            totalStaked,
            avgStakePerValidator,
            governanceTier
        );
    }
    
    /**
     * @notice Add a guardian to the guardian council
     * @param guardian Address of the new guardian
     */
    function addGuardian(address guardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(guardian != address(0), "Invalid guardian address");
        require(!guardianCouncil[guardian], "Already a guardian");
        
        guardianCouncil[guardian] = true;
        guardianCount++;
        _grantRole(GUARDIAN_ROLE, guardian);
        
        emit GuardianAdded(guardian);
    }
    
    /**
     * @notice Remove a guardian from the guardian council
     * @param guardian Address of the guardian to remove
     */
    function removeGuardian(address guardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(guardianCouncil[guardian], "Not a guardian");
        require(guardianCount > 1, "Cannot remove last guardian");
        
        guardianCouncil[guardian] = false;
        guardianCount--;
        _revokeRole(GUARDIAN_ROLE, guardian);
        
        emit GuardianRemoved(guardian);
    }
    
    /**
     * @notice Validate guardian signatures for an emergency override
     * @param operation Function selector to call
     * @param target Contract to call
     * @param data Call data
     * @param signatures Guardian signatures approving this action
     * @return True if signatures are valid
     */
    function validateGuardianSignatures(
        bytes4 operation,
        address target,
        bytes calldata data,
        bytes[] calldata signatures
    ) public view returns (bool) {
        require(signatures.length >= GUARDIAN_QUORUM, "Insufficient signatures");
        
        // Hash the operation details with current nonce to prevent replay
        bytes32 messageHash = keccak256(abi.encodePacked(
            operation,
            target,
            data,
            currentNonce
        ));
        
        // Prefix the hash according to EIP-191
        bytes32 prefixedHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            messageHash
        ));
        
        // Track signers to prevent duplicates
        address[] memory signers = new address[](signatures.length);
        uint256 validSignatures = 0;
        
        // Validate each signature
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = prefixedHash.recover(signatures[i]);
            
            // Check if signer is a guardian
            if (guardianCouncil[signer]) {
                // Check for duplicate signers
                bool isDuplicate = false;
                for (uint256 j = 0; j < validSignatures; j++) {
                    if (signers[j] == signer) {
                        isDuplicate = true;
                        break;
                    }
                }
                
                if (!isDuplicate) {
                    signers[validSignatures] = signer;
                    validSignatures++;
                }
            }
        }
        
        return validSignatures >= GUARDIAN_QUORUM;
    }
    
    /**
     * @notice Override with guardian approval during extreme validator shortage
     * @param operation Function selector to call
     * @param target Contract to call
     * @param data Call data
     * @param signatures Guardian signatures approving this action
     */
    function guardianOverride(
        bytes4 operation,
        address target,
        bytes calldata data,
        bytes[] calldata signatures
    ) external nonReentrant {
        require(stakingContract.getValidatorCount() < CRITICAL_VALIDATOR_THRESHOLD, "Not in emergency");
        
        if (!validateGuardianSignatures(operation, target, data, signatures)) {
            revert InvalidGuardianSignatures();
        }
        
        if (executedNonces[currentNonce]) {
            revert NonceAlreadyExecuted();
        }
        
        // Mark nonce as executed
        executedNonces[currentNonce] = true;
        currentNonce++;
        
        // Execute the call
        (bool success, ) = target.call(data);
        require(success, "Guardian override failed");
        
        emit GuardianOverrideExecuted(msg.sender, operation, target);
    }
    
    /**
     * @notice Create a validator-specific proposal to adjust thresholds or incentives
     * @param description Description of the proposal
     * @param newThreshold New validator threshold if applicable
     * @param incentives Additional incentives for validators if applicable
     * @return proposalId ID of the created proposal
     */
    function createValidatorProposal(
        string calldata description,
        uint256 newThreshold,
        uint256 incentives
    ) external onlyRole(GOVERNANCE_ROLE) returns (uint256) {
        // Create proposal with validator-specific parameters
        proposalCount++;
        uint256 proposalId = proposalCount;
        
        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            description: description,
            proposalType: PROPOSAL_TYPE_VALIDATOR,
            createTime: block.timestamp,
            voteStart: block.timestamp,
            voteEnd: block.timestamp + votingDuration,
            forVotes: 0,
            againstVotes: 0,
            executed: false,
            canceled: false
        });
        
        // Store extended data specific to validator proposals
        bytes memory validatorData = abi.encode(newThreshold, incentives);
        proposalExtendedData[proposalId] = ExtendedProposalData({
            customData: validatorData,
            timelockExpiry: block.timestamp + TIMELOCK_DURATION + votingDuration
        });
        
        emit ValidatorProposalCreated(proposalId, newThreshold);
        return proposalId;
    }
    
    /**
     * @notice Initiate an emergency validator recruitment drive
     * @param incentiveAmount Amount of tokens to incentivize new validators
     * @param targetCount Target number of validators
     */
    function initiateValidatorRecruitment(
        uint256 incentiveAmount,
        uint256 targetCount
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(
            stakingContract.getValidatorCount() < REDUCED_VALIDATOR_THRESHOLD,
            "Not in validator shortage"
        );
        
        // Implementation would involve:
        // 1. Setting up incentives in the staking contract
        // 2. Allocating tokens for validator bonuses
        // 3. Setting expiration for the recruitment drive
        
        // Placeholder for actual implementation
        emit ValidatorRecruitmentInitiated(incentiveAmount, targetCount);
    }
    
    // -------------------------------------------
    // 🔹 Core Governance Functions
    // -------------------------------------------
    
    /**
     * @notice Create a new governance proposal
     * @param description Description of the proposal
     * @param proposalType Type of the proposal
     * @param callData Data to be executed if the proposal passes
     * @param targets Addresses of contracts to call
     * @return proposalId ID of the created proposal
     */
    function createProposal(
        string calldata description,
        uint8 proposalType,
        bytes[] calldata callData,
        address[] calldata targets
    ) external nonReentrant allowedProposalType(proposalType) returns (uint256) {
        if (tStakeToken.balanceOf(msg.sender) < proposalThreshold) {
            revert GovernanceThresholdNotMet();
        }
        
        // Require proper input parameters
        if (callData.length != targets.length || callData.length == 0) {
            revert InvalidParameters();
        }
        
        // Create the proposal
        proposalCount++;
        uint256 proposalId = proposalCount;
        
        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            description: description,
            proposalType: proposalType,
            createTime: block.timestamp,
            voteStart: block.timestamp,
            voteEnd: block.timestamp + votingDuration,
            forVotes: 0,
            againstVotes: 0,
            executed: false,
            canceled: false
        });
        
        // Create execution hash and store
        bytes memory proposalData = abi.encode(targets, callData);
        proposalExtendedData[proposalId] = ExtendedProposalData({
            customData: proposalData,
            timelockExpiry: block.timestamp + TIMELOCK_DURATION + votingDuration
        });
        
        // Emit proposal created event
        emit ProposalCreated(
            proposalId,
            msg.sender,
            description,
            proposalType,
            block.timestamp,
            block.timestamp + votingDuration
        );
        
        return proposalId;
    }
    
    /**
     * @notice Cast vote on an open proposal
     * @param proposalId ID of the proposal
     * @param support True for for, false for against
     */
    function castVote(uint256 proposalId, bool support) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        
        if (block.timestamp > proposal.voteEnd) {
            revert InvalidProposalState();
        }
        
        if (hasVoted[proposalId][msg.sender]) {
            revert InvalidVote();
        }
        
        uint256 weight = tStakeToken.balanceOf(msg.sender);
        if (weight < minimumHolding) {
            revert GovernanceThresholdNotMet();
        }
        
        // Record the vote
        if (support) {
            proposal.forVotes += weight;
        } else {
            proposal.againstVotes += weight;
        }
        
        hasVoted[proposalId][msg.sender] = true;
        totalVotesCast++;
        
        emit VoteCast(proposalId, msg.sender, support, weight);
    }
    
    /**
     * @notice Execute a passed proposal after timelock
     * @param proposalId ID of the proposal to execute
     */
    function executeProposal(uint256 proposalId) 
        external 
        nonReentrant 
        validatorSafetyCheck 
    {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.id == 0) {
            revert ProposalDoesNotExist();
        }
        
        if (proposal.executed) {
            revert ProposalAlreadyExecuted();
        }
        
        if (block.timestamp <= proposal.voteEnd) {
            revert ProposalNotReady();
        }
        
        // Check if the proposal passed
        bool passed = proposal.forVotes > proposal.againstVotes;
        if (!passed) {
            revert InvalidProposalState();
        }
        
        // Check timelock
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        if (block.timestamp < extData.timelockExpiry) {
            revert TimelockNotExpired();
        }
        
        // Execute based on proposal type
        if (proposal.proposalType == PROPOSAL_TYPE_FEE_UPDATE) {
            _executeFeeUpdate(proposalId);
        } else if (proposal.proposalType == PROPOSAL_TYPE_VALIDATOR) {
            _executeValidatorUpdate(proposalId);
        } else {
            // Standard proposal
            (address[] memory targets, bytes[] memory callData) = abi.decode(
                extData.customData,
                (address[], bytes[])
            );
            
            for (uint256 i = 0; i < targets.length; i++) {
                (bool success, ) = targets[i].call(callData[i]);
                require(success, "Proposal execution failed");
            }
        }
        
        // Mark as executed
        proposal.executed = true;
        totalProposalsExecuted++;
        
        emit ProposalExecuted(proposalId);
    }
    
    /**
* @notice Execute fee structure update from proposal
     * @param proposalId ID of the fee proposal
     */
    function _executeFeeUpdate(uint256 proposalId) internal {
        // Require cooldown period has passed
        if (block.timestamp < lastFeeUpdateTime + feeUpdateCooldown) {
            revert InvalidProposalState();
        }
        
        // Decode the fee proposal data
        FeeProposal memory newFees = abi.decode(
            proposalExtendedData[proposalId].customData,
            (FeeProposal)
        );
        
        // Validate fee percentages sum to 100%
        if (newFees.buybackPercentage + 
            newFees.liquidityPairingPercentage + 
            newFees.burnPercentage + 
            newFees.treasuryPercentage != 100) {
            revert InvalidParameters();
        }
        
        // Update fee structure
        currentFeeStructure = newFees;
        lastFeeUpdateTime = block.timestamp;
        
        emit FeeStructureUpdated(
            newFees.projectSubmissionFee,
            newFees.impactReportingFee,
            newFees.buybackPercentage,
            newFees.liquidityPairingPercentage,
            newFees.burnPercentage,
            newFees.treasuryPercentage
        );
    }
    
    /**
     * @notice Execute validator-specific update from proposal
     * @param proposalId ID of the validator proposal
     */
    function _executeValidatorUpdate(uint256 proposalId) internal {
        // Decode the validator proposal data
        (uint256 newThreshold, uint256 incentives) = abi.decode(
            proposalExtendedData[proposalId].customData,
            (uint256, uint256)
        );
        
        // Update validator threshold if specified
        if (newThreshold > 0) {
            bytes memory callData = abi.encodeWithSelector(
                ITerraStakeStaking.setValidatorThreshold.selector,
                newThreshold
            );
            
            (bool success, ) = address(stakingContract).call(callData);
            require(success, "Validator threshold update failed");
            
            // Update original threshold for future resets
            originalValidatorThreshold = newThreshold;
        }
        
        // Apply validator incentives if specified
        if (incentives > 0) {
            // Implementation depends on reward mechanism
            // This is a placeholder for actual incentive distribution
            bytes memory callData = abi.encodeWithSelector(
                ITerraStakeRewardDistributor.addValidatorIncentive.selector,
                incentives
            );
            
            (bool success, ) = address(rewardDistributor).call(callData);
            require(success, "Validator incentive update failed");
        }
    }
    
    /**
     * @notice Cancel a proposal
     * @param proposalId ID of the proposal to cancel
     */
    function cancelProposal(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.id == 0) {
            revert ProposalDoesNotExist();
        }
        
        // Only the proposer or an admin can cancel
        if (msg.sender != proposal.proposer && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        
        if (proposal.executed) {
            revert ProposalAlreadyExecuted();
        }
        
        proposal.canceled = true;
        
        emit ProposalCanceled(proposalId);
    }
    
    // -------------------------------------------
    // 🔹 Treasury Management Functions
    // -------------------------------------------
    
    /**
     * @notice Create a fee proposal
     * @param description Description of the fee proposal
     * @param projectSubmissionFee New project submission fee
     * @param impactReportingFee New impact reporting fee
     * @param buybackPercentage Percentage for buybacks
     * @param liquidityPairingPercentage Percentage for liquidity pairing
     * @param burnPercentage Percentage for burning
     * @param treasuryPercentage Percentage for treasury
     * @return proposalId ID of the created proposal
     */
    function createFeeProposal(
        string calldata description,
        uint256 projectSubmissionFee,
        uint256 impactReportingFee,
        uint8 buybackPercentage,
        uint8 liquidityPairingPercentage,
        uint8 burnPercentage,
        uint8 treasuryPercentage
    ) external nonReentrant allowedProposalType(PROPOSAL_TYPE_FEE_UPDATE) returns (uint256) {
        if (tStakeToken.balanceOf(msg.sender) < proposalThreshold) {
            revert GovernanceThresholdNotMet();
        }
        
        // Validate percentages add up to 100%
        if (buybackPercentage + liquidityPairingPercentage + burnPercentage + treasuryPercentage != 100) {
            revert InvalidParameters();
        }
        
        // Create the proposal
        proposalCount++;
        uint256 proposalId = proposalCount;
        
        FeeProposal memory feeProposal = FeeProposal({
            projectSubmissionFee: projectSubmissionFee,
            impactReportingFee: impactReportingFee,
            buybackPercentage: buybackPercentage,
            liquidityPairingPercentage: liquidityPairingPercentage,
            burnPercentage: burnPercentage,
            treasuryPercentage: treasuryPercentage,
            voteEnd: block.timestamp + votingDuration,
            executed: false
        });
        
        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            description: description,
            proposalType: PROPOSAL_TYPE_FEE_UPDATE,
            createTime: block.timestamp,
            voteStart: block.timestamp,
            voteEnd: block.timestamp + votingDuration,
            forVotes: 0,
            againstVotes: 0,
            executed: false,
            canceled: false
        });
        
        // Store fee proposal data
        proposalExtendedData[proposalId] = ExtendedProposalData({
            customData: abi.encode(feeProposal),
            timelockExpiry: block.timestamp + TIMELOCK_DURATION + votingDuration
        });
        
        emit ProposalCreated(
            proposalId,
            msg.sender,
            description,
            PROPOSAL_TYPE_FEE_UPDATE,
            block.timestamp,
            block.timestamp + votingDuration
        );
        
        return proposalId;
    }
    
    /**
     * @notice Perform a buyback of TSTAKE tokens
     * @param usdcAmount Amount of USDC to use for buyback
     */
    function performBuyback(uint256 usdcAmount) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        require(usdcAmount > 0, "Amount must be greater than 0");
        require(usdcToken.balanceOf(address(this)) >= usdcAmount, "Insufficient USDC balance");
        
        // Approve USDC for the router
        usdcToken.approve(address(uniswapRouter), usdcAmount);
        
        // Define the path
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(usdcToken),
            tokenOut: address(tStakeToken),
            fee: POOL_FEE,
            recipient: address(this),
            deadline: block.timestamp + 15 minutes,
            amountIn: usdcAmount,
            amountOutMinimum: 0, // Consider implementing a minimum output check
            sqrtPriceLimitX96: 0
        });
        
        // Execute the swap
        uint256 amountOut = uniswapRouter.exactInputSingle(params);
        
        emit BuybackExecuted(usdcAmount, amountOut);
    }
    
    /**
     * @notice Add liquidity to TSTAKE/USDC pair
     * @param tStakeAmount Amount of TSTAKE tokens to add
     * @param usdcAmount Amount of USDC to add
     */
    function addLiquidity(uint256 tStakeAmount, uint256 usdcAmount) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        require(liquidityPairingEnabled, "Liquidity pairing disabled");
        require(tStakeAmount > 0 && usdcAmount > 0, "Amounts must be greater than 0");
        require(tStakeToken.balanceOf(address(this)) >= tStakeAmount, "Insufficient TSTAKE balance");
        require(usdcToken.balanceOf(address(this)) >= usdcAmount, "Insufficient USDC balance");
        
        // Transfer tokens to liquidity guard for proper LP management
        tStakeToken.transfer(address(liquidityGuard), tStakeAmount);
        usdcToken.transfer(address(liquidityGuard), usdcAmount);
        
        // Call addLiquidity on the liquidity guard
        liquidityGuard.addLiquidity(tStakeAmount, usdcAmount);
        
        emit LiquidityAdded(tStakeAmount, usdcAmount);
    }
    
    /**
     * @notice Burn TSTAKE tokens from treasury
     * @param amount Amount to burn
     */
    function burnTokens(uint256 amount) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(tStakeToken.balanceOf(address(this)) >= amount, "Insufficient balance to burn");
        
        // Assuming token has a burn function, otherwise send to dead address
        (bool success, ) = address(tStakeToken).call(
            abi.encodeWithSignature("burn(uint256)", amount)
        );
        
        // If burn function doesn't exist, send to dead address
        if (!success) {
            tStakeToken.transfer(address(0xdead), amount);
        }
        
        emit TokensBurned(amount);
    }
    
    /**
     * @notice Transfer tokens from treasury to specified address
     * @param token Token address
     * @param recipient Recipient address
     * @param amount Amount to transfer
     */
    function treasuryTransfer(
        address token,
        address recipient, 
        uint256 amount
    ) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(recipient != address(0), "Invalid recipient");
        
        IERC20(token).transfer(recipient, amount);
        
        emit TreasuryTransfer(token, recipient, amount);
    }
    
    // -------------------------------------------
    // 🔹 Reward Distribution Functions
    // -------------------------------------------
    
    /**
     * @notice Initiate token halving
     */
    function initiateHalving() external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        require(block.timestamp >= lastHalvingTime + TWO_YEARS, "Halving not due yet");
        
        lastHalvingTime = block.timestamp;
        halvingEpoch++;
        
        // Update emission rate in the reward distributor
        rewardDistributor.updateEmissionRate();
        
        emit HalvingInitiated(halvingEpoch);
    }
    
    /**
     * @notice Update validator reward rate
     * @param newRewardRate New reward rate for validators
     */
    function updateValidatorRewardRate(uint256 newRewardRate) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
        validatorSafetyCheck 
    {
        rewardDistributor.setValidatorRewardRate(newRewardRate);
        
        emit ValidatorRewardRateUpdated(newRewardRate);
    }
    
    // -------------------------------------------
    // 🔹 Protocol Parameter Functions
    // -------------------------------------------
    
    /**
     * @notice Update governance parameters
     * @param newVotingDuration New voting duration
     * @param newProposalThreshold New proposal threshold
     * @param newMinimumHolding New minimum holding requirement
     */
    function updateGovernanceParameters(
        uint256 newVotingDuration,
        uint256 newProposalThreshold,
        uint256 newMinimumHolding
    ) external onlyRole(GOVERNANCE_ROLE) validatorSafetyCheck {
        // Require reasonable voting duration
        require(newVotingDuration >= 1 days && newVotingDuration <= 14 days, "Invalid voting duration");
        
        votingDuration = newVotingDuration;
        proposalThreshold = newProposalThreshold;
        minimumHolding = newMinimumHolding;
        
        emit GovernanceParametersUpdated(
            newVotingDuration,
            newProposalThreshold,
            newMinimumHolding
        );
    }
    
    /**
     * @notice Update treasury address
     * @param newTreasuryWallet New treasury wallet address
     */
    function updateTreasuryWallet(address newTreasuryWallet) external onlyRole(GOVERNANCE_ROLE) {
        require(newTreasuryWallet != address(0), "Invalid treasury address");
        
        treasuryWallet = newTreasuryWallet;
        
        emit TreasuryWalletUpdated(newTreasuryWallet);
    }
    
    /**
     * @notice Toggle liquidity pairing
     * @param enabled Whether liquidity pairing is enabled
     */
    function toggleLiquidityPairing(bool enabled) external onlyRole(GOVERNANCE_ROLE) {
        liquidityPairingEnabled = enabled;
        
        emit LiquidityPairingToggled(enabled);
    }
    
    // -------------------------------------------
    // 🔹 Governance Penalty Functions
    // -------------------------------------------
    
    /**
     * @notice Penalize a governor for violating rules
     * @param governor Address of the governor to penalize
     * @param reason Reason for the penalty
     */
    function penalizeGovernor(address governor, string calldata reason) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        require(!penalizedGovernors[governor], "Governor already penalized");
        require(hasRole(GOVERNANCE_ROLE, governor), "Address is not a governor");
        
        penalizedGovernors[governor] = true;
        
        // If staking system allows, implement penalty to stake
        if (address(stakingContract) != address(0)) {
            uint256 stake = stakingContract.getValidatorStake(governor);
            if (stake > 0) {
                uint256 penaltyAmount = (stake * PENALTY_FOR_VIOLATION) / 100;
                stakingContract.slashValidator(governor, penaltyAmount);
            }
        }
        
        // Revoke governance role
        _revokeRole(GOVERNANCE_ROLE, governor);
        
        emit GovernorPenalized(governor, reason);
    }
    
    /**
 * @notice Restore a penalized governor
     * @param governor Address of the governor to restore
     */
    function restoreGovernor(address governor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(penalizedGovernors[governor], "Governor not penalized");
        
        penalizedGovernors[governor] = false;
        _grantRole(GOVERNANCE_ROLE, governor);
        
        emit GovernorRestored(governor);
    }
    
    // -------------------------------------------
    // 🔹 View Functions
    // -------------------------------------------
    
    /**
     * @notice Get details of a proposal
     * @param proposalId ID of the proposal
     * @return Proposal details
     */
    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }
    
    /**
     * @notice Get extended data for a proposal
     * @param proposalId ID of the proposal
     * @return Extended proposal data
     */
    function getProposalExtendedData(uint256 proposalId) external view returns (ExtendedProposalData memory) {
        return proposalExtendedData[proposalId];
    }
    
    /**
     * @notice Check if an account has voted on a proposal
     * @param proposalId ID of the proposal
     * @param account Account to check
     * @return Whether the account has voted
     */
    function hasAccountVoted(uint256 proposalId, address account) external view returns (bool) {
        return hasVoted[proposalId][account];
    }
    
    /**
     * @notice Get the current fee structure
     * @return Current fee structure
     */
    function getCurrentFeeStructure() external view returns (FeeProposal memory) {
        return currentFeeStructure;
    }
    
    /**
     * @notice Get the next halving time
     * @return Timestamp of the next halving
     */
    function getNextHalvingTime() external view returns (uint256) {
        return lastHalvingTime + TWO_YEARS;
    }
    
    /**
     * @notice Get validator safety details
     * @return Current governance tier, validator count, bootstrap status, and threshold details
     */
    function getValidatorSafetyStatus() external view returns (
        uint8 tier,
        uint256 validatorCount,
        bool isBootstrapActive,
        uint256 thresholdEndTime,
        uint256 originalThreshold
    ) {
        validatorCount = stakingContract.getValidatorCount();
        
        return (
            governanceTier,
            validatorCount,
            bootstrapMode,
            temporaryThresholdEndTime,
            originalValidatorThreshold
        );
    }
    
    /**
     * @notice Check if guardian quorum is achievable
     * @return Whether guardian quorum can be achieved with current guardians
     */
    function isGuardianQuorumAchievable() external view returns (bool) {
        return guardianCount >= GUARDIAN_QUORUM;
    }
    
    /**
     * @notice Check if an address is a guardian
     * @param account Address to check
     * @return Whether the address is a guardian
     */
    function isGuardian(address account) external view returns (bool) {
        return guardianCouncil[account];
    }
    
    // -------------------------------------------
    // 🔹 Emergency Functions
    // -------------------------------------------
    
    /**
     * @notice Emergency pause of critical protocol functions
     * @param contractAddresses Addresses of contracts to pause
     */
    function emergencyPause(address[] calldata contractAddresses) 
        external 
        onlyRole(GUARDIAN_ROLE) 
    {
        for (uint256 i = 0; i < contractAddresses.length; i++) {
            // Try to call pause() on the target contract
            (bool success, ) = contractAddresses[i].call(
                abi.encodeWithSignature("pause()")
            );
            
            require(success, "Failed to pause contract");
        }
        
        emit EmergencyPauseActivated(contractAddresses);
    }
    
    /**
     * @notice Emergency unpause of critical protocol functions
     * @param contractAddresses Addresses of contracts to unpause
     */
    function emergencyUnpause(address[] calldata contractAddresses) 
        external 
        onlyRole(GUARDIAN_ROLE) 
    {
        for (uint256 i = 0; i < contractAddresses.length; i++) {
            // Try to call unpause() on the target contract
            (bool success, ) = contractAddresses[i].call(
                abi.encodeWithSignature("unpause()")
            );
            
            require(success, "Failed to unpause contract");
        }
        
        emit EmergencyPauseDeactivated(contractAddresses);
    }
    
    /**
     * @notice Emergency recovery of tokens accidentally sent to contract
     * @param token Token address
     * @param amount Amount to recover
     * @param recipient Recipient address
     */
    function emergencyRecoverTokens(
        address token,
        uint256 amount,
        address recipient
    ) external onlyRole(GUARDIAN_ROLE) {
        require(recipient != address(0), "Invalid recipient");
        
        IERC20(token).transfer(recipient, amount);
        
        emit EmergencyTokenRecovery(token, amount, recipient);
    }
    
    // -------------------------------------------
    // 🔹 Receive Function
    // -------------------------------------------
    
    /**
     * @notice Allow contract to receive ETH
     */
    receive() external payable {
        emit EthReceived(msg.sender, msg.value);
    }
}
