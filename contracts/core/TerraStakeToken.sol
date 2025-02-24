// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/ITerraStakeGovernance.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";

contract TerraStakeToken is ERC20, AccessControl, ReentrancyGuard, Pausable {
    // ================================
    // 🔹 Constants
    // ================================
    uint256 public constant MAX_SUPPLY = 3_000_000_000 * 10**18;
    uint32 public constant MIN_TWAP_PERIOD = 5 minutes;
    uint256 public constant MAX_BATCH_SIZE = 200;
    uint256 public constant PRICE_DECIMALS = 18;

    // ================================
    // 🔹 Uniswap V3 TWAP Oracle
    // ================================
    IUniswapV3Pool public immutable uniswapPool;

    // ================================
    // 🔹 TerraStake Ecosystem References
    // ================================
    ITerraStakeGovernance public governanceContract;
    ITerraStakeStaking public stakingContract;
    ITerraStakeLiquidityGuard public liquidityGuard;

    // ================================
    // 🔹 Blacklist Management
    // ================================
    mapping(address => bool) public isBlacklisted;

    // ================================
    // 🔹 Roles
    // ================================
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ================================
    // 🔹 Events
    // ================================
    event BlacklistUpdated(address indexed account, bool status);
    event AirdropExecuted(address[] recipients, uint256 amount, uint256 totalAmount);
    event TWAPPriceQueried(uint32 twapInterval, uint256 price);
    event EmergencyWithdrawal(address token, address to, uint256 amount);
    event TokenBurned(address indexed burner, uint256 amount);
    event GovernanceUpdated(address indexed governanceContract);
    event StakingUpdated(address indexed stakingContract);
    event LiquidityGuardUpdated(address indexed liquidityGuard);

    // ================================
    // 🔹 Constructor
    // ================================
    constructor(
        address _uniswapPool,
        address _governanceContract,
        address _stakingContract,
        address _liquidityGuard
    ) ERC20("TerraStake", "TSTAKE") {
        require(_uniswapPool != address(0), "Invalid Uniswap pool address");
        require(_governanceContract != address(0), "Invalid governance contract");
        require(_stakingContract != address(0), "Invalid staking contract");
        require(_liquidityGuard != address(0), "Invalid liquidity guard contract");

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        uniswapPool = IUniswapV3Pool(_uniswapPool);
        governanceContract = ITerraStakeGovernance(_governanceContract);
        stakingContract = ITerraStakeStaking(_stakingContract);
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);
    }

    // ================================
    // 🔹 Blacklist Management
    // ================================
    function setBlacklist(address account, bool status) external onlyRole(ADMIN_ROLE) {
        isBlacklisted[account] = status;
        emit BlacklistUpdated(account, status);
    }

    function batchBlacklist(address[] calldata accounts, bool status) external onlyRole(ADMIN_ROLE) {
        uint256 length = accounts.length;
        require(length <= MAX_BATCH_SIZE, "Batch size too large");

        for (uint256 i = 0; i < length;) {
            isBlacklisted[accounts[i]] = status;
            emit BlacklistUpdated(accounts[i], status);
            unchecked { ++i; }
        }
    }

    // ================================
    // 🔹 Airdrop Function
    // ================================
    function airdrop(address[] calldata recipients, uint256 amount) 
        external 
        onlyRole(ADMIN_ROLE) 
        whenNotPaused 
        nonReentrant 
    {
        require(amount > 0, "Amount must be > 0");
        require(recipients.length <= MAX_BATCH_SIZE, "Batch too large");

        uint256 totalAmount = amount * recipients.length;
        require(totalSupply() + totalAmount <= MAX_SUPPLY, "Exceeds max supply");

        for (uint256 i = 0; i < recipients.length;) {
            require(!isBlacklisted[recipients[i]], "Recipient blacklisted");
            _mint(recipients[i], amount);
            unchecked { ++i; }
        }

        emit AirdropExecuted(recipients, amount, totalAmount);
    }

    // ================================
    // 🔹 Minting & Burning
    // ================================
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) whenNotPaused nonReentrant {
        require(to != address(0), "Invalid address");
        require(!isBlacklisted[to], "Recipient blacklisted");
        require(totalSupply() + amount <= MAX_SUPPLY, "Exceeds max supply");

        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyRole(ADMIN_ROLE) whenNotPaused nonReentrant {
        require(!isBlacklisted[from], "Address blacklisted");
        require(balanceOf(from) >= amount, "Insufficient balance");

        _burn(from, amount);
        emit TokenBurned(from, amount);
    }

    // ================================
    // 🔹 Emergency Withdraw
    // ================================
    function emergencyWithdrawMultiple(
        address[] calldata tokens,
        address to,
        uint256[] calldata amounts
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(tokens.length == amounts.length, "Mismatched input lengths");

        for (uint256 i = 0; i < tokens.length;) {
            require(tokens[i] != address(this), "Cannot withdraw native token");
            IERC20(tokens[i]).transfer(to, amounts[i]);
            emit EmergencyWithdrawal(tokens[i], to, amounts[i]);
            unchecked { ++i; }
        }
    }

    // ================================
    // 🔹 Governance & Ecosystem Updates
    // ================================
    function updateGovernanceContract(address _governanceContract) external onlyRole(ADMIN_ROLE) {
        require(_governanceContract != address(0), "Invalid address");
        governanceContract = ITerraStakeGovernance(_governanceContract);
        emit GovernanceUpdated(_governanceContract);
    }

    function updateStakingContract(address _stakingContract) external onlyRole(ADMIN_ROLE) {
        require(_stakingContract != address(0), "Invalid address");
        stakingContract = ITerraStakeStaking(_stakingContract);
        emit StakingUpdated(_stakingContract);
    }

    function updateLiquidityGuard(address _liquidityGuard) external onlyRole(ADMIN_ROLE) {
        require(_liquidityGuard != address(0), "Invalid address");
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);
        emit LiquidityGuardUpdated(_liquidityGuard);
    }

    // ================================
    // 🔹 Security Functions
    // ================================
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
}
