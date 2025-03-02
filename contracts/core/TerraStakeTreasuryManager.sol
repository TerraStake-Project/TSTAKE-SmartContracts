// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import "../interfaces/ITerraStakeLiquidityGuard.sol";

/**
 * @title TerraStakeTreasuryManager
 * @author TerraStake Protocol Team
 * @notice Treasury management contract for the TerraStake Protocol
 * handling buybacks, liquidity management, and treasury operations
 */
contract TerraStakeTreasuryManager is 
    Initializable, 
    AccessControlEnumerableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable
{
    // -------------------------------------------
    // 🔹 Constants
    // -------------------------------------------
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    
    uint24 public constant POOL_FEE = 3000; // 0.3% pool fee for Uniswap v3
    
    // -------------------------------------------
    // 🔹 State Variables
    // -------------------------------------------
    
    // Contract references
    ITerraStakeLiquidityGuard public liquidityGuard;
    ISwapRouter public uniswapRouter;
    IERC20 public tStakeToken;
    IERC20 public usdcToken;
    
    // Fee structure
    FeeStructure public currentFeeStructure;
    uint256 public lastFeeUpdateTime;
    uint256 public feeUpdateCooldown;
    
    address public treasuryWallet;
    
    // Liquidity pairing
    bool public liquidityPairingEnabled;
    
    // -------------------------------------------
    // 🔹 Structs
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
    // 🔹 Events
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
    // 🔹 Errors
    // -------------------------------------------
    
    error Unauthorized();
    error InvalidParameters();
    error InvalidAmount();
    error InsufficientBalance();
    error SlippageTooHigh();
    
    // -------------------------------------------
    // 🔹 Initializer & Upgrade Control
    // -------------------------------------------
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @notice Initialize the treasury manager contract
     * @param _liquidityGuard Address of the liquidity guard
     * @param _tStakeToken Address of the TStake token
     * @param _usdcToken Address of the USDC token
     * @param _uniswapRouter Address of the Uniswap V3 router
     * @param _initialAdmin Initial admin address
     * @param _treasuryWallet Address of the treasury wallet
     */
    function initialize(
        address _liquidityGuard,
        address _tStakeToken,
        address _usdcToken,
        address _uniswapRouter,
        address _initialAdmin,
        address _treasuryWallet
    ) external initializer {
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        _grantRole(UPGRADER_ROLE, _initialAdmin);
        _grantRole(GOVERNANCE_ROLE, _initialAdmin);
        _grantRole(GUARDIAN_ROLE, _initialAdmin);
        
        // Initialize contract references
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);
        tStakeToken = IERC20(_tStakeToken);
        usdcToken = IERC20(_usdcToken);
        uniswapRouter = ISwapRouter(_uniswapRouter);
        treasuryWallet = _treasuryWallet;
        
        // Initialize fee parameters
        feeUpdateCooldown = 30 days;
        
        // Set initial fee structure
        currentFeeStructure = FeeStructure({
            projectSubmissionFee: 500 * 10**6, // 500 USDC
            impactReportingFee: 100 * 10**6, // 100 USDC
            buybackPercentage: 30, // 30%
            liquidityPairingPercentage: 30, // 30%
            burnPercentage: 20, // 20%
            treasuryPercentage: 20 // 20%
        });
        
        // Enable liquidity pairing by default
        liquidityPairingEnabled = true;
    }
    
    /**
     * @notice Authorize contract upgrades, restricted to the upgrader role
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
    
    // -------------------------------------------
    // 🔹 Treasury Management Functions
    // -------------------------------------------
    
    /**
     * @notice Update fee structure
     * @param newFeeStructure The new fee structure to set
     */
    function updateFeeStructure(FeeStructure calldata newFeeStructure) external onlyRole(GOVERNANCE_ROLE) {
        // Require cooldown period has passed
        require(block.timestamp >= lastFeeUpdateTime + feeUpdateCooldown, "Fee update cooldown active");
        
        // Validate fee percentages sum to 100%
        if (newFeeStructure.buybackPercentage + 
            newFeeStructure.liquidityPairingPercentage + 
            newFeeStructure.burnPercentage + 
            newFeeStructure.treasuryPercentage != 100) {
            revert InvalidParameters();
        }
        
        // Update fee structure
        currentFeeStructure = newFeeStructure;
        lastFeeUpdateTime = block.timestamp;
        
        emit FeeStructureUpdated(
            newFeeStructure.projectSubmissionFee,
            newFeeStructure.impactReportingFee,
            newFeeStructure.buybackPercentage,
            newFeeStructure.liquidityPairingPercentage,
            newFeeStructure.burnPercentage,
            newFeeStructure.treasuryPercentage
        );
    }
    
    /**
     * @notice Perform a buyback of TSTAKE tokens with slippage protection
     * @param usdcAmount Amount of USDC to use for buyback
     * @param minTStakeAmount Minimum amount of TSTAKE to receive
     */
    function performBuyback(uint256 usdcAmount, uint256 minTStakeAmount) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        if (usdcAmount == 0) revert InvalidAmount();
        if (minTStakeAmount == 0) revert InvalidAmount();
        
        uint256 usdcBalance = usdcToken.balanceOf(address(this));
        if (usdcBalance < usdcAmount) revert InsufficientBalance();
        
        // Approve USDC for the router
        usdcToken.approve(address(uniswapRouter), usdcAmount);
        
        // Define the swap parameters with slippage protection
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(usdcToken),
            tokenOut: address(tStakeToken),
            fee: POOL_FEE,
            recipient: address(this),
            deadline: block.timestamp + 15 minutes,
            amountIn: usdcAmount,
            amountOutMinimum: minTStakeAmount, // Add slippage protection
            sqrtPriceLimitX96: 0
        });
        
        // Execute the swap
        uint256 amountOut = uniswapRouter.exactInputSingle(params);
        
        // Verify we received at least the minimum amount
        if (amountOut < minTStakeAmount) revert SlippageTooHigh();
        
        emit BuybackExecuted(usdcAmount, amountOut);
    }
    
    /**
     * @notice Add liquidity to TSTAKE/USDC pair
     * @param tStakeAmount Amount of TSTAKE tokens to add
     * @param usdcAmount Amount of USDC to add
     */
    function addLiquidity(uint256 tStakeAmount, uint256 usdcAmount) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        if (!liquidityPairingEnabled) revert Unauthorized();
        if (tStakeAmount == 0 || usdcAmount == 0) revert InvalidAmount();
        
        uint256 tStakeBalance = tStakeToken.balanceOf(address(this));
        uint256 usdcBalance = usdcToken.balanceOf(address(this));
        
        if (tStakeBalance < tStakeAmount) revert InsufficientBalance();
        if (usdcBalance < usdcAmount) revert InsufficientBalance();
        
        // Transfer tokens to liquidity guard for proper LP management
        tStakeToken.transfer(address(liquidityGuard), tStakeAmount);
        usdcToken.transfer(address(liquidityGuard), usdcAmount);
        
        // Call addLiquidity on the liquidity guard
        liquidityGuard.addLiquidity(tStakeAmount, usdcAmount);
        
        emit LiquidityAdded(tStakeAmount, usdcAmount);
    }
    
    /**
     * @notice Burn TSTAKE tokens from treasury
     * @param amount Amount to burn
     */
    function burnTokens(uint256 amount) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        if (amount == 0) revert InvalidAmount();
        
        uint256 tStakeBalance = tStakeToken.balanceOf(address(this));
        if (tStakeBalance < amount) revert InsufficientBalance();
        
        // Try to use burn function if it exists
        (bool success, ) = address(tStakeToken).call(
            abi.encodeWithSignature("burn(uint256)", amount)
        );
        
        // If burn function doesn't exist, send to dead address
        if (!success) {
            tStakeToken.transfer(address(0xdead), amount);
        }
        
        emit TokensBurned(amount);
    }
    
    /**
     * @notice Transfer tokens from treasury to specified address
     * @param token Token address
     * @param recipient Recipient address
     * @param amount Amount to transfer
     */
    function treasuryTransfer(
        address token,
        address recipient, 
        uint256 amount
    ) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert InvalidParameters();
        
        IERC20(token).transfer(recipient, amount);
        
        emit TreasuryTransfer(token, recipient, amount);
    }
    
    /**
     * @notice Update treasury address
     * @param newTreasuryWallet New treasury wallet address
     */
    function updateTreasuryWallet(address newTreasuryWallet) external onlyRole(GOVERNANCE_ROLE) {
        if (newTreasuryWallet == address(0)) revert InvalidParameters();
        
        treasuryWallet = newTreasuryWallet;
        
        emit TreasuryWalletUpdated(newTreasuryWallet);
    }
    
    /**
     * @notice Toggle liquidity pairing
     * @param enabled Whether liquidity pairing is enabled
     */
    function toggleLiquidityPairing(bool enabled) external onlyRole(GOVERNANCE_ROLE) {
        liquidityPairingEnabled = enabled;
        
        emit LiquidityPairingToggled(enabled);
    }
    
    /**
     * @notice Emergency recovery of tokens accidentally sent to contract
     * @param token Token address
     * @param amount Amount to recover
     * @param recipient Recipient address
     */
    function emergencyRecoverTokens(
        address token,
        uint256 amount,
        address recipient
    ) external onlyRole(GUARDIAN_ROLE) {
        if (recipient == address(0)) revert InvalidParameters();
        
        IERC20(token).transfer(recipient, amount);
        
        emit EmergencyTokenRecovery(token, amount, recipient);
    }
    
    /**
     * @notice Handle notification of TSTAKE tokens received
     * @dev Since ERC20 transfers don't trigger contract code, this function must be called after sending tokens
     * @param sender Address that sent the tokens
     * @param amount Amount of TSTAKE tokens received
     */
    function notifyTStakeReceived(address sender, uint256 amount) external {
        // Verify the transfer occurred by checking current balance
        uint256 contractBalance = tStakeToken.balanceOf(address(this));
        require(contractBalance >= amount, "TSTAKE transfer verification failed");
        
        emit TStakeReceived(sender, amount);
    }
    
    /**
 * @notice Allow contract to receive ETH
     */
    receive() external payable {}
    
    /**
     * @notice Update UniswapRouter address to support future upgrades
     * @param _newRouter Address of the new Uniswap router
     */
    function updateUniswapRouter(address _newRouter) external onlyRole(GOVERNANCE_ROLE) {
        require(_newRouter != address(0), "Invalid router address");
        uniswapRouter = ISwapRouter(_newRouter);
    }
    
    /**
     * @notice Update liquidity guard address
     * @param _newLiquidityGuard Address of the new liquidity guard
     */
    function updateLiquidityGuard(address _newLiquidityGuard) external onlyRole(GOVERNANCE_ROLE) {
        require(_newLiquidityGuard != address(0), "Invalid liquidity guard address");
        liquidityGuard = ITerraStakeLiquidityGuard(_newLiquidityGuard);
    }
    
    /**
     * @notice Update fee update cooldown period
     * @param _newCooldown New cooldown period in seconds
     */
    function updateFeeUpdateCooldown(uint256 _newCooldown) external onlyRole(GOVERNANCE_ROLE) {
        require(_newCooldown >= 1 days, "Cooldown must be at least 1 day");
        feeUpdateCooldown = _newCooldown;
    }
    
    /**
     * @notice Process fees from project submission or impact reporting
     * @param amount The amount of USDC received as fees
     * @param feeType 0 for project submission, 1 for impact reporting
     */
    function processFees(uint256 amount, uint8 feeType) external nonReentrant {
        // Verify sender has governance role
        if (!hasRole(GOVERNANCE_ROLE, msg.sender)) revert Unauthorized();
        
        // Verify amount
        if (amount == 0) revert InvalidAmount();
        
        // Verify we have the tokens
        uint256 usdcBalance = usdcToken.balanceOf(address(this));
        if (usdcBalance < amount) revert InsufficientBalance();
        
        // Calculate fee distribution amounts based on percentages
        uint256 buybackAmount = (amount * currentFeeStructure.buybackPercentage) / 100;
        uint256 liquidityAmount = (amount * currentFeeStructure.liquidityPairingPercentage) / 100;
        uint256 treasuryAmount = (amount * currentFeeStructure.treasuryPercentage) / 100;
        // Burn amount is unused since we don't burn USDC
        
        // Process buyback if there's an amount to process
        if (buybackAmount > 0) {
            // Calculate a reasonable minimum TSTAKE amount (allowing for 5% slippage)
            // In production, should use an oracle for better price estimation
            uint256 minTStakeAmount = estimateMinimumTStakeOutput(buybackAmount, 5); // 5% slippage
            
            // Approve and execute the buyback
            usdcToken.approve(address(uniswapRouter), buybackAmount);
            
            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: address(usdcToken),
                tokenOut: address(tStakeToken),
                fee: POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp + 15 minutes,
                amountIn: buybackAmount,
                amountOutMinimum: minTStakeAmount,
                sqrtPriceLimitX96: 0
            });
            
            uint256 tStakeReceived = uniswapRouter.exactInputSingle(params);
            emit BuybackExecuted(buybackAmount, tStakeReceived);
        }
        
        // Process liquidity addition if enabled and there's an amount to process
        if (liquidityPairingEnabled && liquidityAmount > 0) {
            // For liquidity pairing, we need equal value of TSTAKE and USDC
            // In production, you should use an oracle for accurate pricing
            uint256 tStakeForLiquidity = estimateTStakeForLiquidity(liquidityAmount);
            
            // Check if we have enough TSTAKE from buybacks or existing balance
            uint256 tStakeBalance = tStakeToken.balanceOf(address(this));
            
            if (tStakeBalance >= tStakeForLiquidity) {
                // Transfer tokens to liquidity guard
                tStakeToken.transfer(address(liquidityGuard), tStakeForLiquidity);
                usdcToken.transfer(address(liquidityGuard), liquidityAmount);
                
                // Add liquidity
                liquidityGuard.addLiquidity(tStakeForLiquidity, liquidityAmount);
                emit LiquidityAdded(tStakeForLiquidity, liquidityAmount);
            } else {
                // If not enough TSTAKE, send USDC to treasury instead
                treasuryAmount += liquidityAmount;
            }
        }
        
        // Transfer treasury amount
        if (treasuryAmount > 0) {
            usdcToken.transfer(treasuryWallet, treasuryAmount);
            emit TreasuryTransfer(address(usdcToken), treasuryWallet, treasuryAmount);
        }
    }
    
    /**
     * @notice Estimate minimum TSTAKE output for a given USDC input with slippage
     * @param usdcAmount Amount of USDC input
     * @param slippagePercentage Allowed slippage in percentage
     * @return Minimum TSTAKE to receive
     */
    function estimateMinimumTStakeOutput(uint256 usdcAmount, uint256 slippagePercentage) 
        public view returns (uint256) 
    {
        // In a real implementation, this would use an oracle or Uniswap's quoter
        // This is a simplified placeholder assuming 1 USDC = 0.1 TSTAKE (example)
        uint256 expectedTStake = usdcAmount * 10 / 100; // Placeholder conversion
        
        // Apply slippage
        uint256 slippageAmount = (expectedTStake * slippagePercentage) / 100;
        return expectedTStake - slippageAmount;
    }
    
    /**
     * @notice Estimate amount of TSTAKE needed for liquidity with given USDC amount
     * @param usdcAmount Amount of USDC
     * @return Amount of TSTAKE needed
     */
    function estimateTStakeForLiquidity(uint256 usdcAmount) public view returns (uint256) {
        // In a real implementation, this would use an oracle or Uniswap's quoter
        // This is a simplified placeholder assuming 1 USDC = 0.1 TSTAKE (example)
        return usdcAmount * 10 / 100; // Placeholder conversion
    }
}
