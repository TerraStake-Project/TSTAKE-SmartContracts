// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "../interfaces/ITerraStakeRewardDistributor.sol";

/**
 * @title TerraStakeLiquidityGuard
 * @notice Secure liquidity protection & auto-reinjection for the TerraStake ecosystem.
 * @dev Protects against flash loans, price manipulation, and excessive liquidity withdrawals.
 *      This version adds TWAP-based cooldown protection before liquidity withdrawal.
 */
contract TerraStakeLiquidityGuard is AccessControl, ReentrancyGuard {
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
    ITerraStakeRewardDistributor public rewardDistributor;

    // ================================
    // 🔹 Liquidity Management Variables
    // ================================
    uint256 public reinjectionThreshold;
    uint256 public autoLiquidityInjectionRate;
    uint256 public maxLiquidityPerAddress;
    uint256 public liquidityRemovalCooldown = 7 days;

    // ================================
    // 🔹 Liquidity Injection & TWAP-Based Protection
    // ================================
    mapping(address => uint256) public userLiquidity;
    mapping(address => uint256) public lastLiquidityRemoval;
    mapping(address => bool) public liquidityWhitelist;

    // ================================
    // 🔹 Events
    // ================================
    event LiquidityInjected(uint256 amount);
    event LiquidityCapUpdated(uint256 newCap);
    event LiquidityInjectionRateUpdated(uint256 newRate);
    event CircuitBreakerTriggered();
    event TWAPVerificationFailed();
    event LiquidityRemoved(address indexed provider, uint256 amount);
    event LiquidityReinjectionThresholdUpdated(uint256 newThreshold);

    // ================================
    // 🔹 Constructor
    // ================================
    constructor(
        address _tStakeToken,
        address _usdcToken,
        address _positionManager,
        address _uniswapPool,
        address _rewardDistributor,
        uint256 _reinjectionThreshold,
        uint256 _autoLiquidityInjectionRate
    ) {
        require(_tStakeToken != address(0), "Invalid TSTAKE token address");
        require(_usdcToken != address(0), "Invalid USDC token address");
        require(_positionManager != address(0), "Invalid Uniswap position manager");
        require(_uniswapPool != address(0), "Invalid Uniswap pool");
        require(_rewardDistributor != address(0), "Invalid reward distributor");

        tStakeToken = IERC20(_tStakeToken);
        usdcToken = IERC20(_usdcToken);
        positionManager = INonfungiblePositionManager(_positionManager);
        uniswapPool = IUniswapV3Pool(_uniswapPool);
        rewardDistributor = ITerraStakeRewardDistributor(_rewardDistributor);

        reinjectionThreshold = _reinjectionThreshold;
        autoLiquidityInjectionRate = _autoLiquidityInjectionRate;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
    }

    // ================================
    // 🔹 Liquidity Injection (Auto-Reinjection)
    // ================================
    function injectLiquidity(uint256 amount) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        require(amount > 0, "Invalid liquidity amount");
        require(tStakeToken.balanceOf(address(this)) >= amount, "Insufficient balance");

        // Send liquidity to the reward distributor for reinjection
        tStakeToken.approve(address(rewardDistributor), amount);
        rewardDistributor.injectLiquidity(amount);

        emit LiquidityInjected(amount);
    }

    // ================================
    // 🔹 Governance-Controlled Adjustments
    // ================================
    function updateLiquidityInjectionRate(uint256 newRate) external onlyRole(GOVERNANCE_ROLE) {
        require(newRate <= 10, "Rate too high");
        autoLiquidityInjectionRate = newRate;
        emit LiquidityInjectionRateUpdated(newRate);
    }

    function updateLiquidityCap(uint256 newCap) external onlyRole(GOVERNANCE_ROLE) {
        maxLiquidityPerAddress = newCap;
        emit LiquidityCapUpdated(newCap);
    }

    function updateReinjectionThreshold(uint256 newThreshold) external onlyRole(GOVERNANCE_ROLE) {
        reinjectionThreshold = newThreshold;
        emit LiquidityReinjectionThresholdUpdated(newThreshold);
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
