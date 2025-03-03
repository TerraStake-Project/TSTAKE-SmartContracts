// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "./ITerraStakeRewardDistributor.sol";
import "./ITerraStakeTreasury.sol";

/**
 * @title ITerraStakeLiquidityGuard
 * @notice Interface for the TerraStakeLiquidityGuard contract
 */
interface ITerraStakeLiquidityGuard {
    // Events
    event LiquidityInjected(uint256 amount, uint256 tokenAmount, uint256 usdcAmount);
    event LiquidityRemoved(
        address indexed provider, 
        uint256 amount, 
        uint256 fee,
        uint256 remainingLiquidity,
        uint256 timestamp
    );
    event LiquidityDeposited(address indexed provider, uint256 amount);
    
    event LiquidityCapUpdated(uint256 newCap);
    event LiquidityInjectionRateUpdated(uint256 newRate);
    event LiquidityReinjectionThresholdUpdated(uint256 newThreshold);
    event LiquidityParametersUpdated(
        uint256 dailyLimit, 
        uint256 weeklyLimit, 
        uint256 vestingRate, 
        uint256 baseFee
    );
    
    event CircuitBreakerTriggered();
    event TWAPVerificationFailed(uint256 currentPrice, uint256 twapPrice);
    event EmergencyModeChanged(bool active);
    event AddressWhitelisted(address indexed user, bool status);
    event SlippageToleranceUpdated(uint256 oldTolerance, uint256 newTolerance);
    event RewardDistributorUpdated(address oldDistributor, address newDistributor);
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event UniswapPositionCreated(uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event UniswapPositionIncreased(uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event UniswapPositionDecreased(uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event UniswapPositionClosed(uint256 tokenId, uint256 amount0, uint256 amount1);
    event UniswapFeesCollected(uint256 tokenId, uint256 amount0, uint256 amount1);
    event WeeklyLimitBelowRecommended(uint256 actualLimit, uint256 recommendedMinimum);
    
    // State variables access
    function tStakeToken() external view returns (IERC20Upgradeable);
    function usdcToken() external view returns (IERC20Upgradeable);
    function positionManager() external view returns (INonfungiblePositionManager);
    function uniswapPool() external view returns (IUniswapV3Pool);
    function rewardDistributor() external view returns (ITerraStakeRewardDistributor);
    function treasury() external view returns (ITerraStakeTreasury);
    
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
    function twapObservationTimeframes(uint256 index) external view returns (uint32);
    function managedPositions(uint256 tokenId) external view returns (bool);
    function activePositionIds(uint256 index) external view returns (uint256);
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
    function PERCENTAGE_DENOMINATOR() external view returns (uint256);
    function TWAP_PRICE_TOLERANCE() external view returns (uint256);
    function MAX_FEE_PERCENTAGE() external view returns (uint256);
    function MIN_INJECTION_INTERVAL() external view returns (uint256);
    function MAX_TICK_RANGE() external view returns (uint256);
    function DEFAULT_SLIPPAGE_TOLERANCE() external view returns (uint256);
    function ONE_DAY() external view returns (uint256);
    function ONE_WEEK() external view returns (uint256);
    function ONE_MONTH() external view returns (uint256);
    
    // Core functions
    function initialize(
        address _tStakeToken,
        address _usdcToken,
        address _positionManager,
        address _uniswapPool,
        address _rewardDistributor,
        address _treasury,
        uint256 _reinjectionThreshold,
        address _admin
    ) external;
    
    function depositLiquidity(uint256 amount) external;
    function removeLiquidity(uint256 amount) external;
    function injectLiquidity(uint256 amount) external;
    function collectPositionFees(uint256 tokenId) external returns (uint256 amount0, uint256 amount1);
    function decreasePositionLiquidity(
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min
    ) external returns (uint256 amount0, uint256 amount1);
    function closePosition(uint256 tokenId) external returns (uint256 amount0, uint256 amount1);
    
    // Calculation functions
    function getWithdrawalFee(address user, uint256 amount) external view returns (uint256);
    function validateTWAPPrice() external view returns (bool);
    function calculateTWAP() external view returns (uint256);
    function calculatePriceFromTick(int24 tick) external pure returns (uint256);
    function findBestPositionToIncrease(int24 currentTick) external view returns (uint256);
    
    // Governance functions
    function updateLiquidityParameters(
        uint256 newDailyLimit,
        uint256 newWeeklyLimit,
        uint256 newVestingRate,
        uint256 newBaseFee
    ) external;
    
    function updateLargeLiquidityFeeIncrease(uint256 newFeeIncrease) external;
    function updateLiquidityInjectionRate(uint256 newRate) external;
    function updateLiquidityCap(uint256 newCap) external;
    function updateReinjectionThreshold(uint256 newThreshold) external;
    function updateRemovalCooldown(uint256 newCooldown) external;
    function updateTWAPTimeframes(uint32[] calldata newTimeframes) external;
    function updateSlippageTolerance(uint256 newTolerance) external;
    function updateRewardDistributor(address newDistributor) external;
    function updateTreasury(address newTreasury) external;
    
    // Emergency functions
    function setEmergencyMode(bool active) external;
    function recoverTokens(address token, uint256 amount) external;
    function setWhitelistStatus(address user, bool status) external;
    
    // View functions
    function getUserLiquidityInfo(address user) external view returns (
        uint256 liquidity,
        uint256 vestingStart,
        uint256 lastRemoval
    );
    function getUserWithdrawalInfo(address user) external view returns (
        uint256 dailyAmount,
        uint256 dailyLimit,
        uint256 weeklyAmount,
        uint256 weeklyLimit
    );
    function getAvailableWithdrawalAmount(address user) external view returns (uint256);
    function getActivePositions() external view returns (uint256[] memory);
    function getCurrentPrices() external view returns (uint256 twapPrice, uint256 spotPrice);
    function areWithdrawalsAllowed() external view returns (bool);
    function getAnalytics() external view returns (
        uint256 totalLiquidity,
        uint256 totalInjected,
        uint256 totalFees,
        uint256[2] memory withdrawalStats
    );
    function version() external pure returns (string memory);
}
