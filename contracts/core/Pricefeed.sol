// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./interfaces/IPriceFeed.sol"; // ✅ Corrected import

contract PriceFeed is IPriceFeed, AccessControlUpgradeable, UUPSUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant PRICE_UPDATER_ROLE = keccak256("PRICE_UPDATER_ROLE"); // ✅ External Updater Role

    struct TokenData {
        string coinGeckoId; // ✅ CoinGecko Token ID (e.g., "terra-stake-token", "ethereum", "usd-coin")
        uint256 lastPrice; // ✅ Last recorded price
        uint256 lastUpdated; // ✅ Last update timestamp
        bool isActive; // ✅ Whether token is actively tracked
    }

    mapping(address => TokenData) public trackedTokens; // ✅ Mapping token address to data
    EnumerableSet.AddressSet private tokenSet; // ✅ List of tracked tokens

    event TokenAdded(address indexed token, string coinGeckoId);
    event TokenRemoved(address indexed token);
    event PriceUpdated(address indexed token, uint256 price, uint256 timestamp);
    event GovernanceTransferred(address indexed newGovernance);

    /// @notice ✅ **Initialize Contract**
    function initialize(address admin) external initializer {
        require(admin != address(0), "Invalid admin");

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(PRICE_UPDATER_ROLE, admin);
    }

    /// @notice ✅ **Upgrade Authorization**
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(GOVERNANCE_ROLE) {}

    /// @notice ✅ **Add Token (Governance Only)**
    function addToken(address token, string memory coinGeckoId) external onlyRole(GOVERNANCE_ROLE) {
        require(token != address(0), "Invalid token");
        require(bytes(coinGeckoId).length > 0, "Invalid CoinGecko ID");
        require(!tokenSet.contains(token), "Token already tracked");

        trackedTokens[token] = TokenData(coinGeckoId, 0, block.timestamp, true);
        tokenSet.add(token);

        emit TokenAdded(token, coinGeckoId);
    }

    /// @notice ✅ **Remove Token (Governance Only)**
    function removeToken(address token) external onlyRole(GOVERNANCE_ROLE) {
        require(tokenSet.contains(token), "Token not tracked");

        delete trackedTokens[token];
        tokenSet.remove(token);

        emit TokenRemoved(token);
    }

    /// @notice ✅ **Update Price (From Off-Chain API)**
    function updatePrice(address token, uint256 newPrice) external override onlyRole(PRICE_UPDATER_ROLE) {
        require(tokenSet.contains(token), "Token not tracked");
        require(newPrice > 0, "Invalid price");

        TokenData storage tokenData = trackedTokens[token];
        tokenData.lastPrice = newPrice;
        tokenData.lastUpdated = block.timestamp;

        emit PriceUpdated(token, newPrice, block.timestamp);
    }

    /// @notice ✅ **Get Price**
    function getPrice(address token) external view override returns (uint256) {
        require(tokenSet.contains(token), "Token not tracked");
        return trackedTokens[token].lastPrice;
    }

    /// @notice ✅ **Get All Tracked Tokens**
    function getTrackedTokens() external view override returns (address[] memory) {
        return tokenSet.values();
    }

    /// @notice ✅ **Transfer Governance**
    function transferGovernance(address newGovernance) external onlyRole(GOVERNANCE_ROLE) {
        require(newGovernance != address(0), "Invalid address");
        _grantRole(GOVERNANCE_ROLE, newGovernance);
        _revokeRole(GOVERNANCE_ROLE, msg.sender);
        emit GovernanceTransferred(newGovernance);
    }
}

