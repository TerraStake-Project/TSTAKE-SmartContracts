// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./ITerraStakeLiquidityGuard.sol";
import "./ITerraStakeTreasury.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";

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
    event LiquidityAdded(uint256 tStakeAmount, uint256 usdcAmount);
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
    event QuoterFailure(string reason, uint256 usdcAmount, uint256 timestamp);
    event SlippageApplied(uint256 originalAmount, uint256 slippageAmount, uint256 finalAmount);
    event TreasuryAllocationCreated(address token, uint256 amount, uint256 releaseTime);

    /**
     * @notice Event emitted when a fee is transferred to a specific category (buyback, liquidity, burn, treasury)
     * @param category The category of the fee (buyback, liquidity, burn, treasury)
     * @param amount The amount transferred to the category
     */
    event FeeTransferred(string category, uint256 amount);

    /**
     * @notice Event emitted when a buyback is executed
     * @param amount The amount spent in the buyback
     * @param tokensBought The number of tokens bought
     */
    event BuybackExecuted(uint256 amount, uint256 tokensBought);
    
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

    // -------------------------------------------
    //  View Functions
    // -------------------------------------------
    
    function GOVERNANCE_ROLE() external view returns (bytes32);
    function UPGRADER_ROLE() external view returns (bytes32);
    function GUARDIAN_ROLE() external view returns (bytes32);
    function POOL_FEE() external view returns (uint24);
    
    function liquidityGuard() external view returns (ITerraStakeLiquidityGuard);
    function uniswapRouter() external view returns (ISwapRouter);
    function uniswapQuoter() external view returns (IQuoter);
    function tStakeToken() external view returns (IERC20);
    function usdcToken() external view returns (IERC20);
    function treasury() external view returns (ITerraStakeTreasury);
    function currentFeeStructure() external view returns (FeeStructure memory);
    function lastFeeUpdateTime() external view returns (uint256);
    function feeUpdateCooldown() external view returns (uint256);
    function treasuryWallet() external view returns (address);
    function liquidityPairingEnabled() external view returns (bool);
    
    function estimateMinimumTStakeOutput(uint256 usdcAmount, uint256 slippagePercentage) 
        external returns (uint256);
        
    function estimateTStakeForLiquidity(uint256 usdcAmount) external returns (uint256);
    
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
    
    function performBuyback(uint256 usdcAmount, uint256 minTStakeAmount) external;
    
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
    
    function updateLiquidityGuard(address _newLiquidityGuard) external;
    
    function updateFeeUpdateCooldown(uint256 _newCooldown) external;
    
    function processFees(uint256 amount, uint8 feeType) external;
    
    function sendRevenueToTreasury(address token, uint256 amount, string calldata source) external;
    
    function requestTokenBurn(uint256 amount) external;
    
    function processFeesWithTreasuryAllocation(
        uint256 amount, 
        uint8 feeType, 
        string calldata treasuryPurpose
    ) external;
    
    function withdrawUSDCEquivalent(uint256 amount) external returns (uint256);
}
