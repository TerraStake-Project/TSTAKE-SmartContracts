// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import "../interfaces/ITerraStakeGovernance.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/ITerraStakeRewardDistributor.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";

/**
 * @title TerraStakeGovernance
 * @author TerraStake Protocol Team
 * @notice Governance contract for the TerraStake Protocol with advanced voting, 
 * proposal management, treasury control, and economic adjustments
 */
contract TerraStakeGovernance is 
    Initializable, 
    AccessControlEnumerableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable,
    ITerraStakeGovernance
{
    // -------------------------------------------
    // 🔹 Constants
    // -------------------------------------------
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    
    uint8 public constant PROPOSAL_TYPE_STANDARD = 0;
    uint8 public constant PROPOSAL_TYPE_FEE_UPDATE = 1;
    uint8 public constant PROPOSAL_TYPE_PARAM_UPDATE = 2;
    uint8 public constant PROPOSAL_TYPE_CONTRACT_UPDATE = 3;
    uint8 public constant PROPOSAL_TYPE_PENALTY = 4;
    uint8 public constant PROPOSAL_TYPE_EMERGENCY = 5;
    
    uint256 public constant TIMELOCK_DURATION = 2 days;
    uint256 public constant PENALTY_FOR_VIOLATION = 5; // 5% of stake
    uint256 public constant TWO_YEARS = 730 days;
    uint24 public constant POOL_FEE = 3000; // 0.3% pool fee for Uniswap v3
    
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
    }
    
    /**
     * @notice Authorize contract upgrades, restricted to the upgrader role
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
    
    // -------------------------------------------
    // 🔹 Proposal Creation & Execution
    // -------------------------------------------
    
    /**
     * @notice Creates a standard proposal with arbitrary calldata and target
     * @param proposalHash Hash of the proposal details
     * @param description Description of the proposal
     * @param callData Data to be executed if proposal passes
     * @param target Target contract address for execution
     * @return proposalId The ID of the newly created proposal
     */
    function createStandardProposal(
        bytes32 proposalHash,
        string calldata description,
        bytes calldata callData,
        address target
    ) external nonReentrant returns (uint256) {
        uint256 votingPower = stakingContract.governanceVotes(msg.sender);
        if (votingPower < proposalThreshold) revert GovernanceThresholdNotMet();
        if (penalizedGovernors[msg.sender]) revert GovernanceViolation();
        if (target == address(0)) revert InvalidParameters();
        
        uint256 proposalId = _createBaseProposal(
            proposalHash, 
            description, 
            callData, 
            target, 
            PROPOSAL_TYPE_STANDARD
        );
        
        return proposalId;
    }
    
    /**
     * @notice Creates a proposal to update fee structure
     * @param proposalHash Hash of the proposal details
     * @param description Description of the proposal
     * @param projectSubmissionFee New project submission fee
     * @param impactReportingFee New impact reporting fee
     * @param buybackPercentage New percentage allocated for token buybacks
     * @param liquidityPairingPercentage New percentage allocated for liquidity pairing
     * @param burnPercentage New percentage allocated for token burns
     * @param treasuryPercentage New percentage allocated for treasury
     * @return proposalId The ID of the newly created proposal
     */
    function createFeeUpdateProposal(
        bytes32 proposalHash,
        string calldata description,
        uint256 projectSubmissionFee,
        uint256 impactReportingFee,
        uint256 buybackPercentage,
        uint256 liquidityPairingPercentage,
        uint256 burnPercentage,
        uint256 treasuryPercentage
    ) external nonReentrant returns (uint256) {
        uint256 votingPower = stakingContract.governanceVotes(msg.sender);
        if (votingPower < proposalThreshold) revert GovernanceThresholdNotMet();
        if (penalizedGovernors[msg.sender]) revert GovernanceViolation();
        
        // Ensure percentages add up to 100%
        if (buybackPercentage + liquidityPairingPercentage + burnPercentage + treasuryPercentage != 100) 
            revert InvalidParameters();
            
        // Check cooldown period
        if (block.timestamp < lastFeeUpdateTime + feeUpdateCooldown) revert TimelockNotExpired();
        
        uint256 proposalId = _createBaseProposal(
            proposalHash, 
            description, 
            "", // No calldata for fee proposals
            address(0), // No target for fee proposals
            PROPOSAL_TYPE_FEE_UPDATE
        );
        
        // Store fee-specific data
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        extData.feeData = FeeProposal(
            projectSubmissionFee,
            impactReportingFee,
            buybackPercentage,
            liquidityPairingPercentage,
            burnPercentage,
            treasuryPercentage,
            proposals[proposalId].endTime,
            false
        );
        
        emit FeeProposalCreated(
            proposalId,
            projectSubmissionFee,
            impactReportingFee,
            buybackPercentage,
            liquidityPairingPercentage,
            burnPercentage,
            treasuryPercentage
        );
        
        return proposalId;
    }
    
    /**
     * @notice Creates a proposal to update governance parameters
     * @param proposalHash Hash of the proposal details
     * @param description Description of the proposal
     * @param _votingDuration New voting period duration
     * @param _proposalThreshold New threshold for proposal creation
     * @param _minimumHolding New minimum token holding to vote
     * @param _feeUpdateCooldown New cooldown period for fee updates
     * @return proposalId The ID of the newly created proposal
     */
    function createParamUpdateProposal(
        bytes32 proposalHash,
        string calldata description,
        uint256 _votingDuration,
        uint256 _proposalThreshold,
        uint256 _minimumHolding,
        uint256 _feeUpdateCooldown
    ) external nonReentrant returns (uint256) {
        uint256 votingPower = stakingContract.governanceVotes(msg.sender);
        if (votingPower < proposalThreshold) revert GovernanceThresholdNotMet();
        if (penalizedGovernors[msg.sender]) revert GovernanceViolation();
        
        uint256 proposalId = _createBaseProposal(
            proposalHash, 
            description, 
            "", // No calldata for parameter proposals
            address(0), // No target for parameter proposals
            PROPOSAL_TYPE_PARAM_UPDATE
        );
        
        // Store parameter data
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        extData.numericParams = new uint256[](4);
        extData.numericParams[0] = _votingDuration;
        extData.numericParams[1] = _proposalThreshold;
        extData.numericParams[2] = _minimumHolding;
        extData.numericParams[3] = _feeUpdateCooldown;
        
        return proposalId;
    }
    
    /**
     * @notice Creates a proposal to update contract references
     * @param proposalHash Hash of the proposal details
     * @param description Description of the proposal
     * @param _stakingContract New staking contract address
     * @param _rewardDistributor New reward distributor contract address
     * @param _liquidityGuard New liquidity guard contract address
     * @param _treasuryWallet New treasury wallet address
     * @return proposalId The ID of the newly created proposal
     */
    function createContractUpdateProposal(
        bytes32 proposalHash,
        string calldata description,
        address _stakingContract,
        address _rewardDistributor,
        address _liquidityGuard,
        address _treasuryWallet
    ) external nonReentrant returns (uint256) {
uint256 votingPower = stakingContract.governanceVotes(msg.sender);
        if (votingPower < proposalThreshold) revert GovernanceThresholdNotMet();
        if (penalizedGovernors[msg.sender]) revert GovernanceViolation();
        
        uint256 proposalId = _createBaseProposal(
            proposalHash, 
            description, 
            "", // No calldata for contract update proposals
            address(0), // No target for contract update proposals
            PROPOSAL_TYPE_CONTRACT_UPDATE
        );
        
        // Store contract addresses
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        extData.contractAddresses = new address[](4);
        extData.contractAddresses[0] = _stakingContract;
        extData.contractAddresses[1] = _rewardDistributor;
        extData.contractAddresses[2] = _liquidityGuard;
        extData.contractAddresses[3] = _treasuryWallet;
        
        return proposalId;
    }
    
    /**
     * @notice Creates a proposal to penalize a governance violator
     * @param proposalHash Hash of the proposal details
     * @param description Description of the proposal
     * @param violator Address of the violator
     * @param reason Reason for the penalty
     * @return proposalId The ID of the newly created proposal
     */
    function createPenaltyProposal(
        bytes32 proposalHash,
        string calldata description,
        address violator,
        string calldata reason
    ) external nonReentrant returns (uint256) {
        uint256 votingPower = stakingContract.governanceVotes(msg.sender);
        if (votingPower < proposalThreshold) revert GovernanceThresholdNotMet();
        if (penalizedGovernors[msg.sender]) revert GovernanceViolation();
        if (violator == address(0)) revert InvalidParameters();
        
        uint256 proposalId = _createBaseProposal(
            proposalHash, 
            description, 
            "", // No calldata for penalty proposals
            address(0), // No target for penalty proposals
            PROPOSAL_TYPE_PENALTY
        );
        
        // Store violator address
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        extData.accountsToUpdate = new address[](1);
        extData.accountsToUpdate[0] = violator;
        
        return proposalId;
    }
    
    /**
     * @notice Create emergency proposal for critical operations
     * @param proposalHash Hash of the proposal details
     * @param description Description of the proposal
     * @param haltOperations Whether to halt protocol operations
     * @return proposalId The ID of the newly created proposal
     */
    function createEmergencyProposal(
        bytes32 proposalHash,
        string calldata description,
        bool haltOperations
    ) external nonReentrant returns (uint256) {
        // Only governance role members can create emergency proposals
        if (!hasRole(GOVERNANCE_ROLE, msg.sender)) revert Unauthorized();
        if (penalizedGovernors[msg.sender]) revert GovernanceViolation();
        
        uint256 proposalId = _createBaseProposal(
            proposalHash, 
            description, 
            "", // No calldata for emergency proposals
            address(0), // No target for emergency proposals
            PROPOSAL_TYPE_EMERGENCY
        );
        
        // Store emergency action flag
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        extData.boolParams = new bool[](1);
        extData.boolParams[0] = haltOperations;
        
        return proposalId;
    }
    
    /**
     * @notice Pardon a previously penalized governor (requires DAO vote)
     * @param proposalHash Hash of the proposal details
     * @param description Description of the proposal
     * @param violator Address to pardon
     * @return proposalId The ID of the newly created proposal
     */
    function createPardonProposal(
        bytes32 proposalHash,
        string calldata description,
        address violator
    ) external nonReentrant returns (uint256) {
        uint256 votingPower = stakingContract.governanceVotes(msg.sender);
        if (votingPower < proposalThreshold) revert GovernanceThresholdNotMet();
        if (penalizedGovernors[msg.sender]) revert GovernanceViolation();
        if (!penalizedGovernors[violator]) revert InvalidParameters(); // Can only pardon if currently penalized
        
        uint256 proposalId = _createBaseProposal(
            proposalHash, 
            description, 
            "", // No calldata for pardon proposals
            address(0), // No target for pardon proposals
            PROPOSAL_TYPE_PENALTY
        );
        
        // Store violator address with special flag for pardon
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        extData.accountsToUpdate = new address[](1);
        extData.accountsToUpdate[0] = violator;
        extData.boolParams = new bool[](1);
        extData.boolParams[0] = true; // true for pardon vs false for penalize
        
        return proposalId;
    }
    
    /**
     * @notice Create a proposal to adjust staking reward rate
     * @param proposalHash Hash of the proposal details
     * @param description Description of the proposal
     * @param newRate New staking reward rate
     * @return proposalId The ID of the newly created proposal
     */
    function createRewardRateAdjustmentProposal(
        bytes32 proposalHash,
        string calldata description,
        uint256 newRate
    ) external nonReentrant returns (uint256) {
        uint256 votingPower = stakingContract.governanceVotes(msg.sender);
        if (votingPower < proposalThreshold) revert GovernanceThresholdNotMet();
        if (penalizedGovernors[msg.sender]) revert GovernanceViolation();
        
        // Create proposal with reward rate adjustment calldata
        bytes memory callData = abi.encodeWithSelector(
            ITerraStakeRewardDistributor.setRewardRate.selector,
            newRate
        );
        
        uint256 proposalId = _createBaseProposal(
            proposalHash, 
            description, 
            callData, 
            address(rewardDistributor), 
            PROPOSAL_TYPE_STANDARD
        );
        
        return proposalId;
    }
    
    /**
     * @notice Create a proposal to execute token buyback using rewards
     * @param proposalHash Hash of the proposal details
     * @param description Description of the proposal
     * @param usdcAmount Amount of USDC to use for buyback
     * @return proposalId The ID of the newly created proposal
     */
    function createBuybackProposal(
        bytes32 proposalHash,
        string calldata description,
        uint256 usdcAmount
    ) external nonReentrant returns (uint256) {
        uint256 votingPower = stakingContract.governanceVotes(msg.sender);
        if (votingPower < proposalThreshold) revert GovernanceThresholdNotMet();
        if (penalizedGovernors[msg.sender]) revert GovernanceViolation();
        if (usdcAmount == 0) revert InvalidParameters();
        
        uint256 proposalId = _createBaseProposal(
            proposalHash, 
            description, 
            "", // Custom execution in executeBuybackProposal
            address(0), 
            PROPOSAL_TYPE_STANDARD
        );
        
        // Store buyback amount
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        extData.numericParams = new uint256[](1);
        extData.numericParams[0] = usdcAmount;
        
        return proposalId;
    }
    
    /**
     * @notice Create a proposal to toggle liquidity pairing
     * @param proposalHash Hash of the proposal details
     * @param description Description of the proposal
     * @param enabled Whether to enable or disable liquidity pairing
     * @return proposalId The ID of the newly created proposal
     */
    function createLiquidityPairingProposal(
        bytes32 proposalHash,
        string calldata description,
        bool enabled
    ) external nonReentrant returns (uint256) {
        uint256 votingPower = stakingContract.governanceVotes(msg.sender);
        if (votingPower < proposalThreshold) revert GovernanceThresholdNotMet();
        if (penalizedGovernors[msg.sender]) revert GovernanceViolation();
        
        uint256 proposalId = _createBaseProposal(
            proposalHash, 
            description, 
            "", // No calldata for liquidity pairing proposals
            address(0), // No target for liquidity pairing proposals
            PROPOSAL_TYPE_STANDARD
        );
        
        // Store liquidity pairing flag
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        extData.boolParams = new bool[](1);
        extData.boolParams[0] = enabled;
        
        return proposalId;
    }
    
    /**
     * @notice Internal function to create the base proposal
     * @param proposalHash Hash of the proposal details
     * @param description Description of the proposal
     * @param callData Data to be executed if proposal passes
     * @param target Target contract address for execution
     * @param proposalType Type of the proposal
     * @return proposalId The ID of the newly created proposal
     */
    function _createBaseProposal(
        bytes32 proposalHash,
        string calldata description,
        bytes memory callData,
        address target,
        uint8 proposalType
    ) internal returns (uint256) {
        // Ensure proposal hash has not been executed already
        if (executedHashes[proposalHash]) revert ProposalAlreadyExecuted();
        
        // Increment proposal count and create new proposal
        proposalCount++;
        uint256 proposalId = proposalCount;
        
        // Set up proposal timing
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + votingDuration;
        uint256 timelockEnd = endTime + TIMELOCK_DURATION;
        
        // Create proposal
        Proposal storage newProposal = proposals[proposalId];
        newProposal.id = proposalId;
        newProposal.proposer = msg.sender;
        newProposal.hashOfProposal = proposalHash;
        newProposal.startTime = startTime;
        newProposal.endTime = endTime;
        newProposal.forVotes = 0;
        newProposal.againstVotes = 0;
        newProposal.executed = false;
        newProposal.callData = callData;
        newProposal.target = target;
        newProposal.timelockEnd = timelockEnd;
        
        // Set proposal type
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        extData.proposalType = proposalType;
        
        emit ProposalCreated(
            proposalId,
            msg.sender,
            proposalHash,
            startTime,
            endTime,
            description,
            proposalType
        );
        
        return proposalId;
    }
    
    /**
     * @notice Cast a vote on a proposal
     * @param proposalId ID of the proposal to vote on
     * @param support True for vote in favor, false for vote against
     */
    function castVote(uint256 proposalId, bool support) external nonReentrant {
        if (proposalId == 0 || proposalId > proposalCount) revert ProposalDoesNotExist();
        
        Proposal storage proposal = proposals[proposalId];
        if (block.timestamp <= proposal.startTime) revert ProposalNotReady();
        if (block.timestamp > proposal.endTime) revert InvalidProposalState();
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (hasVoted[proposalId][msg.sender]) revert InvalidVote();
        
        // Check if caller meets minimum holding
        uint256 votingPower = stakingContract.governanceVotes(msg.sender);
        if (votingPower < minimumHolding) revert GovernanceThresholdNotMet();
        if (penalizedGovernors[msg.sender]) revert GovernanceViolation();
        
        // Mark as voted
        hasVoted[proposalId][msg.sender] = true;
        
        // Apply quadratic voting
        uint256 quadraticVotingPower = sqrt(votingPower);
        
        // Tally votes
        if (support) {
            proposal.forVotes += quadraticVotingPower;
        } else {
            proposal.againstVotes += quadraticVotingPower;
        }
        
        totalVotesCast++;
        
        emit GovernanceVoteCast(msg.sender, proposalId, support);
    }
    
    /**
     * @notice Execute a proposal that has passed voting
     * @param proposalId ID of the proposal to execute
     */
    function executeProposal(uint256 proposalId) external nonReentrant {
        if (proposalId == 0 || proposalId > proposalCount) revert ProposalDoesNotExist();
        
        Proposal storage proposal = proposals[proposalId];
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (block.timestamp <= proposal.endTime) revert ProposalNotReady();
        if (block.timestamp < proposal.timelockEnd) revert TimelockNotExpired();
        if (proposal.forVotes <= proposal.againstVotes) revert GovernanceThresholdNotMet();
        
        // Mark as executed
        proposal.executed = true;
        executedHashes[proposal.hashOfProposal] = true;
        totalProposalsExecuted++;
        
        // Execute based on proposal type
        uint8 pType = extData.proposalType;
        
        bool success = true;
        
        if (pType == PROPOSAL_TYPE_STANDARD) {
            // Execute standard proposal with calldata
            if (proposal.target != address(0) && proposal.callData.length > 0) {
                (bool callSuccess, ) = proposal.target.call(proposal.callData);
                success = callSuccess;
            }
        } 
        else if (pType == PROPOSAL_TYPE_FEE_UPDATE) {
            _executeFeeUpdate(proposalId);
        } 
        else if (pType == PROPOSAL_TYPE_PARAM_UPDATE) {
            _executeParamUpdate(proposalId);
        } 
        else if (pType == PROPOSAL_TYPE_CONTRACT_UPDATE) {
            _executeContractUpdate(proposalId);
        } 
        else if (pType == PROPOSAL_TYPE_PENALTY) {
            _executePenalty(proposalId);
        } 
        else if (pType == PROPOSAL_TYPE_EMERGENCY) {
 _executeEmergency(proposalId);
        }
        
        emit ProposalExecuted(proposalId, msg.sender);
    }
    
    /**
     * @notice Execute a token buyback proposal
     * @param proposalId ID of the buyback proposal
     */
    function executeBuybackProposal(uint256 proposalId) external nonReentrant {
        if (proposalId == 0 || proposalId > proposalCount) revert ProposalDoesNotExist();
        
        Proposal storage proposal = proposals[proposalId];
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (block.timestamp <= proposal.endTime) revert ProposalNotReady();
        if (block.timestamp < proposal.timelockEnd) revert TimelockNotExpired();
        if (proposal.forVotes <= proposal.againstVotes) revert GovernanceThresholdNotMet();
        
        // Mark as executed
        proposal.executed = true;
        executedHashes[proposal.hashOfProposal] = true;
        totalProposalsExecuted++;
        
        // Execute buyback
        uint256 usdcAmount = extData.numericParams[0];
        
        // Ensure treasury has enough USDC
        require(usdcToken.balanceOf(treasuryWallet) >= usdcAmount, "Insufficient USDC in treasury");
        
        // Transfer USDC from treasury to this contract for the swap
        usdcToken.transferFrom(treasuryWallet, address(this), usdcAmount);
        
        // Approve Uniswap router to spend USDC
        usdcToken.approve(address(uniswapRouter), usdcAmount);
        
        // Set swap parameters
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(usdcToken),
            tokenOut: address(tStakeToken),
            fee: POOL_FEE,
            recipient: treasuryWallet,
            deadline: block.timestamp + 15 minutes,
            amountIn: usdcAmount,
            amountOutMinimum: 0, // Allow any amount (assumes TWAP protection)
            sqrtPriceLimitX96: 0 // No price limit
        });
        
        // Execute swap and get amount of TStake received
        uint256 amountOut = uniswapRouter.exactInputSingle(params);
        
        emit RewardBuybackExecuted(usdcAmount, amountOut);
        emit ProposalExecuted(proposalId, msg.sender);
    }
    
    /**
     * @notice Execute liquidity pairing proposal
     * @param proposalId ID of the liquidity pairing proposal
     */
    function executeLiquidityPairingProposal(uint256 proposalId) external nonReentrant {
        if (proposalId == 0 || proposalId > proposalCount) revert ProposalDoesNotExist();
        
        Proposal storage proposal = proposals[proposalId];
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (block.timestamp <= proposal.endTime) revert ProposalNotReady();
        if (block.timestamp < proposal.timelockEnd) revert TimelockNotExpired();
        if (proposal.forVotes <= proposal.againstVotes) revert GovernanceThresholdNotMet();
        
        // Mark as executed
        proposal.executed = true;
        executedHashes[proposal.hashOfProposal] = true;
        totalProposalsExecuted++;
        
        // Toggle liquidity pairing
        liquidityPairingEnabled = extData.boolParams[0];
        
        emit LiquidityPairingToggled(liquidityPairingEnabled);
        emit ProposalExecuted(proposalId, msg.sender);
    }
    
    /**
     * @notice Execute a fee update proposal
     * @param proposalId ID of the fee update proposal
     */
    function _executeFeeUpdate(uint256 proposalId) internal {
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        FeeProposal storage feeProposal = extData.feeData;
        
        // Update current fee structure
        currentFeeStructure = FeeProposal({
            projectSubmissionFee: feeProposal.projectSubmissionFee,
            impactReportingFee: feeProposal.impactReportingFee,
            buybackPercentage: feeProposal.buybackPercentage,
            liquidityPairingPercentage: feeProposal.liquidityPairingPercentage,
            burnPercentage: feeProposal.burnPercentage,
            treasuryPercentage: feeProposal.treasuryPercentage,
            voteEnd: 0,
            executed: true
        });
        
        // Update last fee update time
        lastFeeUpdateTime = block.timestamp;
        
        emit FeeStructureUpdated(
            feeProposal.projectSubmissionFee,
            feeProposal.impactReportingFee,
            feeProposal.buybackPercentage,
            feeProposal.liquidityPairingPercentage,
            feeProposal.burnPercentage,
            feeProposal.treasuryPercentage
        );
    }
    
    /**
     * @notice Execute a parameter update proposal
     * @param proposalId ID of the parameter update proposal
     */
    function _executeParamUpdate(uint256 proposalId) internal {
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        
        // Update governance parameters
        votingDuration = extData.numericParams[0];
        proposalThreshold = extData.numericParams[1];
        minimumHolding = extData.numericParams[2];
        feeUpdateCooldown = extData.numericParams[3];
        
        emit GovernanceParametersUpdated(
            votingDuration,
            proposalThreshold,
            minimumHolding
        );
    }
    
    /**
     * @notice Execute a contract update proposal
     * @param proposalId ID of the contract update proposal
     */
    function _executeContractUpdate(uint256 proposalId) internal {
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        
        address newStakingContract = extData.contractAddresses[0];
        address newRewardDistributor = extData.contractAddresses[1];
        address newLiquidityGuard = extData.contractAddresses[2];
        address newTreasuryWallet = extData.contractAddresses[3];
        
        // Update contract references (if not zero address)
        if (newStakingContract != address(0)) {
            stakingContract = ITerraStakeStaking(newStakingContract);
        }
        
        if (newRewardDistributor != address(0)) {
            rewardDistributor = ITerraStakeRewardDistributor(newRewardDistributor);
        }
        
        if (newLiquidityGuard != address(0)) {
            liquidityGuard = ITerraStakeLiquidityGuard(newLiquidityGuard);
        }
        
        if (newTreasuryWallet != address(0)) {
            treasuryWallet = newTreasuryWallet;
            emit TreasuryWalletUpdated(newTreasuryWallet);
        }
        
        emit GovernanceContractsUpdated(
            address(stakingContract),
            address(rewardDistributor),
            address(liquidityGuard)
        );
    }
    
    /**
     * @notice Execute a penalty proposal
     * @param proposalId ID of the penalty proposal
     */
    function _executePenalty(uint256 proposalId) internal {
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        address violator = extData.accountsToUpdate[0];
        
        // Check if this is a pardon proposal
        bool isPardon = extData.boolParams.length > 0 && extData.boolParams[0];
        
        if (isPardon) {
            // Remove penalty
            penalizedGovernors[violator] = false;
        } else {
            // Apply penalty
            penalizedGovernors[violator] = true;
            emit GovernanceViolationDetected(violator, PENALTY_FOR_VIOLATION);
        }
    }
    
    /**
     * @notice Execute an emergency proposal
     * @param proposalId ID of the emergency proposal
     */
    function _executeEmergency(uint256 proposalId) internal {
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        bool haltOperations = extData.boolParams[0];
        
        // Execute emergency action (to be implemented in specific contracts)
        if (haltOperations) {
            // Signal emergency halt
            emit EmergencyActionTriggered(proposalId, "OPERATIONS_HALTED");
        } else {
            // Signal emergency resolution
            emit EmergencyActionResolved(proposalId, "OPERATIONS_RESUMED");
        }
    }
    
    /**
     * @notice Process multiple proposals in a single transaction
     * @param proposalIds Array of proposal IDs to process
     */
    function batchProcessProposals(uint256[] calldata proposalIds) external nonReentrant {
        uint256 successCount = 0;
        
        for (uint256 i = 0; i < proposalIds.length; i++) {
            uint256 proposalId = proposalIds[i];
            
            // Skip invalid proposals
            if (proposalId == 0 || proposalId > proposalCount) continue;
            
            Proposal storage proposal = proposals[proposalId];
            
            // Check if proposal can be executed
            if (proposal.executed ||
                block.timestamp <= proposal.endTime ||
                block.timestamp < proposal.timelockEnd ||
                proposal.forVotes <= proposal.againstVotes) {
                continue;
            }
            
            // Mark as executed
            proposal.executed = true;
            executedHashes[proposal.hashOfProposal] = true;
            totalProposalsExecuted++;
            
            // Execute based on proposal type
            ExtendedProposalData storage extData = proposalExtendedData[proposalId];
            uint8 pType = extData.proposalType;
            
            if (pType == PROPOSAL_TYPE_STANDARD) {
                // Execute standard proposal with calldata
                if (proposal.target != address(0) && proposal.callData.length > 0) {
                    (bool callSuccess, ) = proposal.target.call(proposal.callData);
                    if (callSuccess) {
                        successCount++;
                    }
                }
            } 
            else if (pType == PROPOSAL_TYPE_FEE_UPDATE) {
                _executeFeeUpdate(proposalId);
                successCount++;
            } 
            else if (pType == PROPOSAL_TYPE_PARAM_UPDATE) {
                _executeParamUpdate(proposalId);
                successCount++;
            } 
            else if (pType == PROPOSAL_TYPE_CONTRACT_UPDATE) {
                _executeContractUpdate(proposalId);
                successCount++;
            } 
            else if (pType == PROPOSAL_TYPE_PENALTY) {
                _executePenalty(proposalId);
                successCount++;
            } 
            else if (pType == PROPOSAL_TYPE_EMERGENCY) {
                _executeEmergency(proposalId);
                successCount++;
            }
            
            emit ProposalExecuted(proposalId, msg.sender);
        }
        
        emit BatchProposalsProcessed(proposalIds, successCount);
    }
    
    /**
     * @notice Check if a proposal can be executed
     * @param proposalId ID of the proposal to check
     * @return True if the proposal can be executed
     */
    function canExecuteProposal(uint256 proposalId) external view returns (bool) {
        if (proposalId == 0 || proposalId > proposalCount) return false;
        
        Proposal storage proposal = proposals[proposalId];
        
        return (
            !proposal.executed &&
            block.timestamp > proposal.endTime &&
            block.timestamp >= proposal.timelockEnd &&
            proposal.forVotes > proposal.againstVotes
        );
    }
    
    // -------------------------------------------
    // 🔹 Halving & Reward Management
    // -------------------------------------------
    
    /**
     * @notice Trigger automatic halving if the time has come
     */
    function triggerAutomaticHalving() external nonReentrant {
        if (block.timestamp < lastHalvingTime + TWO_YEARS) revert TimelockNotExpired();
        _applyHalving(true);
    }
    
    /**
     * @notice Apply halving to the reward rate
     * @param isAutomatic Whether this is an automatic halving or manual triggered
     */
    function _applyHalving(bool isAutomatic) internal {
        // Can only proceed if automatic halving is due or called through governance
        if (isAutomatic && block.timestamp < lastHalvingTime + TWO_YEARS) revert TimelockNotExpired();
        
        // Cut reward rate in half
        uint256 currentRate = rewardDistributor.rewardRate();
        uint256 newRate = currentRate / 2;
        
        // Update the reward rate in distributor
        rewardDistributor.setRewardRate(newRate);
        
        // Update halving state
        lastHalvingTime = block.timestamp;
        halvingEpoch++;
        
        emit HalvingTriggered(halvingEpoch, block.timestamp, isAutomatic);
        
        // Schedule the next automatic halving
        emit AutomaticHalvingScheduled(block.timestamp + TWO_YEARS);
    }
    
    // -------------------------------------------
    // 🔹 Emergency Management
    // -------------------------------------------
    
    /**
     * @notice Emergency function to recover ERC20 tokens sent to this contract
     * @param token Address of the token to recover
     * @param amount Amount of tokens to recover
     */
    function recoverERC20(address token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(token).transfer(treasuryWallet, amount);
        emit TokenRecovered(token, amount, treasuryWallet);
    }
    
    // -------------------------------------------
    // 🔹 Utility Functions
    // -------------------------------------------
    
    /**
     * @notice Perform square root calculation for quadratic voting
     * @param x Value to find the square root of
     * @return y The square root value
     */
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        
        uint256 z = (x + 1) / 2;
        y = x;
        
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
    
    // -------------------------------------------
// 🔹 View Functions
    // -------------------------------------------
    
    /**
     * @notice Validate that governance parameters are within safe ranges
     * @return True if all parameters are valid
     */
    function validateGovernanceParameters() external view returns (bool) {
        return (
            votingDuration >= 1 days && // Minimum 1 day voting period
            votingDuration <= 14 days && // Maximum 14 days voting period
            proposalThreshold >= 100 * 10**18 && // Minimum 100 tokens
            minimumHolding <= proposalThreshold && // Minimum holding <= proposal threshold
            feeUpdateCooldown >= 7 days // Minimum 7 days cooldown
        );
    }
    
    /**
     * @notice Get the current fee structure
     * @return The current fee structure
     */
    function getCurrentFeeStructure() external view returns (FeeProposal memory) {
        return currentFeeStructure;
    }
    
    /**
     * @notice Get a proposal by ID
     * @param proposalId ID of the proposal to get
     * @return The proposal data
     */
    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        if (proposalId == 0 || proposalId > proposalCount) revert ProposalDoesNotExist();
        return proposals[proposalId];
    }
    
    /**
     * @notice Get extended data for a proposal
     * @param proposalId ID of the proposal to get
     * @return Extended proposal data
     */
    function getProposalExtendedData(uint256 proposalId) external view returns (ExtendedProposalData memory) {
        if (proposalId == 0 || proposalId > proposalCount) revert ProposalDoesNotExist();
        return proposalExtendedData[proposalId];
    }
    
    /**
     * @notice Check if a proposal is still in its active voting period
     * @param proposalId ID of the proposal to check
     * @return True if the proposal is active
     */
    function isProposalActive(uint256 proposalId) external view returns (bool) {
        if (proposalId == 0 || proposalId > proposalCount) return false;
        
        Proposal storage proposal = proposals[proposalId];
        return (
            block.timestamp >= proposal.startTime &&
            block.timestamp <= proposal.endTime &&
            !proposal.executed
        );
    }
    
    /**
     * @notice Check if a proposal has succeeded in voting
     * @param proposalId ID of the proposal to check
     * @return True if the proposal has succeeded
     */
    function hasProposalSucceeded(uint256 proposalId) external view returns (bool) {
        if (proposalId == 0 || proposalId > proposalCount) return false;
        
        Proposal storage proposal = proposals[proposalId];
        return (
            proposal.forVotes > proposal.againstVotes &&
            block.timestamp > proposal.endTime &&
            !proposal.executed
        );
    }
    
    /**
     * @notice Get the unclaimed rewards percentage
     * @return The percentage of unclaimed rewards
     */
    function getUnclaimedRewardsPercentage() external view returns (uint256) {
        return rewardDistributor.getUnclaimedRewardsPercentage();
    }
    
    /**
     * @notice Get time until next halving
     * @return Seconds until next halving (0 if overdue)
     */
    function getTimeUntilNextHalving() external view returns (uint256) {
        uint256 nextHalvingTime = lastHalvingTime + TWO_YEARS;
        if (block.timestamp >= nextHalvingTime) {
            return 0;
        }
        return nextHalvingTime - block.timestamp;
    }
    
    /**
     * @notice Get voting power for an account
     * @param account Address to check
     * @return Voting power of the account
     */
    function getVotingPower(address account) external view returns (uint256) {
        return stakingContract.governanceVotes(account);
    }
    
    /**
     * @notice Get quadratic voting power for an account
     * @param account Address to check
     * @return Quadratic voting power of the account
     */
    function getQuadraticVotingPower(address account) external view returns (uint256) {
        uint256 votingPower = stakingContract.governanceVotes(account);
        return sqrt(votingPower);
    }
    
    /**
     * @notice Check if an account has voted on a proposal
     * @param proposalId ID of the proposal to check
     * @param account Address to check
     * @return True if the account has voted
     */
    function hasAccountVoted(uint256 proposalId, address account) external view returns (bool) {
        if (proposalId == 0 || proposalId > proposalCount) return false;
        return hasVoted[proposalId][account];
    }
    
    /**
     * @notice Check if an account meets the minimum holding requirement
     * @param account Address to check
     * @return True if the account meets the minimum holding
     */
    function meetsMinimumHolding(address account) external view returns (bool) {
        uint256 votingPower = stakingContract.governanceVotes(account);
        return votingPower >= minimumHolding;
    }
    
    /**
     * @notice Get proposal voting statistics
     * @param proposalId ID of the proposal to check
     * @return forVotes Total votes in favor
     * @return againstVotes Total votes against
     * @return totalVoters Count of total voters for this proposal
     */
    function getProposalVotingStats(uint256 proposalId) external view returns (
        uint256 forVotes,
        uint256 againstVotes,
        uint256 totalVoters
    ) {
        if (proposalId == 0 || proposalId > proposalCount) revert ProposalDoesNotExist();
        
        Proposal storage proposal = proposals[proposalId];
        forVotes = proposal.forVotes;
        againstVotes = proposal.againstVotes;
        
        // For simplicity, we don't track exact voter count per proposal
        // This would need a counter in the proposal structure
        totalVoters = 0; // This is a placeholder
    }
    
    /**
     * @notice Get remaining time for proposal voting
     * @param proposalId ID of the proposal to check
     * @return Time remaining in seconds (0 if ended)
     */
    function getProposalTimeRemaining(uint256 proposalId) external view returns (uint256) {
        if (proposalId == 0 || proposalId > proposalCount) revert ProposalDoesNotExist();
        
        Proposal storage proposal = proposals[proposalId];
        if (block.timestamp >= proposal.endTime) {
            return 0;
        }
        return proposal.endTime - block.timestamp;
    }
    
    /**
     * @notice Get the current implementation address (for UUPS)
     * @return The implementation address
     */
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }
    
    /**
     * @notice Check if the protocol pricing is stable
     * @return True if price is stable
     */
    function isPriceStable() external view returns (bool) {
        return liquidityGuard.isPriceStable();
    }
    
    /**
     * @notice Get total votes cast across all proposals
     * @return The total number of votes cast
     */
    function getTotalVotesCast() external view returns (uint256) {
        return totalVotesCast;
    }
    
    /**
     * @notice Get overall governance statistics
     * @return propCount Total number of proposals
     * @return executedCount Total number of executed proposals
     * @return activeProposalCount Number of currently active proposals
     */
    function getGovernanceStats() external view returns (
        uint256 propCount,
        uint256 executedCount,
        uint256 activeProposalCount
    ) {
        propCount = proposalCount;
        executedCount = totalProposalsExecuted;
        
        // Calculate active proposals (could be optimized with a counter)
        uint256 active = 0;
        for (uint256 i = 1; i <= proposalCount; i++) {
            Proposal storage prop = proposals[i];
            if (!prop.executed && 
                block.timestamp >= prop.startTime && 
                block.timestamp <= prop.endTime) {
                active++;
            }
        }
        
        activeProposalCount = active;
    }
    
    /**
     * @notice Batch check if multiple accounts meet minimum holding
     * @param accounts Array of addresses to check
     * @return Array of booleans indicating if each account meets minimum
     */
    function batchCheckMinimumHolding(address[] calldata accounts) external view returns (bool[] memory) {
        bool[] memory results = new bool[](accounts.length);
        
        for (uint256 i = 0; i < accounts.length; i++) {
            uint256 votingPower = stakingContract.governanceVotes(accounts[i]);
            results[i] = votingPower >= minimumHolding;
        }
        
        return results;
    }
    
    /**
     * @notice Get the timestamp of the next halving
     * @return Timestamp when next halving will occur
     */
    function getNextHalvingTime() external view returns (uint256) {
        return lastHalvingTime + TWO_YEARS;
    }
    
    /**
     * @notice Implementation of the {IERC165} interface
     * @param interfaceId Interface ID to check
     * @return True if the interface is supported
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(AccessControlEnumerableUpgradeable) returns (bool) {
        return
            interfaceId == type(ITerraStakeGovernance).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
