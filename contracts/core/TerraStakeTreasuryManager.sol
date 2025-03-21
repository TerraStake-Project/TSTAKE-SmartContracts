// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
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
    //  Structs
    // -------------------------------------------
    
    struct FeeStructure {
        uint256 projectSubmissionFee; // Fee for project submission in USDC
        uint256 impactReportingFee;   // Fee for impact reporting in USDC
        uint256 buybackPercentage;    // Percentage for buybacks
        uint256 liquidityPairingPercentage; // Percentage for liquidity pairing
        uint256 burnPercentage;       // Percentage for burning tokens
        uint256 treasuryPercentage;   // Percentage for treasury
    }

    struct SlippageConfig {
        uint256 baseSlippage; // Base slippage percentage (e.g., 5% = 5)
        uint256 maxSlippage;  // Maximum slippage percentage (e.g., 20% = 20)
        uint256 minSlippage;  // Minimum slippage percentage (e.g., 1% = 1)
        uint256 volatilityWindow; // Time window for volatility calculation (e.g., 1 day)
    }

    // -------------------------------------------
    //  Constants
    // -------------------------------------------
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    
    uint24 public constant POOL_FEE = 3000;
    uint256 public constant DEFAULT_SLIPPAGE = 5;
    uint256 public constant MINIMUM_QUOTE_AMOUNT = 1;
    uint256 public constant MAX_PRICE_IMPACT_FACTOR = 100;
    uint256 public constant PRICE_PRECISION = 1e18;
    uint256 public constant QUOTER_HEALTH_THRESHOLD = 1 days;
    
    // -------------------------------------------
    //  State Variables
    // -------------------------------------------
    
    ITerraStakeLiquidityGuard public liquidityGuard;
    ISwapRouter public uniswapRouter;
    IQuoter public uniswapQuoter;
    IQuoter public secondaryQuoter;
    AggregatorV3Interface public chainlinkPriceFeed;
    IERC20 public tStakeToken;
    IERC20 public usdcToken;
    ITerraStakeTreasury public treasury;
    
    FeeStructure public currentFeeStructure;
    uint256 public lastFeeUpdateTime;
    uint256 public feeUpdateCooldown;
    
    address public treasuryWallet;
    
    bool public liquidityPairingEnabled;
    
    uint256 public fallbackTStakePerUsdc;
    uint256 public fallbackPriceTimestamp;
    
    uint256 public quoterFailureCount;
    uint256 public lastSuccessfulQuoteTimestamp;
    
    SlippageConfig public slippageConfig;
    uint256[] public priceHistory;
    uint256[] public priceTimestamps;
    uint256 public volatilityIndex;
    
    // -------------------------------------------
    //  Errors
    // -------------------------------------------
    
    error InvalidAmount();
    error InvalidParameters();
    error InsufficientBalance();
    error Unauthorized();
    error SlippageTooHigh();
    error TransferFailed();
    
    // -------------------------------------------
    //  Events
    // -------------------------------------------
    
    event FeePercentageUpdated(string feeType, uint256 newValue);
    event BuybackExecuted(uint256 usdcAmount, uint256 tStakeAmount, uint256 slippageApplied, address quoterUsed);
    event LiquidityAdded(uint256 tStakeAmount, uint256 usdcAmount, address liquidityGuard);
    event TokensBurned(uint256 amount);
    event TreasuryTransfer(address token, address recipient, uint256 amount);
    event TreasuryWalletUpdated(address newTreasuryWallet);
    event TreasuryContractUpdated(address newTreasury);
    event RevenueForwardedToTreasury(address token, uint256 amount, string source);
    event TreasuryAllocationCreated(address token, uint256 amount, uint256 releaseTime);
    event LiquidityPairingToggled(bool enabled);
    event EmergencyTokenRecovery(address token, uint256 amount, address recipient);
    event TStakeReceived(address sender, uint256 amount);
    event QuoterUpdated(address newQuoter);
    event SecondaryQuoterUpdated(address newSecondaryQuoter);
    event ChainlinkPriceFeedUpdated(address newPriceFeed);
    event FallbackPriceUpdated(uint256 price, uint256 timestamp);
    event QuoterFailure(string reason, uint256 amount, uint256 timestamp, address quoter);
    event SlippageApplied(uint256 originalAmount, uint256 slippageAmount, uint256 finalAmount, uint256 adjustedSlippagePercentage);
    event FeeTransferred(string category, uint256 amount);
    event UsdcWithdrawn(address indexed recipient, uint256 tStakeAmount, uint256 usdcAmount, uint256 slippageApplied, address quoterUsed);
    event VolatilityUpdated(uint256 volatilityIndex);
    event SlippageConfigUpdated(uint256 baseSlippage, uint256 maxSlippage, uint256 minSlippage, uint256 volatilityWindow);
    event FeeProcessed(uint256 totalAmount, uint8 feeType, uint256 buybackAmount, uint256 liquidityAmount, uint256 treasuryAmount);
    event LiquiditySkippedDueToBalance(uint256 liquidityAmount, uint256 tStakeRequired, uint256 tStakeAvailable);
    
    // -------------------------------------------
    //  Initializer & Upgrade Control
    // -------------------------------------------
    
    constructor() {
        _disableInitializers();
    }
    
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
        
        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        _grantRole(UPGRADER_ROLE, _initialAdmin);
        _grantRole(GOVERNANCE_ROLE, _initialAdmin);
        _grantRole(GUARDIAN_ROLE, _initialAdmin);
        
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);
        tStakeToken = IERC20(_tStakeToken);
        usdcToken = IERC20(_usdcToken);
        uniswapRouter = ISwapRouter(_uniswapRouter);
        uniswapQuoter = IQuoter(_uniswapQuoter);
        secondaryQuoter = IQuoter(_secondaryQuoter);
        chainlinkPriceFeed = AggregatorV3Interface(_chainlinkPriceFeed);
        treasuryWallet = _treasuryWallet;
        treasury = ITerraStakeTreasury(_treasury);
        
        feeUpdateCooldown = 30 days;
        
        currentFeeStructure = FeeStructure({
            projectSubmissionFee: 500 * 10**6,
            impactReportingFee: 100 * 10**6,
            buybackPercentage: 30,
            liquidityPairingPercentage: 30,
            burnPercentage: 20,
            treasuryPercentage: 20
        });
        
        liquidityPairingEnabled = true;
        
        fallbackTStakePerUsdc = 1e17;
        fallbackPriceTimestamp = block.timestamp;
        
        slippageConfig = SlippageConfig({
            baseSlippage: DEFAULT_SLIPPAGE,
            maxSlippage: 20,
            minSlippage: 1,
            volatilityWindow: 1 days
        });
    }
    
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
    
    function performBuyback(uint256 usdcAmount, uint256 minTStakeAmount) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
        nonReentrant 
        returns (uint256) 
    {
        if (usdcAmount == 0) revert InvalidAmount();
        if (minTStakeAmount == 0) revert InvalidAmount();
        
        uint256 usdcBalance = usdcToken.balanceOf(address(this));
        if (usdcBalance < usdcAmount) revert InsufficientBalance();
        
        _safeApprove(address(usdcToken), address(uniswapRouter), usdcAmount);
        
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(usdcToken),
            tokenOut: address(tStakeToken),
            fee: POOL_FEE,
            recipient: address(this),
            deadline: block.timestamp + 15 minutes,
            amountIn: usdcAmount,
            amountOutMinimum: minTStakeAmount,
            sqrtPriceLimitX96: 0
        });
        
        address quoterUsed = lastSuccessfulQuoteTimestamp == block.timestamp 
            ? address(uniswapQuoter) 
            : address(0);
        uint256 amountOut = uniswapRouter.exactInputSingle(params);
        
        if (amountOut < minTStakeAmount) revert SlippageTooHigh();
        
        _updateFallbackPrice(usdcAmount, amountOut, true);
        
        uint256 slippageApplied = amountOut > minTStakeAmount ? 0 : (minTStakeAmount - amountOut);
        emit BuybackExecuted(usdcAmount, amountOut, slippageApplied, quoterUsed);
        return amountOut;
    }
    
    function addLiquidity(uint256 tStakeAmount, uint256 usdcAmount) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
        nonReentrant 
    {
        if (!liquidityPairingEnabled) revert Unauthorized();
        if (tStakeAmount == 0 || usdcAmount == 0) revert InvalidAmount();
        
        uint256 tStakeBalance = tStakeToken.balanceOf(address(this));
        uint256 usdcBalance = usdcToken.balanceOf(address(this));
        
        if (tStakeBalance < tStakeAmount) revert InsufficientBalance();
        if (usdcBalance < usdcAmount) revert InsufficientBalance();
        
        _safeTransfer(address(tStakeToken), address(liquidityGuard), tStakeAmount);
        _safeTransfer(address(usdcToken), address(liquidityGuard), usdcAmount);
        
        liquidityGuard.addLiquidity(tStakeAmount, usdcAmount);
        
        emit LiquidityAdded(tStakeAmount, usdcAmount, address(liquidityGuard));
    }
    
    function burnTokens(uint256 amount) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        if (amount == 0) revert InvalidAmount();
        
        uint256 tStakeBalance = tStakeToken.balanceOf(address(this));
        if (tStakeBalance < amount) revert InsufficientBalance();
        
        (bool success, ) = address(tStakeToken).call(
            abi.encodeWithSignature("burn(uint256)", amount)
        );
        
        if (!success) {
            _safeTransfer(address(tStakeToken), address(0xdead), amount);
        }
        
        emit TokensBurned(amount);
    }
    
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
    
    function updateTreasuryWallet(address newTreasuryWallet) external onlyRole(GOVERNANCE_ROLE) {
        if (newTreasuryWallet == address(0)) revert InvalidParameters();
        
        treasuryWallet = newTreasuryWallet;
        
        emit TreasuryWalletUpdated(newTreasuryWallet);
    }
    
    function updateTreasury(address _newTreasury) external onlyRole(GOVERNANCE_ROLE) {
        if (_newTreasury == address(0)) revert InvalidParameters();
        treasury = ITerraStakeTreasury(_newTreasury);
        emit TreasuryContractUpdated(_newTreasury);
    }
    
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
    
    function processFeesWithTreasuryAllocation(
        uint256 amount, 
        uint8 feeType, 
        string calldata treasuryPurpose
    ) external nonReentrant {
        if (!hasRole(GOVERNANCE_ROLE, msg.sender)) revert Unauthorized();
        
        processFees(amount, feeType);
        
        uint256 treasuryAmount = amount * currentFeeStructure.treasuryPercentage / 100;
        
        if (treasuryAmount > 0) {
            _safeApprove(address(usdcToken), address(treasury), treasuryAmount);
            
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
    
    function toggleLiquidityPairing(bool enabled) external onlyRole(GOVERNANCE_ROLE) {
        liquidityPairingEnabled = enabled;
        
        emit LiquidityPairingToggled(enabled);
    }
    
    function emergencyRecoverTokens(
        address token,
        uint256 amount,
        address recipient
    ) external onlyRole(GUARDIAN_ROLE) {
        if (recipient == address(0)) revert InvalidParameters();
        
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < amount) revert InsufficientBalance();
        
        _safeTransfer(token, recipient, amount);
        
        emit EmergencyTokenRecovery(token, amount, recipient);
    }
    
    function notifyTStakeReceived(address sender, uint256 amount) external {
        uint256 contractBalance = tStakeToken.balanceOf(address(this));
        require(contractBalance >= amount, "TSTAKE transfer verification failed");
        
        emit TStakeReceived(sender, amount);
    }
    
    receive() external payable {}
    
    function updateUniswapRouter(address _newRouter) external onlyRole(GOVERNANCE_ROLE) {
        if (_newRouter == address(0)) revert InvalidParameters();
        uniswapRouter = ISwapRouter(_newRouter);
    }
    
    function updateUniswapQuoter(address _newQuoter) external onlyRole(GOVERNANCE_ROLE) {
        if (_newQuoter == address(0)) revert InvalidParameters();
        uniswapQuoter = IQuoter(_newQuoter);
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
    
    function updateLiquidityGuard(address _newLiquidityGuard) external onlyRole(GOVERNANCE_ROLE) {
        if (_newLiquidityGuard == address(0)) revert InvalidParameters();
        liquidityGuard = ITerraStakeLiquidityGuard(_newLiquidityGuard);
    }
    
    function updateFeeUpdateCooldown(uint256 _newCooldown) external onlyRole(GOVERNANCE_ROLE) {
        if (_newCooldown < 1 days) revert InvalidParameters();
        feeUpdateCooldown = _newCooldown;
    }
    
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
    
    function processFees(uint256 amount, uint8 feeType) public nonReentrant {
        if (!hasRole(GOVERNANCE_ROLE, msg.sender)) revert Unauthorized();
        
        if (amount == 0) revert InvalidAmount();
        
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
            uint256 minTStakeAmount = estimateMinimumTStakeOutput(buybackAmount, DEFAULT_SLIPPAGE);
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
            
            _updateFallbackPrice(buybackAmount, tStakeReceived, true);
            
            uint256 slippageApplied = tStakeReceived > minTStakeAmount ? 0 : (minTStakeAmount - tStakeReceived);
            emit BuybackExecuted(buybackAmount, tStakeReceived, slippageApplied, quoterUsed);
        }
        
        if (isLiquidityEnabled && liquidityAmount > 0) {
            uint256 tStakeForLiquidity = estimateTStakeForLiquidity(liquidityAmount);
            uint256 tStakeBalance = tStakeToken.balanceOf(address(this));
            
            if (tStakeBalance >= tStakeForLiquidity) {
                _safeTransfer(address(tStakeToken), address(liquidityGuard), tStakeForLiquidity);
                _safeTransfer(address(usdcToken), address(liquidityGuard), liquidityAmount);
                liquidityGuard.addLiquidity(tStakeForLiquidity, liquidityAmount);
                emit LiquidityAdded(tStakeForLiquidity, liquidityAmount, address(liquidityGuard));
            } else {
                treasuryAmount += liquidityAmount;
                emit LiquiditySkippedDueToBalance(liquidityAmount, tStakeForLiquidity, tStakeBalance);
            }
        }
        
        if (treasuryAmount > 0) {
            _safeTransfer(address(usdcToken), cachedTreasuryWallet, treasuryAmount);
            emit TreasuryTransfer(address(usdcToken), cachedTreasuryWallet, treasuryAmount);
        }
    }

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
                0,
                lastSuccessfulQuoteTimestamp == block.timestamp ​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​
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
     * @notice Withdraw the USDC equivalent of a specified amount of TSTAKE tokens
     * @param tStakeAmount Amount of TSTAKE to convert to USDC
     * @param minUsdcAmount Minimum amount of USDC to receive (slippage protection)
     * @param recipient Address to receive the USDC
     * @return usdcReceived The amount of USDC received from the swap
     */
    function withdrawUsdcEquivalent(
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
        public 
        returns (uint256) 
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
     * @notice Estimate amount of TSTAKE needed for liquidity with given USDC amount
     * @param usdcAmount Amount of USDC
     * @return Amount of TSTAKE needed
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
     * @notice Safely transfer tokens with verification
     * @param token Token address
     * @param to Recipient address
     * @param amount Amount to transfer
     */
    function _safeTransfer(address token, address to, uint256 amount) internal {
        if (amount == 0 || to == address(0)) return;
        
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < amount) revert InsufficientBalance();
        
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
        
        IERC20(token).approve(spender, 0);
        bool success = IERC20(token).approve(spender, amount);
        if (!success) revert TransferFailed();
    }
    
    // -------------------------------------------
    //  View Functions for External Queries
    // -------------------------------------------
    
    function getFeeStructure() external view returns (FeeStructure memory) {
        return currentFeeStructure;
    }
    
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
    
    function getQuoterHealthStats() 
        external 
        view 
        returns (
            uint256 failures, 
            uint256 lastSuccess, 
            bool healthy
        ) 
    {
        bool isHealthy = lastSuccessfulQuoteTimestamp > 0 && 
                         (block.timestamp - lastSuccessfulQuoteTimestamp) < QUOTER_HEALTH_THRESHOLD;
        
        return (
            quoterFailureCount,
            lastSuccessfulQuoteTimestamp,
            isHealthy
        );
    }
    
    function calculateExpectedOutputFromFallback(uint256 usdcAmount) 
        external 
        view 
        returns (uint256) 
    {
        if (usdcAmount == 0) return 0;
        return usdcAmount * fallbackTStakePerUsdc / PRICE_PRECISION;
    }
    
    function hasRoleExternal(bytes32 role, address account) external view returns (bool) {
        return hasRole(role, account);
    }
    
    function getProjectSubmissionFee() external view returns (uint256) {
        return currentFeeStructure.projectSubmissionFee;
    }
    
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