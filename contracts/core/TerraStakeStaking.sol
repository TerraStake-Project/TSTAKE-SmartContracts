// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@layerzerolabs/contracts/interfaces/ILayerZeroEndpoint.sol";

import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/ITerraStakeRewardDistributor.sol";
import "../interfaces/ITerraStakeProjects.sol";
import "../interfaces/ITerraStakeGovernance.sol";
import "../interfaces/ITerraStakeSlashing.sol";
import "../interfaces/ITerraStakeAI.sol";

/**
 * @title TerraStakeStaking
 * @notice Enhanced staking contract with multi-project support, dynamic APR, halving events,
 * LayerZero cross-chain sync, improved staking dynamics, and a new Stake Locking Boost feature.
 * @dev Combines robust staking logic with advanced tokenomics features, upgradeable via UUPS.
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

    // Custom Errors
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

    // Constants
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 public constant CROSS_CHAIN_RELAYER_ROLE = keccak256("CROSS_CHAIN_RELAYER_ROLE");

    uint256 public constant BASE_APR = 10;
    uint256 public constant BOOSTED_APR = 20;
    uint256 public constant NFT_APR_BOOST = 10;
    uint256 public constant LP_APR_BOOST = 15;
    uint256 public constant LOCK_BOOST_APR = 5; // New: Additional 5% APR for locking > 1 year
    uint256 public constant BASE_PENALTY_PERCENT = 10;
    uint256 public constant MAX_PENALTY_PERCENT = 30;
    uint256 public constant LOW_STAKING_THRESHOLD = 1_000_000 * 10**18;
    uint256 public constant GOVERNANCE_VESTING_PERIOD = 7 days;
    uint256 public constant MAX_LIQUIDITY_RATE = 10;
    uint256 public constant MIN_STAKING_DURATION = 30 days;
    uint256 public constant LOCK_BOOST_DURATION = 365 days; // Threshold for lock boost
    uint256 public constant GOVERNANCE_THRESHOLD = 10_000 * 10**18;
    address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // Halving Constants (Adopted from TerraStakeToken)
    uint256 public constant HALVING_RATE = 65; // 65% of previous rate, 35% reduction

    // State Variables
    IERC1155 public nftContract;
    IERC20 public stakingToken;
    ITerraStakeRewardDistributor public rewardDistributor;
    ITerraStakeProjects public projectsContract;
    ITerraStakeGovernance public governanceContract;
    ITerraStakeSlashing public slashingContract;
    address public liquidityPool;
    ILayerZeroEndpoint public layerZeroEndpoint;
    ITerraStakeAI public terraStakeAI;

    uint256 public liquidityInjectionRate;
    bool public autoLiquidityEnabled;
    uint256 public halvingPeriod;
    uint256 public lastHalvingTime;
    uint256 public currentHalvingEpoch; // Renamed from halvingEpoch for consistency
    uint256 public proposalNonce;
    uint256 public validatorThreshold;
    uint256 public dynamicBaseAPR; // Acts as emission rate equivalent
    uint256 public dynamicBoostedAPR; // Scaled with base APR
    uint16 public targetChainId;
    uint256 public lastSentEpoch;
    uint256 public lastReceivedEpoch;

    mapping(address => mapping(uint256 => StakingPosition)) private _stakingPositions;
    mapping(address => uint256[]) private _stakedProjects;
    mapping(address => uint256) private _governanceVotes;
    mapping(address => uint256) private _stakingBalance;
    mapping(address => bool) private _governanceViolators;
    mapping(address => bool) private _validators;
    mapping(uint256 => uint256) public sentTimestamps;
    mapping(uint256 => uint256) public receivedTimestamps;

    uint256 private _totalStaked;
    StakingTier[] private _tiers;

    address[] private _activeStakers;
    mapping(address => bool) private _isActiveStaker;

    mapping(address => PenaltyEvent[]) private _penaltyHistory;
    mapping(address => uint256) private _validatorCommission;
    mapping(uint256 => uint256) private _projectVotes;
    uint256 public validatorRewardPool;
    uint256 public governanceQuorum;
    bool public dynamicRewardsEnabled;
    uint256 public lastRewardAdjustmentTime;

    uint256[50] private __gap;

    // Structs
    struct StakingPosition {
        uint256 amount;
        uint256 stakingStart;
        uint256 duration;
        uint256 lastCheckpoint;
        uint256 projectId;
        bool isLPStaker;
        bool hasNFTBoost;
        bool autoCompounding;
        bool isLocked; // New: Indicates if position qualifies for lock boost
    }

    struct PenaltyEvent {
        uint256 projectId;
        uint256 timestamp;
        uint256 totalPenalty;
        uint256 burned;
        uint256 redistributed;
        uint256 toLiquidity;
    }

    struct StakingTier {
        uint256 minDuration;
        uint256 multiplier;
        bool votingRights;
    }

    // Initialization
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _nftContract,
        address _stakingToken,
        address _rewardDistributor,
        address _liquidityPool,
        address _projectsContract,
        address _governanceContract,
        address _admin,
        address _layerZeroEndpoint,
        uint16 _targetChainId
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
        if (_layerZeroEndpoint == address(0)) revert InvalidAddress("layerZeroEndpoint", _layerZeroEndpoint);

        nftContract = IERC1155(_nftContract);
        stakingToken = IERC20(_stakingToken);
        rewardDistributor = ITerraStakeRewardDistributor(_rewardDistributor);
        liquidityPool = _liquidityPool;
        projectsContract = ITerraStakeProjects(_projectsContract);
        governanceContract = ITerraStakeGovernance(_governanceContract);
        layerZeroEndpoint = ILayerZeroEndpoint(_layerZeroEndpoint);
        targetChainId = _targetChainId;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(GOVERNANCE_ROLE, _governanceContract);
        _grantRole(UPGRADER_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
        _grantRole(CROSS_CHAIN_RELAYER_ROLE, _admin);

        halvingPeriod = 730 days;
        lastHalvingTime = block.timestamp;
        currentHalvingEpoch = 0;
        liquidityInjectionRate = 5;
        autoLiquidityEnabled = true;
        validatorThreshold = 100_000 * 10**18;
        dynamicBaseAPR = BASE_APR;
        dynamicBoostedAPR = BOOSTED_APR;

        _tiers.push(StakingTier(30 days, 100, false));
        _tiers.push(StakingTier(90 days, 150, true));
        _tiers.push(StakingTier(180 days, 200, true));
        _tiers.push(StakingTier(365 days, 300, true));

        governanceQuorum = 1000;
        dynamicRewardsEnabled = false;
        lastRewardAdjustmentTime = block.timestamp;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // ============ Halving Mechanism (Adopted from TerraStakeToken) ============

    /**
     * @notice Applies halving to APRs, reducing them by 35% (retaining 65%)
     * @dev Matches TerraStakeToken’s applyHalving logic
     */
    function applyHalving() external onlyRole(GOVERNANCE_ROLE) {
        require(block.timestamp >= lastHalvingTime + halvingPeriod, "Halving not due");

        uint256 oldBaseAPR = dynamicBaseAPR;
        uint256 oldBoostedAPR = dynamicBoostedAPR;

        // Reduce APRs by 35% (keep 65% of previous rate)
        dynamicBaseAPR = (dynamicBaseAPR * HALVING_RATE) / 100;
        dynamicBoostedAPR = (dynamicBoostedAPR * HALVING_RATE) / 100;

        // Ensure minimum APRs
        if (dynamicBaseAPR < 1) dynamicBaseAPR = 1;
        if (dynamicBoostedAPR < 2) dynamicBoostedAPR = 2;

        currentHalvingEpoch += 1;
        lastHalvingTime = block.timestamp;

        _syncWithGovernance();

        emit HalvingApplied(
            currentHalvingEpoch,
            oldBaseAPR,
            dynamicBaseAPR,
            oldBoostedAPR,
            dynamicBoostedAPR
        );
        emit EmissionRateUpdated(dynamicBaseAPR); // Matches TerraStakeToken’s event
    }

    /**
     * @notice Triggers halving immediately, syncing with ecosystem contracts
     * @dev Matches TerraStakeToken’s triggerHalving logic
     * @return New halving epoch
     */
    function triggerHalving() external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256) {
        if (block.timestamp < lastHalvingTime + halvingPeriod) {
            revert("Halving not yet due");
        }

        uint256 oldBaseAPR = dynamicBaseAPR;
        uint256 oldBoostedAPR = dynamicBoostedAPR;

        // Apply halving to APRs (35% reduction)
        dynamicBaseAPR = (dynamicBaseAPR * HALVING_RATE) / 100;
        dynamicBoostedAPR = (dynamicBoostedAPR * HALVING_RATE) / 100;

        // Ensure minimum APRs
        if (dynamicBaseAPR < 1) dynamicBaseAPR = 1;
        if (dynamicBoostedAPR < 2) dynamicBoostedAPR = 2;

        currentHalvingEpoch += 1;
        lastHalvingTime = block.timestamp;

        // Sync with governance ( TerraStakeToken syncs with staking and governance, here we mimic)
        _syncWithGovernance();

        emit HalvingTriggered(currentHalvingEpoch, lastHalvingTime);
        emit EmissionRateUpdated(dynamicBaseAPR);

        return currentHalvingEpoch;
    }

    /**
     * @notice Checks and applies halving if due
     * @dev Adapted to use TerraStakeToken’s timing logic
     * @return True if halving applied, false otherwise
     */
    function checkAndApplyHalving() public returns (bool) {
        if (block.timestamp < lastHalvingTime + halvingPeriod) return false;

        uint256 oldBaseAPR = dynamicBaseAPR;
        uint256 oldBoostedAPR = dynamicBoostedAPR;

        // Apply 35% reduction
        dynamicBaseAPR = (dynamicBaseAPR * HALVING_RATE) / 100;
        dynamicBoostedAPR = (dynamicBoostedAPR * HALVING_RATE) / 100;

        // Ensure minimum APRs
        if (dynamicBaseAPR < 1) dynamicBaseAPR = 1;
        if (dynamicBoostedAPR < 2) dynamicBoostedAPR = 2;

        currentHalvingEpoch += 1;
        lastHalvingTime = block.timestamp;

        _syncWithGovernance();

        emit HalvingApplied(
            currentHalvingEpoch,
            oldBaseAPR,
            dynamicBaseAPR,
            oldBoostedAPR,
            dynamicBoostedAPR
        );
        emit EmissionRateUpdated(dynamicBaseAPR);

        return true;
    }

    /**
     * @notice Syncs halving with governance contract
     * @dev Internal helper from original TerraStakeStaking, reused here
     */
    function _syncWithGovernance() internal {
        if (address(governanceContract) != address(0)) {
            try governanceContract.applyHalving(currentHalvingEpoch) {
            } catch {
                emit HalvingSyncFailed(address(governanceContract));
            }
        }
    }

    /**
     * @notice Gets halving details
     * @return period, lastTime, epoch, nextHalving
     */
    function getHalvingDetails() external view returns (
        uint256 period,
        uint256 lastTime,
        uint256 epoch,
        uint256 nextHalving
    ) {
        return (
            halvingPeriod,
            lastHalvingTime,
            currentHalvingEpoch,
            lastHalvingTime + halvingPeriod
        );
    }

    /**
     * @notice Sets the halving period
     * @param newPeriod New period in seconds
     */
    function setHalvingPeriod(uint256 newPeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newPeriod == 0) revert InvalidParameter("newPeriod", newPeriod);
        checkAndApplyHalving();
        halvingPeriod = newPeriod;
        emit HalvingPeriodUpdated(newPeriod);
    }

    // ============ LayerZero Cross-Chain Functions (Unchanged) ============

    function sendHalvingEpoch(uint256 epoch) external onlyRole(CROSS_CHAIN_RELAYER_ROLE) nonReentrant {
        require(epoch > lastSentEpoch, "Already sent this epoch");

        bytes memory payload = abi.encode(epoch, block.timestamp, dynamicBaseAPR, dynamicBoostedAPR);
        uint16 version = 1;
        uint256 gasLimit = 300000;

        bytes memory adapterParams = abi.encodePacked(version, gasLimit);
        
        try layerZeroEndpoint.send{value: msg.value}(
            targetChainId,
            abi.encodePacked(address(this)),
            payload,
            payable(msg.sender),
            address(0),
            adapterParams
        ) {
            lastSentEpoch = epoch;
            sentTimestamps[epoch] = block.timestamp;
            emit HalvingEpochSent(epoch, block.timestamp);
        } catch {
            emit RelayerFailureDetected(epoch, "Failed to send message");
        }
    }

    function receiveHalvingEpoch(uint256 epoch, uint256 sentTime, uint256 remoteBaseAPR, uint256 remoteBoostedAPR) 
        external 
        onlyRole(CROSS_CHAIN_RELAYER_ROLE) 
    {
        require(epoch > lastReceivedEpoch, "Already received this epoch");

        lastReceivedEpoch = epoch;
        receivedTimestamps[epoch] = block.timestamp;
        uint256 latency = block.timestamp - sentTime;

        if (epoch > currentHalvingEpoch) {
            dynamicBaseAPR = remoteBaseAPR;
            dynamicBoostedAPR = remoteBoostedAPR;
            currentHalvingEpoch = epoch;
            lastHalvingTime = block.timestamp; // Update to maintain consistency
        }

        emit HalvingEpochReceived(epoch, block.timestamp, latency);
    }

    function batchSendHalvingEpochs(uint256 startEpoch, uint256 count) external onlyRole(CROSS_CHAIN_RELAYER_ROLE) {
        for (uint256 i = 0; i < count; i++) {
            sendHalvingEpoch(startEpoch + i);
        }
    }

    function checkRelayerPerformance(uint256 epoch) external view returns (uint256 latency, string memory status) {
        if (receivedTimestamps[epoch] == 0) {
            return (0, "Not received");
        }

        latency = receivedTimestamps[epoch] - sentTimestamps[epoch];
        status = latency < 60 ? "Fast" : (latency < 180 ? "Delayed" : "Slow");
        return (latency, status);
    }

    function forceResync(uint256 epoch) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit RelayerFailureDetected(epoch, "Manual resync triggered");
        sendHalvingEpoch(epoch);
    }

    function externalHalvingSync(uint256 epoch, uint256 remoteTime) external onlyRole(DEFAULT_ADMIN_ROLE) {
        lastReceivedEpoch = epoch;
        receivedTimestamps[epoch] = block.timestamp;
        emit HalvingEpochReceived(epoch, block.timestamp, block.timestamp - remoteTime);
    }

    function syncCrossChain(uint256 _targetChainId) external returns (bool) {
        checkAndApplyHalving();
        targetChainId = uint16(_targetChainId);
        sendHalvingEpoch(currentHalvingEpoch);
        emit CrossChainSyncInitiated(targetChainId, currentHalvingEpoch);
        return true;
    }

    function syncCrossChain() external onlyRole(CROSS_CHAIN_RELAYER_ROLE) {
        uint256 epoch = currentHalvingEpoch;
        try layerZeroEndpoint.send{value: msg.value}(
            targetChainId,
            abi.encodePacked(address(this)),
            abi.encode(epoch, block.timestamp, dynamicBaseAPR, dynamicBoostedAPR),
            payable(msg.sender),
            address(0),
            abi.encodePacked(uint16(1), uint256(300000))
        ) {
            lastSentEpoch = epoch;
            emit HalvingEpochSent(epoch, block.timestamp);
        } catch {
            emit RelayerFailureDetected(epoch, "Failed to send message");
        }
    }

    function receiveHalvingState(
        uint256 sourceChainId,
        uint256 remoteEpoch,
        uint256 remoteBaseAPR,
        uint256 remoteBoostedAPR
    ) 
        external
        onlyRole(CROSS_CHAIN_RELAYER_ROLE)
    {
        if (remoteEpoch > currentHalvingEpoch) {
            uint256 oldBaseAPR = dynamicBaseAPR;
            uint256 oldBoostedAPR = dynamicBoostedAPR;
            
            currentHalvingEpoch = remoteEpoch;
            dynamicBaseAPR = remoteBaseAPR;
            dynamicBoostedAPR = remoteBoostedAPR;
            lastHalvingTime = block.timestamp; // Update to maintain consistency
            
            emit HalvingStateReceived(
                sourceChainId,
                remoteEpoch,
                oldBaseAPR,
                dynamicBaseAPR,
                oldBoostedAPR,
                dynamicBoostedAPR
            );
        }
    }

    // ============ Staking Operations (Unchanged) ============

    function stake(
        uint256 projectId,
        uint256 amount,
        uint256 duration,
        bool isLP,
        bool autoCompound,
        bool lockBoost
    )
        external
        nonReentrant
        whenNotPaused
    {
        checkAndApplyHalving();
        
        if (amount == 0) revert ZeroAmount();
        if (duration < MIN_STAKING_DURATION) revert InsufficientStakingDuration(MIN_STAKING_DURATION, duration);
        if (!projectsContract.projectExists(projectId)) revert ProjectDoesNotExist(projectId);
        if (lockBoost && duration < LOCK_BOOST_DURATION) revert InsufficientStakingDuration(LOCK_BOOST_DURATION, duration);

        bool hasNFTBoost = nftContract.balanceOf(msg.sender, 1) > 0;
        StakingPosition storage position = _stakingPositions[msg.sender][projectId];

        if (position.amount > 0) {
            _claimRewards(msg.sender, projectId);
        } else {
            position.stakingStart = block.timestamp;
            position.projectId = projectId;
        }

        position.amount += amount;
        position.lastCheckpoint = block.timestamp;
        position.duration = duration;
        position.isLPStaker = isLP;
        position.hasNFTBoost = hasNFTBoost;
        position.autoCompounding = autoCompound;
        position.isLocked = lockBoost;

        _stakedProjects[msg.sender].push(projectId);
        _totalStaked += amount;
        _stakingBalance[msg.sender] += amount;

        if (_stakingBalance[msg.sender] >= GOVERNANCE_THRESHOLD && !_governanceViolators[msg.sender]) {
            _governanceVotes[msg.sender] = _stakingBalance[msg.sender];
            emit GovernanceVotesUpdated(msg.sender, _governanceVotes[msg.sender]);
        }

        if (!stakingToken.transferFrom(msg.sender, address(this), amount)) {
            emit TransferFailedEvent(address(stakingToken), msg.sender, address(this), amount);
            revert TransferFailed(address(stakingToken), msg.sender, address(this), amount);
        }

        projectsContract.incrementStakerCount(projectId);

        if (_stakingBalance[msg.sender] >= validatorThreshold && !_validators[msg.sender]) {
            _validators[msg.sender] = true;
            emit ValidatorStatusChanged(msg.sender, true);
        }

        if (!_isActiveStaker[msg.sender]) {
            _isActiveStaker[msg.sender] = true;
            _activeStakers.push(msg.sender);
        }
        emit Staked(msg.sender, projectId, amount, duration, block.timestamp, position.amount);
    }

    function batchStake(
        uint256[] calldata projectIds,
        uint256[] calldata amounts,
        uint256[] calldata durations,
        bool[] calldata isLP,
        bool[] calldata autoCompound,
        bool[] calldata lockBoosts
    )
        external
        nonReentrant
        whenNotPaused
    {
        checkAndApplyHalving();
        
        uint256 length = projectIds.length;
        if (length == 0) revert InvalidParameter("projectIds", 0);
        if (amounts.length != length || durations.length != length || 
            isLP.length != length || autoCompound.length != length || lockBoosts.length != length) {
            revert InvalidParameter("arrayLengths", length);
        }
        if (length > 50) revert InvalidParameter("batchSize", length);

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < length; i++) {
            if (amounts[i] == 0) revert ZeroAmount();
            totalAmount += amounts[i];
        }

        if (!stakingToken.transferFrom(msg.sender, address(this), totalAmount)) {
            emit TransferFailedEvent(address(stakingToken), msg.sender, address(this), totalAmount);
            revert TransferFailed(address(stakingToken), msg.sender, address(this), totalAmount);
        }

        bool hasNFTBoost = nftContract.balanceOf(msg.sender, 1) > 0;

        for (uint256 i = 0; i < length; i++) {
            if (durations[i] < MIN_STAKING_DURATION) {
                revert InsufficientStakingDuration(MIN_STAKING_DURATION, durations[i]);
            }
            if (lockBoosts[i] && durations[i] < LOCK_BOOST_DURATION) {
                revert InsufficientStakingDuration(LOCK_BOOST_DURATION, durations[i]);
            }
            if (!projectsContract.projectExists(projectIds[i])) {
                revert ProjectDoesNotExist(projectIds[i]);
            }

            StakingPosition storage position = _stakingPositions[msg.sender][projectIds[i]];
            if (position.amount > 0) {
                _claimRewards(msg.sender, projectIds[i]);
            } else {
                position.stakingStart = block.timestamp;
                position.projectId = projectIds[i];
            }

            position.amount += amounts[i];
            position.lastCheckpoint = block.timestamp;
            position.duration = durations[i];
            position.isLPStaker = isLP[i];
            position.hasNFTBoost = hasNFTBoost;
            position.autoCompounding = autoCompound[i];
            position.isLocked = lockBoosts[i];

            _stakedProjects[msg.sender].push(projectIds[i]);
            _totalStaked += amounts[i];
            _stakingBalance[msg.sender] += amounts[i];

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

        if (_stakingBalance[msg.sender] >= GOVERNANCE_THRESHOLD && !_governanceViolators[msg.sender]) {
            _governanceVotes[msg.sender] = _stakingBalance[msg.sender];
            emit GovernanceVotesUpdated(msg.sender, _governanceVotes[msg.sender]);
        }

        if (_stakingBalance[msg.sender] >= validatorThreshold && !_validators[msg.sender]) {
            _validators[msg.sender] = true;
            emit ValidatorStatusChanged(msg.sender, true);
        }

        if (!_isActiveStaker[msg.sender]) {
            _isActiveStaker[msg.sender] = true;
            _activeStakers.push(msg.sender);
        }
    }

    function unstake(uint256 projectId) external nonReentrant {
        checkAndApplyHalving();
        
        StakingPosition storage position = _stakingPositions[msg.sender][projectId];
        if (position.amount == 0) revert NoActiveStakingPosition(msg.sender, projectId);
        _claimRewards(msg.sender, projectId);

        uint256 amount = position.amount;
        uint256 stakingTime = block.timestamp - position.stakingStart;
        uint256 penalty = 0;

        if (stakingTime < position.duration) {
            uint256 remainingTime = position.duration - stakingTime;
            uint256 penaltyPercent = BASE_PENALTY_PERCENT +
                ((remainingTime * (MAX_PENALTY_PERCENT - BASE_PENALTY_PERCENT)) / position.duration);
            penalty = (amount * penaltyPercent) / 100;
            _handlePenalty(msg.sender, projectId, penalty);
        }

        _totalStaked -= amount;
        _stakingBalance[msg.sender] -= amount;

        if (_stakingBalance[msg.sender] < GOVERNANCE_THRESHOLD) {
            _governanceVotes[msg.sender] = 0;
            emit GovernanceVotesUpdated(msg.sender, 0);
        } else if (!_governanceViolators[msg.sender]) {
            _governanceVotes[msg.sender] = _stakingBalance[msg.sender];
            emit GovernanceVotesUpdated(msg.sender, _governanceVotes[msg.sender]);
        }

        projectsContract.decrementStakerCount(projectId);
        delete _stakingPositions[msg.sender][projectId];

        uint256[] storage userProjects = _stakedProjects[msg.sender];
        for (uint256 i = 0; i < userProjects.length; i++) {
            if (userProjects[i] == projectId) {
                userProjects[i] = userProjects[userProjects.length - 1];
                userProjects.pop();
                break;
            }
        }

        if (_validators[msg.sender] && _stakingBalance[msg.sender] < validatorThreshold) {
            _validators[msg.sender] = false;
            emit ValidatorStatusChanged(msg.sender, false);
        }

        uint256 transferAmount = amount - penalty;
        if (!stakingToken.transfer(msg.sender, transferAmount)) {
            emit TransferFailedEvent(address(stakingToken), address(this), msg.sender, transferAmount);
            revert TransferFailed(address(stakingToken), address(this), msg.sender, transferAmount);
        }

        if (_stakingBalance[msg.sender] == 0) {
            _isActiveStaker[msg.sender] = false;
            _removeInactiveStaker(msg.sender);
        }
        emit Unstaked(msg.sender, projectId, transferAmount, penalty, block.timestamp);
    }

    function batchUnstake(uint256[] calldata projectIds) external nonReentrant whenNotPaused {
        checkAndApplyHalving();
        
        uint256 length = projectIds.length;
        if (length == 0) revert InvalidParameter("projectIds", 0);
        if (length > 50) revert InvalidParameter("batchSize", length);

        uint256 totalAmount = 0;
        uint256 totalPenalty = 0;
        uint256 totalToRedistribute = 0;
        uint256 totalToBurn = 0;
        uint256 totalToLiquidity = 0;

        for (uint256 i = 0; i < length; i++) {
            uint256 projectId = projectIds[i];
            StakingPosition storage position = _stakingPositions[msg.sender][projectId];
            if (position.amount == 0) revert NoActiveStakingPosition(msg.sender, projectId);
            _claimRewards(msg.sender, projectId);

            uint256 posAmount = position.amount;
            uint256 stakingEnd = position.stakingStart + position.duration;
            uint256 penalty = 0;
            uint256 toRedistribute = 0;
            uint256 toBurn = 0;
            uint256 toLiquidity = 0;

            if (block.timestamp < stakingEnd) {
                uint256 remainingTime = stakingEnd - block.timestamp;
                uint256 penaltyPercent = BASE_PENALTY_PERCENT +
                    ((remainingTime * (MAX_PENALTY_PERCENT - BASE_PENALTY_PERCENT)) / position.duration);
                penalty = (posAmount * penaltyPercent) / 100;
                toRedistribute = penalty / 2;
                toBurn = penalty / 4;
                toLiquidity = penalty - toRedistribute - toBurn;

                _penaltyHistory[msg.sender].push(PenaltyEvent({
                    projectId: projectId,
                    timestamp: block.timestamp,
                    totalPenalty: penalty,
                    redistributed: toRedistribute,
                    burned: toBurn,
                    toLiquidity: toLiquidity
                }));
            }

            totalAmount += (posAmount - penalty);
            totalPenalty += penalty;
            totalToRedistribute += toRedistribute;
            totalToBurn += toBurn;
            totalToLiquidity += toLiquidity;

            _totalStaked -= posAmount;
            _stakingBalance[msg.sender] -= posAmount;
            projectsContract.decrementStakerCount(projectId);
            delete _stakingPositions[msg.sender][projectId];

            uint256[] storage userProjects = _stakedProjects[msg.sender];
            for (uint256 j = 0; j < userProjects.length; j++) {
                if (userProjects[j] == projectId) {
                    userProjects[j] = userProjects[userProjects.length - 1];
                    userProjects.pop();
                    break;
                }
            }

            emit Unstaked(msg.sender, projectId, posAmount - penalty, penalty, block.timestamp);
        }

        if (_stakingBalance[msg.sender] < GOVERNANCE_THRESHOLD) {
            _governanceVotes[msg.sender] = 0;
            emit GovernanceVotesUpdated(msg.sender, 0);
        } else if (!_governanceViolators[msg.sender]) {
            _governanceVotes[msg.sender] = _stakingBalance[msg.sender];
            emit GovernanceVotesUpdated(msg.sender, _governanceVotes[msg.sender]);
        }

        if (_validators[msg.sender] && _stakingBalance[msg.sender] < validatorThreshold) {
            _validators[msg.sender] = false;
            emit ValidatorStatusChanged(msg.sender, false);
        }

        if (totalAmount > 0) {
            if (!stakingToken.transfer(msg.sender, totalAmount)) {
                emit TransferFailedEvent(address(stakingToken), address(this), msg.sender, totalAmount);
                revert TransferFailed(address(stakingToken), address(this), msg.sender, totalAmount);
            }
        }

        if (totalPenalty > 0) {
            if (totalToBurn > 0) {
                if (!stakingToken.transfer(BURN_ADDRESS, totalToBurn)) {
                    emit TransferFailedEvent(address(stakingToken), address(this), BURN_ADDRESS, totalToBurn);
                    revert TransferFailed(address(stakingToken), address(this), BURN_ADDRESS, totalToBurn);
                }
                emit SlashedTokensBurned(totalToBurn);
            }
            if (totalToRedistribute > 0) {
                if (!stakingToken.transfer(address(rewardDistributor), totalToRedistribute)) {
                    emit TransferFailedEvent(address(stakingToken), address(this), address(rewardDistributor), totalToRedistribute);
                    revert TransferFailed(address(stakingToken), address(this), address(rewardDistributor), totalToRedistribute);
                }
                rewardDistributor.addPenaltyRewards(totalToRedistribute);
                emit SlashedTokensDistributed(totalToRedistribute);
            }
            if (totalToLiquidity > 0) {
                if (!stakingToken.transfer(liquidityPool, totalToLiquidity)) {
                    emit TransferFailedEvent(address(stakingToken), address(this), liquidityPool, totalToLiquidity);
                    revert TransferFailed(address(stakingToken), address(this), liquidityPool, totalToLiquidity);
                }
                emit LiquidityInjected(liquidityPool, totalToLiquidity, block.timestamp);
            }
            emit PenaltyApplied(msg.sender, 0, totalPenalty, totalToBurn, totalToRedistribute, totalToLiquidity);
        }

        if (_stakingBalance[msg.sender] == 0) {
            _isActiveStaker[msg.sender] = false;
            _removeInactiveStaker(msg.sender);
        }
    }

    function finalizeProjectStaking(uint256 projectId, bool isCompleted) external onlyRole(GOVERNANCE_ROLE) {
        checkAndApplyHalving();
        
        if (!projectsContract.projectExists(projectId)) revert ProjectDoesNotExist(projectId);

        address[] memory stakers = getActiveStakers();
        for (uint256 i = 0; i < stakers.length; i++) {
            StakingPosition storage position = _stakingPositions[stakers[i]][projectId];
            if (position.amount > 0) {
                _claimRewards(stakers[i], projectId);
            }
        }

        emit isCompleted ? ProjectStakingCompleted(projectId, block.timestamp) : 
            ProjectStakingCancelled(projectId, block.timestamp);
    }

    function claimRewards(uint256 projectId) external nonReentrant {
        checkAndApplyHalving();
        _claimRewards(msg.sender, projectId);
    }

    function _claimRewards(address user, uint256 projectId) internal {
        StakingPosition storage position = _stakingPositions[user][projectId];
        if (position.amount == 0) revert NoActiveStakingPosition(user, projectId);
        uint256 reward = calculateRewards(user, projectId);
        if (reward == 0) {
            position.lastCheckpoint = block.timestamp;
            return;
        }

        if (position.autoCompounding) {
            uint256 compoundAmount = (reward * 20) / 100;
            position.amount += compoundAmount;
            _totalStaked += compoundAmount;
            _stakingBalance[user] += compoundAmount;

            if (_stakingBalance[user] >= GOVERNANCE_THRESHOLD && !_governanceViolators[user]) {
                _governanceVotes[user] = _stakingBalance[user];
                emit GovernanceVotesUpdated(user, _governanceVotes[user]);
            }
            reward -= compoundAmount;

            emit RewardCompounded(user, projectId, compoundAmount, block.timestamp);
        }

        if (autoLiquidityEnabled) {
            uint256 liquidityAmount = (reward * liquidityInjectionRate) / 100;
            if (liquidityAmount > 0) {
                reward -= liquidityAmount;
                if (!stakingToken.transfer(liquidityPool, liquidityAmount)) {
                    emit TransferFailedEvent(address(stakingToken), address(this), liquidityPool, liquidityAmount);
                    revert TransferFailed(address(stakingToken), address(this), liquidityPool, liquidityAmount);
                }
                emit LiquidityInjected(liquidityPool, liquidityAmount, block.timestamp);
            }
        }

        _distributeValidatorRewards(reward);
        position.lastCheckpoint = block.timestamp;

        if (reward > 0) {
            rewardDistributor.distributeReward(user, reward);
            emit RewardClaimed(user, projectId, reward, block.timestamp);
        }
    }

    function _distributeValidatorRewards(uint256 rewardAmount) internal {
        uint256 validatorShare = (rewardAmount * 5) / 100;
        if (validatorShare > 0) {
            validatorRewardPool += validatorShare;
            emit ValidatorRewardsAccumulated(validatorShare, validatorRewardPool);
        }
    }

    function _handlePenalty(address user, uint256 projectId, uint256 penaltyAmount) internal {
        uint256 burnAmount = (penaltyAmount * 40) / 100;
        uint256 redistributeAmount = (penaltyAmount * 40) / 100;
        uint256 liquidityAmount = penaltyAmount - burnAmount - redistributeAmount;

        if (!stakingToken.transfer(BURN_ADDRESS, burnAmount)) {
            emit TransferFailedEvent(address(stakingToken), address(this), BURN_ADDRESS, burnAmount);
            revert TransferFailed(address(stakingToken), address(this), BURN_ADDRESS, burnAmount);
        }
        if (!stakingToken.transfer(address(rewardDistributor), redistributeAmount)) {
            emit TransferFailedEvent(address(stakingToken), address(this), address(rewardDistributor), redistributeAmount);
            revert TransferFailed(address(stakingToken), address(this), address(rewardDistributor), redistributeAmount);
        }
        if (!stakingToken.transfer(liquidityPool, liquidityAmount)) {
            emit TransferFailedEvent(address(stakingToken), address(this), liquidityPool, liquidityAmount);
            revert TransferFailed(address(stakingToken), address(this), liquidityPool, liquidityAmount);
        }

        _penaltyHistory[user].push(PenaltyEvent({
            projectId: projectId,
            timestamp: block.timestamp,
            totalPenalty: penaltyAmount,
            redistributed: redistributeAmount,
            burned: burnAmount,
            toLiquidity: liquidityAmount
        }));

        emit PenaltyApplied(user, projectId, penaltyAmount, burnAmount, redistributeAmount, liquidityAmount);
    }

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

    // ============ Validator Operations (Unchanged) ============

    function becomeValidator() external nonReentrant whenNotPaused {
        checkAndApplyHalving();
        
        if (_validators[msg.sender]) revert AlreadyValidator(msg.sender);
        if (_stakingBalance[msg.sender] < validatorThreshold) {
            revert InvalidParameter("stakingBalance", _stakingBalance[msg.sender]);
        }
        _validators[msg.sender] = true;
        _validatorCommission[msg.sender] = 500;
        emit ValidatorAdded(msg.sender, block.timestamp);
    }

    function claimValidatorRewards() external nonReentrant {
        checkAndApplyHalving();
        
        if (!_validators[msg.sender]) revert NotValidator(msg.sender);
        
        uint256 validatorCount = 0;
        for (uint256 i = 0; i < _activeStakers.length; i++) {
            if (_validators[_activeStakers[i]]) validatorCount++;
        }
        
        if (validatorCount == 0) return;
        
        uint256 rewardPerValidator = validatorRewardPool / validatorCount;
        validatorRewardPool = 0;

        rewardDistributor.distributeReward(msg.sender, rewardPerValidator);
        emit ValidatorRewardsDistributed(msg.sender, rewardPerValidator);
    }

    function updateValidatorCommission(uint256 newCommissionRate) external {
        checkAndApplyHalving();
        
        if (!_validators[msg.sender]) revert NotValidator(msg.sender);
        if (newCommissionRate > 2000) revert RateTooHigh(newCommissionRate, 2000);
        _validatorCommission[msg.sender] = newCommissionRate;
        emit ValidatorCommissionUpdated(msg.sender, newCommissionRate);
    }

    // ============ Governance Operations (Unchanged) ============

    function voteOnProposal(uint256 proposalId, bool support) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        checkAndApplyHalving();
        
        if (_governanceViolators[msg.sender]) revert GovernanceViolation(msg.sender);
        uint256 votingPower = _governanceVotes[msg.sender];
        if (votingPower == 0) revert InvalidParameter("votingPower", votingPower);
        governanceContract.recordVote(proposalId, msg.sender, votingPower, support);
        emit ProposalVoted(proposalId, msg.sender, votingPower, support);
    }

    function createProposal(
        string calldata description,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas
    )
        external
        nonReentrant
        whenNotPaused
    {
        checkAndApplyHalving();
        
        if (_governanceViolators[msg.sender]) revert GovernanceViolation(msg.sender);
        uint256 votingPower = _governanceVotes[msg.sender];
        if (votingPower < GOVERNANCE_THRESHOLD) revert InvalidParameter("votingPower", votingPower);
        proposalNonce++;
        uint256 proposalId = governanceContract.createProposal(
            proposalNonce,
            msg.sender,
            description,
            targets,
            values,
            calldatas
        );
        emit GovernanceProposalCreated(proposalId, msg.sender, description);
    }

    function markGovernanceViolator(address violator) external onlyRole(GOVERNANCE_ROLE) {
        checkAndApplyHalving();
        
        _governanceViolators[violator] = true;
        _governanceVotes[violator] = 0;
        emit GovernanceViolatorMarked(violator, block.timestamp);
        emit GovernanceVotesUpdated(violator, 0);
    }

    function slashGovernanceVote(address user) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
        returns (uint256) 
    {
        checkAndApplyHalving();
        
        if (_governanceViolators[user]) return 0;
        
        uint256 slashedAmount = _governanceVotes[user];
        if (slashedAmount == 0) return 0;
        
        _governanceViolators[user] = true;
        _governanceVotes[user] = 0;
        
        emit GovernanceViolatorMarked(user, block.timestamp);
        emit GovernanceVotesUpdated(user, 0);
        return slashedAmount;
    }

    // ============ Administrative & Emergency (Unchanged) ============

    function updateTiers(
        uint256[] calldata minDurations,
        uint256[] calldata multipliers,
        bool[] calldata votingRights
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        checkAndApplyHalving();
        
        if (minDurations.length != multipliers.length || minDurations.length != votingRights.length) {
            revert InvalidTierConfiguration();
        }
        delete _tiers;

        for (uint256 i = 0; i < minDurations.length; i++) {
            if (minDurations[i] < MIN_STAKING_DURATION) {
                revert InsufficientStakingDuration(MIN_STAKING_DURATION, minDurations[i]);
            }
            _tiers.push(StakingTier(minDurations[i], multipliers[i], votingRights[i]));
        }
        emit TiersUpdated(minDurations, multipliers, votingRights);
    }

    function setLiquidityInjectionRate(uint256 newRate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        checkAndApplyHalving();
        
        if (newRate > MAX_LIQUIDITY_RATE) revert RateTooHigh(newRate, MAX_LIQUIDITY_RATE);
        liquidityInjectionRate = newRate;
        emit LiquidityInjectionRateUpdated(newRate);
    }

    function toggleAutoLiquidity(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        checkAndApplyHalving();
        
        autoLiquidityEnabled = enabled;
        emit AutoLiquidityToggled(enabled);
    }

    function setValidatorThreshold(uint256 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        checkAndApplyHalving();
        
        if (newThreshold == 0) revert InvalidParameter("newThreshold", newThreshold);
        validatorThreshold = newThreshold;
        emit ValidatorThresholdUpdated(newThreshold);
    }

    function setRewardDistributor(address newDistributor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        checkAndApplyHalving();
        
        if (newDistributor == address(0)) revert InvalidAddress("newDistributor", newDistributor);
        rewardDistributor = ITerraStakeRewardDistributor(newDistributor);
        emit RewardDistributorUpdated(newDistributor);
    }

    function setLiquidityPool(address newPool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        checkAndApplyHalving();
        
        if (newPool == address(0)) revert InvalidAddress("newPool", newPool);
        liquidityPool = newPool;
        emit LiquidityPoolUpdated(newPool);
    }

    function setSlashingContract(address newSlashingContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        checkAndApplyHalving();
        
        if (newSlashingContract == address(0)) revert InvalidAddress("newSlashingContract", newSlashingContract);
        slashingContract = ITerraStakeSlashing(newSlashingContract);
        emit SlashingContractUpdated(newSlashingContract);
    }

    function setGovernanceQuorum(uint256 newQuorum) external onlyRole(DEFAULT_ADMIN_ROLE) {
        checkAndApplyHalving();
        
        governanceQuorum = newQuorum;
        emit GovernanceQuorumUpdated(newQuorum);
    }

    function toggleDynamicRewards(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        checkAndApplyHalving();
        
        dynamicRewardsEnabled = enabled;
        emit DynamicRewardsToggled(enabled);
    }

    function pause() external onlyRole(EMERGENCY_ROLE) {
        checkAndApplyHalving();
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        checkAndApplyHalving();
        _unpause();
    }

    function recoverERC20(address token) external onlyRole(EMERGENCY_ROLE) returns (bool) {
        checkAndApplyHalving();
        
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (token == address(stakingToken)) {
            amount = amount - _totalStaked;
        }
        if (!IERC20(token).transfer(msg.sender, amount)) {
            emit TransferFailedEvent(token, address(this), msg.sender, amount);
            revert TransferFailed(token, address(this), msg.sender, amount);
        }
        emit TokenRecovered(token, amount, msg.sender);
        return true;
    }

    // ============ Slashing (Unchanged) ============

    function slash(address validator, uint256 amount) external onlyRole(SLASHER_ROLE) returns (bool) {
        checkAndApplyHalving();
        
        if (!_validators[validator]) revert NotValidator(validator);
        if (amount == 0) revert ZeroAmount();
        uint256 userBalance = _stakingBalance[validator];
        if (userBalance < amount) amount = userBalance;
        if (amount == 0) return false;

        _stakingBalance[validator] -= amount;
        _totalStaked -= amount;

        if (_stakingBalance[validator] < validatorThreshold) {
            _validators[validator] = false;
            emit ValidatorStatusChanged(validator, false);
        }

        _handlePenalty(validator, 0, amount);
        emit Slashed(validator, amount, block.timestamp);
        return true;
    }

    function distributeSlashedTokens(uint256 amount) external onlyRole(SLASHER_ROLE) {
        checkAndApplyHalving();
        
        if (!stakingToken.approve(address(rewardDistributor), amount)) {
            emit TransferFailedEvent(address(stakingToken), address(this), address(rewardDistributor), amount);
            revert TransferFailed(address(stakingToken), address(this), address(rewardDistributor), amount);
        }
        rewardDistributor.addPenaltyRewards(amount);
        emit SlashedTokensDistributed(amount);
    }

    // ============ View Functions (Unchanged) ============

    function calculateRewards(address user) external view returns (uint256 totalRewards) {
        uint256[] memory projectIds = _stakedProjects[user];
        for (uint256 i = 0; i < projectIds.length; i++) {
            totalRewards += calculateRewards(user, projectIds[i]);
        }
        return totalRewards;
    }

    function calculateRewards(address user, uint256 projectId) public view returns (uint256) {
        StakingPosition storage position = _stakingPositions[user][projectId];
        if (position.amount == 0 || block.timestamp == position.lastCheckpoint) return 0;

        uint256 stakingTime = block.timestamp - position.lastCheckpoint;
        uint256 tierId = getApplicableTier(position.duration);
        uint256 tierMult = _tiers[tierId].multiplier;
        uint256 baseRate = (_totalStaked < LOW_STAKING_THRESHOLD) ? dynamicBoostedAPR : dynamicBaseAPR;

        if (position.hasNFTBoost) baseRate += NFT_APR_BOOST;
        if (position.isLPStaker) baseRate += LP_APR_BOOST;
        if (position.isLocked) baseRate += LOCK_BOOST_APR;

        uint256 effectiveRate = (baseRate * tierMult) / 100;
        return (position.amount * effectiveRate * stakingTime) / (100 * 365 days);
    }

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
        uint256 projectCount = projectsContract.getProjectCount();
        uint256 count = 0;

        for (uint256 i = 1; i <= projectCount; i++) {
            if (_stakingPositions[user][i].amount > 0) count++;
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

    function totalStakedTokens() external view returns (uint256) {
        return _totalStaked;
    }

    function getValidatorRewardPool() external view returns (uint256) {
        return validatorRewardPool;
    }

    function getAllTiers() external view returns (StakingTier[] memory) {
        return _tiers;
    }

    function getTopStakers(uint256 limit) external view returns (address[] memory stakers, uint256[] memory amounts) {
        uint256 stakerCount = _activeStakers.length;
        if (limit > stakerCount) limit = stakerCount;
        if (limit == 0) return (new address[](0), new uint256[](0));

        stakers = new address[](limit);
        amounts = new uint256[](limit);
        address[] memory tempStakers = new address[](stakerCount);
        uint256[] memory tempAmounts = new uint256[](stakerCount);

        for (uint256 i = 0; i < stakerCount; i++) {
            tempStakers[i] = _activeStakers[i];
            tempAmounts[i] = _stakingBalance[_activeStakers[i]];
        }

        for (uint256 i = 0; i < limit; i++) {
            uint256 maxIndex = i;
            for (uint256 j = i + 1; j < stakerCount; j++) {
                if (tempAmounts[j] > tempAmounts[maxIndex]) maxIndex = j;
            }
            if (maxIndex != i) {
                uint256 tempAmount = tempAmounts[i];
                tempAmounts[i] = tempAmounts[maxIndex];
                tempAmounts[maxIndex] = tempAmount;
                address tempAddr = tempStakers[i];
                tempStakers[i] = tempStakers[maxIndex];
                tempStakers[maxIndex] = tempAddr;
            }
            stakers[i] = tempStakers[i];
            amounts[i] = tempAmounts[i];
        }
        return (stakers, amounts);
    }

    function getValidatorCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < _activeStakers.length; i++) {
            if (_validators[_activeStakers[i]]) count++;
        }
        return count;
    }

    function version() external pure returns (string memory) {
        return "1.0.1-enhanced";
    }

    function adjustRewardRates() external {
        checkAndApplyHalving();
        
        if (!dynamicRewardsEnabled) return;
        if (block.timestamp - lastRewardAdjustmentTime < 1 days) return;

        uint256 oldBaseAPR = dynamicBaseAPR;
        
        if (_totalStaked < LOW_STAKING_THRESHOLD / 10) {
            dynamicBaseAPR = 15;
            dynamicBoostedAPR = 30;
        } else if (_totalStaked < LOW_STAKING_THRESHOLD / 2) {
            dynamicBaseAPR = 12;
            dynamicBoostedAPR = 24;
        } else if (_totalStaked < LOW_STAKING_THRESHOLD) {
            dynamicBaseAPR = BASE_APR;
            dynamicBoostedAPR = BOOSTED_APR;
        } else {
            dynamicBaseAPR = 8;
            dynamicBoostedAPR = 16;
        }

        lastRewardAdjustmentTime = block.timestamp;
        emit RewardRateAdjusted(oldBaseAPR, dynamicBaseAPR);
    }

    function getActiveStakers() public view returns (address[] memory) {
        return _activeStakers;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlEnumerableUpgradeable, ERC165Upgradeable)
        returns (bool)
    {
        return interfaceId == type(ITerraStakeStaking).interfaceId || 
               super.supportsInterface(interfaceId);
    }

    // ============ Events (Updated for Halving) ============
    event HalvingApplied(
        uint256 epoch,
        uint256 oldBaseAPR,
        uint256 newBaseAPR,
        uint256 oldBoostedAPR,
        uint256 newBoostedAPR
    );
    event HalvingSyncFailed(address targetContract);
    event HalvingPeriodUpdated(uint256 newPeriod);
    event CrossChainSyncInitiated(uint256 targetChainId, uint256 currentEpoch);
    event HalvingStateReceived(
        uint256 sourceChainId,
        uint256 remoteEpoch,
        uint256 oldBaseAPR,
        uint256 newBaseAPR,
        uint256 oldBoostedAPR,
        uint256 newBoostedAPR
    );
    event HalvingEpochSent(uint256 epoch, uint256 timestamp);
    event HalvingEpochReceived(uint256 epoch, uint256 timestamp, uint256 latency);
    event RelayerFailureDetected(uint256 epoch, string reason);
    event Staked(address indexed user, uint256 projectId, uint256 amount, uint256 duration, uint256 timestamp, uint256 newBalance);
    event Unstaked(address indexed user, uint256 projectId, uint256 amount, uint256 penalty, uint256 timestamp);
    event RewardClaimed(address indexed user, uint256 projectId, uint256 amount, uint256 timestamp);
    event RewardCompounded(address indexed user, uint256 projectId, uint256 amount, uint256 timestamp);
    event PenaltyApplied(address indexed user, uint256 projectId, uint256 totalPenalty, uint256 burned, uint256 redistributed, uint256 toLiquidity);
    event LiquidityInjected(address indexed pool, uint256 amount, uint256 timestamp);
    event ValidatorAdded(address indexed validator, uint256 timestamp);
    event ValidatorStatusChanged(address indexed validator, bool status);
    event ValidatorRewardsDistributed(address indexed validator, uint256 amount);
    event ValidatorCommissionUpdated(address indexed validator, uint256 newRate);
    event ProposalVoted(uint256 proposalId, address indexed voter, uint256 votingPower, bool support);
    event GovernanceProposalCreated(uint256 proposalId, address indexed proposer, string description);
    event GovernanceViolatorMarked(address indexed violator, uint256 timestamp);
    event GovernanceVotesUpdated(address indexed user, uint256 newVotes);
    event TiersUpdated(uint256[] minDurations, uint256[] multipliers, bool[] votingRights);
    event LiquidityInjectionRateUpdated(uint256 newRate);
    event AutoLiquidityToggled(bool enabled);
    event ValidatorThresholdUpdated(uint256 newThreshold);
    event RewardDistributorUpdated(address newDistributor);
    event LiquidityPoolUpdated(address newPool);
    event SlashingContractUpdated(address newSlashingContract);
    event GovernanceQuorumUpdated(uint256 newQuorum);
    event DynamicRewardsToggled(bool enabled);
    event TokenRecovered(address indexed token, uint256 amount, address indexed to);
    event Slashed(address indexed validator, uint256 amount, uint256 timestamp);
    event SlashedTokensDistributed(uint256 amount);
    event SlashedTokensBurned(uint256 amount);
    event ValidatorRewardsAccumulated(uint256 amount, uint256 newPool);
    event ProjectStakingCompleted(uint256 projectId, uint256 timestamp);
    event ProjectStakingCancelled(uint256 projectId, uint256 timestamp);
    event RewardRateAdjusted(uint256 oldBaseAPR, uint256 newBaseAPR);
    event TransferFailedEvent(address token, address from, address to, uint256 amount);
    // Added from TerraStakeToken for halving consistency
    event HalvingTriggered(uint256 epochNumber, uint256 timestamp);
    event EmissionRateUpdated(uint256 newRate);
}