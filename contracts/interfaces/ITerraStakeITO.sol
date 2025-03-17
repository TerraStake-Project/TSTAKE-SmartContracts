// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

/**
 * @title ITerraStakeITO
 * @notice Interface for the Official TerraStake Initial Token Offering (ITO) contract
 * @dev Handles token sales, dynamic pricing, liquidity injection, vesting schedules, blacklist management,
 * emergency withdrawals, unsold token burning, and transaction validation through AntiBot system.
 */
interface ITerraStakeITO {
    enum ITOState { NotStarted, Active, Ended }

    // ================================
    //  Vesting Struct & Variables
    // ================================
    enum VestingType { Treasury, Staking, Liquidity }
    struct VestingSchedule {
        uint256 totalAmount;
        uint256 initialUnlock; // percentage (e.g. 10 for 10%)
        uint256 startTime;
        uint256 duration;
        uint256 claimedAmount;
        uint256 lastClaimTime;
    }

    // ================================
    //  Events
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

    /**
     * @notice Sets the AntiBot contract address for transaction validation
     * @param _antiBot Address of the AntiBot contract
     */
    function setAntiBot(address _antiBot) external;

    // ================================
    //  Administrative Controls
    // ================================
    function setITOState(ITOState newState) external;

    function togglePurchases(bool paused) external;

    function updatePurchaseLimits(uint256 newMin, uint256 newMax) external;

    // ================================
    //  Blacklist Management
    // ================================
    function updateBlacklist(address account, bool status) external;

    // ================================
    //  Vesting Management
    // ================================
    function getVestedAmount(VestingType vestingType) external view returns (uint256);

    function claimVestedFunds(VestingType vestingType) external;

    // ================================
    //  Price Management
    // ================================
    function getCurrentPrice() external view returns (uint256);

    function updatePricingParameters(
        uint256 newStartPrice,
        uint256 newEndPrice,
        uint256 newDuration
    ) external;

    // ================================
    //  Purchase Function
    // ================================
    function buyTokens(uint256 usdcAmount, uint256 minTokensOut) external;

    // ================================
    //  Burn Unsold Tokens Function
    // ================================
    function burnUnsoldTokens() external;

    // ================================
    //  Emergency Functions
    // ================================
    function emergencyWithdraw(address token) external;

    // ================================
    //  View Functions
    // ================================
    function getITOStats() external view returns (
        uint256 totalSold,
        uint256 remaining,
        uint256 currentPrice,
        ITOState state
    );
}

