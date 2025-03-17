// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;


import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";             // Added for pausing functionality
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/IERC1155Upgradeable.sol";                 // Added for UUPS upgradeability
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import "@uniswap/v4-core/contracts/types/PoolKey.sol";
import "@uniswap/v4-core/contracts/types/BalanceDelta.sol";

import "../interfaces/ITerraStakeProjects.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/ITerraStakeValidatorSafety.sol";
import "../interfaces/ITerraStakeRewardDistributor.sol";  // Added missing reward distributor interface
import "../interfaces/ITerraStakeGovernance.sol";           // Added missing governance interface
import "../interfaces/ITerraStakeSlashing.sol"; 

/**
 * @title TerraStake Staking Contract
 * @notice Manages core staking operations and validator activities
 * @dev Implements upgradeable contracts pattern
 */
contract TerraStakeStaking is 
    Initializable,
    ReentrancyGuardUpgradeable,
    AccessControlEnumerableUpgradeable,
    ERC165Upgradeable,
    PausableUpgradeable,         // Added inheritance
    UUPSUpgradeable,             // Added inheritance
    ITerraStakeStaking
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
        // -------------------------------------------
        //   Constants
        // -------------------------------------------
        
        /// @notice Role for governance-related actions
        bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
        
        /// @notice Role for contract upgrade operations
        bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
        
        /// @notice Role for emergency actions like pausing
        bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
        
        /// @notice Role for validator slashing authority
        bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
        
        /// @notice Role for operational management
        bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
        
        /// @notice Base Annual Percentage Rate (10%)
        uint256 public constant BASE_APR = 10;
        
        /// @notice Boosted APR when TVL is below threshold (20%)
        uint256 public constant BOOSTED_APR = 20;
        
        /// @notice Additional APR boost for NFT holders (10%)
        uint256 public constant NFT_APR_BOOST = 10;
        
        /// @notice Additional APR boost for LP token stakers (15%)
        uint256 public constant LP_APR_BOOST = 15;
        
        /// @notice Base early withdrawal penalty percentage (10%)
        uint256 public constant BASE_PENALTY_PERCENT = 10;
        
        /// @notice Maximum early withdrawal penalty percentage (30%)
        uint256 public constant MAX_PENALTY_PERCENT = 30;
        
        /// @notice Threshold below which boosted APR applies (1M TSTAKE)
        uint256 public constant LOW_STAKING_THRESHOLD = 1_000_000 * 10**18;
        
        /// @notice Vesting period for governance actions
        uint256 public constant GOVERNANCE_VESTING_PERIOD = 7 days;
        
        /// @notice Maximum allowed rate for auto-liquidity injection (10%)
        uint256 public constant MAX_LIQUIDITY_RATE = 10;
        
        /// @notice Minimum staking duration (30 days)
        uint256 public constant MIN_STAKING_DURATION = 30 days;
        
        /// @notice Minimum tokens required for governance participation
        uint256 public constant GOVERNANCE_THRESHOLD = 10_000 * 10**18;
        
        /// @notice Maximum commission rate for validators (20%)
        uint256 public constant MAX_VALIDATOR_COMMISSION = 2000; // basis points
        
        /// @notice Default commission rate for new validators (5%)
        uint256 public constant DEFAULT_VALIDATOR_COMMISSION = 500; // basis points
        
        /// @notice Cooldown period between halving events
        uint256 public constant MIN_HALVING_COOLDOWN = 180 days;
        
        /// @notice Basis points denominator (100%)
        uint256 public constant BASIS_POINTS = 10000;
        
        /// @notice Minimum number of active validators required
        uint256 public constant MIN_ACTIVE_VALIDATORS = 3;
        
        /// @notice Maximum range for dynamic APR adjustment per update (2%)
        uint256 public constant MAX_APR_ADJUSTMENT = 2;
        
        /// @notice Dead address for token burning
        address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
        
        /// @notice Default Uniswap V4 pool fee tier (0.3%)
        uint24 public constant UNISWAP_V4_FEE_TIER = 3000; // 0.3% fee (Uniswap V4 default)
        
        /// @notice Minimum required liquidity in Uniswap V4 before auto-injections
        uint256 public constant MIN_UNISWAP_LIQUIDITY_THRESHOLD = 10_000 * 10**18; // 10K tokens
        
        /// @notice Volatility factor adjustment limit (max ±5%)
        uint256 public constant MAX_VOLATILITY_ADJUSTMENT = 500; // 500 basis points (5%)
        
        /// @notice TWAP observation window for Uniswap V4 price calculations
        uint32 public constant UNISWAP_TWAP_INTERVAL = 1800; // 30-minute TWAP
        
        /// @notice Default slippage tolerance for Uniswap V4 liquidity injections
        uint256 public constant UNISWAP_SLIPPAGE_TOLERANCE = 200; // 2% slippage tolerance
// -------------------------------------------
//   State Variables 
// -------------------------------------------

/// @notice NFT contract for boost eligibility verification
IERC1155 public nftContract;

/// @notice The TSTAKE token that can be staked
IERC20Upgradeable public stakingToken;

/// @notice Contract responsible for distributing staking rewards
ITerraStakeRewardDistributor public rewardDistributor;

/// @notice Registry of all staking projects
ITerraStakeProjects public projectsContract;

/// @notice Governance contract for proposal management
ITerraStakeGovernance public governanceContract;

/// @notice Contract responsible for validator slashing
ITerraStakeSlashing public slashingContract;

/// @notice Contract for validator safety and management
IValidatorSafety public validatorSafety;

/// @notice Address of the liquidity pool for auto-injection
address public liquidityPool;

/// @notice Price data provider for TSTAKE/USD pricing
IUniswapV4DataProvider public priceDataProvider;

/// @notice Percentage of rewards reinjected into liquidity (0-10%)
uint256 public liquidityInjectionRate;

/// @notice Whether auto-liquidity is currently enabled
bool public autoLiquidityEnabled;

/// @notice Period between reward halving events (e.g., 730 days)
uint256 public halvingPeriod;

/// @notice Timestamp of the last halving event
uint256 public lastHalvingTime;

/// @notice Current halving epoch (increments with each halving)
uint256 public halvingEpoch;

/// @notice Counter for governance proposals
uint256 public proposalNonce;

/// @notice Minimum tokens required to become a validator
uint256 public validatorThreshold;

/// @notice Total amount of validator rewards waiting to be claimed
uint256 public validatorRewardPool;

/// @notice Minimum percentage of voting power required for a proposal to pass
uint256 public governanceQuorum;

/// @notice Whether dynamic reward rate adjustment is enabled
bool public dynamicRewardsEnabled;

/// @notice Timestamp of last dynamic reward rate adjustment
uint256 public lastRewardAdjustmentTime;

/// @notice Current base APR if dynamic rewards are enabled
uint256 public dynamicBaseAPR;

/// @notice Current boosted APR if dynamic rewards are enabled
uint256 public dynamicBoostedAPR;

/// @notice Last recorded TSTAKE market price in USD (scaled by 1e18)
uint256 public lastTokenPrice;

/// @notice Timestamp of the last price update
uint256 public lastPriceUpdateTime;

/// @notice Total value locked in USD (scaled by 1e18)
uint256 public tvlInUSD;

/// @notice Next reward cycle start time
uint256 public nextRewardCycleStart;

/// @notice Duration of each reward distribution cycle
uint256 public rewardCycleDuration;

/// @notice Fee collector address for protocol revenue
address public feeCollector;

/// @notice Protocol fee rate in basis points (e.g., 50 = 0.5%)
uint256 public protocolFeeRate;

/// @notice Mapping of staking positions by user address and project ID
/// @dev CRITICAL: DO NOT MODIFY THIS MAPPING STRUCTURE
mapping(address => mapping(uint256 => StakingPosition)) private _stakingPositions;

/// @notice Mapping of voting power by user address
/// @dev CRITICAL: DO NOT MODIFY THIS MAPPING STRUCTURE
mapping(address => uint256) private _governanceVotes;

/// @notice Mapping of total staked amount by user address
/// @dev CRITICAL: DO NOT MODIFY THIS MAPPING STRUCTURE
mapping(address => uint256) private _stakingBalance;

/// @notice Mapping of governance violators who lost voting rights
/// @dev CRITICAL: DO NOT MODIFY THIS MAPPING STRUCTURE
mapping(address => bool) private _governanceViolators;

/// @notice Mapping of active validators
/// @dev CRITICAL: DO NOT MODIFY THIS MAPPING STRUCTURE
mapping(address => bool) private _validators;

/// @notice Flag to track active stakers for efficient iteration
/// @dev CRITICAL: DO NOT MODIFY THIS MAPPING STRUCTURE
mapping(address => bool) private _isActiveStaker;

/// @notice Validator commission rates in basis points (100 = 1%)
/// @dev CRITICAL: DO NOT MODIFY THIS MAPPING STRUCTURE
mapping(address => uint256) private _validatorCommission;

/// @notice Project votes for governance decisions
/// @dev CRITICAL: DO NOT MODIFY THIS MAPPING STRUCTURE
mapping(uint256 => uint256) private _projectVotes;

/// @notice History of penalty events by user address
/// @dev CRITICAL: DO NOT MODIFY THIS MAPPING STRUCTURE
mapping(address => PenaltyEvent[]) private _penaltyHistory;

/// @notice Total staked amount across all users and projects
uint256 private _totalStaked;

/// @notice Array of staking tiers defining duration multipliers
StakingTier[] private _tiers;

/// @notice Array of active staker addresses for efficient iteration
address[] private _activeStakers;

/// @notice Last calculation of APY by project ID
mapping(uint256 => uint256) private _projectAPY;

/// @notice Mapping to track if a user has active stake with auto-compound
mapping(address => bool) private _hasAutoCompoundStake;

/// @notice Mapping to track last compound time by user
mapping(address => uint256) private _lastCompoundTime;

/// @notice Last recorded Uniswap V4 trading volume for TSTAKE pairs
mapping(address => mapping(address => uint256)) private _uniswapTradingVolume;

/// @notice Last recorded Uniswap V4 TWAP price for TSTAKE pairs
mapping(address => mapping(address => uint256)) private _uniswapTwapPrice;

/// @notice Last recorded Uniswap V4 volatility factor for TSTAKE pairs
mapping(address => mapping(address => uint256)) private _uniswapVolatilityFactor;

/**
 * @dev Reserved storage space to avoid layout collisions during upgrades.
 *      ALWAYS keep this at the end of the state variables.
 *      NEVER modify the size of this array.
 */
uint256[40] private __gap;
// -------------------------------------------
//   Events
// -------------------------------------------

/// @notice Emitted when a validator is added
/// @param validator Address of the new validator
/// @param timestamp Time of addition
event ValidatorAdded(address indexed validator, uint256 timestamp);

/// @notice Emitted when a validator is removed
/// @param validator Address of the removed validator
/// @param timestamp Time of removal
event ValidatorRemoved(address indexed validator, uint256 timestamp);

/// @notice Emitted when validator status changes
/// @param validator Address of the validator
/// @param isActive New status
event ValidatorStatusChanged(address indexed validator, bool isActive);

/// @notice Emitted when validator commission rate is updated
/// @param validator Address of the validator
/// @param newCommissionRate New commission rate in basis points
event ValidatorCommissionUpdated(address indexed validator, uint256 newCommissionRate);

/// @notice Emitted when validator rewards are distributed
/// @param validator Address of the validator
/// @param amount Amount of rewards distributed
event ValidatorRewardsDistributed(address indexed validator, uint256 amount);

/// @notice Emitted when validator rewards accumulate in the pool
/// @param amount Amount added to pool
/// @param newTotal New total in validator reward pool
event ValidatorRewardsAccumulated(uint256 amount, uint256 newTotal);

/// @notice Emitted when a penalty is applied for early unstaking
/// @param user Address of the user
/// @param projectId ID of the project
/// @param totalPenalty Total penalty amount
/// @param burnAmount Amount burned
/// @param redistributeAmount Amount redistributed to stakers
/// @param liquidityAmount Amount sent to liquidity
event PenaltyApplied(
    address indexed user,
    uint256 indexed projectId,
    uint256 totalPenalty,
    uint256 burnAmount,
    uint256 redistributeAmount,
    uint256 liquidityAmount
);

/// @notice Emitted when a user votes on a governance proposal
/// @param proposalId ID of the proposal
/// @param voter Address of the voter
/// @param votingPower Voting power used
/// @param support Whether the vote is in support
event ProposalVoted(
    uint256 indexed proposalId,
    address indexed voter,
    uint256 votingPower,
    bool support
);

/// @notice Emitted when a new governance proposal is created
/// @param proposalId ID of the new proposal
/// @param proposer Address of the proposer
/// @param description Proposal description
event GovernanceProposalCreated(
    uint256 indexed proposalId,
    address indexed proposer,
    string description
);

/// @notice Emitted when a user is marked as a governance violator
/// @param violator Address of the violator
/// @param timestamp Time of marking
event GovernanceViolatorMarked(address indexed violator, uint256 timestamp);

/// @notice Emitted when staking tiers are updated
/// @param minDurations Array of minimum durations
/// @param multipliers Array of reward multipliers
/// @param votingRights Array of voting rights flags
event TiersUpdated(
    uint256[] minDurations,
    uint256[] multipliers,
    bool[] votingRights
);

/// @notice Emitted when liquidity injection rate is updated
/// @param newRate New injection rate
event LiquidityInjectionRateUpdated(uint256 newRate);

/// @notice Emitted when auto liquidity is toggled
/// @param enabled New status
event AutoLiquidityToggled(bool enabled);

/// @notice Emitted when validator threshold is updated
/// @param newThreshold New threshold amount
event ValidatorThresholdUpdated(uint256 newThreshold);

/// @notice Emitted when reward distributor contract is updated
/// @param newDistributor Address of the new distributor
event RewardDistributorUpdated(address indexed newDistributor);

/// @notice Emitted when liquidity pool address is updated
/// @param newPool Address of the new pool
event LiquidityPoolUpdated(address indexed newPool);

/// @notice Emitted when a validator is slashed
/// @param validator Address of the slashed validator
/// @param amount Amount slashed
/// @param timestamp Time of slashing
event Slashed(address indexed validator, uint256 amount, uint256 timestamp);

/// @notice Emitted when tokens are recovered from the contract
/// @param token Address of the token
/// @param amount Amount recovered
/// @param recipient Address receiving the tokens
event TokenRecovered(
    address indexed token,
    uint256 amount,
    address indexed recipient
);

/// @notice Emitted when slashing contract is updated
/// @param newContract Address of the new contract
event SlashingContractUpdated(address indexed newContract);

/// @notice Emitted when a project is voted on for approval
/// @param projectId ID of the project
/// @param voter Address of the voter
/// @param approved Whether the vote approves the project
/// @param votingPower Voting power used
event ProjectApprovalVoted(
    uint256 indexed projectId,
    address indexed voter,
    bool approved,
    uint256 votingPower
);

/// @notice Emitted when reward rate is adjusted
/// @param oldRate Previous rate
/// @param newRate New rate
event RewardRateAdjusted(uint256 oldRate, uint256 newRate);

/// @notice Emitted when a halving event occurs
/// @param epoch New halving epoch
/// @param oldBaseAPR Previous base APR
/// @param newBaseAPR New base APR
/// @param oldBoostedAPR Previous boosted APR
/// @param newBoostedAPR New boosted APR
event HalvingApplied(
    uint256 indexed epoch,
    uint256 oldBaseAPR,
    uint256 newBaseAPR,
    uint256 oldBoostedAPR,
    uint256 newBoostedAPR
);

/// @notice Emitted when dynamic rewards are toggled
/// @param enabled New status
event DynamicRewardsToggled(bool enabled);

/// @notice Emitted when governance quorum is updated
/// @param newQuorum New quorum percentage
event GovernanceQuorumUpdated(uint256 newQuorum);

/// @notice Emitted when protocol fee rate is updated
/// @param oldRate Previous rate in basis points
/// @param newRate New rate in basis points
event ProtocolFeeRateUpdated(uint256 oldRate, uint256 newRate);

/// @notice Emitted when fee collector address is updated
/// @param oldCollector Previous collector address
/// @param newCollector New collector address
event FeeCollectorUpdated(address indexed oldCollector, address indexed newCollector);

/// @notice Emitted when price data is updated
/// @param price New token price in USD (scaled by 1e18)
/// @param tvl New TVL in USD (scaled by 1e18)
event PriceDataUpdated(uint256 price, uint256 tvl);

/// @notice Emitted when reward cycle parameters are updated
/// @param cycleDuration New cycle duration in seconds
/// @param nextCycleStart Timestamp of next cycle start
event RewardCycleUpdated(uint256 cycleDuration, uint256 nextCycleStart);

/// @notice Emitted when a validator safety contract is updated
/// @param newContract Address of the new contract
event ValidatorSafetyUpdated(address indexed newContract);

/// @notice Emitted when validator commission is collected
/// @param validator Validator address
/// @param delegator Delegator address
/// @param amount Amount of commission collected
event CommissionCollected(address indexed validator, address indexed delegator, uint256 amount);

/// @notice Emitted when a project APY is recalculated
/// @param projectId ID of the project
/// @param oldAPY Previous APY in basis points
/// @param newAPY New APY in basis points
event ProjectAPYUpdated(uint256 indexed projectId, uint256 oldAPY, uint256 newAPY);

/// @notice Emitted when Uniswap V4 trading volume updates
/// @param tokenA First token in the pair
/// @param tokenB Second token in the pair
/// @param volume New trading volume
event UniswapV4TradingVolumeUpdated(address indexed tokenA, address indexed tokenB, uint256 volume);

/// @notice Emitted when Uniswap V4 TWAP price updates
/// @param tokenA First token in the pair
/// @param tokenB Second token in the pair
/// @param price Updated TWAP price
event UniswapV4PriceUpdated(address indexed tokenA, address indexed tokenB, uint256 price);

/// @notice Emitted when Uniswap V4 volatility factor updates
/// @param tokenA First token in the pair
/// @param tokenB Second token in the pair
/// @param volatilityFactor Updated volatility factor
event UniswapV4VolatilityUpdated(address indexed tokenA, address indexed tokenB, uint256 volatilityFactor);

// -------------------------------------------
//   Constructor & Initializer
// -------------------------------------------

/// @custom:oz-upgrades-unsafe-allow constructor
constructor() {
    _disableInitializers();
}

/**
 * @notice Initializes the contract (UUPS + OpenZeppelin upgradeable pattern)
 * @dev Must only be called once during proxy deployment
 * @param _nftContract Address of the NFT contract for boost verification
 * @param _stakingToken Address of the TSTAKE token
 * @param _rewardDistributor Address of the reward distributor contract
 * @param _liquidityPool Address of the liquidity pool for auto-injection
 * @param _projectsContract Address of the projects registry contract
 * @param _governanceContract Address of the governance contract
 * @param _validatorSafety Address of the validator safety contract
 * @param _priceDataProvider Address of the price data provider (Uniswap V4)
 * @param _feeCollector Address for protocol fee collection
 * @param _admin Address of the contract administrator
 */
function initialize(
    address _nftContract,
    address _stakingToken,
    address _rewardDistributor,
    address _liquidityPool,
    address _projectsContract,
    address _governanceContract,
    address _validatorSafety,
    address _priceDataProvider,
    address _feeCollector,
    address _admin
) external initializer {
    // Initialize inherited contracts
    __AccessControlEnumerable_init();
    __ReentrancyGuard_init();
    __Pausable_init();
    __UUPSUpgradeable_init();
    __ERC165_init();
    
    // Validate addresses
    if (_nftContract == address(0)) revert InvalidAddress("nftContract", _nftContract);
    if (_stakingToken == address(0)) revert InvalidAddress("stakingToken", _stakingToken);
    if (_rewardDistributor == address(0)) revert InvalidAddress("rewardDistributor", _rewardDistributor);
    if (_liquidityPool == address(0)) revert InvalidAddress("liquidityPool", _liquidityPool);
    if (_projectsContract == address(0)) revert InvalidAddress("projectsContract", _projectsContract);
    if (_governanceContract == address(0)) revert InvalidAddress("governanceContract", _governanceContract);
    if (_validatorSafety == address(0)) revert InvalidAddress("validatorSafety", _validatorSafety);
    if (_admin == address(0)) revert InvalidAddress("admin", _admin);
    
    // Set contract references
    nftContract = IERC1155(_nftContract);
    stakingToken = IERC20Upgradeable(_stakingToken);
    rewardDistributor = ITerraStakeRewardDistributor(_rewardDistributor);
    liquidityPool = _liquidityPool;
    projectsContract = ITerraStakeProjects(_projectsContract);
    governanceContract = ITerraStakeGovernance(_governanceContract);
    validatorSafety = IValidatorSafety(_validatorSafety);
    priceDataProvider = IUniswapV4DataProvider(_priceDataProvider);
    feeCollector = _feeCollector;
    
    // Set up access control
    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(GOVERNANCE_ROLE, _governanceContract);
    _grantRole(UPGRADER_ROLE, _admin);
    _grantRole(EMERGENCY_ROLE, _admin);
    _grantRole(SLASHER_ROLE, _admin);
    _grantRole(OPERATOR_ROLE, _admin);
    
    // Set up protocol parameters
    halvingPeriod = 730 days;
    lastHalvingTime = block.timestamp;
    halvingEpoch = 0;
    liquidityInjectionRate = 5; // 5% of rewards
    autoLiquidityEnabled = true;
    validatorThreshold = 100_000 * 10**18; // 100,000 TSTAKE
    
    // Set up governance parameters
    governanceQuorum = 1000; // 10% in basis points
    proposalNonce = 0;
    
    // Set up rewards parameters
    dynamicRewardsEnabled = false;
    lastRewardAdjustmentTime = block.timestamp;
    dynamicBaseAPR = BASE_APR;
    dynamicBoostedAPR = BOOSTED_APR;
    
    // Set up protocol fee
    protocolFeeRate = 50; // 0.5% in basis points
    
    // Set up reward cycles
    rewardCycleDuration = 1 days;
    nextRewardCycleStart = block.timestamp + rewardCycleDuration;
    
    // Initialize price data (Uniswap V4)
    lastTokenPrice = 0;
    lastPriceUpdateTime = block.timestamp;
    tvlInUSD = 0;
    
    // Initialize staking tiers (ordered by duration ascending)
    _tiers.push(StakingTier(30 days, 100, false)); // 1x multiplier, no voting
    _tiers.push(StakingTier(90 days, 150, true));  // 1.5x multiplier, with voting
    _tiers.push(StakingTier(180 days, 200, true)); // 2x multiplier, with voting
    _tiers.push(StakingTier(365 days, 300, true)); // 3x multiplier, with voting
    
    // Verify tier configuration is correctly ordered
    for (uint256 i = 1; i < _tiers.length; i++) {
        if (_tiers[i].minDuration <= _tiers[i-1].minDuration) {
            revert InvalidTierConfiguration();
        }
    }
    
    // Initialize validator pool
    validatorRewardPool = 0;
    
    // Emit initialization events
    emit RewardDistributorUpdated(_rewardDistributor);
    emit LiquidityPoolUpdated(_liquidityPool);
    emit ValidatorThresholdUpdated(validatorThreshold);
    emit LiquidityInjectionRateUpdated(liquidityInjectionRate);
    emit AutoLiquidityToggled(autoLiquidityEnabled);
    emit GovernanceQuorumUpdated(governanceQuorum);
    emit FeeCollectorUpdated(address(0), _feeCollector);
    emit ProtocolFeeRateUpdated(0, protocolFeeRate);
    emit ValidatorSafetyUpdated(_validatorSafety);
    
    // Set up tier events - create arrays for the event
    uint256[] memory durations = new uint256[](_tiers.length);
    uint256[] memory multipliers = new uint256[](_tiers.length);
    bool[] memory votingRights = new bool[](_tiers.length);
    
    for (uint256 i = 0; i < _tiers.length; i++) {
        durations[i] = _tiers[i].minDuration;
        multipliers[i] = _tiers[i].multiplier;
        votingRights[i] = _tiers[i].hasVotingRights;
    }
    
    emit TiersUpdated(durations, multipliers, votingRights);
}

/**
 * @notice Authorizes an upgrade to a new implementation
 * @dev Only callable by accounts with the UPGRADER_ROLE
 * @param newImplementation Address of the new implementation contract
 */
function _authorizeUpgrade(address newImplementation)
    internal
    override
    onlyRole(UPGRADER_ROLE)
{
    // Validation could be added here, but the role check is sufficient
    // Additional pre-upgrade checks could be implemented as needed
}
// -------------------------------------------
// -------------------------------------------
    //   Staking Operations
    // -------------------------------------------

    /**
     * @notice Stake tokens for a single project
     * @param projectId ID of the project to stake in
     * @param amount Amount of tokens to stake
     * @param duration Desired staking duration in seconds
     * @param isLP Whether staking LP tokens (for additional APR boost)
     * @param autoCompound Whether to automatically compound future rewards
     */
    function stake(
        uint256 projectId,
        uint256 amount,
        uint256 duration,
        bool isLP,
        bool autoCompound
    )
        external
        nonReentrant
        whenNotPaused
    {
        // Validate inputs
        if (amount == 0) revert ZeroAmount();
        if (duration < MIN_STAKING_DURATION) {
            revert InsufficientStakingDuration(MIN_STAKING_DURATION, duration);
        }
        if (!projectsContract.projectExists(projectId)) {
            revert ProjectDoesNotExist(projectId);
        }

        // Get user state
        uint256 userStakingBalance = _stakingBalance[msg.sender];
        uint256 currentTotalStaked = _totalStaked;
        bool hasNFTBoost = (nftContract.balanceOf(msg.sender, 1) > 0);

        // Get or create staking position
        StakingPosition storage position = _stakingPositions[msg.sender][projectId];

        // If existing position, claim pending rewards
        if (position.amount > 0) {
            _claimRewards(msg.sender, projectId);
        } else {
            // New position initialization
            position.stakingStart = block.timestamp;
            position.projectId = projectId;
        }

        // Update position
        position.amount += amount;
        position.lastCheckpoint = block.timestamp;
        position.duration = duration;
        position.isLPStaker = isLP;
        position.hasNFTBoost = hasNFTBoost;
        position.autoCompounding = autoCompound;

        // Update global stats
        currentTotalStaked += amount;
        _totalStaked = currentTotalStaked;

        userStakingBalance += amount;
        _stakingBalance[msg.sender] = userStakingBalance;

        // Update auto-compound tracking
        if (autoCompound && !_hasAutoCompoundStake[msg.sender]) {
            _hasAutoCompoundStake[msg.sender] = true;
            _lastCompoundTime[msg.sender] = block.timestamp;
        }

        // Update governance votes if threshold is reached
        if (userStakingBalance >= GOVERNANCE_THRESHOLD && !_governanceViolators[msg.sender]) {
            _governanceVotes[msg.sender] = userStakingBalance;
        }

        // Transfer tokens using SafeERC20
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        // Inform projects contract of new staker
        projectsContract.incrementStakerCount(projectId);

        // Check for validator qualification
        if (userStakingBalance >= validatorThreshold && !_validators[msg.sender]) {
            _validators[msg.sender] = true;
            emit ValidatorStatusChanged(msg.sender, true);
        }

        // Add to active stakers if not already tracked
        if (!_isActiveStaker[msg.sender]) {
            _isActiveStaker[msg.sender] = true;
            _activeStakers.push(msg.sender);
        }

        // Fetch and update Uniswap V4 LP fees if staking LP tokens
        if (isLP) {
            _updateUniswapV4LPFees(msg.sender, amount);
        }

        // Update price and TVL data if price provider exists
        _updatePriceData();

        emit Staked(msg.sender, projectId, amount, duration, block.timestamp, position.amount);
    }

    /**
     * @dev Updates price and TVL data using Uniswap V4 oracle if available
     */
    function _updatePriceData() internal {
        if (address(priceDataProvider) != address(0)) {
            try priceDataProvider.getLatestPrice() returns (uint256 price) {
                lastTokenPrice = price;
                tvlInUSD = (_totalStaked * price) / 1e18;
                lastPriceUpdateTime = block.timestamp;
                emit PriceDataUpdated(price, tvlInUSD);
            } catch {
                // Silently continue if price feed fails
            }
        }
    }

    /**
     * @dev Fetches Uniswap V4 LP fee rewards for a user and updates staking rewards
     * @param user Address of the LP staker
     * @param amount Amount staked as LP tokens
     */
    function _updateUniswapV4LPFees(address user, uint256 amount) internal {
        if (address(priceDataProvider) != address(0)) {
            try priceDataProvider.getUniswapV4LPFees(user) returns (uint256 lpRewards) {
                if (lpRewards > 0) {
                    // Update staking rewards based on LP rewards
                    _stakingBalance[user] += lpRewards;
                    _totalStaked += lpRewards;

                    // Emit event for LP rewards
                    emit UniswapV4LPFeesUpdated(user, lpRewards, amount);
                }
            } catch {
                // Ignore errors from Uniswap V4 feed
            }
        }
    }

    /**
     * @notice Event emitted when Uniswap V4 LP fees are updated for a staker
     * @param user Address of the staker
     * @param lpRewards Amount of LP rewards added
     * @param stakedAmount Original amount staked as LP
     */
    event UniswapV4LPFeesUpdated(address indexed user, uint256 lpRewards, uint256 stakedAmount);
}


// -------------------------------------------
//   Validator Operations
// -------------------------------------------

/**
 * @notice Called by a user to explicitly become a validator if their stake is sufficient
 * @dev Requires user to have staked at least validatorThreshold amount of tokens
 */
function becomeValidator() 
    external 
    nonReentrant 
    whenNotPaused 
{
    if (_validators[msg.sender]) {
        revert AlreadyValidator(msg.sender);
    }
    if (_stakingBalance[msg.sender] < validatorThreshold) {
        revert InvalidParameter("validatorThreshold", _stakingBalance[msg.sender]);
    }
    if (_governanceViolators[msg.sender]) {
        revert GovernanceViolation(msg.sender);
    }

    _validators[msg.sender] = true;
    _validatorCommission[msg.sender] = DEFAULT_VALIDATOR_COMMISSION;
    _validatorSet.push(msg.sender);
    _validatorCount++;
    _lastValidatorActivity[msg.sender] = block.timestamp;

    emit ValidatorAdded(msg.sender, block.timestamp);
    emit ValidatorStatusChanged(msg.sender, true);
}

/**
 * @notice Claim the portion of validatorRewardPool allocated to each validator
 * @dev Distribution is weighted by validator's stake and active delegations
 */
function claimValidatorRewards() 
    external 
    nonReentrant 
    whenNotPaused 
{
    if (!_validators[msg.sender]) {
        revert NotValidator(msg.sender);
    }

    uint256 validatorShare = calculateValidatorRewardShare(msg.sender);
    if (validatorShare == 0) {
        revert InvalidParameter("validatorShare", 0);
    }

    validatorRewardPool -= validatorShare;

    uint256 commissionEarned = 0;
    if (_validatorDelegationCount[msg.sender] > 0) {
        uint256 commissionRate = _validatorCommission[msg.sender];
        commissionEarned = (validatorShare * commissionRate) / BASIS_POINTS;
        validatorShare -= commissionEarned;
    }

    bool success = rewardDistributor.distributeReward(msg.sender, validatorShare);
    if (!success) {
        revert DistributionFailed(validatorShare);
    }

    if (commissionEarned > 0) {
        _totalCommissionEarned[msg.sender] += commissionEarned;
        emit CommissionCollected(msg.sender, address(0), commissionEarned);
    }

    emit ValidatorRewardsDistributed(msg.sender, validatorShare);
}

/**
 * @notice Update validator's commission rate
 * @param newCommissionRate New commission rate in basis points (e.g., 1000 = 10%)
 */
function updateValidatorCommission(uint256 newCommissionRate) 
    external 
    nonReentrant 
    whenNotPaused 
{
    if (!_validators[msg.sender]) {
        revert NotValidator(msg.sender);
    }
    if (newCommissionRate > MAX_VALIDATOR_COMMISSION) {
        revert RateTooHigh(newCommissionRate, MAX_VALIDATOR_COMMISSION);
    }

    _validatorCommission[msg.sender] = newCommissionRate;
    emit ValidatorCommissionUpdated(msg.sender, newCommissionRate);
}

/**
 * @dev Calculates the validator's share of the reward pool
 * @param validator Address of the validator
 * @return Validator's share of the reward pool
 */
function calculateValidatorRewardShare(address validator) 
    public 
    view 
    returns (uint256) 
{
    if (!_validators[validator] || validatorRewardPool == 0) {
        return 0;
    }

    uint256 totalValidatorStake = getTotalValidatorStake();
    if (totalValidatorStake == 0) {
        return validatorRewardPool / _validatorCount;
    }

    uint256 validatorTotalStake = _stakingBalance[validator] + _validatorTotalDelegated[validator];
    uint256 weightedShare = (validatorRewardPool * validatorTotalStake) / totalValidatorStake;
    
    return weightedShare;
}

/**
 * @dev Gets the total stake across all validators
 * @return Total combined stake of all validators
 */
function getTotalValidatorStake() 
    public 
    view 
    returns (uint256) 
{
    uint256 total = 0;
    for (uint256 i = 0; i < _validatorSet.length; i++) {
        address validator = _validatorSet[i];
        if (_validators[validator]) {
            total += _stakingBalance[validator] + _validatorTotalDelegated[validator];
        }
    }
    return total;
}

/**
 * @dev Updates price and TVL data using Uniswap V4 oracle if available
 */
function _updatePriceData() internal {
    if (address(priceDataProvider) != address(0)) {
        try priceDataProvider.getLatestPrice() returns (uint256 price) {
            lastTokenPrice = price;
            tvlInUSD = (_totalStaked * price) / 1e18;
            lastPriceUpdateTime = block.timestamp;
            emit PriceDataUpdated(price, tvlInUSD);
        } catch {
            // Silently continue if price feed fails
        }
    }
}

// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

// -------------------------------------------
// 🔹 Governance Operations (Arbitrum + Uniswap V4)
// -------------------------------------------

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v4-core/contracts/interfaces/IUniswapV4Pool.sol";
import "@uniswap/v4-core/contracts/interfaces/IUniswapV4Factory.sol";
import "@uniswap/v4-periphery/contracts/interfaces/ISwapRouter.sol";

interface IUniswapV4Hooks {
    function onSwap(address sender, uint256 amount0, uint256 amount1) external returns (bool);
}

contract GovernanceOperations is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IUniswapV4Factory public immutable uniswapFactory;
    ISwapRouter public immutable uniswapRouter;
    address public treasuryWallet;
    
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    struct LiquidityPosition {
        address token0;
        address token1;
        uint256 liquidity;
    }

    mapping(address => mapping(address => LiquidityPosition)) public liquidityPositions;
    mapping(address => bool) public approvedHooks;

    event LiquidityAdded(address indexed token0, address indexed token1, uint256 amount0, uint256 amount1);
    event LiquidityRemoved(address indexed token0, address indexed token1, uint256 liquidity);
    event SwapExecuted(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event HookApproved(address indexed hook, bool approved);

    constructor(
        address _uniswapFactory,
        address _uniswapRouter,
        address _treasuryWallet
    ) {
        require(_uniswapFactory != address(0) && _uniswapRouter != address(0), "Invalid Uniswap addresses");
        require(_treasuryWallet != address(0), "Invalid treasury wallet");

        uniswapFactory = IUniswapV4Factory(_uniswapFactory);
        uniswapRouter = ISwapRouter(_uniswapRouter);
        treasuryWallet = _treasuryWallet;

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(GOVERNANCE_ROLE, msg.sender);
    }

    /**
     * @notice Add liquidity to a Uniswap V4 pool
     * @param token0 Address of the first token
     * @param token1 Address of the second token
     * @param amount0 Amount of token0 to add
     * @param amount1 Amount of token1 to add
     */
    function addLiquidity(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(amount0 > 0 && amount1 > 0, "Amounts must be greater than zero");

        IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0);
        IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);

        IERC20(token0).safeApprove(address(uniswapRouter), amount0);
        IERC20(token1).safeApprove(address(uniswapRouter), amount1);

        (uint256 liquidity, , ) = IUniswapV4Pool(uniswapFactory.getPool(token0, token1))
            .mint(address(this), amount0, amount1);

        liquidityPositions[token0][token1] = LiquidityPosition(token0, token1, liquidity);

        emit LiquidityAdded(token0, token1, amount0, amount1);
    }

    /**
     * @notice Remove liquidity from a Uniswap V4 pool
     * @param token0 Address of the first token
     * @param token1 Address of the second token
     */
    function removeLiquidity(address token0, address token1) external onlyRole(GOVERNANCE_ROLE) {
        LiquidityPosition storage position = liquidityPositions[token0][token1];
        require(position.liquidity > 0, "No liquidity position");

        IUniswapV4Pool pool = IUniswapV4Pool(uniswapFactory.getPool(token0, token1));
        pool.burn(address(this), position.liquidity);

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        IERC20(token0).safeTransfer(treasuryWallet, balance0);
        IERC20(token1).safeTransfer(treasuryWallet, balance1);

        delete liquidityPositions[token0][token1];

        emit LiquidityRemoved(token0, token1, position.liquidity);
    }

    /**
     * @notice Swap tokens using Uniswap V4
     * @param tokenIn Address of the input token
     * @param tokenOut Address of the output token
     * @param amountIn Amount of input tokens
     * @param minAmountOut Minimum amount of output tokens expected
     */
    function swapTokens(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(amountIn > 0, "Invalid input amount");

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).safeApprove(address(uniswapRouter), amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: 3000, // Default fee tier
            recipient: treasuryWallet,
            deadline: block.timestamp + 15 minutes,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = uniswapRouter.exactInputSingle(params);

        emit SwapExecuted(tokenIn, tokenOut, amountIn, amountOut);
    }

    /**
     * @notice Approve or revoke a Uniswap V4 hook contract
     * @param hook Address of the hook contract
     * @param approved Whether to approve or revoke
     */
    function approveUniswapHook(address hook, bool approved) external onlyRole(GOVERNANCE_ROLE) {
        approvedHooks[hook] = approved;
        emit HookApproved(hook, approved);
    }
}

// -------------------------------------------
//  🔹 Administrative & Emergency
// -------------------------------------------

// Emergency mode settings
bool public emergencyModeActive;
uint256 public emergencyModeActivationTime;
uint256 public emergencyModeCooldown;
address public emergencyMultisig;
bool public tiersLocked;
mapping(bytes32 => uint256) public emergencyOperationTimestamps;
mapping(address => bool) public pauseExemptAddresses;
uint256 public constant EMERGENCY_COOLDOWN_PERIOD = 30 days;
uint256 public constant EMERGENCY_TIMELOCK = 6 hours;
uint256 public constant PARAMETER_CHANGE_DELAY = 2 days;

// Admin operation tracking
uint256 public lastProtocolUpdateTime;
uint256 public lastTierUpdateTime;
uint256 public lastFeeUpdateTime;
mapping(bytes32 => uint256) public parameterLastUpdated;
mapping(bytes32 => uint256) public pendingParameterUpdates;
mapping(bytes32 => bool) public parametersLocked;

// Uniswap V4 Liquidity Integration
address public liquidityPool;
bool public autoLiquidityEnabled;
uint256 public liquidityInjectionRate;

/**
 * @notice Set the Uniswap V4 liquidity pool address
 * @param newPool Address of the new liquidity pool
 */
function setLiquidityPool(address newPool) 
    external 
    onlyRole(DEFAULT_ADMIN_ROLE) 
    whenNotPaused
{
    if (newPool == address(0)) {
        revert InvalidAddress("liquidityPool", newPool);
    }

    address oldPool = liquidityPool;
    liquidityPool = newPool;

    emit LiquidityPoolUpdated(newPool);
    emit ContractAddressUpdated("liquidityPool", oldPool, newPool);
}

/**
 * @notice Withdraw liquidity from Uniswap V4 pool in case of emergency
 * @param token Address of the LP token
 * @param amount Amount to withdraw
 */
function emergencyWithdrawLP(address token, uint256 amount)
    external
    onlyRole(EMERGENCY_ROLE)
{
    if (amount == 0) {
        revert InvalidParameter("withdrawAmount", amount);
    }

    IERC20(token).transfer(msg.sender, amount);
    emit LPTokenWithdrawn(token, amount, msg.sender);
}

/**
 * @notice Update emergency multisig address
 * @param newMultisig New multisig address
 */
function setEmergencyMultisig(address newMultisig)
    external
    onlyRole(DEFAULT_ADMIN_ROLE)
{
    if (newMultisig == address(0)) {
        revert InvalidAddress("emergencyMultisig", newMultisig);
    }

    address oldMultisig = emergencyMultisig;
    emergencyMultisig = newMultisig;

    // Assign emergency role
    _grantRole(EMERGENCY_ROLE, newMultisig);
    if (oldMultisig != address(0)) {
        _revokeRole(EMERGENCY_ROLE, oldMultisig);
    }

    emit EmergencyMultisigUpdated(oldMultisig, newMultisig);
}

/**
 * @notice Activate emergency mode
 */
function activateEmergencyMode()
    external
    onlyRole(EMERGENCY_ROLE)
{
    if (emergencyModeActive) {
        revert InvalidParameter("alreadyActive", 1);
    }

    emergencyModeActive = true;
    emergencyModeActivationTime = block.timestamp;

    _pause();

    emit EmergencyModeActivated(msg.sender, block.timestamp);
}

/**
 * @notice Deactivate emergency mode
 */
function deactivateEmergencyMode()
    external
    onlyRole(DEFAULT_ADMIN_ROLE)
{
    if (!emergencyModeActive) {
        revert InvalidParameter("notActive", 0);
    }

    emergencyModeActive = false;
    emergencyModeCooldown = EMERGENCY_COOLDOWN_PERIOD;

    emit EmergencyModeDeactivated(msg.sender, block.timestamp);
}

/**
 * @notice Execute emergency operation
 * @param target Contract to call
 * @param data Call data
 * @param value ETH value to send
 */
function executeEmergencyOperation(address target, bytes calldata data, uint256 value)
    external
    payable
    onlyRole(EMERGENCY_ROLE)
    returns (bool, bytes memory)
{
    bytes32 operationHash = keccak256(abi.encode(target, data, value, block.chainid));

    if (block.timestamp < emergencyOperationTimestamps[operationHash] + EMERGENCY_COOLDOWN_PERIOD) {
        revert StakingLocked(emergencyOperationTimestamps[operationHash] + EMERGENCY_COOLDOWN_PERIOD);
    }

    emergencyOperationTimestamps[operationHash] = block.timestamp;
    (bool success, bytes memory returnData) = target.call{value: value}(data);

    emit EmergencyOperationExecuted(target, data, value, success);
    return (success, returnData);
}

/**
 * @notice Pause protocol (emergency only)
 */
function pause() 
    external 
    onlyRole(EMERGENCY_ROLE) 
{
    _pause();
    emit ProtocolPaused(msg.sender);
}

/**
 * @notice Unpause protocol
 */
function unpause() 
    external 
    onlyRole(DEFAULT_ADMIN_ROLE) 
{
    _unpause();
    emit ProtocolUnpaused(msg.sender);
}

/**
 * @notice Recover ERC20 tokens accidentally sent to the contract
 * @param token Address of the token to recover
 * @return success Whether the recovery was successful
 */
function recoverERC20(address token)
    external
    onlyRole(EMERGENCY_ROLE)
    returns (bool)
{
    uint256 amount = IERC20(token).balanceOf(address(this));
    if (token == address(stakingToken)) {
        amount = amount - _totalStaked; 
    }

    if (amount == 0) {
        return false;
    }

    IERC20(token).transfer(msg.sender, amount);
    emit TokenRecovered(token, amount, msg.sender);
    return true;
}

/**
 * @notice Set the emergency mode cooldown period
 * @param newCooldown New cooldown period in seconds
 */
function setEmergencyModeCooldown(uint256 newCooldown)
    external
    onlyRole(DEFAULT_ADMIN_ROLE)
{
    if (newCooldown < 1 days) {
        revert InvalidParameter("cooldownTooShort", newCooldown);
    }

    emergencyModeCooldown = newCooldown;
    emit EmergencyModeCooldownUpdated(newCooldown);
}

// Additional state variables needed for the Administrative & Emergency section
address[] private _validatorSet;
uint256 private _validatorCount;

// Events for the Administrative & Emergency section
event EmergencyModeActivated(address indexed activator, uint256 timestamp);
event EmergencyModeDeactivated(address indexed deactivator, uint256 timestamp);
event EmergencyOperationExecuted(address indexed target, bytes data, uint256 value, bool success);
event ProtocolPaused(address indexed pauser);
event ProtocolUnpaused(address indexed unpauser);
event EmergencyMultisigUpdated(address oldMultisig, address newMultisig);
event LiquidityPoolUpdated(address newPool);
event LPTokenWithdrawn(address indexed token, uint256 amount, address recipient);
event TokenRecovered(address indexed token, uint256 amount, address indexed recipient);
event EmergencyModeCooldownUpdated(uint256 newCooldown);

// -------------------------------------------
//   Slashing
// -------------------------------------------

// Slashing configuration
uint256 public minSlashableAmount;
uint256 public maxSlashPercentage;
uint256 public slashCooldownPeriod;
uint256 public appealWindow;
uint256 public lastSlashingParameterUpdate;

// Slashing severity levels (basis points: 100 = 1%)
uint256 public constant MINOR_VIOLATION_SLASH_RATE = 500;    // 5%
uint256 public constant MAJOR_VIOLATION_SLASH_RATE = 2000;   // 20%
uint256 public constant CRITICAL_VIOLATION_SLASH_RATE = 5000; // 50%

// Slashing state tracking
mapping(address => SlashingRecord[]) private _slashingHistory;
mapping(bytes32 => bool) private _slashingAppeals;
mapping(bytes32 => uint256) private _lastValidatorSlashTime;
mapping(address => uint256) private _totalSlashedAmount;
mapping(uint256 => uint256) private _epochSlashedAmount;

/**
 * @notice Record structure for slashing events
 */
struct SlashingRecord {
    uint256 timestamp;
    uint256 amount;
    SlashingReason reason;
    address reporter;
    bool appealed;
    bool appealAccepted;
    string evidence;
    bytes32 slashId;
}

/**
 * @notice Enum of possible slashing reasons
 */
enum SlashingReason {
    None,
    Downtime,
    DoubleSigning,
    Misbehavior,
    ProtocolViolation,
    ConsensusFailure,
    GovernanceViolation,
    Other
}

/**
 * @notice Slash a validator for misbehavior
 * @param validator Address of the validator to slash
 * @param amount Amount to slash (must be <= stake * maxSlashPercentage/10000)
 * @param reason Reason for slashing
 * @param evidence IPFS hash or other reference to evidence
 * @return success Whether the slashing was successful
 */
function slash(
    address validator,
    uint256 amount,
    SlashingReason reason,
    string calldata evidence
) 
    external 
    onlyRole(SLASHER_ROLE)
    returns (bool) 
{
    // Validate inputs
    if (!_validators[validator]) {
        revert NotValidator(validator);
    }
    
    if (amount == 0) {
        revert ZeroAmount();
    }
    
    if (reason == SlashingReason.None) {
        revert InvalidParameter("reason", 0);
    }
    
    // Check validator's stake
    uint256 validatorStake = _stakingBalance[validator];
    uint256 maxSlashable = (validatorStake * maxSlashPercentage) / 10000;
    
    if (amount > maxSlashable) {
        amount = maxSlashable; // Cap the slashing amount
    }
    
    if (amount < minSlashableAmount) {
        revert InvalidParameter("amountTooSmall", amount);
    }
    
    // Check cooldown period to prevent abuse
    bytes32 validatorKey = keccak256(abi.encodePacked(validator));
    if (block.timestamp < _lastValidatorSlashTime[validatorKey] + slashCooldownPeriod) {
        revert StakingLocked(_lastValidatorSlashTime[validatorKey] + slashCooldownPeriod);
    }
    
    // All checks passed, perform the slashing
    _lastValidatorSlashTime[validatorKey] = block.timestamp;
    
    // Create a unique slashing ID
    bytes32 slashId = keccak256(abi.encodePacked(
        validator,
        amount,
        block.timestamp,
        reason,
        msg.sender
    ));
    
    // Update staker's total
    _stakingBalance[validator] -= amount;
    _totalStaked -= amount;
    
    // Update slashing metrics
    _totalSlashedAmount[validator] += amount;
    _epochSlashedAmount[halvingEpoch] += amount;
    
    // Update governance votes if needed
    if (_stakingBalance[validator] < GOVERNANCE_THRESHOLD) {
        _governanceVotes[validator] = 0;
    } else {
        _governanceVotes[validator] = _stakingBalance[validator];
    }
    
    // Remove validator status if they drop below threshold
    if (_stakingBalance[validator] < validatorThreshold) {
        _validators[validator] = false;
        emit ValidatorStatusChanged(validator, false);
        emit ValidatorRemoved(validator, block.timestamp);
    }
    
    // Record slashing event in history
    _slashingHistory[validator].push(SlashingRecord({
        timestamp: block.timestamp,
        amount: amount,
        reason: reason,
        reporter: msg.sender,
        appealed: false,
        appealAccepted: false,
        evidence: evidence,
        slashId: slashId
    }));
    
    // Distribute slashed funds according to protocol rules
    _distributeSlashedFunds(validator, amount, reason);
    
    // Notify slashing contract if configured
    if (address(slashingContract) != address(0)) {
        try slashingContract.recordSlashingEvent(validator, amount, uint8(reason)) {} 
        catch {}
    }
    
    emit Slashed(validator, amount, block.timestamp);
    emit DetailedSlashingEvent(
        validator, 
        amount, 
        uint8(reason), 
        msg.sender,
        evidence,
        slashId
    );
    
    return true;
}

// Events for the Slashing section
event DetailedSlashingEvent(
    address indexed validator,
    uint256 amount,
    uint8 reason,
    address reporter,
    string evidence,
    bytes32 slashId
);

event SlashedFundsDistributed(
    address indexed validator,
    uint256 totalAmount,
    uint256 amountBurned,
    uint256 amountToRewardPool,
    uint256 amountToTreasury
);

event SlashingParametersUpdated(
    uint256 minSlashableAmount,
    uint256 maxSlashPercentage,
    uint256 slashCooldownPeriod,
    uint256 appealWindow
);

event SlashingParametersInitialized(
    uint256 minSlashableAmount,
    uint256 maxSlashPercentage,
    uint256 slashCooldownPeriod,
    uint256 appealWindow
);

event SlashingAppealed(
    address indexed validator,
    bytes32 indexed slashId,
    string justification
);

event SlashingAppealResolved(
    address indexed validator,
    bytes32 indexed slashId,
    bool accepted,
    uint256 refundAmount
);

event SlashingImmunityGranted(
    address indexed validator,
    uint256 duration,
    uint256 expiryTime
);

event ValidatorReported(
    address indexed validator,
    address indexed reporter,
    uint8 reason,
    string evidence,
    uint256 timestamp
);

event BatchSlashingCompleted(
    uint256 totalAttempts,
    uint256 successCount
);

// -------------------------------------------
//   View Functions
// -------------------------------------------

/**
 * @notice Calculates user's pending rewards for a specific position
 * @param user User address
 * @param projectId Project ID
 * @return Pending rewards in tokens
 */
function calculateRewards(address user, uint256 projectId)
    public
    view
    returns (uint256)
{
    StakingPosition storage position = _stakingPositions[user][projectId];
    if (position.amount == 0) {
        return 0;
    }

    uint256 stakingTime = block.timestamp - position.lastCheckpoint;
    if (stakingTime == 0) {
        return 0;
    }

    // Tier multiplier
    uint256 tierId = getApplicableTier(position.duration);
    uint256 tierMult = _tiers[tierId].multiplier;

    // Base APR logic (with halving/dynamic approach)
    uint256 baseRate = (_totalStaked < LOW_STAKING_THRESHOLD)
        ? dynamicBoostedAPR
        : dynamicBaseAPR;

    // Additional conditions
    if (position.hasNFTBoost) {
        baseRate += NFT_APR_BOOST;
    }
    if (position.isLPStaker) {
        baseRate += LP_APR_BOOST;
    }

    uint256 effectiveRate = (baseRate * tierMult) / 100;

    // annualReward = principal * effRate / 100
    // but we do pro-rata for stakingTime / year
    uint256 reward = (position.amount * effectiveRate * stakingTime)
        / (100 * 365 days);

    return reward;
}

/**
 * @notice Calculates total pending rewards across all projects for a user
 * @param user User address
 * @return totalRewards Total pending rewards
 */
function calculateTotalRewards(address user) 
    external 
    view 
    returns (uint256 totalRewards) 
{
    uint256 projectCount = projectsContract.getProjectCount();
    
    for (uint256 i = 1; i <= projectCount; i++) {
        if (_stakingPositions[user][i].amount > 0) {
            totalRewards += calculateRewards(user, i);
        }
    }
    
    return totalRewards;
}

/**
 * @notice Finds the staking tier index that applies for a given duration
 * @param duration Staking duration in seconds
 * @return Applicable tier index
 */
function getApplicableTier(uint256 duration) 
    public 
    view 
    returns (uint256) 
{
    uint256 applicableTier = 0;
    for (uint256 i = 0; i < _tiers.length; i++) {
        if (duration >= _tiers[i].minDuration) {
            applicableTier = i;
        } else {
            break;
        }
    }
    return applicableTier;
}

/**
 * @notice Get all staking tiers
 * @return Array of staking tiers
 */
function getAllTiers() 
    external 
    view 
    returns (StakingTier[] memory) 
{
    return _tiers;
}

/**
 * @notice Get specific tier by index
 * @param index Tier index
 * @return Staking tier
 */
function getTier(uint256 index) 
    external 
    view 
    returns (StakingTier memory) 
{
    require(index < _tiers.length, "Invalid tier index");
    return _tiers[index];
}

/**
 * @notice Get tier count
 * @return Number of tiers
 */
function getTierCount() 
    external 
    view 
    returns (uint256) 
{
    return _tiers.length;
}

/**
 * @notice Get user's stake for a single project
 * @param user User address
 * @param projectId Project ID
 * @return Amount staked
 */
function getUserStake(address user, uint256 projectId) 
    external 
    view 
    returns (uint256) 
{
    return _stakingPositions[user][projectId].amount;
}

/**
 * @notice Get user's total stake across all projects
 * @param user User address
 * @return Total amount staked
 */
function getUserTotalStake(address user) 
    external 
    view 
    returns (uint256) 
{
    return _stakingBalance[user];
}

/**
 * @notice Get full details of a user's staking position
 * @param user User address
 * @param projectId Project ID
 * @return position Staking position details
 */
function getUserStakingPosition(address user, uint256 projectId) 
    external 
    view 
    returns (StakingPosition memory position) 
{
    return _stakingPositions[user][projectId];
}

/**
 * @notice Get all staking positions for a user
 * @param user User address
 * @return positions Array of staking positions
 */
function getUserPositions(address user) 
    external 
    view 
    returns (StakingPosition[] memory positions) 
{
    uint256 projectCount = projectsContract.getProjectCount();
    uint256 count = 0;

    for (uint256 i = 1; i <= projectCount; i++) {
        if (_stakingPositions[user][i].amount > 0) {
            count++;
        }
    }

    positions = new StakingPosition[](count);
    uint256 index = 0;

    for (uint256 i = 1; i <= projectCount; i++) {
        if (_stakingPositions[user][i].amount > 0) {
            positions[index] = _stakingPositions[user][i];
            index++;
        }
    }
    return positions;
}

/**
 * @notice Basic version info
 * @return Version string
 */
function version() 
    external 
    pure 
    returns (string memory) 
{
    return "1.2.0";
}

// -------------------------------------------
//   Internal Utilities
// -------------------------------------------

/**
 * @dev See {IERC165-supportsInterface}.
 */
function supportsInterface(bytes4 interfaceId)
    public
    view
    override(AccessControlEnumerableUpgradeable, ERC165Upgradeable)
    returns (bool)
{
    return
        interfaceId == type(ITerraStakeStaking).interfaceId ||
        super.supportsInterface(interfaceId);
}

/**
 * @dev Handles token transfers with proper error checking
 * @param token Token address
 * @param to Recipient address
 * @param amount Amount to transfer
 * @return True if successful
 */
function _safeTransfer(address token, address to, uint256 amount) internal returns (bool) {
    if (amount == 0 || to == address(0)) return true;
    
    (bool success, bytes memory data) = token.call(
        abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
    );
    
    return success && (data.length == 0 || abi.decode(data, (bool)));
}

/**
 * @dev Handles token transferFrom with proper error checking
 * @param token Token address
 * @param from Sender address
 * @param to Recipient address
 * @param amount Amount to transfer
 * @return True if successful
 */
function _safeTransferFrom(address token, address from, address to, uint256 amount) internal returns (bool) {
    if (amount == 0) return true;
    
    (bool success, bytes memory data) = token.call(
        abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount)
    );
    
    return success && (data.length == 0 || abi.decode(data, (bool)));
}

/**
 * @dev Get staking position with validation
 * @param user User address
 * @param projectId Project ID
 * @return position Staking position
 */
function _getValidatedPosition(address user, uint256 projectId) internal view returns (StakingPosition storage position) {
    position = _stakingPositions[user][projectId];
    if (position.amount == 0) {
        revert NoActiveStakingPosition(user, projectId);
    }
    return position;
}

/**
 * @dev Initialize a new staking position
 * @param user User address
 * @param projectId Project ID
 * @param amount Initial staking amount
 * @param duration Staking duration
 * @param isLP Whether position is LP staking
 * @param autoCompound Whether to auto-compound rewards
 * @return position Initialized staking position
 */
function _initializePosition(
    address user,
    uint256 projectId,
    uint256 amount,
    uint256 duration,
    bool isLP,
    bool autoCompound
) internal returns (StakingPosition storage position) {
    position = _stakingPositions[user][projectId];
    
    bool isNewPosition = position.amount == 0;
    bool hasNFTBoost = (nftContract.balanceOf(user, 1) > 0);
    
    if (isNewPosition) {
        position.stakingStart = block.timestamp;
        position.projectId = projectId;
        
        // Add user to active stakers if not already there
        if (!_isActiveStaker[user]) {
            _isActiveStaker[user] = true;
            _activeStakers.push(user);
        }
        
        // Increment project staker count
        projectsContract.incrementStakerCount(projectId);
    } else {
        // Claim rewards up to now before modifying position
        _claimRewards(user, projectId);
    }
    
    // Update position
    position.amount += amount;
    position.lastCheckpoint = block.timestamp;
    position.duration = duration;
    position.isLPStaker = isLP;
    position.hasNFTBoost = hasNFTBoost;
    position.autoCompounding = autoCompound;
    
    // Update global stats
    _totalStaked += amount;
    _stakingBalance[user] += amount;
    
    return position;
}

/**
 * @dev Check and update governance votes
 * @param user User address
 */
function _updateGovernanceVotes(address user) internal {
    uint256 userStakingBalance = _stakingBalance[user];
    
    // Update governance votes if threshold is reached and not a violator
    if (userStakingBalance >= GOVERNANCE_THRESHOLD && !_governanceViolators[user]) {
        _governanceVotes[user] = userStakingBalance;
    } else {
        _governanceVotes[user] = 0;
    }
}

/**
 * @dev Check and update validator status
 * @param user User address
 */
    function _updateValidatorStatus(address user) internal {
    uint256 userStakingBalance = _stakingBalance[user];
    
    // Update validator status based on threshold
    if (userStakingBalance >= validatorThreshold && !_validators[user]) {
        _validators[user] = true;
        _validatorCount++;
        
        // Add to validator set if not already there
        bool found = false;
        for (uint256 i = 0; i < _validatorSet.length; i++) {
            if (_validatorSet[i] == user) {
                found = true;
                break;
            }
        }
        
        if (!found) {
            _validatorSet.push(user);
        }
        
        emit ValidatorStatusChanged(user, true);
        emit ValidatorAdded(user, block.timestamp);
    } else if (userStakingBalance < validatorThreshold && _validators[user]) {
        _validators[user] = false;
        _validatorCount--;
        emit ValidatorStatusChanged(user, false);
        emit ValidatorRemoved(user, block.timestamp);
    }
}

/**
 * @dev Calculate time until staking position unlocks
 * @param position Staking position
 * @return Time in seconds until position unlocks (0 if already unlocked)
 */
function _timeUntilUnlock(StakingPosition storage position) internal view returns (uint256) {
    uint256 unlockTime = position.stakingStart + position.duration;
    if (block.timestamp >= unlockTime) {
        return 0;
    }
    return unlockTime - block.timestamp;
}

/**
 * @dev Calculate early withdrawal penalty
 * @param position Staking position
 * @return penalty Penalty amount
 * @return penaltyRate Penalty rate applied (100 = 1%)
 */
function _calculatePenalty(StakingPosition storage position) internal view returns (uint256 penalty, uint256 penaltyRate) {
    uint256 timeUntilUnlock = _timeUntilUnlock(position);
    
    if (timeUntilUnlock == 0) {
        return (0, 0);
    }
    
    // Calculate penalty rate based on remaining time
    penaltyRate = BASE_PENALTY_PERCENT + ((timeUntilUnlock * (MAX_PENALTY_PERCENT - BASE_PENALTY_PERCENT)) / position.duration);
    penalty = (position.amount * penaltyRate) / 100;
    
    return (penalty, penaltyRate);
}

/**
 * @dev Checks if current APR needs halving based on time elapsed
 * @return Whether halving should be applied
 */
function _checkAndApplyHalving() internal returns (bool) {
    uint256 nextHalvingTime = lastHalvingTime + halvingPeriod;
    
    if (block.timestamp >= nextHalvingTime) {
        // Time for halving
        uint256 oldBaseAPR = dynamicBaseAPR;
        uint256 oldBoostedAPR = dynamicBoostedAPR;
        
        // Apply halving
        dynamicBaseAPR = dynamicBaseAPR / 2;
        dynamicBoostedAPR = dynamicBoostedAPR / 2;
        
        // Ensure minimum APR
        if (dynamicBaseAPR < 1) {
            dynamicBaseAPR = 1; // Minimum 1% APR
        }
        if (dynamicBoostedAPR < 2) {
            dynamicBoostedAPR = 2; // Minimum 2% boosted APR
        }
        
        // Update halving time and epoch
        lastHalvingTime = nextHalvingTime;
        halvingEpoch++;
        
        emit HalvingApplied(
            halvingEpoch,
            oldBaseAPR,
            dynamicBaseAPR,
            oldBoostedAPR,
            dynamicBoostedAPR
        );
        
        return true;
    }
    
    return false;
}

/**
 * @dev Adjust reward rates based on protocol parameters
 */
function _adjustRewardRates() internal {
    // Only adjust once per day maximum
    if (block.timestamp < lastRewardAdjustmentTime + 1 days) {
        return;
    }
    
    // Check if we need to apply halving first
    bool halved = _checkAndApplyHalving();
    
    // Only apply dynamic adjustments if enabled and not halved
    if (dynamicRewardsEnabled && !halved) {
        uint256 oldBaseAPR = dynamicBaseAPR;
        uint256 oldBoostedAPR = dynamicBoostedAPR;
        
        // Simple dynamic rate adjustment based on total staked
        // This is a simplified example - real implementations could be more complex
        if (_totalStaked < LOW_STAKING_THRESHOLD / 2) {
            // Very low TVL, higher rates to attract stakers
            dynamicBaseAPR = BASE_APR * 12 / 10; // +20%
            dynamicBoostedAPR = BOOSTED_APR * 12 / 10; // +20%
        } else if (_totalStaked < LOW_STAKING_THRESHOLD) {
            // Standard boosted rates
            dynamicBaseAPR = BASE_APR;
            dynamicBoostedAPR = BOOSTED_APR;
        } else if (_totalStaked < LOW_STAKING_THRESHOLD * 2) {
            // Medium TVL, reduce rates slightly
            dynamicBaseAPR = BASE_APR * 9 / 10; // -10%
            dynamicBoostedAPR = BOOSTED_APR * 9 / 10; // -10%
        } else {
            // High TVL, reduce rates more
            dynamicBaseAPR = BASE_APR * 8 / 10; // -20%
            dynamicBoostedAPR = BOOSTED_APR * 8 / 10; // -20%
        }
        
        if (oldBaseAPR != dynamicBaseAPR || oldBoostedAPR != dynamicBoostedAPR) {
            emit RewardRateAdjusted(oldBaseAPR, dynamicBaseAPR);
        }
    }
    
    lastRewardAdjustmentTime = block.timestamp;
}

/**
 * @dev Add a penalty event to user's history
 * @param user User address
 * @param projectId Project ID
 * @param totalPenalty Total penalty amount
 * @param redistributed Amount redistributed to stakers
 * @param burned Amount burned
 * @param toLiquidity Amount sent to liquidity pool
 */
function _recordPenaltyEvent(
    address user,
    uint256 projectId,
    uint256 totalPenalty,
    uint256 redistributed,
    uint256 burned,
    uint256 toLiquidity
) internal {
    _penaltyHistory[user].push(PenaltyEvent({
        projectId: projectId,
        timestamp: block.timestamp,
        totalPenalty: totalPenalty,
        redistributed: redistributed,
        burned: burned,
        toLiquidity: toLiquidity
    }));
}

/**
 * @dev Inject penalty-derived liquidity
 * @param amount Amount to inject into liquidity
 * @return success Whether the operation succeeded
 */
function _injectLiquidity(uint256 amount) internal returns (bool success) {
    if (amount == 0 || !autoLiquidityEnabled) {
        return true;
    }
    
    success = _safeTransfer(address(stakingToken), liquidityPool, amount);
    
    if (success) {
        emit LiquidityInjected(liquidityPool, amount, block.timestamp);
    }
    
    return success;
}

/**
 * @dev Burn tokens by sending to burn address
 * @param amount Amount to burn
 * @return success Whether the operation succeeded
 */
function _burnTokens(uint256 amount) internal returns (bool success) {
    if (amount == 0) {
        return true;
    }
    
    success = _safeTransfer(address(stakingToken), BURN_ADDRESS, amount);
    
    if (success) {
        emit TokensBurned(amount, block.timestamp);
    }
    
    return success;
}

/**
 * @dev Check if a user has NFT boost entitlement and update if needed
 * @param user User address
 * @param projectId Project ID
 * @return True if user has NFT boost
 */
function _checkAndUpdateNFTBoost(address user, uint256 projectId) internal returns (bool) {
    StakingPosition storage position = _stakingPositions[user][projectId];
    bool hasNFT = nftContract.balanceOf(user, 1) > 0;
    
    if (position.hasNFTBoost != hasNFT) {
        position.hasNFTBoost = hasNFT;
        emit NFTBoostStatusChanged(user, projectId, hasNFT);
    }
    
    return hasNFT;
}

/**
 * @dev Project validation with error message
 * @param projectId Project ID to validate
 */
function _validateProject(uint256 projectId) internal view {
    if (!projectsContract.projectExists(projectId)) {
        revert ProjectDoesNotExist(projectId);
    }
}

/**
 * @dev Validate staking duration
 * @param duration Staking duration to validate
 */
function _validateStakingDuration(uint256 duration) internal pure {
    if (duration < MIN_STAKING_DURATION) {
        revert InsufficientStakingDuration(MIN_STAKING_DURATION, duration);
    }
}

/**
 * @dev Clear a staking position properly
 * @param user User address
 * @param projectId Project ID
 */
function _clearStakingPosition(address user, uint256 projectId) internal {
    // Decrement project staker count
    projectsContract.decrementStakerCount(projectId);
    
    // Delete position
    delete _stakingPositions[user][projectId];
    
    // Check if user has any remaining positions
    bool hasPositions = false;
    uint256 projectCount = projectsContract.getProjectCount();
    
    for (uint256 i = 1; i <= projectCount; i++) {
        if (_stakingPositions[user][i].amount > 0) {
            hasPositions = true;
            break;
        }
    }
    
    // If no positions left, remove from active stakers
    if (!hasPositions) {
        _isActiveStaker[user] = false;
        _removeInactiveStaker(user);
    }
}

/**
 * @dev Removes an address from the _activeStakers array in O(1) time
 * @param staker Address to remove
 */
function _removeInactiveStaker(address staker) internal {
    uint256 length = _activeStakers.length;
    for (uint256 i = 0; i < length; i++) {
        if (_activeStakers[i] == staker) {
            // Swap with the last element and pop
            _activeStakers[i] = _activeStakers[length - 1];
            _activeStakers.pop();
            return;
        }
    }
}

/**
 * @dev Validates that caller is a registered validator
 */
function _requireValidator() internal view {
    if (!_validators[msg.sender]) {
        revert NotValidator(msg.sender);
    }
}

/**
 * @dev Calculate rewards and handle compound/distribution settings
 * @param user User address
 * @param projectId Project ID
 * @return reward Amount to distribute
 * @return compounded Amount compounded
 */
function _processRewards(address user, uint256 projectId) internal returns (uint256 reward, uint256 compounded) {
    StakingPosition storage position = _stakingPositions[user][projectId];
    
    // Calculate rewards
    uint256 totalReward = calculateRewards(user, projectId);
    if (totalReward == 0) {
        position.lastCheckpoint = block.timestamp;
        return (0, 0);
    }
    
    // Update checkpoint
    position.lastCheckpoint = block.timestamp;
    
    // Handle auto-compounding
    if (position.autoCompounding) {
        // 20% is auto-compounded
        compounded = (totalReward * 20) / 100;
        
        if (compounded > 0) {
            position.amount += compounded;
            _totalStaked += compounded;
            _stakingBalance[user] += compounded;
            
            // Update governance votes if needed
            _updateGovernanceVotes(user);
            
            // Check validator status
            _updateValidatorStatus(user);
            
            emit RewardCompounded(user, projectId, compounded, block.timestamp);
        }
        
        reward = totalReward - compounded;
    } else {
        reward = totalReward;
        compounded = 0;
    }
    
    return (reward, compounded);
}

/**
 * @dev Process liquidity injection from rewards
 * @param reward Base reward amount
 * @return remainingReward Reward after liquidity injection
 * @return liquidityAmount Amount sent to liquidity
 */
function _processLiquidityInjection(uint256 reward) internal returns (uint256 remainingReward, uint256 liquidityAmount) {
    if (!autoLiquidityEnabled || reward == 0) {
        return (reward, 0);
    }
    
    liquidityAmount = (reward * liquidityInjectionRate) / 100;
    
    if (liquidityAmount > 0) {
        bool success = _injectLiquidity(liquidityAmount);
        
        // If injection fails, return the amount to rewards
        if (!success) {
            liquidityAmount = 0;
        }
    }
    
    remainingReward = reward - liquidityAmount;
    return (remainingReward, liquidityAmount);
}

/**
 * @dev Apply correct distribution for slashed/penalty funds
 * @param totalAmount Total amount slashed/penalized
 * @return burned Amount burned
 * @return redistributed Amount redistributed to stakers
 * @return liquidityAmount Amount sent to liquidity
 */
function _distributePenaltyFunds(uint256 totalAmount) internal returns (
    uint256 burned,
    uint256 redistributed,
    uint256 liquidityAmount
) {
    // Default distribution: 40% burn, 40% redistribute, 20% liquidity
    burned = (totalAmount * 40) / 100;
    redistributed = (totalAmount * 40) / 100;
    liquidityAmount = totalAmount - burned - redistributed;
    
    // Handle burns
    if (burned > 0) {
        bool burnSuccess = _burnTokens(burned);
        if (!burnSuccess) {
            // If burn fails, redistribute instead
            redistributed += burned;
            burned = 0;
        }
    }
    
    // Handle redistribution to reward pool
    if (redistributed > 0) {
        bool redistributeSuccess = _safeTransfer(
            address(stakingToken),
            address(rewardDistributor),
            redistributed
        );
        
        if (redistributeSuccess) {
            // Notify reward distributor
            rewardDistributor.addPenaltyRewards(redistributed);
        } else {
            // If redistribution fails, try to add to liquidity
            liquidityAmount += redistributed;
            redistributed = 0;
        }
    }
    
    // Handle liquidity injection
    if (liquidityAmount > 0) {
        bool liquiditySuccess = _injectLiquidity(liquidityAmount);
        if (!liquiditySuccess) {
            // If liquidity fails, try to burn instead
            bool fallbackBurnSuccess = _burnTokens(liquidityAmount);
            if (fallbackBurnSuccess) {
                burned += liquidityAmount;
                liquidityAmount = 0;
            }
        }
    }
    
    return (burned, redistributed, liquidityAmount);
}

/**
 * @dev Safe math for calculating rewards and percentages
 * @param amount Base amount
 * @param numerator Numerator for percentage
 * @param denominator Denominator for percentage
 * @return Result of the calculation
 */
function _calculatePercentage(
    uint256 amount,
    uint256 numerator,
    uint256 denominator
) internal pure returns (uint256) {
    if (amount == 0 || numerator == 0) {
        return 0;
    }
    return amount * numerator / denominator;
}

/**
 * @dev Check for project vote eligibility and cast vote
 * @param user Voter address
 * @param projectId Project ID
 * @param support Whether to support the project
 * @return voteWeight Weight of the vote cast
 */
function _processProjectVote(
    address user,
    uint256 projectId,
    bool support
) internal returns (uint256 voteWeight) {
    if (_governanceViolators[user]) {
        revert GovernanceViolation(user);
    }
    
    voteWeight = _governanceVotes[user];
    if (voteWeight == 0) {
        revert InvalidParameter("votingPower", voteWeight);
    }
    
    // Update project votes
    if (support) {
        _projectVotes[projectId] += voteWeight;
    } else {
        // Ensure we don't underflow
        if (_projectVotes[projectId] >= voteWeight) {
            _projectVotes[projectId] -= voteWeight;
        } else {
            _projectVotes[projectId] = 0;
        }
    }
    
    emit ProjectApprovalVoted(projectId, user, support, voteWeight);
    return voteWeight;
}

/**
 * @dev Process validator rewards from the validator pool
 * @param validator Validator address
 * @return reward Amount distributed
 */
function _distributeValidatorReward(address validator) internal returns (uint256 reward) {
    if (validatorRewardPool == 0) {
        return 0;
    }
    
    if (_validatorCount == 0) {
        return 0;
    }
    
    // Equal distribution to all validators
    reward = validatorRewardPool / _validatorCount;
    
    if (reward > 0) {
        validatorRewardPool -= reward;
        
        bool success = rewardDistributor.distributeReward(validator, reward);
        if (!success) {
            // If distribution fails, put back in pool
            validatorRewardPool += reward;
            reward = 0;
        }
    }
    
    return reward;
}

/**
 * @dev Emergency recovery function - only callable in emergency mode
 * @param token Token to recover
 * @param amount Amount to recover
 * @param destination Destination address
 * @return success Whether recovery succeeded
 */
function _emergencyRecover(
    address token,
    uint256 amount,
    address destination
) internal returns (bool success) {
    if (!emergencyModeActive) {
        revert EmergencyModeNotActive();
    }
    
    if (destination == address(0)) {
        revert InvalidAddress("destination", destination);
    }
    
    // If this is the staking token, ensure we don't withdraw staked funds
    if (token == address(stakingToken)) {
        uint256 availableBalance = IERC20(token).balanceOf(address(this)) - _totalStaked;
        if (amount > availableBalance) {
            amount = availableBalance;
        }
    }
    
    if (amount == 0) {
        return true;
    }
    
    success = _safeTransfer(token, destination, amount);
    
    if (success) {
        emit EmergencyRecovery(token, amount, destination);
    }
    
    return success;
}

/**
 * @dev Check and adjust dynamic rewards based on protocol state
 */
function _checkDynamicRewards() internal {
    // Only run this check once per day to save gas
    if (block.timestamp < lastRewardAdjustmentTime + 1 days) {
        return;
    }
    
    _adjustRewardRates();
}

/**
 * @dev Set emergency mode active
 * @param active Whether emergency mode should be active
 */
function _setEmergencyMode(bool active) internal {
    if (emergencyModeActive == active) {
        return;
    }
    
    emergencyModeActive = active;
    
    if (active) {
        emergencyModeActivationTime = block.timestamp;
        emit EmergencyModeActivated(msg.sender);
    } else {
        emit EmergencyModeDeactivated(msg.sender);
    }
}

/**
 * @dev Check if emergency mode cooldown is active
 * @return Whether cooldown is active
 */
function _isEmergencyCooldownActive() internal view returns (bool) {
    return block.timestamp < emergencyModeActivationTime + emergencyModeCooldown;
}

// -------------------------------------------
//  Events for Internal Utilities
// -------------------------------------------

event TokensBurned(uint256 amount, uint256 timestamp);
event EmergencyRecovery(address token, uint256 amount, address destination);
event EmergencyModeActivated(address activator);
event EmergencyModeDeactivated(address deactivator);
event NFTBoostStatusChanged(address indexed user, uint256 indexed projectId, bool hasBoost);
event ValidatorRewardDistributed(address indexed validator, uint256 amount);
event ValidatorRewardsAccumulated(uint256 amount, uint256 newTotal);
event TierMultiplierApplied(address indexed user, uint256 indexed projectId, uint256 tierId, uint256 multiplier);
event DynamicRewardRateUpdated(uint256 baseAPR, uint256 boostedAPR, uint256 timestamp);
event StakingPositionUpdated(address indexed user, uint256 indexed projectId, uint256 newAmount, uint256 newDuration);
event GovernanceVoteUpdated(address indexed user, uint256 newVotingPower);
event SlashingFundsDistributed(uint256 burned, uint256 redistributed, uint256 toLiquidity);
event AutoCompoundingToggled(address indexed user, uint256 indexed projectId, bool enabled);
event EmergencyCooldownUpdated(uint256 newCooldown);
event ValidatorSetUpdated(uint256 count, uint256 threshold);
event SecurityActionTaken(string action, address indexed target, uint256 timestamp);
event BatchOperationCompleted(string operation, uint256 processedCount, uint256 successCount);



