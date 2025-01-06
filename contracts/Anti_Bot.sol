// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";

contract AntiBot is AccessControlEnumerable {
    // Roles
    bytes32 public constant BOT_ROLE = keccak256("BOT_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant CONFIG_MANAGER_ROLE = keccak256("CONFIG_MANAGER_ROLE");
    bytes32 public constant TRANSACTION_MONITOR_ROLE = keccak256("TRANSACTION_MONITOR_ROLE");

    // State Variables
    bool public isAntibotEnabled = true;
    uint256 public blockThreshold = 1; // Global block threshold
    bool public testingMode = false;

    mapping(address => uint256) private globalThresholds; // Custom thresholds for addresses
    mapping(address => bool) private trustedContracts; // Exempt trusted contracts
    mapping(address => mapping(bytes4 => bool)) private functionExemptions; // Function-level exemptions
    mapping(address => mapping(address => uint256)) private lastTransactionBlock; // Last transaction block tracking

    // User statistics
    struct ThrottleStats {
        uint256 totalTransactions;
        uint256 throttledTransactions;
    }
    mapping(address => ThrottleStats) public userStats;

    // Events
    event AntibotStatusUpdated(bool isEnabled);
    event BlockThresholdUpdated(uint256 newThreshold);
    event AddressExempted(address indexed account);
    event ExemptionRevoked(address indexed account);
    event TransactionThrottled(address indexed from, address indexed to, uint256 blockNumber);
    event TrustedContractAdded(address indexed contractAddress);
    event TrustedContractRemoved(address indexed contractAddress);
    event FunctionExempted(address indexed account, bytes4 indexed functionSignature);
    event FunctionExemptionRevoked(address indexed account, bytes4 indexed functionSignature);
    event TestingModeUpdated(bool enabled);

    constructor(address admin) {
        _setupRole(DEFAULT_ADMIN_ROLE, admin);
        _setupRole(ADMIN_ROLE, admin);
        _setupRole(CONFIG_MANAGER_ROLE, admin);
        _setupRole(TRANSACTION_MONITOR_ROLE, admin);
    }

    /**
     * @dev Modifier to throttle transactions between non-exempt addresses or functions.
     */
    modifier transactionThrottler(address from, address to, bytes4 functionSignature) {
        if (isAntibotEnabled) {
            if (
                !trustedContracts[from] &&
                !trustedContracts[to] &&
                !functionExemptions[from][functionSignature]
            ) {
                uint256 threshold = globalThresholds[from] > 0 ? globalThresholds[from] : blockThreshold;
                if (block.number <= lastTransactionBlock[from][to] + threshold) {
                    userStats[from].throttledTransactions += 1;
                    emit TransactionThrottled(from, to, block.number);

                    if (!testingMode) {
                        revert("Antibot: Transaction throttled");
                    }
                }
                lastTransactionBlock[from][to] = block.number;
            }
        }
        userStats[from].totalTransactions += 1;
        _;
    }

    /**
     * @dev Toggles the anti-bot mechanism on or off.
     */
    function toggleAntibot() external onlyRole(CONFIG_MANAGER_ROLE) {
        isAntibotEnabled = !isAntibotEnabled;
        emit AntibotStatusUpdated(isAntibotEnabled);
    }

    /**
     * @dev Updates the global block threshold for throttling transactions.
     * @param newThreshold The new global block threshold.
     */
    function updateBlockThreshold(uint256 newThreshold) external onlyRole(CONFIG_MANAGER_ROLE) {
        require(newThreshold > 0, "Antibot: Threshold must be greater than zero");
        blockThreshold = newThreshold;
        emit BlockThresholdUpdated(newThreshold);
    }

    /**
     * @dev Updates custom thresholds for specific addresses.
     * @param account The address to update the threshold for.
     * @param threshold The custom block threshold.
     */
    function updateAddressThreshold(address account, uint256 threshold) external onlyRole(CONFIG_MANAGER_ROLE) {
        require(threshold > 0, "Antibot: Threshold must be positive");
        globalThresholds[account] = threshold;
    }

    /**
     * @dev Grants BOT_ROLE to an address, exempting it from throttling.
     * @param account The address to exempt.
     */
    function exemptAddress(address account) external onlyRole(TRANSACTION_MONITOR_ROLE) {
        grantRole(BOT_ROLE, account);
        emit AddressExempted(account);
    }

    /**
     * @dev Revokes BOT_ROLE from an address, removing its exemption.
     * @param account The address to revoke.
     */
    function revokeExemption(address account) external onlyRole(TRANSACTION_MONITOR_ROLE) {
        revokeRole(BOT_ROLE, account);
        emit ExemptionRevoked(account);
    }

    /**
     * @dev Marks an address as a trusted contract exempt from throttling.
     * @param contractAddress The contract address to trust.
     */
    function addTrustedContract(address contractAddress) external onlyRole(CONFIG_MANAGER_ROLE) {
        trustedContracts[contractAddress] = true;
        emit TrustedContractAdded(contractAddress);
    }

    /**
     * @dev Removes a trusted contract from the exemption list.
     * @param contractAddress The contract address to untrust.
     */
    function removeTrustedContract(address contractAddress) external onlyRole(CONFIG_MANAGER_ROLE) {
        trustedContracts[contractAddress] = false;
        emit TrustedContractRemoved(contractAddress);
    }

    /**
     * @dev Exempts a specific function for an address.
     * @param account The address to exempt.
     * @param functionSignature The function signature to exempt.
     */
    function exemptFunction(address account, bytes4 functionSignature) external onlyRole(TRANSACTION_MONITOR_ROLE) {
        functionExemptions[account][functionSignature] = true;
        emit FunctionExempted(account, functionSignature);
    }

    /**
     * @dev Revokes a function-level exemption for an address.
     * @param account The address to revoke exemption from.
     * @param functionSignature The function signature to revoke.
     */
    function revokeFunctionExemption(address account, bytes4 functionSignature) external onlyRole(TRANSACTION_MONITOR_ROLE) {
        functionExemptions[account][functionSignature] = false;
        emit FunctionExemptionRevoked(account, functionSignature);
    }

    /**
     * @dev Enables or disables testing mode.
     * @param enabled Whether testing mode should be enabled.
     */
    function toggleTestingMode(bool enabled) external onlyRole(CONFIG_MANAGER_ROLE) {
        testingMode = enabled;
        emit TestingModeUpdated(enabled);
    }

    /**
     * @dev Checks if a transaction is throttled (for debugging or external use).
     * @param from The sender address.
     * @param to The receiver address.
     * @return Whether the transaction is throttled.
     */
    function isTransactionThrottled(address from, address to) external view returns (bool) {
        if (!isAntibotEnabled) return false;
        if (trustedContracts[from] || trustedContracts[to]) return false;
        uint256 threshold = globalThresholds[from] > 0 ? globalThresholds[from] : blockThreshold;
        return block.number <= lastTransactionBlock[from][to] + threshold;
    }
}

