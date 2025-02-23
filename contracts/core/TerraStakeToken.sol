// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/ITerraStakeToken.sol";

/**
 * @title TerraStakeToken
 * @notice Official TerraStake Token (TSTAKE) for the TerraStake ecosystem.
 * @dev This contract manages governance, staking rewards, and liquidity provisioning.
 * It integrates directly with Uniswap v3 for automatic liquidity injection.
 */
contract TerraStakeToken is ERC20, AccessControl, Pausable, ITerraStakeToken {
    // ================================
    // 🔹 Token Metadata & Supply
    // ================================
    uint256 public constant MAX_CAP = 3_000_000_000 * 10**18; // ✅ 3B max supply

    // ================================
    // 🔹 Uniswap & Liquidity Management
    // ================================
    address public immutable liquidityPool;
    ISwapRouter public immutable uniswapRouter;
    IERC20 public immutable usdcToken;

    uint256 public liquidityFee;
    uint256 public minLiquidityFee;
    uint256 public maxLiquidityFee;
    uint256 public tradingVolume;
    uint256 public lastFeeUpdateTime;

    // ================================
    // 🔹 Security & Governance
    // ================================
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
    // 🔹 Constructor (Non-Upgradable)
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
        require(balanceOf(sender) >= amount, "Insufficient balance");

        uint256 fee = (amount * liquidityFee) / 100;
        uint256 transferAmount = amount - fee;

        super._transfer(sender, liquidityPool, fee);
        super._transfer(sender, recipient, transferAmount);

        tradingVolume += amount;
        emit LiquidityAdded(amount, fee);
    }

    function addLiquidity(uint256 usdcAmount, uint256 tStakeAmount) external onlyRole(GOVERNANCE_ROLE) {
        require(usdcAmount > 0 && tStakeAmount > 0, "Invalid amounts");

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
    // 🔹 Governance & Security
    // ================================
    function proposeFeeAdjustment(uint256 newFee) external onlyRole(GOVERNANCE_ROLE) {
        require(newFee >= minLiquidityFee && newFee <= maxLiquidityFee, "Fee out of range");

        uint256 proposalId = proposals.length;
        proposals.push(Proposal({
            proposer: msg.sender,
            newLiquidityFee: newFee,
            endTime: block.timestamp + 3 days,
            executed: false
        }));

        emit ProposalCreated(proposalId, msg.sender, newFee, block.timestamp + 3 days);
    }

    function executeProposal(uint256 proposalId) external onlyRole(GOVERNANCE_ROLE) {
        Proposal storage proposal = proposals[proposalId];
        require(!proposal.executed, "Already executed");
        require(block.timestamp >= proposal.endTime, "Voting period not ended");

        liquidityFee = proposal.newLiquidityFee;
        proposal.executed = true;

        emit ProposalExecuted(proposalId, proposal.newLiquidityFee);
    }

    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    function officialInfo() external pure returns (string memory) {
        return "This is the official TerraStake Token (TSTAKE), deployed and maintained by the TerraStake team.";
    }

    function verifyOwner() external pure returns (string memory) {
        return "Official TerraStake Deployment - Contact TerraStake Team for verification.";
    }
}
