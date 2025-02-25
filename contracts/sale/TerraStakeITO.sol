// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

/// @dev Minimal interface extending IERC20 to include burning functionality.
interface IBurnableERC20 is IERC20 {
    function burn(uint256 amount) external;
}

/**
 * @title TerraStakeITO
 * @notice Official TerraStake Initial Token Offering (ITO) contract with structured vesting, liquidity management,
 *         unsold token burning, emergency controls, and transparent reporting.
 * @dev Handles token sales, dynamic pricing, liquidity injection, vesting schedules, blacklist management,
 *      emergency withdrawals, and unsold token burning.
 */
contract TerraStakeITO is AccessControlEnumerable, ReentrancyGuard {
    // ================================
    // 🔹 Constants & Roles
    // ================================
    uint24 public constant POOL_FEE = 3000;
    uint256 public constant MAX_TOKENS_FOR_ITO = 300_000_000 * 10**18;
    uint256 public constant DEFAULT_MIN_PURCHASE_USDC = 1_000 * 10**6;
    uint256 public constant DEFAULT_MAX_PURCHASE_USDC = 150_000 * 10**6;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant MULTISIG_ROLE = keccak256("MULTISIG_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ================================
    // 🔹 Contract State Variables
    // ================================
    IBurnableERC20 public immutable tStakeToken;
    IERC20 public immutable usdcToken;
    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Pool public immutable uniswapPool;

    address public immutable treasuryMultiSig;
    address public immutable stakingRewards;
    address public immutable liquidityPool;

    uint256 public startingPrice = 0.10 * 10**18;
    uint256 public endingPrice = 0.20 * 10**18;
    uint256 public priceDuration = 30 days;
    uint256 public tokensSold;
    uint256 public accumulatedUSDC;
    uint256 public itoStartTime;
    uint256 public itoEndTime;
    uint256 public minPurchaseUSDC;
    uint256 public maxPurchaseUSDC;

    bool public purchasesPaused;
    mapping(address => uint256) public purchasedAmounts;
    mapping(address => bool) public blacklist;

    enum ITOState { NotStarted, Active, Ended }
    ITOState public itoState;

    // ================================
    // 🔹 Vesting Struct & Variables
    // ================================
    enum VestingType { Treasury, Staking, Liquidity }

    struct VestingSchedule {
        uint256 totalAmount;
        uint256 initialUnlock; // percentage (e.g. 10 for 10%)
        uint256 startTime;
        uint256 duration;
        uint256 claimedAmount;
        uint256 lastClaimTime;
    }

    mapping(VestingType => VestingSchedule) public vestingSchedules;

    // ================================
    // 🔹 Events
    // ================================
    event TokensPurchased(address indexed buyer, uint256 usdcAmount, uint256 tokenAmount, uint256 timestamp);
    event LiquidityAdded(uint256 usdcAmount, uint256 tStakeAmount, uint256 timestamp);
    event ITOStateChanged(ITOState newState);
    event PriceUpdated(uint256 newPrice);
    event PurchaseLimitsUpdated(uint256 newMin, uint256 newMax);
    event BlacklistStatusUpdated(address indexed account, bool status);
    event EmergencyWithdrawal(address token, uint256 amount);
    event PurchasesPaused(bool status);
    event VestingScheduleInitialized(VestingType vestingType, uint256 totalAmount);
    event VestingClaimed(VestingType vestingType, uint256 amount, uint256 timestamp);
    event TokensBurned(uint256 amount, uint256 timestamp, uint256 newTotalSupply);

    // ================================
    // 🔹 Constructor
    // ================================
    constructor(
        address _tStakeToken,
        address _usdcToken,
        address _positionManager,
        address _uniswapPool,
        address _treasuryMultiSig,
        address _stakingRewards,
        address _liquidityPool,
        address admin
    ) {
        require(_tStakeToken != address(0) && _usdcToken != address(0), "Invalid token addresses");
        require(_positionManager != address(0) && _uniswapPool != address(0), "Invalid Uniswap addresses");
        require(_treasuryMultiSig != address(0) && _stakingRewards != address(0), "Invalid operational addresses");

        tStakeToken = IBurnableERC20(_tStakeToken);
        usdcToken = IERC20(_usdcToken);
        positionManager = INonfungiblePositionManager(_positionManager);
        uniswapPool = IUniswapV3Pool(_uniswapPool);
        treasuryMultiSig = _treasuryMultiSig;
        stakingRewards = _stakingRewards;
        liquidityPool = _liquidityPool;

        itoStartTime = block.timestamp;
        itoEndTime = block.timestamp + priceDuration;
        itoState = ITOState.NotStarted;

        minPurchaseUSDC = DEFAULT_MIN_PURCHASE_USDC;
        maxPurchaseUSDC = DEFAULT_MAX_PURCHASE_USDC;

        _setupRoles(admin);
        _initializeVesting();
    }

    function _setupRoles(address admin) private {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(MULTISIG_ROLE, treasuryMultiSig);
        _grantRole(PAUSER_ROLE, admin);
    }

    function _initializeVesting() private {
        vestingSchedules[VestingType.Treasury] = VestingSchedule(0, 10, block.timestamp, 730 days, 0, block.timestamp);
        vestingSchedules[VestingType.Staking] = VestingSchedule(0, 15, block.timestamp, 1095 days, 0, block.timestamp);
        vestingSchedules[VestingType.Liquidity] = VestingSchedule(0, 0, block.timestamp + 365 days, 730 days, 0, block.timestamp);
    }

    // ================================
    // 🔹 Administrative Controls
    // ================================
    function setITOState(ITOState newState) external onlyRole(GOVERNANCE_ROLE) {
        itoState = newState;
        emit ITOStateChanged(newState);
    }

    function togglePurchases(bool paused) external onlyRole(PAUSER_ROLE) {
        purchasesPaused = paused;
        emit PurchasesPaused(paused);
    }

    function updatePurchaseLimits(uint256 newMin, uint256 newMax) external onlyRole(GOVERNANCE_ROLE) {
        require(newMin < newMax, "Invalid limits");
        minPurchaseUSDC = newMin;
        maxPurchaseUSDC = newMax;
        emit PurchaseLimitsUpdated(newMin, newMax);
    }

    // ================================
    // 🔹 Blacklist Management
    // ================================
    function updateBlacklist(address account, bool status) external onlyRole(GOVERNANCE_ROLE) {
        blacklist[account] = status;
        emit BlacklistStatusUpdated(account, status);
    }

    // ================================
    // 🔹 Vesting Management
    // ================================
    function getVestedAmount(VestingType vestingType) public view returns (uint256) {
        VestingSchedule storage schedule = vestingSchedules[vestingType];
        if (block.timestamp < schedule.startTime) return 0;
        
        uint256 timeElapsed = block.timestamp - schedule.startTime;
        if (timeElapsed >= schedule.duration) return schedule.totalAmount;
        
        uint256 initialAmount = (schedule.totalAmount * schedule.initialUnlock) / 100;
        uint256 vestingAmount = schedule.totalAmount - initialAmount;
        uint256 vestedAmount = (vestingAmount * timeElapsed) / schedule.duration;
        
        return initialAmount + vestedAmount;
    }

    function claimVestedFunds(VestingType vestingType) external onlyRole(GOVERNANCE_ROLE) {
        VestingSchedule storage schedule = vestingSchedules[vestingType];
        uint256 vestedAmount = getVestedAmount(vestingType);
        uint256 claimableAmount = vestedAmount - schedule.claimedAmount;
        
        require(claimableAmount > 0, "No funds to claim");
        schedule.claimedAmount += claimableAmount;
        schedule.lastClaimTime = block.timestamp;
        
        if (vestingType == VestingType.Treasury) {
            usdcToken.transfer(treasuryMultiSig, claimableAmount);
        } else if (vestingType == VestingType.Staking) {
            usdcToken.transfer(stakingRewards, claimableAmount);
        }
        
        emit VestingClaimed(vestingType, claimableAmount, block.timestamp);
    }

    // ================================
    // 🔹 Price Management
    // ================================
    function getCurrentPrice() public view returns (uint256) {
        if (block.timestamp >= itoEndTime) return endingPrice;
        if (itoStartTime == 0 || itoStartTime >= itoEndTime) return startingPrice;

        uint256 elapsed = block.timestamp - itoStartTime;
        if (elapsed >= priceDuration) return endingPrice;

        uint256 priceIncrease = ((endingPrice - startingPrice) * elapsed) / priceDuration;
        return startingPrice + priceIncrease;
    }

    function updatePricingParameters(
        uint256 newStartPrice,
        uint256 newEndPrice,
        uint256 newDuration
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(itoState == ITOState.NotStarted, "ITO already started");
        startingPrice = newStartPrice;
        endingPrice = newEndPrice;
        priceDuration = newDuration;
        emit PriceUpdated(newStartPrice);
    }

    // ================================
    // 🔹 Purchase Function
    // ================================
    function buyTokens(uint256 usdcAmount, uint256 minTokensOut) external nonReentrant {
        require(itoState == ITOState.Active, "ITO not active");
        require(!purchasesPaused, "Purchases paused");
        require(!blacklist[msg.sender], "Address blacklisted");
        require(usdcAmount >= minPurchaseUSDC && usdcAmount <= maxPurchaseUSDC, "Invalid purchase amount");

        uint256 tokenAmount = (usdcAmount * 10**18) / getCurrentPrice();
        require(tokenAmount >= minTokensOut, "Slippage exceeded");
        require(tokensSold + tokenAmount <= MAX_TOKENS_FOR_ITO, "Exceeds allocation");

        require(usdcToken.transferFrom(msg.sender, address(this), usdcAmount), "USDC transfer failed");
        _distributeUSDC(usdcAmount);
        require(tStakeToken.transfer(msg.sender, tokenAmount), "Token transfer failed");

        tokensSold += tokenAmount;
        accumulatedUSDC += usdcAmount;
        purchasedAmounts[msg.sender] += tokenAmount;

        emit TokensPurchased(msg.sender, usdcAmount, tokenAmount, block.timestamp);
    }

    // ================================
    // 🔹 Distribution Function
    // ================================
    function _distributeUSDC(uint256 amount) internal {
        uint256 treasuryShare = (amount * 40) / 100;
        uint256 stakingShare = (amount * 35) / 100;
        uint256 liquidityShare = amount - (treasuryShare + stakingShare);

        vestingSchedules[VestingType.Treasury].totalAmount += treasuryShare;
        vestingSchedules[VestingType.Staking].totalAmount += stakingShare;
        vestingSchedules[VestingType.Liquidity].totalAmount += liquidityShare;

        _addLiquidity(liquidityShare);
    }

    // ================================
    // 🔹 Liquidity Injection Function
    // ================================
    function _addLiquidity(uint256 liquidityUSDCAmount) internal {
        // Approve USDC for the position manager.
        usdcToken.approve(address(positionManager), liquidityUSDCAmount);
        
        // Calculate the corresponding amount of tStake tokens based on the current price.
        uint256 tStakeAmount = (liquidityUSDCAmount * 10**18) / getCurrentPrice();
        tStakeToken.approve(address(positionManager), tStakeAmount);

        // Retrieve the current tick from the Uniswap pool.
        (, int24 currentTick, , , , ,) = uniswapPool.slot0();
        // Define a simple tick range around the current tick.
        int24 tickSpacing = 60; // Typical tick spacing for a 0.3% fee tier.
        int24 tickLower = currentTick - (10 * tickSpacing);
        int24 tickUpper = currentTick + (10 * tickSpacing);

        // Set up the mint parameters for creating a new position.
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(usdcToken),
            token1: address(tStakeToken),
            fee: POOL_FEE,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: liquidityUSDCAmount,
            amount1Desired: tStakeAmount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: liquidityPool,
            deadline: block.timestamp + 15 minutes
        });

        // Mint the liquidity position.
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = positionManager.mint(params);
        emit LiquidityAdded(amount0, amount1, block.timestamp);
    }

    // ================================
    // 🔹 Burn Unsold Tokens Function
    // ================================
    function burnUnsoldTokens() external onlyRole(GOVERNANCE_ROLE) {
        require(itoState == ITOState.Ended, "ITO must be ended");
        require(!purchasesPaused, "System paused");
        
        uint256 unsoldAmount = MAX_TOKENS_FOR_ITO - tokensSold;
        require(unsoldAmount > 0, "No tokens to burn");
        
        // Get current total supply before burn.
        uint256 currentSupply = tStakeToken.totalSupply();
        
        // Burn the unsold tokens.
        tStakeToken.burn(unsoldAmount);
        
        // Calculate new total supply.
        uint256 newSupply = currentSupply - unsoldAmount;
        
        emit TokensBurned(unsoldAmount, block.timestamp, newSupply);
    }

    // ================================
    // 🔹 Emergency Functions
    // ================================
    function emergencyWithdraw(address token) external onlyRole(MULTISIG_ROLE) {
        require(itoState == ITOState.Ended, "ITO not ended");
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).transfer(treasuryMultiSig, balance);
        emit EmergencyWithdrawal(token, balance);
    }

    // ================================
    // 🔹 View Functions
    // ================================
    function getITOStats() external view returns (
        uint256 totalSold,
        uint256 remaining,
        uint256 currentPrice,
        ITOState state
    ) {
        return (
            tokensSold,
            MAX_TOKENS_FOR_ITO - tokensSold,
            getCurrentPrice(),
            itoState
        );
    }
}
