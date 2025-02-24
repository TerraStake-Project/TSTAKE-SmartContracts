// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TerraStakeToken is ERC20, AccessControl, ReentrancyGuard, Pausable {
    // Constants
    uint256 public constant MAX_SUPPLY = 3_000_000_000 * 10**18;
    uint32 public constant MIN_TWAP_PERIOD = 5 minutes;
    uint256 public constant MAX_BATCH_SIZE = 200;
    uint256 public constant PRICE_DECIMALS = 18;

    // Uniswap V3 TWAP Price Oracle
    IUniswapV3Pool public immutable uniswapPool;

    // Blacklist tracking
    mapping(address => bool) public isBlacklisted;

    // Roles
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // Events
    event BlacklistUpdated(address indexed account, bool status);
    event AirdropExecuted(address[] recipients, uint256 amount, uint256 totalAmount);
    event TWAPPriceQueried(uint32 twapInterval, uint256 price);
    event EmergencyWithdrawal(address token, address to, uint256 amount);

    constructor(address _uniswapPool) ERC20("TerraStake", "TSTAKE") {
        require(_uniswapPool != address(0), "Invalid pool address");

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        uniswapPool = IUniswapV3Pool(_uniswapPool);
    }

    // 🔒 Blacklist functionality
    function setBlacklist(address account, bool status) external onlyRole(ADMIN_ROLE) {
        isBlacklisted[account] = status;
        emit BlacklistUpdated(account, status);
    }

    // 📦 Batch Blacklist Management (Efficient)
    function batchBlacklist(address[] calldata accounts, bool status) external onlyRole(ADMIN_ROLE) {
        uint256 length = accounts.length;
        require(length <= MAX_BATCH_SIZE, "TerraStake: Invalid batch size");

        for (uint256 i = 0; i < length;) {
            address account = accounts[i];
            require(account != address(0), "TerraStake: Zero address");
            isBlacklisted[account] = status;
            emit BlacklistUpdated(account, status);
            unchecked { ++i; } // Gas optimization
        }
    }

    // 🚀 Optimized Airdrop with batch limit & blacklist check
    function airdrop(address[] calldata recipients, uint256 amount) 
        external 
        onlyRole(ADMIN_ROLE) 
        whenNotPaused 
        nonReentrant 
    {
        require(amount > 0, "TerraStake: Zero amount");
        require(recipients.length > 0 && recipients.length <= MAX_BATCH_SIZE, "TerraStake: Invalid batch size");

        uint256 totalAmount = amount * recipients.length;
        require(totalSupply() + totalAmount <= MAX_SUPPLY, "TerraStake: Exceeds max supply");

        uint256 length = recipients.length;
        for (uint256 i = 0; i < length;) {
            address recipient = recipients[i];
            require(recipient != address(0) && !isBlacklisted[recipient], "TerraStake: Invalid recipient");
            _mint(recipient, amount);
            unchecked { ++i; } // Gas optimization
        }

        emit AirdropExecuted(recipients, amount, totalAmount);
    }

    // 🔥 Batch Burn Function
    function batchBurn(
        address[] calldata froms,
        uint256[] calldata amounts
    ) external onlyRole(ADMIN_ROLE) whenNotPaused nonReentrant {
        require(froms.length == amounts.length && froms.length <= MAX_BATCH_SIZE, "Invalid batch");

        for (uint256 i = 0; i < froms.length;) {
            require(froms[i] != address(0) && !isBlacklisted[froms[i]], "Invalid address");
            require(balanceOf(froms[i]) >= amounts[i], "Insufficient balance");
            _burn(froms[i], amounts[i]);
            unchecked { ++i; }
        }
    }

    // 📊 Multi-Token Emergency Withdraw
    function emergencyWithdrawMultiple(
        address[] calldata tokens,
        address to,
        uint256[] calldata amounts
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(tokens.length == amounts.length, "Length mismatch");
        for (uint256 i = 0; i < tokens.length;) {
            require(tokens[i] != address(this), "Cannot withdraw TSTAKE");
            IERC20(tokens[i]).transfer(to, amounts[i]);
            emit EmergencyWithdrawal(tokens[i], to, amounts[i]);
            unchecked { ++i; }
        }
    }

    // 🔍 Blacklist Status Check with Reason
    function checkBlacklistStatus(address account) external view returns (bool status, string memory reason) {
        status = isBlacklisted[account];
        reason = status ? "Address is blacklisted" : "Address is not blacklisted";
    }

    // 🚀 Secure Transfers with Blacklist Protection
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        require(!isBlacklisted[from] && !isBlacklisted[to], "TerraStake: Blacklisted address");
        super._transfer(from, to, amount);
    }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) whenNotPaused nonReentrant {
        require(to != address(0), "Zero address");
        require(!isBlacklisted[to], "Blacklisted address");
        require(totalSupply() + amount <= MAX_SUPPLY, "Exceeds max supply");
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyRole(ADMIN_ROLE) whenNotPaused nonReentrant {
        require(from != address(0), "Zero address");
        require(!isBlacklisted[from], "Blacklisted address");
        require(balanceOf(from) >= amount, "Insufficient balance");
        _burn(from, amount);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
}
