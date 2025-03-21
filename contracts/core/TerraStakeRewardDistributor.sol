// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@chainlink/contracts/src/v0.8/vrf/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import "../interfaces/ITerraStakeRewardDistributor.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";
import "../interfaces/ITerraStakeSlashing.sol";

/**
 * @title TerraStakeRewardDistributor
 * @author TerraStake Protocol Team
 * @notice Handles staking rewards, liquidity injection, APR management, and reward halving
 */
contract TerraStakeRewardDistributor is
    Initializable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    VRFConsumerBaseV2,
    ITerraStakeRewardDistributor
{
    using SafeERC20 for IERC20;

    // Constants
    bytes32 public constant STAKING_CONTRACT_ROLE = keccak256("STAKING_CONTRACT_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant MULTISIG_ROLE = keccak256("MULTISIG_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    uint256 public constant MAX_LIQUIDITY_INJECTION_RATE = 10; // 10%
    uint256 public constant MAX_HALVING_REDUCTION_RATE = 90;   // 90%
    uint256 public constant TWO_YEARS_IN_SECONDS = 730 days;
    uint256 public constant MIN_REWARD_RATE = 10;              // 10% (floor)
    uint256 public constant PARAMETER_TIMELOCK = 2 days;

    // Errors
    error Unauthorized();
    error InvalidAddress(string name);
    error InvalidParameter(string name);
    error TransferFailed(address token, address from, address to, uint256 amount);
    error HalvingAlreadyRequested();
    error RandomizationFailed();
    error TimelockNotExpired(uint256 current, uint256 required);
    error NoUpdatePending(string paramName);
    error CircuitBreakerActive();
    error CannotRecoverRewardToken();
    error MaxDistributionExceeded();

    // State Variables
    IERC20 public rewardToken;
    ITerraStakeStaking public stakingContract;
    ISwapRouter public uniswapRouter;
    ITerraStakeLiquidityGuard public liquidityGuard;
    ITerraStakeSlashing public slashingContract;
    VRFCoordinatorV2Interface public vrfCoordinator;
   
    address public rewardSource;
    address public liquidityPool;
   
    uint256 public totalDistributed;
    uint256 public halvingEpoch;
    uint256 public lastHalvingTime;
    uint256 public halvingReductionRate;
    uint256 public liquidityInjectionRate;
    uint256 public maxDailyDistribution;
    uint256 public dailyDistributed;
    uint256 public lastDistributionReset;
   
    bool public autoBuybackEnabled;
    bool public isPaused; // Updated state variable
    bool public pendingRandomnessRequest;
   
    bytes32 public keyHash;
    uint64 public subscriptionId;
    uint32 public callbackGasLimit;
    mapping(bytes32 => bool) private vrfRequests;
   
    mapping(address => uint256) public pendingPenalties;
    uint256 public totalPendingPenalties;
    uint256 public totalStakedCache;
    uint256 public lastStakeUpdateTime;

    struct PendingUpdate {
        uint256 value;
        uint256 effectiveTime;
        bool isAddress;
        address addrValue;
    }
    mapping(bytes32 => PendingUpdate) public pendingParameterUpdates;

    // Events
    event RewardDistributed(address indexed user, uint256 amount);
    event HalvingApplied(uint256 newRewardRate, uint256 halvingEpoch);
    event LiquidityInjected(uint256 amount);
    event LiquidityInjectionFailed(uint256 amount);
    event PenaltyReDistributed(address indexed from, uint256 amount);
    event HalvingRequested(uint256 requestId);
    event RandomnessReceived(bytes32 indexed requestId, uint256 randomness);
    event RewardParametersUpdated(string paramName, uint256 oldValue, uint256 newValue);
    event ContractUpdated(string contractName, address oldAddress, address newAddress);
    event FeatureToggled(string featureName, bool enabled);
    event EmergencyTokenRecovery(address token, uint256 amount, address recipient);
    event ParameterUpdateProposed(string paramName, uint256 value, uint256 effectiveTime);
    event AddressUpdateProposed(string paramName, address value, uint256 effectiveTime);
    event Paused(bool paused); // Updated event
    event PenaltiesBatchDistributed(uint256 startIndex, uint256 endIndex, uint256 amount);
    event StakeTotalCacheUpdated(uint256 oldTotal, uint256 newTotal);
    event DailyDistributionLimitUpdated(uint256 oldLimit, uint256 newLimit);
    event DailyDistributionReset(uint256 timestamp);
    event PenaltyRewardsAdded(address sender, uint256 amount);

    constructor(address _vrfCoordinator) VRFConsumerBaseV2(_vrfCoordinator) {
        _disableInitializers();
    }

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

        rewardToken = IERC20(_rewardToken);
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
        callbackGasLimit = 100000;

        lastHalvingTime = block.timestamp;
        halvingReductionRate = 80;
        liquidityInjectionRate = 5;
        autoBuybackEnabled = true;

        maxDailyDistribution = type(uint256).max;
        lastDistributionReset = block.timestamp;

        _updateStakeTotalCache();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(GOVERNANCE_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
        _grantRole(STAKING_CONTRACT_ROLE, _stakingContract);
        _grantRole(MULTISIG_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function distributeReward(address user, uint256 amount)
        external
        override
        onlyRole(STAKING_CONTRACT_ROLE)
        nonReentrant
    {
        if (user == address(0)) revert InvalidAddress("user");
        if (amount == 0) revert InvalidParameter("amount");
        if (isPaused) revert CircuitBreakerActive();

        _checkAndResetDailyLimit();
        _checkAndApplyHalving();

        uint256 adjustedAmount = (amount * halvingReductionRate) / 100;

        if (dailyDistributed + adjustedAmount > maxDailyDistribution) revert MaxDistributionExceeded();
        dailyDistributed += adjustedAmount;

        rewardToken.safeTransferFrom(rewardSource, user, adjustedAmount);
        totalDistributed += adjustedAmount;

        if (autoBuybackEnabled && address(liquidityGuard) != address(0) && address(uniswapRouter) != address(0)) {
            uint256 injectionAmount = (adjustedAmount * liquidityInjectionRate) / 100;
            rewardToken.safeTransferFrom(rewardSource, address(this), injectionAmount);

            // Swap half of injectionAmount for USDC (example)
            rewardToken.safeApprove(address(uniswapRouter), injectionAmount / 2);
            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: address(rewardToken),
                tokenOut: address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48), // USDC address (example)
                fee: 3000,
                recipient: address(this),
                deadline: block.timestamp + 15 minutes,
                amountIn: injectionAmount / 2,
                amountOutMinimum: 0, // Should set slippage tolerance in production
                sqrtPriceLimitX96: 0
            });

            try uniswapRouter.exactInputSingle(params) {
                try liquidityGuard.injectLiquidity(injectionAmount / 2) {
                    emit LiquidityInjected(injectionAmount / 2);
                } catch {
                    emit LiquidityInjectionFailed(injectionAmount / 2);
                }
            } catch {
                emit LiquidityInjectionFailed(injectionAmount / 2);
            }
        }

        emit RewardDistributed(user, adjustedAmount);
    }

    function claimRewards(address user)
        external
        nonReentrant
        returns (uint256 rewardAmount)
    {
        if (user == address(0)) revert InvalidAddress("user");
        if (isPaused) revert CircuitBreakerActive();

        _checkAndResetDailyLimit();

        rewardAmount = stakingContract.calculateRewards(user);
        (uint256 slashedReward, ) = slashingContract.getUserSlashedRewards(user);
        rewardAmount += slashedReward;

        if (rewardAmount == 0) return 0;

        uint256 adjustedReward = (rewardAmount * halvingReductionRate) / 100;

        if (dailyDistributed + adjustedReward > maxDailyDistribution) revert MaxDistributionExceeded();
        dailyDistributed += adjustedReward;

        rewardToken.safeTransferFrom(rewardSource, user, adjustedReward);
        totalDistributed += adjustedReward;

        if (autoBuybackEnabled && address(liquidityGuard) != address(0) && address(uniswapRouter) != address(0)) {
            uint256 injectionAmount = (adjustedReward * liquidityInjectionRate) / 100;
            rewardToken.safeTransferFrom(rewardSource, address(this), injectionAmount);

            rewardToken.safeApprove(address(uniswapRouter), injectionAmount / 2);
            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: address(rewardToken),
                tokenOut: address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48),
                fee: 3000,
                recipient: address(this),
                deadline: block.timestamp + 15 minutes,
                amountIn: injectionAmount / 2,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

            try uniswapRouter.exactInputSingle(params) {
                try liquidityGuard.injectLiquidity(injectionAmount / 2) {
                    emit LiquidityInjected(injectionAmount / 2);
                } catch {
                    emit LiquidityInjectionFailed(injectionAmount / 2);
                }
            } catch {
                emit LiquidityInjectionFailed(injectionAmount / 2);
            }
        }

        emit RewardDistributed(user, adjustedReward);
        return adjustedReward;
    }

    function redistributePenalty(address from, uint256 amount)
        external
        override
        nonReentrant
    {
        if (msg.sender != address(slashingContract)) revert Unauthorized();
        if (amount == 0) revert InvalidParameter("amount");

        pendingPenalties[from] += amount;
        totalPendingPenalties += amount;

        emit PenaltyReDistributed(from, amount);
    }

    function addPenaltyRewards(uint256 amount) external nonReentrant onlyRole(GOVERNANCE_ROLE) {
        if (amount == 0) revert InvalidParameter("amount");

        IERC20(address(rewardToken)).safeTransferFrom(msg.sender, address(this), amount);
        totalPendingPenalties += amount;

        emit PenaltyRewardsAdded(msg.sender, amount);
    }

    function batchDistributePenalties(uint256 startIndex, uint256 endIndex)
        external
        onlyRole(GOVERNANCE_ROLE)
        nonReentrant
    {
        if (totalPendingPenalties == 0) revert InvalidParameter("noPendingPenalties");

        address[] memory stakers = stakingContract.getActiveStakers();
        if (stakers.length == 0) return;

        if (endIndex >= stakers.length) {
            endIndex = stakers.length - 1;
        }
        if (startIndex > endIndex) revert InvalidParameter("invalidIndices");

        if (block.timestamp > lastStakeUpdateTime + 1 days) {
            _updateStakeTotalCache();
        }

        if (totalStakedCache == 0) return;

        uint256 batchStaked = 0;
        for (uint256 i = startIndex; i <= endIndex; i++) {
            batchStaked += stakingContract.getUserTotalStake(stakers[i]);
        }

        if (batchStaked == 0) return;

        uint256 batchPenaltyShare = (totalPendingPenalties * batchStaked) / totalStakedCache;
        uint256 distributedInBatch = 0;

        for (uint256 i = startIndex; i <= endIndex; i++) {
            address staker = stakers[i];
            uint256 stakerAmount = stakingContract.getUserTotalStake(staker);

            if (stakerAmount > 0) {
                uint256 penaltyShare = (batchPenaltyShare * stakerAmount) / batchStaked;
                if (penaltyShare > 0) {
                    try rewardToken.safeTransfer(staker, penaltyShare) {
                        distributedInBatch += penaltyShare;
                    } catch {
                        continue;
                    }
                }
            }
        }

        if (distributedInBatch > 0) {
            totalPendingPenalties -= distributedInBatch;
        }

        emit PenaltiesBatchDistributed(startIndex, endIndex, distributedInBatch);
    }

    function _updateStakeTotalCache() internal {
        uint256 oldTotal = totalStakedCache;
        address[] memory stakers = stakingContract.getActiveStakers();
        uint256 newTotal = 0;

        for (uint256 i = 0; i < stakers.length; i++) {
            newTotal += stakingContract.getUserTotalStake(stakers[i]);
        }

        totalStakedCache = newTotal;
        lastStakeUpdateTime = block.timestamp;

        emit StakeTotalCacheUpdated(oldTotal, newTotal);
    }

    function updateStakeTotalCache() external override onlyRole(GOVERNANCE_ROLE) {
        _updateStakeTotalCache();
    }

    function _checkAndResetDailyLimit() internal {
        if (block.timestamp >= lastDistributionReset + 1 days) {
            dailyDistributed = 0;
            lastDistributionReset = block.timestamp;
            emit DailyDistributionReset(block.timestamp);
        }
    }

    function _checkAndApplyHalving() internal {
        if (isPaused) return;
        if (block.timestamp >= lastHalvingTime + TWO_YEARS_IN_SECONDS) {
            _applyHalving();
        }
    }

    function _applyHalving() internal {
        lastHalvingTime = block.timestamp;
        halvingEpoch++;
        uint256 newRate = (halvingReductionRate * MAX_HALVING_REDUCTION_RATE) / 100;
        halvingReductionRate = newRate < MIN_REWARD_RATE ? MIN_REWARD_RATE : newRate;
        emit HalvingApplied(halvingReductionRate, halvingEpoch);
    }

    function requestRandomHalving() external override onlyRole(GOVERNANCE_ROLE) returns (uint256) {
        if (pendingRandomnessRequest) revert HalvingAlreadyRequested();
        pendingRandomnessRequest = true;

        uint256 requestId = vrfCoordinator.requestRandomWords(
            keyHash,
            subscriptionId,
            3,
            callbackGasLimit,
            1
        );

        vrfRequests[bytes32(requestId)] = true;
        emit HalvingRequested(requestId);
        return requestId;
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        bytes32 requestIdBytes = bytes32(requestId);
        if (!vrfRequests[requestIdBytes]) revert RandomizationFailed();

        uint256 oldRate = halvingReductionRate;
        uint256 randomAdjustment = randomWords[0] % 11;
        int256 adjustmentDirection = randomAdjustment >= 5 ? int256(1) : int256(-1);
        uint256 adjustmentAmount = randomAdjustment % 6;

        int256 newRateInt = int256(oldRate) + (adjustmentDirection * int256(adjustmentAmount));
        uint256 newRate = uint256(newRateInt < int256(MIN_REWARD_RATE) ? int256(MIN_REWARD_RATE) : newRateInt);

        halvingReductionRate = newRate;
        lastHalvingTime = block.timestamp;
        halvingEpoch++;

        delete vrfRequests[requestIdBytes];
        pendingRandomnessRequest = false;

        emit RandomnessReceived(requestIdBytes, randomWords[0]);
        emit HalvingApplied(halvingReductionRate, halvingEpoch);
    }

    function forceHalving() external override onlyRole(MULTISIG_ROLE) {
        _applyHalving();
    }

    function setPaused(bool paused) external override onlyRole(EMERGENCY_ROLE) {
        isPaused = paused;
        emit Paused(paused);
    }

    function proposeRewardSource(address newRewardSource) external override onlyRole(GOVERNANCE_ROLE) {
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

    function executeRewardSourceUpdate() external override onlyRole(GOVERNANCE_ROLE) {
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

    function proposeLiquidityInjectionRate(uint256 newRate) external override onlyRole(GOVERNANCE_ROLE) {
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

    function executeLiquidityInjectionRateUpdate() external override onlyRole(GOVERNANCE_ROLE) {
        bytes32 updateKey = keccak256("liquidityInjectionRate");
        PendingUpdate memory update = pendingParameterUpdates[updateKey];
        if (update.effectiveTime == 0) revert NoUpdatePending("liquidityInjectionRate");
        if (block.timestamp < update.effectiveTime) revert TimelockNotExpired(block.timestamp, update.effectiveTime);

        uint256 oldRate = liquidityInjectionRate;
        liquidityInjectionRate = update.value;
        delete pendingParameterUpdates[updateKey];
        emit RewardParametersUpdated("liquidityInjectionRate", oldRate, update.value);
    }

    function setMaxDailyDistribution(uint256 newLimit) external override onlyRole(GOVERNANCE_ROLE) {
        uint256 oldLimit = maxDailyDistribution;
        maxDailyDistribution = newLimit;
        emit DailyDistributionLimitUpdated(oldLimit, newLimit);
    }

    function setAutoBuyback(bool enabled) external override onlyRole(GOVERNANCE_ROLE) {
        autoBuybackEnabled = enabled;
        emit FeatureToggled("autoBuyback", enabled);
    }

    function setCallbackGasLimit(uint32 newLimit) external override onlyRole(GOVERNANCE_ROLE) {
        if (newLimit < 100000) revert InvalidParameter("newLimit");
        uint32 oldLimit = callbackGasLimit;
        callbackGasLimit = newLimit;
        emit RewardParametersUpdated("callbackGasLimit", oldLimit, newLimit);
    }

    function setSubscriptionId(uint64 newSubscriptionId) external override onlyRole(GOVERNANCE_ROLE) {
        uint64 oldSubscriptionId = subscriptionId;
        subscriptionId = newSubscriptionId;
        emit RewardParametersUpdated("subscriptionId", oldSubscriptionId, newSubscriptionId);
    }

    function proposeStakingContract(address newStakingContract) external override onlyRole(GOVERNANCE_ROLE) {
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

    function executeStakingContractUpdate() external override onlyRole(GOVERNANCE_ROLE) {
        bytes32 updateKey = keccak256("stakingContract");
        PendingUpdate memory update = pendingParameterUpdates[updateKey];
        if (update.effectiveTime == 0) revert NoUpdatePending("stakingContract");
        if (block.timestamp < update.effectiveTime) revert TimelockNotExpired(block.timestamp, update.effectiveTime);
        if (!update.isAddress) revert InvalidParameter("notAddressUpdate");

        address oldStakingContract = address(stakingContract);
        stakingContract = ITerraStakeStaking(update.addrValue);
        _revokeRole(STAKING_CONTRACT_ROLE, oldStakingContract);
        _grantRole(STAKING_CONTRACT_ROLE, update.addrValue);
        delete pendingParameterUpdates[updateKey];
        _updateStakeTotalCache();
        emit ContractUpdated("stakingContract", oldStakingContract, update.addrValue);
    }

    function proposeLiquidityGuard(address newLiquidityGuard) external override onlyRole(GOVERNANCE_ROLE) {
        bytes32 updateKey = keccak256("liquidityGuard");
        pendingParameterUpdates[updateKey] = PendingUpdate({
            value: 0,
            effectiveTime: block.timestamp + PARAMETER_TIMELOCK,
            isAddress: true,
            addrValue: newLiquidityGuard
        });
        emit AddressUpdateProposed("liquidityGuard", newLiquidityGuard, block.timestamp + PARAMETER_TIMELOCK);
    }

    function executeLiquidityGuardUpdate() external override onlyRole(GOVERNANCE_ROLE) {
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

    function proposeSlashingContract(address newSlashingContract) external override onlyRole(GOVERNANCE_ROLE) {
        bytes32 updateKey = keccak256("slashingContract");
        pendingParameterUpdates[updateKey] = PendingUpdate({
            value: 0,
            effectiveTime: block.timestamp + PARAMETER_TIMELOCK,
            isAddress: true,
            addrValue: newSlashingContract
        });
        emit AddressUpdateProposed("slashingContract", newSlashingContract, block.timestamp + PARAMETER_TIMELOCK);
    }

    function executeSlashingContractUpdate() external override onlyRole(GOVERNANCE_ROLE) {
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

    function proposeUniswapRouter(address newUniswapRouter) external override onlyRole(GOVERNANCE_ROLE) {
        bytes32 updateKey = keccak256("uniswapRouter");
        pendingParameterUpdates[updateKey] = PendingUpdate({
            value: 0,
            effectiveTime: block.timestamp + PARAMETER_TIMELOCK,
            isAddress: true,
            addrValue: newUniswapRouter
        });
        emit AddressUpdateProposed("uniswapRouter", newUniswapRouter, block.timestamp + PARAMETER_TIMELOCK);
    }

    function executeUniswapRouterUpdate() external override onlyRole(GOVERNANCE_ROLE) {
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

    function proposeLiquidityPool(address newLiquidityPool) external override onlyRole(GOVERNANCE_ROLE) {
        bytes32 updateKey = keccak256("liquidityPool");
        pendingParameterUpdates[updateKey] = PendingUpdate({
            value: 0,
            effectiveTime: block.timestamp + PARAMETER_TIMELOCK,
            isAddress: true,
            addrValue: newLiquidityPool
        });
        emit AddressUpdateProposed("liquidityPool", newLiquidityPool, block.timestamp + PARAMETER_TIMELOCK);
    }

    function executeLiquidityPoolUpdate() external override onlyRole(GOVERNANCE_ROLE) {
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

    function recoverERC20(address tokenAddress, uint256 amount, address recipient)
        external
        override
        onlyRole(MULTISIG_ROLE)
        nonReentrant
    {
        if (tokenAddress == address(rewardToken)) revert CannotRecoverRewardToken();
        IERC20(tokenAddress).safeTransfer(recipient, amount);
        emit EmergencyTokenRecovery(tokenAddress, amount, recipient);
    }

    function cancelPendingUpdate(string calldata paramName) external override onlyRole(MULTISIG_ROLE) {
        bytes32 updateKey = keccak256(abi.encodePacked(paramName));
        if (pendingParameterUpdates[updateKey].effectiveTime == 0) {
            revert NoUpdatePending(paramName);
        }
        delete pendingParameterUpdates[updateKey];
    }

    function getAdjustedRewardAmount(uint256 baseAmount) external view override returns (uint256) {
        return (baseAmount * halvingReductionRate) / 100;
    }

    function getTimeUntilNextHalving() external view override returns (uint256) {
        uint256 nextHalvingTime = lastHalvingTime + TWO_YEARS_IN_SECONDS;
        if (block.timestamp >= nextHalvingTime) {
            return 0;
        }
        return nextHalvingTime - block.timestamp;
    }

    function getPendingUpdateTime(string calldata paramName) external view override returns (uint256) {
        bytes32 updateKey = keccak256(abi.encodePacked(paramName));
        return pendingParameterUpdates[updateKey].effectiveTime;
    }

    function getPendingUpdateValue(string calldata paramName)
        external
        view
        override
        returns (uint256 value, bool isAddress, address addrValue)
    {
        bytes32 updateKey = keccak256(abi.encodePacked(paramName));
        PendingUpdate memory update = pendingParameterUpdates[updateKey];
        return (update.value, update.isAddress, update.addrValue);
    }

    function getPendingPenalty(address validator) external view override returns (uint256) {
        return pendingPenalties[validator];
    }

    function getHalvingStatus() external view override returns (
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
            isPaused
        );
    }

    function getDistributionStats() external view override returns (
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
            isPaused
        );
    }

    function version() external pure override returns (string memory) {
        return "2.0.0";
    }
}