// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "./IAntiBot.sol";

/**
 * @title AntiBot - TerraStake Security Module v3.0
 * @notice Protects against front-running, flash crashes, sandwich attacks, and excessive transactions.
 * - Managed via TerraStake Governance DAO
 * - Dynamic Buyback Pause on Major Price Swings
 * - Flash Crash & Price Surge Prevention with Circuit Breakers
 * - Dynamic Front-Running & Adaptive Multi-TX Throttling
 * - Liquidity Locking Mechanism to Prevent Flash Loan Drains
 * - Optimized gas usage with efficient storage writes
 * - Governance exemptions with timelock and maximum limit
 * - Failsafe admin mechanism for governance continuity
 */
contract AntiBot is 
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IAntiBot
{
    // ================================
    //  Custom Errors
    // ================================
    error InvalidPriceOracle();
    error TransactionThrottled(address user, uint256 blockNumber, uint256 cooldownEnds);
    error TimelockNotExpired(address account, uint256 unlockTime);
    error InvalidLockPeriod();
    error CircuitBreakerActive();
    error CircuitBreakerNotActive();
    error OnlyRoleCanAccess(bytes32 requiredRole);
    error ZeroAddressProvided();
    error InvalidThresholdValue();
    error MaxGovernanceExemptionsReached();
    error NotAuthorized();
    error GovernanceStillActive();
    error FailsafeModeInactive();
    error FailsafeModeAlreadyActive();

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

    // ================================
    //  Dynamic Throttling Parameters
    // ================================
    uint256 public baseMultiplier = 12; // Base multiplier for cooldown periods
    uint256 public rapidTransactionThreshold = 5; // Number of transactions in short period to trigger multiplier increase
    uint256 public rapidTransactionWindow = 5 minutes; // Time window for rapid transaction detection
    uint256 public maxMultiplier = 60; // Maximum multiplier (5 minutes at 12 seconds per block)

    // ================================
    //  Price Surge Parameters
    // ================================
    uint256 public priceSurgeThreshold = 10; // 10% sudden price increase
    bool public isPriceSurgeActive = false;
    uint256 public surgeCooldownPeriod = 30 minutes;
    uint256 public lastSurgeTime;

    // ================================
    //  Failsafe Admin Parameters
    // ================================
    uint256 public governanceInactivityThreshold = 30 days;
    uint256 public lastGovernanceActivity;
    address public failsafeAdmin;
    bool public failsafeMode = false;

    // ================================
    //  Mappings
    // ================================
    mapping(address => uint256) private userCooldown;
    mapping(address => uint256) private userTransactionCount;
    mapping(address => uint256) private lastTransactionTime;
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
    event CircuitBreakerReset(bytes32 indexed callerRole);
    event EmergencyCircuitBreakerReset(address indexed admin, bytes32 indexed callerRole);
    event AddressExempted(address indexed account);
    event ExemptionRevoked(address indexed account, bytes32 indexed callerRole);
    event TrustedContractAdded(address indexed contractAddress);
    event TrustedContractRemoved(address indexed contractAddress, bytes32 indexed callerRole);
    event PriceImpactThresholdUpdated(uint256 newThreshold);
    event CircuitBreakerThresholdUpdated(uint256 newThreshold);
    event LiquidityLockPeriodUpdated(uint256 newPeriod);
    event GovernanceExemptionRequested(address indexed account, uint256 unlockTime);
    event GovernanceExemptionApproved(address indexed account, bytes32 indexed callerRole);
    event PriceMonitoringUpdated(uint256 timestamp, int256 oldPrice, int256 newPrice);
    event PriceCheckCooldownUpdated(uint256 newCooldown);
    event PriceSurgeDetected(bool status, int256 priceChange);
    event PriceSurgeReset(bytes32 indexed callerRole);
    event FailsafeAdminUpdated(address indexed admin);
    event FailsafeModeActivated(address indexed activator);
    event FailsafeModeDeactivated(address indexed deactivator);
    event DynamicThrottlingUpdated(uint256 baseMultiplier, uint256 rapidThreshold, uint256 window, uint256 maxMultiplier);
    event PriceSurgeThresholdUpdated(uint256 newThreshold, uint256 newCooldown);
    event GovernanceInactivityThresholdUpdated(uint256 newThreshold);
    event UserThrottled(address indexed user, uint256 multiplier, uint256 cooldownEnds);

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
        lastGovernanceActivity = block.timestamp;
        
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
            uint256 threshold = blockThreshold; // Fixed: Always use blockThreshold
            
            // Calculate dynamic multiplier based on transaction frequency
            uint256 multiplier = baseMultiplier;
            uint256 txCount = userTransactionCount[from];
            uint256 timeSinceLastTx = block.timestamp - lastTransactionTime[from];
            
            // If user is making frequent transactions, increase the multiplier
            if (txCount > 0 && timeSinceLastTx < rapidTransactionWindow) {
                txCount++;
                if (txCount >= rapidTransactionThreshold) {
                    // Exponential backoff for repeated rapid transactions
                    // Fixed: Use SafeMath-like approach to prevent overflow
                    uint256 factor = 1 + ((txCount - rapidTransactionThreshold + 1) / 2);
                    multiplier = baseMultiplier * factor;
                    if (multiplier > maxMultiplier) multiplier = maxMultiplier;
                }
            } else {
                // Reset counter if sufficient time has passed
                txCount = 1;
            }
            
            if (block.timestamp <= cooldown + (threshold * multiplier)) {
                uint256 cooldownEnds = cooldown + (threshold * multiplier);
                emit UserThrottled(from, multiplier, cooldownEnds);
                revert TransactionThrottled(from, block.number, cooldownEnds);
            }
            
            // Update state variables
            userCooldown[from] = block.timestamp;
            userTransactionCount[from] = txCount;
            lastTransactionTime[from] = block.timestamp;
        }
        _;
    }

    modifier circuitBreakerCheck() {
        if (isCircuitBreakerTriggered || isPriceSurgeActive) revert CircuitBreakerActive();
        _;
    }

    modifier failsafeOrGovernance() {
        if (!hasRole(GOVERNANCE_ROLE, msg.sender) && 
            !(failsafeMode && msg.sender == failsafeAdmin)) {
            revert NotAuthorized();
        }
        _;
        
        // Update governance activity timestamp if called by governance
        if (hasRole(GOVERNANCE_ROLE, msg.sender)) {
            lastGovernanceActivity = block.timestamp;
        }
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
    function updateBlockThreshold(uint256 newThreshold) external failsafeOrGovernance {
        blockThreshold = newThreshold;
        emit BlockThresholdUpdated(newThreshold);
    }

    /**
     * @notice Updates dynamic throttling parameters
     * @param _baseMultiplier Base multiplier for cooldown
     * @param _rapidThreshold Number of transactions to trigger increased throttling
     * @param _window Time window for rapid transaction detection (in seconds)
     * @param _maxMultiplier Maximum throttling multiplier
     */
    function updateDynamicThrottling(
        uint256 _baseMultiplier,
        uint256 _rapidThreshold,
        uint256 _window,
        uint256 _maxMultiplier
    ) external failsafeOrGovernance {
        require(_baseMultiplier > 0, "Base multiplier must be positive");
        require(_rapidThreshold > 1, "Rapid threshold must be > 1");
        require(_window > 0, "Window must be positive");
        require(_maxMultiplier >= _baseMultiplier, "Max multiplier must be >= base");
        
        baseMultiplier = _baseMultiplier;
        rapidTransactionThreshold = _rapidThreshold;
        rapidTransactionWindow = _window;
        maxMultiplier = _maxMultiplier;
        
        emit DynamicThrottlingUpdated(_baseMultiplier, _rapidThreshold, _window, _maxMultiplier);
    }

    /**
     * @notice Adds a trusted contract.
     * @param contractAddress Contract address.
     */
    function addTrustedContract(address contractAddress) external failsafeOrGovernance {
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
    function removeTrustedContract(address contractAddress) external failsafeOrGovernance {
        // Optimized SSTORE: Only write if the value exists
        if(trustedContracts[contractAddress]){
            delete trustedContracts[contractAddress];
            emit TrustedContractRemoved(contractAddress, GOVERNANCE_ROLE);
        }
    }

    // ================================
    //  Price-Based Protection
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
        
        // Fixed: Add safety check to prevent division by zero
        if (lastCheckedPrice == 0) {
            lastCheckedPrice = currentPrice;
            lastPriceCheckTime = currentTime;
            emit PriceMonitoringUpdated(currentTime, 0, currentPrice);
            return;
        }
        
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
        
        // Check for price drops (negative change)
        if (priceChange < -int256(priceImpactThreshold)) {
            if (!isBuybackPaused) { // Optimized SSTORE: Only write if changed
                isBuybackPaused = true;
                emit BuybackPaused(true);
            }
        } else if (isBuybackPaused && priceChange >= 0) {
            isBuybackPaused = false; // No need to check, always change if reached here
            emit BuybackPaused(false);
        }
        
        // Check for price surges (positive change)
        if (priceChange > int256(priceSurgeThreshold)) {
            if (!isPriceSurgeActive) {
                isPriceSurgeActive = true;
                lastSurgeTime = currentTime;
                emit PriceSurgeDetected(true, priceChange);
            }
        } else if (isPriceSurgeActive && currentTime > lastSurgeTime + surgeCooldownPeriod) {
            // Auto-reset after cooldown period
            isPriceSurgeActive = false;
            emit PriceSurgeReset(bytes32(0)); // 0 indicates auto-reset
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
    function resetCircuitBreaker() external failsafeOrGovernance {
        // Optimized SSTORE: Only write if changed
        if(isCircuitBreakerTriggered){
            isCircuitBreakerTriggered = false;
            emit CircuitBreakerReset(GOVERNANCE_ROLE);
        }
    }
    
    /**
     * @notice Resets the price surge circuit breaker.
     */
    function resetPriceSurgeBreaker() external failsafeOrGovernance {
        if (isPriceSurgeActive) {
            isPriceSurgeActive = false;
            emit PriceSurgeReset(GOVERNANCE_ROLE);
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
    function updatePriceImpactThreshold(uint256 newThreshold) external failsafeOrGovernance {
        if (newThreshold == 0 || newThreshold >= 50) revert InvalidThresholdValue();
        priceImpactThreshold = newThreshold;
        emit PriceImpactThresholdUpdated(newThreshold);
    }

    /**
     * @notice Updates circuit breaker threshold.
     * @param newThreshold New threshold.
     */
    function updateCircuitBreakerThreshold(uint256 newThreshold) external failsafeOrGovernance {
        circuitBreakerThreshold = newThreshold;
        emit CircuitBreakerThresholdUpdated(newThreshold);
    }
    
    /**
     * @notice Updates price surge threshold and cooldown period.
     * @param newThreshold New threshold for price surges.
     * @param newCooldown New cooldown period after a surge.
     */
    function updatePriceSurgeParameters(uint256 newThreshold, uint256 newCooldown) external failsafeOrGovernance {
        if (newThreshold == 0) revert InvalidThresholdValue();
        priceSurgeThreshold = newThreshold;
        surgeCooldownPeriod = newCooldown;
        emit PriceSurgeThresholdUpdated(newThreshold, newCooldown);
    }

    /**
     * @notice Updates price check cooldown.
     * @param newCooldown New cooldown.
     */
    function updatePriceCheckCooldown(uint256 newCooldown) external failsafeOrGovernance {
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
    function lockLiquidity(address user) external failsafeOrGovernance {
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
    function updateLiquidityLockPeriod(uint256 newPeriod) external failsafeOrGovernance {
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
    function requestGovernanceExemption(address account) external failsafeOrGovernance {
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
    function approveGovernanceExemption(address account) external failsafeOrGovernance {
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
    function revokeExemption(address account) external failsafeOrGovernance {
        // Fixed: Check if the account has the BOT_ROLE before revoking and decrementing
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
    function setAntibotEnabled(bool enabled) external failsafeOrGovernance {
        // Optimized SSTORE: Only write if changed
        if(isAntibotEnabled != enabled){
            isAntibotEnabled = enabled;
            emit AntibotStatusUpdated(enabled);
        }
    }
    
    // ================================
    //  Failsafe Admin Mechanism
    // ================================
    
    /**
     * @notice Sets the failsafe admin address
     * @param admin The address to set as failsafe admin
     */
    function setFailsafeAdmin(address admin) external onlyRole(GOVERNANCE_ROLE) {
        if (admin == address(0)) revert ZeroAddressProvided();
        failsafeAdmin = admin;
        emit FailsafeAdminUpdated(admin);
    }
    
    /**
     * @notice Updates the governance inactivity threshold
     * @param newThreshold New threshold in seconds
     */
    function updateGovernanceInactivityThreshold(uint256 newThreshold) external onlyRole(GOVERNANCE_ROLE) {
        if (newThreshold < 1 days) revert InvalidThresholdValue();
        governanceInactivityThreshold = newThreshold;
        emit GovernanceInactivityThresholdUpdated(newThreshold);
    }
    
    /**
     * @notice Activates failsafe mode if governance has been inactive
     */
    function activateFailsafeMode() external {
        if (msg.sender != failsafeAdmin) revert NotAuthorized();
        if (block.timestamp <= lastGovernanceActivity + governanceInactivityThreshold) revert GovernanceStillActive();
        if (failsafeMode) revert FailsafeModeAlreadyActive();
        
        failsafeMode = true;
        emit FailsafeModeActivated(msg.sender);
    }
    
    /**
     * @notice Deactivates failsafe mode (only governance can do this)
     */
    function deactivateFailsafeMode() external onlyRole(GOVERNANCE_ROLE) {
        if (!failsafeMode) revert FailsafeModeInactive();
        
        failsafeMode = false;
        lastGovernanceActivity = block.timestamp;
        emit FailsafeModeDeactivated(msg.sender);
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
     * @return currentMultiplier Current throttling multiplier for the user
     */
    function getUserCooldownStatus(address user) external view returns (
        uint256 blockNum,
        uint256 threshold,
        bool canTransact,
        uint256 currentMultiplier
    ) {
        blockNum = userCooldown[user];
        // Fixed: Always use blockThreshold instead of userCooldown
        threshold = blockThreshold;
        
        // Calculate current multiplier
        uint256 multiplier = baseMultiplier;
        uint256 txCount = userTransactionCount[user];
        uint256 timeSinceLastTx = block.timestamp - lastTransactionTime[user];
        if (txCount > 0 && timeSinceLastTx < rapidTransactionWindow) {
            if (txCount >= rapidTransactionThreshold) {
                // Fixed: Use safer calculation to prevent overflow
                uint256 factor = 1 + ((txCount - rapidTransactionThreshold + 1) / 2);
                multiplier = baseMultiplier * factor;
                if (multiplier > maxMultiplier) multiplier = maxMultiplier;
            }
        }
        
        canTransact = block.timestamp > userCooldown[user] + (threshold * multiplier) || _isExempt(user);
        return (blockNum, threshold, canTransact, multiplier);
    }

    /**
     * @notice Gets price monitoring status.
     * @return lastPrice Last recorded price.
     * @return currentPrice Current oracle price.
     * @return timeSinceLastCheck Time since last check.
     * @return buybackPaused Whether buyback is paused.
     * @return circuitBroken Whether circuit breaker is triggered.
     * @return surgeBroken Whether price surge breaker is active.
     */
    function getPriceMonitoringStatus() external view returns (
        int256 lastPrice,
        int256 currentPrice,
        uint256 timeSinceLastCheck,
        bool buybackPaused,
        bool circuitBroken,
        bool surgeBroken
    ) {
        lastPrice = lastCheckedPrice;
        currentPrice = _getLatestPrice();
        timeSinceLastCheck = block.timestamp - lastPriceCheckTime; // Use block.timestamp
        buybackPaused = isBuybackPaused;
        circuitBroken = isCircuitBreakerTriggered;
        surgeBroken = isPriceSurgeActive;
        return (lastPrice, currentPrice, timeSinceLastCheck, buybackPaused, circuitBroken, surgeBroken);
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
     * @return appliedMultiplier The multiplier that would be applied
     */
    function checkWouldThrottle(address from) external view returns (
        bool wouldThrottle, 
        uint256 cooldownEnds,
        uint256 appliedMultiplier
    ) {
        if (!isAntibotEnabled || _isExempt(from)) {
            return (false, 0, 0);
        }
        
        // Use local variable to reduce SLOADs
        uint256 cooldown = userCooldown[from];
        // Fixed: Always use blockThreshold
        uint256 threshold = blockThreshold;
        
        // Calculate dynamic multiplier
        uint256 multiplier = baseMultiplier;
        uint256 txCount = userTransactionCount[from];
        uint256 timeSinceLastTx = block.timestamp - lastTransactionTime[from];
        
        if (txCount > 0 && timeSinceLastTx < rapidTransactionWindow) {
            txCount++;  // Simulate the next transaction
            if (txCount >= rapidTransactionThreshold) {
                // Fixed: Use safer calculation to prevent overflow
                uint256 factor = 1 + ((txCount - rapidTransactionThreshold + 1) / 2);
                multiplier = baseMultiplier * factor;
                if (multiplier > maxMultiplier) multiplier = maxMultiplier;
            }
        } else {
            txCount = 1;  // Reset for new transaction window
        }
        
        wouldThrottle = block.timestamp <= cooldown + (threshold * multiplier);
        cooldownEnds = cooldown + (threshold * multiplier);
        appliedMultiplier = multiplier;
        
        return (wouldThrottle, cooldownEnds, appliedMultiplier);
    }

    /**
     * @notice Gets all security thresholds.
     * @return blockLimit Block threshold.
     * @return priceImpact Price impact threshold.
     * @return circuitBreaker Circuit breaker threshold.
     * @return lockPeriod Liquidity lock period.
     * @return priceCooldown Price check cooldown.
     * @return surgeThreshold Price surge threshold.
     * @return surgeCooldown Surge cooldown period.
     */
    function getSecurityThresholds() external view returns (
        uint256 blockLimit,
        uint256 priceImpact,
        uint256 circuitBreaker,
        uint256 lockPeriod,
        uint256 priceCooldown,
        uint256 surgeThreshold,
        uint256 surgeCooldown
    ) {
        return (
            blockThreshold,
            priceImpactThreshold,
            circuitBreakerThreshold,
            liquidityLockPeriod,
            priceCheckCooldown,
            priceSurgeThreshold,
            surgeCooldownPeriod
        );
    }
    
    /**
     * @notice Gets dynamic throttling parameters
     * @return base Base multiplier
     * @return rapid Rapid transaction threshold
     * @return window Time window for rapid transactions
     * @return maxMult Maximum multiplier
     */
    function getDynamicThrottlingParams() external view returns (
        uint256 base,
        uint256 rapid,
        uint256 window,
        uint256 maxMult
    ) {
        return (
            baseMultiplier,
            rapidTransactionThreshold,
            rapidTransactionWindow,
            maxMultiplier
        );
    }
    
    /**
     * @notice Gets failsafe mechanism status
     * @return admin Failsafe admin address
     * @return isActive Whether failsafe mode is active
     * @return inactivityThreshold Governance inactivity threshold
     * @return lastActivity Last governance activity timestamp
     * @return timeUntilFailsafe Time until failsafe can be activated
     */
    function getFailsafeStatus() external view returns (
        address admin,
        bool isActive,
        uint256 inactivityThreshold,
        uint256 lastActivity,
        uint256 timeUntilFailsafe
    ) {
        uint256 timeUntil = 0;
        if (block.timestamp < lastGovernanceActivity + governanceInactivityThreshold) {
            timeUntil = lastGovernanceActivity + governanceInactivityThreshold - block.timestamp;
        }
        
        return (
            failsafeAdmin,
            failsafeMode,
            governanceInactivityThreshold,
            lastGovernanceActivity,
            timeUntil
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
        nonReentrant  // Fixed: Added nonReentrant modifier for consistency
        returns (bool isValid)
    {
        // Transaction passed all checks
        return true;
    }

    /**
     * @notice Manual force check for circuit breaker.
     */
    function forceCheckCircuitBreaker() external onlyRole(TRANSACTION_MONITOR_ROLE) nonReentrant {
        int256 currentPrice = _getLatestPrice();
        
        // Fixed: Add safety check to prevent division by zero
        if (lastCheckedPrice == 0) {
            lastCheckedPrice = currentPrice;
            lastPriceCheckTime = block.timestamp;
            emit PriceMonitoringUpdated(block.timestamp, 0, currentPrice);
            return;
        }
        
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
        
        // Also check for price surges
        if (priceChange > int256(priceSurgeThreshold)) {
            if (!isPriceSurgeActive) {
                isPriceSurgeActive = true;
                lastSurgeTime = currentTime;
                emit PriceSurgeDetected(true, priceChange);
            }
        }
    }
    
    /**
     * @notice Resets a user's transaction count and cooldown
     * @param user The user address to reset
     */
    function resetUserThrottling(address user) external failsafeOrGovernance {
        if (user == address(0)) revert ZeroAddressProvided();
        
        userTransactionCount[user] = 0;
        userCooldown[user] = 0;
        lastTransactionTime[user] = 0;
    }
    
    /**
     * @notice Batch reset user throttling for multiple addresses
     * @param users Array of user addresses to reset
     */
    function batchResetUserThrottling(address[] calldata users) external failsafeOrGovernance {
        for (uint256 i = 0; i < users.length; i++) {
            if (users[i] == address(0)) continue;
            
            userTransactionCount[users[i]] = 0;
            userCooldown[users[i]] = 0;
            lastTransactionTime[users[i]] = 0;
        }
    }
}