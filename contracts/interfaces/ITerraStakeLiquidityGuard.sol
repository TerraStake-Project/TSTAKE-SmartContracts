// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import "./ITerraStakeRewardDistributor.sol";
import "./ITerraStakeTreasuryManager.sol";

/**
 * @title ITerraStakeLiquidityGuard
 * @notice Interface for the TerraStakeLiquidityGuard contract
 */
interface ITerraStakeLiquidityGuard {
    // Events
    event LiquidityInjected(uint256 tStakeAmount, uint256 usdcAmount, uint256 _tokenID, uint128 liquidity);
    event LiquidityRemoved(
        address indexed user,
        uint256 amount,
        uint256 fee,
        uint256 remainingLiquidity,
        uint256 timestamp
    );
    event LiquidityDeposited(address indexed user, uint256 amount0, uint256 amount1);
    event ParameterUpdated(string paramName, uint256 value);
    event EmergencyModeActivated(address activator);
    event EmergencyModeDeactivated(address deactivator);
    event PositionLiquidityDecreased(
        uint256 indexed _tokenID,
        uint128 liquidityReduced,
        uint256 token0Amount,
        uint256 token1Amount
    );
    event PositionClosed(uint256 indexed _tokenID);
    event PositionFeesCollected(
        uint256 indexed _tokenID,
        uint256 token0Fee,
        uint256 token1Fee
    );
    event WhitelistStatusChanged(address user, bool status);
    event TWAPVerificationFailedEvent(uint256 currentPrice, uint256 twapPrice);
    event RewardsReinvested(uint256 rewardAmount, uint256 liquidityAdded);
    event TWAPTimeframesUpdated(uint256[] newTimeframes);
    event RandomLiquidityAdjustment(uint256 tokenId, uint256 adjustment);
    event CircuitBreakerTriggered(address triggerer);
    event CircuitBreakerReset(address resetter);

    // State variables access
    function tStakeToken() external view returns (ERC20Upgradeable);
    function usdcToken() external view returns (ERC20Upgradeable);
    function positionManager() external view returns (IPositionManager);
    function uniswapPool() external view returns (IPoolManager);
    function rewardDistributor() external view returns (ITerraStakeRewardDistributor);
    function treasuryManager() external view returns (ITerraStakeTreasuryManager);
   
    function reinjectionThreshold() external view returns (uint256);
    function autoLiquidityInjectionRate() external view returns (uint256);
    function maxLiquidityPerAddress() external view returns (uint256);
    function liquidityRemovalCooldown() external view returns (uint256);
    function slippageTolerance() external view returns (uint256);
   
    function dailyWithdrawalLimit() external view returns (uint256);
    function weeklyWithdrawalLimit() external view returns (uint256);
    function vestingUnlockRate() external view returns (uint256);
    function baseFeePercentage() external view returns (uint256);
    function largeLiquidityFeeIncrease() external view returns (uint256);
   
    function userLiquidity(address user) external view returns (uint256);
    function lastLiquidityRemoval(address user) external view returns (uint256);
    function userVestingStart(address user) external view returns (uint256);
    function lastDailyWithdrawal(address user) external view returns (uint256);
    function dailyWithdrawalAmount(address user) external view returns (uint256);
    function lastWeeklyWithdrawal(address user) external view returns (uint256);
    function weeklyWithdrawalAmount(address user) external view returns (uint256);
   
    function liquidityWhitelist(address user) external view returns (bool);
    function emergencyMode() external view returns (bool);
    function activePositions(uint256 index) external view returns (uint256);
    function isPositionActive(uint256 tokenID) external view returns (bool);
    function lastLiquidityInjectionTime() external view returns (uint256);
    function totalLiquidityInjected() external view returns (uint256);
    function totalFeesCollected() external view returns (uint256);
    function totalWithdrawalCount() external view returns (uint256);
    function largeWithdrawalCount() external view returns (uint256);

    // Constants
    function GOVERNANCE_ROLE() external view returns (bytes32);
    function EMERGENCY_ROLE() external view returns (bytes32);
    function UPGRADER_ROLE() external view returns (bytes32);
    function OPERATOR_ROLE() external view returns (bytes32);
    function TREASURY_MANAGER_ROLE() external view returns (bytes32);
    function REWARD_DISTRIBUTOR_ROLE() external view returns (bytes32);
    function PERCENTAGE_DENOMINATOR() external view returns (uint256);
    function MAX_FEE_PERCENTAGE() external view returns (uint256);
    function DEFAULT_SLIPPAGE_TOLERANCE() external view returns (uint256);
    function DEFAULT_POOL_FEE() external view returns (uint24);
    function ONE_DAY() external view returns (uint256);
    function ONE_WEEK() external view returns (uint256);
    function MAX_ACTIVE_POSITIONS() external view returns (uint256);

    // Core functions
    function initialize(
        address _tStakeToken,
        address _usdcToken,
        address _positionManager,
        address _uniswapPool,
        address _rewardDistributor,
        address _treasuryManager,
        uint256 _reinjectionThreshold,
        address _admin,
        uint64 _vrfSubscriptionId,
        bytes32 _vrfKeyHash
    ) external;
   
    function addLiquidity(uint256 amount0, uint256 amount1) external;
    function removeLiquidity(uint256 amount) external;
    function injectLiquidity(uint256 amount) external;
    function collectPositionFees(uint256 tokenID) external returns (uint256 amount0, uint256 amount1);
    function decreasePositionLiquidity(
        uint256 tokenID,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min
    ) external returns (uint256 amount0, uint256 amount1);
    function closePosition(uint256 tokenID) external returns (uint256 amount0, uint256 amount1);
    function triggerCircuitBreaker() external;
    function resetCircuitBreaker() external;

    // Calculation functions
    function getWithdrawalFee(address user, uint256 amount) external view returns (uint256);
    function validateTWAPPrice() external view returns (bool);
    function verifyTWAPForWithdrawal() external view returns (bool);
    function updateTWAP() external;
    function calculateTWAP() external view returns (uint256);
    function tickToPrice(int24 tick) external pure returns (uint256);
    function sqrtPriceX96ToUint(uint160 sqrtPriceX96, uint8 decimals) external pure returns (uint256);
    function getSqrtRatioAtTick(int24 tick) external pure returns (uint160);
    function validatePriceImpact(uint256 amountIn, uint256 amountOutMin, address[] memory path) external view returns (bool);

    // Governance functions
    function setDailyWithdrawalLimit(uint256 newLimit) external;
    function setWeeklyWithdrawalLimit(uint256 newLimit) external;
    function setVestingUnlockRate(uint256 newRate) external;
    function setBaseFeePercentage(uint256 newFeePercentage) external;
    function setLargeLiquidityFeeIncrease(uint256 newFeeIncrease) external;
    function setLiquidityRemovalCooldown(uint256 newCooldown) external;
    function setMaxLiquidityPerAddress(uint256 newMax) external;
    function setReinjectionThreshold(uint256 newThreshold) external;
    function setAutoLiquidityInjectionRate(uint256 newRate) external;
    function setSlippageTolerance(uint256 newTolerance) external;
    function setTWAPObservationTimeframes(uint256[] calldata newTimeframes) external;
    function setWhitelistStatus(address user, bool status) external;

    // Emergency functions
    function activateEmergencyMode() external;
    function deactivateEmergencyMode() external;
    function emergencyWithdrawPosition(uint256 _tokenID) external;
    function emergencyTokenRecovery(address token, uint256 amount, address recipient) external;

    // View functions
    function getActivePositionsCount() external view returns (uint256);
    function getAllActivePositions() external view returns (uint256[] memory);
    function getActivePositionsPaginated(uint256 startIndex, uint256 count) external view returns (uint256[] memory);
    function getLiquidityPool() external view returns (address);
    function getLiquiditySettings() external view returns (
        uint256 _dailyWithdrawalLimit,
        uint256 _weeklyWithdrawalLimit,
        uint256 _vestingUnlockRate,
        uint256 _baseFeePercentage,
        uint256 _largeLiquidityFeeIncrease,
        uint256 _liquidityRemovalCooldown,
        uint256 _maxLiquidityPerAddress,
        uint256 _reinjectionThreshold,
        uint256 _autoLiquidityInjectionRate,
        uint256 _slippageTolerance
    );
    function isCircuitBreakerTriggered() external view returns (bool);
    function getUserData(address user) external view returns (
        uint256 liquidity,
        uint256 liquidityUSDC,
        uint256 vestingStart,
        uint256 dailyWithdrawn,
        uint256 weeklyWithdrawn,
        uint256 lastRemoval,
        bool isWhitelisted
    );
    function getUserWithdrawalFee(address user, uint256 amount) external view returns (uint256);

    // Chainlink VRF functions
    function requestRandomLiquidityAdjustment() external;
}
