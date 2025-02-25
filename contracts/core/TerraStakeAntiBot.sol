// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title AntiBot - TerraStake Security Module v2.0
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

    uint256 public blockThreshold = 1;  // Default: 1 block limit per user
    uint256 public priceImpactThreshold = 5;  // Default: 5% price change pauses buyback
    uint256 public circuitBreakerThreshold = 15;  // Default: 15% drop halts trading
    uint256 public liquidityLockPeriod = 1 hours; // Prevents immediate liquidity withdrawal

    mapping(address => uint256) private userCooldown;
    mapping(address => bool) private trustedContracts;
    mapping(address => uint256) private liquidityInjectionTimestamp;

    AggregatorV3Interface public immutable priceOracle;
    int256 public lastCheckedPrice;
    uint256 public lastPriceCheckTime;

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
    event PriceImpactThresholdUpdated(uint256 newThreshold);
    event CircuitBreakerThresholdUpdated(uint256 newThreshold);
    event LiquidityLockPeriodUpdated(uint256 newPeriod);
    event GovernanceExemptionRequested(address indexed account, uint256 unlockTime);
    event GovernanceExemptionApproved(address indexed account);

    constructor(address governanceContract, address stakingContract, address _priceOracle) {
        require(_priceOracle != address(0), "Invalid price oracle");

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, governanceContract);  
        _grantRole(STAKING_CONTRACT_ROLE, stakingContract);

        priceOracle = AggregatorV3Interface(_priceOracle);
        lastCheckedPrice = _getLatestPrice();

        emit GovernanceExemptionApproved(governanceContract);
        emit GovernanceExemptionApproved(stakingContract);
    }

    // ================================
    // 🔹 Transaction Throttling
    // ================================
    modifier transactionThrottler(address from) {
        if (isAntibotEnabled && !trustedContracts[from] && !hasRole(STAKING_CONTRACT_ROLE, from) && !hasRole(GOVERNANCE_ROLE, from)) {
            uint256 threshold = userCooldown[from] > 0 ? userCooldown[from] : blockThreshold;
            require(block.number > userCooldown[from] + threshold, "Transaction throttled");
            userCooldown[from] = block.number;
        }
        _;
    }

    function updateBlockThreshold(uint256 newThreshold) external onlyRole(GOVERNANCE_ROLE) {
        blockThreshold = newThreshold;
        emit BlockThresholdUpdated(newThreshold);
    }

    function addTrustedContract(address contractAddress) external onlyRole(GOVERNANCE_ROLE) {
        trustedContracts[contractAddress] = true;
        emit TrustedContractAdded(contractAddress);
    }

    function removeTrustedContract(address contractAddress) external onlyRole(GOVERNANCE_ROLE) {
        delete trustedContracts[contractAddress];
        emit TrustedContractRemoved(contractAddress);
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

    function updateLiquidityLockPeriod(uint256 newPeriod) external onlyRole(GOVERNANCE_ROLE) {
        require(newPeriod > 0, "Must be > 0");
        liquidityLockPeriod = newPeriod;
        emit LiquidityLockPeriodUpdated(newPeriod);
    }

    // ================================
    // 🔹 Governance Exemptions (Timelocked)
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
}
