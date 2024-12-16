// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "../interfaces/ITerraStakeITO.sol";

contract TerraStakeITO is AccessControlEnumerable, ReentrancyGuard, ITerraStakeITO {
    uint24 public constant POOL_FEE = 3000; // Uniswap Pool Fee
    uint256 public constant MIN_PURCHASE = 1_000 * 10**6; // Minimum purchase in USDC
    uint256 public constant MAX_PURCHASE = 500_000 * 10**6; // Maximum purchase in USDC
    uint256 public constant MAX_TOKENS_FOR_ITO = 10_000_000 * 10**18; // TSTAKE with 18 decimals

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UNISWAP_MANAGER_ROLE = keccak256("UNISWAP_MANAGER_ROLE");

    IERC20 public immutable tStakeToken;
    IERC20 public immutable usdcToken;
    INonfungiblePositionManager public immutable positionManager;

    uint256 public startingPrice;
    uint256 public endingPrice;
    uint256 public priceDuration;
    uint256 public liquidityPercentage;
    uint256 public tokensSold;
    uint256 public accumulatedUSDC;
    uint256 public itoStartTime;
    uint256 public itoEndTime;

    mapping(address => uint256) public purchasedAmounts;
    mapping(address => bool) public blacklist;

    ITOState public itoState;

    constructor(
        address _tStakeToken,
        address _usdcToken,
        address _positionManager,
        uint256 _startingPrice,
        uint256 _endingPrice,
        uint256 _priceDuration,
        uint256 _itoDuration,
        uint256 _liquidityPercentage
    ) {
        require(_tStakeToken != address(0), "Invalid TSTAKE address");
        require(_usdcToken != address(0), "Invalid USDC address");
        require(_positionManager != address(0), "Invalid position manager");

        tStakeToken = IERC20(_tStakeToken);
        usdcToken = IERC20(_usdcToken);
        positionManager = INonfungiblePositionManager(_positionManager);
        startingPrice = _startingPrice;
        endingPrice = _endingPrice;
        priceDuration = _priceDuration;
        itoStartTime = block.timestamp;
        itoEndTime = block.timestamp + _itoDuration;
        liquidityPercentage = _liquidityPercentage;
        itoState = ITOState.NotStarted;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(UNISWAP_MANAGER_ROLE, msg.sender);
    }

    // Override revokeRole from AccessControl and IAccessControl
    function revokeRole(bytes32 role, address account)
        public
        override(IAccessControl, AccessControl)
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        super.revokeRole(role, account);
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

    function finalizeITO() external override onlyRole(GOVERNANCE_ROLE) {
        require(itoState == ITOState.Active, "ITO not active");
        itoState = ITOState.Finalized;

        uint256 liquidityTokens = (tokensSold * liquidityPercentage) / 100;
        require(tStakeToken.transferFrom(msg.sender, address(this), liquidityTokens), "Token transfer failed");

        emit ITOStateChanged(ITOState.Finalized, block.timestamp);
    }

    function buyTokens(uint256 amount) external override nonReentrant {
        require(itoState == ITOState.Active, "ITO not active");
        require(amount >= MIN_PURCHASE, "Below minimum purchase");
        require(purchasedAmounts[msg.sender] + amount <= MAX_PURCHASE, "Exceeds max purchase");
        require(tokensSold + amount <= MAX_TOKENS_FOR_ITO, "Exceeds token cap");
        require(!blacklist[msg.sender], "Address blacklisted");

        uint256 price = getCurrentPrice();
        uint256 cost = (amount * price) / 10**18;

        require(usdcToken.transferFrom(msg.sender, address(this), cost), "USDC transfer failed");
        require(tStakeToken.transfer(msg.sender, amount), "TSTAKE transfer failed");

        tokensSold += amount;
        purchasedAmounts[msg.sender] += amount;
        accumulatedUSDC += cost;

        emit TokensPurchased(msg.sender, amount, cost, block.timestamp);
    }

    function buyTokensAfterITO(uint256 usdcAmount) external override nonReentrant {
        require(itoState == ITOState.Finalized, "ITO not finalized");
        require(usdcAmount >= MIN_PURCHASE, "Below minimum purchase");
        require(!blacklist[msg.sender], "Address blacklisted");

        uint256 poolPrice = getPoolPrice();
        uint256 tokenAmount = (usdcAmount * 10**18) / poolPrice;

        require(tokenAmount <= MAX_PURCHASE, "Exceeds max purchase");
        require(usdcToken.transferFrom(msg.sender, address(this), usdcAmount), "USDC transfer failed");
        require(tStakeToken.transfer(msg.sender, tokenAmount), "TSTAKE transfer failed");

        emit TokensPurchasedAfterITO(msg.sender, tokenAmount, usdcAmount, block.timestamp);
    }

    function getPoolPrice() public view override returns (uint256) {
        require(itoState == ITOState.Finalized, "ITO not finalized");
        return endingPrice;
    }

    function getCurrentPrice() public view override returns (uint256) {
        if (block.timestamp >= itoEndTime) return endingPrice;

        uint256 elapsed = block.timestamp - itoStartTime;
        uint256 priceDifference = startingPrice > endingPrice
            ? startingPrice - endingPrice
            : endingPrice - startingPrice;
        return startingPrice + (elapsed * priceDifference) / priceDuration;
    }

    function addLiquidity(
        uint256 amountTSTAKE,
        uint256 amountUSDC,
        int24 lowerTick,
        int24 upperTick
    ) external override onlyRole(UNISWAP_MANAGER_ROLE) returns (uint256 tokenId) {
        require(itoState == ITOState.Finalized, "ITO not finalized");

        tStakeToken.approve(address(positionManager), amountTSTAKE);
        usdcToken.approve(address(positionManager), amountUSDC);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(tStakeToken),
            token1: address(usdcToken),
            fee: POOL_FEE,
            tickLower: lowerTick,
            tickUpper: upperTick,
            amount0Desired: amountTSTAKE,
            amount1Desired: amountUSDC,
            amount0Min: 0,
            amount1Min: 0,
            recipient: msg.sender,
            deadline: block.timestamp
        });

        (, tokenId, , ) = positionManager.mint(params);
        emit LiquidityAdded(amountTSTAKE, amountUSDC, block.timestamp);
    }

    function withdrawUSDC(address recipient, uint256 amount) external override onlyRole(GOVERNANCE_ROLE) {
        require(recipient != address(0), "Invalid recipient address");
        require(usdcToken.transfer(recipient, amount), "USDC transfer failed");
        emit USDCWithdrawn(recipient, amount, block.timestamp);
    }
}

