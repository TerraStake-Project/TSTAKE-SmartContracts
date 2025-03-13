// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title AntiBot - TerraStake Security Module v2.2
 * @notice Protects against front-running, flash crashes, sandwich attacks, and excessive transactions.
 * - Managed via TerraStake Governance DAO
 * - Dynamic Buyback Pause on Major Price Swings
 * - Flash Crash Prevention & Circuit Breaker for Price Drops
 * - Front-Running & Adaptive Multi-TX Throttling
 * - Liquidity Locking Mechanism to Prevent Flash Loan Drains
 * - Optimized gas usage with efficient storage writes
 * - Governance exemptions with timelock and maximum limit
 */
contract AntiBot is 
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // ================================
    //  Custom Errors
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
    error MaxGovernanceExemptionsReached(); // New error for exceeding max exemptions

    // ================================
    //  Role Management
    // ================================

    bytes32 public constant BOT_ROLE = keccak256("BOT_ROLE");
    bytes32 public constant CONFIG_MANAGER_ROLE = keccak256("CONFIG_MANAGER_ROLE");
    bytes32 public constant TRANSACTION_MONITOR_ROLE = keccak256("TRANSACTION_MONITOR_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant STAKING_CONTRACT_ROLE = keccak256("STAKING_CONTRACT_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ================================
    //  Security Parameters
    // ================================

    bool public isAntibotEnabled = true;
    bool public isBuybackPaused = false;
    bool public isCircuitBreakerTriggered = false;
    uint256 public blockThreshold = 1;  // Default: 1 block limit per user
    uint256 public priceImpactThreshold = 5;  // Default: 5% price change pauses buyback
    uint256 public circuitBreakerThreshold = 15;  // Default: 15% drop halts trading
    uint256 public liquidityLockPeriod = 1 hours; // Prevents immediate liquidity withdrawal
    uint256 public priceCheckCooldown = 5 minutes; // Minimum time between price checks
    uint256 public constant MAX_GOVERNANCE_EXEMPTIONS = 5; // Maximum number of governance exemptions allowed
    uint256 public governanceExemptionCount; // Keep track of active governance exemptions

    mapping(address => uint256) private userCooldown;
    mapping(address => bool) private trustedContracts;
    mapping(address => uint256) private liquidityInjectionTimestamp;
    AggregatorV3Interface public priceOracle;
    int256 public lastCheckedPrice;
    uint256 public lastPriceCheckTime;

    struct GovernanceRequest {
        address account;
        uint256 unlockTime;
    }

    mapping(address => GovernanceRequest) public pendingExemptions;

    // ================================
    //  Events for Transparency
    // ================================

    event AntibotStatusUpdated(bool isEnabled);
    event BlockThresholdUpdated(uint256 newThreshold);
    event BuybackPaused(bool status);
    event CircuitBreakerTriggered(bool status, int256 priceChange);
    event CircuitBreakerReset(bytes32 indexed callerRole); // Log caller's role
    event EmergencyCircuitBreakerReset(address indexed admin, bytes32 indexed callerRole); // Log caller's role
    event AddressExempted(address indexed account);
    event ExemptionRevoked(address indexed account, bytes32 indexed callerRole); // Log caller's role
    event TransactionThrottled(address indexed from, uint256 blockNumber, uint256 cooldownEnds);
    event TrustedContractAdded(address indexed contractAddress);
    event TrustedContractRemoved(address indexed contractAddress, bytes32 indexed callerRole); // Log caller's role
    event PriceImpactThresholdUpdated(uint256 newThreshold);
    event CircuitBreakerThresholdUpdated(uint256 newThreshold);
    event LiquidityLockPeriodUpdated(uint256 newPeriod);
    event GovernanceExemptionRequested(address indexed account, uint256 unlockTime);
    event GovernanceExemptionApproved(address indexed account, bytes32 indexed callerRole); // Log caller's role
    event PriceMonitoringUpdated(uint256 timestamp, int256 oldPrice, int256 newPrice);
    event PriceCheckCooldownUpdated(uint256 newCooldown);
    
    // -------------------------------------------
    //  Constructor & Initializer
    // -------------------------------------------
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address governanceContract,
        address stakingContract,
        address _priceOracle
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        if (_priceOracle == address(0)) revert InvalidPriceOracle();
        if (governanceContract == address(0)) revert ZeroAddressProvided();
        if (stakingContract == address(0)) revert ZeroAddressProvided();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, governanceContract);
        _grantRole(STAKING_CONTRACT_ROLE, stakingContract);
        _grantRole(CONFIG_MANAGER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);

        priceOracle = AggregatorV3Interface(_priceOracle);
        lastCheckedPrice = _getLatestPrice();
        lastPriceCheckTime = block.timestamp;

        // Exempt core contracts from antibot measures
        trustedContracts[governanceContract] = true;
        trustedContracts[stakingContract] = true;
        governanceExemptionCount = 2; // Governance and Staking contracts are exempt

        emit GovernanceExemptionApproved(governanceContract, GOVERNANCE_ROLE);
        emit GovernanceExemptionApproved(stakingContract, STAKING_CONTRACT_ROLE);
    }

    // ================================
    //  Transaction Throttling
    // ================================

    modifier checkThrottle(address from) {
        if (isAntibotEnabled && !_isExempt(from)) {
            // Use local variable to reduce SLOADs
            uint256 cooldown = userCooldown[from];
            uint256 threshold = cooldown > 0 ? cooldown : blockThreshold;

            if (block.timestamp <= cooldown + (threshold * 12)) { // Use block.timestamp directly
                uint256 cooldownEnds = cooldown + (threshold * 12);
                emit TransactionThrottled(from, block.number, cooldownEnds);
                revert TransactionThrottled(from, cooldownEnds);
            }
            // Optimized SSTORE: Only write if the value has changed
            if(cooldown != block.timestamp){
                userCooldown[from] = block.timestamp;
            }
        }
        _;
    }

    modifier circuitBreakerCheck() {
        if (isCircuitBreakerTriggered) revert CircuitBreakerActive();
        _;
    }

    /**
     * @notice Authorize upgrade for UUPS pattern
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    /**
     * @notice Updates the block threshold.
     * @param newThreshold New block threshold.
     */
    function updateBlockThreshold(uint256 newThreshold) external onlyRole(GOVERNANCE_ROLE) {
        blockThreshold = newThreshold;
        emit BlockThresholdUpdated(newThreshold);
    }

    /**
     * @notice Adds a trusted contract.
     * @param contractAddress Contract address.
     */
    function addTrustedContract(address contractAddress) external onlyRole(GOVERNANCE_ROLE) {
        if (contractAddress == address(0)) revert ZeroAddressProvided();
        // Optimized SSTORE: Only write if the value has changed
        if(!trustedContracts[contractAddress]){
            trustedContracts[contractAddress] = true;
            emit TrustedContractAdded(contractAddress);
        }
    }

    /**
     * @notice Removes a trusted contract.
     * @param contractAddress Contract address.
     */
    function removeTrustedContract(address contractAddress) external onlyRole(GOVERNANCE_ROLE) {
        // Optimized SSTORE: Only write if the value exists
        if(trustedContracts[contractAddress]){
            delete trustedContracts[contractAddress];
            emit TrustedContractRemoved(contractAddress, GOVERNANCE_ROLE);
        }
    }

    // ================================
    //  Price-Based Buyback Protection
    // ================================
    /**
     * @notice Gets the latest price.
     * @return Latest price.
     */
    function _getLatestPrice() internal view returns (int256) {
        (, int256 price, , , ) = priceOracle.latestRoundData();
        return price;
    }

    /**
     * @notice Checks price impact.
     */
    function checkPriceImpact() external nonReentrant {
        // Use block.timestamp directly and local variables to reduce gas
        uint256 currentTime = block.timestamp;
        if (currentTime < lastPriceCheckTime + priceCheckCooldown) return;

        int256 currentPrice = _getLatestPrice();
        // Calculate price change using integers to avoid floating-point math
        int256 priceChange = ((currentPrice - lastCheckedPrice) * 100) / lastCheckedPrice;

        int256 oldPrice = lastCheckedPrice;
        // Optimized SSTOREs
        if(lastCheckedPrice != currentPrice){
            lastCheckedPrice = currentPrice;
        }
        
        if(lastPriceCheckTime != currentTime){
            lastPriceCheckTime = currentTime;
        }
        
        emit PriceMonitoringUpdated(currentTime, oldPrice, currentPrice);
        
        // Use a single if-else-if construct for efficiency
        if (priceChange < -int256(priceImpactThreshold)) {
            if (!isBuybackPaused) { // Optimized SSTORE: Only write if changed
                isBuybackPaused = true;
                emit BuybackPaused(true);
            }
        } else if (isBuybackPaused && priceChange >= 0) {
            isBuybackPaused = false; // No need to check, always change if reached here
            emit BuybackPaused(false);
        }

        _checkCircuitBreaker(currentPrice, priceChange);
    }

    /**
     * @notice Internal function to check circuit breaker.
     * @param currentPrice Current price.
     * @param priceChange Price change percentage.
     */
    function _checkCircuitBreaker(int256 currentPrice, int256 priceChange) internal {
        if (priceChange < -int256(circuitBreakerThreshold)) {
            // Optimized SSTORE: Only write if changed
            if(!isCircuitBreakerTriggered){
                isCircuitBreakerTriggered = true;
                emit CircuitBreakerTriggered(true, priceChange);
            }
        }
    }

    /**
     * @notice Resets the circuit breaker.
     */
    function resetCircuitBreaker() external onlyRole(GOVERNANCE_ROLE) {
        // Optimized SSTORE: Only write if changed
        if(isCircuitBreakerTriggered){
            isCircuitBreakerTriggered = false;
            emit CircuitBreakerReset(GOVERNANCE_ROLE);
        }
    }

    /**
     * @notice Emergency circuit breaker reset.
     */
    function emergencyResetCircuitBreaker() external {
        bytes32 callerRole = hasRole(GOVERNANCE_ROLE, msg.sender) ? GOVERNANCE_ROLE : DEFAULT_ADMIN_ROLE;
        
        if (callerRole != GOVERNANCE_ROLE && callerRole != DEFAULT_ADMIN_ROLE) {
            revert OnlyRoleCanAccess(GOVERNANCE_ROLE);
        }
        
        if (!isCircuitBreakerTriggered) {
            revert CircuitBreakerNotActive();
        }
        
        isCircuitBreakerTriggered = false; // No need to check, always change if reached here
        emit EmergencyCircuitBreakerReset(msg.sender, callerRole);
    }

    /**
     * @notice Updates price impact threshold.
     * @param newThreshold New threshold.
     */
    function updatePriceImpactThreshold(uint256 newThreshold) external onlyRole(GOVERNANCE_ROLE) {
        if (newThreshold == 0 || newThreshold >= 50) revert InvalidThresholdValue();
        priceImpactThreshold = newThreshold;
        emit PriceImpactThresholdUpdated(newThreshold);
    }

    /**
     * @notice Updates circuit breaker threshold.
     * @param newThreshold New threshold.
     */
    function updateCircuitBreakerThreshold(uint256 newThreshold) external onlyRole(GOVERNANCE_ROLE) {
        circuitBreakerThreshold = newThreshold;
        emit CircuitBreakerThresholdUpdated(newThreshold);
    }

    /**
     * @notice Updates price check cooldown.
     * @param newCooldown New cooldown.
     */
    function updatePriceCheckCooldown(uint256 newCooldown) external onlyRole(GOVERNANCE_ROLE) {
        priceCheckCooldown = newCooldown;
        emit PriceCheckCooldownUpdated(newCooldown);
    }

    // ================================
    //  Liquidity Lock Mechanism
    // ================================
    /**
     * @notice Locks liquidity.
     * @param user User address.
     */
    function lockLiquidity(address user) external onlyRole(GOVERNANCE_ROLE) {
        if (user == address(0)) revert ZeroAddressProvided();
        // Optimized SSTORE: Only write if changed
        uint256 lockTime = block.timestamp + liquidityLockPeriod;
        if(liquidityInjectionTimestamp[user] != lockTime){
           liquidityInjectionTimestamp[user] = lockTime;
        }
    }

    /**
     * @notice Checks if liquidity can be withdrawn.
     * @param user User address.
     * @return Whether liquidity can be withdrawn.
     */
    function canWithdrawLiquidity(address user) external view returns (bool) {
        return block.timestamp >= liquidityInjectionTimestamp[user]; // Use block.timestamp directly
    }

    /**
     * @notice Updates liquidity lock period.
     * @param newPeriod New period.
     */
    function updateLiquidityLockPeriod(uint256 newPeriod) external onlyRole(GOVERNANCE_ROLE) {
        if (newPeriod == 0) revert InvalidLockPeriod();
        liquidityLockPeriod = newPeriod;
        emit LiquidityLockPeriodUpdated(newPeriod);
    }

    // ================================
    //  Governance Exemptions (Timelocked)
    // ================================
    /**
     * @notice Requests governance exemption.
     * @param account Account address.
     */
    function requestGovernanceExemption(address account) external onlyRole(GOVERNANCE_ROLE) {
        if (account == address(0)) revert ZeroAddressProvided();
        // Check if maximum exemptions are reached
        if (governanceExemptionCount >= MAX_GOVERNANCE_EXEMPTIONS) {
            revert MaxGovernanceExemptionsReached();
        }
        
        uint256 unlockTime = block.timestamp + 24 hours; // Use block.timestamp directly
        pendingExemptions[account] = GovernanceRequest(account, unlockTime);
        emit GovernanceExemptionRequested(account, unlockTime);
    }

    /**
     * @notice Approves governance exemption.
     * @param account Account address.
     */
    function approveGovernanceExemption(address account) external onlyRole(GOVERNANCE_ROLE) {
        GovernanceRequest memory request = pendingExemptions[account];
        if (block.timestamp < request.unlockTime) revert TimelockNotExpired(account, request.unlockTime); // Use block.timestamp
        
        // Check if the account is already exempt
        if(!hasRole(BOT_ROLE, account)){
            _grantRole(BOT_ROLE, account);
            // Increment exemption count only if granting a new exemption
            governanceExemptionCount++;
        }
        
        delete pendingExemptions[account]; // Clear the pending request
        emit GovernanceExemptionApproved(account, GOVERNANCE_ROLE);
    }

    /**
     * @notice Revokes exemption.
     * @param account Account address.
     */
    function revokeExemption(address account) external onlyRole(GOVERNANCE_ROLE) {
        // Check if the account has the BOT_ROLE before revoking and decrementing
        if(hasRole(BOT_ROLE, account)){
            _revokeRole(BOT_ROLE, account);
            governanceExemptionCount--; // Decrement only when revoking an active exemption
        }
        
        emit ExemptionRevoked(account, GOVERNANCE_ROLE);
    }

    /**
     * @notice Toggles antibot.
     * @param enabled Whether antibot is enabled.
     */
    function setAntibotEnabled(bool enabled) external onlyRole(GOVERNANCE_ROLE) {
        // Optimized SSTORE: Only write if changed
        if(isAntibotEnabled != enabled){
            isAntibotEnabled = enabled;
            emit AntibotStatusUpdated(enabled);
        }
    }

    // ================================
    //  Helper Functions
    // ================================
    /**
     * @notice Checks if an address is exempt.
     * @param account Address to check.
     * @return True if exempt.
     */
    function _isExempt(address account) internal view returns (bool) {
        return trustedContracts[account] ||
               hasRole(STAKING_CONTRACT_ROLE, account) ||
               hasRole(GOVERNANCE_ROLE, account) ||
               hasRole(BOT_ROLE, account);
    }

    /**
     * @notice External function to check exemption.
     * @param account Address to check.
     * @return True if exempt.
     */
    function isExempt(address account) external view returns (bool) {
        return _isExempt(account);
    }

    /**
     * @notice Gets user cooldown status.
     * @param user User address.
     * @return blockNum Block cooldown was set.
     * @return threshold Block threshold.
     * @return canTransact Whether user can transact.
     */
    function getUserCooldownStatus(address user) external view returns (
        uint256 blockNum,
        uint256 threshold,
        bool canTransact
    ) {
        blockNum = userCooldown[user];
        threshold = blockNum > 0 ? userCooldown[user] : blockThreshold;
        canTransact = block.timestamp > userCooldown[user] + (threshold * 12) || _isExempt(user); // Use block.timestamp
        return (blockNum, threshold, canTransact);
    }

    /**
     * @notice Gets price monitoring status.
     * @return lastPrice Last recorded price.
     * @return currentPrice Current oracle price.
     * @return timeSinceLastCheck Time since last check.
     * @return buybackPaused Whether buyback is paused.
     * @return circuitBroken Whether circuit breaker is triggered.
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
        timeSinceLastCheck = block.timestamp - lastPriceCheckTime; // Use block.timestamp
        buybackPaused = isBuybackPaused;
        circuitBroken = isCircuitBreakerTriggered;
        return (lastPrice, currentPrice, timeSinceLastCheck, buybackPaused, circuitBroken);
    }

    /**
     * @notice Gets liquidity lock status.
     * @param user User address.
     * @return lockUntil Timestamp lock expires.
     * @return isLocked Whether user is locked.
     * @return remainingTime Time remaining.
     */
    function getLiquidityLockStatus(address user) external view returns (
        uint256 lockUntil,
        bool isLocked,
        uint256 remainingTime
    ) {
        lockUntil = liquidityInjectionTimestamp[user];
        isLocked = block.timestamp < lockUntil; // Use block.timestamp
        remainingTime = isLocked ? lockUntil - block.timestamp : 0; // Use block.timestamp
        return (lockUntil, isLocked, remainingTime);
    }

    /**
     * @notice Checks if a transaction would be throttled.
     * @param from Address to check.
     * @return wouldThrottle Whether throttled.
     * @return cooldownEnds Block cooldown ends.
     */
    function checkWouldThrottle(address from) external view returns (bool wouldThrottle, uint256 cooldownEnds) {
        if (!isAntibotEnabled || _isExempt(from)) {
            return (false, 0);
        }
        
        // Use local variable to reduce SLOADs
        uint256 cooldown = userCooldown[from];
        uint256 threshold = cooldown > 0 ? cooldown : blockThreshold;
        wouldThrottle = block.timestamp <= cooldown + (threshold * 12); // Use block.timestamp
        cooldownEnds = cooldown + (threshold * 12);
        return (wouldThrottle, cooldownEnds);
    }

    /**
     * @notice Gets all security thresholds.
     * @return blockLimit Block threshold.
     * @return priceImpact Price impact threshold.
     * @return circuitBreaker Circuit breaker threshold.
     * @return lockPeriod Liquidity lock period.
     * @return priceCooldown Price check cooldown.
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
      * @notice Validates a transaction.
      * @param sender Transaction sender.
      * @param amount Transfer amount (unused).
      * @return isValid Whether the transaction is valid.
      */
    function validateTransaction(address sender, uint256 amount)
        external
        checkThrottle(sender)
        circuitBreakerCheck
        returns (bool isValid)
    {
        // Transaction passed all checks
        return true;
    }

    /**
     * @notice Manual force check for circuit breaker.
     */
    function forceCheckCircuitBreaker() external onlyRole(TRANSACTION_MONITOR_ROLE) {
        int256 currentPrice = _getLatestPrice();
        int256 priceChange = ((currentPrice - lastCheckedPrice) * 100) / lastCheckedPrice;
        int256 oldPrice = lastCheckedPrice;
        
        // Optimized SSTOREs
        uint256 currentTime = block.timestamp;
        if(lastCheckedPrice != currentPrice){
            lastCheckedPrice = currentPrice;
        }
        
        if(lastPriceCheckTime != currentTime){
            lastPriceCheckTime = currentTime;
        }
        
        emit PriceMonitoringUpdated(currentTime, oldPrice, currentPrice);
        _checkCircuitBreaker(currentPrice, priceChange);
    }
}