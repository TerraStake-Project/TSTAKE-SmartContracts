// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/StorageSlot.sol";

/// @title TerraStakeProxy Contract
/// @notice Manages upgrades, access control, and governance integration
/// @dev Uses OpenZeppelin's TransparentUpgradeableProxy and AccessControl for role-based access
contract TerraStakeProxy is TransparentUpgradeableProxy, AccessControl, ReentrancyGuard, Pausable {
    // Role definitions
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MULTISIG_ADMIN_ROLE = keccak256("MULTISIG_ADMIN_ROLE");

    // Time delays for upgrades and unpausing
    uint256 public constant UPGRADE_TIMELOCK = 2 days; // Timelock for upgrades
    uint256 public constant UNPAUSE_DELAY = 1 days;   // Delay before unpausing

    // Tracks scheduled upgrades and unpause requests
    mapping(address => uint256) public pendingUpgrades;
    mapping(uint256 => uint256) public pendingUnpause;

    uint256 public version; // Tracks the current version of the implementation

    /// Events
    event UpgradeScheduled(address indexed newImplementation, uint256 effectiveTime, uint256 version);
    event UpgradeExecuted(address indexed oldImplementation, address indexed newImplementation, uint256 version);
    event UpgradeCancelled(address indexed newImplementation, address indexed actor, uint256 timestamp);
    event ProxyPaused(address indexed actor, uint256 timestamp);
    event ProxyUnpauseRequested(address indexed actor, uint256 effectiveTime);
    event ProxyUnpaused(address indexed actor, uint256 timestamp);

    /// @notice Initialize the proxy with implementation, admin, and roles
    /// @param _logic Address of the initial implementation contract
    /// @param _data ABI-encoded initializer call for the implementation
    constructor(
        address _logic,
        bytes memory _data
    ) TransparentUpgradeableProxy(_logic, 0xcB3705b50773e95fCe6d3Fcef62B4d753aA0059d, _data) {
        require(_logic != address(0), "Invalid logic address");
        require(_data.length > 0, "Empty initialization data");

        // Set roles and assign them to the predefined admin address
        _grantRole(DEFAULT_ADMIN_ROLE, 0xcB3705b50773e95fCe6d3Fcef62B4d753aA0059d);
        _grantRole(UPGRADER_ROLE, 0xcB3705b50773e95fCe6d3Fcef62B4d753aA0059d);
        _grantRole(PAUSER_ROLE, 0xcB3705b50773e95fCe6d3Fcef62B4d753aA0059d);
        _grantRole(MULTISIG_ADMIN_ROLE, 0xcB3705b50773e95fCe6d3Fcef62B4d753aA0059d);

        version = 1; // Initialize the version
    }

    /// @notice Schedule an upgrade to a new implementation
    /// @param newImplementation Address of the new implementation contract
    function scheduleUpgrade(address newImplementation) external onlyRole(UPGRADER_ROLE) nonReentrant {
        require(newImplementation != address(0), "Zero address");
        require(newImplementation.code.length > 0, "Not a contract");
        require(pendingUpgrades[newImplementation] == 0, "Already scheduled");

        _validateImplementation(newImplementation);

        uint256 effectiveTime = block.timestamp + UPGRADE_TIMELOCK;
        pendingUpgrades[newImplementation] = effectiveTime;

        emit UpgradeScheduled(newImplementation, effectiveTime, version);
    }

    /// @notice Execute a scheduled upgrade
    /// @param newImplementation Address of the new implementation contract
    function executeUpgrade(address newImplementation) external onlyRole(MULTISIG_ADMIN_ROLE) nonReentrant {
        require(pendingUpgrades[newImplementation] != 0, "No upgrade scheduled");
        require(block.timestamp >= pendingUpgrades[newImplementation], "Timelock active");

        address oldImplementation = _implementation();
        require(newImplementation != oldImplementation, "Same implementation");

        _upgradeTo(newImplementation);
        delete pendingUpgrades[newImplementation];

        version++;
        emit UpgradeExecuted(oldImplementation, newImplementation, version);
    }

    /// @notice Cancel a scheduled upgrade
    /// @param newImplementation Address of the scheduled implementation to cancel
    function clearScheduledUpgrade(address newImplementation) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(pendingUpgrades[newImplementation] != 0, "No scheduled upgrade");
        delete pendingUpgrades[newImplementation];
        emit UpgradeCancelled(newImplementation, msg.sender, block.timestamp);
    }

    /// @notice Pause proxy functionality
    function pause() external onlyRole(PAUSER_ROLE) nonReentrant {
        _pause();
        emit ProxyPaused(msg.sender, block.timestamp);
    }

    /// @notice Request to unpause with delay
    function requestUnpause() external onlyRole(PAUSER_ROLE) nonReentrant {
        uint256 effectiveTime = block.timestamp + UNPAUSE_DELAY;
        pendingUnpause[block.number] = effectiveTime;
        emit ProxyUnpauseRequested(msg.sender, effectiveTime);
    }

    /// @notice Execute unpausing after delay
    function unpause() external onlyRole(PAUSER_ROLE) nonReentrant {
        require(pendingUnpause[block.number] != 0, "No unpause scheduled");
        require(block.timestamp >= pendingUnpause[block.number], "Delay active");

        delete pendingUnpause[block.number];
        _unpause();
        emit ProxyUnpaused(msg.sender, block.timestamp);
    }

    /// @notice Get current implementation address
    /// @return The address of the current implementation
    function getImplementation() external view returns (address) {
        return _implementation();
    }

    /// @dev Validate new implementation before upgrade
    function _validateImplementation(address newImplementation) internal view {
        require(newImplementation != address(this), "Cannot upgrade to proxy");
        require(StorageSlot.getAddressSlot(0xb53127684a568b3173ae13b9f8a6016e01e3f0fdb8cb12c3a7c6008eeda3f3a4).value != newImplementation, "Cannot upgrade to admin");
    }

    /// @dev Internal upgrade mechanism using OpenZeppelin StorageSlot
    function _upgradeTo(address newImplementation) internal {
        StorageSlot.getAddressSlot(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc).value = newImplementation;
    }

    /// @dev Prevent calls when paused
    fallback() external payable override {
        require(!paused(), "Contract paused");
        super._fallback();
    }

    receive() external payable {}
}