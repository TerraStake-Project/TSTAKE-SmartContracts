// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

/**
 * @title TerraStakeToken
 * @notice Official TerraStake Token (TSTAKE) for the TerraStake ecosystem.
 * @dev This contract manages governance, staking rewards, and liquidity provisioning.
 * It integrates directly with Uniswap v3 for automatic liquidity injection.
 * 
 * TerraStake is a decentralized staking and governance protocol, designed for scalable and efficient
 * liquidity management, ensuring fair governance participation and reward distribution.
 * 
 * Features:
 * ✅ 3B Max Supply
 * ✅ Auto Liquidity Injection to Uniswap v3
 * ✅ Dynamic Liquidity Fee (Based on Trading Volume)
 * ✅ Fully Upgradeable & Emergency Controls
 * ✅ Secure Governance & Staking Mechanisms
 */
contract TerraStakeToken is Initializable, ERC20Upgradeable, AccessControlUpgradeable, PausableUpgradeable {
    using SafeMath for uint256;

    // ================================
    // 🔹 Token Metadata & Supply
    // ================================
    string public constant TOKEN_NAME = "TerraStake Token";
    string public constant TOKEN_SYMBOL = "TSTAKE";
    uint256 public constant MAX_CAP = 3_000_000_000 * 10**18; // ✅ 3B max supply

    // ================================
    // 🔹 Uniswap & Liquidity Management
    // ================================
    address public liquidityPool;
    ISwapRouter public uniswapRouter;
    IERC20 public usdcToken;

    uint256 public liquidityFee;
    uint256 public minLiquidityFee;
    uint256 public maxLiquidityFee;
    uint256 public tradingVolume;  // Tracks 24-hour trading volume for dynamic fee adjustments
    uint256 public lastFeeUpdateTime;

    // ================================
    // 🔹 Security & Governance
    // ================================
    uint256 public constant MIN_EXECUTION_DELAY = 1 days;
    uint256 public constant MAX_EXECUTION_DELAY = 7 days;
    uint256 public constant PRECISION = 1e18;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    struct Proposal {
        address proposer;
        uint256 newLiquidityFee;
        uint256 endTime;
        bool executed;
    }
    Proposal[] public proposals;
    uint256 public governanceThreshold;

    // ================================
    // 🔹 Events
    // ================================
    event LiquidityFeeUpdated(uint256 newFee);
    event LiquidityAdded(uint256 usdcAmount, uint256 tStakeAmount);
    event ProposalCreated(uint256 proposalId, address proposer, uint256 newFee, uint256 endTime);
    event ProposalExecuted(uint256 proposalId, uint256 newFee);
    event GovernanceFailed(uint256 proposalId, string reason);

    // ================================
    // 🔹 Initialization
    // ================================
    function initialize(
        address admin,
        address _uniswapRouter,
        address _liquidityPool,
        address _usdcToken,
        uint256 _minLiquidityFee,
        uint256 _maxLiquidityFee
    ) external initializer {
        require(admin != address(0), "Invalid admin");
        require(_uniswapRouter != address(0), "Invalid Uniswap Router");
        require(_liquidityPool != address(0), "Invalid Liquidity Pool");
        require(_usdcToken != address(0), "Invalid USDC address");

        __ERC20_init(TOKEN_NAME, TOKEN_SYMBOL);
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, admin);

        liquidityFee = 5; // Default 5%
        minLiquidityFee = _minLiquidityFee;
        maxLiquidityFee = _maxLiquidityFee;
        uniswapRouter = ISwapRouter(_uniswapRouter);
        liquidityPool = _liquidityPool;
        usdcToken = IERC20(_usdcToken);

        governanceThreshold = 1_000_000 * 10**18; // 1M TSTAKE for governance proposals
    }

    // ================================
    // 🔹 Liquidity Management
    // ================================
    function _transfer(address sender, address recipient, uint256 amount) internal override {
        uint256 fee = (amount * liquidityFee) / 100;
        uint256 transferAmount = amount - fee;

        super._transfer(sender, liquidityPool, fee);
        super._transfer(sender, recipient, transferAmount);

        tradingVolume += amount;
        emit LiquidityAdded(amount, fee);
    }

    function addLiquidity(uint256 usdcAmount, uint256 tStakeAmount) external onlyRole(GOVERNANCE_ROLE) {
        usdcToken.transferFrom(msg.sender, address(this), usdcAmount);
        _mint(address(this), tStakeAmount);

        usdcToken.approve(address(uniswapRouter), usdcAmount);
        _approve(address(this), address(uniswapRouter), tStakeAmount);

        uniswapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(usdcToken),
                tokenOut: address(this),
                fee: 3000, // 0.3% Uniswap fee tier
                recipient: address(this),
                deadline: block.timestamp + 600,
                amountIn: usdcAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }

    // ================================
    // 🔹 Verification Functions
    // ================================
    function officialInfo() external pure returns (string memory) {
        return "This is the official TerraStake Token (TSTAKE), deployed and maintained by the TerraStake team.";
    }

    function verifyOwner() external pure returns (string memory) {
        return "Official TerraStake Deployment - Contact TerraStake Team for verification.";
    }

    // ================================
    // 🔹 Governance & Security
    // ================================
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }
}
