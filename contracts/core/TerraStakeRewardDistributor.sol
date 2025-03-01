// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

import "../interfaces/ITerraStakeRewardDistributor.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";
import "../interfaces/ITerraStakeSlashing.sol";

/**
 * @title TerraStakeRewardDistributor
 * @author TerraStake Protocol Team
 * @notice Handles staking rewards, liquidity injection, APR management, and reward halving
 * @dev Integrates with Chainlink VRF for randomized halving and Uniswap for liquidity operations
 */
contract TerraStakeRewardDistributor is 
    Initializable,
    AccessControlEnumerableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable,
    VRFConsumerBaseV2,
    ITerraStakeRewardDistributor 
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    
    // -------------------------------------------
    // 🔹 Constants
    // -------------------------------------------
    bytes32 public constant STAKING_CONTRACT_ROLE = keccak256("STAKING_CONTRACT_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant MULTISIG_ROLE = keccak256("MULTISIG_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    uint256 public constant MAX_LIQUIDITY_INJECTION_RATE = 10; // 10%
    uint256 public constant MAX_HALVING_REDUCTION_RATE = 90;   // 90%
    uint256 public constant TWO_YEARS_IN_SECONDS = 730 days;
    uint256 public constant MIN_REWARD_RATE = 10;              // 10% (floor)
    uint256 public constant PARAMETER_TIMELOCK = 2 days;       // Timelock for parameter changes

    // -------------------------------------------
    // 🔹 Errors
    // -------------------------------------------
    error Unauthorized();
    error InvalidAddress(string name);
    error InvalidParameter(string name);
    error TransferFailed(address token, address from, address to, uint256 amount);
    error HalvingAlreadyRequested();
    error RandomizationFailed();
    error LiquidityInjectionFailed(uint256 amount);
    error TimelockNotExpired(uint256 current, uint256 required);
    error NoUpdatePending(string paramName);
    error CircuitBreakerActive();
    error CannotRecoverRewardToken();
    error MaxDistributionExceeded();

    // -------------------------------------------
    // 🔹 State Variables
    // -------------------------------------------
    // Core contracts and addresses
    IERC20Upgradeable public rewardToken;
    ITerraStakeStaking public stakingContract;
    ISwapRouter public uniswapRouter;
    ITerraStakeLiquidityGuard public liquidityGuard;
    ITerraStakeSlashing public slashingContract;
    VRFCoordinatorV2Interface public vrfCoordinator;
    
    address public rewardSource;
    address public liquidityPool;
    
    // Reward parameters
    uint256 public totalDistributed;
    uint256 public halvingEpoch;
    uint256 public lastHalvingTime;
    uint256 public halvingReductionRate;
    uint256 public liquidityInjectionRate;
    uint256 public maxDailyDistribution;
    uint256 public dailyDistributed;
    uint256 public lastDistributionReset;
    
    // Feature flags
    bool public autoBuybackEnabled;
    bool public halvingMechanismPaused;
    bool public distributionPaused;
    bool public pendingRandomnessRequest;
    
    // Chainlink VRF variables
    bytes32 public keyHash;
    uint64 public subscriptionId;
    uint32 public callbackGasLimit;
    mapping(bytes32 => bool) private vrfRequests;
    
    // Penalty redistribution
    mapping(address => uint256) public pendingPenalties;
    uint256 public totalPendingPenalties;
    uint256 public totalStakedCache;
    uint256 public lastStakeUpdateTime;

    // Timelocked parameter updates
    struct PendingUpdate {
        uint256 value;
        uint256 effectiveTime;
        bool isAddress;
        address addrValue;
    }
    mapping(bytes32 => PendingUpdate) public pendingParameterUpdates;

    // -------------------------------------------
    // 🔹 Events
    // -------------------------------------------
    event RewardDistributed(address indexed user, uint256 amount);
    event HalvingApplied(uint256 newRewardRate, uint256 halvingEpoch);
    event LiquidityInjected(uint256 amount);
    event PenaltyReDistributed(address indexed from, uint256 amount);
    event HalvingRequested(bytes32 requestId);
    event RandomnessReceived(bytes32 indexed requestId, uint256 randomness);
    event RewardParametersUpdated(string paramName, uint256 oldValue, uint256 newValue);
    event ContractUpdated(string contractName, address oldAddress, address newAddress);
    event FeatureToggled(string featureName, bool enabled);
    event EmergencyTokenRecovery(address token, uint256 amount, address recipient);
    event ParameterUpdateProposed(string paramName, uint256 value, uint256 effectiveTime);
    event AddressUpdateProposed(string paramName, address value, uint256 effectiveTime);
    event HalvingMechanismPaused(bool paused);
    event DistributionPaused(bool paused);
    event PenaltiesBatchDistributed(uint256 startIndex, uint256 endIndex, uint256 amount);
    event StakeTotalCacheUpdated(uint256 oldTotal, uint256 newTotal);
    event DailyDistributionLimitUpdated(uint256 oldLimit, uint256 newLimit);
    event DailyDistributionReset(uint256 timestamp);
    event EmergencyCircuitBreakerActivated(address activator, string reason);

    // -------------------------------------------
    // 🔹 Constructor & Initializer
    // -------------------------------------------
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _vrfCoordinator) VRFConsumerBaseV2(_vrfCoordinator) {
        _disableInitializers();
    }
    
    /**
     * @notice Initialize the reward distributor contract
     * @param _rewardToken Address of the reward token
     * @param _rewardSource Address of the reward source
     * @param _stakingContract Address of the staking contract
     * @param _uniswapRouter Address of the Uniswap router
     * @param _liquidityPool Address of the liquidity pool
     * @param _liquidityGuard Address of the liquidity guard
     * @param _slashingContract Address of the slashing contract
     * @param _vrfCoordinator Address of the VRF coordinator
     * @param _keyHash VRF key hash
     * @param _subscriptionId VRF subscription ID
     * @param _admin Initial admin address
     */
    function initialize(
        address _rewardToken,
        address _rewardSource,
        address _stakingContract,
        address _uniswapRouter,
        address _liquidityPool,
        address _liquidityGuard,
        address _slashingContract,
        address _vrfCoordinator,
        bytes32 _keyHash,
        uint64 _subscriptionId,
        address _admin
    ) external initializer {
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        if (_rewardToken == address(0)) revert InvalidAddress("rewardToken");
        if (_rewardSource == address(0)) revert InvalidAddress("rewardSource");
        if (_stakingContract == address(0)) revert InvalidAddress("stakingContract");
        if (_admin == address(0)) revert InvalidAddress("admin");
        
        rewardToken = IERC20Upgradeable(_rewardToken);
        rewardSource = _rewardSource;
        stakingContract = ITerraStakeStaking(_stakingContract);
        
        if (_uniswapRouter != address(0)) {
            uniswapRouter = ISwapRouter(_uniswapRouter);
        }
        
        if (_liquidityPool != address(0)) {
            liquidityPool = _liquidityPool;
        }
        
        if (_liquidityGuard != address(0)) {
            liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);
        }
        
        if (_slashingContract != address(0)) {
            slashingContract = ITerraStakeSlashing(_slashingContract);
        }
        
        vrfCoordinator = VRFCoordinatorV2Interface(_vrfCoordinator);
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;
        callbackGasLimit = 100000; // Default gas limit
        
        lastHalvingTime = block.timestamp;
        halvingReductionRate = 80; // Start at 80% of full rewards
        liquidityInjectionRate = 5; // Start with 5% injection rate
        autoBuybackEnabled = true; // Enable by default
        
        // Initialize daily distribution limits
        maxDailyDistribution = type(uint256).max; // Start with no limit
        lastDistributionReset = block.timestamp;
        
        // Initial stake cache update
        _updateStakeTotalCache();
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(GOVERNANCE_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
        _grantRole(STAKING_CONTRACT_ROLE, _stakingContract);
        _grantRole(MULTISIG_ROLE, _admin); // Initially set admin as multisig
        _grantRole(EMERGENCY_ROLE, _admin); // Initially set admin as emergency role
    }
    
    /**
     * @notice Authorizes contract upgrades
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
    
    // -------------------------------------------
    // 🔹 Core Reward Functions
    // -------------------------------------------
    
    /**
     * @notice Distribute reward to a user
     * @param user Address of the user
     * @param amount Reward amount before halving adjustment
     */
    function distributeReward(address user, uint256 amount) 
        external 
        override 
        onlyRole(STAKING_CONTRACT_ROLE) 
        nonReentrant 
    {
        if (user == address(0)) revert InvalidAddress("user");
        if (amount == 0) revert InvalidParameter("amount");
        if (distributionPaused) revert CircuitBreakerActive();
        
        // Check daily distribution limit
        _checkAndResetDailyLimit();
        
        // Check if halving should be applied
        _checkAndApplyHalving();
        
        // Apply current halving rate to reward amount
        uint256 adjustedAmount = (amount * halvingReductionRate) / 100;
        
        // Ensure we don't exceed daily limit
        if (dailyDistributed + adjustedAmount > maxDailyDistribution) revert MaxDistributionExceeded();
        dailyDistributed += adjustedAmount;
        
        // Transfer reward to the user
        rewardToken.safeTransferFrom(rewardSource, user, adjustedAmount);
        
        // Track total rewards distributed
        totalDistributed += adjustedAmount;
        
        // Handle liquidity injection if enabled and guard contract is set
        if (autoBuybackEnabled && address(liquidityGuard) != address(0)) {
            uint256 injectionAmount = (adjustedAmount * liquidityInjectionRate) / 100;
            try liquidityGuard.injectLiquidity(injectionAmount) {
                emit LiquidityInjected(injectionAmount);
            } catch {
                // Failed injection should not revert the reward
                emit LiquidityInjectionFailed(injectionAmount);
            }
        }
        
        emit RewardDistributed(user, adjustedAmount);
    }
    
    /**
     * @notice Redistribute penalties from slashed validators
     * @param from Address of the slashed validator
     * @param amount Amount of the penalty
     */
    function redistributePenalty(address from, uint256 amount) 
        external 
        override 
        nonReentrant 
    {
        // Only slashing contract can call this
        if (msg.sender != address(slashingContract)) revert Unauthorized();
        if (amount == 0) revert InvalidParameter("amount");
        
        // Add to pending penalties for redistribution
        pendingPenalties[from] += amount;
        totalPendingPenalties += amount;
        
        emit PenaltyReDistributed(from, amount);
    }
    
    /**
     * @notice Distribute accumulated penalties to active stakers in batches
     * @param startIndex Start index in the stakers array
     * @param endIndex End index in the stakers array (inclusive)
     */
    function batchDistributePenalties(uint256 startIndex, uint256 endIndex) 
        external 
        onlyRole(GOVERNANCE_ROLE)
        nonReentrant
    {
        if (totalPendingPenalties == 0) revert InvalidParameter("noPendingPenalties");
        
        // Get active stakers from staking contract
        address[] memory stakers = stakingContract.getActiveStakers();
        if (stakers.length == 0) return; // No stakers to distribute to
        
        // Validate indices
        if (endIndex >= stakers.length) {
            endIndex = stakers.length - 1;
        }
        if (startIndex > endIndex) revert InvalidParameter("invalidIndices");
        
        // Calculate batch proportions using cached total staked amount if recent
        if (block.timestamp > lastStakeUpdateTime + 1 days) {
            _updateStakeTotalCache();
        }
        
        if (totalStakedCache == 0) return; // No stake to calculate proportion
        
        // Calculate total staked for this batch
        uint256 batchStaked = 0;
        for (uint256 i = startIndex; i <= endIndex; i++) {
            batchStaked += stakingContract.getTotalStakedByUser(stakers[i]);
        }
        
        if (batchStaked == 0) return; // No stake in this batch
        
        // Calculate batch's share of penalties
        uint256 batchPenaltyShare = (totalPendingPenalties * batchStaked) / totalStakedCache;
        uint256 distributedInBatch = 0;
        
        // Distribute penalties for this batch
        for (uint256 i = startIndex; i <= endIndex; i++) {
            address staker = stakers[i];
            uint256 stakerAmount = stakingContract.getTotalStakedByUser(staker);
            
            if (stakerAmount > 0) {
                uint256 penaltyShare = (batchPenaltyShare * stakerAmount) / batchStaked;
                if (penaltyShare > 0) {
                    try rewardToken.safeTransfer(staker, penaltyShare) {
                        distributedInBatch += penaltyShare;
                    } catch {
                        // Failed transfer should not block other distributions
                        continue;
                    }
                }
            }
        }
        
        // Update total pending penalties
        if (distributedInBatch > 0) {
            totalPendingPenalties -= distributedInBatch;
        }
        
        emit PenaltiesBatchDistributed(startIndex, endIndex, distributedInBatch);
    }
    
    /**
     * @notice Update the cached total staked amount
     * @dev This reduces gas costs for batch operations by avoiding multiple calls
     */
    function _updateStakeTotalCache() internal {
        uint256 oldTotal = totalStakedCache;
        
        address[] memory stakers = stakingContract.getActiveStakers();
        uint256 newTotal = 0;
        
        for (uint256 i = 0; i < stakers.length; i++) {
            newTotal += stakingContract.getTotalStakedByUser(stakers[i]);
        }
        
        totalStakedCache = newTotal;
        lastStakeUpdateTime = block.timestamp;
        
        emit StakeTotalCacheUpdated(oldTotal, newTotal);
    }
    
    /**
     * @notice Force update of the stake total cache
     * @dev Can be called by governance to ensure accurate distributions
     */
    function updateStakeTotalCache() external onlyRole(GOVERNANCE_ROLE) {
        _updateStakeTotalCache();
    }
    
    /**
     * @notice Check and reset daily distribution limits
     */
    function _checkAndResetDailyLimit() internal {
        // Reset daily counter if a day has passed
        if (block.timestamp >= lastDistributionReset + 1 days) {
            dailyDistributed = 0;
            lastDistributionReset = block.timestamp;
            emit DailyDistributionReset(block.timestamp);
        }
    }
    
    // -------------------------------------------
    // 🔹 Halving Mechanism
    // -------------------------------------------
    
    /**
     * @notice Check if halving should be applied and apply it
     */
    function _checkAndApplyHalving() internal {
        if (halvingMechanismPaused) return;
        
        if (block.timestamp >= lastHalvingTime + TWO_YEARS_IN_SECONDS) {
            // If enough time has passed, apply standard halving
            _applyHalving();
        }
    }
    
    /**
     * @notice Apply halving to reward rate
     */
    function _applyHalving() internal {
        // Record new halving time
        lastHalvingTime = block.timestamp;
        halvingEpoch++;
        
        // Reduce the reward rate (but never below MIN_REWARD_RATE)
        uint256 newRate = (halvingReductionRate * MAX_HALVING_REDUCTION_RATE) / 100;
        halvingReductionRate = newRate < MIN_REWARD_RATE ? MIN_REWARD_RATE : newRate;
        
        emit HalvingApplied(halvingReductionRate, halvingEpoch);
    }
    
    /**
     * @notice Request randomness for halving from Chainlink VRF
     * @return requestId The VRF request ID
     */
    function requestRandomHalving() external onlyRole(GOVERNANCE_ROLE) returns (bytes32) {
        // Ensure we're not already processing a VRF request
        if (pendingRandomnessRequest) revert HalvingAlreadyRequested();
        
        // Set flag and request randomness
        pendingRandomnessRequest = true;
        
        bytes32 requestId = vrfCoordinator.requestRandomWords(
            keyHash,
            subscriptionId,
            3, // requestConfirmations
            callbackGasLimit,
            1  // numWords
        );
        
        vrfRequests[requestId] = true;
        emit HalvingRequested(requestId);
        
        return requestId;
    }
    
    /**
     * @notice Callback function used by VRF Coordinator
     * @param requestId ID of the request
     * @param randomWords Array of random results from VRF Coordinator
     */
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        bytes32 requestIdBytes = bytes32(requestId);
        
        if (!vrfRequests[requestIdBytes]) revert RandomizationFailed();
        
        // Apply randomized adjustment to halvingReductionRate (within bounds)
        uint256 oldRate = halvingReductionRate;
        
        // Use randomness to adjust halving rate within +/-5% of standard rate
        uint256 randomAdjustment = randomWords[0] % 11; // 0-10 range
        int256 adjustmentDirection = randomAdjustment >= 5 ? 1 : -1;
        uint256 adjustmentAmount = randomAdjustment % 6; // 0-5 range
        
        int256 newRateInt = int256(oldRate) + (adjustmentDirection * int256(adjustmentAmount));
        uint256 newRate = uint256(newRateInt < int256(MIN_REWARD_RATE) ? int256(MIN_REWARD_RATE) : newRateInt);
        
        halvingReductionRate = newRate;
        lastHalvingTime = block.timestamp;
        halvingEpoch++;
        
        // Clear request data
        delete vrfRequests[requestIdBytes];
        pendingRandomnessRequest = false;
        
        emit RandomnessReceived(requestIdBytes, randomWords[0]);
        emit HalvingApplied(halvingReductionRate, halvingEpoch);
    }
    
    /**
     * @notice Manually force a halving (emergency only)
     */
    function forceHalving() external onlyRole(MULTISIG_ROLE) {
        _applyHalving();
    }
    
    /**
     * @notice Pause or unpause the halving mechanism
     * @param paused Whether the halving mechanism should be paused
     */
    function pauseHalvingMechanism(bool paused) external onlyRole(MULTISIG_ROLE) {
        halvingMechanismPaused = paused;
        emit HalvingMechanismPaused(paused);
    }
    
    /**
     * @notice Pause or unpause reward distribution
     * @param paused Whether distribution should be paused
     */
    function pauseDistribution(bool paused) external onlyRole(MULTISIG_ROLE) {
        distributionPaused = paused;
        emit DistributionPaused(paused);
    }
    
    /**
     * @notice Emergency circuit breaker to pause all operations
     * @param reason Reason for activation
     */
    function activateEmergencyCircuitBreaker(string calldata reason) external onlyRole(EMERGENCY_ROLE) {
        distributionPaused = true;
        halvingMechanismPaused = true;
        emit EmergencyCircuitBreakerActivated(msg.sender, reason);
    }
    
    // -------------------------------------------
    // 🔹 Parameter Management
    // -------------------------------------------
    
    /**
     * @notice Propose update to the reward source address
     * @param newRewardSource New reward source address
     */
    function proposeRewardSource(address newRewardSource) external onlyRole(GOVERNANCE_ROLE) {
        if (newRewardSource == address(0)) revert InvalidAddress("newRewardSource");
        
        bytes32 updateKey = keccak256("rewardSource");
        pendingParameterUpdates[updateKey] = PendingUpdate({
            value: 0,
            effectiveTime: block.timestamp + PARAMETER_TIMELOCK,
            isAddress: true,
            addrValue: newRewardSource
        });
        
        emit AddressUpdateProposed("rewardSource", newRewardSource, block.timestamp + PARAMETER_TIMELOCK);
    }
    
    /**
     * @notice Execute proposed reward source update after timelock
     */
    function executeRewardSourceUpdate() external onlyRole(GOVERNANCE_ROLE) {
        bytes32 updateKey = keccak256("rewardSource");
        PendingUpdate memory update = pendingParameterUpdates[updateKey];
        
        if (update.effectiveTime == 0) revert NoUpdatePending("rewardSource");
        if (block.timestamp < update.effectiveTime) revert TimelockNotExpired(block.timestamp, update.effectiveTime);
        if (!update.isAddress) revert InvalidParameter("notAddressUpdate");
        
        address oldRewardSource = rewardSource;
        rewardSource = update.addrValue;
        
        delete pendingParameterUpdates[updateKey];
        
        emit ContractUpdated("rewardSource", oldRewardSource, update.addrValue);
    }
    
    /**
     * @notice Propose new liquidity injection rate
     * @param newRate New liquidity injection rate (percentage)
     */
    function proposeLiquidityInjectionRate(uint256 newRate) external onlyRole(GOVERNANCE_ROLE) {
        if (newRate > MAX_LIQUIDITY_INJECTION_RATE) revert InvalidParameter("newRate");
        
        bytes32 updateKey = keccak256("liquidityInjectionRate");
        pendingParameterUpdates[updateKey] = PendingUpdate({
            value: newRate,
            effectiveTime: block.timestamp + PARAMETER_TIMELOCK,
            isAddress: false,
            addrValue: address(0)
        });
        
        emit ParameterUpdateProposed("liquidityInjectionRate", newRate, block.timestamp + PARAMETER_TIMELOCK);
    }
    
    /**
     * @notice Execute proposed liquidity injection rate update after timelock
     */
    function executeLiquidityInjectionRateUpdate() external onlyRole(GOVERNANCE_ROLE) {
        bytes32 updateKey = keccak256("liquidityInjectionRate");
        PendingUpdate memory update = pendingParameterUpdates[updateKey];
        
        if (update.effectiveTime == 0) revert NoUpdatePending("liquidityInjectionRate");
        if (block.timestamp < update.effectiveTime) revert TimelockNotExpired(block.timestamp, update.effectiveTime);
        
        uint256 oldRate = liquidityInjectionRate;
        liquidityInjectionRate = update.value;
        
        delete pendingParameterUpdates[updateKey];
        
        emit RewardParametersUpdated("liquidityInjectionRate", oldRate, update.value);
    }
    
    /**
     * @notice Set the maximum daily distribution limit
     * @param newLimit New maximum daily distribution amount
     */
    function setMaxDailyDistribution(uint256 newLimit) external onlyRole(GOVERNANCE_ROLE) {
        uint256 oldLimit = maxDailyDistribution;
        maxDailyDistribution = newLimit;
        
        emit DailyDistributionLimitUpdated(oldLimit, newLimit);
    }
    
    /**
     * @notice Toggle auto-buyback functionality
     * @param enabled Whether buybacks should be enabled
     */
    function setAutoBuyback(bool enabled) external onlyRole(GOVERNANCE_ROLE) {
        autoBuybackEnabled = enabled;
        
        emit FeatureToggled("autoBuyback", enabled);
    }
    
    /**
     * @notice Update the Chainlink VRF callback gas limit
     * @param newLimit New gas limit for VRF callbacks
     */
    function setCallbackGasLimit(uint32 newLimit) external onlyRole(GOVERNANCE_ROLE) {
        if (newLimit < 100000) revert InvalidParameter("newLimit");
        
        uint32 oldLimit = callbackGasLimit;
        callbackGasLimit = newLimit;
        
        emit RewardParametersUpdated("callbackGasLimit", oldLimit, newLimit);
    }
    
    /**
     * @notice Update Chainlink VRF subscription
     * @param newSubscriptionId New VRF subscription ID
     */
    function setSubscriptionId(uint64 newSubscriptionId) external onlyRole(GOVERNANCE_ROLE) {
        uint64 oldSubscriptionId = subscriptionId;
        subscriptionId = newSubscriptionId;
        
        emit RewardParametersUpdated("subscriptionId", oldSubscriptionId, newSubscriptionId);
    }
    
    // -------------------------------------------
    // 🔹 Contract Updates
    // -------------------------------------------
    
    /**
     * @notice Propose update to the staking contract
     * @param newStakingContract New staking contract address
     */
    function proposeStakingContract(address newStakingContract) external onlyRole(GOVERNANCE_ROLE) {
        if (newStakingContract == address(0)) revert InvalidAddress("newStakingContract");
        
        bytes32 updateKey = keccak256("stakingContract");
        pendingParameterUpdates[updateKey] = PendingUpdate({
            value: 0,
            effectiveTime: block.timestamp + PARAMETER_TIMELOCK,
            isAddress: true,
            addrValue: newStakingContract

        });
        
        emit AddressUpdateProposed("stakingContract", newStakingContract, block.timestamp + PARAMETER_TIMELOCK);
    }
    
    /**
     * @notice Execute proposed staking contract update after timelock
     */
    function executeStakingContractUpdate() external onlyRole(GOVERNANCE_ROLE) {
        bytes32 updateKey = keccak256("stakingContract");
        PendingUpdate memory update = pendingParameterUpdates[updateKey];
        
        if (update.effectiveTime == 0) revert NoUpdatePending("stakingContract");
        if (block.timestamp < update.effectiveTime) revert TimelockNotExpired(block.timestamp, update.effectiveTime);
        if (!update.isAddress) revert InvalidParameter("notAddressUpdate");
        
        address oldStakingContract = address(stakingContract);
        stakingContract = ITerraStakeStaking(update.addrValue);
        
        // Revoke role from old contract and grant to new one
        _revokeRole(STAKING_CONTRACT_ROLE, oldStakingContract);
        _grantRole(STAKING_CONTRACT_ROLE, update.addrValue);
        
        delete pendingParameterUpdates[updateKey];
        
        // Update stake cache with new contract data
        _updateStakeTotalCache();
        
        emit ContractUpdated("stakingContract", oldStakingContract, update.addrValue);
    }
    
    /**
     * @notice Propose update to the liquidity guard contract
     * @param newLiquidityGuard New liquidity guard address
     */
    function proposeLiquidityGuard(address newLiquidityGuard) external onlyRole(GOVERNANCE_ROLE) {
        bytes32 updateKey = keccak256("liquidityGuard");
        pendingParameterUpdates[updateKey] = PendingUpdate({
            value: 0,
            effectiveTime: block.timestamp + PARAMETER_TIMELOCK,
            isAddress: true,
            addrValue: newLiquidityGuard
        });
        
        emit AddressUpdateProposed("liquidityGuard", newLiquidityGuard, block.timestamp + PARAMETER_TIMELOCK);
    }
    
    /**
     * @notice Execute proposed liquidity guard update after timelock
     */
    function executeLiquidityGuardUpdate() external onlyRole(GOVERNANCE_ROLE) {
        bytes32 updateKey = keccak256("liquidityGuard");
        PendingUpdate memory update = pendingParameterUpdates[updateKey];
        
        if (update.effectiveTime == 0) revert NoUpdatePending("liquidityGuard");
        if (block.timestamp < update.effectiveTime) revert TimelockNotExpired(block.timestamp, update.effectiveTime);
        if (!update.isAddress) revert InvalidParameter("notAddressUpdate");
        
        address oldLiquidityGuard = address(liquidityGuard);
        liquidityGuard = ITerraStakeLiquidityGuard(update.addrValue);
        
        delete pendingParameterUpdates[updateKey];
        
        emit ContractUpdated("liquidityGuard", oldLiquidityGuard, update.addrValue);
    }
    
    /**
     * @notice Propose update to the slashing contract
     * @param newSlashingContract New slashing contract address
     */
    function proposeSlashingContract(address newSlashingContract) external onlyRole(GOVERNANCE_ROLE) {
        bytes32 updateKey = keccak256("slashingContract");
        pendingParameterUpdates[updateKey] = PendingUpdate({
            value: 0,
            effectiveTime: block.timestamp + PARAMETER_TIMELOCK,
            isAddress: true,
            addrValue: newSlashingContract
        });
        
        emit AddressUpdateProposed("slashingContract", newSlashingContract, block.timestamp + PARAMETER_TIMELOCK);
    }
    
    /**
     * @notice Execute proposed slashing contract update after timelock
     */
    function executeSlashingContractUpdate() external onlyRole(GOVERNANCE_ROLE) {
        bytes32 updateKey = keccak256("slashingContract");
        PendingUpdate memory update = pendingParameterUpdates[updateKey];
        
        if (update.effectiveTime == 0) revert NoUpdatePending("slashingContract");
        if (block.timestamp < update.effectiveTime) revert TimelockNotExpired(block.timestamp, update.effectiveTime);
        if (!update.isAddress) revert InvalidParameter("notAddressUpdate");
        
        address oldSlashingContract = address(slashingContract);
        slashingContract = ITerraStakeSlashing(update.addrValue);
        
        delete pendingParameterUpdates[updateKey];
        
        emit ContractUpdated("slashingContract", oldSlashingContract, update.addrValue);
    }
    
    /**
     * @notice Propose update to the Uniswap router
     * @param newUniswapRouter New Uniswap router address
     */
    function proposeUniswapRouter(address newUniswapRouter) external onlyRole(GOVERNANCE_ROLE) {
        bytes32 updateKey = keccak256("uniswapRouter");
        pendingParameterUpdates[updateKey] = PendingUpdate({
            value: 0,
            effectiveTime: block.timestamp + PARAMETER_TIMELOCK,
            isAddress: true,
            addrValue: newUniswapRouter
        });
        
        emit AddressUpdateProposed("uniswapRouter", newUniswapRouter, block.timestamp + PARAMETER_TIMELOCK);
    }
    
    /**
     * @notice Execute proposed Uniswap router update after timelock
     */
    function executeUniswapRouterUpdate() external onlyRole(GOVERNANCE_ROLE) {
        bytes32 updateKey = keccak256("uniswapRouter");
        PendingUpdate memory update = pendingParameterUpdates[updateKey];
        
        if (update.effectiveTime == 0) revert NoUpdatePending("uniswapRouter");
        if (block.timestamp < update.effectiveTime) revert TimelockNotExpired(block.timestamp, update.effectiveTime);
        if (!update.isAddress) revert InvalidParameter("notAddressUpdate");
        
        address oldUniswapRouter = address(uniswapRouter);
        uniswapRouter = ISwapRouter(update.addrValue);
        
        delete pendingParameterUpdates[updateKey];
        
        emit ContractUpdated("uniswapRouter", oldUniswapRouter, update.addrValue);
    }
    
    /**
     * @notice Propose update to the liquidity pool address
     * @param newLiquidityPool New liquidity pool address
     */
    function proposeLiquidityPool(address newLiquidityPool) external onlyRole(GOVERNANCE_ROLE) {
        bytes32 updateKey = keccak256("liquidityPool");
        pendingParameterUpdates[updateKey] = PendingUpdate({
            value: 0,
            effectiveTime: block.timestamp + PARAMETER_TIMELOCK,
            isAddress: true,
            addrValue: newLiquidityPool
        });
        
        emit AddressUpdateProposed("liquidityPool", newLiquidityPool, block.timestamp + PARAMETER_TIMELOCK);
    }
    
    /**
     * @notice Execute proposed liquidity pool update after timelock
     */
    function executeLiquidityPoolUpdate() external onlyRole(GOVERNANCE_ROLE) {
        bytes32 updateKey = keccak256("liquidityPool");
        PendingUpdate memory update = pendingParameterUpdates[updateKey];
        
        if (update.effectiveTime == 0) revert NoUpdatePending("liquidityPool");
        if (block.timestamp < update.effectiveTime) revert TimelockNotExpired(block.timestamp, update.effectiveTime);
        if (!update.isAddress) revert InvalidParameter("notAddressUpdate");
        
        address oldLiquidityPool = liquidityPool;
        liquidityPool = update.addrValue;
        
        delete pendingParameterUpdates[updateKey];
        
        emit ContractUpdated("liquidityPool", oldLiquidityPool, update.addrValue);
    }
    
    // -------------------------------------------
    // 🔹 Emergency Recovery Functions
    // -------------------------------------------
    
    /**
     * @notice Recover ERC20 tokens accidentally sent to the contract
     * @param tokenAddress Address of the token to recover
     * @param amount Amount to recover
     */
    function recoverERC20(address tokenAddress, uint256 amount) 
        external 
        onlyRole(MULTISIG_ROLE) 
        nonReentrant 
    {
        // Prevent recovering the reward token to avoid draining rewards
        if (tokenAddress == address(rewardToken)) revert CannotRecoverRewardToken();
        
        IERC20Upgradeable(tokenAddress).safeTransfer(msg.sender, amount);
        emit EmergencyTokenRecovery(tokenAddress, amount, msg.sender);
    }
    
    /**
     * @notice Cancel a pending parameter update
     * @param paramName Name of the parameter update to cancel
     */
    function cancelPendingUpdate(string calldata paramName) external onlyRole(MULTISIG_ROLE) {
        bytes32 updateKey = keccak256(abi.encodePacked(paramName));
        
        if (pendingParameterUpdates[updateKey].effectiveTime == 0) {
            revert NoUpdatePending(paramName);
        }
        
        delete pendingParameterUpdates[updateKey];
    }
    
    // -------------------------------------------
    // 🔹 View Functions
    // -------------------------------------------
    
    /**
     * @notice Get the current reward rate after halving
     * @param baseAmount Base reward amount
     * @return adjustedAmount Adjusted reward amount after halving
     */
    function getAdjustedRewardAmount(uint256 baseAmount) external view returns (uint256) {
        return (baseAmount * halvingReductionRate) / 100;
    }
    
    /**
     * @notice Get time until next halving
     * @return timeRemaining Seconds until next halving
     */
    function getTimeUntilNextHalving() external view returns (uint256) {
        uint256 nextHalvingTime = lastHalvingTime + TWO_YEARS_IN_SECONDS;
        if (block.timestamp >= nextHalvingTime) {
            return 0;
        }
        return nextHalvingTime - block.timestamp;
    }
    
    /**
     * @notice Get effective time for a pending parameter update
     * @param paramName Name of the parameter
     * @return effectiveTime Time when the update can be executed (0 if no pending update)
     */
    function getPendingUpdateTime(string calldata paramName) external view returns (uint256) {
        bytes32 updateKey = keccak256(abi.encodePacked(paramName));
        return pendingParameterUpdates[updateKey].effectiveTime;
    }
    
    /**
     * @notice Get pending parameter value
     * @param paramName Name of the parameter
     * @return value Pending numeric value
     * @return isAddress Whether this is an address update
     * @return addrValue Pending address value (if isAddress is true)
     */
    function getPendingUpdateValue(string calldata paramName) 
        external 
        view 
        returns (uint256 value, bool isAddress, address addrValue) 
    {
        bytes32 updateKey = keccak256(abi.encodePacked(paramName));
        PendingUpdate memory update = pendingParameterUpdates[updateKey];
        return (update.value, update.isAddress, update.addrValue);
    }
    
    /**
     * @notice Get pending penalty for a validator
     * @param validator Validator address
     * @return amount Pending penalty amount
     */
    function getPendingPenalty(address validator) external view returns (uint256) {
        return pendingPenalties[validator];
    }
    
    /**
     * @notice Get halving status information
     * @return currentRate Current halving rate
     * @return epoch Current halving epoch
     * @return lastHalvingTimestamp Timestamp of last halving
     * @return nextHalvingTimestamp Timestamp of next halving
     * @return isPaused Whether halving mechanism is paused
     */
    function getHalvingStatus() external view returns (
        uint256 currentRate,
        uint256 epoch,
        uint256 lastHalvingTimestamp,
        uint256 nextHalvingTimestamp,
        bool isPaused
    ) {
        uint256 next = lastHalvingTime + TWO_YEARS_IN_SECONDS;
        return (
            halvingReductionRate,
            halvingEpoch,
            lastHalvingTime,
            next,
            halvingMechanismPaused
        );
    }
    
    /**
     * @notice Get distribution statistics
     * @return total Total rewards distributed
     * @return daily Today's distribution
     * @return dailyLimit Maximum daily distribution
     * @return nextResetTime Time when daily counter resets
     * @return isPaused Whether distribution is paused
     */
    function getDistributionStats() external view returns (
        uint256 total,
        uint256 daily,
        uint256 dailyLimit,
        uint256 nextResetTime,
        bool isPaused
    ) {
        uint256 next = lastDistributionReset + 1 days;
        return (
            totalDistributed,
            dailyDistributed,
            maxDailyDistribution,
            next,
            distributionPaused
        );
    }
    
    /**
     * @notice Return the contract version
     * @return version Contract version
     */
    function version() external pure returns (string memory) {
        return "2.0.0";
    }
}
