// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

contract TerraStakeToken is ERC20, AccessControl, Pausable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Constants & Immutable State
    uint256 public constant MAX_CAP = 3_000_000_000 * 10**18;
    address public immutable liquidityPool;
    INonfungiblePositionManager public immutable positionManager;
    IERC20 public immutable usdcToken;

    // Configurable State
    uint256 public liquidityFee;       // In %, e.g. 5 => 5%
    uint256 public minLiquidityFee;    // Minimum possible fee
    uint256 public maxLiquidityFee;    // Maximum possible fee
    uint256 public tradingVolume;      // Tracks total token transfers

    // Roles
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // Events
    event LiquidityAdded(
        uint256 tokenId,
        uint256 usdcAmount,
        uint256 tStakeAmount,
        uint128 liquidity
    );
    event LiquidityFeeUpdated(uint256 newFee);
    event LiquidityRemoved(
        uint256 tokenId,
        uint256 usdcAmount,
        uint256 tStakeAmount
    );

    constructor(
        address admin,
        address _positionManager,
        address _liquidityPool,
        address _usdcToken
    ) ERC20("TerraStake Token", "TSTAKE") {
        require(admin != address(0), "Invalid admin");
        require(_positionManager != address(0), "Invalid position manager");
        require(_liquidityPool != address(0), "Invalid pool");
        require(_usdcToken != address(0), "Invalid token");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, admin);

        positionManager = INonfungiblePositionManager(_positionManager);
        liquidityPool = _liquidityPool;
        usdcToken = IERC20(_usdcToken);
        
        liquidityFee = 5;        // 5%
        minLiquidityFee = 1;     // 1%
        maxLiquidityFee = 10;    // 10%
    }

    function addLiquidity(
        uint256 usdcAmount,
        uint256 tStakeAmount,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper
    ) external onlyRole(ADMIN_ROLE) nonReentrant whenNotPaused {
        require(usdcAmount > 0 && tStakeAmount > 0, "Invalid amounts");
        require(totalSupply().add(tStakeAmount) <= MAX_CAP, "Exceeds cap");
        
        _mint(address(this), tStakeAmount);
        usdcToken.safeTransferFrom(msg.sender, address(this), usdcAmount);
        
        TransferHelper.safeApprove(address(usdcToken), address(positionManager), usdcAmount);
        TransferHelper.safeApprove(address(this), address(positionManager), tStakeAmount);

        address token0 = address(usdcToken) < address(this) ? address(usdcToken) : address(this);
        address token1 = address(usdcToken) < address(this) ? address(this) : address(usdcToken);
        
        INonfungiblePositionManager.MintParams memory params = 
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: fee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: token0 == address(usdcToken) ? usdcAmount : tStakeAmount,
                amount1Desired: token0 == address(usdcToken) ? tStakeAmount : usdcAmount,
                amount0Min: token0 == address(usdcToken) ? 
                    usdcAmount.mul(95).div(100) : tStakeAmount.mul(95).div(100),
                amount1Min: token0 == address(usdcToken) ? 
                    tStakeAmount.mul(95).div(100) : usdcAmount.mul(95).div(100),
                recipient: liquidityPool,
                deadline: block.timestamp + 600
            });
        
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = 
            positionManager.mint(params);
            
        emit LiquidityAdded(
            tokenId,
            token0 == address(usdcToken) ? amount0 : amount1,
            token0 == address(usdcToken) ? amount1 : amount0,
            liquidity
        );
        
        // Refund unused tokens
        if (amount0 < (token0 == address(usdcToken) ? usdcAmount : tStakeAmount)) {
            TransferHelper.safeTransfer(
                token0,
                msg.sender,
                (token0 == address(usdcToken) ? usdcAmount : tStakeAmount) - amount0
            );
        }
        if (amount1 < (token0 == address(usdcToken) ? tStakeAmount : usdcAmount)) {
            TransferHelper.safeTransfer(
                token1,
                msg.sender,
                (token0 == address(usdcToken) ? tStakeAmount : usdcAmount) - amount1
            );
        }
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal override whenNotPaused {
        require(sender != address(0) && recipient != address(0), "Invalid address");
        require(amount > 0, "Zero amount");

        uint256 fee = amount.mul(liquidityFee).div(100);
        uint256 transferAmount = amount.sub(fee);

        super._transfer(sender, recipient, transferAmount);
        super._transfer(sender, liquidityPool, fee);
        tradingVolume = tradingVolume.add(amount);
    }

    function setLiquidityFee(uint256 newFee) external onlyRole(ADMIN_ROLE) {
        require(newFee >= minLiquidityFee && newFee <= maxLiquidityFee, "Invalid fee range");
        liquidityFee = newFee;
        emit LiquidityFeeUpdated(newFee);
    }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        require(totalSupply().add(amount) <= MAX_CAP, "Exceeds max supply");
        _mint(to, amount);
    }

    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    function safeIncreaseAllowance(address spender, uint256 addedValue) external {
        require(spender != address(0), "Invalid spender");
        _approve(msg.sender, spender, allowance(msg.sender, spender).add(addedValue));
    }
}
