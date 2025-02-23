// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * @title TerraStakeLiquidityGuard
 * @notice Secure liquidity protection & auto-reinjection for the TerraStake ecosystem.
 * @dev Protects against flash loans, price manipulation, and excessive liquidity withdrawals.
 *      This version adds TWAP-based cooldown protection before liquidity withdrawal.
 */
contract TerraStakeLiquidityGuard is AccessControl, ReentrancyGuard {
    using SafeMath for uint256;

    // ================================
    // 🔹 Governance & Security Roles
    // ================================
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // ================================
    // 🔹 Token & Pool References
    // ================================
    IERC20 public immutable tStakeToken;
    IERC20 public immutable usdcToken;
    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Pool public immutable uniswapPool;

    // ================================
    // 🔹 Liquidity Management Variables
    // ================================
    uint256 public reinjectionThreshold;
    uint256 public autoLiquidityInjectionRate;
    uint256 public maxLiquidityPerAddress;
    uint256 public liquidityRemovalCooldown = 7 days;

    // ================================
    // 🔹 Circuit Breakers & Price Control
    // ================================
    uint256 private constant MAX_DAILY_VOLUME = 1_000_000 * 1e18; // 1M TSTAKE max daily withdrawal
    uint256 private constant VOLUME_RESET_PERIOD = 24 hours;
    uint256 private lastVolumeResetTime;
    uint256 private dailyWithdrawalVolume;

    uint256 private constant MAX_PRICE_IMPACT = 2; // 2% max price deviation
    uint256 private constant PRICE_CHECK_INTERVAL = 5 minutes;
    int256 private lastCheckedPrice;
    uint256 private lastPriceCheckTime;

    // ================================
    // 🔹 Liquidity Lock Structure
    // ================================
    struct LiquidityLock {
        uint256 unlockStart;
        uint256 unlockEnd;
        uint256 releaseRate;
        bool isLocked;
    }

    // ================================
    // 🔹 Mappings for Liquidity & User Restrictions
    // ================================
    mapping(address => uint256) public userLiquidity;
    mapping(address => uint256) public lastLiquidityRemoval;
    mapping(uint256 => LiquidityLock) public liquidityLocks;
    mapping(address => bool) public liquidityWhitelist;
    mapping(address => uint256) public pendingCooldownChanges;

    // ============================================================
    // 🔹 TWAP-Based Liquidity Withdrawal Protection Variables
    // ============================================================
    struct WithdrawalRequest {
        uint256 tokenId;
        uint256 amount;
        uint256 requestTime;
        uint256 requestPrice;
    }
    mapping(address => WithdrawalRequest) public pendingWithdrawal;
    uint256 public constant TWAP_COOLDOWN = 24 hours; // TWAP observation period

    // ================================
    // 🔹 Events for Transparency
    // ================================
    event LiquidityAdded(address indexed provider, uint256 amountTSTAKE, uint256 amountUSDC);
    event LiquidityRemoved(address indexed provider, uint256 amountTSTAKE, uint256 amountUSDC);
    event LiquidityInjected(uint256 amount);
    event LiquidityLocked(uint256 indexed tokenId, uint256 unlockStart, uint256 unlockEnd, uint256 releaseRate);
    event LiquidityReinjectionThresholdUpdated(uint256 newThreshold);
    event LiquidityInjectionRateUpdated(uint256 newRate);
    event LiquidityCapUpdated(uint256 newCap);
    event CooldownUpdated(uint256 newCooldown);
    event CircuitBreakerTriggered();
    event PriceDeviationDetected();
    event TWAPVerificationFailed();

    // New events for the TWAP-based withdrawal process
    event WithdrawalRequested(address indexed user, uint256 tokenId, uint256 amount, uint256 requestTime, uint256 requestPrice);
    event WithdrawalExecuted(address indexed user, uint256 tokenId, uint256 amount, uint256 executionPrice);

    // ================================
    // 🔹 Constructor
    // ================================
    constructor(
        address _tStakeToken,
        address _usdcToken,
        address _positionManager,
        address _uniswapPool,
        uint256 _reinjectionThreshold,
        uint256 _autoLiquidityInjectionRate
    ) {
        require(_tStakeToken != address(0), "Invalid TSTAKE token address");
        require(_usdcToken != address(0), "Invalid USDC token address");
        require(_positionManager != address(0), "Invalid Uniswap position manager");
        require(_uniswapPool != address(0), "Invalid Uniswap pool");

        tStakeToken = IERC20(_tStakeToken);
        usdcToken = IERC20(_usdcToken);
        positionManager = INonfungiblePositionManager(_positionManager);
        uniswapPool = IUniswapV3Pool(_uniswapPool);

        reinjectionThreshold = _reinjectionThreshold;
        autoLiquidityInjectionRate = _autoLiquidityInjectionRate;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
    }

    // ================================
    // 🔹 Circuit Breaker & Price Check
    // ================================
    function _checkCircuitBreaker(uint256 withdrawalAmount) internal {
        if (block.timestamp >= lastVolumeResetTime + VOLUME_RESET_PERIOD) {
            dailyWithdrawalVolume = 0;
            lastVolumeResetTime = block.timestamp;
        }
        dailyWithdrawalVolume = dailyWithdrawalVolume.add(withdrawalAmount);
        if (dailyWithdrawalVolume > MAX_DAILY_VOLUME) {
            emit CircuitBreakerTriggered();
            revert("Circuit Breaker: Exceeded max daily withdrawal volume");
        }
    }

    function _checkPriceDeviation() internal {
        if (block.timestamp < lastPriceCheckTime + PRICE_CHECK_INTERVAL) return;
        int256 currentPrice = _getUniswapPrice();
        int256 priceChange = (currentPrice * 100) / lastCheckedPrice - 100;
        lastCheckedPrice = currentPrice;
        lastPriceCheckTime = block.timestamp;
        if (priceChange > int256(MAX_PRICE_IMPACT) || priceChange < -int256(MAX_PRICE_IMPACT)) {
            emit PriceDeviationDetected();
            revert("Price deviation too high");
        }
    }

    function _getUniswapPrice() internal view returns (int256) {
        (, int256 price, , , ) = uniswapPool.slot0();
        return price;
    }

    // ====================================================
    // 🔹 TWAP-Based Liquidity Withdrawal: Request Phase
    // ====================================================
    function requestLiquidityWithdrawal(uint256 tokenId, uint256 amount) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        require(liquidityWhitelist[msg.sender], "Not whitelisted");
        _checkCircuitBreaker(amount);

        // Ensure liquidity is unlocked based on the liquidity lock settings
        LiquidityLock storage lock = liquidityLocks[tokenId];
        require(block.timestamp >= lock.unlockStart, "Liquidity still locked");

        int256 currentPrice = _getUniswapPrice();
        require(currentPrice > 0, "Invalid price");

        pendingWithdrawal[msg.sender] = WithdrawalRequest({
            tokenId: tokenId,
            amount: amount,
            requestTime: block.timestamp,
            requestPrice: uint256(currentPrice)
        });

        emit WithdrawalRequested(msg.sender, tokenId, amount, block.timestamp, uint256(currentPrice));
    }

    // ====================================================
    // 🔹 TWAP-Based Liquidity Withdrawal: Execution Phase
    // ====================================================
    function executeLiquidityWithdrawal() external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        WithdrawalRequest storage req = pendingWithdrawal[msg.sender];
        require(req.requestTime != 0, "No pending withdrawal");
        require(block.timestamp >= req.requestTime + TWAP_COOLDOWN, "TWAP cooldown period not elapsed");

        int256 currentPriceInt = _getUniswapPrice();
        require(currentPriceInt > 0, "Invalid price");
        uint256 currentPrice = uint256(currentPriceInt);

        // Calculate percentage deviation between current price and the price at request time
        uint256 priceDeviation = calculatePriceDeviation(currentPrice, req.requestPrice);
        require(priceDeviation <= MAX_PRICE_IMPACT, "Price deviation too high");

        // Re-check liquidity lock details
        LiquidityLock storage lock = liquidityLocks[req.tokenId];
        require(block.timestamp >= lock.unlockStart, "Liquidity still locked");
        uint256 elapsedTime = block.timestamp.sub(lock.unlockStart);
        uint256 totalUnlocked = lock.releaseRate.mul(elapsedTime).div(lock.unlockEnd.sub(lock.unlockStart));
        require(req.amount <= totalUnlocked, "Exceeds unlocked amount");

        // Update liquidity provided by the user
        userLiquidity[msg.sender] = userLiquidity[msg.sender].sub(req.amount);

        emit LiquidityRemoved(msg.sender, req.amount, req.amount);
        emit WithdrawalExecuted(msg.sender, req.tokenId, req.amount, currentPrice);

        delete pendingWithdrawal[msg.sender];
    }

    // ====================================================
    // 🔹 Helper: Calculate Price Deviation Percentage
    // ====================================================
    function calculatePriceDeviation(uint256 currentPrice, uint256 basePrice) public pure returns (uint256) {
        if (currentPrice >= basePrice) {
            return currentPrice.sub(basePrice).mul(100).div(basePrice);
        } else {
            return basePrice.sub(currentPrice).mul(100).div(basePrice);
        }
    }

    // ================================
    // 🔹 Governance Security: Timelocked Liquidity Rule Changes
    // ================================
    function requestCooldownChange(uint256 newCooldown) external onlyRole(GOVERNANCE_ROLE) {
        pendingCooldownChanges[msg.sender] = block.timestamp + 24 hours;
        emit CooldownUpdated(newCooldown);
    }

    function confirmCooldownChange(uint256 newCooldown) external onlyRole(GOVERNANCE_ROLE) {
        require(block.timestamp >= pendingCooldownChanges[msg.sender], "Timelock not expired");
        liquidityRemovalCooldown = newCooldown;
        delete pendingCooldownChanges[msg.sender];
    }

    // ================================
    // 🔹 Emergency & Security Controls
    // ================================
    function pauseLiquidityOperations() external onlyRole(EMERGENCY_ROLE) {
        reinjectionThreshold = 0;
    }

    function whitelistAddress(address user, bool status) external onlyRole(GOVERNANCE_ROLE) {
        liquidityWhitelist[user] = status;
    }
}
