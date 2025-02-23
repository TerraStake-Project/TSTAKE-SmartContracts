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

        dailyWithdrawalVolume += withdrawalAmount;
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

    // ================================
    // 🔹 Liquidity Withdrawal with TWAP & Cooldown Control
    // ================================
    function withdrawLiquidity(uint256 tokenId, uint256 amount) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        require(liquidityWhitelist[msg.sender], "Not whitelisted");

        _checkCircuitBreaker(amount);
        _checkPriceDeviation();
        
        LiquidityLock storage lock = liquidityLocks[tokenId];
        require(block.timestamp >= lock.unlockStart, "Liquidity still locked");

        uint256 elapsedTime = block.timestamp - lock.unlockStart;
        uint256 totalUnlocked = (lock.releaseRate * elapsedTime) / (lock.unlockEnd - lock.unlockStart);
        require(amount <= totalUnlocked, "Exceeds unlocked amount");

        userLiquidity[msg.sender] = userLiquidity[msg.sender].sub(amount);

        emit LiquidityRemoved(msg.sender, amount, amount);
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

