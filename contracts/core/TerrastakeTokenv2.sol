// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

// Uniswap V4 imports
import "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import "@uniswap/v4-core/contracts/types/PoolKey.sol";
import "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import "@uniswap/v4-core/contracts/types/Currency.sol";
import "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import "@uniswap/v4-core/contracts/libraries/FullMath.sol";

/**
 * @title TerraStakeToken
 * @notice Advanced ERC20 token with Uniswap V4 integration, cross-chain sync, AI-driven economics,
 * comprehensive security controls, and modular design for scalability.
 */
contract TerraStakeToken is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    ERC20BurnableUpgradeable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using Math for uint256;
    using PoolId for PoolKey;

    // ============ Constants ============
    uint256 public constant MAX_SUPPLY = 3_000_000_000 * 10**18;
    uint32 public constant MIN_TWAP_PERIOD = 5 minutes;
    uint256 public constant BUYBACK_TAX_BASIS_POINTS = 100; // 1%
    uint256 public constant MAX_TAX_BASIS_POINTS = 500; // 5%
    uint256 public constant BURN_RATE_BASIS_POINTS = 10; // 0.1%
    uint256 public constant HALVING_RATE = 65; // 65% of previous emission (35% reduction)
    uint256 public constant TWAP_UPDATE_COOLDOWN = 30 minutes;
    uint256 public constant EMERGENCY_COOLDOWN = 24 hours;

    // ============ Structs ============
    struct BuybackStats {
        uint256 totalTokensBought;
        uint256 totalUSDCSpent;
        uint256 lastBuybackTime;
        uint256 buybackCount;
    }

    struct TWAPObservation {
        uint32 blockTimestamp;
        uint160 sqrtPriceX96;
        uint128 liquidity;
    }

    struct PoolPosition {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 tokenId;
        bool isActive;
    }

    struct NeuralWeights {
        uint256 timestamp;
        uint256 buyWeight;
        uint256 sellWeight;
        uint256 holdWeight;
        uint256 confidenceScore;
        string modelVersion;
    }

    // ============ State Variables ============
    // Uniswap V4 Integration
    IPoolManager public poolManager;
    PoolKey public poolKey;
    bytes32 public poolId;
    bool public poolInitialized;
    mapping(uint256 => PoolPosition) public positions;
    uint256 public positionCounter;
    mapping(bytes32 => TWAPObservation[]) public twapObservations;
    uint32 public twapObservationWindow;

// Token Metrics and Economics
uint256 public lastTWAPPrice;
uint256 public lastTWAPUpdate;
uint256 public maxGasPrice;
uint256 public buybackBudget;
uint256 public totalTaxCollected;
BuybackStats public buybackStatistics;
uint256 public currentHalvingEpoch;
uint256 public lastHalvingTime;
bool public applyHalvingToMint;
uint256 public emissionRate;
uint256 public buybackTaxBasisPoints;
uint256 public burnRateBasisPoints;
uint256 public sellTax;
mapping(address => bool) public isExemptFromTax;

// Taxation and Allocation
struct TaxInfo {
    uint256 total;
    uint256 liquidity;
    uint256 treasury;
    uint256 staking;
    uint256 buyback;
}

struct TaxAllocation {
    uint256 liquidity;
    uint256 treasury;
    uint256 staking;
    uint256 buyback;
}

uint256 public buyTax;
uint256 public transferTax;

TaxAllocation public buyTaxAllocation;
TaxAllocation public sellTaxAllocation;
TaxAllocation public transferTaxAllocation;

uint256 public maxSellTax;


    // Security and Controls
    mapping(address => bool) public isBlacklisted;
    uint256 public twapDeviationThreshold;
    bool public emergencyMode;
    uint256 public lastEmergencyActionTime;
    NeuralWeights public currentNeuralWeights;
    bool public neuralRecommendationsEnabled;
    uint256 public neuralConfidenceThreshold;

    // ============ Roles ============
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant LIQUIDITY_MANAGER_ROLE = keccak256("LIQUIDITY_MANAGER_ROLE");
    bytes32 public constant NEURAL_INDEXER_ROLE = keccak256("NEURAL_INDEXER_ROLE");
    bytes32 public constant AI_MANAGER_ROLE = keccak256("AI_MANAGER_ROLE");
    bytes32 public constant PRICE_ORACLE_ROLE = keccak256("PRICE_ORACLE_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // ============ Events ============
    event PoolInitialized(bytes32 indexed poolId, PoolKey poolKey, uint160 sqrtPriceX96);
    event PositionCreated(uint256 positionId, int24 tickLower, int24 tickUpper, uint128 liquidity);
    event PositionModified(uint256 positionId, int128 liquidityDelta);
    event PositionBurned(uint256 positionId);
    event TWAPPriceUpdated(uint256 price);
    event SwapExecuted(bytes32 indexed poolId, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);
    event BuybackExecuted(uint256 amount, uint256 tokensReceived);
    event TaxUpdated(string taxType, uint256 newRate);
    event BlacklistUpdated(address indexed account, bool status);
    event NeuralWeightsUpdated(uint256 buyWeight, uint256 sellWeight, uint256 holdWeight, uint256 confidenceScore);
    event EmergencyModeChanged(bool enabled);

    // ============ Errors ============
    error InvalidPoolManager();
    error InvalidAdmin();
    error PoolNotInitialized();
    error InvalidTickRange();
    error SwapSlippageExceeded();
    error PositionNotFound();
    error SenderIsBot();
    error PoolAlreadyInitialized();
    error EmergencyCooldownActive();

    // ============ Modifiers ============
    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "Not pool manager");
        _;
    }

    // ============ Initialization ============
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _poolManager,
        address admin
    ) public initializer {
        if (_poolManager == address(0)) revert InvalidPoolManager();
        if (admin == address(0)) revert InvalidAdmin();

        __ERC20_init("TerraStakeToken", "TSTAKE");
        __ERC20Permit_init("TerraStakeToken");
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _setupRoles(admin);
        _initializeState(_poolManager);
    }

    function _setupRoles(address admin) private {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(BURNER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(LIQUIDITY_MANAGER_ROLE, admin);
        _grantRole(NEURAL_INDEXER_ROLE, admin);
        _grantRole(AI_MANAGER_ROLE, admin);
        _grantRole(PRICE_ORACLE_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, admin);
    }

    function _initializeState(address _poolManager) private {
        poolManager = IPoolManager(_poolManager);
        currentHalvingEpoch = 0;
        lastHalvingTime = block.timestamp;
        maxGasPrice = 100 * 10**9;
        buybackTaxBasisPoints = BUYBACK_TAX_BASIS_POINTS;
        burnRateBasisPoints = BURN_RATE_BASIS_POINTS;
        twapDeviationThreshold = 500;
        applyHalvingToMint = true;
        emissionRate = 1_000_000 * 10**18;
        twapObservationWindow = 1 days;
        poolInitialized = false;
        neuralConfidenceThreshold = 70;
        emergencyMode = false;
        buybackBudget = 0;
    }

    // ============ Uniswap V4 Functions ============
    function initializePool(
        Currency _currency0,
        Currency _currency1,
        uint24 _fee,
        uint160 _sqrtPriceX96
    ) external onlyRole(LIQUIDITY_MANAGER_ROLE) nonReentrant {
        if (poolInitialized) revert PoolAlreadyInitialized();

        PoolKey memory key = PoolKey({
            currency0: _currency0,
            currency1: _currency1,
            fee: _fee,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        poolId = key.toId();
        poolManager.initialize(key, _sqrtPriceX96, "");

        poolKey = key;
        poolInitialized = true;

        twapObservations[poolId].push(TWAPObservation({
            blockTimestamp: uint32(block.timestamp),
            sqrtPriceX96: _sqrtPriceX96,
            liquidity: 0
        }));

        emit PoolInitialized(poolId, key, _sqrtPriceX96);
    }

    function addLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityDesired,
        address recipient,
        uint256 amount0Max,
        uint256 amount1Max
    ) external onlyRole(LIQUIDITY_MANAGER_ROLE) nonReentrant returns (uint256 positionId, uint128 liquidityActual) {
        if (!poolInitialized) revert PoolNotInitialized();
        if (tickLower >= tickUpper) revert InvalidTickRange();
        require(tickLower % poolKey.tickSpacing == 0, "Invalid lower tick");
        require(tickUpper % poolKey.tickSpacing == 0, "Invalid upper tick");

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidityDesired)),
            salt: keccak256(abi.encode(block.timestamp, tickLower, tickUpper, liquidityDesired))
        });

        (BalanceDelta delta0, BalanceDelta delta1) = poolManager.modifyLiquidity(
            poolKey,
            params,
            abi.encode(this, recipient)
        );

        int128 amount0 = delta0.amount0();
        int128 amount1 = delta1.amount1();
        uint256 amount0Uint = amount0 >= 0 ? uint256(int256(amount0)) : 0;
        uint256 amount1Uint = amount1 >= 0 ? uint256(int256(amount1)) : 0;

        require(amount0Uint <= amount0Max, "Excessive amount0");
        require(amount1Uint <= amount1Max, "Excessive amount1");

        if (amount0Uint > 0) {
            IERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(msg.sender, address(this), amount0Uint);
            IERC20(Currency.unwrap(poolKey.currency0)).approve(address(poolManager), amount0Uint);
        }
        if (amount1Uint > 0) {
            IERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(msg.sender, address(this), amount1Uint);
            IERC20(Currency.unwrap(poolKey.currency1)).approve(address(poolManager), amount1Uint);
        }

        positionId = ++positionCounter;
        positions[positionId] = PoolPosition({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidityDesired,
            tokenId: positionId,
            isActive: true
        });

        emit PositionCreated(positionId, tickLower, tickUpper, liquidityDesired);
        recordTWAPObservation();

        return (positionId, liquidityDesired);
    }

    function removeLiquidity(
        uint256 positionId,
        uint128 liquidityToRemove,
        address recipient
    ) external onlyRole(LIQUIDITY_MANAGER_ROLE) nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (!poolInitialized) revert PoolNotInitialized();

        PoolPosition storage position = positions[positionId];
        if (!position.isActive) revert PositionNotFound();

        if (liquidityToRemove == 0 || liquidityToRemove > position.liquidity) {
            liquidityToRemove = position.liquidity;
        }

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: position.tickLower,
            tickUpper: position.tickUpper,
            liquidityDelta: -int256(uint256(liquidityToRemove)),
            salt: keccak256(abi.encode(block.timestamp, position.tickLower, position.tickUpper, liquidityToRemove))
        });

        (BalanceDelta delta0, BalanceDelta delta1) = poolManager.modifyLiquidity(
            poolKey,
            params,
            abi.encode(this, recipient)
        );

        position.liquidity -= liquidityToRemove;
        if (position.liquidity == 0) {
            position.isActive = false;
            emit PositionBurned(positionId);
        } else {
            emit PositionModified(positionId, -int128(liquidityToRemove));
        }

        amount0 = delta0.amount0() > 0 ? uint256(int256(delta0.amount0())) : 0;
        amount1 = delta1.amount1() > 0 ? uint256(int256(delta1.amount1())) : 0;

        recordTWAPObservation();
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint160 sqrtPriceLimitX96,
        address recipient
    ) external nonReentrant returns (uint256 amountOut) {
        if (!poolInitialized) revert PoolNotInitialized();
        if (isBlacklisted[msg.sender] || isBlacklisted[recipient]) revert SenderIsBot();

        bool zeroForOne = tokenIn == Currency.unwrap(poolKey.currency0);
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).approve(address(poolManager), amountIn);

        uint256 taxAmount = isExemptFromTax[msg.sender] ? 0 : (amountIn * buybackTaxBasisPoints) / 10000;
        uint256 amountInAfterTax = amountIn - taxAmount;
        if (taxAmount > 0) {
            buybackBudget += taxAmount;
            totalTaxCollected += taxAmount;
        }

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(amountInAfterTax),
            sqrtPriceLimitX96: sqrtPriceLimitX96 == 0
                ? (zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1)
                : sqrtPriceLimitX96
        });

        BalanceDelta swapDelta = poolManager.swap(poolKey, params, abi.encode(this, recipient));
        amountOut = zeroForOne ? uint256(-swapDelta.amount0()) : uint256(-swapDelta.amount1());

        if (amountOut < amountOutMinimum) revert SwapSlippageExceeded();

        buybackStatistics.totalTokensBought += amountOut;
        buybackStatistics.lastBuybackTime = block.timestamp;
        buybackStatistics.buybackCount++;

        emit SwapExecuted(poolId, tokenIn, tokenOut, amountIn, amountOut);
        recordTWAPObservation();

        return amountOut;
    }

    function uniswapV4LockAcquired(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (address caller, address recipient, BalanceDelta delta) = 
            abi.decode(data, (address, address, BalanceDelta));

        int128 amount0Delta = delta.amount0();
        int128 amount1Delta = delta.amount1();

        if (amount0Delta > 0) {
            IERC20(Currency.unwrap(poolKey.currency0)).safeTransfer(address(poolManager), uint128(amount0Delta));
        } else if (amount0Delta < 0) {
            IERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(
                address(poolManager),
                recipient,
                uint128(-amount0Delta)
            );
        }

        if (amount1Delta > 0) {
            IERC20(Currency.unwrap(poolKey.currency1)).safeTransfer(address(poolManager), uint128(amount1Delta));
        } else if (amount1Delta < 0) {
            IERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(
                address(poolManager),
                recipient,
                uint128(-amount1Delta)
            );
        }

        return abi.encode(true);
    }

    // ============ TWAP Functions ============
    function recordTWAPObservation() public {
        if (!poolInitialized) return;

        (uint160 sqrtPriceX96, int24 tick, , ) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);

        twapObservations[poolId].push(TWAPObservation({
            blockTimestamp: uint32(block.timestamp),
            sqrtPriceX96: sqrtPriceX96,
            liquidity: liquidity
        }));

        uint256 price = calculatePriceFromSqrtPriceX96(sqrtPriceX96);
        if (lastTWAPPrice == 0 || 
            block.timestamp > lastTWAPUpdate + TWAP_UPDATE_COOLDOWN ||
            isValidPriceChange(lastTWAPPrice, price)) {
            lastTWAPPrice = price;
            lastTWAPUpdate = block.timestamp;
            emit TWAPPriceUpdated(price);
        }
    }

    function calculatePriceFromSqrtPriceX96(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        return FullMath.mulDiv(priceX192, 1e18, 1 << 192); // Adjust for 18 decimals
    }

    function isValidPriceChange(uint256 oldPrice, uint256 newPrice) internal view returns (bool) {
        if (oldPrice == 0) return true;

        uint256 percentChange = oldPrice > newPrice
            ? ((oldPrice - newPrice) * 10000) / oldPrice
            : ((newPrice - oldPrice) * 10000) / oldPrice;

        return percentChange <= twapDeviationThreshold;
    }

    function getTWAPPrice(uint32 period) public view returns (uint256) {
        if (!poolInitialized || twapObservations[poolId].length < 2) return lastTWAPPrice;

        uint32 targetTime = uint32(block.timestamp) - (period < MIN_TWAP_PERIOD ? MIN_TWAP_PERIOD : period);
        TWAPObservation[] storage observations = twapObservations[poolId];

        uint256 beforeIndex = 0;
        uint256 afterIndex = observations.length - 1;

        for (uint256 i = 0; i < observations.length; i++) {
            if (observations[i].blockTimestamp <= targetTime) {
                beforeIndex = i;
            } else {
                afterIndex = i;
                break;
            }
        }

        TWAPObservation memory beforeObs = observations[beforeIndex];
        TWAPObservation memory afterObs = observations[afterIndex];

        if (beforeObs.blockTimestamp == afterObs.blockTimestamp) {
            return calculatePriceFromSqrtPriceX96(afterObs.sqrtPriceX96);
        }

        uint32 timeDelta = afterObs.blockTimestamp - beforeObs.blockTimestamp;
        uint32 timeWeight = targetTime - beforeObs.blockTimestamp;

        uint160 weightedSqrtPriceX96;
        if (timeWeight == 0) {
            weightedSqrtPriceX96 = beforeObs.sqrtPriceX96;
        } else if (timeWeight >= timeDelta) {
            weightedSqrtPriceX96 = afterObs.sqrtPriceX96;
        } else {
            uint256 afterWeight = (uint256(timeWeight) * 1e18) / timeDelta;
            uint256 beforeWeight = 1e18 - afterWeight;
            weightedSqrtPriceX96 = uint160(
                (uint256(beforeObs.sqrtPriceX96) * beforeWeight + uint256(afterObs.sqrtPriceX96) * afterWeight) / 1e18
            );
        }

        return calculatePriceFromSqrtPriceX96(weightedSqrtPriceX96);
    }

    // ============ Token Economics ============
    function adjustSellTax(uint256 sellWeight) external {
        require(msg.sender == address(poolManager), "Only pool manager");
        sellTax = sellTax + (sellWeight * 10) > MAX_TAX_BASIS_POINTS ? MAX_TAX_BASIS_POINTS : sellTax + (sellWeight * 10);
        emit TaxUpdated("sell", sellTax);
    }

    function executeBuyback(uint256 amount) external onlyRole(GOVERNANCE_ROLE) {
        require(amount <= buybackBudget, "Insufficient budget");
        // Simplified buyback logic; in practice, this would interact with the pool
        uint256 tokensReceived = amount; // Placeholder: actual swap logic needed
        buybackBudget -= amount;
        buybackStatistics.totalTokensBought += tokensReceived;
        buybackStatistics.lastBuybackTime = block.timestamp;
        buybackStatistics.buybackCount++;
        emit BuybackExecuted(amount, tokensReceived);
    }

    // ============ Security and Governance ============
    function updateBlacklistStatus(address account, bool status) external onlyRole(ADMIN_ROLE) {
        isBlacklisted[account] = status;
        emit BlacklistUpdated(account, status);
    }

    function setEmergencyMode(bool enabled) external onlyRole(EMERGENCY_ROLE) {
        if (enabled && block.timestamp < lastEmergencyActionTime + EMERGENCY_COOLDOWN) {
            revert EmergencyCooldownActive();
        }
        emergencyMode = enabled;
        lastEmergencyActionTime = enabled ? block.timestamp : lastEmergencyActionTime;
        emit EmergencyModeChanged(enabled);
    }

    // ============ Neural Network Functions ============
    function updateNeuralWeights(
        uint256 buyWeight,
        uint256 sellWeight,
        uint256 holdWeight,
        uint256 confidenceScore,
        string calldata modelVersion
    ) external onlyRole(NEURAL_INDEXER_ROLE) {
        require(buyWeight + sellWeight + holdWeight == 100, "Weights must sum to 100");
        require(confidenceScore <= 100, "Confidence score must be <= 100");

        currentNeuralWeights = NeuralWeights({
            timestamp: block.timestamp,
            buyWeight: buyWeight,
            sellWeight: sellWeight,
            holdWeight: holdWeight,
            confidenceScore: confidenceScore,
            modelVersion: modelVersion
        });

        emit NeuralWeightsUpdated(buyWeight, sellWeight, holdWeight, confidenceScore);
    }

    function toggleNeuralRecommendations(bool enabled) external onlyRole(AI_MANAGER_ROLE) {
        neuralRecommendationsEnabled = enabled;
    }

    // ============ Upgradeability ============
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        require(newImplementation != address(0), "Invalid implementation");
    }

    // ============ Getters ============
    function getNeuralWeights() external view returns (
        uint256 buyWeight,
        uint256 sellWeight,
        uint256 holdWeight,
        uint256 confidenceScore,
        string memory modelVersion
    ) {
        NeuralWeights memory weights = currentNeuralWeights;
        return (weights.buyWeight, weights.sellWeight, weights.holdWeight, weights.confidenceScore, weights.modelVersion);
    }

    function getBuybackStats() external view returns (BuybackStats memory) {
        return buybackStatistics;
    }

    function getCurrentHalvingEpoch() external view returns (uint256) {
        return currentHalvingEpoch;
    }

    function getLastHalvingTime() external view returns (uint256) {
        return lastHalvingTime;
    }
}

// ============ Tax & Tokenomics ============

/**
 * @notice Get detailed tax information
 * @return buyTaxInfo Buy tax breakdown
 * @return sellTaxInfo Sell tax breakdown
 * @return transferTaxInfo Transfer tax breakdown
 */
function getTaxInfo() external view returns (
    TaxInfo memory buyTaxInfo,
    TaxInfo memory sellTaxInfo,
    TaxInfo memory transferTaxInfo
) {
    buyTaxInfo = TaxInfo({
        total: buyTax,
        liquidity: buyTaxAllocation.liquidity,
        treasury: buyTaxAllocation.treasury,
        staking: buyTaxAllocation.staking,
        buyback: buyTaxAllocation.buyback
    });
    
    sellTaxInfo = TaxInfo({
        total: sellTax,
        liquidity: sellTaxAllocation.liquidity,
        treasury: sellTaxAllocation.treasury,
        staking: sellTaxAllocation.staking,
        buyback: sellTaxAllocation.buyback
    });
    
    transferTaxInfo = TaxInfo({
        total: transferTax,
        liquidity: transferTaxAllocation.liquidity,
        treasury: transferTaxAllocation.treasury,
        staking: transferTaxAllocation.staking,
        buyback: transferTaxAllocation.buyback
    });
    
    return (buyTaxInfo, sellTaxInfo, transferTaxInfo);
}

/**
 * @notice Set tax exemption for multiple addresses in a batch
 * @param accounts Array of addresses
 * @param exempt Whether the addresses are exempt
 */
function setTaxExemptBatch(address[] calldata accounts, bool exempt) external onlyRole(ADMIN_ROLE) {
    for (uint256 i = 0; i < accounts.length; i++) {
        require(accounts[i] != address(0), "Invalid address");
        isExemptFromTax[accounts[i]] = exempt;
    }
}

/**
 * @notice Adjust tax based on market conditions
 * @param marketVolatility Volatility metric (0-100)
 * @param marketVolume Volume metric (in token units)
 */
function adjustTaxBasedOnMarket(uint256 marketVolatility, uint256 marketVolume) external onlyRole(PRICE_ORACLE_ROLE) {
    require(marketVolatility <= 100, "Invalid volatility value");
    
    // Dynamic tax adjustment based on market conditions
    if (marketVolatility > 80) {
        // High volatility - increase sell tax to discourage panic selling
        sellTax = Math.min(sellTax + 1, maxSellTax);
    } else if (marketVolatility < 20 && marketVolume > 1000000 * 10**decimals()) {
        // Low volatility, high volume - decrease taxes to encourage activity
        if (sellTax > 2) {
            sellTax -= 1;
        }
        if (buyTax > 1) {
            buyTax -= 1;
        }
    } else if (marketVolatility < 50 && marketVolume < 100000 * 10**decimals()) {
        // Low volatility, low volume - adjust to stimulate trading
        if (buyTax > 1) {
            buyTax -= 1;
        }
    }
    
    // Emit events for the tax changes
    emit TaxUpdated("buy", buyTax);
    emit TaxUpdated("sell", sellTax);
}

/**
 * @notice Calculate tax amount for a transaction
 * @param sender Sender address
 * @param recipient Recipient address
 * @param amount Transaction amount
 * @param taxType Type of tax (buy, sell, transfer)
 * @return taxAmount The calculated tax amount
 */
function _calculateTax(
    address sender,
    address recipient,
    uint256 amount,
    string memory taxType
) internal view returns (uint256 taxAmount) {
    if (isExemptFromTax[sender] || isExemptFromTax[recipient]) {
        return 0;
    }
    
    uint256 taxRate;
    if (keccak256(abi.encodePacked(taxType)) == keccak256(abi.encodePacked("buy"))) {
        taxRate = buyTax;
    } else if (keccak256(abi.encodePacked(taxType)) == keccak256(abi.encodePacked("sell"))) {
        taxRate = sellTax;
    } else {
        taxRate = transferTax;
    }
    
    return amount * taxRate / 100;
}
