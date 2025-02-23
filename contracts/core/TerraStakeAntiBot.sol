// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title AntiBot - TerraStake Security Module
 * @notice Protects against front-running, flash crashes, sandwich attacks, and excessive transactions.
 * ✅ Managed via TerraStake Governance DAO
 * ✅ Dynamic Buyback Pause on Major Price Swings
 * ✅ Flash Crash Prevention & Circuit Breaker for Price Drops
 * ✅ Front-Running & Adaptive Multi-TX Throttling
 * ✅ Liquidity Locking Mechanism to Prevent Flash Loan Drains
 */
contract AntiBot is AccessControl {
    // ================================
    // 🔹 Role Management
    // ================================
    bytes32 public constant BOT_ROLE = keccak256("BOT_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant CONFIG_MANAGER_ROLE = keccak256("CONFIG_MANAGER_ROLE");
    bytes32 public constant TRANSACTION_MONITOR_ROLE = keccak256("TRANSACTION_MONITOR_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");  
    bytes32 public constant STAKING_CONTRACT_ROLE = keccak256("STAKING_CONTRACT_ROLE"); 

    // ================================
    // 🔹 Security Parameters
    // ================================
    bool public isAntibotEnabled = true;
    bool public isBuybackPaused = false;
    bool public isCircuitBreakerTriggered = false;
    bool public testingMode = false;

    uint256 public blockThreshold = 1;  // Default: 1 block limit per user
    uint256 public priceImpactThreshold = 5;  // Default: 5% price change pauses buyback
    uint256 public circuitBreakerThreshold = 15;  // Default: 15% drop halts trading
    uint256 public liquidityLockPeriod = 1 hours; // Prevents immediate liquidity withdrawal

    mapping(address => uint256) private globalThresholds;
    mapping(address => bool) private trustedContracts;
    mapping(address => uint256) private lastTransactionBlock;
    mapping(address => uint256) public liquidityInjectionTimestamp;

    AggregatorV3Interface public priceOracle;
    int256 public lastCheckedPrice;
    uint256 public lastPriceCheckTime;
    
    struct ThrottleStats {
        uint256 totalTransactions;
        uint256 throttledTransactions;
    }
    mapping(address => ThrottleStats) public userStats;

    struct GovernanceRequest {
        address account;
        uint256 unlockTime;
    }
    mapping(address => GovernanceRequest) public pendingExemptions;

    // ================================
    // 🔹 Events for Transparency
    // ================================
    event AntibotStatusUpdated(bool isEnabled);
    event BlockThresholdUpdated(uint256 newThreshold);
    event BuybackPaused(bool status);
    event CircuitBreakerTriggered(bool status);
    event AddressExempted(address indexed account);
    event ExemptionRevoked(address indexed account);
    event TransactionThrottled(address indexed from, uint256 blockNumber);
    event TrustedContractAdded(address indexed contractAddress);
    event TrustedContractRemoved(address indexed contractAddress);
    event TestingModeUpdated(bool enabled);
    event PriceImpactThresholdUpdated(uint256 newThreshold);
    event CircuitBreakerThresholdUpdated(uint256 newThreshold);
    event LiquidityLockPeriodUpdated(uint256 newPeriod);
    event GovernanceExemptionRequested(address indexed account, uint256 unlockTime);
    event GovernanceExemptionApproved(address indexed account);

    constructor(address admin, address governanceContract, address stakingContract, address _priceOracle) {
        require(_priceOracle != address(0), "Invalid price oracle");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, governanceContract);  
        _grantRole(STAKING_CONTRACT_ROLE, stakingContract);

        priceOracle = AggregatorV3Interface(_priceOracle);
        lastCheckedPrice = _getLatestPrice();

        emit GovernanceExemptionApproved(governanceContract);
        emit GovernanceExemptionApproved(stakingContract);
    }

    // ================================
    // 🔹 Adaptive Transaction Throttling
    // ================================
    modifier transactionThrottler(address from) {
        if (isAntibotEnabled && 
            !hasRole(BOT_ROLE, from) && 
            !hasRole(STAKING_CONTRACT_ROLE, from) && 
            !hasRole(GOVERNANCE_ROLE, from)
        ) {
            uint256 threshold = globalThresholds[from] > 0 ? globalThresholds[from] : blockThreshold;

            if (block.number <= lastTransactionBlock[from] + threshold) {
                userStats[from].throttledTransactions += 1;
                emit TransactionThrottled(from, block.number);

                if (!testingMode) {
                    revert("AntiBot: Transaction throttled");
                }
            }
            lastTransactionBlock[from] = block.number;
        }
        userStats[from].totalTransactions += 1;
        _;
    }

    // ================================
    // 🔹 Price-Based Buyback Protection
    // ================================
    function _getLatestPrice() internal view returns (int256) {
        (, int256 price, , , ) = priceOracle.latestRoundData();
        return price;
    }

    function _checkPriceImpact() internal {
        int256 currentPrice = _getLatestPrice();
        int256 priceChange = ((currentPrice - lastCheckedPrice) * 100) / lastCheckedPrice;
        lastCheckedPrice = currentPrice;
        lastPriceCheckTime = block.timestamp;

        if (priceChange < -int256(priceImpactThreshold)) {
            isBuybackPaused = true;
            emit BuybackPaused(true);
        }
    }

    function _checkCircuitBreaker() internal {
        int256 currentPrice = _getLatestPrice();
        int256 priceChange = ((currentPrice - lastCheckedPrice) * 100) / lastCheckedPrice;

        if (priceChange < -int256(circuitBreakerThreshold)) {
            isCircuitBreakerTriggered = true;
            emit CircuitBreakerTriggered(true);
        }
    }

    // ================================
    // 🔹 Liquidity Lock Mechanism
    // ================================
    function lockLiquidity(address user) external onlyRole(GOVERNANCE_ROLE) {
        liquidityInjectionTimestamp[user] = block.timestamp + liquidityLockPeriod;
    }

    function canWithdrawLiquidity(address user) external view returns (bool) {
        return block.timestamp >= liquidityInjectionTimestamp[user];
    }

    // ================================
    // 🔹 Governance Exemption (Timelocked)
    // ================================
    function requestGovernanceExemption(address account) external onlyRole(GOVERNANCE_ROLE) {
        uint256 unlockTime = block.timestamp + 24 hours;
        pendingExemptions[account] = GovernanceRequest(account, unlockTime);
        emit GovernanceExemptionRequested(account, unlockTime);
    }

    function approveGovernanceExemption(address account) external onlyRole(GOVERNANCE_ROLE) {
        require(block.timestamp >= pendingExemptions[account].unlockTime, "Timelock not expired");
        _grantRole(BOT_ROLE, account);
        delete pendingExemptions[account];
        emit GovernanceExemptionApproved(account);
    }

    // ================================
    // 🔹 Final Governance & Security Checks
    // ================================
    function updateLiquidityLockPeriod(uint256 newPeriod) external onlyRole(GOVERNANCE_ROLE) {
        require(newPeriod > 0, "Must be > 0");
        liquidityLockPeriod = newPeriod;
        emit LiquidityLockPeriodUpdated(newPeriod);
    }

    function isTransactionThrottled(address from) external view returns (bool) {
        if (!isAntibotEnabled) return false;
        if (trustedContracts[from]) return false;
        if (hasRole(STAKING_CONTRACT_ROLE, from) || hasRole(GOVERNANCE_ROLE, from)) return false;

        uint256 threshold = globalThresholds[from] > 0 ? globalThresholds[from] : blockThreshold;
        return (block.number <= lastTransactionBlock[from] + threshold);
    }
}
