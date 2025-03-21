// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/ITerraStakeRewardDistributor.sol";
import "../interfaces/ITerraStakeProjects.sol";
import "../interfaces/ITerraStakeGovernance.sol";
import "../interfaces/ITerraStakeSlashing.sol";
import "../interfaces/IAIEngine.sol"; // Add AIEngine interface

/**
 * @title TerraStakeStaking
 * @notice Official staking contract for the TerraStake ecosystem with multi-project (batch) operations,
 * auto-compounding, dynamic APR, halving events, early-withdrawal penalties, and validator logic.
 * Now enhanced with Neural AI-driven staking optimization features.
 * @dev This contract is upgradeable (UUPS) and uses multiple OpenZeppelin libraries for security.
 */
contract TerraStakeStaking is 
    ITerraStakeStaking,
    Initializable,
    ERC165Upgradeable,
    AccessControlEnumerableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    PausableUpgradeable, 
    UUPSUpgradeable
{
    using Math for uint256;
    // -------------------------------------------
    //   Custom Errors
    // -------------------------------------------
    error ZeroAmount();
    error InsufficientStakingDuration(uint256 minimum, uint256 provided);
    error ProjectDoesNotExist(uint256 projectId);
    error NoActiveStakingPosition(address user, uint256 projectId);
    error TransferFailed(address token, address from, address to, uint256 amount);
    error InvalidAddress(string parameter, address provided);
    error InvalidParameter(string parameter, uint256 provided);
    error UnauthorizedCaller(address caller, string requiredRole);
    error StakingLocked(uint256 releaseTime);
    error GovernanceViolation(address user);
    error SlashingFailed(address validator, uint256 amount);
    error AlreadyValidator(address validator);
    error NotValidator(address account);
    error DistributionFailed(uint256 amount);
    error EmergencyPaused();
    error ActionNotPermittedForValidator();
    error RateTooHigh(uint256 provided, uint256 maximum);
    error InvalidTierConfiguration();
    error BatchTransferFailed();

    // AI-related errors
    error AIEngineNotConfigured();
    error AIProcessingFailed();
    error CircuitBreakerTriggered(address asset);

    // -------------------------------------------
    //   Constants
    // -------------------------------------------
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant UPGRADER_ROLE    = keccak256("UPGRADER_ROLE");
    bytes32 public constant EMERGENCY_ROLE   = keccak256("EMERGENCY_ROLE");
    bytes32 public constant SLASHER_ROLE     = keccak256("SLASHER_ROLE");
    uint256 public constant BASE_APR              = 10;   // 10% APR base
    uint256 public constant BOOSTED_APR           = 20;   // 20% APR if TVL < 1M TSTAKE
    uint256 public constant NFT_APR_BOOST         = 10;   // Additional +10% if user has NFT
    uint256 public constant LP_APR_BOOST          = 15;   // Additional +15% if LP staker
    uint256 public constant BASE_PENALTY_PERCENT  = 10;   // 10% base penalty for early unstake
    uint256 public constant MAX_PENALTY_PERCENT   = 30;   // 30% max penalty
    uint256 public constant LOW_STAKING_THRESHOLD = 1_000_000 * 10**18;
    uint256 public constant GOVERNANCE_VESTING_PERIOD = 7 days;
    uint256 public constant MAX_LIQUIDITY_RATE    = 10;
    uint256 public constant MIN_STAKING_DURATION  = 30 days;
    uint256 public constant GOVERNANCE_THRESHOLD  = 10_000 * 10**18; // min tokens for governance
    address private constant BURN_ADDRESS         = 0x000000000000000000000000000000000000dEaD;

    // AI-related constants
    bytes32 public constant AI_OPERATOR_ROLE = keccak256("AI_OPERATOR_ROLE");

    // -------------------------------------------
    //   State Variables 
    // -------------------------------------------
    IERC1155 public nftContract;
    IERC20 public stakingToken;
    ITerraStakeRewardDistributor public rewardDistributor;
    ITerraStakeProjects public projectsContract;
    ITerraStakeGovernance public governanceContract;
    ITerraStakeSlashing public slashingContract;
    address public liquidityPool;
    uint256 public liquidityInjectionRate;  // percentage of rewards reinjected
    bool    public autoLiquidityEnabled;
    uint256 public halvingPeriod;           // e.g. 730 days
    uint256 public lastHalvingTime;
    uint256 public halvingEpoch;
    uint256 public proposalNonce;
    uint256 public validatorThreshold;

    // AI-related state variables
    IAIEngine public aiEngine;
    bool public aiEnhancedStakingEnabled;
    uint256 public neuralWeightMultiplier; // Used to scale neural weight impact (10000 = 1x)
    uint256 public lastAIGlobalUpdate;
    uint256 public aiUpdateInterval;
    bool public emergencyAIBreakerTriggered;

    // Mappings must remain unchanged:
    /**
     * @dev Private mapping to track individual staking positions for each user
     * @notice Maps user addresses to their multiple staking positions, indexed by a unique position ID
     */
    mapping(address => mapping(uint256 => StakingPosition)) private _stakingPositions;
    mapping(address => uint256) private _governanceVotes;
    mapping(address => uint256) private _stakingBalance;
    mapping(address => bool)    private _governanceViolators;
    mapping(address => bool)    private _validators;
    uint256 private _totalStaked;
    StakingTier[] private _tiers;
    // Track active stakers
    address[] private _activeStakers;
    mapping(address => bool) private _isActiveStaker;
    // Additional state
    mapping(address => PenaltyEvent[]) private _penaltyHistory;
    mapping(address => uint256)         private _validatorCommission;
    mapping(uint256 => uint256)         private _projectVotes;
    uint256 public validatorRewardPool;
    uint256 public governanceQuorum;
    bool    public dynamicRewardsEnabled;
    uint256 public lastRewardAdjustmentTime;
    uint256 public dynamicBaseAPR;
    uint256 public dynamicBoostedAPR;
    // Track governance proposals

    // AI-related mappings
    mapping(address => bool) private _userOptedForAI;
    mapping(address => uint256) private _userLastNeuralUpdate;
    mapping(address => uint256) private _userNeuralScore;
    mapping(uint256 => bool) private _projectUsesAI;
    mapping(uint256 => uint256) private _projectAIMultiplier;

    /**
     * @dev Reserved storage space to avoid layout collisions during upgrades.
     *      Always keep this at the end of state variables.
     */
    uint256[45] private __gap; // Adjusted gap to account for new AI variables

    // AI-related events
    event AIEngineUpdated(address indexed newAIEngine);
    event AIEnhancedStakingToggled(bool enabled);
    event NeuralRewardApplied(address indexed user, uint256 projectId, uint256 baseReward, uint256 neuralReward);
    event UserAIPreferenceSet(address indexed user, bool optedIn);
    event ProjectAIStatusSet(uint256 indexed projectId, bool usesAI, uint256 multiplier);
    event UserNeuralScoreUpdated(address indexed user, uint256 oldScore, uint256 newScore);
    event AIGlobalUpdatePerformed(uint256 timestamp, uint256 assetCount);
    event AICircuitBreakerTriggered(address indexed trigerredBy, uint256 timestamp);
    event AICircuitBreakerReset(address indexed resetBy, uint256 timestamp);

    // -------------------------------------------
    //   Constructor & Initializer
    // -------------------------------------------

    /**
     * @notice Prevents initialization of the implementation contract
     * @dev Disables initializers to ensure the contract cannot be initialized directly, 
     *      following the UUPS upgradeable pattern
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the TerraStake staking contract with core configurations
     * @dev One-time initializer for the upgradeable contract that sets up contracts, roles, and initial staking parameters
     * @param _nftContract Address of the NFT contract used for staking boosts
     * @param _stakingToken Address of the token used for staking
     * @param _rewardDistributor Address of the contract responsible for reward distribution
     * @param _liquidityPool Address of the liquidity pool
     * @param _projectsContract Address of the projects management contract
     * @param _governanceContract Address of the governance contract
     * @param _admin Address of the contract administrator with privileged roles
     * @custom:security Only callable once during proxy deployment, with zero-address checks for all parameters
     */
    function initialize(
        address _nftContract,
        address _stakingToken,
        address _rewardDistributor,
        address _liquidityPool,
        address _projectsContract,
        address _governanceContract,
        address _admin
    ) external initializer {
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        __ERC165_init();
        if (_nftContract == address(0)) revert InvalidAddress("nftContract", _nftContract);
        if (_stakingToken == address(0)) revert InvalidAddress("stakingToken", _stakingToken);
        if (_rewardDistributor == address(0)) revert InvalidAddress("rewardDistributor", _rewardDistributor);
        if (_liquidityPool == address(0)) revert InvalidAddress("liquidityPool", _liquidityPool);
        if (_projectsContract == address(0)) revert InvalidAddress("projectsContract", _projectsContract);
        if (_governanceContract == address(0)) revert InvalidAddress("governanceContract", _governanceContract);
        if (_admin == address(0)) revert InvalidAddress("admin", _admin);
        nftContract      = IERC1155(_nftContract);
        stakingToken     = IERC20(_stakingToken);
        rewardDistributor= ITerraStakeRewardDistributor(_rewardDistributor);
        liquidityPool    = _liquidityPool;
        projectsContract = ITerraStakeProjects(_projectsContract);
        governanceContract = ITerraStakeGovernance(_governanceContract);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(GOVERNANCE_ROLE, _governanceContract);
        _grantRole(UPGRADER_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
        _grantRole(AI_OPERATOR_ROLE, _admin); // Grant AI operator role to admin
        halvingPeriod     = 730 days;
        lastHalvingTime   = block.timestamp;
        halvingEpoch      = 0;
        liquidityInjectionRate = 5;
        autoLiquidityEnabled   = true;
        validatorThreshold     = 100_000 * 10**18;

        // Initialize AI-enhanced staking parameters
        aiEnhancedStakingEnabled = false;
        neuralWeightMultiplier = 10000; // 1x by default
        aiUpdateInterval = 1 days;
        lastAIGlobalUpdate = block.timestamp;
        emergencyAIBreakerTriggered = false;

        // Initialize tiers – ensure they are ordered by duration ascending
        _tiers.push(StakingTier(30 days, 100, false));
        _tiers.push(StakingTier(90 days, 150, true));
        _tiers.push(StakingTier(180 days, 200, true));
        _tiers.push(StakingTier(365 days, 300, true));
        // Additional parameters
        governanceQuorum          = 1000;
        dynamicRewardsEnabled     = false;
        lastRewardAdjustmentTime  = block.timestamp;
        dynamicBaseAPR            = BASE_APR;
        dynamicBoostedAPR         = BOOSTED_APR;
    }

    /**
     * @dev Enforces upgrade authorization to the `UPGRADER_ROLE`.
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}

    // -------------------------------------------
    //   AI Engine Integration Functions
    // -------------------------------------------

    /**
     * @notice Set the AI Engine contract
     * @param _aiEngine Address of the AI Engine contract
     */
    function setAIEngine(address _aiEngine) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_aiEngine == address(0)) revert InvalidAddress("aiEngine", _aiEngine);
        aiEngine = IAIEngine(_aiEngine);
        emit AIEngineUpdated(_aiEngine);
    }

    /**
     * @notice Toggle AI-enhanced staking features
     * @param enabled Whether AI features should be enabled
     */
    function toggleAIEnhancedStaking(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        aiEnhancedStakingEnabled = enabled;
        emit AIEnhancedStakingToggled(enabled);
    }

    /**
     * @notice Set neural weight multiplier for reward scaling
     * @param newMultiplier New multiplier (10000 = 1x)
     */
    function setNeuralWeightMultiplier(uint256 newMultiplier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newMultiplier > 0 && newMultiplier <= 50000, "Invalid multiplier range"); // Max 5x
        neuralWeightMultiplier = newMultiplier;
    }

    /**
     * @notice User opts in or out of AI-enhanced staking
     * @param optIn Whether to opt in for AI enhancements
     */
    function setAIPreference(bool optIn) external {
        _userOptedForAI[msg.sender] = optIn;
        emit UserAIPreferenceSet(msg.sender, optIn);
    }

    /**
     * @notice Set a project's AI status and multiplier
     * @param projectId Project ID
     * @param usesAI Whether the project uses AI
     * @param multiplier AI reward multiplier for this project (10000 = 1x)
     */
    function setProjectAIStatus(uint256 projectId, bool usesAI, uint256 multiplier) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (!projectsContract.projectExists(projectId)) {
            revert ProjectDoesNotExist(projectId);
        }
        require(multiplier <= 30000, "Multiplier too high"); // Cap at 3x
        
        _projectUsesAI[projectId] = usesAI;
        _projectAIMultiplier[projectId] = multiplier;
        
        emit ProjectAIStatusSet(projectId, usesAI, multiplier);
    }

    /**
     * @notice Trigger AI circuit breaker in case of malfunction
     */
    function triggerAICircuitBreaker() external onlyRole(EMERGENCY_ROLE) {
        emergencyAIBreakerTriggered = true;
        emit AICircuitBreakerTriggered(msg.sender, block.timestamp);
    }

    /**
     * @notice Reset AI circuit breaker after emergency
     */
    function resetAICircuitBreaker() external onlyRole(DEFAULT_ADMIN_ROLE) {
        emergencyAIBreakerTriggered = false;
        emit AICircuitBreakerReset(msg.sender, block.timestamp);
    }

    /**
     * @notice Update neural scores for all active stakers
     * @dev Used by keepers and operators to keep neural scores fresh
     */
    function updateAllNeuralScores() external onlyRole(AI_OPERATOR_ROLE) {
        if (!aiEnhancedStakingEnabled || address(aiEngine) == address(0) || emergencyAIBreakerTriggered) return;
        
        address[] memory stakers = getActiveStakers();
        uint256 updateCount = 0;
        
        for (uint256 i = 0; i < stakers.length; i++) {
            address user = stakers[i];
            if (_userOptedForAI[user] && 
                (block.timestamp - _userLastNeuralUpdate[user] > aiUpdateInterval)) {
                
                // Update user's neural score based on staking behavior and patterns
                uint256 oldScore = _userNeuralScore[user];
                
                // Calculate a neural score based on user's staking behavior
                uint256 totalStaked = _stakingBalance[user];
                uint256 longestStake = 0;
                uint256 diversityFactor = 0;
                uint256 positionCount = 0;
                
                // Check each project to find active positions
                uint256 projectCount = projectsContract.getProjectCount();
                for (uint256 j = 1; j <= projectCount; j++) {
                    StakingPosition storage position = _stakingPositions[user][j];
                    if (position.amount > 0) {
                        positionCount++;
                        if (position.duration > longestStake) {
                            longestStake = position.duration;
                        }
                    }
                }
                
                // Add diversity factor for each unique project (with diminishing returns)
                diversityFactor = positionCount * 5;
                
                // Combine factors for neural score - weighting them appropriately
                uint256 stakedWeight = (totalStaked * 50) / (validatorThreshold); // Cap at 50
                if (stakedWeight > 50) stakedWeight = 50;
                
                uint256 durationWeight = (longestStake * 30) / (365 days); // Cap at 30
                if (durationWeight > 30) durationWeight = 30;
                
                // Cap diversity factor at 20
                if (diversityFactor > 20) diversityFactor = 20;
                
                // Combine all factors - total max score is 100
                uint256 newScore = stakedWeight + durationWeight + diversityFactor;
                
                _userNeuralScore[user] = newScore;
                _userLastNeuralUpdate[user] = block.timestamp;
                
                emit UserNeuralScoreUpdated(user, oldScore, newScore);
                
                updateCount++;
            }
        }
        
        // Update neural intelligence
        if (updateCount > 0) {
            // Global AI updates
            try aiEngine.triggerAdaptiveRebalance() {
                // Successfully triggered rebalance
            } catch {
                // Failed but continue
            }
            
            // Update the global timer
            lastAIGlobalUpdate = block.timestamp;
            
            emit AIGlobalUpdatePerformed(block.timestamp, updateCount);
        }
    }

    /**
     * @notice Get a user's neural score
     * @param user Address of the user
     * @return score User's neural score (0-100)
     * @return lastUpdate Timestamp of the last update
     */
    function getUserNeuralScore(address user) external view returns (uint256 score, uint256 lastUpdate) {
        return (_userNeuralScore[user], _userLastNeuralUpdate[user]);
    }

    /**
     * @notice Get AI-enhanced staking recommendations for a user
     * @param user Address of the user
     * @return projectIds Array of recommended project IDs
     * @return scores Array of project scores (higher is better)
     */
    function getAIStakingRecommendations(address user) external view returns (uint256[] memory projectIds, uint256[] memory scores) {
        if (!aiEnhancedStakingEnabled || address(aiEngine) == address(0) || !_userOptedForAI[user]) {
            // Return empty arrays if AI is not enabled
            return (new uint256[](0), new uint256[](0));
        }
        
        // Find AI-enabled projects
        uint256 projectCount = projectsContract.getProjectCount();
        uint256 aiProjectCount = 0;
        
        // First count how many AI projects we have
        for (uint256 i = 1; i <= projectCount; i++) {
            if (_projectUsesAI[i]) {
                aiProjectCount++;
            }
        }
        
        projectIds = new uint256[](aiProjectCount);
        scores = new uint256[](aiProjectCount);
        
        // Fill arrays with AI project recommendations
        uint256 index = 0;
        for (uint256 i = 1; i <= projectCount; i++) {
            if (_projectUsesAI[i]) {
                projectIds[index] = i;
                
                // Calculate a score based on project multiplier and user's neural score
                uint256 projectMult = _projectAIMultiplier[i] == 0 ? 10000 : _projectAIMultiplier[i];
                uint256 userScore = _userNeuralScore[user];
                
                // Score formula: project multiplier * user score / 10000
                scores[index] = (projectMult * userScore) / 10000;
                
                index++;
            }
        }
        
        // Sort by score (descending) using a simple bubble sort
        for (uint256 i = 0; i < aiProjectCount - 1; i++) {
            for (uint256 j = 0; j < aiProjectCount - i - 1; j++) {
                if (scores[j] < scores[j + 1]) {
                    // Swap scores
                    uint256 tempScore = scores[j];
                    scores[j] = scores[j + 1];
                    scores[j + 1] = tempScore;
                    
                    // Swap project IDs
                    uint256 tempId = projectIds[j];
                    projectIds[j] = projectIds[j + 1];
                    projectIds[j + 1] = tempId;
                }
            }
        }
        
        return (projectIds, scores);
    }

    /**
     * @notice Set the AI update interval
     * @param newInterval New interval in seconds
     */
    function setAIUpdateInterval(uint256 newInterval) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newInterval >= 1 hours && newInterval <= 30 days, "Invalid interval");
        aiUpdateInterval = newInterval;
    }

    /**
     * @notice Sync user's staking activity with the AI engine
     * @param user Address of the user
     * @dev Called internally after significant staking events
     */
    function _syncUserWithAIEngine(address user) internal {
        if (!aiEnhancedStakingEnabled || address(aiEngine) == address(0) || emergencyAIBreakerTriggered || !_userOptedForAI[user]) {
            return;
        }
        
        try aiEngine.updateNeuralWeight(
            user, 
            _stakingBalance[user], // Use total staked amount as a signal
            20 // Default smoothing factor
        ) {
            // Successfully updated neural weight
            _userLastNeuralUpdate[user] = block.timestamp;
        } catch {
            // Failed to update, but continue execution
        }
    }

    /**
     * @notice Get project AI status information
     * @param projectId ID of the project
     * @return usesAI Whether the project uses AI
     * @return multiplier The AI multiplier for the project
     */
    function getProjectAIStatus(uint256 projectId) external view returns (bool usesAI, uint256 multiplier) {
        return (_projectUsesAI[projectId], _projectAIMultiplier[projectId]);
    }

    /**
     * @notice Batch set AI status for multiple projects
     * @param projectIds Array of project IDs
     * @param usesAI Array of AI status flags
     * @param multipliers Array of multipliers
     */
    function batchSetProjectAIStatus(
        uint256[] calldata projectIds,
        bool[] calldata usesAI,
        uint256[] calldata multipliers
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(
            projectIds.length == usesAI.length && 
            projectIds.length == multipliers.length,
            "Array length mismatch"
        );
        
        for (uint256 i = 0; i < projectIds.length; i++) {
            if (!projectsContract.projectExists(projectIds[i])) {
                revert ProjectDoesNotExist(projectIds[i]);
            }
            require(multipliers[i] <= 30000, "Multiplier too high"); // Cap at 3x
            
            _projectUsesAI[projectIds[i]] = usesAI[i];
            _projectAIMultiplier[projectIds[i]] = multipliers[i];
            
            emit ProjectAIStatusSet(projectIds[i], usesAI[i], multipliers[i]);
        }
    }

    /**
     * @notice Request a neural weight update for the staking token
     * @dev Can be called by admins to manually trigger updates
     */
    function requestTokenNeuralUpdate() external onlyRole(AI_OPERATOR_ROLE) {
        if (!aiEnhancedStakingEnabled || address(aiEngine) == address(0) || emergencyAIBreakerTriggered) {
            return;
        }
        
        // Get total staked and user count
        uint256 totalStaked = _totalStaked;
        
        // Update neural weight based on total staking metrics
        try aiEngine.updateNeuralWeight(
            address(stakingToken),
            totalStaked,
            15 // Medium smoothing factor
        ) {
            // Success
        } catch {
            // Failed but continue
        }
    }

    // -------------------------------------------
    //   Enhanced Staking Operations with AI
    // -------------------------------------------

    /**
     * @notice AI-enhanced calculation of user's pending rewards for a specific position.
     * @dev This overrides the existing calculateRewards function to add AI enhancements
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
        uint256 tierId       = getApplicableTier(position.duration);
        uint256 tierMult     = _tiers[tierId].multiplier;
        
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
        
        // Calculate base reward using original formula
        uint256 baseReward = (position.amount * effectiveRate * stakingTime)
            / (100 * 365 days);
            
        // AI enhancement logic
        if (aiEnhancedStakingEnabled && !emergencyAIBreakerTriggered && 
            address(aiEngine) != address(0) && 
            _userOptedForAI[user] && _projectUsesAI[projectId]) {
            
            // Get neural weight for the stakingToken
            try aiEngine.assetNeuralWeights(address(stakingToken)) returns (IAIEngine.NeuralWeight memory weight) {
                if (weight.currentWeight > 0) {
                    // Apply neural weight multiplier to base reward
                    uint256 projectMultiplier = _projectAIMultiplier[projectId];
                    if (projectMultiplier == 0) projectMultiplier = 10000; // Default 1x
                    
                    uint256 userScore = _userNeuralScore[user];
                    
                    // Neural boost formula: base * (1 + (neural_weight * project_multiplier * user_score) / (10000 * 10000 * 100))
                    uint256 neuralBoost = (weight.currentWeight * projectMultiplier * userScore) / (10000 * 10000 * 100);
                    
                    // Apply neuralWeightMultiplier as a scaling factor
                    neuralBoost = (neuralBoost * neuralWeightMultiplier) / 10000;
                    
                    // Cap the boost at doubling the reward (adjust as needed)
                    if (neuralBoost > 10000) neuralBoost = 10000;
                    
                    // Apply boost: base * (1 + boost/10000)
                    uint256 aiEnhancedReward = baseReward + ((baseReward * neuralBoost) / 10000);
                    return aiEnhancedReward;
                }
            } catch {
                // If neural weight retrieval fails, return base reward
            }
        }
        
        // Return base reward if AI enhancement is not applicable
        return baseReward;
    }

    // -------------------------------------------
    //   Staking Operations
    // -------------------------------------------

    /**
     * @notice Stake tokens for a single project.
     * @param projectId  ID of the project
     * @param amount     Amount to stake
     * @param duration   Desired staking duration
     * @param isLP       Whether staking LP tokens
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
        if (amount == 0) revert ZeroAmount();
        if (duration < MIN_STAKING_DURATION) {
            revert InsufficientStakingDuration(MIN_STAKING_DURATION, duration);
        }
        if (!projectsContract.projectExists(projectId)) {
            revert ProjectDoesNotExist(projectId);
        }
        uint256 userStakingBalance   = _stakingBalance[msg.sender];
        uint256 currentTotalStaked   = _totalStaked;
        bool hasNFTBoost             = (nftContract.balanceOf(msg.sender, 1) > 0);
        // Get or create the staking position
        StakingPosition storage position = _stakingPositions[msg.sender][projectId];
        // If this is an existing position, claim up to now
        if (position.amount > 0) {
            _claimRewards(msg.sender, projectId);
        } else {
            position.stakingStart = block.timestamp;
            position.projectId    = projectId;
        }
        // Update position
        position.amount         += amount;
        position.lastCheckpoint  = block.timestamp;
        position.duration        = duration;
        position.isLPStaker      = isLP;
        position.hasNFTBoost     = hasNFTBoost;
        position.autoCompounding = autoCompound;
        // Update global stats
        currentTotalStaked += amount;
        _totalStaked        = currentTotalStaked;
        userStakingBalance += amount;
        _stakingBalance[msg.sender] = userStakingBalance;
        // Update governance votes if threshold is reached
        if (userStakingBalance >= GOVERNANCE_THRESHOLD && !_governanceViolators[msg.sender]) {
            _governanceVotes[msg.sender] = userStakingBalance;
        }
        // Transfer tokens
        bool success = stakingToken.transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert TransferFailed(address(stakingToken), msg.sender, address(this), amount);
        }
        // Inform projectsContract that there's a new staker
        projectsContract.incrementStakerCount(projectId);
        // Check if user is now a validator
        if (userStakingBalance >= validatorThreshold && !_validators[msg.sender]) {
            _validators[msg.sender] = true;
            emit ValidatorStatusChanged(msg.sender, true);
        }
        if (!_isActiveStaker[msg.sender]) {
            _isActiveStaker[msg.sender] = true;
            _activeStakers.push(msg.sender);
        }
        
        // AI integration - sync user with AI engine
        if (aiEnhancedStakingEnabled && _userOptedForAI[msg.sender] && _projectUsesAI[projectId]) {
            _syncUserWithAIEngine(msg.sender);
        }
        
        emit Staked(msg.sender, projectId, amount, duration, block.timestamp, position.amount);
    }

    /**
     * @dev Internal function to claim user rewards up to now with AI enhancement.
     */
    function _claimRewards(address user, uint256 projectId) internal {
        StakingPosition storage position = _stakingPositions[user][projectId];
        if (position.amount == 0) {
            revert NoActiveStakingPosition(user, projectId);
        }
        
        uint256 reward = calculateRewards(user, projectId);
        
        if (reward == 0) {
            position.lastCheckpoint = block.timestamp;
            return;
        }
        
        // Record AI-enhanced reward statistics if applicable
        uint256 baseReward = 0;
        uint256 aiBonus = 0;
        
        if (aiEnhancedStakingEnabled && _userOptedForAI[user] && _projectUsesAI[projectId]) {
            // Calculate the base reward without AI enhancement
            uint256 stakingTime = block.timestamp - position.lastCheckpoint;
            uint256 tierId = getApplicableTier(position.duration);
            uint256 tierMult = _tiers[tierId].multiplier;
            uint256 baseRate = (_totalStaked < LOW_STAKING_THRESHOLD) ? dynamicBoostedAPR : dynamicBaseAPR;
            if (position.hasNFTBoost) {
                baseRate += NFT_APR_BOOST;
            }
            if (position.isLPStaker) {
                baseRate += LP_APR_BOOST;
            }
            uint256 effectiveRate = (baseRate * tierMult) / 100;
            baseReward = (position.amount * effectiveRate * stakingTime) / (100 * 365 days);
            
            // Calculate AI bonus
            aiBonus = reward > baseReward ? reward - baseReward : 0;
            
            if (aiBonus > 0) {
                emit NeuralRewardApplied(user, projectId, baseReward, aiBonus);
            }
        }
        
        // Auto-compounding logic
        if (position.autoCompounding) {
            uint256 compoundAmount = (reward * 20) / 100; // 20% of reward is auto-compounded
            position.amount        += compoundAmount;
            _totalStaked           += compoundAmount;
            _stakingBalance[user]  += compoundAmount;
            // If user crosses threshold again
            if (_stakingBalance[user] >= GOVERNANCE_THRESHOLD && !_governanceViolators[user]) {
                _governanceVotes[user] = _stakingBalance[user];
            }
            reward -= compoundAmount;
            emit RewardCompounded(user, projectId, compoundAmount, block.timestamp);
        }
        
        // Liquidity injection if enabled
        if (autoLiquidityEnabled) {
            uint256 liquidityAmount = (reward * liquidityInjectionRate) / 100;
            if (liquidityAmount > 0) {
                reward -= liquidityAmount;
                bool liqSuccess = stakingToken.transfer(liquidityPool, liquidityAmount);
                if (!liqSuccess) {
                    revert TransferFailed(address(stakingToken), address(this), liquidityPool, liquidityAmount);
                }
                emit LiquidityInjected(liquidityPool, liquidityAmount, block.timestamp);
            }
        }
        
        // Additional logic to distribute validator portion
        _distributeValidatorRewards(reward);
        
        position.lastCheckpoint = block.timestamp;
        
        // Send the remainder to user
        if (reward > 0) {
            bool success = rewardDistributor.distributeReward(user, reward);
            if (!success) {
                revert DistributionFailed(reward);
            }
            emit RewardClaimed(user, projectId, reward, block.timestamp);
        }
    }

    /**
     * @notice Unstake tokens from a single project with AI integration.
     * @param projectId The project to unstake from
     */
    function unstake(uint256 projectId) external nonReentrant {
        StakingPosition storage position = _stakingPositions[msg.sender][projectId];
        if (position.amount == 0) {
            revert NoActiveStakingPosition(msg.sender, projectId);
        }
        
        _claimRewards(msg.sender, projectId);
        
        uint256 amount       = position.amount;
        uint256 stakingTime  = block.timestamp - position.stakingStart;
        uint256 penalty      = 0;
        
        // If we haven't reached the user's stated duration, impose penalty
        if (stakingTime < position.duration) {
            uint256 remainingTime = position.duration - stakingTime;
            uint256 penaltyPercent = BASE_PENALTY_PERCENT
                + ((remainingTime * (MAX_PENALTY_PERCENT - BASE_PENALTY_PERCENT)) / position.duration);
            penalty = (amount * penaltyPercent) / 100;
            _handlePenalty(msg.sender, projectId, penalty);
        }
        
        _totalStaked                -= amount;
        _stakingBalance[msg.sender] -= amount;
        
        // Adjust governance votes if they fell below threshold
        if (_stakingBalance[msg.sender] < GOVERNANCE_THRESHOLD) {
            _governanceVotes[msg.sender] = 0;
        } else {
            _governanceVotes[msg.sender] = _stakingBalance[msg.sender];
        }
        
        // Update project stats
        projectsContract.decrementStakerCount(projectId);
        
        // Clear position
        delete _stakingPositions[msg.sender][projectId];
        
        // Check if we drop below validator threshold
        if (_validators[msg.sender] && _stakingBalance[msg.sender] < validatorThreshold) {
            _validators[msg.sender] = false;
            emit ValidatorStatusChanged(msg.sender, false);
        }
        
        uint256 transferAmount = amount - penalty;
        
        bool success = stakingToken.transfer(msg.sender, transferAmount);
        if (!success) {
            revert TransferFailed(address(stakingToken), address(this), msg.sender, transferAmount);
        }
        
        if (_stakingBalance[msg.sender] == 0) {
            _isActiveStaker[msg.sender] = false;
            _removeInactiveStaker(msg.sender);
        }
        
        // AI integration - sync user with AI engine after unstaking
        if (aiEnhancedStakingEnabled && _userOptedForAI[msg.sender]) {
            _syncUserWithAIEngine(msg.sender);
        }
        
        emit Unstaked(msg.sender, projectId, transferAmount, penalty, block.timestamp);
    }

    /**
     * @notice Check if a user is eligible for AI-enhanced staking
     * @param user Address of the user to check
     * @return isEligible Whether the user is eligible
     * @return neuralScore User's current neural score
     */
    function checkAIEligibility(address user) external view returns (bool isEligible, uint256 neuralScore) {
        if (!aiEnhancedStakingEnabled || address(aiEngine) == address(0) || emergencyAIBreakerTriggered) {
            return (false, 0);
        }
        
        bool hasOptedIn = _userOptedForAI[user];
        uint256 score = _userNeuralScore[user];
        
        // User is eligible if they've opted in and have a positive neural score
        return (hasOptedIn && score > 0, score);
    }

    /**
     * @dev Implements ERC165 interface detection with comprehensive support
     * @notice Explicitly declares all interfaces supported by this contract
     * @param interfaceId The interface identifier to check
     * @return bool True if the interface is supported
     */
    function supportsInterface(bytes4 interfaceId)
    public
    view
    override(AccessControlEnumerableUpgradeable, ERC165Upgradeable)
    returns (bool)
{
    return
        interfaceId == type(ITerraStakeStaking).interfaceId ||
        // Add support for IAIEngine interface detection
        interfaceId == type(IAIEngine).interfaceId || 
        super.supportsInterface(interfaceId);
}

/**
 * @notice Get recommended staking projects for a user based on AI analysis
 * @param user Address of the user
 * @param limit Maximum number of recommendations to return
 * @return topProjects Array of top recommended project IDs
 * @return scores Corresponding recommendation scores
 */
function getAIRecommendedProjects(address user, uint256 limit) external view returns (uint256[] memory topProjects, uint256[] memory scores) {
    if (!aiEnhancedStakingEnabled || address(aiEngine) == address(0) || !_userOptedForAI[user]) {
        return (new uint256[](0), new uint256[](0));
    }
    
    // Find AI-enabled projects
    uint256 projectCount = projectsContract.getProjectCount();
    uint256 aiProjectCount = 0;
    
    // First count AI-enabled projects
    for (uint256 i = 1; i <= projectCount; i++) {
        if (_projectUsesAI[i]) {
            aiProjectCount++;
        }
    }
    
    if (aiProjectCount == 0) {
        return (new uint256[](0), new uint256[](0));
    }
    
    // Use the smaller of aiProjectCount or limit
    uint256 resultSize = aiProjectCount < limit ? aiProjectCount : limit;
    
    // Temporary arrays to store all AI projects
    uint256[] memory allProjects = new uint256[](aiProjectCount);
    uint256[] memory allScores = new uint256[](aiProjectCount);
    
    // Result arrays
    topProjects = new uint256[](resultSize);
    scores = new uint256[](resultSize);
    
    // Fill temporary arrays with AI project data
    uint256 index = 0;
    for (uint256 i = 1; i <= projectCount; i++) {
        if (_projectUsesAI[i]) {
            allProjects[index] = i;
            
            // Calculate recommendation score
            uint256 projectMult = _projectAIMultiplier[i] == 0 ? 10000 : _projectAIMultiplier[i];
            uint256 userScore = _userNeuralScore[user];
            
            // Add neural weight influence from AIEngine if available
            uint256 neuralWeight = 10000; // Default 1.0
            try aiEngine.assetNeuralWeights(address(uint160(i))) returns (IAIEngine.NeuralWeight memory weight) {
                if (weight.currentWeight > 0) {
                    neuralWeight = weight.currentWeight;
                }
            } catch {
                // Use default if call fails
            }
            
            // Score formula: (project multiplier * user score * neural weight) / 10000^2
            allScores[index] = (projectMult * userScore * neuralWeight) / (10000 * 10000);
            
            index++;
        }
    }
    
    // Find top projects (basic selection algorithm)
    for (uint256 i = 0; i < resultSize; i++) {
        uint256 maxScore = 0;
        uint256 maxIndex = 0;
        
        for (uint256 j = 0; j < aiProjectCount; j++) {
            if (allScores[j] > maxScore) {
                maxScore = allScores[j];
                maxIndex = j;
            }
        }
        
        // Store result and "remove" this project from consideration
        topProjects[i] = allProjects[maxIndex];
        scores[i] = allScores[maxIndex];
        allScores[maxIndex] = 0; // Mark as processed
    }
    
    return (topProjects, scores);
}

/**
 * @notice Sync project data with the AI engine
 * @param projectId ID of the project to sync
 */
function syncProjectWithAIEngine(uint256 projectId) external onlyRole(AI_OPERATOR_ROLE) {
    if (!aiEnhancedStakingEnabled || address(aiEngine) == address(0) || emergencyAIBreakerTriggered) {
        return;
    }
    
    if (!projectsContract.projectExists(projectId)) {
        revert ProjectDoesNotExist(projectId);
    }
    
    if (!_projectUsesAI[projectId]) {
        return; // Only sync AI-enabled projects
    }
    
    // Count stakers and total staked in this project
    address[] memory stakers = getActiveStakers();
    uint256 totalProjectStaked = 0;
    uint256 projectStakerCount = 0;
    
    for (uint256 i = 0; i < stakers.length; i++) {
        StakingPosition storage position = _stakingPositions[stakers[i]][projectId];
        if (position.amount > 0) {
            totalProjectStaked += position.amount;
            projectStakerCount++;
        }
    }
    
    // Update the AI engine with project metrics
    // Assuming the project address is mapped directly to project ID for simplicity
    // In a real implementation, you would have a mapping from projectId to a contract address
    try aiEngine.updateNeuralWeight(
        address(uint160(projectId)), // Convert project ID to an address for the neural mapping
        totalProjectStaked, // Total staked as the signal
        10 // Lower smoothing factor for projects to make them more responsive
    ) {
        // Success
    } catch {
        // Failed but continue
    }
}

/**
 * @notice Check price feeds for AI-enabled projects
 * @dev Performs sanity checks on the price feeds of AI-enabled projects
 */
function checkAIPriceFeeds() external view returns (bool[] memory status, address[] memory projects) {
    if (!aiEnhancedStakingEnabled || address(aiEngine) == address(0)) {
        return (new bool[](0), new address[](0));
    }
    
    uint256 projectCount = projectsContract.getProjectCount();
    uint256 aiProjectCount = 0;
    
    // Count AI-enabled projects first
    for (uint256 i = 1; i <= projectCount; i++) {
        if (_projectUsesAI[i]) {
            aiProjectCount++;
        }
    }
    
    status = new bool[](aiProjectCount);
    projects = new address[](aiProjectCount);
    
    uint256 index = 0;
    for (uint256 i = 1; i <= projectCount; i++) {
        if (_projectUsesAI[i]) {
            address projectAddr = address(uint160(i)); // Convert project ID to address
            projects[index] = projectAddr;
            
            try aiEngine.priceFeeds(projectAddr) returns (address priceFeed) {
                status[index] = priceFeed != address(0);
            } catch {
                status[index] = false;
            }
            
            index++;
        }
    }
    
    return (status, projects);
}

/**
 * @notice Query the AI engine for the latest price of a project
 * @param projectId ID of the project
 * @return price The latest price, or 0 if unavailable
 * @return isFresh Whether the price is fresh
 */
function getAIProjectPrice(uint256 projectId) external view returns (uint256 price, bool isFresh) {
    if (!aiEnhancedStakingEnabled || address(aiEngine) == address(0) || !_projectUsesAI[projectId]) {
        return (0, false);
    }
    
    address projectAddr = address(uint160(projectId)); // Convert project ID to address
    
    try aiEngine.getLatestPrice(projectAddr) returns (uint256 latestPrice, bool priceFresh) {
        return (latestPrice, priceFresh);
    } catch {
        return (0, false);
    }
}

/**
 * @notice Update project price feed in the AI engine
 * @param projectId ID of the project
 * @param priceFeed Address of the price feed contract
 */
function updateProjectPriceFeed(uint256 projectId, address priceFeed) external onlyRole(AI_OPERATOR_ROLE) {
    if (!aiEnhancedStakingEnabled || address(aiEngine) == address(0)) {
        return;
    }
    
    if (!projectsContract.projectExists(projectId)) {
        revert ProjectDoesNotExist(projectId);
    }
    
    if (priceFeed == address(0)) {
        revert InvalidAddress("priceFeed", priceFeed);
    }
    
    address projectAddr = address(uint160(projectId)); // Convert project ID to address
    
    try aiEngine.updatePriceFeedAddress(projectAddr, priceFeed) {
        _projectUsesAI[projectId] = true; // Enable AI for this project when setting price feed
    } catch {
        revert("Failed to update price feed");
    }
}

/**
 * @notice Get the neural diversity index from the AI engine
 * @return The current diversity index value
 */
function getAIDiversityIndex() external view returns (uint256) {
    if (!aiEnhancedStakingEnabled || address(aiEngine) == address(0)) {
        return 0;
    }
    
    try aiEngine.diversityIndex() returns (uint256 index) {
        return index;
    } catch {
        return 0;
    }
}

/**
 * @notice User-specific view of AI-enhanced staking information
 * @param user Address of the user
 * @return hasOptedIn Whether user has opted in to AI features
 * @return neuralScore User's neural score
 * @return lastUpdateTime Timestamp of last neural update
 * @return enhancedAPY Estimated APY with AI enhancements
 */
function getUserAIStakingInfo(address user) external view returns (
    bool hasOptedIn,
    uint256 neuralScore,
    uint256 lastUpdateTime,
    uint256 enhancedAPY
) {
    hasOptedIn = _userOptedForAI[user];
    neuralScore = _userNeuralScore[user];
    lastUpdateTime = _userLastNeuralUpdate[user];
    
    // Calculate an estimated enhanced APY
    enhancedAPY = dynamicBaseAPR; // Start with base APR
    
    if (aiEnhancedStakingEnabled && hasOptedIn && neuralScore > 0) {
        // Simplified formula for enhanced APY estimate
        uint256 aiBoost = (neuralScore * neuralWeightMultiplier) / 10000;
        enhancedAPY = enhancedAPY + ((enhancedAPY * aiBoost) / 100);
        
        // Cap at a reasonable maximum
        if (enhancedAPY > 100) {
            enhancedAPY = 100; // 100% APY maximum
        }
    }
    
    return (hasOptedIn, neuralScore, lastUpdateTime, enhancedAPY);
}

/**
 * @notice Forces a rebalance through the AI engine
 * @dev Only callable by AI operator
 * @return success Whether rebalance was triggered successfully
 */
function forceAIRebalance() external onlyRole(AI_OPERATOR_ROLE) returns (bool success) {
    if (!aiEnhancedStakingEnabled || address(aiEngine) == address(0) || emergencyAIBreakerTriggered) {
        return false;
    }
    try aiEngine.triggerAdaptiveRebalance() {
        success = true;
    } catch {
        success = false;
    }
    
    return success;
}

/**
 * @notice Batch stake tokens across multiple projects in a single transaction with AI integration.
 * @param projectIds    Array of project IDs to stake into
 * @param amounts       Array of amounts to stake
 * @param durations     Array of staking durations
 * @param isLP          Array of booleans if the position is LP
 * @param autoCompound  Array of booleans if auto-compounding is enabled
 */
function batchStake(
    uint256[] calldata projectIds,
    uint256[] calldata amounts,
    uint256[] calldata durations,
    bool[]    calldata isLP,
    bool[]    calldata autoCompound
)
    external
    nonReentrant
    whenNotPaused
{
    uint256 length = projectIds.length;
    if (length == 0) {
        revert InvalidParameter("projectIds", 0);
    }
    // Validate array lengths
    if (
        amounts.length     != length ||
        durations.length   != length ||
        isLP.length        != length ||
        autoCompound.length!= length
    ) {
        revert InvalidParameter("arrayLengths", length);
    }
    // Hard limit to help avoid block gas blowouts or malicious usage
    // (You can adjust this to a safe upper bound for your environment)
    require(length <= 50, "batchStake: too many items");
    // Calculate total needed for all stakes
    uint256 totalAmount = 0;
    for (uint256 i = 0; i < length; i++) {
        if (amounts[i] == 0) {
            revert ZeroAmount();
        }
        totalAmount += amounts[i];
    }
    // Transfer total in one call for gas efficiency
    if (!stakingToken.transferFrom(msg.sender, address(this), totalAmount)) {
        revert TransferFailed(address(stakingToken), msg.sender, address(this), totalAmount);
    }
    bool hasNFTBoost = (nftContract.balanceOf(msg.sender, 1) > 0);
    uint256 stakedSoFar = 0;
    for (uint256 i = 0; i < length; i++) {
        if (durations[i] < MIN_STAKING_DURATION) {
            revert InsufficientStakingDuration(MIN_STAKING_DURATION, durations[i]);
        }
        if (!projectsContract.projectExists(projectIds[i])) {
            revert ProjectDoesNotExist(projectIds[i]);
        }
        // Retrieve or create the position
        StakingPosition storage position = _stakingPositions[msg.sender][projectIds[i]];
        if (position.amount > 0) {
            _claimRewards(msg.sender, projectIds[i]);
        } else {
            position.stakingStart = block.timestamp;
            position.projectId    = projectIds[i];
        }
        position.amount         += amounts[i];
        position.lastCheckpoint  = block.timestamp;
        position.duration        = durations[i];
        position.isLPStaker      = isLP[i];
        position.hasNFTBoost     = hasNFTBoost;
        position.autoCompounding = autoCompound[i];
        stakedSoFar         += amounts[i];
        _totalStaked        += amounts[i];
        _stakingBalance[msg.sender] += amounts[i];
        // Update project stats
        projectsContract.incrementStakerCount(projectIds[i]);
        emit Staked(
            msg.sender,
            projectIds[i],
            amounts[i],
            durations[i],
            block.timestamp,
            position.amount
        );
    }
    // Update governance votes if threshold is reached
    uint256 userBal = _stakingBalance[msg.sender];
    if (userBal >= GOVERNANCE_THRESHOLD && !_governanceViolators[msg.sender]) {
        _governanceVotes[msg.sender] = userBal;
    }
    // Check validator status
    if (userBal >= validatorThreshold && !_validators[msg.sender]) {
        _validators[msg.sender] = true;
        emit ValidatorStatusChanged(msg.sender, true);
    }
    if (!_isActiveStaker[msg.sender]) {
        _isActiveStaker[msg.sender] = true;
        _activeStakers.push(msg.sender);
    }
    
    // AI integration - sync user with AI engine after batch staking
    if (aiEnhancedStakingEnabled && _userOptedForAI[msg.sender]) {
        _syncUserWithAIEngine(msg.sender);
    }
}

/**
 * @notice Unstake tokens from multiple projects in one transaction with AI integration.
 * @param projectIds Array of project IDs to unstake from.
 */
function batchUnstake(uint256[] calldata projectIds) external nonReentrant whenNotPaused {
    uint256 length = projectIds.length;
    if (length == 0) {
        revert InvalidParameter("projectIds", 0);
    }
    // Hard limit to prevent huge loops
    require(length <= 50, "batchUnstake: too many items");
    uint256 totalAmount       = 0;
    uint256 totalPenalty      = 0;
    uint256 totalToRedistribute = 0;
    uint256 totalToBurn       = 0;
    uint256 totalToLiquidity  = 0;
    for (uint256 i = 0; i < length; i++) {
        uint256 projectId = projectIds[i];
        StakingPosition storage position = _stakingPositions[msg.sender][projectId];
        if (position.amount == 0) {
            revert NoActiveStakingPosition(msg.sender, projectId);
        }
        // Claim up to date
        _claimRewards(msg.sender, projectId);
        uint256 posAmount    = position.amount;
        uint256 stakingEnd   = position.stakingStart + position.duration;
        uint256 penalty      = 0;
        uint256 toRedistribute = 0;
        uint256 toBurn       = 0;
        uint256 toLiquidity  = 0;
        if (block.timestamp < stakingEnd) {
            uint256 remainingTime   = stakingEnd - block.timestamp;
            uint256 penaltyPercent  = BASE_PENALTY_PERCENT
                + ((remainingTime * (MAX_PENALTY_PERCENT - BASE_PENALTY_PERCENT)) / position.duration);
            penalty = (posAmount * penaltyPercent) / 100;
            if (penalty > 0) {
                toRedistribute = penalty / 2;     // 50% to stakers
                toBurn         = penalty / 4;     // 25% burn
                toLiquidity    = penalty - toRedistribute - toBurn; // 25% to liquidity
                _penaltyHistory[msg.sender].push(PenaltyEvent({
                    projectId:     projectId,
                    timestamp:     block.timestamp,
                    totalPenalty:  penalty,
                    redistributed: toRedistribute,
                    burned:        toBurn,
                    toLiquidity:   toLiquidity
                }));
            }
        }
        totalAmount += (posAmount - penalty);
        totalPenalty += penalty;
        totalToRedistribute += toRedistribute;
        totalToBurn += toBurn;
        totalToLiquidity += toLiquidity;
        _totalStaked                -= posAmount;
        _stakingBalance[msg.sender] -= posAmount;
        // Decrement staker count
        projectsContract.decrementStakerCount(projectId);
        // Clear the position
        delete _stakingPositions[msg.sender][projectId];
        emit Unstaked(msg.sender, projectId, posAmount - penalty, penalty, block.timestamp);
    }
    // Update governance votes
    if (_stakingBalance[msg.sender] < GOVERNANCE_THRESHOLD) {
        _governanceVotes[msg.sender] = 0;
    } else {
        _governanceVotes[msg.sender] = _stakingBalance[msg.sender];
    }
    // Check validator status
    if (_validators[msg.sender] && _stakingBalance[msg.sender] < validatorThreshold) {
        _validators[msg.sender] = false;
        emit ValidatorStatusChanged(msg.sender, false);
    }
    // Transfer the user's net tokens
    if (totalAmount > 0) {
        bool success = stakingToken.transfer(msg.sender, totalAmount);
        if (!success) {
            revert TransferFailed(address(stakingToken), address(this), msg.sender, totalAmount);
        }
    }
    // Process penalty distributions
    if (totalPenalty > 0) {
        // Burn portion
        if (totalToBurn > 0) {
            bool success = stakingToken.transfer(BURN_ADDRESS, totalToBurn);
            if (!success) {
                revert TransferFailed(address(stakingToken), address(this), BURN_ADDRESS, totalToBurn);
            }
            emit SlashedTokensBurned(totalToBurn);
        }
        // Redistribute portion
        if (totalToRedistribute > 0) {
            bool success = stakingToken.transfer(address(rewardDistributor), totalToRedistribute);
            if (!success) {
                revert TransferFailed(address(stakingToken), address(this), address(rewardDistributor), totalToRedistribute);
            }
            rewardDistributor.addPenaltyRewards(totalToRedistribute);
            emit SlashedTokensDistributed(totalToRedistribute);
        }
        // Liquidity portion
        if (totalToLiquidity > 0) {
            bool success = stakingToken.transfer(liquidityPool, totalToLiquidity);
            if (!success) {
                revert TransferFailed(address(stakingToken), address(this), liquidityPool, totalToLiquidity);
            }
            emit LiquidityInjected(liquidityPool, totalToLiquidity, block.timestamp);
        }
    }
    if (_stakingBalance[msg.sender] == 0) {
        _isActiveStaker[msg.sender] = false;
        _removeInactiveStaker(msg.sender);
    }
    
    // AI integration - sync user with AI engine after batch unstaking
    if (aiEnhancedStakingEnabled && _userOptedForAI[msg.sender]) {
        _syncUserWithAIEngine(msg.sender);
    }
}

/**
 * @notice Finalizes staking for a specific project, processing final rewards distribution
 * @dev Can only be called by an account with GOVERNANCE_ROLE
 * @param projectId The unique identifier of the project to finalize staking for
 * @param isCompleted Boolean indicating whether the project was completed successfully
 * @custom:revert ProjectDoesNotExist If the specified project does not exist
 */
function finalizeProjectStaking(uint256 projectId, bool isCompleted) external onlyRole(GOVERNANCE_ROLE) {
    if (!projectsContract.projectExists(projectId)) {
        revert ProjectDoesNotExist(projectId);
    }
    // Process final rewards distribution
    address[] memory stakers = getActiveStakers();
    for (uint256 i = 0; i < stakers.length; i++) {
        StakingPosition storage position = _stakingPositions[stakers[i]][projectId];
        if (position.amount > 0) {
            _claimRewards(stakers[i], projectId);
        }
    }
    // Update project status
    if (isCompleted) {
        emit ProjectStakingCompleted(projectId, block.timestamp);
    } else {
        emit ProjectStakingCancelled(projectId, block.timestamp);
    }
    
    // AI integration - update AI engine about project completion
    if (aiEnhancedStakingEnabled && address(aiEngine) != address(0) && _projectUsesAI[projectId]) {
        try aiEngine.updateNeuralWeight(
            address(uint160(projectId)), 
            isCompleted ? 100000 : 1, // High signal if completed, low if cancelled
            50 // Strong impact
        ) {
            // Successfully updated neural weight for project completion state
        } catch {
            // Failed but continue
        }
    }
}

/**
 * @notice Claim rewards for a single project.
 */
function claimRewards(uint256 projectId) external nonReentrant {
    _claimRewards(msg.sender, projectId);
}

/**
 * @dev Splits off 5% of the reward to validator pool.
 */
function _distributeValidatorRewards(uint256 rewardAmount) internal {
    uint256 validatorShare = (rewardAmount * 5) / 100;
    if (validatorShare > 0) {
        validatorRewardPool += validatorShare;
        emit ValidatorRewardsAccumulated(validatorShare, validatorRewardPool);
    }
}

/**
     * @dev Apply the standard penalty distribution for early unstake events.
     */
    function _handlePenalty(address user, uint256 projectId, uint256 penaltyAmount) internal {
        uint256 burnAmount         = (penaltyAmount * 40) / 100; // 40%
        uint256 redistributeAmount = (penaltyAmount * 40) / 100; // 40%
        uint256 liquidityAmount    = penaltyAmount - burnAmount - redistributeAmount;

        bool success = stakingToken.transfer(BURN_ADDRESS, burnAmount);
        if (!success) {
            revert TransferFailed(address(stakingToken), address(this), BURN_ADDRESS, burnAmount);
        }

        success = stakingToken.transfer(address(rewardDistributor), redistributeAmount);
        if (!success) {
            revert TransferFailed(address(stakingToken), address(this), address(rewardDistributor), redistributeAmount);
        }

        success = stakingToken.transfer(liquidityPool, liquidityAmount);
        if (!success) {
            revert TransferFailed(address(stakingToken), address(this), liquidityPool, liquidityAmount);
        }

        PenaltyEvent memory penEvent = PenaltyEvent({
            projectId:     projectId,
            timestamp:     block.timestamp,
            totalPenalty:  penaltyAmount,
            redistributed: redistributeAmount,
            burned:        burnAmount,
            toLiquidity:   liquidityAmount
        });

        _penaltyHistory[user].push(penEvent);

        emit PenaltyApplied(
            user,
            projectId,
            penaltyAmount,
            burnAmount,
            redistributeAmount,
            liquidityAmount
        );
        
        // AI integration - track penalty events for neural learning
        if (aiEnhancedStakingEnabled && address(aiEngine) != address(0) && _userOptedForAI[user]) {
            // Update neural weight to reflect penalty event
            try aiEngine.updateNeuralWeight(
                user,
                penaltyAmount, // Use penalty amount as a negative signal
                30 // Higher impact for penalty events
            ) {
                // Successfully updated neural weight for penalty
            } catch {
                // Failed but continue
            }
        }
    }

    /**
     * @dev Removes an address from the `_activeStakers` array in O(1) time.
     */
    function _removeInactiveStaker(address staker) internal {
        uint256 length = _activeStakers.length;
        for (uint256 i = 0; i < length; i++) {
            if (_activeStakers[i] == staker) {
                _activeStakers[i] = _activeStakers[length - 1];
                _activeStakers.pop();
                return;
            }
        }
    }

    /**
     * @notice Calculate pending rewards for a user
     * @param user Address of the user
     * @return totalRewards Total pending rewards
     */
    function calculateRewards(address user) external view returns (uint256 totalRewards) {
        uint256 userStake = _stakingBalance[user];
        if (userStake == 0) return 0;

        // Get total rewards across all positions
        uint256 projectCount = projectsContract.getProjectCount();
        for (uint256 i = 1; i <= projectCount; i++) {
            if (_stakingPositions[user][i].amount > 0) {
                totalRewards += calculateRewards(user, i);
            }
        }
        
        return totalRewards;
    }

    /**
     * @notice Get the list of active stakers
     */
    function getActiveStakers() public view returns (address[] memory) {
        return _activeStakers;
    }

    // -------------------------------------------
    //   Validator Operations
    // -------------------------------------------

    /**
     * @notice Called by a user to explicitly become a validator if their stake is sufficient.
     */
    function becomeValidator() external nonReentrant whenNotPaused {
        if (_validators[msg.sender]) {
            revert AlreadyValidator(msg.sender);
        }
        if (_stakingBalance[msg.sender] < validatorThreshold) {
            revert InvalidParameter("validatorThreshold", _stakingBalance[msg.sender]);
        }
        _validators[msg.sender] = true;
        _validatorCommission[msg.sender] = 500; // Default 5% commission in basis points
        emit ValidatorAdded(msg.sender, block.timestamp);
        
        // AI integration - update neural score for new validators
        if (aiEnhancedStakingEnabled && address(aiEngine) != address(0) && _userOptedForAI[msg.sender]) {
            // Update user's neural score with a validator bonus
            uint256 oldScore = _userNeuralScore[msg.sender];
            uint256 newScore = oldScore + 20; // Validator bonus
            if (newScore > 100) newScore = 100; // Cap at max score
            
            _userNeuralScore[msg.sender] = newScore;
            emit UserNeuralScoreUpdated(msg.sender, oldScore, newScore);
            
            // Update neural weight in AI engine
            try aiEngine.updateNeuralWeight(
                msg.sender,
                _stakingBalance[msg.sender] * 2, // Double impact for validators
                15 // Medium smoothing factor
            ) {
                // Successfully updated neural weight
            } catch {
                // Failed but continue
            }
        }
    }

    /**
     * @notice Claim the portion of validatorRewardPool allocated to each validator
     */
    function claimValidatorRewards() external nonReentrant {
        if (!_validators[msg.sender]) {
            revert NotValidator(msg.sender);
        }
        
        uint256 validatorCount = 0;
        for (uint256 i = 0; i < _activeStakers.length; i++) {
            if (_validators[_activeStakers[i]]) {
                validatorCount++;
            }
        }
        
        if (validatorCount == 0) {
            return; // no distribution possible
        }
        
        uint256 rewardPerValidator = validatorRewardPool / validatorCount;
        validatorRewardPool = 0;
        bool success = rewardDistributor.distributeReward(msg.sender, rewardPerValidator);
        if (!success) {
            revert DistributionFailed(rewardPerValidator);
        }
        
        // AI integration - track validator rewards for neural learning
        if (aiEnhancedStakingEnabled && address(aiEngine) != address(0) && _userOptedForAI[msg.sender]) {
            try aiEngine.updateNeuralWeight(
                msg.sender,
                rewardPerValidator, // Use reward amount as positive signal
                10 // Smoother impact for recurring rewards
            ) {
                // Successfully updated neural weight
            } catch {
                // Failed but continue
            }
        }
        
        emit ValidatorRewardsDistributed(msg.sender, rewardPerValidator);
    }

    /**
     * @notice Update your commission rate (max 20%).
     */
    function updateValidatorCommission(uint256 newCommissionRate) external {
        if (!_validators[msg.sender]) {
            revert NotValidator(msg.sender);
        }
        if (newCommissionRate > 2000) { // 2000 => 20%
            revert RateTooHigh(newCommissionRate, 2000);
        }
        _validatorCommission[msg.sender] = newCommissionRate;
        emit ValidatorCommissionUpdated(msg.sender, newCommissionRate);
    }

    // -------------------------------------------
    //   Governance Operations
    // -------------------------------------------

    function voteOnProposal(uint256 proposalId, bool support) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        if (_governanceViolators[msg.sender]) {
            revert GovernanceViolation(msg.sender);
        }
        uint256 votingPower = _governanceVotes[msg.sender];
        if (votingPower == 0) {
            revert InvalidParameter("votingPower", votingPower);
        }
        governanceContract.recordVote(proposalId, msg.sender, votingPower, support);
        
        // AI integration - track governance participation
        if (aiEnhancedStakingEnabled && address(aiEngine) != address(0) && _userOptedForAI[msg.sender]) {
            // Update user's neural score with a governance participation bonus
            uint256 oldScore = _userNeuralScore[msg.sender];
            uint256 newScore = oldScore < 95 ? oldScore + 5 : 100; // Small governance bonus capped at 100
            
            _userNeuralScore[msg.sender] = newScore;
            emit UserNeuralScoreUpdated(msg.sender, oldScore, newScore);
        }
        
        emit ProposalVoted(proposalId, msg.sender, votingPower, support);
    }

    function createProposal(
        string calldata description,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[]   calldata calldatas
    )
        external
        nonReentrant
        whenNotPaused
    {
        if (_governanceViolators[msg.sender]) {
            revert GovernanceViolation(msg.sender);
        }
        uint256 votingPower = _governanceVotes[msg.sender];
        if (votingPower < GOVERNANCE_THRESHOLD) {
            revert InvalidParameter("votingPower", votingPower);
        }
        proposalNonce++;
        uint256 proposalId = governanceContract.createProposal(
            proposalNonce,
            msg.sender,
            description,
            targets,
            values,
            calldatas
        );
        
        // AI integration - track proposal creation
        if (aiEnhancedStakingEnabled && address(aiEngine) != address(0) && _userOptedForAI[msg.sender]) {
            // Update user's neural score with a proposal creation bonus
            uint256 oldScore = _userNeuralScore[msg.sender];
            uint256 newScore = oldScore < 90 ? oldScore + 10 : 100; // Larger bonus for creating proposals
            
            _userNeuralScore[msg.sender] = newScore;
            emit UserNeuralScoreUpdated(msg.sender, oldScore, newScore);
            
            // Update neural weight in AI engine
            try aiEngine.updateNeuralWeight(
                msg.sender,
                votingPower * 2, // Double impact for proposal creators
                15 // Medium smoothing factor
            ) {
                // Successfully updated neural weight
            } catch {
                // Failed but continue
            }
        }
        
        emit GovernanceProposalCreated(proposalId, msg.sender, description);
    }

    function markGovernanceViolator(address violator) external onlyRole(GOVERNANCE_ROLE) {
        _governanceViolators[violator] = true;
        _governanceVotes[violator]     = 0;
        
        // AI integration - penalize violators in neural scoring
        if (aiEnhancedStakingEnabled && address(aiEngine) != address(0) && _userOptedForAI[violator]) {
            // Reset neural score for governance violators
            uint256 oldScore = _userNeuralScore[violator];
            _userNeuralScore[violator] = 0;
            emit UserNeuralScoreUpdated(violator, oldScore, 0);
            
            // Update neural weight in AI engine with strongly negative signal
            try aiEngine.updateNeuralWeight(
                violator,
                1, // Minimal weight
                80 // High impact smoothing
            ) {
                // Successfully updated neural weight
            } catch {
                // Failed but continue
            }
        }
        
        emit GovernanceViolatorMarked(violator, block.timestamp);
    }

    /**
     * @notice Slashes a user's governance voting rights as penalty for governance violations
     * @param user Address of the user whose governance voting rights will be slashed
     * @return The amount of voting power that was slashed
     */
    function slashGovernanceVote(address user) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
        returns (uint256) 
    {
        if (_governanceViolators[user]) {
            return 0; // Already a violator
        }
        
        uint256 slashedAmount = _governanceVotes[user];
        if (slashedAmount == 0) {
            return 0; // No voting power to slash
        }
        
        // Mark as violator and remove voting power
        _governanceViolators[user] = true;
        _governanceVotes[user] = 0;
        
        // AI integration - penalize slashed users in neural scoring
        if (aiEnhancedStakingEnabled && address(aiEngine) != address(0) && _userOptedForAI[user]) {
            // Significantly reduce neural score for slashed users
            uint256 oldScore = _userNeuralScore[user];
            uint256 newScore = oldScore > 50 ? oldScore - 50 : 0; // Significant penalty
            
            _userNeuralScore[user] = newScore;
            emit UserNeuralScoreUpdated(user, oldScore, newScore);
            
            // Update neural weight in AI engine
            try aiEngine.updateNeuralWeight(
                user,
                slashedAmount / 10, // Reduced weight
                50 // High impact smoothing
            ) {
                // Successfully updated neural weight
            } catch {
                // Failed but continue
            }
        }
        
        emit GovernanceViolatorMarked(user, block.timestamp);
        
        return slashedAmount;
    }

    /**
     * @notice Applies halving to reward rates, reducing them according to the protocol's emission schedule
     * @dev Can only be called by governance or admin roles
     * @return The new halving epoch number
     */
    function applyHalving() 
        external 
        onlyRole(GOVERNANCE_ROLE) 
        returns (uint256) 
    {
        // Store old values for event emission
        uint256 oldBaseAPR = dynamicBaseAPR;
        uint256 oldBoostedAPR = dynamicBoostedAPR;
        
        // Apply the halving (reducing both APRs by 50%)
        dynamicBaseAPR = dynamicBaseAPR / 2;
        dynamicBoostedAPR = dynamicBoostedAPR / 2;
        
        // Ensure minimum values
        if (dynamicBaseAPR < 1) dynamicBaseAPR = 1;
        if (dynamicBoostedAPR < 2) dynamicBoostedAPR = 2;
        
        // Update halving state
        halvingEpoch++;
        lastHalvingTime = block.timestamp;
        
        // AI integration - trigger rebalance after halving
        if (aiEnhancedStakingEnabled && address(aiEngine) != address(0) && !emergencyAIBreakerTriggered) {
            try aiEngine.triggerAdaptiveRebalance() {
                // Successfully triggered rebalance after halving
            } catch {
                // Failed but continue
            }
        }
        
        emit HalvingApplied(
            halvingEpoch,
            oldBaseAPR,
            dynamicBaseAPR,
            oldBoostedAPR,
            dynamicBoostedAPR
        );
        
        return halvingEpoch;
    }

    // -------------------------------------------
    //   Administrative & Emergency
    // -------------------------------------------

    /**
     * @notice Update the staking tiers in bulk. 
     * @dev This re-initializes the _tiers array. Ensure sorted ascending durations for best logic.
     */
    function updateTiers(
        uint256[] calldata minDurations,
        uint256[] calldata multipliers,
        bool[]    calldata votingRights
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (
            minDurations.length != multipliers.length ||
            minDurations.length != votingRights.length
        ) {
            revert InvalidTierConfiguration();
        }
        // Clear existing
        delete _tiers;
        // Rebuild with new
        for (uint256 i = 0; i < minDurations.length; i++) {
            if (minDurations[i] < MIN_STAKING_DURATION) {
                revert InsufficientStakingDuration(MIN_STAKING_DURATION, minDurations[i]);
            }
            _tiers.push(StakingTier(
                minDurations[i],
                multipliers[i],
                votingRights[i]
            ));
        }
        
        // AI integration - update AI engine after tier changes
        if (aiEnhancedStakingEnabled && address(aiEngine) != address(0) && !emergencyAIBreakerTriggered) {
            // Signal a structural change in the staking system
            try aiEngine.recalculateDiversityIndex() {
                // Successfully recalculated diversity after tier change
            } catch {
                // Failed but continue
            }
        }
        
        emit TiersUpdated(minDurations, multipliers, votingRights);
    }

    function setLiquidityInjectionRate(uint256 newRate) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (newRate > MAX_LIQUIDITY_RATE) {
            revert RateTooHigh(newRate, MAX_LIQUIDITY_RATE);
        }
        liquidityInjectionRate = newRate;
        emit LiquidityInjectionRateUpdated(newRate);
    }

    function toggleAutoLiquidity(bool enabled) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        autoLiquidityEnabled = enabled;
        emit AutoLiquidityToggled(enabled);
    }

    function setValidatorThreshold(uint256 newThreshold) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (newThreshold == 0) {
            revert InvalidParameter("newThreshold", newThreshold);
        }
        validatorThreshold = newThreshold;
        emit ValidatorThresholdUpdated(newThreshold);
    }

    function setRewardDistributor(address newDistributor)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (newDistributor == address(0)) {
            revert InvalidAddress("newDistributor", newDistributor);
        }
        rewardDistributor = ITerraStakeRewardDistributor(newDistributor);
        emit RewardDistributorUpdated(newDistributor);
    }

    function setLiquidityPool(address newPool)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (newPool == address(0)) {
            revert InvalidAddress("newPool", newPool);
        }
        liquidityPool = newPool;
        emit LiquidityPoolUpdated(newPool);
    }

    function setSlashingContract(address newSlashingContract)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (newSlashingContract == address(0)) {
            revert InvalidAddress("newSlashingContract", newSlashingContract);
        }
        slashingContract = ITerraStakeSlashing(newSlashingContract);
        emit SlashingContractUpdated(newSlashingContract);
    }

    function setGovernanceQuorum(uint256 newQuorum)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        governanceQuorum = newQuorum;
        emit GovernanceQuorumUpdated(newQuorum);
    }

    function toggleDynamicRewards(bool enabled)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        dynamicRewardsEnabled = enabled;
        emit DynamicRewardsToggled(enabled);
    }

    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
        
        // AI integration - also pause AI features if main contract is paused
        if (aiEnhancedStakingEnabled && !emergencyAIBreakerTriggered) {
            emergencyAIBreakerTriggered = true;
            emit AICircuitBreakerTriggered(msg.sender, block.timestamp);
        }
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
        
        // Note: Don't automatically unpause AI features - this should be a separate decision
    }

    /**
     * @notice Recover ERC20 tokens accidentally sent here, except the staked ones.
     * @dev If `token == stakingToken`, we only allow the admin to withdraw the excess above `_totalStaked`.
     */
    function recoverERC20(address token)
        external
        onlyRole(EMERGENCY_ROLE)
        returns (bool)
    {
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (token == address(stakingToken)) {
            // We can only withdraw the portion that is not staked
            amount = amount - _totalStaked; 
        }
        bool success = IERC20(token).transfer(msg.sender, amount);
        if (!success) {
            revert TransferFailed(token, address(this), msg.sender, amount);
        }
        emit TokenRecovered(token, amount, msg.sender);
        return true;
    }

    // -------------------------------------------
    //   Slashing
    // -------------------------------------------

    function slash(address validator, uint256 amount) 
        external 
        onlyRole(SLASHER_ROLE)
        returns (bool) 
    {
        if (!_validators[validator]) {
            revert NotValidator(validator);
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        uint256 userBalance = _stakingBalance[validator];
        if (userBalance < amount) {
            amount = userBalance;
        }
        if (amount == 0) {
            return false;
        }
        // Update staker's total
        _stakingBalance[validator] -= amount;
        _totalStaked               -= amount;
        // Remove validator status if they drop below threshold
        if (_stakingBalance[validator] < validatorThreshold) {
            _validators[validator] = false;
            emit ValidatorStatusChanged(validator, false);
        }
        // The actual penalty distribution
        _handlePenalty(validator, 0, amount);
        
        // AI integration - severe penalty for slashed validators in neural scoring
        if (aiEnhancedStakingEnabled && address(aiEngine) != address(0) && _userOptedForAI[validator]) {
            // Reset neural score for slashed validators
            uint256 oldScore = _userNeuralScore[validator];
            _userNeuralScore[validator] = 0;
            emit UserNeuralScoreUpdated(validator, oldScore, 0);
            
            // Update neural weight in AI engine with strongly negative signal
            try aiEngine.updateNeuralWeight(
                validator,
                1, // Minimal weight
                90 // Very high impact
            ) {
                // Successfully updated neural weight
            } catch {
                // Failed but continue
            }
        }
        
        emit Slashed(validator, amount, block.timestamp);
        return true;
    }

    // -------------------------------------------
    //   View Functions
    // -------------------------------------------

    /**
     * @notice Finds the staking tier index that applies for a given duration.
     */
    function getApplicableTier(uint256 duration) public view returns (uint256) {
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

    function getUserStake(address user, uint256 projectId) external view returns (uint256) {
        return _stakingPositions[user][projectId].amount;
    }

    function getUserTotalStake(address user) external view returns (uint256) {
        return _stakingBalance[user];
    }

    function getUserPositions(address user) external view returns (StakingPosition[] memory positions) {
        // We gather from the project contract how many total projects exist
        // Then filter the user's staked positions
        uint256 projectCount = projectsContract.getProjectCount();
        uint256 count        = 0;
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

    function getPenaltyHistory(address user) external view returns (PenaltyEvent[] memory) {
        return _penaltyHistory[user];
    }

    function isValidator(address user) external view returns (bool) {
        return _validators[user];
    }

    function getValidatorCommission(address validator) external view returns (uint256) {
        return _validatorCommission[validator];
    }

    function isGovernanceViolator(address user) external view returns (bool) {
        return _governanceViolators[user];
    }

    function getGovernanceVotes(address user) external view returns (uint256) {
        return _governanceVotes[user];
    }

    function getTotalStaked() external view returns (uint256) {
        return _totalStaked;
    }

    /**
     * @notice Get the total amount of staked tokens
     * @return Total staked tokens
     */
    function totalStakedTokens() external view returns (uint256) {
        return _totalStaked;
    }

    function getValidatorRewardPool() external view returns (uint256) {
        return validatorRewardPool;
    }

    function getAllTiers() external view returns (StakingTier[] memory) {
        return _tiers;
    }

    /**
     * @notice Returns the top stakers up to `limit`.
     * @dev Uses an optimized partial selection sort algorithm that only sorts the top 'limit' elements
     *      for better performance O(n*limit) instead of O(n²).
     */
    function getTopStakers(uint256 limit)
        external
        view
        returns (address[] memory stakers, uint256[] memory amounts)
    {
        uint256 stakerCount = _activeStakers.length;
    
        // Cap the limit at the active stakers count
        if (limit > stakerCount) {
            limit = stakerCount;
        }
    
        if (limit == 0) {
            return (new address[](0), new uint256[](0));
        }
        // Initialize result arrays
        stakers = new address[](limit);
        amounts = new uint256[](limit);
    
        // Work with temporary arrays for selection process
        address[] memory tempStakers = new address[](stakerCount);
        uint256[] memory tempAmounts = new uint256[](stakerCount);
        // Populate temporary arrays
        for (uint256 i = 0; i < stakerCount; i++) {
            tempStakers[i] = _activeStakers[i];
            tempAmounts[i] = _stakingBalance[_activeStakers[i]];
        }
    
        // Find top 'limit' elements using partial selection sort
        // This is more efficient because we only sort what we need
        for (uint256 i = 0; i < limit; i++) {
            uint256 maxIndex = i;
        
            // Find the maximum value in the remaining unsorted portion
            for (uint256 j = i + 1; j < stakerCount; j++) {
                if (tempAmounts[j] > tempAmounts[maxIndex]) {
                    maxIndex = j;
                }
            }
        
            // If we found a new maximum, swap it to the current position
            if (maxIndex != i) {
                // Swap amounts
                uint256 tempAmount = tempAmounts[i];
                tempAmounts[i] = tempAmounts[maxIndex];
                tempAmounts[maxIndex] = tempAmount;
            
                // Swap addresses
                address tempAddr = tempStakers[i];
                tempStakers[i] = tempStakers[maxIndex];
                tempStakers[maxIndex] = tempAddr;
            }
            // Add to result arrays
            stakers[i] = tempStakers[i];
            amounts[i] = tempAmounts[i];
        }
    
        return (stakers, amounts);
    }

    /**
     * @notice Returns the top stakers with AI enhancement information
     * @param limit Maximum number of stakers to return
     * @return stakers Array of staker addresses
     * @return amounts Array of staked amounts
     * @return aiScores Array of AI neural scores (0 if not opted in)
     */
    function getTopAIStakers(uint256 limit)
        external
        view
        returns (address[] memory stakers, uint256[] memory amounts, uint256[] memory aiScores)
    {
        if (!aiEnhancedStakingEnabled || address(aiEngine) == address(0)) {
            (stakers, amounts) = this.getTopStakers(limit);
            aiScores = new uint256[](stakers.length);
            return (stakers, amounts, aiScores);
        }
        
        (stakers, amounts) = this.getTopStakers(limit);
        aiScores = new uint256[](stakers.length);
        
        // Fill in AI scores for each staker
        for (uint256 i = 0; i < stakers.length; i++) {
            if (_userOptedForAI[stakers[i]]) {
                aiScores[i] = _userNeuralScore[stakers[i]];
            } else {
                aiScores[i] = 0;
            }
        }
        
        return (stakers, amounts, aiScores);
    }

    /**
     * @notice Get the current count of validators
     * @return Number of validators
     */
    function getValidatorCount() external view returns (uint256) {
        uint256 count = 0;
        // Count the validators
        for (uint256 i = 0; i < _activeStakers.length; i++) {
            if (_validators[_activeStakers[i]]) {
                count++;
            }
        }
        return count;
    }
   
    /**
     * @notice Basic version info.
     */
    function version() external pure returns (string memory) {
        return "1.0.0-improved-ai";
    }

    /**
     * @notice Apply halving to reward rates when the period has elapsed.
     * @dev Can be called by anyone, but effect happens at most once per halvingPeriod.
     */
    function applyHalvingIfNeeded() external {
        uint256 timeElapsed = block.timestamp - lastHalvingTime;
        if (timeElapsed < halvingPeriod) {
            return;
        }
        uint256 oldBaseAPR = dynamicBaseAPR;
        uint256 oldBoostedAPR = dynamicBoostedAPR;
        // Apply halving: divide rates by 2
        dynamicBaseAPR = dynamicBaseAPR / 2;
        dynamicBoostedAPR = dynamicBoostedAPR / 2;
        
        // Ensure minimum values
        if (dynamicBaseAPR < 1) {
            dynamicBaseAPR = 1;
        }
        if (dynamicBoostedAPR < 2) {
            dynamicBoostedAPR = 2;
        }
        lastHalvingTime = block.timestamp;
        halvingEpoch++;
        
        // AI integration - trigger rebalance after halving
        if (aiEnhancedStakingEnabled && address(aiEngine) != address(0) && !emergencyAIBreakerTriggered) {
            try aiEngine.triggerAdaptiveRebalance() {
                // Successfully triggered rebalance after halving
            } catch {
                // Failed but continue
            }
        }
        
        emit HalvingApplied(
            halvingEpoch,
            oldBaseAPR,
            dynamicBaseAPR,
            oldBoostedAPR,
            dynamicBoostedAPR
        );
    }

    /**
     * @notice Adjust reward rates based on a dynamic formula (if enabled).
     * @dev This can be called by any address to update rates.
     */
    function adjustRewardRates() external {
        if (!dynamicRewardsEnabled) {
            return;
        }
        // Can only adjust once per day
        if (block.timestamp - lastRewardAdjustmentTime < 1 days) {
            return;
        }
        uint256 oldBaseAPR = dynamicBaseAPR;
        
        // Example dynamic adjustment: base APR adjusts based on total staking
        if (_totalStaked < LOW_STAKING_THRESHOLD / 10) {
            // Extremely low staking, boost rates
            dynamicBaseAPR = 15;
            dynamicBoostedAPR = 30;
        } else if (_totalStaked < LOW_STAKING_THRESHOLD / 2) {
            // Low staking, moderate boost
            dynamicBaseAPR = 12;
            dynamicBoostedAPR = 24;
        } else if (_totalStaked < LOW_STAKING_THRESHOLD) {
            // Approaching threshold, smaller boost
            dynamicBaseAPR = BASE_APR;
            dynamicBoostedAPR = BOOSTED_APR;
        } else {
            // Above threshold, use base rates
            dynamicBaseAPR = 8;
            dynamicBoostedAPR = 16;
        }
        lastRewardAdjustmentTime = block.timestamp;
        
        // AI integration - check if dynamic APR changes should trigger rebalance
        if (aiEnhancedStakingEnabled && address(aiEngine) != address(0) && !emergencyAIBreakerTriggered) {
            // Calculate APR change percentage
            uint256 aprChange;
            if (oldBaseAPR > dynamicBaseAPR) {
                aprChange = ((oldBaseAPR - dynamicBaseAPR) * 100) / oldBaseAPR;
            } else {
                aprChange = ((dynamicBaseAPR - oldBaseAPR) * 100) / oldBaseAPR;
            }
            
            // If APR changed significantly, trigger rebalance
            if (aprChange >= 20) { // 20% change threshold
                try aiEngine.triggerAdaptiveRebalance() {
                    // Successfully triggered rebalance due to APR change
                } catch {
                    // Failed but continue
                }
            }
        }
        
        emit RewardRateAdjusted(oldBaseAPR, dynamicBaseAPR);
    }

    /**
     * @notice Get all AI-enabled projects
     * @return projectIds Array of AI-enabled project IDs
     * @return multipliers Array of corresponding AI multipliers
     */
    function getAIEnabledProjects() external view returns (uint256[] memory projectIds, uint256[] memory multipliers) {
        if (!aiEnhancedStakingEnabled || address(aiEngine) == address(0)) {
            return (new uint256[](0), new uint256[](0));
        }
        
        uint256 projectCount = projectsContract.getProjectCount();
        uint256 aiProjectCount = 0;
        
        // First count AI-enabled projects
        for (uint256 i = 1; i <= projectCount; i++) {
            if (_projectUsesAI[i]) {
                aiProjectCount++;
            }
        }
        
        projectIds = new uint256[](aiProjectCount);
        multipliers = new uint256[](aiProjectCount);
        
        uint256 index = 0;
        for (uint256 i = 1; i <= projectCount; i++) {
            if (_projectUsesAI[i]) {
                projectIds[index] = i;
                multipliers[index] = _projectAIMultiplier[i];
                index++;
            }
        }
        
        return (projectIds, multipliers);
    }

    /**
     * @notice Get users who have opted into AI enhancements
     * @param limit Maximum number of users to return
     * @return users Array of user addresses
     * @return scores Array of corresponding neural scores
     */
    function getAIUsers(uint256 limit) external view returns (address[] memory users, uint256[] memory scores) {
        if (!aiEnhancedStakingEnabled || address(aiEngine) == address(0)) {
            return (new address[](0), new uint256[](0));
        }
        
        address[] memory stakers = getActiveStakers();
        uint256 aiUserCount = 0;
        
        // First count AI users
        for (uint256 i = 0; i < stakers.length; i++) {
            if (_userOptedForAI[stakers[i]] && _userNeuralScore[stakers[i]] > 0) {
                aiUserCount++;
            }
        }
        
        // Use the smaller value between limit and aiUserCount
        uint256 resultSize = aiUserCount < limit ? aiUserCount : limit;
        
        users = new address[](resultSize);
        scores = new uint256[](resultSize);
        
        // Fill arrays with AI users
        uint256 index = 0;
        for (uint256 i = 0; i < stakers.length && index < resultSize; i++) {
            if (_userOptedForAI[stakers[i]] && _userNeuralScore[stakers[i]] > 0) {
                users[index] = stakers[i];
                scores[index] = _userNeuralScore[stakers[i]];
                index++;
            }
        }
        
        return (users, scores);
    }

    /**
     * @notice Check if AI engine is properly connected and operational
     * @return status Connection status details
     */
    function checkAIEngineStatus() external view returns (
        bool isConfigured,
        bool isEnabled,
        bool inEmergencyMode,
        uint256 lastUpdate
    ) {
        isConfigured = address(aiEngine) != address(0);
        isEnabled = aiEnhancedStakingEnabled;
        inEmergencyMode = emergencyAIBreakerTriggered;
        lastUpdate = lastAIGlobalUpdate;
        
        return (isConfigured, isEnabled, inEmergencyMode, lastUpdate);
    }

    /**
     * @notice Get AI enhancement statistics
     * @return aiUserCount Number of users opted in to AI
     * @return aiProjectCount Number of AI-enabled projects
     * @return averageNeuralScore Average neural score across all users
     */
    function getAIStatistics() external view returns (
        uint256 aiUserCount,
        uint256 aiProjectCount,
        uint256 averageNeuralScore
    ) {
        if (!aiEnhancedStakingEnabled || address(aiEngine) == address(0)) {
            return (0, 0, 0);
        }
        
        // Count AI projects
        uint256 projectCount = projectsContract.getProjectCount();
        for (uint256 i = 1; i <= projectCount; i++) {
            if (_projectUsesAI[i]) {
                aiProjectCount++;
            }
        }
        
        // Count AI users and calculate average score
        address[] memory stakers = getActiveStakers();
        uint256 totalScore = 0;
        
        for (uint256 i = 0; i < stakers.length; i++) {
            if (_userOptedForAI[stakers[i]]) {
                aiUserCount++;
                totalScore += _userNeuralScore[stakers[i]];
            }
        }
        
        // Calculate average (avoid division by zero)
        averageNeuralScore = aiUserCount > 0 ? totalScore / aiUserCount : 0;
        
        return (aiUserCount, aiProjectCount, averageNeuralScore);
    }

    /**
     * @notice Force an update of a user's neural score
     * @param user Address of the user
     * @dev Only callable by AI operator
     */
    function forceUpdateUserNeuralScore(address user) external onlyRole(AI_OPERATOR_ROLE) {
        if (!aiEnhancedStakingEnabled || address(aiEngine) == address(0) || emergencyAIBreakerTriggered || !_userOptedForAI[user]) {
            return;
        }
        
        // Calculate a neural score based on user's staking behavior
        uint256 oldScore = _userNeuralScore[user];
        uint256 totalStaked = _stakingBalance[user];
        uint256 longestStake = 0;
        uint256 diversityFactor = 0;
        uint256 positionCount = 0;
        
        // Check each project to find active positions
        uint256 projectCount = projectsContract.getProjectCount();
        for (uint256 j = 1; j <= projectCount; j++) {
            StakingPosition storage position = _stakingPositions[user][j];
            if (position.amount > 0) {
                positionCount++;
                if (position.duration > longestStake) {
                    longestStake = position.duration;
                }
            }
        }
        
        // Add diversity factor for each unique project (with diminishing returns)
        diversityFactor = positionCount * 5;
        
        // Combine factors for neural score - weighting them appropriately
        uint256 stakedWeight = (totalStaked * 50) / (validatorThreshold); // Cap at 50
        if (stakedWeight > 50) stakedWeight = 50;
        
        uint256 durationWeight = (longestStake * 30) / (365 days); // Cap at 30
        if (durationWeight > 30) durationWeight = 30;
        
        // Cap diversity factor at 20
        if (diversityFactor > 20) diversityFactor = 20;
        
        // Add validator bonus
        uint256 validatorBonus = _validators[user] ? 10 : 0;
        
        // Cap total at 100
        uint256 newScore = stakedWeight + durationWeight + diversityFactor + validatorBonus;
        if (newScore > 100) newScore = 100;
        
        _userNeuralScore[user] = newScore;
        _userLastNeuralUpdate[user] = block.timestamp;
        
        emit UserNeuralScoreUpdated(user, oldScore, newScore);
        
        // Update neural weight in AI engine
        try aiEngine.updateNeuralWeight(
            user,
            totalStaked, // Use staked amount as signal
            20 // Medium smoothing factor
        ) {
            // Successfully updated neural weight
        } catch {
            // Failed but continue
        }
    }
}
