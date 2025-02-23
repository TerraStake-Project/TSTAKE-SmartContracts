// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "../interfaces/ITerraStakeITO.sol";

/**
 * @title TerraStakeITO
 * @notice Official TerraStake Initial Token Offering (ITO) contract.
 * @dev Handles token sales, dynamic price increase, and automatic liquidity injection.
 * 
 * 🚀 Best Balance for the ITO
 * ✅ 30-Day Duration → Prevents slow movement and last-minute buy rush.
 * ✅ Target Ending Price: $0.20 → Ensures sustainable growth.
 * ✅ Midway Price: $0.15 → Encourages early participation.
 * ✅ Auto-Liquidity Injection → Every sale strengthens the Uniswap v3 pool.
 * ✅ Secure & Governed → Only trusted addresses control operations.
 */
contract TerraStakeITO is AccessControlEnumerable, ReentrancyGuard, ITerraStakeITO {
    uint24 public constant POOL_FEE = 3000;
    uint256 public constant MAX_TOKENS_FOR_ITO = 300_000_000 * 10**18; // 🔹 Adjusted to 300M TSTAKE (10% of 3B supply)
    uint256 public constant DEFAULT_MIN_PURCHASE_USDC = 1_000 * 10**6;
    uint256 public constant DEFAULT_MAX_PURCHASE_USDC = 150_000 * 10**6;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant MULTISIG_ROLE = keccak256("MULTISIG_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IERC20 public immutable tStakeToken;
    IERC20 public immutable usdcToken;
    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Pool public immutable uniswapPool;

    address public immutable treasuryMultiSig;
    address public immutable stakingRewards;
    address public immutable liquidityPool;

    uint256 public startingPrice = 0.10 * 10**18; // $0.10 per token
    uint256 public endingPrice = 0.20 * 10**18; // $0.20 per token
    uint256 public priceDuration = 30 days; // 🔹 Adjusted to 30 days
    uint256 public tokensSold;
    uint256 public accumulatedUSDC;
    uint256 public itoStartTime;
    uint256 public itoEndTime;
    uint256 public minPurchaseUSDC;
    uint256 public maxPurchaseUSDC;

    bool public purchasesPaused;

    mapping(address => uint256) public purchasedAmounts;
    mapping(address => bool) public blacklist;

    ITOState public itoState;

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

        tStakeToken = IERC20(_tStakeToken);
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
    }

    function _setupRoles(address admin) private {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(MULTISIG_ROLE, treasuryMultiSig);
        _grantRole(PAUSER_ROLE, admin);
    }

    function getCurrentPrice() public view override returns (uint256) {
        if (block.timestamp >= itoEndTime) return endingPrice;
        if (itoStartTime == 0 || itoStartTime >= itoEndTime) return startingPrice;

        uint256 elapsed = block.timestamp - itoStartTime;
        if (elapsed >= priceDuration) return endingPrice;

        uint256 priceIncrease = ((endingPrice - startingPrice) * elapsed) / priceDuration;
        return startingPrice + priceIncrease;
    }

    function buyTokens(
        uint256 usdcAmount,
        uint256 minTokensOut,
        bool usePermit,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override nonReentrant {
        require(itoState == ITOState.Active, "ITO not active");
        require(!purchasesPaused, "Purchases paused");
        require(!blacklist[msg.sender], "Address blacklisted");
        require(usdcAmount >= minPurchaseUSDC && usdcAmount <= maxPurchaseUSDC, "Invalid purchase amount");

        uint256 tokenAmount = (usdcAmount * 10**18) / getCurrentPrice();
        require(tokenAmount >= minTokensOut, "Slippage exceeded");
        require(tokensSold + tokenAmount <= MAX_TOKENS_FOR_ITO, "Exceeds ITO allocation");

        if (usePermit) {
            IERC20Permit(address(usdcToken)).permit(msg.sender, address(this), usdcAmount, deadline, v, r, s);
        }

        require(usdcToken.transferFrom(msg.sender, address(this), usdcAmount), "USDC transfer failed");

        uint256 treasuryShare = (usdcAmount * 40) / 100;
        uint256 stakingShare = (usdcAmount * 35) / 100;
        uint256 liquidityShare = usdcAmount - (treasuryShare + stakingShare);

        require(usdcToken.transfer(treasuryMultiSig, treasuryShare), "USDC transfer to Treasury failed");
        require(usdcToken.transfer(stakingRewards, stakingShare), "USDC transfer to Staking failed");

        addLiquidityToUniswap(liquidityShare, tokenAmount);

        require(tStakeToken.transfer(msg.sender, tokenAmount), "TSTAKE transfer failed");

        tokensSold += tokenAmount;
        accumulatedUSDC += usdcAmount;
        purchasedAmounts[msg.sender] += tokenAmount;

        emit TokensPurchased(msg.sender, usdcAmount, tokenAmount, block.timestamp);
    }

    function addLiquidityToUniswap(uint256 usdcAmount, uint256 tStakeAmount) internal {
        INonfungiblePositionManager(positionManager).mint(
            INonfungiblePositionManager.MintParams({
                token0: address(usdcToken),
                token1: address(tStakeToken),
                fee: POOL_FEE,
                tickLower: -887220, 
                tickUpper: 887220,
                amount0Desired: usdcAmount,
                amount1Desired: tStakeAmount,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp + 600
            })
        );
    }

    function pausePurchases() external override onlyRole(PAUSER_ROLE) {
        purchasesPaused = true;
    }

    function resumePurchases() external override onlyRole(PAUSER_ROLE) {
        purchasesPaused = false;
    }
}
