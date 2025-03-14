// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./ITerraStakeLiquidityGuard.sol";

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
    
    event BuybackExecuted(uint256 usdcAmount, uint256 tStakeReceived);
    event LiquidityAdded(uint256 tStakeAmount, uint256 usdcAmount);
    event TokensBurned(uint256 amount);
    event TreasuryTransfer(address token, address recipient, uint256 amount);
    event TreasuryWalletUpdated(address newTreasuryWallet);
    event LiquidityPairingToggled(bool enabled);
    event TStakeReceived(address sender, uint256 amount);
    event EmergencyTokenRecovery(address token, uint256 amount, address recipient);
    
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
        external view returns (uint256);
        
    function estimateTStakeForLiquidity(uint256 usdcAmount) external view returns (uint256);
    
    // -------------------------------------------
    //  State-Changing Functions
    // -------------------------------------------
    
    function initialize(
        address _liquidityGuard,
        address _tStakeToken,
        address _usdcToken,
        address _uniswapRouter,
        address _initialAdmin,
        address _treasuryWallet
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
    
    function toggleLiquidityPairing(bool enabled) external;
    
    function emergencyRecoverTokens(
        address token,
        uint256 amount,
        address recipient
    ) external;
    
    function notifyTStakeReceived(address sender, uint256 amount) external;
    
    function updateUniswapRouter(address _newRouter) external;
    
    function updateLiquidityGuard(address _newLiquidityGuard) external;
    
    function updateFeeUpdateCooldown(uint256 _newCooldown) external;
    
    function processFees(uint256 amount, uint8 feeType) external;
    
    /**
     * @notice Withdraws USDC equivalent of the specified amount
     * @param amount The amount to convert to USDC
     * @return The amount of USDC withdrawn
     */
    function withdrawUSDCEquivalent(uint256 amount) external returns (uint256);
}