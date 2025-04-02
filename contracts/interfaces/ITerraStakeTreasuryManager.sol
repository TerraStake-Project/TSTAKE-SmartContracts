// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./ITerraStakeLiquidityGuard.sol";
import "./ITerraStakeTreasury.sol";
import "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import "@api3/contracts/api3-server-v1/proxies/interfaces/IProxy.sol";

/**
 * @title ITerraStakeTreasuryManager
 * @author TerraStake Protocol Team
 * @notice Interface for the TerraStake Protocol treasury management contract
 */
interface ITerraStakeTreasuryManager {
    // -------------------------------------------
    //  Structs
    // -------------------------------------------
    
    struct FeeStructure {
        uint256 projectSubmissionFee;
        uint256 impactReportingFee;
        uint256 buybackPercentage;
        uint256 liquidityPairingPercentage;
        uint256 burnPercentage;
        uint256 treasuryPercentage;
    }
    
    struct SlippageConfig {
        uint256 baseSlippage;
        uint256 minSlippage;
        uint256 maxSlippage;
        uint256 volatilityWindow;
    }
    
    // -------------------------------------------
    //  Events
    // -------------------------------------------
    event FeeStructureUpdated(
        uint256 projectSubmissionFee,
        uint256 impactReportingFee,
        uint256 buybackPercentage,
        uint256 liquidityPairingPercentage,
        uint256 burnPercentage,
        uint256 treasuryPercentage
    );
    event FeePercentageUpdated(string feeType, uint256 newValue);
    event LiquidityAdded(uint256 tStakeAmount, uint256 usdcAmount, address liquidityGuard);
    event TokensBurned(uint256 amount);
    event TreasuryTransfer(address token, address recipient, uint256 amount);
    event TreasuryWalletUpdated(address newTreasuryWallet);
    event LiquidityPairingToggled(bool enabled);
    event TStakeReceived(address sender, uint256 amount);
    event EmergencyTokenRecovery(address token, uint256 amount, address recipient);
    event TreasuryContractUpdated(address newTreasury);
    event RevenueForwardedToTreasury(address token, uint256 amount, string source);
    event QuoterUpdated(address newQuoter);
    event FallbackPriceUpdated(uint256 tStakePerUsdc, uint256 timestamp);
    event QuoterFailure(string reason, uint256 usdcAmount, uint256 timestamp, address uniswapQuoter);
    event SlippageApplied(uint256 originalAmount, uint256 slippageAmount, uint256 finalAmount, uint256 adjustedSlippagePercentage);
    event TreasuryAllocationCreated(address token, uint256 amount, uint256 releaseTime);
    event UsdcWithdrawn(address indexed recipient, uint256 tStakeAmount, uint256 usdcAmount, uint256 slippageApplied, address quoterUsed);
    event VolatilityUpdated(uint256 volatilityIndex);
    event SecondaryQuoterUpdated(address newSecondaryQuoter);
    event API3DataFeedUpdated(address newDataFeed);
    event SlippageConfigUpdated(uint256 baseSlippage, uint256 maxSlippage, uint256 minSlippage, uint256 volatilityWindow);
    event FeeProcessed(uint256 totalAmount, uint8 feeType, uint256 buybackAmount, uint256 liquidityAmount, uint256 treasuryAmount);
    event LiquiditySkippedDueToBalance(uint256 liquidityAmount, uint256 tStakeRequired, uint256 tStakeAvailable);
    event FeeTransferred(string category, uint256 amount);
    event BuybackExecuted(uint256 usdcAmount, uint256 tStakeAmount, uint256 slippageApplied, address quoterUsed);
    
    // -------------------------------------------
    //  Errors
    // -------------------------------------------
    
    error Unauthorized();
    error InvalidParameters();
    error InvalidAmount();
    error InsufficientBalance();
    error SlippageTooHigh();
    error QuoterError(string reason);
    error ZeroAmountQuoted();
    error ExcessivePriceImpact();
    error TransferFailed();
    error DataFeedStale();
    error DataFeedInvalid();
    
    // -------------------------------------------
    //  View Functions
    // -------------------------------------------
    
    function GOVERNANCE_ROLE() external view returns (bytes32);
    function UPGRADER_ROLE() external view returns (bytes32);
    function GUARDIAN_ROLE() external view returns (bytes32);
    function POOL_FEE() external view returns (uint24);
    
    function liquidityGuard() external view returns (ITerraStakeLiquidityGuard);
    function uniswapRouter() external view returns (IV4Router);
    function uniswapQuoter() external view returns (IV4Quoter);
    function tStakeToken() external view returns (IERC20);
    function usdcToken() external view returns (IERC20);
    function treasury() external view returns (ITerraStakeTreasury);
    function lastFeeUpdateTime() external view returns (uint256);
    function feeUpdateCooldown() external view returns (uint256);
    function treasuryWallet() external view returns (address);
    function liquidityPairingEnabled() external view returns (bool);
    function api3DataFeed() external view returns (IProxy);
    
    function estimateMinimumTStakeOutput(uint256 usdcAmount, uint256 slippagePercentage) 
        external returns (uint256);
    function estimateMinimumUsdcOutput(uint256 tStakeAmount, uint256 slippagePercentage) external returns (uint256);
    function estimateTStakeForLiquidity(uint256 usdcAmount) external returns (uint256);
    function getFallbackPriceInfo() external view returns (uint256 price, uint256 timestamp, uint256 age);
    function getQuoterHealthStats() external view returns (uint256 failures, uint256 lastSuccess, bool healthy);
    function calculateFeeDistribution(uint256 amount) external view returns (uint256 buybackAmount, uint256 liquidityAmount, uint256 treasuryAmount, uint256 burnAmount);
    function calculateExpectedOutputFromFallback(uint256 usdcAmount) external view returns (uint256);
    function hasRoleExternal(bytes32 role, address account) external view returns (bool);
    function getProjectSubmissionFee() external view returns (uint256);
    function getImpactReportingFee() external view returns (uint256);
    function getSlippageConfig() external view returns (SlippageConfig memory);
    function getVolatilityInfo() external view returns (uint256 volatility, uint256 historyLength);
    function getAPI3PriceData() external view returns (uint256 price, uint256 timestamp);
    
    // -------------------------------------------
    //  State-Changing Functions
    // -------------------------------------------   
    function updateFeeStructure(FeeStructure calldata newFeeStructure) external;
    
    function performBuyback(uint256 usdcAmount, uint256 minTStakeAmount) external returns (uint256);
    
    function addLiquidity(uint256 tStakeAmount, uint256 usdcAmount) external;
    
    function burnTokens(uint256 amount) external;
    
    function treasuryTransfer(
        address token,
        address recipient, 
        uint256 amount
    ) external;
    
    function updateTreasuryWallet(address newTreasuryWallet) external;
    
    function updateTreasury(address _newTreasury) external;
    
    function toggleLiquidityPairing(bool enabled) external;
    
    function emergencyRecoverTokens(
        address token,
        uint256 amount,
        address recipient
    ) external;
    
    function notifyTStakeReceived(address sender, uint256 amount) external;
    
    function updateUniswapRouter(address _newRouter) external;
    
    function updateUniswapQuoter(address _newQuoter) external;
    function updateSecondaryQuoter(address _newSecondaryQuoter) external;
    function updateAPI3DataFeed(address _newDataFeed) external;
    
    function updateLiquidityGuard(address _newLiquidityGuard) external;
    
    function updateFeeUpdateCooldown(uint256 _newCooldown) external;
    function updateSlippageConfig(SlippageConfig calldata newConfig) external;
    
    function processFees(uint256 amount, uint8 feeType) external;
    
    function sendRevenueToTreasury(address token, uint256 amount, string calldata source) external;
    
    function requestTokenBurn(uint256 amount) external;
    
    function processFeesWithTreasuryAllocation(uint256 amount, uint8 feeType, string calldata treasuryPurpose) external;
    
    function executeBuyback(uint256 amount) external;
    
    function withdrawUSDCEquivalent(uint256 tStakeAmount, uint256 minUsdcAmount, address recipient) external returns (uint256);
    
    function updateFallbackPrice(uint256 _tStakePerUsdc) external;
    function emergencyAdjustFee(uint8 feeType, uint256 newValue) external;
    function updateBuybackPercentage(uint256 newPercentage) external;
    function updateLiquidityPairingPercentage(uint256 newPercentage) external;
    function updateBurnPercentage(uint256 newPercentage) external;
    function updateTreasuryPercentage(uint256 newPercentage) external;
    function updateProjectSubmissionFee(uint256 newFee) external;
    function updateImpactReportingFee(uint256 newFee) external;
}