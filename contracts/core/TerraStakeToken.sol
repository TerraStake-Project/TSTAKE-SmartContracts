// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import "./interfaces/ITerraStakeToken.sol";

contract TerraStakeToken is 
    ERC20, 
    AccessControl, 
    Pausable, 
    ReentrancyGuard, 
    ITerraStakeToken 
{
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // ------------------------------------------------
    // Constants & Immutable State
    // ------------------------------------------------

    uint256 public constant MAX_CAP = 3_000_000_000 * 10**18;

    address public immutable liquidityPool;
    ISwapRouter public immutable uniswapRouter;
    IERC20 public immutable usdcToken;

    // ------------------------------------------------
    // Configurable State
    // ------------------------------------------------

    uint256 public liquidityFee;       // In %, e.g. 5 => 5%
    uint256 public minLiquidityFee;    // Minimum possible fee
    uint256 public maxLiquidityFee;    // Maximum possible fee
    uint256 public tradingVolume;      // Tracks total token transfers
    uint256 public lastFeeUpdateTime;  
    uint256 public governanceThreshold; // Required balance to propose fee changes

    // ------------------------------------------------
    // Roles
    // ------------------------------------------------

    bytes32 public constant MINTER_ROLE       = keccak256("MINTER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE   = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant EMERGENCY_ROLE    = keccak256("EMERGENCY_ROLE");

    // ------------------------------------------------
    // Governance Proposal Structure
    // ------------------------------------------------

    struct Proposal {
        address proposer;
        uint256 newLiquidityFee;
        uint256 endTime;
        bool executed;
    }
    
    Proposal[] public proposals;

    // ------------------------------------------------
    // Events
    // ------------------------------------------------

    event LiquidityAdded(uint256 usdcAmount, uint256 tStakeAmount);
    event ProposalCreated(uint256 proposalId, address proposer, uint256 newFee, uint256 endTime);
    event ProposalExecuted(uint256 proposalId, uint256 newFee);

    // ------------------------------------------------
    // Constructor
    // ------------------------------------------------

    constructor(
        address admin,
        address _uniswapRouter,
        address _liquidityPool,
        address _usdcToken
    ) ERC20("TerraStake Token", "TSTAKE") {
        require(admin != address(0), "Invalid admin");
        require(_uniswapRouter != address(0), "Invalid router");
        require(_liquidityPool != address(0), "Invalid pool");
        require(_usdcToken != address(0), "Invalid token");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, admin);

        uniswapRouter = ISwapRouter(_uniswapRouter);
        liquidityPool = _liquidityPool;
        usdcToken = IERC20(_usdcToken);
        
        liquidityFee = 5;        // 5%
        minLiquidityFee = 1;     // 1%
        maxLiquidityFee = 10;    // 10%
        governanceThreshold = 1_000_000 * 10**18; // Must hold at least 1,000,000 TSTAKE
    }

    // ------------------------------------------------
    // Liquidity Management
    // ------------------------------------------------

    /**
     * @notice Add liquidity to the TSTAKE/USDC pool on Uniswap V3
     * @dev    Restricted to GOVERNANCE_ROLE and guarded by nonReentrant and Pausable
     */
    function addLiquidity(uint256 usdcAmount, uint256 tStakeAmount) 
        external 
        override
        onlyRole(GOVERNANCE_ROLE) 
        nonReentrant 
        whenNotPaused 
    {
        require(usdcAmount > 0 && tStakeAmount > 0, "Invalid amounts");
        require(totalSupply().add(tStakeAmount) <= MAX_CAP, "Exceeds cap");
        
        // Mint TSTAKE to this contract
        _mint(address(this), tStakeAmount);

        // Transfer USDC from caller
        usdcToken.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // Approve tokens for the swap
        usdcToken.safeApprove(address(uniswapRouter), usdcAmount);
        _approve(address(this), address(uniswapRouter), tStakeAmount);

        // Perform the swap (example usage)
        uniswapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(usdcToken),
                tokenOut: address(this),
                fee: 3000,
                recipient: address(this),
                deadline: block.timestamp + 600,
                amountIn: usdcAmount,
                amountOutMinimum: 0,  // WARNING: 0 means no slippage protection
                sqrtPriceLimitX96: 0
            })
        );
        
        emit LiquidityAdded(usdcAmount, tStakeAmount);
    }

    // ------------------------------------------------
    // ERC20: Transfer Hook
    // ------------------------------------------------

    /**
     * @notice Overridden transfer hook to apply liquidity fee
     *         Moved fee to be taken at the end, and uses nonReentrant.
     */
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal override nonReentrant whenNotPaused {
        require(sender != address(0) && recipient != address(0), "Invalid address");
        require(amount > 0, "Zero amount");

        uint256 fee = amount.mul(liquidityFee).div(100);
        uint256 transferAmount = amount.sub(fee);

        // Transfer to recipient
        super._transfer(sender, recipient, transferAmount);

        // Transfer fee to liquidity pool
        super._transfer(sender, liquidityPool, fee);

        // Update trading volume
        tradingVolume = tradingVolume.add(amount);
    }

    // ------------------------------------------------
    // Governance: Proposals
    // ------------------------------------------------

    /**
     * @notice Propose a new liquidity fee
     * @dev    Caller must hold at least governanceThreshold TSTAKE
     */
    function proposeFeeAdjustment(uint256 newFee) 
        external 
        override 
        onlyRole(GOVERNANCE_ROLE) 
    {
        require(balanceOf(msg.sender) >= governanceThreshold, "Insufficient TSTAKE for governance");
        require(newFee >= minLiquidityFee && newFee <= maxLiquidityFee, "Invalid fee");
        
        proposals.push(Proposal({
            proposer: msg.sender,
            newLiquidityFee: newFee,
            endTime: block.timestamp + 3 days,
            executed: false
        }));

        emit ProposalCreated(proposals.length - 1, msg.sender, newFee, block.timestamp + 3 days);
    }

    /**
     * @notice Execute a proposal if time has elapsed
     */
    function executeProposal(uint256 proposalId) 
        external 
        override 
        onlyRole(GOVERNANCE_ROLE) 
    {
        Proposal storage proposal = proposals[proposalId];
        require(!proposal.executed, "Already executed");
        require(block.timestamp >= proposal.endTime, "Not ready");

        liquidityFee = proposal.newLiquidityFee;
        proposal.executed = true;

        emit ProposalExecuted(proposalId, proposal.newLiquidityFee);
    }

    // ------------------------------------------------
    // Minting
    // ------------------------------------------------

    /**
     * @notice Mint new TSTAKE tokens to a specified address
     * @dev    Only callable by the address with MINTER_ROLE **and** must match the single default admin
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        // Additional check: Must be the same address that holds the default admin role
        require(msg.sender == getRoleMember(DEFAULT_ADMIN_ROLE, 0), "Unauthorized");
        require(totalSupply().add(amount) <= MAX_CAP, "Exceeds max supply");

        _mint(to, amount);
    }

    // ------------------------------------------------
    // Utility & Emergency Functions
    // ------------------------------------------------

    /**
     * @notice Safely increases the allowance from msg.sender to a given spender
     */
    function safeIncreaseAllowance(address spender, uint256 addedValue) external {
        require(spender != address(0), "Invalid spender");
        uint256 newAllowance = allowance(msg.sender, spender).add(addedValue);
        _approve(msg.sender, spender, newAllowance);
    }

    /**
     * @notice Pause all token transfers and sensitive functions
     */
    function pause() external override onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause token transfers and sensitive functions
     */
    function unpause() external override onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    // ------------------------------------------------
    // Interface Requirements
    // ------------------------------------------------

    function officialInfo() external pure override returns (string memory) {
        return "Official TerraStake Token (TSTAKE)";
    }

    function verifyOwner() external view override returns (address) {
        return getRoleMember(DEFAULT_ADMIN_ROLE, 0);
    }
}
