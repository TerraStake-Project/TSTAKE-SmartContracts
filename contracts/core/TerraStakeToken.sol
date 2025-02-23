// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

/**
 * @title TerraStakeToken
 * @notice Secure, governance-driven staking token with liquidity injection and safety mechanisms.
 * @dev Implements ERC20, access control, governance, and Uniswap integration.
 */
contract TerraStakeToken is ERC20, AccessControl, Pausable, ReentrancyGuard {
    using SafeMath for uint256;

    // ================================
    // 🔹 Constants
    // ================================
    uint256 public constant MAX_CAP = 3_000_000_000 * 10**18; // ✅ 3B max supply
    uint256 public constant MIN_LIQUIDITY_FEE = 1; // 1% (hardcoded limit)
    uint256 public constant MAX_LIQUIDITY_FEE = 10; // 10% (hardcoded limit)
    uint256 public constant GOVERNANCE_THRESHOLD = 1_000_000 * 10**18; // 1M TSTAKE required for proposals

    // ================================
    // 🔹 Roles
    // ================================
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // ================================
    // 🔹 Liquidity Management
    // ================================
    address public liquidityPool;
    ISwapRouter public immutable uniswapRouter;
    IERC20 public immutable usdcToken;
    
    uint256 public liquidityFee;
    uint256 public tradingVolume;
    uint256 public lastFeeUpdateTime;

    // ================================
    // 🔹 Governance
    // ================================
    struct Proposal {
        address proposer;
        uint256 newLiquidityFee;
        uint256 endTime;
        bool executed;
    }
    
    Proposal[] public proposals;
    mapping(address => uint256) public userProposals; // Track proposals per user

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
        address _usdcToken
    ) ERC20("TerraStake Token", "TSTAKE") {
        require(admin != address(0), "Invalid admin address");
        require(_uniswapRouter != address(0), "Invalid Uniswap Router");
        require(_liquidityPool != address(0), "Invalid Liquidity Pool");
        require(_usdcToken != address(0), "Invalid USDC Token");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, admin);

        uniswapRouter = ISwapRouter(_uniswapRouter);
        liquidityPool = _liquidityPool;
        usdcToken = IERC20(_usdcToken);

        liquidityFee = 5; // Default 5%
    }

    // ================================
    // 🔹 Liquidity Management
    // ================================
    function _transfer(address sender, address recipient, uint256 amount) internal override whenNotPaused {
        uint256 fee = amount.mul(liquidityFee).div(100);
        uint256 transferAmount = amount.sub(fee);

        super._transfer(sender, liquidityPool, fee);
        super._transfer(sender, recipient, transferAmount);

        tradingVolume += amount;
        emit LiquidityAdded(amount, fee);
    }

    function addLiquidity(uint256 usdcAmount, uint256 tStakeAmount) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        require(usdcToken.transferFrom(msg.sender, address(this), usdcAmount), "USDC transfer failed");
        _mint(address(this), tStakeAmount);

        require(usdcToken.approve(address(uniswapRouter), usdcAmount), "USDC approval failed");
        _approve(address(this), address(uniswapRouter), tStakeAmount);

        bool success = uniswapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(usdcToken),
                tokenOut: address(this),
                fee: 3000,
                recipient: address(this),
                deadline: block.timestamp + 600,
                amountIn: usdcAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        require(success, "Liquidity injection failed");
    }

    // ================================
    // 🔹 Governance
    // ================================
    function proposeFeeAdjustment(uint256 newFee) external onlyRole(GOVERNANCE_ROLE) {
        require(balanceOf(msg.sender) >= GOVERNANCE_THRESHOLD, "Insufficient TSTAKE for proposal");
        require(newFee >= MIN_LIQUIDITY_FEE && newFee <= MAX_LIQUIDITY_FEE, "Invalid fee range");
        require(userProposals[msg.sender] < 1, "Active proposal limit reached");

        uint256 proposalId = proposals.length;
        proposals.push(Proposal(msg.sender, newFee, block.timestamp + 3 days, false));
        userProposals[msg.sender]++;

        emit ProposalCreated(proposalId, msg.sender, newFee, block.timestamp + 3 days);
    }

    function executeProposal(uint256 proposalId) external onlyRole(GOVERNANCE_ROLE) {
        Proposal storage proposal = proposals[proposalId];
        require(!proposal.executed, "Proposal already executed");
        require(block.timestamp >= proposal.endTime, "Voting period not over");

        liquidityFee = proposal.newLiquidityFee;
        proposal.executed = true;
        userProposals[proposal.proposer]--;

        emit ProposalExecuted(proposalId, proposal.newLiquidityFee);
    }

    // ================================
    // 🔹 Emergency Controls
    // ================================
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    // ================================
    // 🔹 Utility Functions
    // ================================
    function getLiquidityReserves() external view returns (uint256) {
        return usdcToken.balanceOf(address(this));
    }

    function officialInfo() external pure returns (string memory) {
        return "This is the official TerraStake Token (TSTAKE), deployed and maintained by the TerraStake team.";
    }

    function verifyOwner() external pure returns (string memory) {
        return "Official TerraStake Deployment - Contact TerraStake Team for verification.";
    }
}
