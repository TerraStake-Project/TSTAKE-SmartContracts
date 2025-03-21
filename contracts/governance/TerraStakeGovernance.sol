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

    // Custom errors for gas savings
    error InsufficientValidators();
    error ProposalTypeNotAllowed();
    error GovernanceThresholdNotMet();
    error InvalidParameters();
    error InvalidProposalState();
    error InvalidVote();
    error ProposalDoesNotExist();
    error ProposalAlreadyExecuted();
    error TimelockNotExpired();
    error Unauthorized();
    error InvalidGuardianSignatures();
    error NonceAlreadyExecuted();

    // Packed storage for gas efficiency
    struct GovernanceParams {
        uint48 votingDuration;        // Reduced from uint256
        uint48 feeUpdateCooldown;     // Reduced from uint256
        uint96 proposalThreshold;     // Reduced from uint256
        uint96 minimumHolding;        // Reduced from uint256
        address treasuryWallet;
    }

    struct SystemState {
        uint48 lastFeeUpdateTime;     // Reduced from uint256
        uint48 lastHalvingTime;       // Reduced from uint256
        uint32 proposalCount;         // Reduced from uint256
        uint32 totalVotesCast;        // Reduced from uint256
        uint32 totalProposalsExecuted;// Reduced from uint256
        uint32 halvingEpoch;          // Reduced from uint256
        uint32 currentNonce;          // Reduced from uint256
        bool liquidityPairingEnabled;
    }

    // -------------------------------------------
    //  Constants
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
    
    uint256 public constant CRITICAL_VALIDATOR_THRESHOLD = 3;
    uint256 public constant REDUCED_VALIDATOR_THRESHOLD = 7;
    uint256 public constant OPTIMAL_VALIDATOR_THRESHOLD = 15;
    uint8 public constant GUARDIAN_QUORUM = 3;
    
    // -------------------------------------------
    //  State Variables
    // -------------------------------------------
    ITerraStakeStaking public stakingContract;
    ITerraStakeRewardDistributor public rewardDistributor;
    ITerraStakeLiquidityGuard public liquidityGuard;
    ISwapRouter public uniswapRouter;
    IERC20 public tStakeToken;
    IERC20 public usdcToken;
    
    GovernanceParams public govParams;
    SystemState public systemState;
    FeeProposal public currentFeeStructure;
    
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => ExtendedProposalData) public proposalExtendedData;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(bytes32 => bool) public executedHashes;
    mapping(address => bool) public penalizedGovernors;
    mapping(uint256 => bool) public executedNonces;
    
    // Validator safety
    uint8 public governanceTier;
    bool public bootstrapMode;
    uint48 public bootstrapEndTime;        // Reduced from uint256
    uint48 public temporaryThresholdEndTime;// Reduced from uint256
    uint96 public originalValidatorThreshold;// Reduced from uint256
    mapping(address => bool) public guardianCouncil;
    uint8 public guardianCount;
    
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
    
    // -------------------------------------------
    //  Initializer & Upgrade Control
    // -------------------------------------------
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
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
        
        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        _grantRole(UPGRADER_ROLE, _initialAdmin);
        _grantRole(GOVERNANCE_ROLE, _initialAdmin);
        _grantRole(GUARDIAN_ROLE, _initialAdmin);
        
        stakingContract = ITerraStakeStaking(_stakingContract);
        rewardDistributor = ITerraStakeRewardDistributor(_rewardDistributor);
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);
        tStakeToken = IERC20(_tStakeToken);
        usdcToken = IERC20(_usdcToken);
        uniswapRouter = ISwapRouter(_uniswapRouter);
        
        // Pack governance parameters
        govParams = GovernanceParams({
            votingDuration: 5 days,
            feeUpdateCooldown: 30 days,
            proposalThreshold: 1000 * 10**18,
            minimumHolding: 100 * 10**18,
            treasuryWallet: _treasuryWallet
        });
        
        // Pack system state
        uint48 currentTime = uint48(block.timestamp);
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
        guardianCouncil[_initialAdmin] = true;
        originalValidatorThreshold = stakingContract.validatorThreshold();
        governanceTier = 0;
    }
    
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
    
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

    function emergencyReduceValidatorThreshold(
        uint256 newThreshold,
        uint256 duration
    ) external onlyRole(GOVERNANCE_ROLE) {
        if (stakingContract.getValidatorCount() >= CRITICAL_VALIDATOR_THRESHOLD) {
            revert InvalidProposalState();
        }
        
        if (temporaryThresholdEndTime == 0) {
            originalValidatorThreshold = stakingContract.validatorThreshold();
        }
        
        (bool success, ) = address(stakingContract).call(
            abi.encodeWithSelector(ITerraStakeStaking.setValidatorThreshold.selector, newThreshold)
        );
        if (!success) revert InvalidParameters();
        
        _scheduleThresholdReset(duration);
        emit EmergencyThresholdReduction(newThreshold, duration);
    }
    
    function _scheduleThresholdReset(uint256 duration) internal {
        temporaryThresholdEndTime = uint48(block.timestamp + duration);
        emit ThresholdResetScheduled(temporaryThresholdEndTime);
    }
    
    function resetValidatorThreshold() external {
        if (temporaryThresholdEndTime == 0 || block.timestamp < temporaryThresholdEndTime) {
            revert InvalidProposalState();
        }
        
        (bool success, ) = address(stakingContract).call(
            abi.encodeWithSelector(ITerraStakeStaking.setValidatorThreshold.selector, 
            originalValidatorThreshold)
        );
        if (!success) revert InvalidParameters();
        
        temporaryThresholdEndTime = 0;
    }
    
    function checkValidatorHealth() external {
        uint256 validatorCount = stakingContract.getValidatorCount();
        uint256 totalStaked = stakingContract.totalStakedTokens();
        emit ValidatorHealthCheck(
            validatorCount,
            totalStaked,
            validatorCount > 0 ? totalStaked / validatorCount : 0,
            governanceTier
        );
    }
    
    function addGuardian(address guardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (guardian == address(0) || guardianCouncil[guardian]) revert InvalidParameters();
        
        guardianCouncil[guardian] = true;
        unchecked { guardianCount++; } // Safe due to small expected count
        _grantRole(GUARDIAN_ROLE, guardian);
        emit GuardianAdded(guardian);
    }
    
    function removeGuardian(address guardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!guardianCouncil[guardian] || guardianCount <= 1) revert InvalidParameters();
        
        guardianCouncil[guardian] = false;
        unchecked { guardianCount--; } // Safe due to check above
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
        
        bytes32 messageHash = keccak256(abi.encodePacked(
            operation, target, data, systemState.currentNonce
        )).toEthSignedMessageHash();
        
        address[GUARDIAN_QUORUM] memory signers; // Stack allocation
        uint256 validCount;
        
        for (uint256 i = 0; i < signatures.length && validCount < GUARDIAN_QUORUM; i++) {
            address signer = messageHash.recover(signatures[i]);
            if (guardianCouncil[signer]) {
                bool isUnique = true;
                for (uint256 j = 0; j < validCount; j++) {
                    if (signers[j] == signer) {
                        isUnique = false;
                        break;
                    }
                }
                if (isUnique) {
                    signers[validCount++] = signer;
                }
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
        if (stakingContract.getValidatorCount() >= CRITICAL_VALIDATOR_THRESHOLD) {
            revert InvalidProposalState();
        }
        if (!validateGuardianSignatures(operation, target, data, signatures)) {
            revert InvalidGuardianSignatures();
        }
        if (executedNonces[systemState.currentNonce]) revert NonceAlreadyExecuted();
        
        executedNonces[systemState.currentNonce] = true;
        unchecked { systemState.currentNonce++; } // Safe increment
        
        (bool success, ) = target.call(data);
        if (!success) revert InvalidParameters();
        
        emit GuardianOverrideExecuted(msg.sender, operation, target);
    }
    
    function createValidatorProposal(
        string calldata description,
        uint256 newThreshold,
        uint256 incentives
    ) external onlyRole(GOVERNANCE_ROLE) returns (uint256) {
        uint32 proposalId = ++systemState.proposalCount; // Pre-increment saves gas
        
        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            description: description,
            proposalType: PROPOSAL_TYPE_VALIDATOR,
            createTime: block.timestamp,
            voteStart: block.timestamp,
            voteEnd: block.timestamp + govParams.votingDuration,
            forVotes: 0,
            againstVotes: 0,
            executed: false,
            canceled: false
        });
        
        proposalExtendedData[proposalId] = ExtendedProposalData({
            customData: abi.encode(newThreshold, incentives),
            timelockExpiry: block.timestamp + TIMELOCK_DURATION + govParams.votingDuration
        });
        
        emit ValidatorProposalCreated(proposalId, newThreshold);
        return proposalId;
    }
    
    function initiateValidatorRecruitment(
        uint256 incentiveAmount,
        uint256 targetCount
    ) external onlyRole(GOVERNANCE_ROLE) {
        if (stakingContract.getValidatorCount() >= REDUCED_VALIDATOR_THRESHOLD) {
            revert InvalidProposalState();
        }
        emit ValidatorRecruitmentInitiated(incentiveAmount, targetCount);
    }
    
    // -------------------------------------------
    //  Core Governance Functions
    // -------------------------------------------
    function createProposal(
        string calldata description,
        uint8 proposalType,
        bytes[] calldata callData,
        address[] calldata targets
    ) external nonReentrant allowedProposalType(proposalType) returns (uint256) {
        if (tStakeToken.balanceOf(msg.sender) < govParams.proposalThreshold) {
            revert GovernanceThresholdNotMet();
        }
        if (callData.length != targets.length || callData.length == 0) {
            revert InvalidParameters();
        }
        
        uint32 proposalId = ++systemState.proposalCount;
        uint256 voteEnd = block.timestamp + govParams.votingDuration;
        
        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            description: description,
            proposalType: proposalType,
            createTime: block.timestamp,
            voteStart: block.timestamp,
            voteEnd: voteEnd,
            forVotes: 0,
            againstVotes: 0,
            executed: false,
            canceled: false
        });
        
        proposalExtendedData[proposalId] = ExtendedProposalData({
            customData: abi.encode(targets, callData),
            timelockExpiry: voteEnd + TIMELOCK_DURATION
        });
        
        emit ProposalCreated(proposalId, msg.sender, description, proposalType, 
            block.timestamp, voteEnd);
        return proposalId;
    }
    
    function castVote(uint256 proposalId, bool support) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        if (block.timestamp > proposal.voteEnd) revert InvalidProposalState();
        if (hasVoted[proposalId][msg.sender]) revert InvalidVote();
        
        uint256 weight = tStakeToken.balanceOf(msg.sender);
        if (weight < govParams.minimumHolding) revert GovernanceThresholdNotMet();
        
        support ? proposal.forVotes += weight : proposal.againstVotes += weight;
        hasVoted[proposalId][msg.sender] = true;
        unchecked { systemState.totalVotesCast++; }
        
        emit VoteCast(proposalId, msg.sender, support, weight);
    }
    
    function executeProposal(uint256 proposalId) 
        external 
        nonReentrant 
        validatorSafetyCheck 
    {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.id == 0) revert ProposalDoesNotExist();
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (block.timestamp <= proposal.voteEnd) revert ProposalNotReady();
        if (proposal.forVotes <= proposal.againstVotes) revert InvalidProposalState();
        
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        if (block.timestamp < extData.timelockExpiry) revert TimelockNotExpired();
        
        if (proposal.proposalType == PROPOSAL_TYPE_FEE_UPDATE) {
            _executeFeeUpdate(proposalId);
        } else if (proposal.proposalType == PROPOSAL_TYPE_VALIDATOR) {
            _executeValidatorUpdate(proposalId);
        } else {
            (address[] memory targets, bytes[] memory callData) = 
                abi.decode(extData.customData, (address[], bytes[]));
            
            for (uint256 i = 0; i < targets.length; i++) {
                (bool success, ) = targets[i].call(callData[i]);
                if (!success) revert InvalidParameters();
            }
        }
        
        proposal.executed = true;
        unchecked { systemState.totalProposalsExecuted++; }
        emit ProposalExecuted(proposalId);
    }
    
    function _executeFeeUpdate(uint256 proposalId) internal {
        if (block.timestamp < systemState.lastFeeUpdateTime + govParams.feeUpdateCooldown) {
            revert InvalidProposalState();
        }
        
        FeeProposal memory newFees = abi.decode(
            proposalExtendedData[proposalId].customData,
            (FeeProposal)
        );
        
        if (newFees.buybackPercentage + newFees.liquidityPairingPercentage + 
            newFees.burnPercentage + newFees.treasuryPercentage != 100) {
            revert InvalidParameters();
        }
        
        currentFeeStructure = newFees;
        systemState.lastFeeUpdateTime = uint48(block.timestamp);
        emit FeeStructureUpdated(
            newFees.projectSubmissionFee,
            newFees.impactReportingFee,
            newFees.buybackPercentage,
            newFees.liquidityPairingPercentage,
            newFees.burnPercentage,
            newFees.treasuryPercentage
        );
    }
    
    function _executeValidatorUpdate(uint256 proposalId) internal {
        (uint256 newThreshold, uint256 incentives) = abi.decode(
            proposalExtendedData[proposalId].customData,
            (uint256, uint256)
        );
        
        if (newThreshold > 0) {
            (bool success, ) = address(stakingContract).call(
                abi.encodeWithSelector(ITerraStakeStaking.setValidatorThreshold.selector, newThreshold)
            );
            if (!success) revert InvalidParameters();
            originalValidatorThreshold = uint96(newThreshold);
        }
        
        if (incentives > 0) {
            (bool success, ) = address(rewardDistributor).call(
                abi.encodeWithSelector(ITerraStakeRewardDistributor.addValidatorIncentive.selector, incentives)
            );
            if (!success) revert InvalidParameters();
        }
    }
    
    function cancelProposal(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.id == 0) revert ProposalDoesNotExist();
        if (msg.sender != proposal.proposer && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        if (proposal.executed) revert ProposalAlreadyExecuted();
        
        proposal.canceled = true;
        emit ProposalCanceled(proposalId);
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
        if (tStakeToken.balanceOf(msg.sender) < govParams.proposalThreshold) {
            revert GovernanceThresholdNotMet();
        }
        if (buybackPercentage + liquidityPairingPercentage + burnPercentage + treasuryPercentage != 100) {
            revert InvalidParameters();
        }
        
        uint32 proposalId = ++systemState.proposalCount;
        uint256 voteEnd = block.timestamp + govParams.votingDuration;
        
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
            voteStart: block.timestamp,
            voteEnd: voteEnd,
            forVotes: 0,
            againstVotes: 0,
            executed: false,
            canceled: false
        });
        
        proposalExtendedData[proposalId] = ExtendedProposalData({
            customData: abi.encode(feeProposal),
            timelockExpiry: voteEnd + TIMELOCK_DURATION
        });
        
        emit ProposalCreated(proposalId, msg.sender, description, PROPOSAL_TYPE_FEE_UPDATE, 
            block.timestamp, voteEnd);
        return proposalId;
    }
    
    function performBuyback(uint256 usdcAmount) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        if (usdcAmount == 0 || usdcToken.balanceOf(address(this)) < usdcAmount) {
            revert InvalidParameters();
        }
        
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
    
    function addLiquidity(uint256 tStakeAmount, uint256 usdcAmount) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
        nonReentrant 
    {
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
        if (amount == 0 || tStakeToken.balanceOf(address(this)) < amount) {
            revert InvalidParameters();
        }
        
        (bool success, ) = address(tStakeToken).call(
            abi.encodeWithSignature("burn(uint256)", amount)
        );
        if (!success) {
            tStakeToken.transfer(address(0xdead), amount);
        }
        emit TokensBurned(amount);
    }
    
    function treasuryTransfer(
        address token,
        address recipient, 
        uint256 amount
    ) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        if (amount == 0 || recipient == address(0)) revert InvalidParameters();
        IERC20(token).transfer(recipient, amount);
        emit TreasuryTransfer(token, recipient, amount);
    }
    
    // -------------------------------------------
    //  Reward Distribution Functions
    // -------------------------------------------
    function initiateHalving() external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        if (block.timestamp < systemState.lastHalvingTime + TWO_YEARS) {
            revert InvalidProposalState();
        }
        
        systemState.lastHalvingTime = uint48(block.timestamp);
        unchecked { systemState.halvingEpoch++; }
        rewardDistributor.updateEmissionRate();
        emit HalvingInitiated(systemState.halvingEpoch);
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
    function updateGovernanceParameters(
        uint256 newVotingDuration,
        uint256 newProposalThreshold,
        uint256 newMinimumHolding
    ) external onlyRole(GOVERNANCE_ROLE) validatorSafetyCheck {
        if (newVotingDuration < 1 days || newVotingDuration > 14 days) {
            revert InvalidParameters();
        }
        
        govParams.votingDuration = uint48(newVotingDuration);
        govParams.proposalThreshold = uint96(newProposalThreshold);
        govParams.minimumHolding = uint96(newMinimumHolding);
        
        emit GovernanceParametersUpdated(
            newVotingDuration,
            newProposalThreshold,
            newMinimumHolding
        );
    }
    
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
    function penalizeGovernor(address governor, string calldata reason) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        if (penalizedGovernors[governor] || !hasRole(GOVERNANCE_ROLE, governor)) {
            revert InvalidParameters();
        }
        
        penalizedGovernors[governor] = true;
        if (address(stakingContract) != address(0)) {
            uint256 stake = stakingContract.getValidatorStake(governor);
            if (stake > 0) {
                stakingContract.slashValidator(governor, (stake * PENALTY_FOR_VIOLATION) / 100);
            }
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
    //  View Functions
    // -------------------------------------------
    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }
    
    function getProposalExtendedData(uint256 proposalId) external view returns (ExtendedProposalData memory) {
        return proposalExtendedData[proposalId];
    }
    
    function hasAccountVoted(uint256 proposalId, address account) external view returns (bool) {
        return hasVoted[proposalId][account];
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
        return (
            governanceTier,
            stakingContract.getValidatorCount(),
            bootstrapMode,
            temporaryThresholdEndTime,
            originalValidatorThreshold
        );
    }
    
    function isGuardianQuorumAchievable() external view returns (bool) {
        return guardianCount >= GUARDIAN_QUORUM;
    }
    
    function isGuardian(address account) external view returns (bool) {
        return guardianCouncil[account];
    }
    
    // -------------------------------------------
    //  Emergency Functions
    // -------------------------------------------
    function emergencyPause(address[] calldata contractAddresses) 
        external 
        onlyRole(GUARDIAN_ROLE) 
    {
        for (uint256 i = 0; i < contractAddresses.length; i++) {
            (bool success, ) = contractAddresses[i].call(abi.encodeWithSignature("pause()"));
            if (!success) revert InvalidParameters();
        }
        emit EmergencyPauseActivated(contractAddresses);
    }
    
    function emergencyUnpause(address[] calldata contractAddresses) 
        external 
        onlyRole(GUARDIAN_ROLE) 
    {
        for (uint256 i = 0; i < contractAddresses.length; i++) {
            (bool success, ) = contractAddresses[i].call(abi.encodeWithSignature("unpause()"));
            if (!success) revert InvalidParameters();
        }
        emit EmergencyPauseDeactivated(contractAddresses);
    }
    
    function emergencyRecoverTokens(
        address token,
        uint256 amount,
        address recipient
    ) external onlyRole(GUARDIAN_ROLE) {
        if (recipient == address(0)) revert InvalidParameters();
        IERC20(token).transfer(recipient, amount);
        emit EmergencyTokenRecovery(token, amount, recipient);
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