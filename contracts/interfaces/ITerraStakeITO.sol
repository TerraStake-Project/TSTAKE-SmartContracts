// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/src/interfaces/IHooks.sol";
import "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import "../interfaces/IAntiBot.sol";

interface IBurnableERC20 is IERC20 {
    function burn(uint256 amount) external;
    function totalSupply() external view returns (uint256);
}

interface ITerraStakeITO is IHooks {
    // Enums
    enum ParticipantTier { Seed, Private, Public }
    enum VestingType { Treasury, Staking, Liquidity }
    enum ITOState { NotStarted, Active, Ended }
   
    // Structs
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

    // Events
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

    // ITO Management Functions
    function startITO(uint256 _duration) external;
    function endITO() external;
    function getCurrentPrice() external view returns (uint256);
    function purchaseTokens(uint256 usdcAmount) external;
    function updatePriceParameters(uint256 _startingPrice, uint256 _endingPrice, uint256 _priceDuration) external;
    function updatePurchaseLimits(uint256 _minPurchaseUSDC, uint256 _maxPurchaseUSDC) external;
    function setPurchasesPaused(bool _paused) external;

    // Vesting Functions
    function setParticipantTier(address participant, ParticipantTier tier) external;
    function initializeEcosystemVesting(VestingType vestingType, uint256 totalAmount, uint256 cliffPeriod, uint256 vestingDuration) external;
    function claimVestedTokens() external;
    function claimEcosystemVestedTokens(VestingType vestingType) external;
    function addVestingMilestone(uint256 targetPrice, uint256 accelerationPercent) external;
    function checkMilestones() external;

    // Liquidity Management Functions
    function initializePool(uint160 initialSqrtPriceX96) external;
    function addLiquidity(uint256 usdcAmount, uint256 tStakeAmount, int24 tickLower, int24 tickUpper) external;
    function removeLiquidity(uint256 positionId) external;
    function getCurrentTWAP() external view returns (uint256);

    // API3 Oracle Integration
    function setApi3Parameters(address _airnode, bytes32 _endpointId, address _sponsorWallet) external;
    function requestApi3PriceUpdate() external;
    function fulfillApi3Request(bytes32 requestId, bytes calldata data) external;

    // Chainlink CCIP Functions
    function setCcipRouter(address _ccipRouter) external;
    function setSyncChains(uint64[] calldata _chainSelectors) external;
    function setTrustedSourceChain(uint64 chainSelector, bool trusted) external;
    function syncState(address receiver, bytes calldata payload) external payable;
    function estimateFees(uint64 destinationChainSelector, address receiver, bytes calldata payload) external view returns (uint256);

    // Admin Functions
    function setAntiBot(address _antiBot) external;
    function updateBlacklist(address account, bool status) external;
    function updateTwapTolerance(uint256 _tolerance) external;
    function updateLiquiditySyncThreshold(uint256 _threshold) external;
    function burnUnsoldTokens() external;
    function emergencyWithdraw(address token, uint256 amount) external;
    function updateTreasuryMultiSig(address _treasuryMultiSig) external;
    function updateStakingRewards(address _stakingRewards) external;
    function updateLiquidityPool(address _liquidityPool) external;
    function updateTwapObservationMaxAge(uint256 _maxAge) external;

    // View Functions
    function getITOStats() external view returns (
        uint256 _tokensSold,
        uint256 _accumulatedUSDC,
        uint256 _currentPrice,
        ITOState _itoState
    );
    function getVestingSchedule(address participant) external view returns (VestingSchedule memory);
    function getEcosystemVestingSchedule(VestingType vestingType) external view returns (VestingSchedule memory);
    function getVestingMilestones() external view returns (VestingMilestone[] memory);
    function getTwapObservations() external view returns (TWAPObservation[] memory);
    function getClaimableAmount(address participant) external view returns (uint256);
    function getEcosystemClaimableAmount(VestingType vestingType) external view returns (uint256);
    function checkAddress(address user) external view returns (bool);
    function version() external pure returns (string memory);

    // Constants
    function POOL_FEE() external view returns (uint24);
    function MAX_TOKENS_FOR_ITO() external view returns (uint256);
    function DEFAULT_MIN_PURCHASE_USDC() external view returns (uint256);
    function DEFAULT_MAX_PURCHASE_USDC() external view returns (uint256);
    function GOVERNANCE_ROLE() external view returns (bytes32);
    function MULTISIG_ROLE() external view returns (bytes32);
    function PAUSER_ROLE() external view returns (bytes32);
   
    // State variables
    function antiBot() external view returns (IAntiBot);
    function tStakeToken() external view returns (IBurnableERC20);
    function usdcToken() external view returns (IERC20);
    function poolManager() external view returns (IPoolManager);
    function ccipRouter() external view returns (address);
    function poolKey() external view returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, IHooks hooks);
    function poolId() external view returns (bytes32);
    function poolInitialized() external view returns (bool);
    function startingPrice() external view returns (uint256);
    function endingPrice() external view returns (uint256);
    function priceDuration() external view returns (uint256);
    function tokensSold() external view returns (uint256);
    function accumulatedUSDC() external view returns (uint256);
    function itoStartTime() external view returns (uint256);
    function itoEndTime() external view returns (uint256);
    function minPurchaseUSDC() external view returns (uint256);
    function maxPurchaseUSDC() external view returns (uint256);
    function purchasesPaused() external view returns (bool);
    function treasuryMultiSig() external view returns (address);
    function stakingRewards() external view returns (address);
    function liquidityPool() external view returns (address);
    function api3Airnode() external view returns (address);
    function api3EndpointId() external view returns (bytes32);
    function api3SponsorWallet() external view returns (address);
    function purchasedAmounts(address) external view returns (uint256);
    function blacklist(address) external view returns (bool);
    function positionIds(uint256) external view returns (uint256);
    function pendingRequests(bytes32) external view returns (bool);
    function processedCcipMessages(bytes32) external view returns (bool);
    function trustedSourceChains(uint64) external view returns (bool);
    function itoState() external view returns (ITOState);
    function positionCounter() external view returns (uint256);
    function latestApi3Price() external view returns (uint256);
    function pendingApi3Request() external view returns (bool);
    function twapTolerance() external view returns (uint256);
    function liquiditySyncThreshold() external view returns (uint256);
    function syncChainSelectors(uint256) external view returns (uint64);
    function twapObservations(uint256) external view returns (uint256 timestamp, uint160 sqrtPriceX96, uint128 liquidity);
    function lastTwapObservationTime() external view returns (uint256);
    function twapObservationMaxAge() external view returns (uint256);
    function participantTiers(address) external view returns (ParticipantTier);
    function participantVesting(address) external view returns (
        uint256 totalAmount,
        uint256 initialUnlock,
        uint256 cliffPeriod,
        uint256 vestingDuration,
        uint256 startTime,
        uint256 claimedAmount,
        uint256 lastClaimTime
    );
    function initialUnlockClaimed(address) external view returns (uint256);
    function ecosystemVesting(VestingType) external view returns (
        uint256 totalAmount,
        uint256 initialUnlock,
        uint256 cliffPeriod,
        uint256 vestingDuration,
        uint256 startTime,
        uint256 claimedAmount,
        uint256 lastClaimTime
    );
    function vestingMilestones(uint256) external view returns (
        uint256 targetPrice,
        uint256 accelerationPercent,
        bool achieved
    );
}
