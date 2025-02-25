// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/StorageSlot.sol";

/// @title TerraStakeProxy
/// @notice Manages secure upgrades, governance control, and emergency pauses
contract TerraStakeProxy is TransparentUpgradeableProxy, AccessControl, ReentrancyGuard, Pausable {
    // ================================
    // 🔹 Role Definitions
    // ================================
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MULTISIG_ADMIN_ROLE = keccak256("MULTISIG_ADMIN_ROLE");

    // ================================
    // 🔹 Upgrade Security & Governance Variables
    // ================================
    uint256 public constant UPGRADE_TIMELOCK = 2 days; // Timelock for upgrades
    uint256 public constant UNPAUSE_DELAY = 1 days; // Delay before unpausing

    mapping(address => uint256) public scheduledUpgrades;
    mapping(uint256 => uint256) public scheduledUnpauses;
    mapping(address => bytes32) public implementationHashes;

    uint256 public version;

    // ================================
    // 🔹 Events for Transparency
    // ================================
    event UpgradeScheduled(address indexed newImplementation, uint256 effectiveTime, uint256 version, bytes32 bytecodeHash);
    event UpgradeExecuted(address indexed oldImplementation, address indexed newImplementation, uint256 version, bytes32 oldHash, bytes32 newHash);
    event UpgradeCancelled(address indexed newImplementation, address indexed actor);
    event ProxyPaused(address indexed actor);
    event ProxyUnpauseRequested(address indexed actor, uint256 effectiveTime);
    event ProxyUnpaused(address indexed actor);
    event BytecodeMismatch(address indexed implementation, bytes32 expectedHash, bytes32 actualHash);

    // ================================
    // 🔹 Constructor
    // ================================
    constructor(
        address _logic,
        bytes memory _data
    ) TransparentUpgradeableProxy(_logic, msg.sender, _data) {
        require(_logic != address(0), "Invalid logic address");
        require(_data.length > 0, "Initialization data required");

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(MULTISIG_ADMIN_ROLE, msg.sender);

        version = 1;
        implementationHashes[_logic] = _getBytecodeHash(_logic);
    }

    // ================================
    // 🔹 Upgrade Security & Execution
    // ================================
    function scheduleUpgrade(address newImplementation) external onlyRole(UPGRADER_ROLE) nonReentrant {
        require(newImplementation != address(0), "Zero address");
        require(newImplementation.code.length > 0, "Invalid contract");
        require(scheduledUpgrades[newImplementation] == 0, "Already scheduled");

        _validateImplementation(newImplementation);
        bytes32 newBytecodeHash = _getBytecodeHash(newImplementation);
        require(newBytecodeHash != implementationHashes[_implementation()], "Same bytecode");

        scheduledUpgrades[newImplementation] = block.timestamp + UPGRADE_TIMELOCK;
        implementationHashes[newImplementation] = newBytecodeHash;

        emit UpgradeScheduled(newImplementation, scheduledUpgrades[newImplementation], version, newBytecodeHash);
    }

    function executeUpgrade(address newImplementation) external onlyRole(MULTISIG_ADMIN_ROLE) nonReentrant {
        require(scheduledUpgrades[newImplementation] != 0, "No upgrade scheduled");
        require(block.timestamp >= scheduledUpgrades[newImplementation], "Timelock active");

        address oldImplementation = _implementation();
        require(newImplementation != oldImplementation, "Same implementation");

        bytes32 storedHash = implementationHashes[newImplementation];
        bytes32 currentHash = _getBytecodeHash(newImplementation);
        require(storedHash == currentHash, "Bytecode mismatch");

        bytes32 oldHash = implementationHashes[oldImplementation];
        _upgradeTo(newImplementation);
        delete scheduledUpgrades[newImplementation];

        version++;
        emit UpgradeExecuted(oldImplementation, newImplementation, version, oldHash, currentHash);
    }

    function cancelUpgrade(address newImplementation) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(scheduledUpgrades[newImplementation] != 0, "No scheduled upgrade");
        delete scheduledUpgrades[newImplementation];
        delete implementationHashes[newImplementation];

        emit UpgradeCancelled(newImplementation, msg.sender);
    }

    // ================================
    // 🔹 Pausing & Emergency Functions
    // ================================
    function pause() external onlyRole(PAUSER_ROLE) nonReentrant {
        _pause();
        emit ProxyPaused(msg.sender);
    }

    function requestUnpause() external onlyRole(PAUSER_ROLE) nonReentrant {
        uint256 effectiveTime = block.timestamp + UNPAUSE_DELAY;
        scheduledUnpauses[block.number] = effectiveTime;
        emit ProxyUnpauseRequested(msg.sender, effectiveTime);
    }

    function unpause() external onlyRole(PAUSER_ROLE) nonReentrant {
        require(scheduledUnpauses[block.number] != 0, "No unpause scheduled");
        require(block.timestamp >= scheduledUnpauses[block.number], "Delay active");

        delete scheduledUnpauses[block.number];
        _unpause();
        emit ProxyUnpaused(msg.sender);
    }

    // ================================
    // 🔹 Internal Helper Functions
    // ================================
    function _getBytecodeHash(address implementation) internal view returns (bytes32) {
        return keccak256(implementation.code);
    }

    function _validateImplementation(address newImplementation) internal view {
        require(newImplementation != address(this), "Cannot upgrade to proxy");
        require(StorageSlot.getAddressSlot(0xb53127684a568b3173ae13b9f8a6016e01e3f0fdb8cb12c3a7c6008eeda3f3a4).value != newImplementation, "Cannot upgrade admin");
    }

    function getImplementation() external view returns (address) {
        return _implementation();
    }

    // ================================
    // 🔹 Secure Fallback & Payment Handling
    // ================================
    fallback() external payable override {
        require(!paused(), "Proxy paused");
        super._fallback();
    }

    receive() external payable {}
}
