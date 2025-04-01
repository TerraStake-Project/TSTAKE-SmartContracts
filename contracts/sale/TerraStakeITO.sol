// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

// OpenZeppelin
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// Uniswap V4
import "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import "@uniswap/v4-core/contracts/types/PoolKey.sol";
import "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import "@uniswap/v4-core/contracts/libraries/LiquidityAmounts.sol";

// API3
import "@api3/airnode-protocol/contracts/rrp/requesters/RrpRequesterV0.sol";

// Chainlink CCIP
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";

// Custom
import "../interfaces/IAntiBot.sol";

interface IBurnableERC20 is IERC20Upgradeable {
    function burn(uint256 amount) external;
    function totalSupply() external view returns (uint256);
}

contract TerraStakeITO is 
    AccessControlEnumerableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable, 
    CCIPReceiver,
    RrpRequesterV0,
    IHooks 
{
    using PoolId for PoolKey;
    using CurrencyLibrary for Currency;

    // ============ Constants ============
    uint24 public constant POOL_FEE = 3000;
    uint256 public constant MAX_TOKENS_FOR_ITO = 300_000_000 * 10**18;
    uint256 public constant DEFAULT_MIN_PURCHASE_USDC = 1_000 * 10**6;
    uint256 public constant DEFAULT_MAX_PURCHASE_USDC = 150_000 * 10**6;
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant MULTISIG_ROLE = keccak256("MULTISIG_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // Vesting constants
    uint256 public constant SEED_CLIFF_PERIOD = 90 days;
    uint256 public constant PRIVATE_CLIFF_PERIOD = 60 days;
    uint256 public constant PUBLIC_CLIFF_PERIOD = 30 days;
    uint256 public constant SEED_VESTING_DURATION = 730 days; // 24 months
    uint256 public constant PRIVATE_VESTING_DURATION = 548 days; // 18 months
    uint256 public constant PUBLIC_VESTING_DURATION = 365 days; // 12 months
    uint256 public constant SEED_INITIAL_UNLOCK = 0;
    uint256 public constant PRIVATE_INITIAL_UNLOCK = 500; // 5% in basis points
    uint256 public constant PUBLIC_INITIAL_UNLOCK = 1000; // 10% in basis points

    // ============ External contracts ============
    IAntiBot public antiBot;
    IBurnableERC20 public tStakeToken;
    IERC20Upgradeable public usdcToken;
    IPoolManager public poolManager;
    IRouterClient public ccipRouter;

    // ============ Pool configuration ============
    PoolKey public poolKey;
    bytes32 public poolId;
    bool public poolInitialized;

    // ============ ITO state ============
    uint256 public startingPrice;
    uint256 public endingPrice;
    uint256 public priceDuration;
    uint256 public tokensSold;
    uint256 public accumulatedUSDC;
    uint256 public itoStartTime;
    uint256 public itoEndTime;
    uint256 public minPurchaseUSDC;
    uint256 public maxPurchaseUSDC;
    bool public purchasesPaused;

    // ============ Addresses ============
    address public treasuryMultiSig;
    address public stakingRewards;
    address public liquidityPool;
    address public api3Airnode;
    bytes32 public api3EndpointId;
    address public api3SponsorWallet;

    // ============ Mappings ============
    mapping(address => uint256) public purchasedAmounts;
    mapping(address => bool) public blacklist;
    mapping(uint256 => uint256) public positionIds;
    mapping(bytes32 => bool) public pendingRequests;
    mapping(bytes32 => bool) public processedCcipMessages;
    mapping(uint64 => bool) public trustedSourceChains;

    // ============ Vesting ============
    enum ParticipantTier { Seed, Private, Public }
    enum VestingType { Treasury, Staking, Liquidity }
    enum ITOState { NotStarted, Active, Ended }
    
    struct VestingSchedule {
        uint256 totalAmount;
        uint256 initialUnlock;
        uint256 cliffPeriod;
        uint256 vestingDuration;
        uint256 startTime;
        uint256 claimedAmount;
        uint256 lastClaimTime;
    }
    
    struct VestingMilestone {
        uint256 targetPrice;
        uint256 accelerationPercent;
        bool achieved;
    }
    
    struct TWAPObservation {
        uint256 timestamp;
        uint160 sqrtPriceX96;
        uint128 liquidity;
    }

    // ============ State ============
    ITOState public itoState;
    uint256 public positionCounter;
    uint256 public latestApi3Price;
    bool public pendingApi3Request;
    uint256 public twapTolerance;
    uint256 public liquiditySyncThreshold;
    uint64[] public syncChainSelectors;
    TWAPObservation[] public twapObservations;
    uint256 public lastTwapObservationTime;
    uint256 public twapObservationMaxAge;
    mapping(address => ParticipantTier) public participantTiers;
    mapping(address => VestingSchedule) public participantVesting;
    mapping(address => uint256) public initialUnlockClaimed;
    mapping(VestingType => VestingSchedule) public ecosystemVesting;
    VestingMilestone[] public vestingMilestones;

    // ============ Events ============
    event TokensPurchased(address indexed buyer, uint256 usdcAmount, uint256 tokenAmount, uint256 timestamp);
    event LiquidityAdded(uint256 usdcAmount, uint256 tStakeAmount, uint256 timestamp);
    event ITOStateChanged(ITOState newState);
    event PriceUpdated(uint256 newStartPrice, uint256 newEndPrice, uint256 newDuration);
    event PurchaseLimitsUpdated(uint256 newMin, uint256 newMax);
    event BlacklistStatusUpdated(address indexed account, bool status);
    event EmergencyWithdrawal(address token, uint256 amount);
    event PurchasesPaused(bool status);
    event EcosystemVestingScheduleInitialized(VestingType vestingType, uint256 totalAmount);
    event ParticipantVestingScheduleInitialized(address indexed participant, ParticipantTier tier, uint256 amount);
    event EcosystemVestingClaimed(VestingType vestingType, uint256 amount, uint256 timestamp);
    event ParticipantVestingClaimed(address indexed participant, uint256 amount, uint256 timestamp);
    event InitialUnlockClaimed(address indexed participant, uint256 amount, uint256 timestamp);
    event TokensBurned(uint256 amount, uint256 timestamp, uint256 newTotalSupply);
    event StateSynced(uint64 indexed chainSelector, bytes32 indexed payloadHash, uint256 timestamp);
    event MessageReceived(uint64 indexed sourceChainSelector, address sender, bytes32 messageId, bytes data);
    event LiquiditySynced(uint256 usdcAmount, uint256 tStakeAmount);
    event Api3PriceUpdated(uint256 price, uint256 timestamp);
    event Api3RequestMade(bytes32 requestId);
    event TWAPToleranceUpdated(uint256 newTolerance);
    event LiquiditySyncThresholdUpdated(uint256 newThreshold);
    event PoolInitialized(bytes32 poolId, uint160 sqrtPriceX96);
    event TWAPObservationStored(uint256 timestamp, uint160 sqrtPriceX96, uint128 liquidity);
    event VestingMilestoneCreated(uint256 targetPrice, uint256 accelerationPercent);
    event VestingMilestoneAchieved(uint256 targetPrice, uint256 timestamp);
    event ParticipantTierSet(address indexed participant, ParticipantTier tier);
    event CcipRouterSet(address indexed router);
    event TrustedChainStatusUpdated(uint64 indexed chainSelector, bool status);

    // ============ Modifiers ============
    modifier onlyHooksCaller() {
        require(msg.sender == address(poolManager), "Only hooks caller");
        _;
    }
    
    modifier onlyValidPool(PoolKey calldata key) {
        require(key.toId() == poolId, "Invalid pool");
        _;
    }

    /**
     * @notice Initialize the contract
     */
    function initialize(
        address _tStakeToken,
        address _usdcToken,
        address _poolManager,
        address _treasuryMultiSig,
        address _stakingRewards,
        address _liquidityPool,
        address _ccipRouter,
        address _airnodeRrp,
        address admin
    ) external initializer {
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __CCIPReceiver_init(_ccipRouter);
        __RrpRequesterV0_init(_airnodeRrp);

        require(_tStakeToken != address(0), "Invalid token address");
        tStakeToken = IBurnableERC20(_tStakeToken);
        usdcToken = IERC20Upgradeable(_usdcToken);
        poolManager = IPoolManager(_poolManager);
        treasuryMultiSig = _treasuryMultiSig;
        stakingRewards = _stakingRewards;
        liquidityPool = _liquidityPool;
        ccipRouter = IRouterClient(_ccipRouter);

        // Initialize pool key
        Currency currency0 = Currency.wrap(_usdcToken < _tStakeToken ? _usdcToken : _tStakeToken);
        Currency currency1 = Currency.wrap(_usdcToken < _tStakeToken ? _tStakeToken : _usdcToken);
        
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });
        poolId = poolKey.toId();

        // Initialize ITO parameters
        startingPrice = 0.10 * 10**18;
        endingPrice = 0.20 * 10**18;
        priceDuration = 30 days;
        minPurchaseUSDC = DEFAULT_MIN_PURCHASE_USDC;
        maxPurchaseUSDC = DEFAULT_MAX_PURCHASE_USDC;
        itoState = ITOState.NotStarted;
        twapTolerance = 5 * 10**16; // 5%
        liquiditySyncThreshold = 50_000 * 10**6; // 50,000 USDC
        twapObservationMaxAge = 1 days;

        // Setup roles
        _setupRole(DEFAULT_ADMIN_ROLE, admin);
        _setupRole(GOVERNANCE_ROLE, admin);
        _setupRole(MULTISIG_ROLE, _treasuryMultiSig);
        _setupRole(PAUSER_ROLE, admin);
    }

    // ============ ITO Management Functions ============
    
    /**
     * @notice Start the ITO
     * @param _duration Duration of the ITO in seconds
     */
    function startITO(uint256 _duration) external onlyRole(GOVERNANCE_ROLE) {
        require(itoState == ITOState.NotStarted, "ITO already started");
        itoStartTime = block.timestamp;
        itoEndTime = block.timestamp + _duration;
        itoState = ITOState.Active;
        emit ITOStateChanged(ITOState.Active);
    }
    
    /**
     * @notice End the ITO
     */
    function endITO() external onlyRole(GOVERNANCE_ROLE) {
        require(itoState == ITOState.Active, "ITO not active");
        itoState = ITOState.Ended;
        itoEndTime = block.timestamp;
        emit ITOStateChanged(ITOState.Ended);
    }
    
    /**
     * @notice Get the current token price
     * @return Current price in USDC per token (18 decimals)
     */
    function getCurrentPrice() public view returns (uint256) {
        if (itoState != ITOState.Active) return startingPrice;
        
        uint256 elapsed = block.timestamp - itoStartTime;
        if (elapsed >= priceDuration) return endingPrice;
        
        return startingPrice + ((endingPrice - startingPrice) * elapsed / priceDuration);
    }
    
    /**
     *
     * @notice Purchase tokens during the ITO
     * @param usdcAmount Amount of USDC to spend
     */
    function purchaseTokens(uint256 usdcAmount) external nonReentrant {
        require(itoState == ITOState.Active, "ITO not active");
        require(!purchasesPaused, "Purchases paused");
        require(!blacklist[msg.sender], "Address blacklisted");
        require(usdcAmount >= minPurchaseUSDC, "Below minimum purchase");
        
        uint256 totalPurchased = purchasedAmounts[msg.sender] + usdcAmount;
        require(totalPurchased <= maxPurchaseUSDC, "Exceeds maximum purchase");
        
        // Anti-bot check if enabled
        if (address(antiBot) != address(0)) {
            require(antiBot.checkAddress(msg.sender), "Anti-bot check failed");
        }
        
        // Calculate tokens based on current price
        uint256 tokenAmount = (usdcAmount * 10**18) / getCurrentPrice();
        require(tokensSold + tokenAmount <= MAX_TOKENS_FOR_ITO, "Exceeds ITO allocation");
        
        // Transfer USDC from user
        require(usdcToken.transferFrom(msg.sender, address(this), usdcAmount), "USDC transfer failed");
        
        // Update state
        tokensSold += tokenAmount;
        accumulatedUSDC += usdcAmount;
        purchasedAmounts[msg.sender] += usdcAmount;
        
        // Set up vesting schedule
        _setupVestingSchedule(msg.sender, tokenAmount);
        
        emit TokensPurchased(msg.sender, usdcAmount, tokenAmount, block.timestamp);
    }
    
    /**
     * @notice Update ITO price parameters
     * @param _startingPrice New starting price
     * @param _endingPrice New ending price
     * @param _priceDuration New price duration
     */
    function updatePriceParameters(
        uint256 _startingPrice,
        uint256 _endingPrice,
        uint256 _priceDuration
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(_startingPrice > 0, "Invalid starting price");
        require(_endingPrice >= _startingPrice, "End price must be >= start price");
        require(_priceDuration > 0, "Invalid price duration");
        
        startingPrice = _startingPrice;
        endingPrice = _endingPrice;
        priceDuration = _priceDuration;
        
        emit PriceUpdated(_startingPrice, _endingPrice, _priceDuration);
    }
    
    /**
     * @notice Update purchase limits
     * @param _minPurchaseUSDC New minimum purchase amount
     * @param _maxPurchaseUSDC New maximum purchase amount
     */
    function updatePurchaseLimits(
        uint256 _minPurchaseUSDC,
        uint256 _maxPurchaseUSDC
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(_minPurchaseUSDC > 0, "Invalid minimum purchase");
        require(_maxPurchaseUSDC >= _minPurchaseUSDC, "Max must be >= min");
        
        minPurchaseUSDC = _minPurchaseUSDC;
        maxPurchaseUSDC = _maxPurchaseUSDC;
        
        emit PurchaseLimitsUpdated(_minPurchaseUSDC, _maxPurchaseUSDC);
    }
    
    /**
     * @notice Pause or unpause token purchases
     * @param _paused New paused state
     */
    function setPurchasesPaused(bool _paused) external onlyRole(PAUSER_ROLE) {
        purchasesPaused = _paused;
        emit PurchasesPaused(_paused);
    }

    // ============ Vesting Functions ============
    
    /**
     * @notice Set participant tier
     * @param participant Address of the participant
     * @param tier Tier level
     */
    function setParticipantTier(address participant, ParticipantTier tier) external onlyRole(GOVERNANCE_ROLE) {
        participantTiers[participant] = tier;
        emit ParticipantTierSet(participant, tier);
    }
    
    /**
     * @notice Set up vesting schedule for a participant
     * @param participant Address of the participant
     * @param tokenAmount Amount of tokens to vest
     */
    function _setupVestingSchedule(address participant, uint256 tokenAmount) internal {
        ParticipantTier tier = participantTiers[participant];
        
        uint256 initialUnlockPercent;
        uint256 cliffPeriod;
        uint256 vestingDuration;
        
        if (tier == ParticipantTier.Seed) {
            initialUnlockPercent = SEED_INITIAL_UNLOCK;
            cliffPeriod = SEED_CLIFF_PERIOD;
            vestingDuration = SEED_VESTING_DURATION;
        } else if (tier == ParticipantTier.Private) {
            initialUnlockPercent = PRIVATE_INITIAL_UNLOCK;
            cliffPeriod = PRIVATE_CLIFF_PERIOD;
            vestingDuration = PRIVATE_VESTING_DURATION;
        } else {
            initialUnlockPercent = PUBLIC_INITIAL_UNLOCK;
            cliffPeriod = PUBLIC_CLIFF_PERIOD;
            vestingDuration = PUBLIC_VESTING_DURATION;
        }
        
        uint256 initialUnlock = (tokenAmount * initialUnlockPercent) / 10000;
        
        // Create or update vesting schedule
        VestingSchedule storage schedule = participantVesting[participant];
        if (schedule.totalAmount == 0) {
            schedule.startTime = itoEndTime;
        }
        
        schedule.totalAmount += tokenAmount;
        schedule.initialUnlock += initialUnlock;
        schedule.cliffPeriod = cliffPeriod;
        schedule.vestingDuration = vestingDuration;
        
        emit ParticipantVestingScheduleInitialized(participant, tier, tokenAmount);
    }
    
    /**
     * @notice Initialize ecosystem vesting schedule
     * @param vestingType Type of ecosystem vesting
     * @param totalAmount Total amount of tokens to vest
     * @param cliffPeriod Cliff period in seconds
     * @param vestingDuration Vesting duration in seconds
     */
    function initializeEcosystemVesting(
        VestingType vestingType,
        uint256 totalAmount,
        uint256 cliffPeriod,
        uint256 vestingDuration
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(ecosystemVesting[vestingType].totalAmount ==.0, "Already initialized");
        require(totalAmount > 0, "Invalid amount");
        require(vestingDuration > 0, "Invalid duration");
        
        ecosystemVesting[vestingType] = VestingSchedule({
            totalAmount: totalAmount,
            initialUnlock: 0,
            cliffPeriod: cliffPeriod,
            vestingDuration: vestingDuration,
            startTime: block.timestamp,
            claimedAmount: 0,
            lastClaimTime: 0
        });
        
        emit EcosystemVestingScheduleInitialized(vestingType, totalAmount);
    }
    
    /**
     * @notice Claim vested tokens for a participant
     */
    function claimVestedTokens() external nonReentrant {
        VestingSchedule storage schedule = participantVesting[msg.sender];
        require(schedule.totalAmount > 0, "No vesting schedule");
        require(block.timestamp >= schedule.startTime, "Vesting not started");
        
        // Handle initial unlock if not claimed
        uint256 claimableAmount = 0;
        if (initialUnlockClaimed[msg.sender] == 0 && schedule.initialUnlock > 0) {
            claimableAmount += schedule.initialUnlock;
            initialUnlockClaimed[msg.sender] = schedule.initialUnlock;
            emit InitialUnlockClaimed(msg.sender, schedule.initialUnlock, block.timestamp);
        }
        
        // Calculate vested amount
        if (block.timestamp >= schedule.startTime + schedule.cliffPeriod) {
            uint256 vestedAmount = _calculateVestedAmount(schedule);
            uint256 newlyVested = vestedAmount - schedule.claimedAmount;
            
            if (newlyVested > 0) {
                claimableAmount += newlyVested;
                schedule.claimedAmount += newlyVested;
                schedule.lastClaimTime = block.timestamp;
            }
        }
        
        require(claimableAmount > 0, "No tokens to claim");
        require(tStakeToken.transfer(msg.sender, claimableAmount), "Token transfer failed");
        
        emit ParticipantVestingClaimed(msg.sender, claimableAmount, block.timestamp);
    }
    
    /**
     * @notice Claim ecosystem vested tokens
     * @param vestingType Type of ecosystem vesting
     */
    function claimEcosystemVestedTokens(VestingType vestingType) external nonReentrant onlyRole(MULTISIG_ROLE) {
        VestingSchedule storage schedule = ecosystemVesting[vestingType];
        require(schedule.totalAmount > 0, "No vesting schedule");
        require(block.timestamp >= schedule.startTime, "Vesting not started");
        
        address recipient;
        if (vestingType == VestingType.Treasury) {
            recipient = treasuryMultiSig;
        } else if (vestingType == VestingType.Staking) {
            recipient = stakingRewards;
        } else if (vestingType == VestingType.Liquidity) {
            recipient = liquidityPool;
        } else {
            revert("Invalid vesting type");
        }
        
        // Calculate vested amount
        if (block.timestamp >= schedule.startTime + schedule.cliffPeriod) {
            uint256 vestedAmount = _calculateVestedAmount(schedule);
            uint256 newlyVested = vestedAmount - schedule.claimedAmount;
            
            if (newlyVested > 0) {
                schedule.claimedAmount += newlyVested;
                schedule.lastClaimTime = block.timestamp;
                
                require(tStakeToken.transfer(recipient, newlyVested), "Token transfer failed");
                emit EcosystemVestingClaimed(vestingType, newlyVested, block.timestamp);
            } else {
                revert("No tokens to claim");
            }
        } else {
            revert("Cliff period not passed");
        }
    }
    
    /**
     * @notice Calculate vested amount for a schedule
     * @param schedule Vesting schedule
     * @return Vested amount
     */
    function _calculateVestedAmount(VestingSchedule storage schedule) internal view returns (uint256) {
        if (block.timestamp < schedule.startTime + schedule.cliffPeriod) {
            return 0;
        }
        
        uint256 vestedAmount = schedule.totalAmount - schedule.initialUnlock;
        uint256 elapsedTime = block.timestamp - (schedule.startTime + schedule.cliffPeriod);
        
        if (elapsedTime >= schedule.vestingDuration) {
            return vestedAmount;
        }
        
        // Apply milestone acceleration if any
        uint256 accelerationFactor = _calculateAccelerationFactor();
        uint256 adjustedElapsedTime = elapsedTime * accelerationFactor / 10000;
        
        if (adjustedElapsedTime >= schedule.vestingDuration) {
            return vestedAmount;
        }
        
        return (vestedAmount * adjustedElapsedTime) / schedule.vestingDuration;
    }
    
    /**
     * @notice Calculate acceleration factor based on achieved milestones
     * @return Acceleration factor in basis points (10000 = 100%)
     */
    function _calculateAccelerationFactor() internal view returns (uint256) {
        uint256 factor = 10000; // Base: 100%
        
        for (uint256 i = 0; i < vestingMilestones.length; i++) {
            if (vestingMilestones[i].achieved) {
                factor += vestingMilestones[i].accelerationPercent;
            }
        }
        
        return factor;
    }
    
    /**
     * @notice Add a vesting milestone
     * @param targetPrice Target price to achieve
     * @param accelerationPercent Acceleration percentage in basis points
     */
    function addVestingMilestone(uint256 targetPrice, uint256 accelerationPercent) external onlyRole(GOVERNANCE_ROLE) {
        require(targetPrice > 0, "Invalid target price");
        require(accelerationPercent > 0, "Invalid acceleration");
        
        vestingMilestones.push(VestingMilestone({
            targetPrice: targetPrice,
            accelerationPercent: accelerationPercent,
            achieved: false
        }));
        
        emit VestingMilestoneCreated(targetPrice, accelerationPercent);
    }
    
    /**
     * @notice Check and update milestone achievements
     */
    function checkMilestones() external {
        uint256 currentPrice = getCurrentTWAP();
        
        for (uint256 i = 0; i < vestingMilestones.length; i++) {
            if (!vestingMilestones[i].achieved && currentPrice >= vestingMilestones[i].targetPrice) {
                vestingMilestones[i].achieved = true;
                emit VestingMilestoneAchieved(vestingMilestones[i].targetPrice, block.timestamp);
            }
        }
    }

    // ============ Uniswap V4 Hook Functions ============
    
    /**
     * @notice Hook called before pool initialization
     */
    function beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96, bytes calldata)
        external
        override
        onlyHooksCaller
        onlyValidPool(key)
        returns (bytes4)
    {
        require(!poolInitialized, "Pool already initialized");
        return IHooks.beforeInitialize.selector;
    }
    
    /**
     * @notice Hook called after pool initialization
     */
    function afterInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96, int24, int24, bytes calldata)
        external
        override
        onlyHooksCaller
        onlyValidPool(key)
        returns (bytes4)
    {
        poolInitialized = true;
        
        // Store initial TWAP observation
        twapObservations.push(TWAPObservation({
            timestamp: block.timestamp,
            sqrtPriceX96: sqrtPriceX96,
            liquidity: 0
        }));
        
        lastTwapObservationTime = block.timestamp;
        
        emit PoolInitialized(key.toId(), sqrtPriceX96);
        return IHooks.afterInitialize.selector;
    }
    /**
     * @notice Hook called before swap
     */
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        onlyHooksCaller
        onlyValidPool(key)
        returns (bytes4)
    {
        return IHooks.beforeSwap.selector;
    }
    
    /**
     * @notice Hook called after swap
     */
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    )
        external
        override
        onlyHooksCaller
        onlyValidPool(key)
        returns (bytes4)
    {
        // Store TWAP observation if enough time has passed
        if (block.timestamp >= lastTwapObservationTime + 1 hours) {
            (uint160 sqrtPriceX96, , , , , , ) = poolManager.getSlot0(key.toId());
            uint128 liquidity = poolManager.getLiquidity(key.toId());
            
            twapObservations.push(TWAPObservation({
                timestamp: block.timestamp,
                sqrtPriceX96: sqrtPriceX96,
                liquidity: liquidity
            }));
            
            lastTwapObservationTime = block.timestamp;
            
            emit TWAPObservationStored(block.timestamp, sqrtPriceX96, liquidity);
            
            // Clean up old observations
            _cleanupOldObservations();
        }
        
        return IHooks.afterSwap.selector;
    }
    
    /**
     * @notice Hook called before adding liquidity
     */
    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    )
        external
        override
        onlyHooksCaller
        onlyValidPool(key)
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }
    
    /**
     * @notice Hook called after adding liquidity
     */
    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        bytes calldata
    )
        external
        override
        onlyHooksCaller
        onlyValidPool(key)
        returns (bytes4)
    {
        return IHooks.afterAddLiquidity.selector;
    }
    
    /**
     * @notice Hook called before removing liquidity
     */
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    )
        external
        override
        onlyHooksCaller
        onlyValidPool(key)
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }
    
    /**
     * @notice Hook called after removing liquidity
     */
    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        bytes calldata
    )
        external
        override
        onlyHooksCaller
        onlyValidPool(key)
        returns (bytes4)
    {
        return IHooks.afterRemoveLiquidity.selector;
    }
    
    /**
     * @notice Hook called before donating
     */
    function beforeDonate(
        address,
        PoolKey calldata key,
        uint256,
        uint256,
        bytes calldata
    )
        external
        override
        onlyHooksCaller
        onlyValidPool(key)
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }
    
    /**
     * @notice Hook called after donating
     */
    function afterDonate(
        address,
        PoolKey calldata key,
        uint256,
        uint256,
        bytes calldata
    )
        external
        override
        onlyHooksCaller
        onlyValidPool(key)
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }

    // ============ Liquidity Management Functions ============
    
    /**
     * @notice Initialize the Uniswap V4 pool
     * @param initialSqrtPriceX96 Initial sqrt price
     */
    function initializePool(uint160 initialSqrtPriceX96) external onlyRole(GOVERNANCE_ROLE) {
        require(!poolInitialized, "Pool already initialized");
        require(itoState == ITOState.Ended, "ITO must be ended");
        
        poolManager.initialize(poolKey, initialSqrtPriceX96, "");
    }
    
    /**
     * @notice Add liquidity to the Uniswap V4 pool
     * @param usdcAmount Amount of USDC to add
     * @param tStakeAmount Amount of tStake tokens to add
     * @param tickLower Lower tick
     * @param tickUpper Upper tick
     */
    function addLiquidity(
        uint256 usdcAmount,
        uint256 tStakeAmount,
        int24 tickLower,
        int24 tickUpper
    ) external onlyRole(MULTISIG_ROLE) {
        require(poolInitialized, "Pool not initialized");
        
        // Transfer tokens to this contract if needed
        if (usdcAmount > 0) {
            require(usdcToken.transferFrom(msg.sender, address(this), usdcAmount), "USDC transfer failed");
        }
        
        if (tStakeAmount > 0) {
            require(tStakeToken.transferFrom(msg.sender, address(this), tStakeAmount), "tStake transfer failed");
        }
        
        // Approve tokens to pool manager
        usdcToken.approve(address(poolManager), usdcAmount);
        tStakeToken.approve(address(poolManager), tStakeAmount);
        
        // Add liquidity
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: 0, // Will be calculated by the pool manager
            salt: bytes32(positionCounter)
        });
        
        bytes memory callData = abi.encodeWithSelector(
            IPoolManager.modifyLiquidity.selector,
            poolKey,
            params,
            ""
        );
        
        (bool success, bytes memory result) = address(poolManager).call(callData);
        require(success, "Liquidity addition failed");
        
        // Store position ID
        positionIds[positionCounter] = abi.decode(result, (uint256));
        positionCounter++;
        
        emit LiquidityAdded(usdcAmount, tStakeAmount, block.timestamp);
    }
    
    /**
     * @notice Remove liquidity from the Uniswap V4 pool
     * @param positionId ID of the position
     */
    function removeLiquidity(uint256 positionId) external onlyRole(MULTISIG_ROLE) {
        require(poolInitialized, "Pool not initialized");
        require(positionIds[positionId] > 0, "Invalid position ID");
        
        // Remove liquidity
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: 0, // Will be retrieved from position
            tickUpper: 0, // Will be retrieved from position
            liquidityDelta: -int256(positionIds[positionId]),
            salt: bytes32(positionId)
        });
        
        bytes memory callData = abi.encodeWithSelector(
            IPoolManager.modifyLiquidity.selector,
            poolKey,
            params,
            ""
        );
        
        (bool success,) = address(poolManager).call(callData);
        require(success, "Liquidity removal failed");
        
        // Transfer tokens back to caller
        uint256 usdcBalance = usdcToken.balanceOf(address(this));
        uint256 tStakeBalance = tStakeToken.balanceOf(address(this));
        
        if (usdcBalance > 0) {
            require(usdcToken.transfer(msg.sender, usdcBalance), "USDC transfer failed");
        }
        
        if (tStakeBalance > 0) {
            require(tStakeToken.transfer(msg.sender, tStakeBalance), "tStake transfer failed");
        }
    }
    
    /**
     * @notice Clean up old TWAP observations
     */
    function _cleanupOldObservations() internal {
        uint256 cutoffTime = block.timestamp - twapObservationMaxAge;
        uint256 i = 0;
        
        while (i < twapObservations.length && twapObservations[i].timestamp < cutoffTime) {
            i++;
        }
        
        if (i > 0) {
            uint256 j = 0;
            while (i < twapObservations.length) {
                twapObservations[j] = twapObservations[i];
                i++;
                j++;
            }
            
            while (twapObservations.length > j) {
                twapObservations.pop();
            }
        }
    }
    
    /**
     * @notice Get current TWAP price
     * @return TWAP price
     */
    function getCurrentTWAP() public view returns (uint256) {
        if (twapObservations.length < 2) {
            return 0;
        }
        
        uint256 weightedPriceSum = 0;
        uint256 totalWeight = 0;
        
        for (uint256 i = 1; i < twapObservations.length; i++) {
            TWAPObservation memory prev = twapObservations[i-1];
            TWAPObservation memory curr = twapObservations[i];
            
            uint256 timeWeight = curr.timestamp - prev.timestamp;
            uint256 avgSqrtPrice = (uint256(curr.sqrtPriceX96) + uint256(prev.sqrtPriceX96)) / 2;
            uint256 price = (avgSqrtPrice * avgSqrtPrice) / (2**192);
            
            weightedPriceSum += price * timeWeight;
            totalWeight += timeWeight;
        }
        
        if (totalWeight == 0) {
            return 0;
        }
        
        return weightedPriceSum / totalWeight;
    }

    // ============ API3 Oracle Integration ============
    
    /**
     * @notice Set API3 Airnode parameters
     * @param _airnode Airnode address
     * @param _endpointId Endpoint ID
     * @param _sponsorWallet Sponsor wallet address
     */
    function setApi3Parameters(
        address _airnode,
        bytes32 _endpointId,
        address _sponsorWallet
    ) external onlyRole(GOVERNANCE_ROLE) {
        api3Airnode = _airnode;
        api3EndpointId = _endpointId;
        api3SponsorWallet = _sponsorWallet;
    }
    
    /**
     * @notice Request price update from API3
     */
    function requestApi3PriceUpdate() external {
        require(api3Airnode != address(0), "API3 not configured");
        require(!pendingApi3Request, "Request already pending");
        
        bytes32 requestId = airnodeRrp.makeFullRequest(
            api3Airnode,
            api3EndpointId,
            address(this),
            api3SponsorWallet,
            address(this),
            this.fulfillApi3Request.selector,
            ""
        );
        
        pendingRequests[requestId] = true;
        pendingApi3Request = true;
        
        emit Api3RequestMade(requestId);
    }
    
    /**
     * @notice Fulfill API3 price update request
     * @param requestId Request ID
     * @param data Response data
     */
    function fulfillApi3Request(bytes32 requestId, bytes calldata data) external {
        require(msg.sender == address(airnodeRrp), "Caller not airnode");
        require(pendingRequests[requestId], "Request not found");
        
        pendingRequests[requestId] = false;
        pendingApi3Request = false;
        
        uint256 price = abi.decode(data, (uint256));
        latestApi3Price = price;
        
        emit Api3PriceUpdated(price, block.timestamp);
    }

    // ============ Chainlink CCIP Integration ============
    
    /**
     * @notice Set Chainlink CCIP router address
     * @param _ccipRouter New router address
     */
    function setCcipRouter(address _ccipRouter) external onlyRole(GOVERNANCE_ROLE) {
        require(_ccipRouter != address(0), "Invalid CCIP router");
        ccipRouter = IRouterClient(_ccipRouter);
        emit CcipRouterSet(_ccipRouter);
    }
    
    /**
     * @notice Set chains to sync with
     * @param _chainSelectors Array of chain selectors
     */
    function setSyncChains(uint64[] calldata _chainSelectors) external onlyRole(GOVERNANCE_ROLE) {
        delete syncChainSelectors;
        
        for (uint256 i = 0; i < _chainSelectors.length; i++) {
            syncChainSelectors.push(_chainSelectors[i]);
            trustedSourceChains[_chainSelectors[i]] = true;
            emit TrustedChainStatusUpdated(_chainSelectors[i], true);
        }
    }
    
    /**
     * @notice Set trusted source chain status
     * @param chainSelector Chain selector
     * @param trusted Whether the chain is trusted
     */
    function setTrustedSourceChain(uint64 chainSelector, bool trusted) external onlyRole(GOVERNANCE_ROLE) {
        trustedSourceChains[chainSelector] = trusted;
        emit TrustedChainStatusUpdated(chainSelector, trusted);
    }
    
    /**
     * @notice Sync state to other chains
     * @param receiver The address of the receiver on the destination chain
     * @param payload Data to sync
     */
    function syncState(
        address receiver,
        bytes calldata payload
    ) external onlyRole(GOVERNANCE_ROLE) payable {
        for (uint256 i = 0; i < syncChainSelectors.length; i++) {
            uint64 destinationChainSelector = syncChainSelectors[i];
            
            Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
                receiver: abi.encode(receiver),
                data: payload,
                tokenAmounts: new Client.EVMTokenAmount[](0),
                extraArgs: "", 
                feeToken: address(0) // Use native token for fees
            });
            
            uint256 fee = ccipRouter.getFee(destinationChainSelector, message);
            require(msg.value >= fee, "Insufficient fee");
            
            bytes32 messageId = ccipRouter.ccipSend{value: fee}(
                destinationChainSelector,
                message
            );
            
            emit StateSynced(destinationChainSelector, keccak256(payload), block.timestamp);
        }
        
        // Return any unused ETH
        if (address(this).balance > 0) {
            (bool success, ) = payable(msg.sender).call{value: address(this).balance}("");
            require(success, "ETH refund failed");
        }
    }
    
    /**
     * @notice Handler for receiving CCIP messages
     * @param message The CCIP message containing data from the source chain
     */
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        uint64 sourceChainSelector = message.sourceChainSelector;
        require(trustedSourceChains[sourceChainSelector], "Untrusted source chain");
        
        // Prevent replay attacks
        bytes32 messageId = message.messageId;
        require(!processedCcipMessages[messageId], "Message already processed");
        processedCcipMessages[messageId] = true;
        
        // Process the message
        address sender = abi.decode(message.sender, (address));
        bytes memory data = message.data;
        
        // Implement the cross-chain message processing logic here
        // This could include updating state variables, processing commands, etc.
        
        emit MessageReceived(sourceChainSelector, sender, messageId, data);
    }
    
    /**
     * @notice Estimate fees for CCIP message
     * @param destinationChainSelector The selector of the destination chain
     * @param receiver The address of the receiver on the destination chain
     * @param payload The data payload to send
     * @return fee The estimated fee
     */
    function estimateFees(
        uint64 destinationChainSelector,
        address receiver,
        bytes calldata payload
    ) external view returns (uint256) {
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: payload,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: "",
            feeToken: address(0) // Use native token for fees
        });
        
        return ccipRouter.getFee(destinationChainSelector, message);
    }

    // ============ Admin Functions ============
    
    /**
     * @notice Set anti-bot contract
     * @param _antiBot Anti-bot contract address
     */
    function setAntiBot(address _antiBot) external onlyRole(GOVERNANCE_ROLE) {
        antiBot = IAntiBot(_antiBot);
    }
    
    /**
     * @notice Update blacklist status for an address
     * @param account Address to update
     * @param status New blacklist status
     */
    function updateBlacklist(address account, bool status) external onlyRole(GOVERNANCE_ROLE) {
        blacklist[account] = status;
        emit BlacklistStatusUpdated(account, status);
    }
    
    /**
     * @notice Update TWAP tolerance
     * @param _tolerance New tolerance value
     */
    function updateTwapTolerance(uint256 _tolerance) external onlyRole(GOVERNANCE_ROLE) {
        twapTolerance = _tolerance;
        emit TWAPToleranceUpdated(_tolerance);
    }
    
    /**
     * @notice Update liquidity sync threshold
     * @param _threshold New threshold value
     */
    function updateLiquiditySyncThreshold(uint256 _threshold) external onlyRole(GOVERNANCE_ROLE) {
        liquiditySyncThreshold = _threshold;
        emit LiquiditySyncThresholdUpdated(_threshold);
    }
    
    /**
     * @notice Burn unsold tokens after ITO ends
     */
    function burnUnsoldTokens() external onlyRole(GOVERNANCE_ROLE) {
        require(itoState == ITOState.Ended, "ITO not ended");
        
        uint256 unsoldAmount = MAX_TOKENS_FOR_ITO - tokensSold;
        if (unsoldAmount > 0) {
            tStakeToken.burn(unsoldAmount);
            emit TokensBurned(unsoldAmount, block.timestamp, tStakeToken.totalSupply());
        }
    }
    
    /**
     * @notice Emergency withdrawal of tokens
     * @param token Token address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyRole(MULTISIG_ROLE) {
        require(itoState == ITOState.Ended, "ITO not ended");
        
        IERC20Upgradeable tokenContract = IERC20Upgradeable(token);
        require(tokenContract.transfer(treasuryMultiSig, amount), "Transfer failed");
        
        emit EmergencyWithdrawal(token, amount);
    }
    
    /**
     * @notice Update treasury multisig address
     * @param _treasuryMultiSig New treasury multisig address
     */
    function updateTreasuryMultiSig(address _treasuryMultiSig) external onlyRole(GOVERNANCE_ROLE) {
        require(_treasuryMultiSig != address(0), "Invalid address");
        
        // Revoke role from old address
        _revokeRole(MULTISIG_ROLE, treasuryMultiSig);
        
        // Update address
        treasuryMultiSig = _treasuryMultiSig;
        
        // Grant role to new address
        _grantRole(MULTISIG_ROLE, _treasuryMultiSig);
    }
    
    /**
     * @notice Update staking rewards address
     * @param _stakingRewards New staking rewards address
     */
    function updateStakingRewards(address _stakingRewards) external onlyRole(GOVERNANCE_ROLE) {
        require(_stakingRewards != address(0), "Invalid address");
        stakingRewards = _stakingRewards;
    }
    
    /**
     * @notice Update liquidity pool address
     * @param _liquidityPool New liquidity pool address
     */
    function updateLiquidityPool(address _liquidityPool) external onlyRole(GOVERNANCE_ROLE) {
        require(_liquidityPool != address(0), "Invalid address");
        liquidityPool = _liquidityPool;
    }
    
    /**
     * @notice Update TWAP observation max age
     * @param _maxAge New max age in seconds
     */
    function updateTwapObservationMaxAge(uint256 _maxAge) external onlyRole(GOVERNANCE_ROLE) {
        require(_maxAge > 0, "Invalid max age");
        twapObservationMaxAge = _maxAge;
    }

    // ============ View Functions ============
    
    /**
     * @notice Get ITO stats
     * @return _tokensSold Total tokens sold
     * @return _accumulatedUSDC Total USDC accumulated
     * @return _currentPrice Current token price
     * @return _itoState Current ITO state
     */
    function getITOStats() external view returns (
        uint256 _tokensSold,
        uint256 _accumulatedUSDC,
        uint256 _currentPrice,
        ITOState _itoState
    ) {
        return (tokensSold, accumulatedUSDC, getCurrentPrice(), itoState);
    }
    
    /**
     * @notice Get vesting schedule for a participant
     * @param participant Address of the participant
     * @return schedule Vesting schedule
     */
    function getVestingSchedule(address participant) external view returns (VestingSchedule memory) {
        return participantVesting[participant];
    }
    
    /**
     * @notice Get ecosystem vesting schedule
     * @param vestingType Type of ecosystem vesting
     * @return schedule Vesting schedule
     */
    function getEcosystemVestingSchedule(VestingType vestingType) external view returns (VestingSchedule memory) {
        return ecosystemVesting[vestingType];
    }
    
    /**
     * @notice Get vesting milestones
     * @return Array of vesting milestones
     */
    function getVestingMilestones() external view returns (VestingMilestone[] memory) {
        return vestingMilestones;
    }
    
    /**
     * @notice Get TWAP observations
     * @return Array of TWAP observations
     */
    function getTwapObservations() external view returns (TWAPObservation[] memory) {
        return twapObservations;
    }
    
    /**
     * @notice Get claimable amount for a participant
     * @param participant Address of the participant
     * @return Claimable amount
     */
    function getClaimableAmount(address participant) external view returns (uint256) {
        VestingSchedule storage schedule = participantVesting[participant];
        if (schedule.totalAmount == 0) {
            return 0;
        }
        
        uint256 claimableAmount = 0;
        
        // Check initial unlock
        if (initialUnlockClaimed[participant] == 0 && schedule.initialUnlock > 0 && block.timestamp >= schedule.startTime) {
            claimableAmount += schedule.initialUnlock;
        }
        
        // Check vested amount
        if (block.timestamp >= schedule.startTime + schedule.cliffPeriod) {
            uint256 vestedAmount = _calculateVestedAmount(schedule);
            uint256 newlyVested = vestedAmount - schedule.claimedAmount;
            claimableAmount += newlyVested;
        }
        
        return claimableAmount;
    }
    
    /**
     * @notice Get ecosystem claimable amount
     * @param vestingType Type of ecosystem vesting
     * @return Claimable amount
     */
    function getEcosystemClaimableAmount(VestingType vestingType) external view returns (uint256) {
        VestingSchedule storage schedule = ecosystemVesting[vestingType];
        if (schedule.totalAmount == 0) {
            return 0;
        }
        
        if (block.timestamp < schedule.startTime + schedule.cliffPeriod) {
            return 0;
        }
        
        uint256 vestedAmount = _calculateVestedAmount(schedule);
        return vestedAmount - schedule.claimedAmount;
    }

    /**
     * @notice Check if an address passes anti-bot verification
     * @param user Address to check
     * @return Whether the address passes verification
     */
    function checkAddress(address user) external view returns (bool) {
        if (address(antiBot) == address(0)) {
            return true;
        }
        
        return !blacklist[user] && antiBot.checkAddress(user);
    }
    
    /**
     * @notice Get the current version of the contract
     * @return Version string
     */
    function version() external pure returns (string memory) {
        return "TerraStakeITO v2.0";
    }

    // ============ Upgrade Function ============
    
    /**
     * @notice Authorize contract upgrade
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ============ Fallback Functions ============
    
    /**
     * @notice Receive ETH
     */
    receive() external payable {}
}                   