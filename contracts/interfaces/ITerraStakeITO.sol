// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ITerraStakeITO {
    // ================================
    // 🔹 Enumerations
    // ================================
    enum ITOState { NotStarted, Active, Ended }
    enum VestingType { Treasury, Staking, Liquidity }

    // ================================
    // 🔹 Structs
    // ================================
    struct VestingSchedule {
        uint256 totalAmount;
        uint256 initialUnlock;
        uint256 startTime;
        uint256 duration;
        uint256 claimedAmount;
        uint256 lastClaimTime;
    }

    // ================================
    // 🔹 Events
    // ================================
    event TokensPurchased(address indexed buyer, uint256 usdcAmount, uint256 tokenAmount, uint256 timestamp);
    event LiquidityAdded(uint256 usdcAmount, uint256 tStakeAmount, uint256 timestamp);
    event ITOStateChanged(ITOState newState);
    event PriceUpdated(uint256 newPrice);
    event PurchaseLimitsUpdated(uint256 newMin, uint256 newMax);
    event BlacklistStatusUpdated(address indexed account, bool status);
    event EmergencyWithdrawal(address token, uint256 amount);
    event PurchasesPaused(bool status);
    event VestingScheduleInitialized(VestingType vestingType, uint256 totalAmount);
    event VestingClaimed(VestingType vestingType, uint256 amount, uint256 timestamp);
    event TokensBurned(uint256 amount, uint256 timestamp, uint256 newTotalSupply);

    // ================================
    // 🔹 Constants
    // ================================
    function POOL_FEE() external view returns (uint24);
    function MAX_TOKENS_FOR_ITO() external view returns (uint256);
    function DEFAULT_MIN_PURCHASE_USDC() external view returns (uint256);
    function DEFAULT_MAX_PURCHASE_USDC() external view returns (uint256);

    // ================================
    // 🔹 State Variables
    // ================================
    function tStakeToken() external view returns (address);
    function usdcToken() external view returns (address);
    function positionManager() external view returns (address);
    function uniswapPool() external view returns (address);
    function treasuryMultiSig() external view returns (address);
    function stakingRewards() external view returns (address);
    function liquidityPool() external view returns (address);
    
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
    function purchasedAmounts(address) external view returns (uint256);
    function blacklist(address) external view returns (bool);
    function itoState() external view returns (ITOState);
    function vestingSchedules(VestingType) external view returns (VestingSchedule memory);

    // ================================
    // 🔹 Administrative Functions
    // ================================
    function setITOState(ITOState newState) external;
    function togglePurchases(bool paused) external;
    function updatePurchaseLimits(uint256 newMin, uint256 newMax) external;
    function updateBlacklist(address account, bool status) external;

    // ================================
    // 🔹 Vesting Functions
    // ================================
    function claimVestedFunds(VestingType vestingType) external;
    function getVestedAmount(VestingType vestingType) external view returns (uint256);

    // ================================
    // 🔹 Pricing Functions
    // ================================
    function getCurrentPrice() external view returns (uint256);
    function updatePricingParameters(
        uint256 newStartPrice,
        uint256 newEndPrice,
        uint256 newDuration
    ) external;

    // ================================
    // 🔹 Purchase & Distribution Functions
    // ================================
    function buyTokens(uint256 usdcAmount, uint256 minTokensOut) external;

    // ================================
    // 🔹 Token Burning Function
    // ================================
    function burnUnsoldTokens() external;

    // ================================
    // 🔹 Emergency Functions
    // ================================
    function emergencyWithdraw(address token) external;

    // ================================
    // 🔹 View Functions
    // ================================
    function getITOStats() external view returns (
        uint256 totalSold,
        uint256 remaining,
        uint256 currentPrice,
        ITOState state
    );
}
