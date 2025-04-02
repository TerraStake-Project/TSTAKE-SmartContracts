// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/**
 * @title ITerraStakeToken
 * @notice Interface for the TerraStakeToken contract, an advanced ERC20 token with Uniswap V4 integration,
 * cross-chain synchronization, and comprehensive economic controls.
 * @dev Matches TerraStakeToken v1.0, supporting halving mechanisms, liquidity management, and AI-driven indexing.
 */
interface ITerraStakeToken {
    // ============ Structs ============

    /**
     * @notice Statistics for token buyback operations.
     * @param totalTokensBought Total tokens repurchased.
     * @param totalUSDCSpent Total USDC spent on buybacks.
     * @param lastBuybackTime Timestamp of the most recent buyback.
     * @param buybackCount Number of buyback operations performed.
     */
    struct BuybackStats {
        uint256 totalTokensBought;
        uint256 totalUSDCSpent;
        uint256 lastBuybackTime;
        uint256 buybackCount;
    }

    /**
     * @notice Cross-chain halving state for synchronization.
     * @param epoch Current halving epoch.
     * @param timestamp Timestamp of the last halving.
     * @param totalSupply Token supply at the time of halving.
     * @param halvingPeriod Duration of the halving cycle.
     */
    struct CrossChainHalving {
        uint256 epoch;
        uint256 timestamp;
        uint256 totalSupply;
        uint256 halvingPeriod;
    }

    /**
     * @notice Time-weighted average price (TWAP) observation for Uniswap V4 pool.
     * @param blockTimestamp Timestamp of the observation.
     * @param sqrtPriceX96 Square root price in X96 format.
     * @param liquidity Pool liquidity at the observation.
     */
    struct TWAPObservation {
        uint32 blockTimestamp;
        uint160 sqrtPriceX96;
        uint128 liquidity;
    }

    /**
     * @notice Uniswap V4 liquidity position details.
     * @param tickLower Lower tick boundary of the position.
     * @param tickUpper Upper tick boundary of the position.
     * @param liquidity Amount of liquidity provided.
     * @param tokenId Unique identifier for the position.
     * @param isActive Whether the position is currently active.
     */
    struct PoolPosition {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 tokenId;
        bool isActive;
    }

    /**
     * @notice Information about the Uniswap V4 pool.
     * @param id Pool identifier.
     * @param sqrtPriceX96 Current square root price in X96 format.
     * @param tick Current pool tick.
     * @param observationIndex Index of the latest TWAP observation.
     * @param observationCardinality Number of TWAP observations stored.
     * @param fee Pool fee in basis points.
     */
    struct PoolInfo {
        bytes32 id;
        uint160 sqrtPriceX96;
        int24 tick;
        uint16 observationIndex;
        uint16 observationCardinality;
        uint24 fee;
    }

    // ============ Events ============

    event BlacklistUpdated(address indexed account, bool isBlacklisted);
    event AirdropExecuted(address[] recipients, uint256 amountPerRecipient, uint256 totalAmount);
    event TWAPPriceUpdated(uint256 newPrice);
    event TokenBurned(address indexed burner, uint256 amount);
    event GovernanceUpdated(address indexed newGovernanceContract);
    event StakingUpdated(address indexed newStakingContract);
    event LiquidityGuardUpdated(address indexed newLiquidityGuard);
    event BuybackExecuted(uint256 usdcAmount, uint256 tokensReceived, uint256 price);
    event LiquidityInjected(uint256 usdcAmount, uint256 tokensUsed);
    event HalvingTriggered(uint256 epochNumber, uint256 timestamp);
    event CrossChainSyncSuccessful(uint16 indexed chainId);
    event HalvingSyncFailed();
    event CrossChainHandlerUpdated(address indexed newCrossChainHandler);
    event CrossChainMessageSent(uint16 indexed destChainId, bytes32 indexed payloadHash, uint256 nonce);
    event CrossChainStateUpdated(uint16 indexed srcChainId, ICrossChainHandler.CrossChainState state);
    event AntiBotUpdated(address indexed newAntiBot);
    event TransactionThrottled(address indexed user, uint256 cooldownEnds);
    event ChainSupportUpdated(uint16 indexed chainId, bool isSupported);
    event EmissionRateUpdated(uint256 newRate);
    event PoolInitialized(bytes32 indexed poolId, PoolKey poolKey, uint160 sqrtPriceX96);
    event PositionCreated(uint256 indexed positionId, int24 tickLower, int24 tickUpper, uint128 liquidity);
    event PositionModified(uint256 indexed positionId, int128 liquidityDelta);
    event PositionBurned(uint256 indexed positionId);
    event TWAPObservationRecorded(bytes32 indexed poolId, uint32 timestamp, uint160 sqrtPriceX96, uint128 liquidity);
    event SwapExecuted(bytes32 indexed poolId, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);
    event HookRegistered(bytes32 indexed poolId, address hookAddress);
    event TokensMinted(address indexed recipient, uint256 amount);
    event StakingMint(uint256 amount);
    event GovernanceMint(uint256 amount);
    event MaxGasPriceUpdated(uint256 newMaxGasPrice);
    event TwapDeviationThresholdUpdated(uint256 newThreshold);
    event HalvingToMintUpdated(bool isApplied);
    event BuybackBudgetTransferred(uint256 amount, address indexed recipient);

    // ============ Errors ============

    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error TWAPUpdateCooldown();
    error MaxSupplyExceeded();
    error InvalidPool();
    error PoolNotInitialized();
    error NeuralManagerNotSet();
    error CrossChainHandlerNotSet();
    error CrossChainSyncFailed(bytes reason);
    error InvalidChainId();
    error StaleMessage();
    error TransactionThrottledError(); // Renamed to avoid conflict with event
    error PoolAlreadyInitialized();
    error InvalidTickRange();
    error SwapSlippageExceeded();
    error PositionNotFound();
    error InsufficientLiquidity();
    error InvalidHookConfiguration();
    error CallbackNotAuthorized();
    error InvalidSqrtPriceLimit();
    error MaxGasPriceExceeded();
    error TransferAmountTooSmall();
    error SenderIsBot();
    error ReceiverIsBot();

    // ============ Initialization ============

    /**
     * @notice Initializes the token contract with core dependencies.
     * @param poolManager Uniswap V4 pool manager address.
     * @param governanceContract Governance contract address.
     * @param stakingContract Staking contract address.
     * @param liquidityGuard Liquidity guard contract address.
     * @param aiEngine AI engine contract address (optional).
     * @param priceFeed Price feed oracle address.
     * @param gasOracle Gas price oracle address.
     * @param neuralManager Neural manager contract address.
     * @param crossChainHandler Cross-chain handler address (optional).
     * @param antiBot Anti-bot contract address (optional).
     */
    function initialize(
        address poolManager,
        address governanceContract,
        address stakingContract,
        address liquidityGuard,
        address aiEngine,
        address priceFeed,
        address gasOracle,
        address neuralManager,
        address crossChainHandler,
        address antiBot
    ) external;

    // ============ Uniswap V4 Integration ============

    /**
     * @notice Initializes a Uniswap V4 pool for the token.
     * @param currency0 First token in the pool (e.g., stablecoin).
     * @param currency1 Second token in the pool (e.g., this token).
     * @param fee Pool fee in basis points.
     * @param hook Hook contract for the pool.
     * @param hookData Additional data for hook initialization.
     * @param sqrtPriceX96 Initial square root price in X96 format.
     */
    function initializePool(
        Currency currency0,
        Currency currency1,
        uint24 fee,
        IHooks hook,
        bytes calldata hookData,
        uint160 sqrtPriceX96
    ) external;

    /**
     * @notice Adds liquidity to a Uniswap V4 pool position.
     * @param tickLower Lower tick boundary.
     * @param tickUpper Upper tick boundary.
     * @param liquidityDesired Amount of liquidity to add.
     * @param recipient Recipient of the position.
     * @return positionId ID of the created position.
     * @return liquidityActual Actual liquidity added.
     */
    function addLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityDesired,
        address recipient
    ) external returns (uint256 positionId, uint128 liquidityActual);

    /**
     * @notice Removes liquidity from a Uniswap V4 position.
     * @param positionId ID of the position.
     * @param liquidityToRemove Amount of liquidity to remove (0 for all).
     * @param recipient Recipient of the withdrawn tokens.
     * @return amount0 Amount of token0 withdrawn.
     * @return amount1 Amount of token1 withdrawn.
     */
    function removeLiquidity(
        uint256 positionId,
        uint128 liquidityToRemove,
        address recipient
    ) external returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Executes a swap through the Uniswap V4 pool.
     * @param tokenIn Input token address.
     * @param tokenOut Output token address.
     * @param amountIn Input token amount.
     * @param amountOutMinimum Minimum output amount (slippage protection).
     * @param sqrtPriceLimitX96 Price limit for the swap.
     * @param recipient Recipient of the output tokens.
     * @return amountOut Amount of output tokens received.
     */
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint160 sqrtPriceLimitX96,
        address recipient
    ) external returns (uint256 amountOut);

    /**
     * @notice Handles Uniswap V4 hook callbacks.
     * @param sender Sender of the callback.
     * @param key Pool key for the callback.
     * @param data Callback data.
     */
    function v4HookCallback(address sender, PoolKey calldata key, bytes calldata data) external;

    /**
     * @notice Retrieves the time-weighted average price (TWAP) for a given period.
     * @param period Time period for TWAP calculation.
     * @return twapPrice Calculated TWAP price.
     */
    function getTWAPPrice(uint32 period) external view returns (uint256 twapPrice);

    /**
     * @notice Updates the TWAP price from the Uniswap V4 pool.
     */
    function updateTWAPPrice() external;

    /**
     * @notice Forces an update of TWAP observations with the current pool state.
     */
    function forceUpdateTWAPObservation() external;

    /**
     * @notice Sets the TWAP observation window.
     * @param newWindow New observation window in seconds.
     */
    function setTWAPObservationWindow(uint32 newWindow) external;

    // ============ Halving Mechanism ============

    /**
     * @notice Applies the halving mechanism to reduce emission rates.
     */
    function applyHalving() external;

    /**
     * @notice Triggers a halving across token, staking, and governance contracts.
     * @return epoch New halving epoch number.
     */
    function triggerHalving() external returns (uint256 epoch);

    // ============ Cross-Chain Functions ============

    /**
     * @notice Sets the cross-chain handler contract address.
     * @param crossChainHandler New cross-chain handler address.
     */
    function setCrossChainHandler(address crossChainHandler) external;

    /**
     * @notice Sets the anti-bot contract address.
     * @param antiBot New anti-bot contract address.
     */
    function setAntiBot(address antiBot) external;

    /**
     * @notice Adds support for a new chain ID.
     * @param chainId Chain ID to support.
     */
    function addSupportedChain(uint16 chainId) external;

    /**
     * @notice Removes support for a chain ID.
     * @param chainId Chain ID to remove.
     */
    function removeSupportedChain(uint16 chainId) external;

    /**
     * @notice Synchronizes state across supported chains.
     */
    function syncStateToChains() external;

    /**
     * @notice Executes a remote token action (e.g., minting) on this chain.
     * @param srcChainId Source chain ID.
     * @param recipient Recipient address for the tokens.
     * @param amount Amount of tokens to mint.
     * @param txreference Unique transaction reference.
     */
    function executeRemoteTokenAction(
        uint16 srcChainId,
        address recipient,
        uint256 amount,
        bytes32 txreference
    ) external;

    /**
     * @notice Updates the contract state from a cross-chain message.
     * @param srcChainId Source chain ID.
     * @param state Cross-chain state data.
     */
    function updateFromCrossChain(uint16 srcChainId, ICrossChainHandler.CrossChainState calldata state) external;

    // ============ Token Economics ============

    /**
     * @notice Executes a token buyback using USDC.
     * @param usdcAmount Amount of USDC to spend.
     */
    function executeBuyback(uint256 usdcAmount) external;

    /**
     * @notice Injects liquidity into the Uniswap V4 pool.
     * @param usdcAmount Amount of USDC to use.
     * @param tickLower Lower tick boundary.
     * @param tickUpper Upper tick boundary.
     * @return positionId ID of the created liquidity position.
     */
    function injectLiquidity(
        uint256 usdcAmount,
        int24 tickLower,
        int24 tickUpper
    ) external returns (uint256 positionId);

    // ============ Token Transfers ============

    /**
     * @notice Sets tax-exempt status for an account.
     * @param account Account to update.
     * @param isExempt Whether the account is tax-exempt.
     */
    function setTaxExempt(address account, bool isExempt) external;

    /**
     * @notice Sets blacklist status for an account.
     * @param account Account to update.
     * @param isBlacklisted Whether the account is blacklisted.
     */
    function setBlacklisted(address account, bool isBlacklisted) external;

    /**
     * @notice Sets tax rates for transactions.
     * @param buybackTaxBasisPoints Buyback tax in basis points.
     * @param burnRateBasisPoints Burn rate in basis points.
     */
    function setTaxRates(uint256 buybackTaxBasisPoints, uint256 burnRateBasisPoints) external;

    // ============ Administrative Functions ============

    /**
     * @notice Pauses token transfers.
     */
    function pause() external;

    /**
     * @notice Unpauses token transfers.
     */
    function unpause() external;

    /**
     * @notice Updates the governance contract address.
     * @param governanceContract New governance contract address.
     */
    function setGovernanceContract(address governanceContract) external;

    /**
     * @notice Updates the staking contract address.
     * @param stakingContract New staking contract address.
     */
    function setStakingContract(address stakingContract) external;

    /**
     * @notice Updates the liquidity guard contract address.
     * @param liquidityGuard New liquidity guard contract address.
     */
    function setLiquidityGuard(address liquidityGuard) external;

    /**
     * @notice Updates the neural manager contract address.
     * @param neuralManager New neural manager contract address.
     */
    function setNeuralManager(address neuralManager) external;

    /**
     * @notice Sets the maximum gas price for transactions.
     * @param maxGasPrice New maximum gas price in wei.
     */
    function setMaxGasPrice(uint256 maxGasPrice) external;

    /**
     * @notice Sets the TWAP deviation threshold.
     * @param threshold New threshold in basis points.
     */
    function setTwapDeviationThreshold(uint256 threshold) external;

    /**
     * @notice Updates the emission rate for minting.
     * @param emissionRate New emission rate.
     */
    function updateEmissionRate(uint256 emissionRate) external;

    /**
     * @notice Sets whether halving is applied to minting operations.
     * @param isApplied Whether to apply halving to minting.
     */
    function setApplyHalvingToMint(bool isApplied) external;

    /**
     * @notice Transfers buyback budget to a treasury address.
     * @param amount Amount to transfer.
     * @param recipient Treasury address.
     */
    function transferBuybackBudget(uint256 amount, address recipient) external;

    // ============ Minting ============

    /**
     * @notice Mints new tokens for rewards or staking programs.
     * @param recipient Recipient address.
     * @param amount Amount to mint.
     * @return adjustedAmount Actual amount minted after halving adjustments.
     */
    function mint(address recipient, uint256 amount) external returns (uint256 adjustedAmount);

    /**
     * @notice Mints tokens directly to the staking contract.
     * @param amount Amount to mint.
     * @return adjustedAmount Actual amount minted after halving adjustments.
     */
    function mintToStaking(uint256 amount) external returns (uint256 adjustedAmount);

    /**
     * @notice Mints tokens for governance rewards.
     * @param amount Amount to mint.
     * @return adjustedAmount Actual amount minted after halving adjustments.
     */
    function mintForGovernance(uint256 amount) external returns (uint256 adjustedAmount);

    /**
     * @notice Burns tokens from the caller's balance.
     * @param amount Amount to burn.
     */
    function burn(uint256 amount) external;

    /**
     * @notice Burns tokens from a specific account with approval.
     * @param account Account to burn from.
     * @param amount Amount to burn.
     */
    function burnFrom(address account, uint256 amount) external;

    // ============ View Functions ============

    /**
     * @notice Retrieves buyback operation statistics.
     * @return stats Buyback statistics.
     */
    function getBuybackStatistics() external view returns (BuybackStats memory stats);

    /**
     * @notice Retrieves Uniswap V4 pool information.
     * @return poolInfo Current pool details.
     */
    function getPoolInfo() external view returns (PoolInfo memory poolInfo);

    /**
     * @notice Retrieves details of a specific liquidity position.
     * @param positionId Position ID.
     * @return position Position details.
     */
    function getPosition(uint256 positionId) external view returns (PoolPosition memory position);

    /**
     * @notice Retrieves the current halving status.
     * @return epoch Current halving epoch.
     * @return lastTime Timestamp of the last halving.
     * @return nextTime Timestamp of the next expected halving.
     */
    function getHalvingStatus() external view returns (uint256 epoch, uint256 lastTime, uint256 nextTime);

    /**
     * @notice Retrieves the current buyback budget.
     * @return amount Available buyback budget.
     */
    function getBuybackBudget() external view returns (uint256 amount);

    /**
     * @notice Retrieves the contract version.
     * @return version Version string (e.g., "TerraStakeToken v1.0").
     */
    function version() external pure returns (string memory version);

    /**
     * @notice Retrieves the token standard name.
     * @return name Standard name (e.g., "TerraStake ERC20").
     */
    function tokenStandard() external pure returns (string memory name);
}

interface ICrossChainHandler {
    struct CrossChainState {
        uint256 halvingEpoch;
        uint256 timestamp;
        uint256 totalSupply;
        uint256 lastTWAPPrice;
        uint256 emissionRate;
    }
}