// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";
import "../interfaces/ITerraStakeTreasury.sol";

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
        uint8 buybackPercentage;
        uint8 liquidityPairingPercentage;
        uint8 burnPercentage;
        uint8 treasuryPercentage;
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
        uint8 buybackPercentage,
        uint8 liquidityPairingPercentage,
        uint8 burnPercentage,
        uint8 treasuryPercentage
    );
    
    event BuybackExecuted(uint256 usdcAmount, uint256 tStakeReceived);
    event LiquidityAdded(uint256 tStakeAmount, uint256 usdcAmount);
    event TokensBurned(uint256 amount);
    event TreasuryTransfer(address token, address recipient, uint256 amount);
    event TreasuryWalletUpdated(address newTreasuryWallet);
    event LiquidityPairingToggled(bool enabled);
    event TStakeReceived(address sender, uint256 amount);
    event EmergencyTokenRecovery(address token, uint256 amount, address recipient);
    event RevenueForwardedToTreasury(address token, uint256 amount, string source);
    event TreasuryAllocationCreated(address token, uint256 amount, uint256 releaseTime);
    event QuoterUpdated(address newQuoter);
    event FallbackPriceUpdated(uint256 price, uint256 timestamp);
    event QuoterFailure(string reason, uint256 amount, uint256 timestamp, address quoter);
    event SlippageApplied(uint256 originalAmount, uint256 slippageAmount, uint256 finalAmount, uint256 adjustedSlippage);
    event FeeTransferred(string category, uint256 amount);
    event UsdcWithdrawn(address indexed recipient, uint256 tStakeAmount, uint256 usdcAmount, uint256 slippageApplied, address quoterUsed);
    event VolatilityUpdated(uint256 volatilityIndex);
    
    // -------------------------------------------
    //  View Functions
    // -------------------------------------------
    
    function GOVERNANCE_ROLE() external view returns (bytes32);
    function UPGRADER_ROLE() external view returns (bytes32);
    function GUARDIAN_ROLE() external view returns (bytes32);
    function POOL_FEE() external view returns (uint24);
    
    function liquidityGuard() external view returns (ITerraStakeLiquidityGuard);
    function tStakeToken() external view returns (IERC20);
    function usdcToken() external view returns (IERC20);
    function currentFeeStructure() external view returns (FeeStructure memory);
    function lastFeeUpdateTime() external view returns (uint256);
    function feeUpdateCooldown() external view returns (uint256);
    function treasuryWallet() external view returns (address);
    function liquidityPairingEnabled() external view returns (bool);
    
    function estimateMinimumTStakeOutput(uint256 usdcAmount, uint256 slippagePercentage) 
        external returns (uint256);
        
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
    
    // -------------------------------------------
    //  State-Changing Functions
    // -------------------------------------------
    
    function initialize(
        address _liquidityGuard,
        address _tStakeToken,
        address _usdcToken,
        address _uniswapRouter,
        address _uniswapQuoter,
        address _initialAdmin,
        address _treasuryWallet,
        address _treasury
    ) external;
    
    function updateFeeStructure(FeeStructure calldata newFeeStructure) external;
    
    function performBuyback(uint256 usdcAmount, uint256 minTStakeAmount) external returns (uint256);
    
    function addLiquidity(uint256 tStakeAmount, uint256 usdcAmount) external;
    
    function burnTokens(uint256 amount) external;
    
    function treasuryTransfer(address token, address recipient, uint256 amount) external;
    
    function updateTreasuryWallet(address newTreasuryWallet) external;
    
    function toggleLiquidityPairing(bool enabled) external;
    
    function emergencyRecoverTokens(address token, uint256 amount, address recipient) external;
    
    function notifyTStakeReceived(address sender, uint256 amount) external;
    
    function updateUniswapRouter(address _newRouter) external;
    
    function updateLiquidityGuard(address _newLiquidityGuard) external;
    
    function updateFeeUpdateCooldown(uint256 _newCooldown) external;
    
    function processFees(uint256 amount, uint8 feeType) external;
    
    function sendRevenueToTreasury(address token, uint256 amount, string calldata source) external;
    
    function requestTokenBurn(uint256 amount) external;
    
    function processFeesWithTreasuryAllocation(uint256 amount, uint8 feeType, string calldata treasuryPurpose) external;
    
    function executeBuyback(uint256 amount) external;
    
    function withdrawUsdcEquivalent(uint256 tStakeAmount, uint256 minUsdcAmount, address recipient) external returns (uint256);
    
    function updateFallbackPrice(uint256 _tStakePerUsdc) external;
}