// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";
import "../interfaces/ITerraStakeTreasuryManager.sol";
import "../interfaces/ITerraStakeToken.sol";
import "../interfaces/ITerraStakeTreasury.sol";
import "../interfaces/ITerraStakeGovernance.sol";

/**
 * @title TerraStakeTreasuryManager
 * @author TerraStake Protocol Team
 * @notice Treasury management contract for the TerraStake Protocol
 * handling buybacks, liquidity management, and treasury operations
 * @dev This contract is upgradeable via UUPS pattern and uses OpenZeppelin's access control
 */
contract TerraStakeTreasuryManager is 
    ITerraStakeTreasuryManager,
    Initializable, 
    AccessControlEnumerableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable
{
    // -------------------------------------------
    //  Constants
    // -------------------------------------------
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    
    /// @dev 0.3% pool fee for Uniswap v3 (3000 = 0.3%)
    uint24 public constant POOL_FEE = 3000;
    
    /// @dev Default slippage percentage if not specified (5%)
    uint256 public constant DEFAULT_SLIPPAGE = 5;
    
    /// @dev Minimum value for sanity checks
    uint256 public constant MINIMUM_QUOTE_AMOUNT = 1;
    
    /// @dev Maximum acceptable price impact for quotes (100x)
    uint256 public constant MAX_PRICE_IMPACT_FACTOR = 100;
    
    /// @dev Precision factor for price calculations (1e18 instead of 100)
    uint256 public constant PRICE_PRECISION = 1e18;
    
    /// @dev Time threshold for quoter health check (1 day)
    uint256 public constant QUOTER_HEALTH_THRESHOLD = 1 days;
    
    // -------------------------------------------
    //  State Variables
    // -------------------------------------------
    
    // Contract references
    ITerraStakeLiquidityGuard public liquidityGuard;
    ISwapRouter public uniswapRouter;
    IQuoter public uniswapQuoter;
    IQuoter public secondaryQuoter;
    AggregatorV3Interface public chainlinkPriceFeed;
    IERC20 public tStakeToken;
    IERC20 public usdcToken;
    ITerraStakeTreasury public treasury;
    
    // Fee structure
    FeeStructure public currentFeeStructure;
    uint256 public lastFeeUpdateTime;
    uint256 public feeUpdateCooldown;
    
    address public treasuryWallet;
    
    // Liquidity pairing
    bool public liquidityPairingEnabled;
    
    // Fallback price configuration - now uses 1e18 precision
    uint256 public fallbackTStakePerUsdc; // Amount of tStake per 1 USDC, scaled by PRICE_PRECISION
    uint256 public fallbackPriceTimestamp; // When the fallback price was last updated
    
    // Statistics for monitoring
    uint256 public quoterFailureCount;
    uint256 public lastSuccessfulQuoteTimestamp;
    
    SlippageConfig public slippageConfig;
    uint256[] public priceHistory;
    uint256[] public priceTimestamps;
    uint256 public volatilityIndex;

    // -------------------------------------------
    //  Initializer & Upgrade Control
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
     * @param _uniswapQuoter Address of the Uniswap V3 quoter
     * @param _secondaryQuoter Address of the secondary quoter
     * @param _chainlinkPriceFeed Address of the Chainlink price feed
     * @param _initialAdmin Initial admin address
     * @param _treasuryWallet Address of the treasury wallet
     * @param _treasury Address of the treasury contract
     */
    function initialize(
        address _liquidityGuard,
        address _tStakeToken,
        address _usdcToken,
        address _uniswapRouter,
        address _uniswapQuoter,
        address _secondaryQuoter,
        address _chainlinkPriceFeed,
        address _initialAdmin,
        address _treasuryWallet,
        address _treasury
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
        uniswapQuoter = IQuoter(_uniswapQuoter);
        secondaryQuoter = IQuoter(_secondaryQuoter);
        chainlinkPriceFeed = AggregatorV3Interface(_chainlinkPriceFeed);
        treasuryWallet = _treasuryWallet;
        treasury = ITerraStakeTreasury(_treasury);
        
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
        
        // Set initial fallback price (default: 0.1 TSTAKE per 1 USDC)
        // With PRICE_PRECISION = 1e18, this means 0.1 * 1e18 = 1e17
        fallbackTStakePerUsdc = 1e17;
        fallbackPriceTimestamp = block.timestamp;

        slippageConfig = SlippageConfig({
            baseSlippage: DEFAULT_SLIPPAGE,
            maxSlippage: 20,
            minSlippage: 1,
            volatilityWindow: 1 days
        });
    }
    
    /**
     * @notice Authorize contract upgrades, restricted to the upgrader role
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
    
    // -------------------------------------------
    //  Treasury Management Functions
    // -------------------------------------------
    
    function updateBuybackPercentage(uint256 newPercentage) external onlyRole(GOVERNANCE_ROLE) {
        _updateFeePercentage("buyback", newPercentage);
        currentFeeStructure.buybackPercentage = newPercentage;
        emit FeePercentageUpdated("Buyback", newPercentage);
    }

    function updateLiquidityPairingPercentage(uint256 newPercentage) external onlyRole(GOVERNANCE_ROLE) {
        _updateFeePercentage("liquidityPairing", newPercentage);
        currentFeeStructure.liquidityPairingPercentage = newPercentage;
        emit FeePercentageUpdated("LiquidityPairing", newPercentage);
    }

    function updateBurnPercentage(uint256 newPercentage) external onlyRole(GOVERNANCE_ROLE) {
        _updateFeePercentage("burn", newPercentage);
        currentFeeStructure.burnPercentage = newPercentage;
        emit FeePercentageUpdated("Burn", newPercentage);
    }

    function updateTreasuryPercentage(uint256 newPercentage) external onlyRole(GOVERNANCE_ROLE) {
        _updateFeePercentage("treasury", newPercentage);
        currentFeeStructure.treasuryPercentage = newPercentage;
        emit FeePercentageUpdated("Treasury", newPercentage);
    }

    function updateProjectSubmissionFee(uint256 newFee) external onlyRole(GOVERNANCE_ROLE) {
        if (newFee == 0) revert InvalidAmount();
        currentFeeStructure.projectSubmissionFee = newFee;
        emit FeePercentageUpdated("ProjectSubmissionFee", newFee);
    }

    function updateImpactReportingFee(uint256 newFee) external onlyRole(GOVERNANCE_ROLE) {
        if (newFee == 0) revert InvalidAmount();
        currentFeeStructure.impactReportingFee = newFee;
        emit FeePercentageUpdated("ImpactReportingFee", newFee);
    }

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
    function performBuyback(uint256 usdcAmount, uint256 minTStakeAmount) public onlyRole(GOVERNANCE_ROLE) nonReentrant returns (uint256) {
        if (usdcAmount == 0) revert InvalidAmount();
        if (minTStakeAmount == 0) revert InvalidAmount();
        
        uint256 usdcBalance = usdcToken.balanceOf(address(this));
        if (usdcBalance < usdcAmount) revert InsufficientBalance();
        
        // Approve USDC for the router
        _safeApprove(address(usdcToken), address(uniswapRouter), usdcAmount);
        
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
        address quoterUsed = lastSuccessfulQuoteTimestamp == block.timestamp 
            ? address(uniswapQuoter) 
            : address(0);
        uint256 amountOut = uniswapRouter.exactInputSingle(params);
        
        // Verify we received at least the minimum amount
        if (amountOut < minTStakeAmount) revert SlippageTooHigh();
        
        // Update fallback price based on this swap
        _updateFallbackPrice(usdcAmount, amountOut, true);
        
        uint256 slippageApplied = amountOut > minTStakeAmount ? 0 : (minTStakeAmount - amountOut);
        emit BuybackExecuted(usdcAmount, amountOut, slippageApplied, quoterUsed);
        return amountOut;
    }
    
    /**
     * @notice Add liquidity to TSTAKE/USDC pair
     * @param tStakeAmount Amount of TSTAKE tokens to add
     * @param usdcAmount Amount of USDC to add
     */
    function addLiquidity(uint256 tStakeAmount, uint256 usdcAmount) public onlyRole(GOVERNANCE_ROLE) nonReentrant {
        if (!liquidityPairingEnabled) revert Unauthorized();
        if (tStakeAmount == 0 || usdcAmount == 0) revert InvalidAmount();
        
        uint256 tStakeBalance = tStakeToken.balanceOf(address(this));
        uint256 usdcBalance = usdcToken.balanceOf(address(this));
        
        if (tStakeBalance < tStakeAmount) revert InsufficientBalance();
        if (usdcBalance < usdcAmount) revert InsufficientBalance();
        
        // Transfer tokens to liquidity guard for proper LP management
        _safeTransfer(address(tStakeToken), address(liquidityGuard), tStakeAmount);
        _safeTransfer(address(usdcToken), address(liquidityGuard), usdcAmount);
        
        // Call addLiquidity on the liquidity guard
        liquidityGuard.addLiquidity(tStakeAmount, usdcAmount);
        
        emit LiquidityAdded(tStakeAmount, usdcAmount, address(liquidityGuard));
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
            _safeTransfer(address(tStakeToken), address(0xdead), amount);
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
        
        _safeTransfer(token, recipient, amount);
        
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
     * @notice Update treasury contract address
     * @param _newTreasury Address of the new treasury contract
     */
    function updateTreasury(address _newTreasury) external onlyRole(GOVERNANCE_ROLE) {
        if (_newTreasury == address(0)) revert InvalidParameters();
        treasury = ITerraStakeTreasury(_newTreasury);
        emit TreasuryContractUpdated(_newTreasury);
    }
    
    /**
     * @notice Send collected revenue to the treasury
     * @param token Token address
     * @param amount Amount to send
     * @param source Source description
     */
    function sendRevenueToTreasury(address token, uint256 amount, string calldata source) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
        nonReentrant 
    {
        if (amount == 0) revert InvalidAmount();
        
        _safeApprove(token, address(treasury), amount);
        treasury.receiveRevenue(token, amount, source);
        
        emit RevenueForwardedToTreasury(token, amount, source);
    }

    /**
     * @notice Request token burn through treasury
     * @param amount Amount to burn
     */
    function requestTokenBurn(uint256 amount) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
        nonReentrant 
    {
        if (amount == 0) revert InvalidAmount();
        
        _safeTransfer(address(tStakeToken), address(treasury), amount);
        treasury.burnTokens(amount);
        
        emit TokensBurned(amount);
    }
    
    /**
     * @notice Process fees and coordinate with treasury for allocation
     * @param amount The amount of USDC received as fees
     * @param feeType 0 for project submission, 1 for impact reporting
     * @param treasuryPurpose Purpose description for treasury allocation
     */
    function processFeesWithTreasuryAllocation(
        uint256 amount, 
        uint8 feeType, 
        string calldata treasuryPurpose
    ) external nonReentrant {
        // Verify sender has governance role
        if (!hasRole(GOVERNANCE_ROLE, msg.sender)) revert Unauthorized();
        
        // Process fees as before
        processFees(amount, feeType);
        
        // Calculate treasury amount
        uint256 treasuryAmount = amount * currentFeeStructure.treasuryPercentage / 100;
        
        // Allocate to treasury if needed
        if (treasuryAmount > 0) {
            _safeApprove(address(usdcToken), address(treasury), treasuryAmount);
            
            // Use current time + 1 day as release time for example
            uint256 releaseTime = block.timestamp + 1 days;
            
            treasury.allocateFunds(
                address(usdcToken),
                treasuryWallet,
                treasuryAmount,
                releaseTime,
                treasuryPurpose
            );
            
            emit TreasuryAllocationCreated(address(usdcToken), treasuryAmount, releaseTime);
        }
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
        
        // Check if we have enough balance
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < amount) revert InsufficientBalance();
        
        _safeTransfer(token, recipient, amount);
        
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
        if (_newRouter == address(0)) revert InvalidParameters();
        uniswapRouter = ISwapRouter(_newRouter);
    }
    
    /**
     * @notice Update Uniswap Quoter address
     * @param _newQuoter Address of the new Uniswap quoter
     */
    function updateUniswapQuoter(address _newQuoter) external onlyRole(GOVERNANCE_ROLE) {
        if (_newQuoter == address(0)) revert InvalidParameters();
        uniswapQuoter = IQuoter(_newQuoter);
        
        // Reset quoter failure counter when updating quoter
        quoterFailureCount = 0;
        
        emit QuoterUpdated(_newQuoter);
    }

    function updateSecondaryQuoter(address _newSecondaryQuoter) external onlyRole(GOVERNANCE_ROLE) {
        if (_newSecondaryQuoter == address(0)) revert InvalidParameters();
        secondaryQuoter = IQuoter(_newSecondaryQuoter);
        emit SecondaryQuoterUpdated(_newSecondaryQuoter);
    }

    function updateChainlinkPriceFeed(address _newPriceFeed) external onlyRole(GOVERNANCE_ROLE) {
        if (_newPriceFeed == address(0)) revert InvalidParameters();
        chainlinkPriceFeed = AggregatorV3Interface(_newPriceFeed);
        emit ChainlinkPriceFeedUpdated(_newPriceFeed);
    }
    
    /**
     * @notice Update liquidity guard address
     * @param _newLiquidityGuard Address of the new liquidity guard
     */
    function updateLiquidityGuard(address _newLiquidityGuard) external onlyRole(GOVERNANCE_ROLE) {
        if (_newLiquidityGuard == address(0)) revert InvalidParameters();
        liquidityGuard = ITerraStakeLiquidityGuard(_newLiquidityGuard);
    }
    
    /**
     * @notice Update fee update cooldown period
     * @param _newCooldown New cooldown period in seconds
     */
    function updateFeeUpdateCooldown(uint256 _newCooldown) external onlyRole(GOVERNANCE_ROLE) {
        if (_newCooldown < 1 days) revert InvalidParameters();
        feeUpdateCooldown = _newCooldown;
    }
    
    /**
     * @notice Manually update the fallback price for price quotations
     * @dev This is useful when market conditions change significantly or after periods of low liquidity
     * @param _tStakePerUsdc New amount of TSTAKE per 1 USDC (scaled by PRICE_PRECISION)
     */
    function updateFallbackPrice(uint256 _tStakePerUsdc) external onlyRole(GOVERNANCE_ROLE) {
        if (_tStakePerUsdc == 0) revert InvalidParameters();
        
        fallbackTStakePerUsdc = _tStakePerUsdc;
        fallbackPriceTimestamp = block.timestamp;
        
        emit FallbackPriceUpdated(_tStakePerUsdc, block.timestamp);
    }

    function updateSlippageConfig(SlippageConfig calldata newConfig) external onlyRole(GOVERNANCE_ROLE) {
        if (newConfig.minSlippage == 0 || 
            newConfig.maxSlippage < newConfig.minSlippage || 
            newConfig.baseSlippage < newConfig.minSlippage || 
            newConfig.baseSlippage > newConfig.maxSlippage ||
            newConfig.volatilityWindow < 1 hours) {
            revert InvalidParameters();
        }
        slippageConfig = newConfig;
        emit SlippageConfigUpdated(newConfig.baseSlippage, newConfig.maxSlippage, newConfig.minSlippage, newConfig.volatilityWindow);
    }
    
    /**
     * @notice Process fees from project submission or impact reporting
     * @param amount The amount of USDC received as fees
     * @param feeType 0 for project submission, 1 for impact reporting
     */
    function processFees(uint256 amount, uint8 feeType) public nonReentrant {
        // Verify sender has governance role
        if (!hasRole(GOVERNANCE_ROLE, msg.sender)) revert Unauthorized();
        
        // Verify amount
        if (amount == 0) revert InvalidAmount();
        
        // Verify we have the tokens
        uint256 usdcBalance = usdcToken.balanceOf(address(this));
        if (usdcBalance < amount) revert InsufficientBalance();
        
        FeeStructure memory feeStruct = currentFeeStructure;
        bool isLiquidityEnabled = liquidityPairingEnabled;
        address cachedTreasuryWallet = treasuryWallet;
        
        uint256 buybackAmount = amount * feeStruct.buybackPercentage / 100;
        uint256 liquidityAmount = amount * feeStruct.liquidityPairingPercentage / 100;
        uint256 treasuryAmount = amount * feeStruct.treasuryPercentage / 100;
        
        emit FeeProcessed(amount, feeType, buybackAmount, liquidityAmount, treasuryAmount);
        
        if (buybackAmount > 0) {
            // Calculate a reasonable minimum TSTAKE amount (allowing for default slippage)
            uint256 minTStakeAmount = estimateMinimumTStakeOutput(buybackAmount, DEFAULT_SLIPPAGE);
            
            // Approve and execute the buyback
            _safeApprove(address(usdcToken), address(uniswapRouter), buybackAmount);
            
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
            
            address quoterUsed = lastSuccessfulQuoteTimestamp == block.timestamp 
                ? address(uniswapQuoter) 
                : address(0);
            uint256 tStakeReceived = uniswapRouter.exactInputSingle(params);
            
            // Update fallback price based on this successful swap
            _updateFallbackPrice(buybackAmount, tStakeReceived, true);
            
            uint256 slippageApplied = tStakeReceived > minTStakeAmount ? 0 : (minTStakeAmount - tStakeReceived);
            emit BuybackExecuted(buybackAmount, tStakeReceived, slippageApplied, quoterUsed);
        }
        
        // Process liquidity addition if enabled and there's an amount to process
        if (liquidityPairingEnabled && liquidityAmount > 0) {
            // For liquidity pairing, we need equal value of TSTAKE and USDC
            uint256 tStakeForLiquidity = estimateTStakeForLiquidity(liquidityAmount);
            
            // Check if we have enough TSTAKE from buybacks or existing balance
            uint256 tStakeBalance = tStakeToken.balanceOf(address(this));
            
            if (tStakeBalance >= tStakeForLiquidity) {
                // Transfer tokens to liquidity guard
                _safeTransfer(address(tStakeToken), address(liquidityGuard), tStakeForLiquidity);
                _safeTransfer(address(usdcToken), address(liquidityGuard), liquidityAmount);
                
                // Add liquidity
                liquidityGuard.addLiquidity(tStakeForLiquidity, liquidityAmount);
                emit LiquidityAdded(tStakeForLiquidity, liquidityAmount, address(liquidityGuard));
            } else {
                // If not enough TSTAKE, send USDC to treasury instead
                treasuryAmount += liquidityAmount;
                emit LiquiditySkippedDueToBalance(liquidityAmount, tStakeForLiquidity, tStakeBalance);
            }
        }
        
        // Transfer treasury amount
        if (treasuryAmount > 0) {
            _safeTransfer(address(usdcToken), cachedTreasuryWallet, treasuryAmount);
            emit TreasuryTransfer(address(usdcToken), cachedTreasuryWallet, treasuryAmount);
        }
    }

    /**
     * @notice Split the fee into categories (buyback, liquidity, burn, treasury)
     * @param amount The total amount to split (e.g., buyback funds)
     */
    function splitFee(uint256 amount)
        internal
        returns (
            uint256 buybackAmount,
            uint256 liquidityAmount,
            uint256 burnAmount,
            uint256 treasuryAmount
        )
    {
        if (amount == 0) revert InvalidAmount();

        FeeStructure memory feeStruct = currentFeeStructure;
        buybackAmount = (amount * feeStruct.buybackPercentage) / 100;
        liquidityAmount = (amount * feeStruct.liquidityPairingPercentage) / 100;
        burnAmount = (amount * feeStruct.burnPercentage) / 100;
        treasuryAmount = (amount * feeStruct.treasuryPercentage) / 100;

        if (buybackAmount > 0) emit FeeTransferred("Buyback", buybackAmount);
        if (liquidityAmount > 0) emit FeeTransferred("Liquidity", liquidityAmount);
        if (burnAmount > 0) emit FeeTransferred("Burn", burnAmount);
        if (treasuryAmount > 0) emit FeeTransferred("Treasury", treasuryAmount);

        return (buybackAmount, liquidityAmount, burnAmount, treasuryAmount);
    }

    /**
     * @notice Emergency adjustment of fees for governance purposes
     * @param feeType The type of fee to adjust: 1 for project submission, 2 for impact reporting
     * @param newValue The new value for the specified fee type
     */
    function emergencyAdjustFee(uint8 feeType, uint256 newValue) external onlyRole(GOVERNANCE_ROLE) {
        if (newValue == 0) revert InvalidAmount();

        if (feeType == 1) {
            currentFeeStructure.projectSubmissionFee = newValue;
            emit FeePercentageUpdated("ProjectSubmissionFee", newValue);
        } else if (feeType == 2) {
            currentFeeStructure.impactReportingFee = newValue;
            emit FeePercentageUpdated("ImpactReportingFee", newValue);
        } else {
            revert InvalidParameters();
        }
    }

    /**
     * @notice Execute a buyback using the fee mechanism
     * @param amount The total amount to use for buyback and associated processes
     */
    function executeBuyback(uint256 amount) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        if (amount == 0) revert InvalidAmount();

        bool isLiquidityEnabled = liquidityPairingEnabled;
        address cachedTreasuryWallet = treasuryWallet;

        (
            uint256 buybackAmount,
            uint256 liquidityAmount,
            uint256 burnAmount,
            uint256 treasuryAmount
        ) = splitFee(amount);

        uint256 tStakeReceived = 0;
        if (buybackAmount > 0) {
            uint256 minTStakeAmount = estimateMinimumTStakeOutput(buybackAmount, DEFAULT_SLIPPAGE);
            tStakeReceived = performBuyback(buybackAmount, minTStakeAmount);
        }

        if (isLiquidityEnabled && liquidityAmount > 0) {
            uint256 tStakeForLiquidity = estimateTStakeForLiquidity(liquidityAmount);
            uint256 tStakeBalance = tStakeToken.balanceOf(address(this));
            if (tStakeBalance >= tStakeForLiquidity) {
                addLiquidity(tStakeForLiquidity, liquidityAmount);
            } else {
                _safeTransfer(address(usdcToken), cachedTreasuryWallet, liquidityAmount);
                emit TreasuryTransfer(address(usdcToken), cachedTreasuryWallet, liquidityAmount);
            }
        }

        if (burnAmount > 0) {
            _safeTransfer(address(usdcToken), address(0xdead), burnAmount);
            emit FeeTransferred("Burn", burnAmount);
        }

        if (treasuryAmount > 0) {
            _safeTransfer(address(usdcToken), cachedTreasuryWallet, treasuryAmount);
            emit TreasuryTransfer(address(usdcToken), cachedTreasuryWallet, treasuryAmount);
        }

        if (buybackAmount > 0) {
            emit BuybackExecuted(
                buybackAmount, 
                tStakeReceived, 
                0, // Slippage already emitted in performBuyback
                lastSuccessfulQuoteTimestamp == block.timestamp ? address(uniswapQuoter) : address(0)
            );
        }
    }

    /**
     * @notice Estimate minimum USDC output for a given TSTAKE input with slippage
     * @param tStakeAmount Amount of TSTAKE input
     * @param slippagePercentage Base slippage percentage
     * @return Minimum USDC to receive
     */
    function estimateMinimumUsdcOutput(uint256 tStakeAmount, uint256 slippagePercentage) 
        public 
        returns (uint256) 
    {
        if (tStakeAmount == 0) return 0;
        
        // Try primary Quoter
        try uniswapQuoter.quoteExactInputSingle(
            address(tStakeToken),
            address(usdcToken),
            POOL_FEE,
            tStakeAmount,
            0
        ) returns (uint256 expectedUsdc) {
            return _validateAndApplySlippage(expectedUsdc, tStakeAmount, slippagePercentage, false);
        } catch (bytes memory reason) {
            emit QuoterFailure(string(reason), tStakeAmount, block.timestamp, address(uniswapQuoter));
            quoterFailureCount++;
        }
        
        // Try secondary Quoter
        try secondaryQuoter.quoteExactInputSingle(
            address(tStakeToken),
            address(usdcToken),
            POOL_FEE,
            tStakeAmount,
            0
        ) returns (uint256 expectedUsdc) {
            return _validateAndApplySlippage(expectedUsdc, tStakeAmount, slippagePercentage, false);
        } catch (bytes memory reason) {
            emit QuoterFailure(string(reason), tStakeAmount, block.timestamp, address(secondaryQuoter));
            quoterFailureCount++;
        }
        
        // Try Chainlink price feed
        try chainlinkPriceFeed.latestRoundData() returns (
            uint80, 
            int256 price, 
            uint256, 
            uint256 updatedAt, 
            uint80
        ) {
            if (block.timestamp - updatedAt > 1 hours) {
                emit QuoterFailure("Chainlink price stale", tStakeAmount, block.timestamp, address(chainlinkPriceFeed));
                quoterFailureCount++;
            } else if (price <= 0) {
                emit QuoterFailure("Invalid Chainlink price", tStakeAmount, block.timestamp, address(chainlinkPriceFeed));
                quoterFailureCount++;
            } else {
                // Chainlink price is TSTAKE/USDC, scaled by 1e8
                uint256 expectedUsdc = tStakeAmount * PRICE_PRECISION / (uint256(price) * PRICE_PRECISION / 1e8);
                return _validateAndApplySlippage(expectedUsdc, tStakeAmount, slippagePercentage, false);
            }
        } catch (bytes memory reason) {
            emit QuoterFailure(string(reason), tStakeAmount, block.timestamp, address(chainlinkPriceFeed));
            quoterFailureCount++;
        }
        
        // Fallback to historical price
        return _applySlippageToFallbackEstimateUsdc(tStakeAmount, slippagePercentage);
    }

    /**
     * @notice Apply slippage to fallback estimate for USDC
     * @param tStakeAmount TSTAKE amount to estimate for
     * @param slippagePercentage Slippage percentage to apply
     * @return Estimated USDC amount after slippage
     */
    function _applySlippageToFallbackEstimateUsdc(uint256 tStakeAmount, uint256 slippagePercentage) 
        internal 
        returns (uint256) 
    {
        uint256 expectedUsdc = tStakeAmount * PRICE_PRECISION / fallbackTStakePerUsdc;
        return _applySlippage(expectedUsdc, slippagePercentage);
    }

    /**
     * @notice Withdraw the USDC equivalent of a specified amount of TSTAKE tokens
     * @param tStakeAmount Amount of TSTAKE to convert to USDC
     * @param minUsdcAmount Minimum amount of USDC to receive (slippage protection)
     * @param recipient Address to receive the USDC
     * @return usdcReceived The amount of USDC received from the swap
     */
    function withdrawUSDCEquivalent(
        uint256 tStakeAmount,
        uint256 minUsdcAmount,
        address recipient
    ) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
        nonReentrant 
        returns (uint256 usdcReceived) 
    {
        if (tStakeAmount == 0) revert InvalidAmount();
        if (minUsdcAmount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert InvalidParameters();

        uint256 tStakeBalance = tStakeToken.balanceOf(address(this));
        if (tStakeBalance < tStakeAmount) revert InsufficientBalance();

        _safeApprove(address(tStakeToken), address(uniswapRouter), tStakeAmount);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(tStakeToken),
            tokenOut: address(usdcToken),
            fee: POOL_FEE,
            recipient: recipient,
            deadline: block.timestamp + 15 minutes,
            amountIn: tStakeAmount,
            amountOutMinimum: minUsdcAmount,
            sqrtPriceLimitX96: 0
        });

        address quoterUsed = lastSuccessfulQuoteTimestamp == block.timestamp 
            ? address(uniswapQuoter) 
            : address(0);
        usdcReceived = uniswapRouter.exactInputSingle(params);

        if (usdcReceived < minUsdcAmount) revert SlippageTooHigh();

        _updateFallbackPrice(usdcReceived, tStakeAmount, false);

        uint256 slippageApplied = usdcReceived > minUsdcAmount ? 0 : (minUsdcAmount - usdcReceived);
        emit TreasuryTransfer(address(usdcToken), recipient, usdcReceived);
        emit UsdcWithdrawn(recipient, tStakeAmount, usdcReceived, slippageApplied, quoterUsed);
        return usdcReceived;
    }
    
    /**
     * @notice Estimate minimum TSTAKE output for a given USDC input with slippage
     * @param usdcAmount Amount of USDC input
     * @param slippagePercentage Base slippage percentage
     * @return Minimum TSTAKE to receive
     */
    function estimateMinimumTStakeOutput(uint256 usdcAmount, uint256 slippagePercentage) 
        public returns (uint256) 
    {
        if (usdcAmount == 0) return 0;
        
        // Try primary Quoter
        try uniswapQuoter.quoteExactInputSingle(
            address(usdcToken),
            address(tStakeToken),
            POOL_FEE,
            usdcAmount,
            0
        ) returns (uint256 expectedTStake) {
            return _validateAndApplySlippage(expectedTStake, usdcAmount, slippagePercentage, true);
        } catch (bytes memory reason) {
            emit QuoterFailure(string(reason), usdcAmount, block.timestamp, address(uniswapQuoter));
            quoterFailureCount++;
        }
        
        // Try secondary Quoter
        try secondaryQuoter.quoteExactInputSingle(
            address(usdcToken),
            address(tStakeToken),
            POOL_FEE,
            usdcAmount,
            0
        ) returns (uint256 expectedTStake) {
            return _validateAndApplySlippage(expectedTStake, usdcAmount, slippagePercentage, true);
        } catch (bytes memory reason) {
            emit QuoterFailure(string(reason), usdcAmount, block.timestamp, address(secondaryQuoter));
            quoterFailureCount++;
        }
        
        // Try Chainlink price feed
        try chainlinkPriceFeed.latestRoundData() returns (
            uint80, 
            int256 price, 
            uint256, 
            uint256 updatedAt, 
            uint80
        ) {
            if (block.timestamp - updatedAt > 1 hours) {
                emit QuoterFailure("Chainlink price stale", usdcAmount, block.timestamp, address(chainlinkPriceFeed));
                quoterFailureCount++;
            } else if (price <= 0) {
                emit QuoterFailure("Invalid Chainlink price", usdcAmount, block.timestamp, address(chainlinkPriceFeed));
                quoterFailureCount++;
            } else {
                uint256 expectedTStake = usdcAmount * uint256(price) * PRICE_PRECISION / (1e8 * PRICE_PRECISION);
                return _validateAndApplySlippage(expectedTStake, usdcAmount, slippagePercentage, true);
            }
        } catch (bytes memory reason) {
            emit QuoterFailure(string(reason), usdcAmount, block.timestamp, address(chainlinkPriceFeed));
            quoterFailureCount++;
        }
        
        // Fallback to historical price
        return _applySlippageToFallbackEstimate(usdcAmount, slippagePercentage);
    }
    
    /**
     * @notice Validate a quoted amount and apply slippage
     * @param expectedAmount The quoted amount
     * @param inputAmount The input amount (USDC or TSTAKE)
     * @param slippagePercentage Base slippage percentage
     * @param isUsdcToTStake True if USDC -> TSTAKE, false if TSTAKE -> USDC
     * @return Amount after validation and slippage
     */
    function _validateAndApplySlippage(
        uint256 expectedAmount,
        uint256 inputAmount,
        uint256 slippagePercentage,
        bool isUsdcToTStake
    ) internal returns (uint256) {
        if (expectedAmount == 0) {
            emit QuoterFailure(
                isUsdcToTStake ? "Zero amount quoted" : "Zero amount quoted for USDC", 
                inputAmount, 
                block.timestamp, 
                address(0)
            );
            quoterFailureCount++;
            return isUsdcToTStake 
                ? _applySlippageToFallbackEstimate(inputAmount, slippagePercentage)
                : _applySlippageToFallbackEstimateUsdc(inputAmount, slippagePercentage);
        }
        
        uint256 fallbackEstimate = isUsdcToTStake 
            ? inputAmount * fallbackTStakePerUsdc / PRICE_PRECISION
            : inputAmount * PRICE_PRECISION / fallbackTStakePerUsdc;
            
        if (expectedAmount < fallbackEstimate / MAX_PRICE_IMPACT_FACTOR) {
            emit QuoterFailure(
                isUsdcToTStake ? "Quote too low compared to fallback" : "Quote too low compared to fallback for USDC", 
                inputAmount, 
                block.timestamp, 
                address(0)
            );
            quoterFailureCount++;
            return isUsdcToTStake 
                ? _applySlippageToFallbackEstimate(inputAmount, slippagePercentage)
                : _applySlippageToFallbackEstimateUsdc(inputAmount, slippagePercentage);
        }
        
        if (expectedAmount > fallbackEstimate * MAX_PRICE_IMPACT_FACTOR) {
            emit QuoterFailure(
                isUsdcToTStake ? "Quote too high compared to fallback" : "Quote too high compared to fallback for USDC", 
                inputAmount, 
                block.timestamp, 
                address(0)
            );
            quoterFailureCount++;
            return isUsdcToTStake 
                ? _applySlippageToFallbackEstimate(inputAmount, slippagePercentage)
                : _applySlippageToFallbackEstimateUsdc(inputAmount, slippagePercentage);
        }
        
        lastSuccessfulQuoteTimestamp = block.timestamp;
        return _applySlippage(expectedAmount, slippagePercentage);
    }

    /**
     * @notice Validate a quoted TSTAKE amount for liquidity
     * @param tStakeAmount The quoted TSTAKE amount
     * @param usdcAmount The USDC amount
     * @return Validated TSTAKE amount
     */
    function _validateQuoteForLiquidity(uint256 tStakeAmount, uint256 usdcAmount) internal returns (uint256) {
        if (tStakeAmount == 0) {
            emit QuoterFailure("Zero amount quoted for liquidity", usdcAmount, block.timestamp, address(0));
            quoterFailureCount++;
            return usdcAmount * fallbackTStakePerUsdc / PRICE_PRECISION;
        }
        
        uint256 fallbackEstimate = usdcAmount * fallbackTStakePerUsdc / PRICE_PRECISION;
        if (tStakeAmount < fallbackEstimate / MAX_PRICE_IMPACT_FACTOR || 
            tStakeAmount > fallbackEstimate * MAX_PRICE_IMPACT_FACTOR) {
            emit QuoterFailure("Extreme liquidity quote", usdcAmount, block.timestamp, address(0));
            quoterFailureCount++;
            return fallbackEstimate;
        }
        
        lastSuccessfulQuoteTimestamp = block.timestamp;
        return tStakeAmount;
    }

    /**
     * @notice Update a fee percentage and validate the total
     * @param feeType Type of fee being updated
     * @param newPercentage New percentage value
     */
    function _updateFeePercentage(string memory feeType, uint256 newPercentage) internal {
        require(block.timestamp >= lastFeeUpdateTime + feeUpdateCooldown, "Fee update cooldown active");
        
        uint256 totalPercentage = 0;
        if (keccak256(abi.encodePacked(feeType)) == keccak256(abi.encodePacked("buyback"))) {
            totalPercentage = newPercentage + 
                              currentFeeStructure.liquidityPairingPercentage + 
                              currentFeeStructure.burnPercentage + 
                              currentFeeStructure.treasuryPercentage;
        } else if (keccak256(abi.encodePacked(feeType)) == keccak256(abi.encodePacked("liquidityPairing"))) {
            totalPercentage = currentFeeStructure.buybackPercentage + 
                              newPercentage + 
                              currentFeeStructure.burnPercentage + 
                              currentFeeStructure.treasuryPercentage;
        } else if (keccak256(abi.encodePacked(feeType)) == keccak256(abi.encodePacked("burn"))) {
            totalPercentage = currentFeeStructure.buybackPercentage + 
                              currentFeeStructure.liquidityPairingPercentage + 
                              newPercentage + 
                              currentFeeStructure.treasuryPercentage;
        } else if (keccak256(abi.encodePacked(feeType)) == keccak256(abi.encodePacked("treasury"))) {
            totalPercentage = currentFeeStructure.buybackPercentage + 
                              currentFeeStructure.liquidityPairingPercentage + 
                              currentFeeStructure.burnPercentage + 
                              newPercentage;
        }
        
        if (totalPercentage != 100) revert InvalidParameters();
        lastFeeUpdateTime = block.timestamp;
    }



    /**
     * @notice Estimate amount of TSTAKE needed for liquidity with given USDC amount
     * @param usdcAmount Amount of USDC
     * @return Amount of TSTAKE needed
     * @dev This function attempts to use the Uniswap Quoter, but falls back to a calculation
     *      based on historical data if the quoter fails
     */
    function estimateTStakeForLiquidity(uint256 usdcAmount) public returns (uint256) {
        if (usdcAmount == 0) return 0;
        
        // Try primary Quoter
        try uniswapQuoter.quoteExactInputSingle(
            address(usdcToken),
            address(tStakeToken),
            POOL_FEE,
            usdcAmount,
            0
        ) returns (uint256 tStakeAmount) {
            return _validateQuoteForLiquidity(tStakeAmount, usdcAmount);
        } catch (bytes memory reason) {
            emit QuoterFailure(string(reason), usdcAmount, block.timestamp, address(uniswapQuoter));
            quoterFailureCount++;
        }
        
        // Try secondary Quoter
        try secondaryQuoter.quoteExactInputSingle(
            address(usdcToken),
            address(tStakeToken),
            POOL_FEE,
            usdcAmount,
            0
        ) returns (uint256 tStakeAmount) {
            return _validateQuoteForLiquidity(tStakeAmount, usdcAmount);
        } catch (bytes memory reason) {
            emit QuoterFailure(string(reason), usdcAmount, block.timestamp, address(secondaryQuoter));
            quoterFailureCount++;
        }
        
        // Try Chainlink price feed
        try chainlinkPriceFeed.latestRoundData() returns (
            uint80, 
            int256 price, 
            uint256, 
            uint256 updatedAt, 
            uint80
        ) {
            if (block.timestamp - updatedAt > 1 hours) {
                emit QuoterFailure("Chainlink price stale", usdcAmount, block.timestamp, address(chainlinkPriceFeed));
                quoterFailureCount++;
            } else if (price <= 0) {
                emit QuoterFailure("Invalid Chainlink price", usdcAmount, block.timestamp, address(chainlinkPriceFeed));
                quoterFailureCount++;
            } else {
                uint256 tStakeAmount = usdcAmount * uint256(price) * PRICE_PRECISION / (1e8 * PRICE_PRECISION);
                return _validateQuoteForLiquidity(tStakeAmount, usdcAmount);
            }
        } catch (bytes memory reason) {
            emit QuoterFailure(string(reason), usdcAmount, block.timestamp, address(chainlinkPriceFeed));
            quoterFailureCount++;
        }
        
        // Fallback to historical price
        return usdcAmount * fallbackTStakePerUsdc / PRICE_PRECISION;
    }
    
    // -------------------------------------------
    //  Internal Helper Functions
    // -------------------------------------------
    
    /**
     * @notice Updates the fallback price based on a successful swap and calculates volatility
     * @param usdcAmount Amount of USDC involved in the swap
     * @param tStakeAmount Amount of TSTAKE involved in the swap
     * @param isUsdcToTStake True if the swap is USDC -> TSTAKE, false if TSTAKE -> USDC
     */
    function _updateFallbackPrice(uint256 usdcAmount, uint256 tStakeAmount, bool isUsdcToTStake) internal {
        if (usdcAmount == 0 || tStakeAmount == 0) return;
        
        // Calculate new price
        uint256 newPrice;
        if (isUsdcToTStake) {
            newPrice = tStakeAmount * PRICE_PRECISION / usdcAmount;
        } else {
            newPrice = tStakeAmount * PRICE_PRECISION / usdcAmount;
        }
        
        // Cache state variables
        uint256 windowStart = block.timestamp - slippageConfig.volatilityWindow;
        uint256 historyLength = priceTimestamps.length;
        
        // Clean up old entries
        while (historyLength > 0 && priceTimestamps[0] < windowStart) {
            for (uint256 i = 0; i < historyLength - 1; i++) {
                priceTimestamps[i] = priceTimestamps[i + 1];
                priceHistory[i] = priceHistory[i + 1];
            }
            priceTimestamps.pop();
            priceHistory.pop();
            historyLength--;
        }
        
        // Add new price
        priceHistory.push(newPrice);
        priceTimestamps.push(block.timestamp);
        historyLength++;
        
        // Calculate volatility
        uint256 newVolatilityIndex = 0;
        if (historyLength >= 2) {
            uint256 meanPrice = 0;
            for (uint256 i = 0; i < historyLength; i++) {
                meanPrice += priceHistory[i];
            }
            meanPrice = meanPrice / historyLength;
            
            uint256 sumSquaredDiff = 0;
            for (uint256 i = 0; i < historyLength; i++) {
                int256 diff = int256(priceHistory[i]) - int256(meanPrice);
                sumSquaredDiff += uint256(diff * diff);
            }
            
            newVolatilityIndex = (sumSquaredDiff / historyLength) * PRICE_PRECISION / (meanPrice * meanPrice);
        }
        
        // Batch storage updates
        volatilityIndex = newVolatilityIndex;
        fallbackTStakePerUsdc = newPrice;
        fallbackPriceTimestamp = block.timestamp;
        
        emit FallbackPriceUpdated(newPrice, block.timestamp);
        emit VolatilityUpdated(newVolatilityIndex);
    }
    
    /**
     * @notice Apply dynamic slippage to an estimated amount
     * @param amount Original amount
     * @param slippagePercentage Base slippage percentage to adjust
     * @return Amount after slippage
     */
    function _applySlippage(uint256 amount, uint256 slippagePercentage) internal returns (uint256) {
        if (amount == 0) return 0;
        
        // Adjust slippage based on volatility
        uint256 adjustedSlippage = slippagePercentage;
        if (volatilityIndex > 0) {
            uint256 volatilityFactor = volatilityIndex / PRICE_PRECISION;
            uint256 slippageIncrease = (slippageConfig.maxSlippage - slippageConfig.baseSlippage) * volatilityFactor;
            adjustedSlippage = slippageConfig.baseSlippage + slippageIncrease;
            if (adjustedSlippage > slippageConfig.maxSlippage) {
                adjustedSlippage = slippageConfig.maxSlippage;
            }
            if (adjustedSlippage < slippageConfig.minSlippage) {
                adjustedSlippage = slippageConfig.minSlippage;
            }
        }
        
        uint256 slippageAmount = amount * adjustedSlippage / 100;
        uint256 finalAmount = amount - slippageAmount;
        
        emit SlippageApplied(amount, slippageAmount, finalAmount, adjustedSlippage);
        return finalAmount;
    }
    
    /**
     * @notice Apply slippage to fallback estimate
     * @param usdcAmount USDC amount to estimate for
     * @param slippagePercentage Slippage percentage to apply
     * @return Estimated TSTAKE amount after slippage
     */
    function _applySlippageToFallbackEstimate(uint256 usdcAmount, uint256 slippagePercentage) 
        internal 
        returns (uint256) 
    {
        uint256 expectedTStake = usdcAmount * fallbackTStakePerUsdc / PRICE_PRECISION;
        return _applySlippage(expectedTStake, slippagePercentage);
    }
    
    /**
     * @notice Safely transfer tokens with verification
     * @param token Token address
     * @param to Recipient address
     * @param amount Amount to transfer
     */
    function _safeTransfer(address token, address to, uint256 amount) internal {
        if (amount == 0 || to == address(0)) return;
        
        // Check balance
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < amount) revert InsufficientBalance();
        
        // Perform transfer
        bool success = IERC20(token).transfer(to, amount);
        if (!success) revert TransferFailed();
    }
    
    /**
     * @notice Safely approve tokens with verification
     * @param token Token address
     * @param spender Spender address
     * @param amount Amount to approve
     */
    function _safeApprove(address token, address spender, uint256 amount) internal {
        if (amount == 0 || spender == address(0)) return;
        
        // First reset approval to 0 to handle non-standard ERC20 implementations
        IERC20(token).approve(spender, 0);
        
        // Perform approval
        bool success = IERC20(token).approve(spender, amount);
        if (!success) revert TransferFailed();
    }
    
    // -------------------------------------------
    //  View Functions for External Queries
    // -------------------------------------------
    
    /**
     * @notice Get the current fee structure
     * @return Current fee structure
     */
    function getFeeStructure() external view returns (FeeStructure memory) {
        return currentFeeStructure;
    }
    
    /**
     * @notice Calculate fee distribution for a given amount
     * @param amount Amount to calculate distribution for
     * @return buybackAmount Buyback amount
     * @return liquidityAmount Liquidity amount
     * @return treasuryAmount Treasury amount
     * @return burnAmount Burn amount
     */
    function calculateFeeDistribution(uint256 amount) 
        external 
        view 
        returns (
            uint256 buybackAmount, 
            uint256 liquidityAmount, 
            uint256 treasuryAmount, 
            uint256 burnAmount
        ) 
    {
        buybackAmount = amount * currentFeeStructure.buybackPercentage / 100;
        liquidityAmount = amount * currentFeeStructure.liquidityPairingPercentage / 100;
        treasuryAmount = amount * currentFeeStructure.treasuryPercentage / 100;
        burnAmount = amount * currentFeeStructure.burnPercentage / 100;
        
        return (buybackAmount, liquidityAmount, treasuryAmount, burnAmount);
    }
    
    /**
     * @notice Get the fallback price information
     * @return price TSTAKE per USDC (scaled by PRICE_PRECISION)
     * @return timestamp Last update timestamp
     * @return age Age of the fallback price in seconds
     */
    function getFallbackPriceInfo() 
        external 
        view 
        returns (
            uint256 price, 
            uint256 timestamp, 
            uint256 age
        ) 
    {
        return (
            fallbackTStakePerUsdc, 
            fallbackPriceTimestamp, 
            block.timestamp - fallbackPriceTimestamp
        );
    }
    
    /**
     * @notice Get quoter health statistics
     * @return failures Number of quoter failures
     * @return lastSuccess Timestamp of last successful quote
     * @return healthy Whether the quoter is considered healthy (succeeded recently)
     */
    function getQuoterHealthStats() 
        external 
        view 
        returns (
            uint256 failures, 
            uint256 lastSuccess, 
            bool healthy
        ) 
    {
        // Simplified logic using constant for threshold
        bool isHealthy = lastSuccessfulQuoteTimestamp > 0 && 
                         (block.timestamp - lastSuccessfulQuoteTimestamp) < QUOTER_HEALTH_THRESHOLD;
        
        return (
            quoterFailureCount,
            lastSuccessfulQuoteTimestamp,
            isHealthy
        );
    }
    
    /**
     * @notice Calculate expected TSTAKE output for a given USDC input based on fallback price
     * @param usdcAmount Amount of USDC input
     * @return Expected TSTAKE amount (without slippage)
     * @dev This is a view function that doesn't interact with the quoter for gas efficiency
     */
    function calculateExpectedOutputFromFallback(uint256 usdcAmount) 
        external 
        view 
        returns (uint256) 
    {
        if (usdcAmount == 0) return 0;
        
        // Calculate expected amount using fallback price with PRICE_PRECISION
        return usdcAmount * fallbackTStakePerUsdc / PRICE_PRECISION;
    }
    
    /**
     * @notice Check if a role is granted to an account
     * @param role Role to check
     * @param account Account to check
     * @return Whether the role is granted
     */
    function hasRoleExternal(bytes32 role, address account) external view returns (bool) {
        return hasRole(role, account);
    }
    
    /**
     * @notice Get project submission fee
     * @return Current project submission fee in USDC
     */
    function getProjectSubmissionFee() external view returns (uint256) {
        return currentFeeStructure.projectSubmissionFee;
    }
    
    /**
     * @notice Get impact reporting fee
     * @return Current impact reporting fee in USDC
     */
    function getImpactReportingFee() external view returns (uint256) {
        return currentFeeStructure.impactReportingFee;
    }

    function getSlippageConfig() external view returns (SlippageConfig memory) {
        return slippageConfig;
    }

    function getVolatilityInfo() external view returns (uint256 volatility, uint256 historyLength) {
        return (volatilityIndex, priceHistory.length);
    }
}                    