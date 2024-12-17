// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @title TerraStakeProxy Contract
/// @notice Manages upgrades and access control for the TerraStake protocol
/// @dev Implements transparent proxy pattern with timelock and pause mechanisms
contract TerraStakeProxy is TransparentUpgradeableProxy, AccessControl, ReentrancyGuard, Pausable {
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MULTISIG_ADMIN_ROLE = keccak256("MULTISIG_ADMIN_ROLE");

    uint256 public constant UPGRADE_TIMELOCK = 2 days;
    uint256 public constant UNPAUSE_DELAY = 1 days;

    mapping(address => uint256) public pendingUpgrades;
    mapping(uint256 => uint256) public pendingUnpause;

    uint256 public version;

    event UpgradeScheduled(
        address indexed newImplementation, 
        uint256 indexed effectiveTime,
        uint256 indexed version
    );
    event UpgradeExecuted(
        address indexed oldImplementation, 
        address indexed newImplementation,
        uint256 indexed version
    );
    event UpgradeCancelled(
        address indexed newImplementation, 
        uint256 indexed timestamp
    );
    event ProxyPaused(address indexed actor, uint256 timestamp);
    event ProxyUnpauseRequested(
        address indexed actor, 
        uint256 indexed effectiveTime
    );
    event ProxyUnpaused(address indexed actor, uint256 timestamp);

    /// @notice Initialize the proxy with implementation and admin
    /// @param _logic Initial implementation address
    /// @param _admin Admin address for access control
    /// @param _data Initialization data for implementation
    constructor(
        address _logic,
        address _admin,
        bytes memory _data
    ) TransparentUpgradeableProxy(_logic, _admin, _data) {
        require(_logic != address(0), "Invalid logic address");
        require(_admin != address(0), "Invalid admin address");
        require(_data.length > 0, "Empty initialization data");

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
        _grantRole(MULTISIG_ADMIN_ROLE, _admin);

        version = 1;
    }

    /// @notice Schedule an upgrade to new implementation
    /// @param newImplementation Address of new implementation
    function scheduleUpgrade(address newImplementation) 
        external 
        onlyRole(UPGRADER_ROLE) 
        nonReentrant 
    {
        require(newImplementation != address(0), "Zero address");
        require(newImplementation.code.length > 0, "Not a contract");
        require(pendingUpgrades[newImplementation] == 0, "Already scheduled");

        _validateImplementation(newImplementation);

        uint256 effectiveTime = block.timestamp + UPGRADE_TIMELOCK;
        pendingUpgrades[newImplementation] = effectiveTime;

        emit UpgradeScheduled(newImplementation, effectiveTime, version);
    }

    /// @notice Execute scheduled upgrade
    /// @param newImplementation Address of new implementation
    function executeUpgrade(address newImplementation) 
        external 
        onlyRole(MULTISIG_ADMIN_ROLE) 
        nonReentrant 
    {
        require(pendingUpgrades[newImplementation] != 0, "No upgrade scheduled");
        require(block.timestamp >= pendingUpgrades[newImplementation], "Timelock active");

        address oldImplementation = _implementation();
        require(newImplementation != oldImplementation, "Same implementation");

        _upgradeTo(newImplementation);
        delete pendingUpgrades[newImplementation];

        version++;
        emit UpgradeExecuted(oldImplementation, newImplementation, version);
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

    /// @notice Cancel scheduled upgrade
    /// @param newImplementation Address of scheduled implementation
    function clearScheduledUpgrade(address newImplementation) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
        nonReentrant 
    {
        require(pendingUpgrades[newImplementation] != 0, "No scheduled upgrade");
        delete pendingUpgrades[newImplementation];
        emit UpgradeCancelled(newImplementation, block.timestamp);
    }

    /// @notice Get current implementation
    function getImplementation() external view returns (address) {
        return _implementation();
    }

    /// @dev Internal upgrade implementation
    function _upgradeTo(address newImplementation) internal {
        bytes32 implementationSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        assembly {
            sstore(implementationSlot, newImplementation)
        }
    }

    /// @dev Validate new implementation
    function _validateImplementation(address newImplementation) internal view {
        require(newImplementation != address(this), "Cannot upgrade to proxy");
        
        bytes32 adminSlot = 0xb53127684a568b3173ae13b9f8a6016e01e3f0fdb8cb12c3a7c6008eeda3f3a4;
        address admin;
        assembly {
            admin := sload(adminSlot)
        }
        require(newImplementation != admin, "Cannot upgrade to admin");
    }

    receive() external payable {}

    fallback() external payable override {
        require(!paused(), "Contract paused");
        super._fallback();
    }
}

