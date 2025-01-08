// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";

contract AntiBot is AccessControl {
    bytes32 public constant BOT_ROLE = keccak256("BOT_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant CONFIG_MANAGER_ROLE = keccak256("CONFIG_MANAGER_ROLE");
    bytes32 public constant TRANSACTION_MONITOR_ROLE = keccak256("TRANSACTION_MONITOR_ROLE");

    bool public isAntibotEnabled = true;
    uint256 public blockThreshold = 1;
    bool public testingMode = false;

    mapping(address => uint256) private globalThresholds;
    mapping(address => bool) private trustedContracts;
    mapping(address => mapping(bytes4 => bool)) private functionExemptions;
    mapping(address => mapping(address => uint256)) private lastTransactionBlock;

    struct ThrottleStats {
        uint256 totalTransactions;
        uint256 throttledTransactions;
    }
    mapping(address => ThrottleStats) public userStats;

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
    event AddressThresholdUpdated(address indexed account, uint256 threshold);
    event BatchAddressesExempted(address[] accounts);
    event BatchExemptionsRevoked(address[] accounts);
    event BatchAddressThresholdsUpdated(address[] accounts, uint256[] thresholds);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(CONFIG_MANAGER_ROLE, admin);
        _grantRole(TRANSACTION_MONITOR_ROLE, admin);
    }

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

    function toggleAntibot() external onlyRole(CONFIG_MANAGER_ROLE) {
        isAntibotEnabled = !isAntibotEnabled;
        emit AntibotStatusUpdated(isAntibotEnabled);
    }

    function updateBlockThreshold(uint256 newThreshold) external onlyRole(CONFIG_MANAGER_ROLE) {
        require(newThreshold > 0, "Antibot: Threshold must be > 0");
        blockThreshold = newThreshold;
        emit BlockThresholdUpdated(newThreshold);
    }

    function updateAddressThreshold(address account, uint256 threshold) external onlyRole(CONFIG_MANAGER_ROLE) {
        require(threshold > 0, "Antibot: Threshold must be > 0");
        globalThresholds[account] = threshold;
        emit AddressThresholdUpdated(account, threshold);
    }

    function batchUpdateAddressThresholds(address[] calldata accounts, uint256[] calldata thresholds)
        external
        onlyRole(CONFIG_MANAGER_ROLE)
    {
        require(accounts.length == thresholds.length, "Arrays size mismatch");
        for (uint256 i = 0; i < accounts.length; ) {
            require(thresholds[i] > 0, "Antibot: Threshold must be > 0");
            globalThresholds[accounts[i]] = thresholds[i];
            unchecked { ++i; }
        }
        emit BatchAddressThresholdsUpdated(accounts, thresholds);
    }

    function exemptAddress(address account) external onlyRole(TRANSACTION_MONITOR_ROLE) {
        grantRole(BOT_ROLE, account);
        emit AddressExempted(account);
    }

    function revokeExemption(address account) external onlyRole(TRANSACTION_MONITOR_ROLE) {
        revokeRole(BOT_ROLE, account);
        emit ExemptionRevoked(account);
    }

    function batchExemptAddresses(address[] calldata accounts) external onlyRole(TRANSACTION_MONITOR_ROLE) {
        for (uint256 i = 0; i < accounts.length; ) {
            grantRole(BOT_ROLE, accounts[i]);
            unchecked { ++i; }
        }
        emit BatchAddressesExempted(accounts);
    }

    function batchRevokeExemptions(address[] calldata accounts) external onlyRole(TRANSACTION_MONITOR_ROLE) {
        for (uint256 i = 0; i < accounts.length; ) {
            revokeRole(BOT_ROLE, accounts[i]);
            unchecked { ++i; }
        }
        emit BatchExemptionsRevoked(accounts);
    }

    function addTrustedContract(address contractAddress) external onlyRole(CONFIG_MANAGER_ROLE) {
        trustedContracts[contractAddress] = true;
        emit TrustedContractAdded(contractAddress);
    }

    function removeTrustedContract(address contractAddress) external onlyRole(CONFIG_MANAGER_ROLE) {
        trustedContracts[contractAddress] = false;
        emit TrustedContractRemoved(contractAddress);
    }

    function exemptFunction(address account, bytes4 functionSignature) external onlyRole(TRANSACTION_MONITOR_ROLE) {
        functionExemptions[account][functionSignature] = true;
        emit FunctionExempted(account, functionSignature);
    }

    function revokeFunctionExemption(address account, bytes4 functionSignature) external onlyRole(TRANSACTION_MONITOR_ROLE) {
        functionExemptions[account][functionSignature] = false;
        emit FunctionExemptionRevoked(account, functionSignature);
    }

    function toggleTestingMode(bool enabled) external onlyRole(CONFIG_MANAGER_ROLE) {
        testingMode = enabled;
        emit TestingModeUpdated(enabled);
    }

    function isTransactionThrottled(address from, address to) external view returns (bool) {
        if (!isAntibotEnabled) return false;
        if (trustedContracts[from] || trustedContracts[to]) return false;

        uint256 threshold = globalThresholds[from] > 0 ? globalThresholds[from] : blockThreshold;
        return (block.number <= lastTransactionBlock[from][to] + threshold);
    }

    function exampleTransfer(address from, address to, uint256 amount, bytes4 funcSig)
        external
        transactionThrottler(from, to, funcSig)
    {
        // Your token transfer or action logic here
        // e.g., _transfer(from, to, amount);
    }
}
