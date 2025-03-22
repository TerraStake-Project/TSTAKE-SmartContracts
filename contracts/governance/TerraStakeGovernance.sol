// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
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
import "../interfaces/ITerraStakeTreasuryManager.sol";
import "../interfaces/ITerraStakeValidatorSafety.sol";
import "../interfaces/ITerraStakeGuardianCouncil.sol";

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

    // Custom errors
    error Unauthorized();
    error InvalidParameters();
    error InvalidProposalState();
    error ProposalNotActive();
    error ProposalExpired();
    error AlreadyVoted();
    error InsufficientVotingPower();
    error InvalidTargetCount();
    error EmptyProposal();
    error TooManyActions();
    error InvalidState();
    error GovernanceThresholdNotMet();
    error ProposalNotReady();
    error ProposalDoesNotExist();
    error InvalidVote();
    error TimelockNotExpired();
    error ProposalAlreadyExecuted();
    error GovernanceViolation();
    error InsufficientValidators();
    error ProposalTypeNotAllowed();
    error InvalidGuardianSignatures();
    error NonceAlreadyExecuted();

    // Packed storage
    struct GovernanceParams {
        uint48 votingDelay;          // Added for interface
        uint48 votingPeriod;
        uint48 executionDelay;       // Added for interface
        uint48 executionPeriod;      // Added for interface
        uint48 feeUpdateCooldown;
        uint96 proposalThreshold;
        uint96 minimumHolding;
        address treasuryWallet;
    }

    struct SystemState {
        uint48 lastFeeUpdateTime;
        uint48 lastHalvingTime;
        uint32 proposalCount;
        uint32 totalVotesCast;
        uint32 totalProposalsExecuted;
        uint32 halvingEpoch;
        uint32 currentNonce;
        bool liquidityPairingEnabled;
    }

    // -------------------------------------------
    //  Constants
    // -------------------------------------------
    bytes32 public constant override GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant override UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant override GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant override VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    
    uint8 public constant PROPOSAL_TYPE_STANDARD = 0;
    uint8 public constant PROPOSAL_TYPE_FEE_UPDATE = 1;
    uint8 public constant PROPOSAL_TYPE_PARAM_UPDATE = 2;
    uint8 public constant PROPOSAL_TYPE_CONTRACT_UPDATE = 3;
    uint8 public constant PROPOSAL_TYPE_PENALTY = 4;
    uint8 public constant PROPOSAL_TYPE_EMERGENCY = 5;
    uint8 public constant PROPOSAL_TYPE_VALIDATOR = 6;
    
    uint256 public constant TIMELOCK_DURATION = 2 days;
    uint256 public constant PENALTY_FOR_VIOLATION = 5;
    uint256 public constant TWO_YEARS = 730 days;
    uint24 public constant POOL_FEE = 3000;
    
    uint256 public constant CRITICAL_VALIDATOR_THRESHOLD = 3;
    uint256 public constant REDUCED_VALIDATOR_THRESHOLD = 7;
    uint256 public constant OPTIMAL_VALIDATOR_THRESHOLD = 15;
    uint8 public constant GUARDIAN_QUORUM = 3;
    uint8 public constant MAX_ACTIONS = 10; // Added to prevent gas limit issues
    
    // -------------------------------------------
    //  State Variables
    // -------------------------------------------
    ITerraStakeStaking public stakingContract;
    ITerraStakeRewardDistributor public rewardDistributor;
    ITerraStakeLiquidityGuard public liquidityGuard;
    ISwapRouter public uniswapRouter;
    IERC20 public override tStakeToken;
    IERC20 public usdcToken;
    
    ITerraStakeTreasuryManager public override treasuryManager;
    ITerraStakeValidatorSafety public override validatorSafety;
    ITerraStakeGuardianCouncil public override guardianCouncil;
    
    GovernanceParams public govParams;
    SystemState public systemState;
    FeeProposal public currentFeeStructure;
    
    mapping(uint256 => Proposal) public override proposals;
    mapping(uint256 => ExtendedProposalData) public proposalExtendedData;
    mapping(uint256 => mapping(address => Receipt)) public override receipts;
    mapping(bytes32 => bool) public executedHashes;
    mapping(address => bool) public penalizedGovernors;
    mapping(uint256 => bool) public executedNonces;
    mapping(address => uint256) public override latestProposalIds;
    
    uint8 public governanceTier;
    bool public bootstrapMode;
    uint48 public bootstrapEndTime;
    uint48 public temporaryThresholdEndTime;
    uint96 public originalValidatorThreshold;
    mapping(address => bool) public guardianCouncilMembers;
    uint8 public guardianCount;
    
    bool public paused; // Added for pause/unpause
    
    // -------------------------------------------
    //  Modifiers
    // -------------------------------------------
    modifier validatorSafetyCheck() {
        if (!bootstrapMode && stakingContract.getValidatorCount() < CRITICAL_VALIDATOR_THRESHOLD) {
            revert InsufficientValidators();
        }
        _;
    }
    
    modifier allowedProposalType(uint8 proposalType) {
        if (!isProposalTypeAllowed(proposalType)) {
            revert ProposalTypeNotAllowed();
        }
        _;
    }
    
    modifier whenNotPaused() {
        if (paused) revert InvalidState();
        _;
    }
    
    // -------------------------------------------
    //  Initializer & Upgrade Control
    // -------------------------------------------
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    function initialize(
        address _treasuryManager,
        address _validatorSafety,
        address _guardianCouncil,
        address _tStakeToken,
        address _initialAdmin
    ) external override initializer {
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        _grantRole(UPGRADER_ROLE, _initialAdmin);
        _grantRole(GOVERNANCE_ROLE, _initialAdmin);
        _grantRole(GUARDIAN_ROLE, _initialAdmin);
        
        treasuryManager = ITerraStakeTreasuryManager(_treasuryManager);
        validatorSafety = ITerraStakeValidatorSafety(_validatorSafety);
        guardianCouncil = ITerraStakeGuardianCouncil(_guardianCouncil);
        tStakeToken = IERC20(_tStakeToken);
        
        stakingContract = ITerraStakeStaking(_validatorSafety); // Assuming validatorSafety is staking contract
        rewardDistributor = ITerraStakeRewardDistributor(_treasuryManager); // Assuming treasuryManager handles rewards
        liquidityGuard = ITerraStakeLiquidityGuard(_treasuryManager); // Assuming treasuryManager handles liquidity
        usdcToken = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // Example USDC address
        uniswapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564); // Example Uniswap V3 router
        
        uint48 currentTime = uint48(block.timestamp);
        govParams = GovernanceParams({
            votingDelay: 1 days,
            votingPeriod: 5 days,
            executionDelay: TIMELOCK_DURATION,
            executionPeriod: 7 days,
            feeUpdateCooldown: 30 days,
            proposalThreshold: 1000 * 10**18,
            minimumHolding: 100 * 10**18,
            treasuryWallet: _initialAdmin
        });
        
        systemState = SystemState({
            lastFeeUpdateTime: currentTime,
            lastHalvingTime: currentTime,
            proposalCount: 0,
            totalVotesCast: 0,
            totalProposalsExecuted: 0,
            halvingEpoch: 0,
            currentNonce: 1,
            liquidityPairingEnabled: true
        });
        
        currentFeeStructure = FeeProposal({
            projectSubmissionFee: 500 * 10**6,
            impactReportingFee: 100 * 10**6,
            buybackPercentage: 30,
            liquidityPairingPercentage: 30,
            burnPercentage: 20,
            treasuryPercentage: 20,
            voteEnd: 0,
            executed: true
        });
        
        bootstrapMode = true;
        bootstrapEndTime = currentTime + 90 days;
        guardianCount = 1;
        guardianCouncilMembers[_initialAdmin] = true;
        originalValidatorThreshold = stakingContract.validatorThreshold();
        governanceTier = 0;
    }
    
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
    
    // -------------------------------------------
    //  Proposal Creation and Management
    // -------------------------------------------
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        uint8 proposalType
    ) external override nonReentrant allowedProposalType(proposalType) whenNotPaused returns (uint256) {
        if (tStakeToken.balanceOf(msg.sender) < govParams.proposalThreshold) revert GovernanceThresholdNotMet();
        if (targets.length != values.length || targets.length != calldatas.length || targets.length == 0) revert InvalidParameters();
        if (targets.length > MAX_ACTIONS) revert TooManyActions();
        
        uint32 proposalId = ++systemState.proposalCount;
        uint256 voteStart = block.timestamp + govParams.votingDelay;
        uint256 voteEnd = voteStart + govParams.votingPeriod;
        
        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            description: description,
            proposalType: proposalType,
            createTime: block.timestamp,
            voteStart: voteStart,
            voteEnd: voteEnd,
            forVotes: 0,
            againstVotes: 0,
            executed: false,
            canceled: false
        });
        
        proposalExtendedData[proposalId] = ExtendedProposalData({
            customData: abi.encode(targets, values, calldatas),
            timelockExpiry: voteEnd + govParams.executionDelay
        });
        
        latestProposalIds[msg.sender] = proposalId;
        
        emit ProposalCreated(proposalId, msg.sender, description, proposalType, voteStart, voteEnd);
        return proposalId;
    }
    
    function castVote(uint256 proposalId, uint8 support, string memory reason) 
        external 
        override 
        nonReentrant 
        whenNotPaused 
    {
        if (support > uint8(VoteType.Abstain)) revert InvalidVote();
        Proposal storage proposal = proposals[proposalId];
        if (block.timestamp < proposal.voteStart || block.timestamp > proposal.voteEnd) revert ProposalNotActive();
        if (receipts[proposalId][msg.sender].hasVoted) revert AlreadyVoted();
        
        uint256 weight = tStakeToken.balanceOf(msg.sender);
        if (weight < govParams.minimumHolding) revert InsufficientVotingPower();
        
        VoteType voteType = VoteType(support);
        receipts[proposalId][msg.sender] = Receipt(true, voteType, weight);
        
        if (voteType == VoteType.For) proposal.forVotes += weight;
        else if (voteType == VoteType.Against) proposal.againstVotes += weight;
        
        unchecked { systemState.totalVotesCast++; }
        emit VoteCast(proposalId, msg.sender, voteType == VoteType.For, weight);
    }
    
    function validatorSupport(uint256 proposalId, bool support) external override whenNotPaused {
        if (!hasRole(VALIDATOR_ROLE, msg.sender)) revert Unauthorized();
        Proposal storage proposal = proposals[proposalId];
        if (block.timestamp < proposal.voteStart || block.timestamp > proposal.voteEnd) revert ProposalNotActive();
        
        emit ValidatorSupport(msg.sender, proposalId, support);
    }
    
    function queueProposal(uint256 proposalId) external override nonReentrant whenNotPaused {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.id == 0) revert ProposalDoesNotExist();
        if (proposal.executed || proposal.canceled) revert InvalidProposalState();
        if (block.timestamp <= proposal.voteEnd) revert ProposalNotReady();
        if (proposal.forVotes <= proposal.againstVotes) revert InvalidProposalState();
        
        emit ProposalQueued(proposalId, block.timestamp);
    }
    
    function executeProposal(uint256 proposalId) 
        external 
        override 
        nonReentrant 
        validatorSafetyCheck 
        whenNotPaused 
    {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.id == 0) revert ProposalDoesNotExist();
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (block.timestamp <= proposal.voteEnd) revert ProposalNotReady();
        if (proposal.forVotes <= proposal.againstVotes) revert InvalidProposalState();
        
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        if (block.timestamp < extData.timelockExpiry) revert TimelockNotExpired();
        if (block.timestamp > extData.timelockExpiry + govParams.executionPeriod) revert ProposalExpired();
        
        if (proposal.proposalType == PROPOSAL_TYPE_FEE_UPDATE) {
            _executeFeeUpdate(proposalId);
        } else if (proposal.proposalType == PROPOSAL_TYPE_VALIDATOR) {
            _executeValidatorUpdate(proposalId);
        } else {
            (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = 
                abi.decode(extData.customData, (address[], uint256[], bytes[]));
            
            for (uint256 i = 0; i < targets.length; i++) {
                (bool success, ) = targets[i].call{value: values[i]}(calldatas[i]);
                if (!success) revert InvalidParameters();
            }
        }
        
        proposal.executed = true;
        unchecked { systemState.totalProposalsExecuted++; }
        emit ProposalExecuted(proposalId);
    }
    
    function cancelProposal(uint256 proposalId) external override whenNotPaused {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.id == 0) revert ProposalDoesNotExist();
        if (msg.sender != proposal.proposer && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert Unauthorized();
        if (proposal.executed) revert ProposalAlreadyExecuted();
        
        proposal.canceled = true;
        emit ProposalCanceled(proposalId);
    }
    
    // -------------------------------------------
    //  Governance Parameter Management
    // -------------------------------------------
    function updateProposalThreshold(uint256 newThreshold) external override onlyRole(GOVERNANCE_ROLE) {
        govParams.proposalThreshold = uint96(newThreshold);
        emit GovernanceParametersUpdated("proposalThreshold", govParams.proposalThreshold, newThreshold);
    }
    
    function updateVotingDelay(uint256 newVotingDelay) external override onlyRole(GOVERNANCE_ROLE) {
        if (newVotingDelay > 7 days) revert InvalidParameters();
        uint256 oldValue = govParams.votingDelay;
        govParams.votingDelay = uint48(newVotingDelay);
        emit GovernanceParametersUpdated("votingDelay", oldValue, newVotingDelay);
    }
    
    function updateVotingPeriod(uint256 newVotingPeriod) external override onlyRole(GOVERNANCE_ROLE) {
        if (newVotingPeriod < 1 days || newVotingPeriod > 14 days) revert InvalidParameters();
        uint256 oldValue = govParams.votingPeriod;
        govParams.votingPeriod = uint48(newVotingPeriod);
        emit GovernanceParametersUpdated("votingPeriod", oldValue, newVotingPeriod);
    }
    
    function updateExecutionDelay(uint256 newExecutionDelay) external override onlyRole(GOVERNANCE_ROLE) {
        uint256 oldValue = govParams.executionDelay;
        govParams.executionDelay = uint48(newExecutionDelay);
        emit GovernanceParametersUpdated("executionDelay", oldValue, newExecutionDelay);
    }
    
    function updateExecutionPeriod(uint256 newExecutionPeriod) external override onlyRole(GOVERNANCE_ROLE) {
        if (newExecutionPeriod < 1 days) revert InvalidParameters();
        uint256 oldValue = govParams.executionPeriod;
        govParams.executionPeriod = uint48(newExecutionPeriod);
        emit GovernanceParametersUpdated("executionPeriod", oldValue, newExecutionPeriod);
    }
    
    // -------------------------------------------
    //  Module Management
    // -------------------------------------------
    function updateTreasuryManager(address newTreasuryManager) external override onlyRole(GOVERNANCE_ROLE) {
        if (newTreasuryManager == address(0)) revert InvalidParameters();
        address oldManager = address(treasuryManager);
        treasuryManager = ITerraStakeTreasuryManager(newTreasuryManager);
        rewardDistributor = ITerraStakeRewardDistributor(newTreasuryManager);
        liquidityGuard = ITerraStakeLiquidityGuard(newTreasuryManager);
        emit ModuleUpdated("treasuryManager", oldManager, newTreasuryManager);
    }
    
    function updateValidatorSafety(address newValidatorSafety) external override onlyRole(GOVERNANCE_ROLE) {
        if (newValidatorSafety == address(0)) revert InvalidParameters();
        address oldSafety = address(validatorSafety);
        validatorSafety = ITerraStakeValidatorSafety(newValidatorSafety);
        stakingContract = ITerraStakeStaking(newValidatorSafety);
        emit ModuleUpdated("validatorSafety", oldSafety, newValidatorSafety);
    }
    
    function updateGuardianCouncil(address newGuardianCouncil) external override onlyRole(GOVERNANCE_ROLE) {
        if (newGuardianCouncil == address(0)) revert InvalidParameters();
        address oldCouncil = address(guardianCouncil);
        guardianCouncil = ITerraStakeGuardianCouncil(newGuardianCouncil);
        emit ModuleUpdated("guardianCouncil", oldCouncil, newGuardianCouncil);
    }
    
    // -------------------------------------------
    //  Validator Safety Mechanisms
    // -------------------------------------------
    function updateGovernanceTier() public returns (uint8) {
        uint256 validatorCount = stakingContract.getValidatorCount();
        uint8 newTier = validatorCount >= OPTIMAL_VALIDATOR_THRESHOLD ? 2 :
                       validatorCount >= CRITICAL_VALIDATOR_THRESHOLD ? 1 : 0;
        
        if (newTier != governanceTier) {
            governanceTier = newTier;
            emit GovernanceTierUpdated(newTier, validatorCount);
        }
        return newTier;
    }
    
    function isProposalTypeAllowed(uint8 proposalType) public view returns (bool) {
        uint256 validatorCount = stakingContract.getValidatorCount();
        uint8 effectiveTier = validatorCount >= OPTIMAL_VALIDATOR_THRESHOLD ? 2 :
                            validatorCount >= CRITICAL_VALIDATOR_THRESHOLD ? 1 : 0;
        
        if (effectiveTier == 0) {
            return proposalType == PROPOSAL_TYPE_EMERGENCY ||
                   proposalType == PROPOSAL_TYPE_VALIDATOR ||
                   proposalType == PROPOSAL_TYPE_PENALTY;
        }
        return effectiveTier == 1 ? proposalType != PROPOSAL_TYPE_CONTRACT_UPDATE : true;
    }
    
    function setValidatorBootstrap(uint256 duration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!bootstrapMode) revert InvalidProposalState();
        bootstrapEndTime = uint48(block.timestamp) + uint48(duration);
        emit BootstrapModeConfigured(duration);
    }
    
    function exitBootstrapMode() external {
        if (!bootstrapMode) revert InvalidProposalState();
        if (block.timestamp <= bootstrapEndTime && 
            stakingContract.getValidatorCount() < OPTIMAL_VALIDATOR_THRESHOLD) {
            revert InvalidProposalState();
        }
        bootstrapMode = false;
        emit BootstrapModeExited();
    }

    function emergencyReduceValidatorThreshold(uint256 newThreshold, uint256 duration) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        if (stakingContract.getValidatorCount() >= CRITICAL_VALIDATOR_THRESHOLD) revert InvalidProposalState();
        
        if (temporaryThresholdEndTime == 0) originalValidatorThreshold = stakingContract.validatorThreshold();
        
        (bool success, ) = address(stakingContract).call(
            abi.encodeWithSelector(ITerraStakeStaking.setValidatorThreshold.selector, newThreshold)
        );
        if (!success) revert InvalidParameters();
        
        temporaryThresholdEndTime = uint48(block.timestamp + duration);
        emit EmergencyThresholdReduction(newThreshold, duration);
        emit ThresholdResetScheduled(temporaryThresholdEndTime);
    }
    
    function resetValidatorThreshold() external {
        if (temporaryThresholdEndTime == 0 || block.timestamp < temporaryThresholdEndTime) revert InvalidProposalState();
        
        (bool success, ) = address(stakingContract).call(
            abi.encodeWithSelector(ITerraStakeStaking.setValidatorThreshold.selector, originalValidatorThreshold)
        );
        if (!success) revert InvalidParameters();
        
        temporaryThresholdEndTime = 0;
    }
    
    function checkValidatorHealth() external {
        uint256 validatorCount = stakingContract.getValidatorCount();
        uint256 totalStaked = stakingContract.totalStakedTokens();
        emit ValidatorHealthCheck(validatorCount, totalStaked, 
            validatorCount > 0 ? totalStaked / validatorCount : 0, governanceTier);
    }
    
    function addGuardian(address guardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (guardian == address(0) || guardianCouncilMembers[guardian]) revert InvalidParameters();
        
        guardianCouncilMembers[guardian] = true;
        unchecked { guardianCount++; }
        _grantRole(GUARDIAN_ROLE, guardian);
        emit GuardianAdded(guardian);
    }
    
    function removeGuardian(address guardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!guardianCouncilMembers[guardian] || guardianCount <= 1) revert InvalidParameters();
        
        guardianCouncilMembers[guardian] = false;
        unchecked { guardianCount--; }
        _revokeRole(GUARDIAN_ROLE, guardian);
        emit GuardianRemoved(guardian);
    }
    
    function validateGuardianSignatures(
        bytes4 operation,
        address target,
        bytes calldata data,
        bytes[] calldata signatures
    ) public view returns (bool) {
        if (signatures.length < GUARDIAN_QUORUM) return false;
        
        bytes32 messageHash = keccak256(abi.encodePacked(operation, target, data, systemState.currentNonce))
            .toEthSignedMessageHash();
        
        address[GUARDIAN_QUORUM] memory signers;
        uint256 validCount;
        
        for (uint256 i = 0; i < signatures.length && validCount < GUARDIAN_QUORUM; i++) {
            address signer = messageHash.recover(signatures[i]);
            if (guardianCouncilMembers[signer]) {
                bool isUnique = true;
                for (uint256 j = 0; j < validCount; j++) {
                    if (signers[j] == signer) {
                        isUnique = false;
                        break;
                    }
                }
                if (isUnique) signers[validCount++] = signer;
            }
        }
        return validCount >= GUARDIAN_QUORUM;
    }
    
    function guardianOverride(
        bytes4 operation,
        address target,
        bytes calldata data,
        bytes[] calldata signatures
    ) external nonReentrant {
        if (stakingContract.getValidatorCount() >= CRITICAL_VALIDATOR_THRESHOLD) revert InvalidProposalState();
        if (!validateGuardianSignatures(operation, target, data, signatures)) revert InvalidGuardianSignatures();
        if (executedNonces[systemState.currentNonce]) revert NonceAlreadyExecuted();
        
        executedNonces[systemState.currentNonce] = true;
        unchecked { systemState.currentNonce++; }
        
        (bool success, ) = target.call(data);
        if (!success) revert InvalidParameters();
        
        emit GuardianOverrideExecuted(msg.sender, operation, target);
    }
    
    function createValidatorProposal(string calldata description, uint256 newThreshold, uint256 incentives) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
        returns (uint256) 
    {
        uint32 proposalId = ++systemState.proposalCount;
        uint256 voteStart = block.timestamp + govParams.votingDelay;
        uint256 voteEnd = voteStart + govParams.votingPeriod;
        
        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            description: description,
            proposalType: PROPOSAL_TYPE_VALIDATOR,
            createTime: block.timestamp,
            voteStart: voteStart,
            voteEnd: voteEnd,
            forVotes: 0,
            againstVotes: 0,
            executed: false,
            canceled: false
        });
        
        proposalExtendedData[proposalId] = ExtendedProposalData({
            customData: abi.encode(newThreshold, incentives),
            timelockExpiry: voteEnd + govParams.executionDelay
        });
        
        emit ValidatorProposalCreated(proposalId, newThreshold);
        return proposalId;
    }
    
    function initiateValidatorRecruitment(uint256 incentiveAmount, uint256 targetCount) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        if (stakingContract.getValidatorCount() >= REDUCED_VALIDATOR_THRESHOLD) revert InvalidProposalState();
        emit ValidatorRecruitmentInitiated(incentiveAmount, targetCount);
    }
    
    // -------------------------------------------
    //  Treasury Management Functions
    // -------------------------------------------
    function createFeeProposal(
        string calldata description,
        uint256 projectSubmissionFee,
        uint256 impactReportingFee,
        uint8 buybackPercentage,
        uint8 liquidityPairingPercentage,
        uint8 burnPercentage,
        uint8 treasuryPercentage
    ) external nonReentrant allowedProposalType(PROPOSAL_TYPE_FEE_UPDATE) returns (uint256) {
        if (tStakeToken.balanceOf(msg.sender) < govParams.proposalThreshold) revert GovernanceThresholdNotMet();
        if (buybackPercentage + liquidityPairingPercentage + burnPercentage + treasuryPercentage != 100) {
            revert InvalidParameters();
        }
        
        uint32 proposalId = ++systemState.proposalCount;
        uint256 voteStart = block.timestamp + govParams.votingDelay;
        uint256 voteEnd = voteStart + govParams.votingPeriod;
        
        FeeProposal memory feeProposal = FeeProposal({
            projectSubmissionFee: projectSubmissionFee,
            impactReportingFee: impactReportingFee,
            buybackPercentage: buybackPercentage,
            liquidityPairingPercentage: liquidityPairingPercentage,
            burnPercentage: burnPercentage,
            treasuryPercentage: treasuryPercentage,
            voteEnd: voteEnd,
            executed: false
        });
        
        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            description: description,
            proposalType: PROPOSAL_TYPE_FEE_UPDATE,
            createTime: block.timestamp,
            voteStart: voteStart,
            voteEnd: voteEnd,
            forVotes: 0,
            againstVotes: 0,
            executed: false,
            canceled: false
        });
        
        proposalExtendedData[proposalId] = ExtendedProposalData({
            customData: abi.encode(feeProposal),
            timelockExpiry: voteEnd + govParams.executionDelay
        });
        
        emit ProposalCreated(proposalId, msg.sender, description, PROPOSAL_TYPE_FEE_UPDATE, voteStart, voteEnd);
        return proposalId;
    }
    
    function _executeFeeUpdate(uint256 proposalId) internal {
        if (block.timestamp < systemState.lastFeeUpdateTime + govParams.feeUpdateCooldown) revert InvalidProposalState();
        
        FeeProposal memory newFees = abi.decode(proposalExtendedData[proposalId].customData, (FeeProposal));
        
        if (newFees.buybackPercentage + newFees.liquidityPairingPercentage + 
            newFees.burnPercentage + newFees.treasuryPercentage != 100) {
            revert InvalidParameters();
        }
        
        currentFeeStructure = newFees;
        systemState.lastFeeUpdateTime = uint48(block.timestamp);
        emit FeeStructureUpdated(newFees.projectSubmissionFee, newFees.impactReportingFee,
            newFees.buybackPercentage, newFees.liquidityPairingPercentage,
            newFees.burnPercentage, newFees.treasuryPercentage);
    }
    
    function _executeValidatorUpdate(uint256 proposalId) internal {
        (uint256 newThreshold, uint256 incentives) = abi.decode(
            proposalExtendedData[proposalId].customData, (uint256, uint256));
        
        if (newThreshold > 0) {
            (bool success, ) = address(stakingContract).call(
                abi.encodeWithSelector(ITerraStakeStaking.setValidatorThreshold.selector, newThreshold));
            if (!success) revert InvalidParameters();
            originalValidatorThreshold = uint96(newThreshold);
        }
        
        if (incentives > 0) {
            (bool success, ) = address(rewardDistributor).call(
                abi.encodeWithSelector(ITerraStakeRewardDistributor.addValidatorIncentive.selector, incentives));
            if (!success) revert InvalidParameters();
        }
    }
    
    function performBuyback(uint256 usdcAmount) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        if (usdcAmount == 0 || usdcToken.balanceOf(address(this)) < usdcAmount) revert InvalidParameters();
        
        usdcToken.approve(address(uniswapRouter), usdcAmount);
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(usdcToken),
            tokenOut: address(tStakeToken),
            fee: POOL_FEE,
            recipient: address(this),
            deadline: block.timestamp + 15 minutes,
            amountIn: usdcAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        
        uint256 amountOut = uniswapRouter.exactInputSingle(params);
        emit BuybackExecuted(usdcAmount, amountOut);
    }
    
    function addLiquidity(uint256 tStakeAmount, uint256 usdcAmount) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        if (!systemState.liquidityPairingEnabled || tStakeAmount == 0 || usdcAmount == 0 ||
            tStakeToken.balanceOf(address(this)) < tStakeAmount ||
            usdcToken.balanceOf(address(this)) < usdcAmount) {
            revert InvalidParameters();
        }
        
        tStakeToken.transfer(address(liquidityGuard), tStakeAmount);
        usdcToken.transfer(address(liquidityGuard), usdcAmount);
        liquidityGuard.addLiquidity(tStakeAmount, usdcAmount);
        emit LiquidityAdded(tStakeAmount, usdcAmount);
    }
    
    function burnTokens(uint256 amount) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        if (amount == 0 || tStakeToken.balanceOf(address(this)) < amount) revert InvalidParameters();
        
        (bool success, ) = address(tStakeToken).call(abi.encodeWithSignature("burn(uint256)", amount));
        if (!success) tStakeToken.transfer(address(0xdead), amount);
        emit TokensBurned(amount);
    }
    
    function treasuryTransfer(address token, address recipient, uint256 amount) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
        nonReentrant 
    {
        if (amount == 0 || recipient == address(0)) revert InvalidParameters();
        IERC20(token).transfer(recipient, amount);
        emit TreasuryTransfer(token, recipient, amount);
    }
    
    // -------------------------------------------
    //  Reward Distribution Functions
    // -------------------------------------------
    function applyHalving() external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        if (block.timestamp < systemState.lastHalvingTime + TWO_YEARS) revert InvalidProposalState();
        
        systemState.lastHalvingTime = uint48(block.timestamp);
        unchecked { systemState.halvingEpoch++; }
        rewardDistributor.updateEmissionRate();
        emit HalvingInitiated(systemState.halvingEpoch);
    }

    function recordVote(uint256 proposalId, address voter, uint256 votingPower, bool support) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];

        // Validate proposal existence and voting period
        require(proposal.voteStart > 0, "Proposal does not exist");
        require(block.timestamp >= proposal.voteStart && block.timestamp <= proposal.voteEnd, "Not in voting period");

        // Validate voter eligibility
        require(!proposal.hasVoted[voter], "Already voted");
        require(votingPower >= govParams.minimumHolding, "Insufficient token balance to vote");

        // Record the vote
        if (support) {
            proposal.forVotes += votingPower;
        } else {
            proposal.againstVotes += votingPower;
        }

        // Mark voter as having voted
        proposal.hasVoted[voter] = true;
        systemState.totalVotesCast++;
    }
    
    function updateValidatorRewardRate(uint256 newRewardRate) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
        validatorSafetyCheck 
    {
        rewardDistributor.setValidatorRewardRate(newRewardRate);
        emit ValidatorRewardRateUpdated(newRewardRate);
    }
    
    // -------------------------------------------
    //  Protocol Parameter Functions
    // -------------------------------------------
    function updateTreasuryWallet(address newTreasuryWallet) external onlyRole(GOVERNANCE_ROLE) {
        if (newTreasuryWallet == address(0)) revert InvalidParameters();
        govParams.treasuryWallet = newTreasuryWallet;
        emit TreasuryWalletUpdated(newTreasuryWallet);
    }
    
    function toggleLiquidityPairing(bool enabled) external onlyRole(GOVERNANCE_ROLE) {
        systemState.liquidityPairingEnabled = enabled;
        emit LiquidityPairingToggled(enabled);
    }
    
    // -------------------------------------------
    //  Governance Penalty Functions
    // -------------------------------------------
    function penalizeGovernor(address governor, string calldata reason) external onlyRole(GOVERNANCE_ROLE) {
        if (penalizedGovernors[governor] || !hasRole(GOVERNANCE_ROLE, governor)) revert InvalidParameters();
        
        penalizedGovernors[governor] = true;
        if (address(stakingContract) != address(0)) {
            uint256 stake = stakingContract.getValidatorStake(governor);
            if (stake > 0) stakingContract.slashValidator(governor, (stake * PENALTY_FOR_VIOLATION) / 100);
        }
        _revokeRole(GOVERNANCE_ROLE, governor);
        emit GovernorPenalized(governor, reason);
    }
    
    function restoreGovernor(address governor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!penalizedGovernors[governor]) revert InvalidParameters();
        penalizedGovernors[governor] = false;
        _grantRole(GOVERNANCE_ROLE, governor);
        emit GovernorRestored(governor);
    }
    
    // -------------------------------------------
    //  Emergency Functions
    // -------------------------------------------
    function pause() external override onlyRole(GUARDIAN_ROLE) {
        paused = true;
        emit EmergencyPauseActivated(new address[](0));
    }
    
    function unpause() external override onlyRole(GUARDIAN_ROLE) {
        paused = false;
        emit EmergencyPauseDeactivated(new address[](0));
    }
    
    function emergencyPause(address[] calldata contractAddresses) external onlyRole(GUARDIAN_ROLE) {
        for (uint256 i = 0; i < contractAddresses.length; i++) {
            (bool success, ) = contractAddresses[i].call(abi.encodeWithSignature("pause()"));
            if (!success) revert InvalidParameters();
        }
        emit EmergencyPauseActivated(contractAddresses);
    }
    
    function emergencyUnpause(address[] calldata contractAddresses) external onlyRole(GUARDIAN_ROLE) {
        for (uint256 i = 0; i < contractAddresses.length; i++) {
            (bool success, ) = contractAddresses[i].call(abi.encodeWithSignature("unpause()"));
            if (!success) revert InvalidParameters();
        }
        emit EmergencyPauseDeactivated(contractAddresses);
    }
    
    function emergencyRecoverTokens(address token, uint256 amount, address recipient) 
        external 
        onlyRole(GUARDIAN_ROLE) 
    {
        if (recipient == address(0)) revert InvalidParameters();
        IERC20(token).transfer(recipient, amount);
        emit EmergencyTokenRecovery(token, amount, recipient);
    }

    // -------------------------------------------
    //  View Functions
    // -------------------------------------------
    function proposalThreshold() external view override returns (uint256) { return govParams.proposalThreshold; }
    function votingDelay() external view override returns (uint256) { return govParams.votingDelay; }
    function votingPeriod() external view override returns (uint256) { return govParams.votingPeriod; }
    function executionDelay() external view override returns (uint256) { return govParams.executionDelay; }
    function executionPeriod() external view override returns (uint256) { return govParams.executionPeriod; }
    function proposalCount() external view override returns (uint256) { return systemState.proposalCount; }
    
    function getProposalState(uint256 proposalId) external view override returns (ProposalState) {
        Proposal memory proposal = proposals[proposalId];
        if (proposal.id == 0) return ProposalState.Pending;
        if (proposal.canceled) return ProposalState.Canceled;
        if (proposal.executed) return ProposalState.Executed;
        if (block.timestamp < proposal.voteStart) return ProposalState.Pending;
        if (block.timestamp <= proposal.voteEnd) return ProposalState.Active;
        if (proposal.forVotes <= proposal.againstVotes) return ProposalState.Defeated;
        if (block.timestamp < proposalExtendedData[proposalId].timelockExpiry) return ProposalState.Queued;
        if (block.timestamp > proposalExtendedData[proposalId].timelockExpiry + govParams.executionPeriod) {
            return ProposalState.Expired;
        }
        return ProposalState.Succeeded;
    }
    
    function getProposalDetails(uint256 proposalId) 
        external 
        view 
        override 
        returns (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) 
    {
        Proposal memory proposal = proposals[proposalId];
        if (proposal.id == 0) revert ProposalDoesNotExist();
        (targets, values, calldatas) = abi.decode(proposalExtendedData[proposalId].customData, 
            (address[], uint256[], bytes[]));
        description = proposal.description;
    }
    
    function getProposalVotes(uint256 proposalId) 
        external 
        view 
        override 
        returns (
            uint256 againstVotes,
            uint256 forVotes,
            uint256 abstainVotes,
            uint256 validatorSupport
        ) 
    {
        Proposal memory proposal = proposals[proposalId];
        if (proposal.id == 0) revert ProposalDoesNotExist();
        return (proposal.againstVotes, proposal.forVotes, 0, 0); // Abstain and validatorSupport not fully tracked
    }
    
    function hasProposalSucceeded(uint256 proposalId) external view override returns (bool) {
        Proposal memory proposal = proposals[proposalId];
        if (proposal.id == 0) revert ProposalDoesNotExist();
        return proposal.forVotes > proposal.againstVotes && block.timestamp > proposal.voteEnd;
    }
    
    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }
    
    function getProposalExtendedData(uint256 proposalId) external view returns (ExtendedProposalData memory) {
        return proposalExtendedData[proposalId];
    }
    
    function getCurrentFeeStructure() external view returns (FeeProposal memory) {
        return currentFeeStructure;
    }
    
    function getNextHalvingTime() external view returns (uint256) {
        return systemState.lastHalvingTime + TWO_YEARS;
    }
    
    function getValidatorSafetyStatus() external view returns (
        uint8 tier,
        uint256 validatorCount,
        bool isBootstrapActive,
        uint256 thresholdEndTime,
        uint256 originalThreshold
    ) {
        return (governanceTier, stakingContract.getValidatorCount(), bootstrapMode, 
            temporaryThresholdEndTime, originalValidatorThreshold);
    }
    
    function isGuardianQuorumAchievable() external view returns (bool) {
        return guardianCount >= GUARDIAN_QUORUM;
    }
    
    function isGuardian(address account) external view returns (bool) {
        return guardianCouncilMembers[account];
    }

    // -------------------------------------------
    //  TStake Token Reception
    // -------------------------------------------
    function notifyTStakeReceived(address sender, uint256 amount) external {
        if (tStakeToken.balanceOf(address(this)) < amount) revert InvalidParameters();
        emit TStakeReceived(sender, amount);
    }

    receive() external payable {
        emit TStakeReceived(msg.sender, msg.value);
    }
}