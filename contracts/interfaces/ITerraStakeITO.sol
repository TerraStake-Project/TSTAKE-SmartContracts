// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

/**
 * @title ITerraStakeITO
 * @notice Interface for the TerraStake Initial Token Offering (ITO) contract on Arbitrum
 * @dev Handles token sales, dynamic pricing, Uniswap V4 liquidity injection, vesting schedules, 
 * blacklist management, emergency withdrawals, unsold token burning, LayerZero cross-chain sync, 
 * API3 price validation, and TWAP checks with adjustable parameters.
 */
interface ITerraStakeITO {
    enum ITOState { NotStarted, Active, Ended }

    // ================================
    //  Vesting Struct & Variables
    // ================================
    enum VestingType { Treasury, Staking, Liquidity }
    struct VestingSchedule {
        uint256 totalAmount;
        uint256 initialUnlock; // percentage (e.g., 10 for 10%)
        uint256 startTime;
        uint256 duration;
        uint256 claimedAmount;
        uint256 lastClaimTime;
    }

    // ================================
    //  Events
    // ================================
    event TokensPurchased(address indexed buyer, uint256 usdcAmount, uint256 tokenAmount, uint256 timestamp);
    event LiquidityAdded(uint256 usdcAmount, uint256 tStakeAmount, uint256 positionId, uint256 timestamp);
    event ITOStateChanged(ITOState newState);
    event PriceUpdated(uint256 newStartPrice, uint256 newEndPrice, uint256 newDuration);
    event PurchaseLimitsUpdated(uint256 newMin, uint256 newMax);
    event BlacklistStatusUpdated(address indexed account, bool status);
    event EmergencyWithdrawal(address token, uint256 amount);
    event PurchasesPaused(bool status);
    event VestingScheduleInitialized(VestingType vestingType, uint256 totalAmount);
    event VestingClaimed(VestingType vestingType, uint256 amount, uint256 timestamp);
    event TokensBurned(uint256 amount, uint256 timestamp, uint256 newTotalSupply);
    event StateSynced(uint16 indexed chainId, bytes32 indexed payloadHash, uint256 nonce);
    event LiquiditySynced(uint256 usdcAmount, uint256 tStakeAmount);
    event Api3PriceUpdated(uint256 price, uint256 timestamp);
    event Api3RequestMade(bytes32 requestId);
    event TWAPToleranceUpdated(uint256 newTolerance); // Added for adjustable TWAP tolerance
    event SequencerCooldownUpdated(uint256 newCooldown); // Added for adjustable sequencer cooldown
    event LiquiditySyncThresholdUpdated(uint256 newThreshold); // Added for adjustable liquidity sync threshold

    // ================================
    //  Administrative Controls
    // ================================
    /**
     * @notice Sets the AntiBot contract address for transaction validation
     * @param _antiBot Address of the AntiBot contract
     */
    function setAntiBot(address _antiBot) external;

    /**
     * @notice Sets the Arbitrum Sequencer Oracle address
     * @param _oracle Address of the sequencer oracle
     */
    function setSequencerOracle(address _oracle) external;

    /**
     * @notice Sets the Uniswap V4 hook contract address
     * @param _hook Address of the Uniswap V4 hook contract
     */
    function setUniswapV4Hook(address _hook) external;

    /**
     * @notice Sets the API3 oracle configuration for price validation
     * @param _airnode API3 Airnode address
     * @param _endpointId Endpoint ID for tStake/USDC price
     * @param _sponsorWallet Sponsor wallet address
     */
    function setApi3Config(address _airnode, bytes32 _endpointId, address _sponsorWallet) external;

    /**
     * @notice Sets the ITO state (NotStarted, Active, Ended)
     * @param newState New state to set
     */
    function setITOState(ITOState newState) external;

    /**
     * @notice Toggles purchase functionality
     * @param paused True to pause, false to unpause
     */
    function togglePurchases(bool paused) external;

    /**
     * @notice Updates minimum and maximum purchase limits in USDC
     * @param newMin New minimum purchase amount
     * @param newMax New maximum purchase amount
     */
    function updatePurchaseLimits(uint256 newMin, uint256 newMax) external;

    /**
     * @notice Updates pricing parameters before ITO starts
     * @param newStartPrice New starting price in wei
     * @param newEndPrice New ending price in wei
     * @param newDuration New duration in seconds
     */
    function updatePricingParameters(uint256 newStartPrice, uint256 newEndPrice, uint256 newDuration) external;

    /**
     * @notice Sets the TWAP deviation tolerance
     * @param newTolerance New tolerance value (e.g., 5 * 10**16 for 5%)
     */
    function setTWAPTolerance(uint256 newTolerance) external;

    /**
     * @notice Sets the sequencer cooldown period after downtime
     * @param newCooldown New cooldown period in seconds
     */
    function setSequencerCooldown(uint256 newCooldown) external;

    /**
     * @notice Sets the threshold for automatic liquidity syncing
     * @param newThreshold New threshold in USDC (e.g., 50_000 * 10**6)
     */
    function setLiquiditySyncThreshold(uint256 newThreshold) external;

    // ================================
    //  Blacklist Management
    // ================================
    /**
     * @notice Updates blacklist status for an account
     * @param account Address to update
     * @param status True to blacklist, false to remove
     */
    function updateBlacklist(address account, bool status) external;

    /**
     * @notice Checks if an account is blacklisted
     * @param account Address to check
     * @return True if blacklisted, false otherwise
     */
    function blacklist(address account) external view returns (bool);

    // ================================
    //  Vesting Management
    // ================================
    /**
     * @notice Gets the vested amount available for a vesting type
     * @param vestingType Type of vesting (Treasury, Staking, Liquidity)
     * @return Amount of USDC vested and unclaimed
     */
    function getVestedAmount(VestingType vestingType) external view returns (uint256);

    /**
     * @notice Claims vested funds for a specific vesting type (Treasury or Staking)
     * @param vestingType Type of vesting to claim (Treasury, Staking)
     */
    function claimVestedFunds(VestingType vestingType) external;

    /**
     * @notice Releases vested liquidity to the Uniswap V4 pool after the cliff
     */
    function releaseVestedLiquidity() external;

    // ================================
    //  Price Management
    // ================================
    /**
     * @notice Gets the current dynamic price of tStake in USD wei
     * @return Current price
     */
    function getCurrentPrice() external view returns (uint256);

    // ================================
    //  Purchase Function
    // ================================
    /**
     * @notice Purchases tStake tokens with USDC
     * @param usdcAmount Amount of USDC to spend
     * @param minTokensOut Minimum tStake tokens expected
     */
    function buyTokens(uint256 usdcAmount, uint256 minTokensOut) external;

    // ================================
    //  Burn Unsold Tokens Function
    // ================================
    /**
     * @notice Burns unsold tStake tokens after ITO ends
     */
    function burnUnsoldTokens() external;

    // ================================
    //  Emergency Functions
    // ================================
    /**
     * @notice Withdraws a token balance in emergency after ITO ends
     * @param token Address of the token to withdraw
     */
    function emergencyWithdraw(address token) external;

    // ================================
    //  Liquidity and Sync Functions
    // ================================
    /**
     * @notice Manually syncs liquidity to the Uniswap V4 pool
     */
    function syncLiquidity() external;

    /**
     * @notice Requests the latest tStake/USDC price from API3 oracle
     */
    function requestApi3Price() external;

    /**
     * @notice Gets the TWAP price from the Uniswap V4 pool
     * @return TWAP price in USD wei
     */
    function getTWAPPrice() external view returns (uint256);

    /**
     * @notice Rebalances a liquidity position in Uniswap V4
     * @param positionId ID of the position to rebalance
     * @param newLiquidityParams New liquidity parameters
     */
    function rebalanceLiquidityPosition(
        uint256 positionId,
        IPositionManager.ModifyPositionParams calldata newLiquidityParams
    ) external;

    /**
     * @notice Collects fees from a Uniswap V4 liquidity position
     * @param positionId ID of the position to collect fees from
     * @param recipient Address to receive the fees
     */
    function collectPositionFees(uint256 positionId, address recipient) external;

    // ================================
    //  View Functions
    // ================================
    /**
     * @notice Gets current ITO statistics
     * @return totalSold Total tStake tokens sold
     * @return remaining Remaining tStake tokens available
     * @return currentPrice Current price in USD wei
     * @return state Current ITO state
     */
    function getITOStats() external view returns (
        uint256 totalSold,
        uint256 remaining,
        uint256 currentPrice,
        ITOState state
    );

    /**
     * @notice Gets the current sqrtPriceX96 from the Uniswap V4 pool
     * @return sqrtPriceX96 Current pool price
     */
    function getPoolPrice() external view returns (uint160 sqrtPriceX96);

    /**
     * @notice Gets the total supply of tStake tokens
     * @return Total supply
     */
    function totalSupply() external view returns (uint256);
}