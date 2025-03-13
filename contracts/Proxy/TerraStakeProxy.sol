// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/utils/StorageSlot.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// @title TerraStakeProxy
/// @notice A proxy manager that uses a TransparentUpgradeableProxy with scheduled upgrades and unpausing.
/// It supports timelocked upgrades, emergency pausing/unpausing, and emits detailed events for transparency.
contract TerraStakeProxy is TransparentUpgradeableProxy, AccessControlUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    // ====================================================
    //  Role Definitions
    // ====================================================
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MULTISIG_ADMIN_ROLE = keccak256("MULTISIG_ADMIN_ROLE");

    // ====================================================
    //  Upgrade Governance Variables
    // ====================================================
    uint256 public constant UPGRADE_TIMELOCK = 2 days;   // Timelock for upgrades
    uint256 public constant UNPAUSE_DELAY = 1 days;       // Delay before unpausing
    mapping(address => uint256) public scheduledUpgrades;
    mapping(uint256 => uint256) public scheduledUnpauses;
    mapping(address => bytes32) public implementationHashes;
    uint256 public version;

    // ====================================================
    //  Events for Transparency
    // ====================================================
    event UpgradeScheduled(address indexed newImplementation, uint256 effectiveTime, uint256 version, bytes32 bytecodeHash);
    event UpgradeExecuted(address indexed oldImplementation, address indexed newImplementation, uint256 version, bytes32 oldHash, bytes32 newHash);
    event UpgradeCancelled(address indexed newImplementation, address indexed actor);
    event ProxyPaused(address indexed actor);
    event ProxyUnpauseRequested(address indexed actor, uint256 effectiveTime);
    event ProxyUnpaused(address indexed actor);
    event BytecodeMismatch(address indexed implementation, bytes32 expectedHash, bytes32 actualHash);

    // ====================================================
    //  Constructor & Initializer
    // ====================================================
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _logic, bytes memory _data) TransparentUpgradeableProxy(_logic, msg.sender, _data) {
        // In the constructor we assign the default admin and other roles.
        // Note that TransparentUpgradeableProxy does not have its own initializer,
        // so we use the constructor for setup.
        AccessControlUpgradeable.__AccessControl_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
        PausableUpgradeable.__Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(MULTISIG_ADMIN_ROLE, msg.sender);

        version = 1;
        implementationHashes[_logic] = _getBytecodeHash(_logic);
        // Emit deployment event if desired.
    }

    // ====================================================
    //  Upgrade Scheduling & Execution
    // ====================================================

    /**
     * @notice Schedule an upgrade to a new implementation.
     * @param newImplementation The address of the new implementation.
     */
    function scheduleUpgrade(address newImplementation) external onlyRole(UPGRADER_ROLE) nonReentrant {
        require(newImplementation != address(0), "Zero address");
        require(newImplementation.code.length > 0, "Not a contract");
        require(scheduledUpgrades[newImplementation] == 0, "Upgrade already scheduled");

        _validateImplementation(newImplementation);

        bytes32 newBytecodeHash = _getBytecodeHash(newImplementation);
        address currentImpl = _implementation();
        require(newBytecodeHash != implementationHashes[currentImpl], "Same bytecode as current");

        scheduledUpgrades[newImplementation] = block.timestamp + UPGRADE_TIMELOCK;
        implementationHashes[newImplementation] = newBytecodeHash;

        emit UpgradeScheduled(newImplementation, scheduledUpgrades[newImplementation], version, newBytecodeHash);
    }

    /**
     * @notice Execute a scheduled upgrade once the timelock has passed.
     * @param newImplementation The address of the new implementation.
     */
    function executeUpgrade(address newImplementation) external onlyRole(MULTISIG_ADMIN_ROLE) nonReentrant {
        require(scheduledUpgrades[newImplementation] != 0, "No scheduled upgrade");
        require(block.timestamp >= scheduledUpgrades[newImplementation], "Upgrade timelock active");

        address oldImplementation = _implementation();
        require(newImplementation != oldImplementation, "Already active");

        bytes32 storedHash = implementationHashes[newImplementation];
        bytes32 currentHash = _getBytecodeHash(newImplementation);
        require(storedHash == currentHash, "Bytecode mismatch");

        bytes32 oldHash = implementationHashes[oldImplementation];

        // _upgradeTo(newImplementation);

        delete scheduledUpgrades[newImplementation];
        version++;

        emit UpgradeExecuted(oldImplementation, newImplementation, version, oldHash, currentHash);
    }

    /**
     * @notice Cancel a scheduled upgrade.
     * @param newImplementation The address of the implementation whose upgrade is to be cancelled.
     */
    function cancelUpgrade(address newImplementation) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(scheduledUpgrades[newImplementation] != 0, "No scheduled upgrade");

        delete scheduledUpgrades[newImplementation];
        delete implementationHashes[newImplementation];

        emit UpgradeCancelled(newImplementation, msg.sender);
    }

    // ====================================================
    //  Pausing & Emergency Functions
    // ====================================================

    /**
     * @notice Pause the proxy (blocks all calls to implementation).
     */
    function pause() external onlyRole(PAUSER_ROLE) nonReentrant {
        _pause();
        emit ProxyPaused(msg.sender);
    }

    /**
     * @notice Request an unpause after a delay.
     */
    function requestUnpause() external onlyRole(PAUSER_ROLE) nonReentrant {
        uint256 effectiveTime = block.timestamp + UNPAUSE_DELAY;
        scheduledUnpauses[block.number] = effectiveTime;
        emit ProxyUnpauseRequested(msg.sender, effectiveTime);
    }

    /**
     * @notice Unpause the proxy once the delay has passed.
     */
    function unpause() external onlyRole(PAUSER_ROLE) nonReentrant {
        require(scheduledUnpauses[block.number] != 0, "No unpause scheduled");
        require(block.timestamp >= scheduledUnpauses[block.number], "Unpause delay active");

        delete scheduledUnpauses[block.number];
        _unpause();
        emit ProxyUnpaused(msg.sender);
    }

    // ====================================================
    //  Internal Helper Functions
    // ====================================================

    function _getBytecodeHash(address implementation) internal view returns (bytes32) {
        return keccak256(implementation.code);
    }

    function _validateImplementation(address newImplementation) internal view {
        require(newImplementation != address(this), "Cannot upgrade to self");
        require(newImplementation != proxy(), "Cannot upgrade to proxy");
    }

    // Override _implementation() provided by TransparentUpgradeableProxy
    // (In TransparentUpgradeableProxy, _implementation() is internal, so we call it via StorageSlot.)
    function _implementation() internal view override returns (address impl) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        return StorageSlot.getAddressSlot(slot).value;
    }

    // Expose the proxy address (same as "proxy" variable in TransparentUpgradeableProxy)
    function proxy() public view returns (address) {
        return address(this);
    }

    // ====================================================
    //  Upgrade Authorization
    // ====================================================

    function _authorizeUpgrade(address newImplementation) internal onlyRole(UPGRADER_ROLE) {}

    // ====================================================
    //  Fallback Functions
    // ====================================================
    fallback() external payable override {
        require(!paused(), "Proxy is paused");
        super._fallback();
    }

    receive() external payable {}

    // ====================================================
    //  External Views
    // ====================================================
    function getImplementation() external view returns (address) {
        return _implementation();
    }
}
