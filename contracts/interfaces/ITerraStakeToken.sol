// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

/**
 * @title ITerraStakeToken
 * @notice Interface for TerraStake's enhanced ERC20 token with governance, staking, and economic controls
 * @dev Includes all public/external functionality including cross-chain and halving mechanisms
 */
interface ITerraStakeToken is IERC20Upgradeable {
    // ============ Structs ============
    struct BuybackStats {
        uint256 totalTokensBought;
        uint256 totalUSDCSpent;
        uint256 lastBuybackTime;
        uint256 buybackCount;
    }

    struct CrossChainHalving {
        uint256 epoch;
        uint256 timestamp;
        uint256 totalSupply;
        uint256 halvingPeriod;
    }

    // ============ Constants ============
    function MAX_SUPPLY() external pure returns (uint256);
    function MIN_TWAP_PERIOD() external pure returns (uint32);
    function MAX_BATCH_SIZE() external pure returns (uint256);
    function PRICE_DECIMALS() external pure returns (uint256);
    function LARGE_TRANSFER_THRESHOLD() external pure returns (uint256);
    function MAX_VOLATILITY_THRESHOLD() external pure returns (uint256);
    function TWAP_UPDATE_COOLDOWN() external pure returns (uint256);
    function BUYBACK_TAX_BASIS_POINTS() external pure returns (uint256);
    function MAX_TAX_BASIS_POINTS() external pure returns (uint256);
    function BURN_RATE_BASIS_POINTS() external pure returns (uint256);
    function HALVING_RATE() external pure returns (uint256);

    // ============ State Getters ============
    function poolManager() external view returns (IPoolManager);
    function poolKey() external view returns (PoolKey memory);
    function poolId() external view returns (bytes32);
    function governanceContract() external view returns (ITerraStakeGovernance);
    function stakingContract() external view returns (ITerraStakeStaking);
    function liquidityGuard() external view returns (ITerraStakeLiquidityGuard);
    function aiEngine() external view returns (IAIEngine);
    function neuralManager() external view returns (ITerraStakeNeural);
    function crossChainHandler() external view returns (ICrossChainHandler);
    function antiBot() external view returns (IAntiBot);
    function priceFeed() external view returns (IProxy);
    function gasOracle() external view returns (IProxy);
    function lastTWAPPrice() external view returns (uint256);
    function lastTWAPUpdate() external view returns (uint256);
    function maxGasPrice() external view returns (uint256);
    function buybackBudget() external view returns (uint256);
    function buybackTotalAmount() external view returns (uint256);
    function buybackStatistics() external view returns (BuybackStats memory);
    function currentHalvingEpoch() external view returns (uint256);
    function lastHalvingTime() external view returns (uint256);
    function applyHalvingToMint() external view returns (bool);
    function emissionRate() external view returns (uint256);
    function isBlacklisted(address account) external view returns (bool);
    function taxExempt(address account) external view returns (bool);
    function supportedChainIds(uint16 chainId) external view returns (bool);
    function buybackTaxBasisPoints() external view returns (uint256);
    function burnRateBasisPoints() external view returns (uint256);
    function twapDeviationThreshold() external view returns (uint256);
    function lastConfirmedTWAPPrice() external view returns (uint256);

    // ============ Role Getters ============
    function MINTER_ROLE() external pure returns (bytes32);
    function ADMIN_ROLE() external pure returns (bytes32);
    function UPGRADER_ROLE() external pure returns (bytes32);
    function LIQUIDITY_MANAGER_ROLE() external pure returns (bytes32);
    function NEURAL_INDEXER_ROLE() external pure returns (bytes32);
    function AI_MANAGER_ROLE() external pure returns (bytes32);
    function PRICE_ORACLE_ROLE() external pure returns (bytes32);
    function CROSS_CHAIN_OPERATOR_ROLE() external pure returns (bytes32);
    function GOVERNANCE_ROLE() external pure returns (bytes32);

    // ============ Core Functions ============
    function initialize(
        address _poolManager,
        address _governanceContract,
        address _stakingContract,
        address _liquidityGuard,
        address _aiEngine,
        address _priceFeed,
        address _gasOracle,
        address _neuralManager,
        address _crossChainHandler,
        address _antiBot
    ) external;

    function mint(address to, uint256 amount) external;
    function burnFrom(address from, uint256 amount) external;
    function permitAndTransfer(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        address to,
        uint256 amount
    ) external;

    // ============ Cross-Chain Functions ============
    function setCrossChainHandler(address _crossChainHandler) external;
    function setAntiBot(address _antiBot) external;
    function addSupportedChain(uint16 chainId) external;
    function removeSupportedChain(uint16 chainId) external;
    function syncStateToChains() external;
    function executeRemoteTokenAction(
        uint16 srcChainId,
        address recipient,
        uint256 amount,
        bytes32 reference
    ) external;
    function updateFromCrossChain(
        uint16 srcChainId,
        ICrossChainHandler.CrossChainState calldata state
    ) external;

    // ============ Halving Mechanism ============
    function applyHalving() external;
    function triggerHalving() external returns (uint256);

    // ============ Token Economics ============
    function executeBuyback(uint256 usdcAmount) external;

    // ============ Security Functions ============
    function pause() external;
    function unpause() external;

    // ============ Admin Functions ============
    function setBlacklist(address account, bool status) external;
    function batchBlacklist(address[] calldata accounts, bool status) external;
    function setTaxExemption(address account, bool exempt) external;
    function batchSetTaxExemption(address[] calldata accounts, bool exempt) external;
    function setBuybackTax(uint256 taxBps) external;
    function setBurnRate(uint256 burnBps) external;
    function setBuybackBudget(uint256 budget) external;
    function setTWAPDeviationThreshold(uint256 threshold) external;
    function setApplyHalvingToMint(bool apply) external;
    function emergencyWithdraw(address token, address to, uint256 amount) external;
    function emergencyWithdrawMultiple(
        address[] calldata tokens,
        address to,
        uint256[] calldata amounts
    ) external;

    // ============ Events ============
    event BlacklistUpdated(address indexed account, bool status);
    event AirdropExecuted(address[] recipients, uint256 amount, uint256 totalAmount);
    event TWAPPriceUpdated(uint256 price);
    event TokenBurned(address indexed burner, uint256 amount);
    event GovernanceUpdated(address indexed governanceContract);
    event StakingUpdated(address indexed stakingContract);
    event LiquidityGuardUpdated(address indexed liquidityGuard);
    event BuybackExecuted(uint256 amount, uint256 tokensReceived, uint256 price);
    event LiquidityInjected(uint256 amount, uint256 tokensUsed);
    event HalvingTriggered(uint256 epochNumber, uint256 timestamp);
    event CrossChainSyncSuccessful(uint256 epoch);
    event HalvingSyncFailed();
    event CrossChainHandlerUpdated(address indexed crossChainHandler);
    event CrossChainMessageSent(uint16 indexed destChainId, bytes32 indexed payloadHash, uint256 nonce);
    event CrossChainStateUpdated(uint16 indexed srcChainId, ICrossChainHandler.CrossChainState state);
    event AntiBotUpdated(address indexed newAntiBot);
    event TransactionThrottled(address indexed user, uint256 cooldownEnds);
    event ChainSupportUpdated(uint16 indexed chainId, bool supported);
    event EmissionRateUpdated(uint256 newRate);

    // ============ Errors ============
    error NotAuthorized();
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
    error TransactionThrottled();
}