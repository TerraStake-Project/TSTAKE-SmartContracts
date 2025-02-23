// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * @title TerraStakeToken (TSTAKE)
 * @notice Secure & Immutable ERC20 Token with governance, staking, and Uniswap liquidity management.
 */
contract TerraStakeToken is ERC20, AccessControl, Pausable, ReentrancyGuard {
    using SafeMath for uint256;

    // ================================
    // 🔹 Token Metadata & Supply
    // ================================
    uint256 public constant MAX_CAP = 3_000_000_000 * 10**18; // ✅ 3B max supply

    // ================================
    // 🔹 Roles & Governance
    // ================================
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant MULTISIG_ROLE = keccak256("MULTISIG_ROLE");

    // ================================
    // 🔹 Uniswap & Liquidity Management
    // ================================
    address public liquidityPool;
    ISwapRouter public immutable uniswapRouter;
    IERC20 public immutable usdcToken;

    uint256 public liquidityFee;
    uint256 public minLiquidityFee;
    uint256 public maxLiquidityFee;
    uint256 public tradingVolume;  // Tracks 24-hour trading volume
    uint256 public lastFeeUpdateTime;

    // ================================
    // 🔹 Governance Proposals
    // ================================
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
    event EmergencyPaused(address by);
    event EmergencyUnpaused(address by);

    // ================================
    // 🔹 Constructor (Immutable)
    // ================================
    constructor(
        address admin,
        address _uniswapRouter,
        address _liquidityPool,
        address _usdcToken,
        uint256 _minLiquidityFee,
        uint256 _maxLiquidityFee
    ) ERC20("TerraStake Token", "TSTAKE") {
        require(admin != address(0), "Invalid admin");
        require(_uniswapRouter != address(0), "Invalid Uniswap Router");
        require(_liquidityPool != address(0), "Invalid Liquidity Pool");
        require(_usdcToken != address(0), "Invalid USDC address");

        _setupRole(DEFAULT_ADMIN_ROLE, admin);
        _setupRole(MINTER_ROLE, admin);
        _setupRole(GOVERNANCE_ROLE, admin);
        _setupRole(EMERGENCY_ROLE, admin);
        _setupRole(MULTISIG_ROLE, admin);

        liquidityFee = 5; // Default 5%
        minLiquidityFee = _minLiquidityFee;
        maxLiquidityFee = _maxLiquidityFee;
        uniswapRouter = ISwapRouter(_uniswapRouter);
        liquidityPool = _liquidityPool;
        usdcToken = IERC20(_usdcToken);

        governanceThreshold = 1_000_000 * 10**18; // 1M TSTAKE required for governance proposals
        _mint(admin, MAX_CAP); // ✅ Mint entire supply to admin
    }

    // ================================
    // 🔹 Liquidity Management (Safe)
    // ================================
    function _transfer(address sender, address recipient, uint256 amount) internal override {
        require(liquidityPool != address(0), "Liquidity pool not set");
        uint256 fee = (amount * liquidityFee) / 100;
        uint256 transferAmount = amount - fee;

        super._transfer(sender, liquidityPool, fee);
        super._transfer(sender, recipient, transferAmount);

        tradingVolume += amount;
        emit LiquidityAdded(amount, fee);
    }

    function addLiquidity(uint256 usdcAmount, uint256 tStakeAmount) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        require(usdcAmount > 0 && tStakeAmount > 0, "Invalid amounts");
        require(address(uniswapRouter) != address(0), "Uniswap router not set");

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
                amountOutMinimum: 0, // Ensure slippage protection
                sqrtPriceLimitX96: 0
            })
        );
    }

    // ================================
    // 🔹 Governance & Proposals
    // ================================
    function proposeFeeAdjustment(uint256 newFee) external onlyRole(GOVERNANCE_ROLE) {
        require(newFee >= minLiquidityFee && newFee <= maxLiquidityFee, "Fee out of range");
        require(balanceOf(msg.sender) >= governanceThreshold, "Insufficient governance stake");

        uint256 proposalId = proposals.length;
        proposals.push(Proposal(msg.sender, newFee, block.timestamp + 3 days, false));

        emit ProposalCreated(proposalId, msg.sender, newFee, block.timestamp + 3 days);
    }

    function executeProposal(uint256 proposalId) external onlyRole(MULTISIG_ROLE) {
        require(proposalId < proposals.length, "Invalid proposal ID");
        Proposal storage proposal = proposals[proposalId];
        require(!proposal.executed, "Already executed");
        require(block.timestamp >= proposal.endTime, "Voting period not ended");

        liquidityFee = proposal.newLiquidityFee;
        proposal.executed = true;

        emit ProposalExecuted(proposalId, proposal.newLiquidityFee);
    }

    // ================================
    // 🔹 Emergency Controls
    // ================================
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
        emit EmergencyPaused(msg.sender);
    }

    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
        emit EmergencyUnpaused(msg.sender);
    }

    // ================================
    // 🔹 Verification & Security
    // ================================
    function officialInfo() external pure returns (string memory) {
        return "This is the official TerraStake Token (TSTAKE), deployed and maintained by the TerraStake team.";
    }

    function verifyOwner() external view returns (address) {
        return getRoleMember(DEFAULT_ADMIN_ROLE, 0);
    }
}
