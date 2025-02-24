// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "../interfaces/ITerraStakeITO.sol";

contract TerraStakeITO is AccessControlEnumerable, ReentrancyGuard, ITerraStakeITO {
    uint24 public constant POOL_FEE = 3000;
    uint256 public constant MAX_TOKENS_FOR_ITO = 240_000_000 * 10**18;
    uint256 public constant DEFAULT_MIN_PURCHASE_USDC = 1_500 * 10**6;
    uint256 public constant DEFAULT_MAX_PURCHASE_USDC = 100_000 * 10**6;
    uint256 public constant VESTING_CLIFF = 6 weeks;
    uint256 public constant VESTING_DURATION = 24 weeks;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant MULTISIG_ROLE = keccak256("MULTISIG_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UNISWAP_MANAGER_ROLE = keccak256("UNISWAP_MANAGER_ROLE");

    IERC20 public immutable tStakeToken;
    IERC20 public immutable usdcToken;
    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Pool public immutable uniswapPool;
    
    address public immutable treasuryMultiSig;
    address public immutable stakingRewards;
    address public immutable liquidityPool;

    uint256 public startingPrice;
    uint256 public endingPrice;
    uint256 public priceDuration;
    uint256 public liquidityPercentage;
    uint256 public tokensSold;
    uint256 public accumulatedUSDC;
    uint256 public itoStartTime;
    uint256 public itoEndTime;
    uint256 public minPurchaseUSDC;
    uint256 public maxPurchaseUSDC;
    uint256 public vestedTreasuryTokens;
    uint256 public vestingStart;
    
    bool public purchasesPaused;
    
    mapping(address => uint256) public purchasedAmounts;
    mapping(address => bool) public blacklist;
    
    ITOState public itoState;

    constructor(
        address _tStakeToken,
        address _usdcToken,
        address _positionManager,
        address _uniswapPool,
        uint256 _startingPrice,
        uint256 _endingPrice,
        uint256 _priceDuration,
        uint256 _itoDuration,
        uint256 _liquidityPercentage,
        address _treasuryMultiSig,
        address _stakingRewards,
        address _liquidityPool,
        address admin
    ) {
        require(_tStakeToken != address(0) && _usdcToken != address(0), "Invalid token addresses");
        require(_positionManager != address(0) && _uniswapPool != address(0), "Invalid Uniswap addresses");
        require(_treasuryMultiSig != address(0) && _stakingRewards != address(0), "Invalid operational addresses");
        require(_liquidityPercentage <= 100, "Invalid liquidity percentage");

        tStakeToken = IERC20(_tStakeToken);
        usdcToken = IERC20(_usdcToken);
        positionManager = INonfungiblePositionManager(_positionManager);
        uniswapPool = IUniswapV3Pool(_uniswapPool);
        treasuryMultiSig = _treasuryMultiSig;
        stakingRewards = _stakingRewards;
        liquidityPool = _liquidityPool;

        startingPrice = _startingPrice;
        endingPrice = _endingPrice;
        priceDuration = _priceDuration;
        itoStartTime = block.timestamp;
        itoEndTime = block.timestamp + _itoDuration;
        liquidityPercentage = _liquidityPercentage;
        
        itoState = ITOState.NotStarted;
        minPurchaseUSDC = DEFAULT_MIN_PURCHASE_USDC;
        maxPurchaseUSDC = DEFAULT_MAX_PURCHASE_USDC;

        _setupRoles(admin);
    }

    function _setupRoles(address admin) private {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(MULTISIG_ROLE, treasuryMultiSig);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UNISWAP_MANAGER_ROLE, admin);
    }

    function getCurrentPrice() public view override returns (uint256) {
        if (block.timestamp >= itoEndTime) return endingPrice;
        uint256 elapsed = block.timestamp - itoStartTime;
        uint256 priceIncrease = (endingPrice - startingPrice) * elapsed / priceDuration;
        return startingPrice + priceIncrease;
    }

    function getPoolPrice() public view override returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = uniswapPool.slot0();
        return uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e6 / (1 << 192);
    }

    function getRemainingVestedTreasuryTokens() external view override returns (uint256) {
        return vestedTreasuryTokens;
    }

    function startITO() external override onlyRole(GOVERNANCE_ROLE) {
        require(itoState == ITOState.NotStarted, "ITO already started");
        itoState = ITOState.Active;
        emit ITOStateChanged(ITOState.Active, block.timestamp);
    }

    function pauseITO() external override onlyRole(PAUSER_ROLE) {
        require(itoState == ITOState.Active, "ITO not active");
        itoState = ITOState.Paused;
        emit ITOStateChanged(ITOState.Paused, block.timestamp);
    }

    function finalizeITO() external override onlyRole(MULTISIG_ROLE) {
        require(itoState == ITOState.Active, "ITO not active");
        itoState = ITOState.Finalized;

        uint256 unsoldTokens = MAX_TOKENS_FOR_ITO - tokensSold;
        _distributeUnsoldTokens(unsoldTokens);
        
        emit ITOStateChanged(ITOState.Finalized, block.timestamp);
    }

    function _distributeUnsoldTokens(uint256 unsoldTokens) private {
        uint256 burnAmount = (unsoldTokens * 10) / 100;
        uint256 treasuryAmount = (unsoldTokens * 50) / 100;
        uint256 stakingAmount = (unsoldTokens * 30) / 100;
        uint256 liquidityAmount = (unsoldTokens * 20) / 100;

        if (burnAmount > 0) {
            require(tStakeToken.transfer(address(0), burnAmount), "Burn failed");
            emit UnsoldTokensBurned(burnAmount, block.timestamp);
        }

        if (treasuryAmount > 0) {
            vestedTreasuryTokens = treasuryAmount;
            vestingStart = block.timestamp;
        }

        if (stakingAmount > 0) {
            require(tStakeToken.transfer(stakingRewards, stakingAmount), "Staking transfer failed");
        }

        if (liquidityAmount > 0) {
            require(tStakeToken.transfer(liquidityPool, liquidityAmount), "Liquidity transfer failed");
        }

        emit UnsoldTokensAllocated(treasuryAmount, stakingAmount, liquidityAmount, block.timestamp);
    }

    function claimVestedTokens() external override onlyRole(MULTISIG_ROLE) {
        require(vestingStart > 0, "No vested tokens");
        require(block.timestamp >= vestingStart + VESTING_CLIFF, "Cliff period active");

        uint256 claimable = _calculateClaimableAmount();
        require(claimable > 0, "Nothing to claim");

        vestedTreasuryTokens -= claimable;
        require(tStakeToken.transfer(treasuryMultiSig, claimable), "Transfer failed");
        
        emit TreasuryVestedTokensClaimed(claimable, vestedTreasuryTokens, block.timestamp);
    }

    function _calculateClaimableAmount() private view returns (uint256) {
        uint256 elapsed = block.timestamp - vestingStart;
        return (vestedTreasuryTokens * elapsed) / VESTING_DURATION;
    }

    function updateITOPrices(
        uint256 newStartingPrice,
        uint256 newEndingPrice,
        uint256 newPriceDuration
    ) external override onlyRole(GOVERNANCE_ROLE) {
        require(itoState != ITOState.Finalized, "ITO already finalized");
        startingPrice = newStartingPrice;
        endingPrice = newEndingPrice;
        priceDuration = newPriceDuration;
        
        emit DynamicITOParametersUpdated(newStartingPrice, newEndingPrice, newPriceDuration);
    }

    function buyTokens(uint256 usdcAmount, uint256 minTokensOut) external override nonReentrant {
        require(itoState == ITOState.Active, "ITO not active");
        require(!purchasesPaused, "Purchases paused");
        require(!blacklist[msg.sender], "Address blacklisted");
        require(usdcAmount >= minPurchaseUSDC && usdcAmount <= maxPurchaseUSDC, "Invalid purchase amount");

        uint256 tokenAmount = (usdcAmount * 10**18) / getCurrentPrice();
        require(tokenAmount >= minTokensOut, "Slippage exceeded");
        require(tokensSold + tokenAmount <= MAX_TOKENS_FOR_ITO, "Exceeds ITO allocation");

        require(usdcToken.transferFrom(msg.sender, address(this), usdcAmount), "USDC transfer failed");
        require(tStakeToken.transfer(msg.sender, tokenAmount), "TSTAKE transfer failed");

        tokensSold += tokenAmount;
        accumulatedUSDC += usdcAmount;
        purchasedAmounts[msg.sender] += tokenAmount;

        emit TokensPurchased(msg.sender, usdcAmount, tokenAmount, block.timestamp);
    }

    function buyTokensAfterITO(uint256 usdcAmount) external override nonReentrant {
        require(itoState == ITOState.Finalized, "ITO not finalized");
        require(!blacklist[msg.sender], "Address blacklisted");
        
        uint256 poolPrice = getPoolPrice();
        uint256 tokenAmount = (usdcAmount * 10**18) / poolPrice;
        
        require(usdcToken.transferFrom(msg.sender, address(this), usdcAmount), "USDC transfer failed");
        require(tStakeToken.transfer(msg.sender, tokenAmount), "TSTAKE transfer failed");
        
        emit TokensPurchasedAfterITO(msg.sender, usdcAmount, tokenAmount, block.timestamp);
    }

    function addLiquidity(
        uint256 amountTSTAKE,
        uint256 amountUSDC,
        int24 lowerTick,
        int24 upperTick,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external override onlyRole(UNISWAP_MANAGER_ROLE) returns (uint256 tokenId) {
        require(tStakeToken.approve(address(positionManager), amountTSTAKE), "TSTAKE approval failed");
        require(usdcToken.approve(address(positionManager), amountUSDC), "USDC approval failed");

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(tStakeToken),
            token1: address(usdcToken),
            fee: POOL_FEE,
            tickLower: lowerTick,
            tickUpper: upperTick,
            amount0Desired: amountTSTAKE,
            amount1Desired: amountUSDC,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            recipient: recipient,
            deadline: block.timestamp
        });

        (tokenId,,,) = positionManager.mint(params);
        emit LiquidityAdded(amountTSTAKE, amountUSDC, block.timestamp);
        return tokenId;
    }

    function withdrawUSDC(address recipient, uint256 amount) external override onlyRole(MULTISIG_ROLE) {
        require(recipient != address(0), "Invalid recipient");
        require(amount <= usdcToken.balanceOf(address(this)), "Insufficient balance");
        
        require(usdcToken.transfer(recipient, amount), "USDC transfer failed");
        emit USDCWithdrawn(recipient, amount, block.timestamp);
    }

    function pausePurchases() external override onlyRole(PAUSER_ROLE) {
        purchasesPaused = true;
    }

    function resumePurchases() external override onlyRole(PAUSER_ROLE) {
        purchasesPaused = false;
    }
}