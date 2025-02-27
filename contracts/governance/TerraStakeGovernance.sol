// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeERC20Upgradeable, IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/ITerraStakeRewardDistributor.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";
import "../interfaces/ITerraStakeGovernance.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/**
 * @title TerraStakeGovernance
 * @notice Manages governance, voting, liquidity pairing, and economic adjustments in the TerraStake ecosystem.
 * @dev Implements quadratic voting, governance-controlled staking rewards, liquidity protection, and upgradeability.
 */
contract TerraStakeGovernance is
    Initializable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    ITerraStakeGovernance
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using Address for address;

    // -------------------------------------------
    // 🔹 Custom Errors (Gas Optimized)
    // -------------------------------------------
    error UnauthorizedCaller();
    error ProposalAlreadyExecuted();
    error ProposalNotReady();
    error InvalidParameters();
    error GovernanceViolation();
    error TimelockNotExpired();
    error InsufficientBalance();
    error GovernanceThresholdNotMet();
    error InvalidVote();
    error ProposalDoesNotExist();
    error NoActiveProposal();
    error PendingOperationRequired();
    error InvalidProposalState();

    // -------------------------------------------
    // 🔹 Governance Constants
    // -------------------------------------------
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE"); // Only for circuit breaker in extreme cases
    
    uint256 private constant TWO_YEARS = 63_072_000; // 2 years in seconds for automatic halving
    uint256 private constant PENALTY_FOR_VIOLATION = 5; // 5% stake slashing for governance abuse
    uint256 public constant TIMELOCK_DURATION = 2 days;
    uint24 public constant POOL_FEE = 3000;
    uint256 private constant AUTO_HALVING_THRESHOLD = 60; // 60% unclaimed rewards trigger halving
    
    // Proposal types
    uint8 private constant PROPOSAL_TYPE_STANDARD = 0;
    uint8 private constant PROPOSAL_TYPE_FEE_UPDATE = 1;
    uint8 private constant PROPOSAL_TYPE_PARAM_UPDATE = 2;
    uint8 private constant PROPOSAL_TYPE_CONTRACT_UPDATE = 3;
    uint8 private constant PROPOSAL_TYPE_PENALTY = 4;
    uint8 private constant PROPOSAL_TYPE_EMERGENCY = 5;

    // -------------------------------------------
    // 🔹 Governance State Variables
    // -------------------------------------------
    uint256 public proposalCount;
    uint256 public votingDuration;
    uint256 public proposalThreshold;
    uint256 public minimumHolding;
    uint256 public totalVotesCast;
    uint256 public totalProposalsExecuted;
    uint256 public feeUpdateCooldown;
    uint256 public lastFeeUpdateTime;
    bool public liquidityPairingEnabled;

    mapping(address => uint256) public governanceVotes;
    mapping(address => bool) public penalizedGovernors;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(bytes32 => bool) public executedHashes;

    uint256 public halvingPeriod;  // Will be set to TWO_YEARS for automatic halving
    uint256 public lastHalvingTime;
    uint256 public halvingEpoch;

    ITerraStakeStaking public stakingContract;
    ITerraStakeRewardDistributor public rewardDistributor;
    ITerraStakeLiquidityGuard public liquidityGuard;
    ISwapRouter public uniswapRouter;
    IQuoter public uniswapQuoter;
    IUniswapV3Pool public uniswapPool;
    IERC1155 public nftContract;
    IERC20Upgradeable public usdcToken;
    IERC20Upgradeable public tStakeToken;
    
    address public treasuryWallet;

    struct FeeProposal {
        uint256 projectSubmissionFee;
        uint256 impactReportingFee;
        uint256 buybackPercentage;
        uint256 liquidityPairingPercentage;
        uint256 burnPercentage;
        uint256 treasuryPercentage;
        uint256 voteEnd;
        bool executed;
    }

    FeeProposal public currentFeeStructure;
    FeeProposal public pendingFeeProposal;
    
    // Extended proposal struct to handle multiple types of proposals
    struct ExtendedProposalData {
        uint8 proposalType;
        FeeProposal feeData;
        address[] contractAddresses;
        uint256[] numericParams;
        address[] accountsToUpdate;
        bool[] boolParams;
    }
    
    mapping(uint256 => ExtendedProposalData) public proposalExtendedData;

    // -------------------------------------------
    // 🔹 Events
    // -------------------------------------------
    event GovernanceParametersUpdated(uint256 newVotingDuration, uint256 newProposalThreshold, uint256 newMinimumHolding);
    event RewardRateAdjusted(uint256 newRate, uint256 timestamp);
    event TokenRecovered(address indexed token, uint256 amount, address indexed recipient);
    event LiquidityPairingToggled(bool enabled);
    event HalvingTriggered(uint256 epoch, uint256 timestamp, bool isAutomatic);
    event ProposalExecuted(uint256 indexed proposalId, address indexed executor);
    event GovernanceVoteCast(address indexed voter, uint256 indexed proposalId, bool vote);
    event GovernanceViolationDetected(address indexed violator, uint256 penaltyAmount);
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        bytes32 hashOfProposal,
        uint256 startTime,
        uint256 endTime,
        string description,
        uint8 proposalType
    );
    event FeeProposalCreated(
        uint256 proposalId,
        uint256 projectSubmissionFee,
        uint256 impactReportingFee,
        uint256 buybackPercentage,
        uint256 liquidityPairingPercentage,
        uint256 burnPercentage,
        uint256 treasuryPercentage
    );
    event FeeStructureUpdated(
        uint256 projectSubmissionFee,
        uint256 impactReportingFee,
        uint256 buybackPercentage,
        uint256 liquidityPairingPercentage,
        uint256 burnPercentage,
        uint256 treasuryPercentage
    );
    event GovernanceContractsUpdated(
        address stakingContract,
        address rewardDistributor,
        address liquidityGuard
    );
    event TreasuryWalletUpdated(address newTreasuryWallet);
    event RewardBuybackExecuted(uint256 usdcAmount, uint256 tokensReceived);
    event AutomaticHalvingScheduled(uint256 nextHalvingTime);
    event EmergencyActionTriggered(uint256 proposalId, string action);
    event EmergencyActionResolved(uint256 proposalId, string action);
    event BatchProposalsProcessed(uint256[] proposalIds, uint256 successCount);

    // -------------------------------------------
    // 🔹 Initialization
    // -------------------------------------------
    function initialize(
        address _stakingContract,
        address _rewardDistributor,
        address _liquidityGuard,
        address _uniswapRouter,
        address _uniswapQuoter,
        address _uniswapPool,
        address _nftContract,
        address _treasuryWallet,
        address _usdcToken,
        address _tStakeToken,
        uint256 _votingDuration,
        uint256 _proposalThreshold,
        uint256 _minimumHolding,
        uint256 _feeUpdateCooldown
    ) external initializer {
        if (
            _stakingContract == address(0) ||
            _rewardDistributor == address(0) ||
            _liquidityGuard == address(0) ||
            _uniswapRouter == address(0) ||
            _uniswapQuoter == address(0) ||
            _uniswapPool == address(0) ||
            _nftContract == address(0) ||
            _treasuryWallet == address(0) ||
            _usdcToken == address(0) ||
            _tStakeToken == address(0)
        ) revert InvalidParameters();

        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);

        stakingContract = ITerraStakeStaking(_stakingContract);
        rewardDistributor = ITerraStakeRewardDistributor(_rewardDistributor);
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);
        uniswapRouter = ISwapRouter(_uniswapRouter);
        uniswapQuoter = IQuoter(_uniswapQuoter);
        uniswapPool = IUniswapV3Pool(_uniswapPool);
        nftContract = IERC1155(_nftContract);
        treasuryWallet = _treasuryWallet;
        usdcToken = IERC20Upgradeable(_usdcToken);
        tStakeToken = IERC20Upgradeable(_tStakeToken);

        votingDuration = _votingDuration;
        proposalThreshold = _proposalThreshold;
        minimumHolding = _minimumHolding;
        halvingPeriod = TWO_YEARS; // Fixed at 2 years as per requirements
        feeUpdateCooldown = _feeUpdateCooldown;

        lastHalvingTime = block.timestamp;
        halvingEpoch = 0;
        liquidityPairingEnabled = true;

        currentFeeStructure = FeeProposal(6100, 2200, 5, 10, 50, 35, 0, true);
        
        // Schedule the first automatic halving for 2 years from now
        emit AutomaticHalvingScheduled(block.timestamp + TWO_YEARS);
    }

    // -------------------------------------------
    // 🔹 Core Governance Functions
    // -------------------------------------------

    /**
     * @notice Authorize contract upgrade
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        // Upgrades should ideally go through DAO proposal process
        // This is a safety mechanism that requires the UPGRADER_ROLE
    }

    /**
     * @notice Recover accidentally sent ERC20 tokens
     * @param token The address of the token to recover
     * @param amount The amount to recover
     */
    function recoverERC20(address token, uint256 amount) external onlyRole(EMERGENCY_ROLE) {
        if (token == address(tStakeToken)) revert UnauthorizedCaller();
        if (amount == 0) revert InsufficientBalance();
        IERC20Upgradeable(token).safeTransfer(treasuryWallet, amount);
        emit TokenRecovered(token, amount, treasuryWallet);
    }

    /**
     * @notice Creates a new standard governance proposal
     * @param proposalHash Hash of the proposal details
     * @param description Description of the proposal
     * @param callData Data to be executed if proposal passes
     * @param target Target contract for execution
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
     * @notice Creates a new proposal for updating fee structure
     * @param proposalHash Hash of the proposal details
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
     * @param violator Address of the alleged violator
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
     * @notice Creates a proposal for emergency actions
     * @param proposalHash Hash of the proposal details
     * @param description Description of the proposal
     * @param haltOperations Whether to halt operations
     * @return proposalId The ID of the newly created proposal
     */
    function createEmergencyProposal(
        bytes32 proposalHash,
        string calldata description,
        bool haltOperations
    ) external nonReentrant returns (uint256) {
        uint256 votingPower = stakingContract.governanceVotes(msg.sender);
        if (votingPower < proposalThreshold) revert GovernanceThresholdNotMet();
        if (penalizedGovernors[msg.sender]) revert GovernanceViolation();
        
        uint256 proposalId = _createBaseProposal(
            proposalHash, 
            description, 
            "", // No calldata for emergency proposals
            address(0), // No target for emergency proposals
            PROPOSAL_TYPE_EMERGENCY
        );
        
        // Store emergency action
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        extData.boolParams = new bool[](1);
        extData.boolParams[0] = haltOperations; // true to halt, false to resume
        
        return proposalId;
    }
    
    /**
     * @notice Internal function to create base proposal structure
     * @param proposalHash Hash of the proposal details
     * @param description Description of the proposal
     * @param callData Data to be executed if proposal passes
     * @param target Target contract for execution
     * @param proposalType Type of proposal (standard, fee, param, etc.)
     * @return proposalId The ID of the newly created proposal
     */
    function _createBaseProposal(
        bytes32 proposalHash,
        string calldata description,
        bytes calldata callData,
        address target,
        uint8 proposalType
    ) internal returns (uint256) {
        proposalCount++;
        uint256 proposalId = proposalCount;
        
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + votingDuration;
        
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
        newProposal.timelockEnd = endTime + TIMELOCK_DURATION;
        
        // Create extended data with proposal type
        proposalExtendedData[proposalId].proposalType = proposalType;
        
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
     * @notice Vote on a governance proposal with quadratic voting
     * @param proposalId ID of the proposal to vote on
     * @param support True to vote for, false to vote against
     */
    function castVote(uint256 proposalId, bool support) external nonReentrant {
        if (proposalId == 0 || proposalId > proposalCount) revert ProposalDoesNotExist();
        
        Proposal storage proposal = proposals[proposalId];
        
        if (block.timestamp >= proposal.endTime) revert ProposalNotReady();
        if (block.timestamp < proposal.startTime) revert ProposalNotReady();
        if (hasVoted[proposalId][msg.sender]) revert InvalidVote();
        if (penalizedGovernors[msg.sender]) revert GovernanceViolation();
        
        uint256 votingPower = stakingContract.governanceVotes(msg.sender);
        if (votingPower < minimumHolding) revert GovernanceThresholdNotMet();
        
        // Calculate quadratic voting power (sqrt of voting power)
        uint256 quadraticVotes = sqrt(votingPower);
        
        if (support) {
            proposal.forVotes += quadraticVotes;
        } else {
            proposal.againstVotes += quadraticVotes;
        }
        
        hasVoted[proposalId][msg.sender] = true;
        totalVotesCast++;
        
        emit GovernanceVoteCast(msg.sender, proposalId, support);
    }
    
    /**
     * @notice Execute a passed proposal after timelock period
     * @param proposalId ID of the proposal to execute
     */
    function executeProposal(uint256 proposalId) external nonReentrant {
        if (proposalId == 0 || proposalId > proposalCount) revert ProposalDoesNotExist();
        
        Proposal storage proposal = proposals[proposalId];
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (block.timestamp <= proposal.endTime) revert ProposalNotReady();
        if (block.timestamp < proposal.timelockEnd) revert TimelockNotExpired();
        
        // Verify proposal passed (more votes for than against)
        if (proposal.forVotes <= proposal.againstVotes) revert GovernanceThresholdNotMet();
        
        // Verify proposal hash not already executed (prevent replay)
        if (executedHashes[proposal.hashOfProposal]) revert ProposalAlreadyExecuted();
        
        // Set as executed
        proposal.executed = true;
        executedHashes[proposal.hashOfProposal] = true;
        totalProposalsExecuted++;
        
        // Execute the proposal based on its type
        uint8 pType = extData.proposalType;
        
        if (pType == PROPOSAL_TYPE_STANDARD) {
            // Execute standard proposal with calldata
            if (proposal.target != address(0) && proposal.callData.length > 0) {
                (bool success, ) = proposal.target.call(proposal.callData);
                if (!success) revert InvalidProposalState();
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
            _executeEmergencyAction(proposalId);
        }
        
        emit ProposalExecuted(proposalId, msg.sender);
    }
    
    /**
     * @notice Batch process multiple proposals that are ready for execution
     * @param proposalIds Array of proposal IDs to process
     */
function batchProcessProposals(uint256[] calldata proposalIds) external nonReentrant {
        uint256 successCount = 0;
        
        for (uint256 i = 0; i < proposalIds.length; i++) {
            uint256 proposalId = proposalIds[i];
            
            // Only execute if the proposal is in executable state
            if (canExecuteProposal(proposalId)) {
                Proposal storage proposal = proposals[proposalId];
                ExtendedProposalData storage extData = proposalExtendedData[proposalId];
                
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
                    _executeEmergencyAction(proposalId);
                }
                
                if (success) {
                    successCount++;
                    emit ProposalExecuted(proposalId, msg.sender);
                }
            }
        }
        
        emit BatchProposalsProcessed(proposalIds, successCount);
    }
    
    /**
     * @notice Check if a proposal can be executed
     * @param proposalId ID of the proposal to check
     * @return True if the proposal can be executed
     */
    function canExecuteProposal(uint256 proposalId) public view returns (bool) {
        if (proposalId == 0 || proposalId > proposalCount) return false;
        
        Proposal storage proposal = proposals[proposalId];
        
        return (
            !proposal.executed &&
            block.timestamp > proposal.endTime &&
            block.timestamp >= proposal.timelockEnd &&
            proposal.forVotes > proposal.againstVotes &&
            !executedHashes[proposal.hashOfProposal]
        );
    }

    /**
     * @notice Internal function to execute fee structure updates
     * @param proposalId ID of the proposal to execute
     */
    function _executeFeeUpdate(uint256 proposalId) internal {
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        FeeProposal storage feeData = extData.feeData;
        
        // Update the current fee structure
        currentFeeStructure = FeeProposal(
            feeData.projectSubmissionFee,
            feeData.impactReportingFee,
            feeData.buybackPercentage,
            feeData.liquidityPairingPercentage,
            feeData.burnPercentage,
            feeData.treasuryPercentage,
            0,
            true
        );
        
        lastFeeUpdateTime = block.timestamp;
        
        emit FeeStructureUpdated(
            currentFeeStructure.projectSubmissionFee,
            currentFeeStructure.impactReportingFee,
            currentFeeStructure.buybackPercentage,
            currentFeeStructure.liquidityPairingPercentage,
            currentFeeStructure.burnPercentage,
            currentFeeStructure.treasuryPercentage
        );
    }
    
    /**
     * @notice Internal function to execute parameter updates
     * @param proposalId ID of the proposal to execute
     */
    function _executeParamUpdate(uint256 proposalId) internal {
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        uint256[] memory params = extData.numericParams;
        
        // Update governance parameters
        votingDuration = params[0];
        proposalThreshold = params[1];
        minimumHolding = params[2];
        feeUpdateCooldown = params[3];
        
        emit GovernanceParametersUpdated(votingDuration, proposalThreshold, minimumHolding);
    }
    
    /**
     * @notice Internal function to execute contract reference updates
     * @param proposalId ID of the proposal to execute
     */
    function _executeContractUpdate(uint256 proposalId) internal {
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        address[] memory contracts = extData.contractAddresses;
        
        // Validate new contract addresses
        for (uint256 i = 0; i < contracts.length; i++) {
            if (contracts[i] == address(0)) revert InvalidParameters();
        }
        
        // Update contract references
        stakingContract = ITerraStakeStaking(contracts[0]);
        rewardDistributor = ITerraStakeRewardDistributor(contracts[1]);
        liquidityGuard = ITerraStakeLiquidityGuard(contracts[2]);
        treasuryWallet = contracts[3];
        
        emit GovernanceContractsUpdated(contracts[0], contracts[1], contracts[2]);
        emit TreasuryWalletUpdated(contracts[3]);
    }
    
    /**
     * @notice Internal function to execute penalty against governance violator
     * @param proposalId ID of the proposal to execute
     */
    function _executePenalty(uint256 proposalId) internal {
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        address violator = extData.accountsToUpdate[0];
        
        if (penalizedGovernors[violator]) return; // Already penalized
        
        penalizedGovernors[violator] = true;
        
        // Calculate penalty amount
        uint256 stakedAmount = stakingContract.getUserStake(violator);
        uint256 penaltyAmount = (stakedAmount * PENALTY_FOR_VIOLATION) / 100;
        
        // Slash stake
        if (penaltyAmount > 0) {
            stakingContract.slashStake(violator, penaltyAmount);
        }
        
        emit GovernanceViolationDetected(violator, penaltyAmount);
    }
    
    /**
     * @notice Internal function to execute emergency actions
     * @param proposalId ID of the proposal to execute
     */
    function _executeEmergencyAction(uint256 proposalId) internal {
        ExtendedProposalData storage extData = proposalExtendedData[proposalId];
        bool haltOperations = extData.boolParams[0];
        
        if (haltOperations) {
            // Trigger circuit breaker in liquidity guard
            liquidityGuard.triggerCircuitBreaker();
            
            // Stop staking rewards
            rewardDistributor.pause();
            
            emit EmergencyActionTriggered(proposalId, "System operations halted");
        } else {
            // Reset circuit breaker
            liquidityGuard.resetCircuitBreaker();
            
            // Resume staking rewards
            rewardDistributor.unpause();
            
            emit EmergencyActionResolved(proposalId, "System operations resumed");
        }
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
    
    // -------------------------------------------
    // 🔹 Halving and Reward Management
    // -------------------------------------------
    
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
     * @notice Execute a buyback proposal
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
        
        uint256 usdcAmount = extData.numericParams[0];
        if (usdcAmount == 0 || usdcAmount > usdcToken.balanceOf(address(this))) 
            revert InvalidParameters();
        
        // Mark as executed
        proposal.executed = true;
        executedHashes[proposal.hashOfProposal] = true;
        totalProposalsExecuted++;
        
        // Approve USDC for Uniswap router
        usdcToken.approve(address(uniswapRouter), usdcAmount);
        
        uint256 balanceBefore = tStakeToken.balanceOf(address(this));
        
        // Execute swap via Uniswap
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(usdcToken),
            tokenOut: address(tStakeToken),
            fee: POOL_FEE,
            recipient: address(this),
            deadline: block.timestamp + 15 minutes,
            amountIn: usdcAmount,
            amountOutMinimum: 0, // Could add slippage protection here
            sqrtPriceLimitX96: 0
        });
        
        uniswapRouter.exactInputSingle(params);
        
        uint256 tokensReceived = tStakeToken.balanceOf(address(this)) - balanceBefore;
        
        // Distribute purchased tokens as rewards
        tStakeToken.approve(address(rewardDistributor), tokensReceived);
        rewardDistributor.addRewards(tokensReceived);
        
        emit RewardBuybackExecuted(usdcAmount, tokensReceived);
        emit ProposalExecuted(proposalId, msg.sender);
    }
    
    /**
     * @notice Trigger halving of rewards - can only be triggered automatically
     */
    function triggerAutomaticHalving() external {
        // Check if it's time for the halving (2 years since last halving)
        if (block.timestamp < lastHalvingTime + TWO_YEARS) revert TimelockNotExpired();
        
        _applyHalving(true);
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
     * @notice Validate that governance parameters are in a valid state
     * @return True if all governance parameters are valid
     */
    function validateGovernanceParameters() external view returns (bool) {
        return (
            votingDuration > 0 &&
            proposalThreshold > 0 &&
            minimumHolding > 0 &&
            treasuryWallet != address(0)
        );
    }
    
    /**
     * @notice Get the current fee structure
     * @return FeeProposal struct containing current fee details
     */
    function getCurrentFeeStructure() external view returns (FeeProposal memory) {
        return currentFeeStructure;
    }
    
    /**
     * @notice Get a proposal by ID
     * @param proposalId ID of the proposal to query
     * @return Proposal struct containing proposal details
     */
    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }
    
    /**
     * @notice Get extended data for a proposal
     * @param proposalId ID of the proposal to query
     * @return ExtendedProposalData struct containing additional proposal details
     */
    function getProposalExtendedData(uint256 proposalId) external view returns (ExtendedProposalData memory) {
        return proposalExtendedData[proposalId];
    }
    
    /**
     * @notice Check if a proposal is active for voting
     * @param proposalId ID of the proposal to check
     * @return True if proposal is active
     */
    function isProposalActive(uint256 proposalId) external view returns (bool) {
        Proposal storage proposal = proposals[proposalId];
        return (
            block.timestamp >= proposal.startTime &&
            block.timestamp <= proposal.endTime &&
            !proposal.executed
        );
    }
    
    /**
     * @notice Check if a proposal has succeeded and is ready for execution
     * @param proposalId ID of the proposal to check
     * @return True if proposal has succeeded
     */
    function hasProposalSucceeded(uint256 proposalId) external view returns (bool) {
        Proposal storage proposal = proposals[proposalId];
        return (
            !proposal.executed &&
            block.timestamp > proposal.endTime &&
            proposal.forVotes > proposal.againstVotes
        );
    }
    
    /**
     * @notice Get the number of unclaimed rewards as a percentage
     * @return Percentage of unclaimed rewards
     */
    function getUnclaimedRewardsPercentage() external view returns (uint256) {
        return rewardDistributor.getUnclaimedRewardsPercentage();
    }
    
    /**
     * @notice Get the time until next automatic halving
     * @return Time in seconds until next halving or 0 if overdue
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
     * @param account Address to check voting power for
     * @return votingPower The account's voting power
     */
    function getVotingPower(address account) external view returns (uint256) {
        if (penalizedGovernors[account]) return 0;
        return stakingContract.governanceVotes(account);
    }
    
    /**
     * @notice Get quadratic voting power for an account
     * @param account Address to check quadratic voting power for
     * @return votingPower The account's quadratic voting power
     */
    function getQuadraticVotingPower(address account) external view returns (uint256) {
        if (penalizedGovernors[account]) return 0;
        uint256 rawVotingPower = stakingContract.governanceVotes(account);
        return sqrt(rawVotingPower);
    }
    
    /**
     * @notice Check if an account has voted on a specific proposal
     * @param proposalId ID of the proposal
     * @param account Address to check
     * @return True if account has voted
     */
    function hasAccountVoted(uint256 proposalId, address account) external view returns (bool) {
        return hasVoted[proposalId][account];
    }
    
    /**
     * @notice Check if account meets minimum holding requirement for governance
     * @param account Address to check
     * @return True if account meets minimum holding requirement
     */
    function meetsMinimumHolding(address account) external view returns (bool) {
        if (penalizedGovernors[account]) return false;
        return stakingContract.governanceVotes(account) >= minimumHolding;
    }
    
    /**
     * @notice Get voting stats for a proposal
     * @param proposalId ID of the proposal
     * @return forVotes Number of votes in favor
     * @return againstVotes Number of votes against
     * @return totalVoters Total number of voters
     */
    function getProposalVotingStats(uint256 proposalId) external view returns (
        uint256 forVotes,
        uint256 againstVotes,
        uint256 totalVoters
    ) {
        Proposal storage proposal = proposals[proposalId];
        forVotes = proposal.forVotes;
        againstVotes = proposal.againstVotes;
        
        // Count total voters for this proposal
        uint256 votersCount = 0;
        uint256 voterRoleCount = getRoleMemberCount(GOVERNANCE_ROLE);
        for (uint256 i = 0; i < voterRoleCount; i++) {
            address voter = getRoleMember(GOVERNANCE_ROLE, i);
            if (hasVoted[proposalId][voter]) {
                votersCount++;
            }
        }
        
        return (forVotes, againstVotes, votersCount);
    }
    
    /**
     * @notice Get remaining time for a proposal's voting period
     * @param proposalId ID of the proposal
     * @return timeRemaining Time remaining in seconds or 0 if ended
     */
    function getProposalTimeRemaining(uint256 proposalId) external view returns (uint256) {
        Proposal storage proposal = proposals[proposalId];
        if (block.timestamp >= proposal.endTime) {
            return 0;
        }
        return proposal.endTime - block.timestamp;
    }
    
    /**
     * @notice Get the current implementation address of this contract
     * @return The implementation address
     */
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }
    
    /**
     * @notice Check if price stability requirements are met for governance actions
     * @return True if price is stable according to the liquidity guard
     */
    function isPriceStable() external view returns (bool) {
        return liquidityGuard.verifyTWAPForWithdrawal();
    }
    
    /**
     * @notice Get total proposal votes cast across all proposals
     * @return Total votes cast
     */
    function getTotalVotesCast() external view returns (uint256) {
        return totalVotesCast;
    }
    
    /**
     * @notice Get governance statistics
     * @return proposalCount Total number of proposals created
     * @return executedCount Total number of executed proposals
     * @return activeProposalCount Active proposal count
     */
    function getGovernanceStats() external view returns (
        uint256 propCount,
        uint256 executedCount,
        uint256 activeProposalCount
    ) {
        uint256 active = 0;
        
        for (uint256 i = 1; i <= proposalCount; i++) {
            if (block.timestamp >= proposals[i].startTime && 
                block.timestamp <= proposals[i].endTime &&
                !proposals[i].executed) {
                active++;
            }
        }
        
        return (proposalCount, totalProposalsExecuted, active);
    }
    
    /**
     * @notice Batch function to check if multiple accounts meet minimum holding
     * @param accounts Array of addresses to check
     * @return results Array of boolean results
     */
    function batchCheckMinimumHolding(address[] calldata accounts) external view returns (bool[] memory results) {
        uint256 length = accounts.length;
        results = new bool[](length);
        
        for (uint256 i = 0; i < length; i++) {
            if (penalizedGovernors[accounts[i]]) {
                results[i] = false;
            } else {
                results[i] = stakingContract.governanceVotes(accounts[i]) >= minimumHolding;
            }
        }
        
        return results;
    }
    
    /**
     * @notice Get the next scheduled halving time
     * @return timestamp Timestamp of next halving
     */
    function getNextHalvingTime() external view returns (uint256) {
        return lastHalvingTime + TWO_YEARS;
    }
}
