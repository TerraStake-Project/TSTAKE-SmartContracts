// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title AntiBot - TerraStake Security Module v2.1
 * @notice Protects against front-running, flash crashes, sandwich attacks, and excessive transactions.
 * ✅ Managed via TerraStake Governance DAO
 * ✅ Dynamic Buyback Pause on Major Price Swings
 * ✅ Flash Crash Prevention & Circuit Breaker for Price Drops
 * ✅ Front-Running & Adaptive Multi-TX Throttling
 * ✅ Liquidity Locking Mechanism to Prevent Flash Loan Drains
 */
contract AntiBot is AccessControl, ReentrancyGuard {
    // ================================
    // 🔹 Custom Errors
    // ================================
    error InvalidPriceOracle();
    error TransactionThrottled(address user, uint256 cooldownEnds);
    error TimelockNotExpired(address account, uint256 unlockTime);
    error InvalidLockPeriod();
    error CircuitBreakerActive();
    error CircuitBreakerNotActive();
    error OnlyRoleCanAccess(bytes32 requiredRole);
    error ZeroAddressProvided();
    error InvalidThresholdValue();

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
    uint256 public priceCheckCooldown = 5 minutes; // Minimum time between price checks

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
    event CircuitBreakerTriggered(bool status, int256 priceChange);
    event CircuitBreakerReset();
    event EmergencyCircuitBreakerReset(address indexed admin);
    event AddressExempted(address indexed account);
    event ExemptionRevoked(address indexed account);
    event TransactionThrottled(address indexed from, uint256 blockNumber, uint256 cooldownEnds);
    event TrustedContractAdded(address indexed contractAddress);
    event TrustedContractRemoved(address indexed contractAddress);
    event PriceImpactThresholdUpdated(uint256 newThreshold);
    event CircuitBreakerThresholdUpdated(uint256 newThreshold);
    event LiquidityLockPeriodUpdated(uint256 newPeriod);
    event GovernanceExemptionRequested(address indexed account, uint256 unlockTime);
    event GovernanceExemptionApproved(address indexed account);
    event PriceMonitoringUpdated(uint256 timestamp, int256 oldPrice, int256 newPrice);
    event PriceCheckCooldownUpdated(uint256 newCooldown);

    constructor(address governanceContract, address stakingContract, address _priceOracle) {
        if (_priceOracle == address(0)) revert InvalidPriceOracle();
        if (governanceContract == address(0)) revert ZeroAddressProvided();
        if (stakingContract == address(0)) revert ZeroAddressProvided();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, governanceContract);  
        _grantRole(STAKING_CONTRACT_ROLE, stakingContract);
        _grantRole(CONFIG_MANAGER_ROLE, msg.sender);

        priceOracle = AggregatorV3Interface(_priceOracle);
        lastCheckedPrice = _getLatestPrice();
        lastPriceCheckTime = block.timestamp;

        // Exempt core contracts from antibot measures
        trustedContracts[governanceContract] = true;
        trustedContracts[stakingContract] = true;

        emit GovernanceExemptionApproved(governanceContract);
        emit GovernanceExemptionApproved(stakingContract);
    }

    // ================================
    // 🔹 Transaction Throttling
    // ================================
    modifier checkThrottle(address from) {
        if (isAntibotEnabled && !_isExempt(from)) {
            uint256 threshold = userCooldown[from] > 0 ? userCooldown[from] : blockThreshold;
            if (block.number <= userCooldown[from] + threshold) {
                uint256 cooldownEnds = (userCooldown[from] + threshold) * 12; // Approximate seconds (12 sec/block)
                emit TransactionThrottled(from, block.number, cooldownEnds);
                revert TransactionThrottled(from, cooldownEnds);
            }
            userCooldown[from] = block.number;
        }
        _;
    }
    
    modifier circuitBreakerCheck() {
        if (isCircuitBreakerTriggered) revert CircuitBreakerActive();
        _;
    }

    /**
     * @notice Updates the block threshold that determines transaction frequency limits
     * @param newThreshold Number of blocks before a user can make another transaction
     */
    function updateBlockThreshold(uint256 newThreshold) external onlyRole(GOVERNANCE_ROLE) {
        blockThreshold = newThreshold;
        emit BlockThresholdUpdated(newThreshold);
    }

    /**
     * @notice Adds a trusted contract that will be exempt from transaction throttling
     * @param contractAddress Address of the contract to exempt
     */
    function addTrustedContract(address contractAddress) external onlyRole(GOVERNANCE_ROLE) {
        if (contractAddress == address(0)) revert ZeroAddressProvided();
        trustedContracts[contractAddress] = true;
        emit TrustedContractAdded(contractAddress);
    }

    /**
     * @notice Removes a contract from the trusted list
     * @param contractAddress Address of the contract to remove exemption
     */
    function removeTrustedContract(address contractAddress) external onlyRole(GOVERNANCE_ROLE) {
        delete trustedContracts[contractAddress];
        emit TrustedContractRemoved(contractAddress);
    }

    // ================================
    // 🔹 Price-Based Buyback Protection
    // ================================
    
    /**
     * @notice Gets the latest price from Chainlink oracle
     * @return Latest price from the oracle
     */
    function _getLatestPrice() internal view returns (int256) {
        (, int256 price, , , ) = priceOracle.latestRoundData();
        return price;
    }

    /**
     * @notice Checks price impact and may pause buybacks if threshold is exceeded
     */
    function checkPriceImpact() external nonReentrant {
        if (block.timestamp < lastPriceCheckTime + priceCheckCooldown) return;
        
        int256 currentPrice = _getLatestPrice();
        int256 priceChange = ((currentPrice - lastCheckedPrice) * 100) / lastCheckedPrice;
        
        int256 oldPrice = lastCheckedPrice;
        lastCheckedPrice = currentPrice;
        lastPriceCheckTime = block.timestamp;
        
        emit PriceMonitoringUpdated(block.timestamp, oldPrice, currentPrice);

        if (priceChange < -int256(priceImpactThreshold)) {
            isBuybackPaused = true;
            emit BuybackPaused(true);
        } else if (isBuybackPaused && priceChange >= 0) {
            isBuybackPaused = false;
            emit BuybackPaused(false);
        }
        
        _checkCircuitBreaker(currentPrice, priceChange);
    }

    /**
     * @notice Internal function to check if circuit breaker should be triggered
     * @param currentPrice Current price from oracle
     * @param priceChange Percentage price change
     */
    function _checkCircuitBreaker(int256 currentPrice, int256 priceChange) internal {
        if (priceChange < -int256(circuitBreakerThreshold)) {
            isCircuitBreakerTriggered = true;
            emit CircuitBreakerTriggered(true, priceChange);
        }
    }

    /**
     * @notice Resets the circuit breaker (governance only)
     */
    function resetCircuitBreaker() external onlyRole(GOVERNANCE_ROLE) {
        isCircuitBreakerTriggered = false;
        emit CircuitBreakerReset();
    }

    /**
     * @notice Emergency function to reset circuit breaker
     */
    function emergencyResetCircuitBreaker() external {
        if (!hasRole(GOVERNANCE_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert OnlyRoleCanAccess(GOVERNANCE_ROLE);
        }
        if (!isCircuitBreakerTriggered) {
            revert CircuitBreakerNotActive();
        }
        
        isCircuitBreakerTriggered = false;
        emit EmergencyCircuitBreakerReset(msg.sender);
    }

    /**
     * @notice Updates the price impact threshold that triggers buyback pauses
     * @param newThreshold New threshold percentage (e.g. 5 for 5%)
     */
    function updatePriceImpactThreshold(uint256 newThreshold) external onlyRole(GOVERNANCE_ROLE) {
        if (newThreshold == 0 || newThreshold >= 50) revert InvalidThresholdValue();
        priceImpactThreshold = newThreshold;
        emit PriceImpactThresholdUpdated(newThreshold);
    }

    /**
     * @notice Updates the circuit breaker threshold
     * @param newThreshold New threshold percentage (e.g. 15 for 15%)
     */
    function updateCircuitBreakerThreshold(uint256 newThreshold) external onlyRole(GOVERNANCE_ROLE) {
        circuitBreakerThreshold = newThreshold;
        emit CircuitBreakerThresholdUpdated(newThreshold);
    }
    
    /**
     * @notice Updates cooldown period between price checks
     * @param newCooldown New cooldown period in seconds
     */
    function updatePriceCheckCooldown(uint256 newCooldown) external onlyRole(GOVERNANCE_ROLE) {
        priceCheckCooldown = newCooldown;
        emit PriceCheckCooldownUpdated(newCooldown);
    }

    // ================================
    // 🔹 Liquidity Lock Mechanism
    // ================================
    
    /**
     * @notice Locks liquidity for a user for the set lock period
     * @param user Address of the user to lock
     */
    function lockLiquidity(address user) external onlyRole(GOVERNANCE_ROLE) {
        if (user == address(0)) revert ZeroAddressProvided();
        liquidityInjectionTimestamp[user] = block.timestamp + liquidityLockPeriod;
    }

    /**
     * @notice Checks if a user can withdraw liquidity
     * @param user Address to check
     * @return Whether the user can withdraw liquidity
     */
    function canWithdrawLiquidity(address user) external view returns (bool) {
        return block.timestamp >= liquidityInjectionTimestamp[user];
    }

    /**
     * @notice Updates the liquidity lock period
     * @param newPeriod New lock period in seconds
     */
    function updateLiquidityLockPeriod(uint256 newPeriod) external onlyRole(GOVERNANCE_ROLE) {
        if (newPeriod == 0) revert InvalidLockPeriod();
        liquidityLockPeriod = newPeriod;
        emit LiquidityLockPeriodUpdated(newPeriod);
    }

    // ================================
    // 🔹 Governance Exemptions (Timelocked)
    // ================================
    
    /**
     * @notice Requests a governance exemption for an account
     * @param account Address to exempt
     */
    function requestGovernanceExemption(address account) external onlyRole(GOVERNANCE_ROLE) {
        if (account == address(0)) revert ZeroAddressProvided();
        uint256 unlockTime = block.timestamp + 24 hours;
        pendingExemptions[account] = GovernanceRequest(account, unlockTime);
        emit GovernanceExemptionRequested(account, unlockTime);
    }

    /**
     * @notice Approves a pending governance exemption after timelock
     * @param account Address to approve
     */
    function approveGovernanceExemption(address account) external onlyRole(GOVERNANCE_ROLE) {
        GovernanceRequest memory request = pendingExemptions[account];
        if (block.timestamp < request.unlockTime) revert TimelockNotExpired(account, request.unlockTime);
        
        _grantRole(BOT_ROLE, account);
        delete pendingExemptions[account];
        emit GovernanceExemptionApproved(account);
    }
    
    /**
     * @notice Revokes an exemption
     * @param account Address to revoke exemption from
     */
    function revokeExemption(address account) external onlyRole(GOVERNANCE_ROLE) {
        _revokeRole(BOT_ROLE, account);
        emit ExemptionRevoked(account);
    }

    /**
     * @notice Toggles the antibot protections on or off
     * @param enabled Whether antibot should be enabled
     */
    function setAntibotEnabled(bool enabled) external onlyRole(GOVERNANCE_ROLE) {
        isAntibotEnabled = enabled;
        emit AntibotStatusUpdated(enabled);
    }
    
    // ================================
    // 🔹 Helper Functions
    // ================================
    
    /**
     * @notice Checks if an address is exempt from throttling
     * @param account Address to check
     * @return True if the address is exempt
     */
    function _isExempt(address account) internal view returns (bool) {
        return trustedContracts[account] || 
               hasRole(STAKING_CONTRACT_ROLE, account) || 
               hasRole(GOVERNANCE_ROLE, account) || 
               hasRole(BOT_ROLE, account);
    }
    
    /**
     * @notice External function to check if an address is exempt
     * @param account Address to check
     * @return True if the address is exempt
     */
    function isExempt(address account) external view returns (bool) {
        return _isExempt(account);
    }
    
    /**
     * @notice Gets the cooldown status for a user
     * @param user Address to check
     * @return blockNum The block when cooldown was set
     * @return threshold The block threshold for this user
     * @return canTransact Whether the user can transact now
     */
    function getUserCooldownStatus(address user) external view returns (
        uint256 blockNum,
        uint256 threshold,
        bool canTransact
    ) {
        blockNum = userCooldown[user];
        threshold = blockNum > 0 ? userCooldown[user] : blockThreshold;
        canTransact = block.number > userCooldown[user] + threshold || _isExempt(user);
        
        return (blockNum, threshold, canTransact);
    }
    
    /**
     * @notice Gets the current status of price monitoring
     * @return lastPrice Last recorded price
     * @return currentPrice Current oracle price
     * @return timeSinceLastCheck Time since last check in seconds
     * @return buybackPaused Whether buyback is paused
     * @return circuitBroken Whether circuit breaker is triggered
     */
    function getPriceMonitoringStatus() external view returns (
        int256 lastPrice,
        int256 currentPrice,
        uint256 timeSinceLastCheck,
        bool buybackPaused,
        bool circuitBroken
    ) {
        lastPrice = lastCheckedPrice;
        currentPrice = _getLatestPrice();
        timeSinceLastCheck = block.timestamp - lastPriceCheckTime;
        buybackPaused = isBuybackPaused;
        circuitBroken = isCircuitBreakerTriggered;
        
        return (lastPrice, currentPrice, timeSinceLastCheck, buybackPaused, circuitBroken);
    }
    
    /**
     * @notice Gets the liquidity lock status for a user
     * @param user Address to check
     * @return lockUntil Timestamp when the lock expires
     * @return isLocked Whether the user is currently locked
     * @return remainingTime Time remaining in seconds
     */
    function getLiquidityLockStatus(address user) external view returns (
        uint256 lockUntil,
        bool isLocked,
        uint256 remainingTime
    ) {
        lockUntil = liquidityInjectionTimestamp[user];
        isLocked = block.timestamp < lockUntil;
        remainingTime = isLocked ? lockUntil - block.timestamp : 0;
        
        return (lockUntil, isLocked, remainingTime);
    }
    
    /**
     * @notice Checks if a transaction would be throttled
     * @param from Address to check
     * @return wouldThrottle Whether the transaction would be throttled
     * @return cooldownEnds Block number when cooldown ends
     */
    function checkWouldThrottle(address from) external view returns (bool wouldThrottle, uint256 cooldownEnds) {
        if (!isAntibotEnabled || _isExempt(from)) {
            return (false, 0);
        }
        
        uint256 threshold = userCooldown[from] > 0 ? userCooldown[from] : blockThreshold;
        wouldThrottle = block.number <= userCooldown[from] + threshold;
        cooldownEnds = userCooldown[from] + threshold;
        
        return (wouldThrottle, cooldownEnds);
    }
    
    /**
     * @notice Gets all security thresholds in one call
     * @return blockLimit Block threshold for transaction throttling
     * @return priceImpact Price impact threshold for buyback pause
     * @return circuitBreaker Circuit breaker threshold
     * @return lockPeriod Liquidity lock period
     * @return priceCooldown Price check cooldown
     */
    function getSecurityThresholds() external view returns (
        uint256 blockLimit,
        uint256 priceImpact,
        uint256 circuitBreaker,
        uint256 lockPeriod,
        uint256 priceCooldown
    ) {
        return (
            blockThreshold,
            priceImpactThreshold,
            circuitBreakerThreshold,
            liquidityLockPeriod,
            priceCheckCooldown
        );
    }
    
    /**
     * @notice Validates a transaction against antibot rules
     * @dev This function can be called from other contracts to validate transactions
     * @param sender Address initiating the transaction
     * @param amount Amount being transferred (for potential future use)
     * @return isValid Whether the transaction is valid
     */
    function validateTransaction(address sender, uint256 amount) 
        external 
        checkThrottle(sender) 
        circuitBreakerCheck 
        returns (bool isValid) 
    {
        // Transaction passed all checks if we got this far
        return true;
    }
    
    /**
     * @notice Manual force check for circuit breaker conditions
     * @dev This function allows governance to force check circuit breaker
     */
    function forceCheckCircuitBreaker() external onlyRole(TRANSACTION_MONITOR_ROLE) {
        int256 currentPrice = _getLatestPrice();
        int256 priceChange = ((currentPrice - lastCheckedPrice) * 100) / lastCheckedPrice;
        
        int256 oldPrice = lastCheckedPrice;
        lastCheckedPrice = currentPrice;
        lastPriceCheckTime = block.timestamp;
        
        emit PriceMonitoringUpdated(block.timestamp, oldPrice, currentPrice);
        
        _checkCircuitBreaker(currentPrice, priceChange);
    }
}
