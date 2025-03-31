// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "../interfaces/IAPI3PriceFeed.sol";
import "../interfaces/IAntiBot.sol";

/**
 * @title AntiBot - TerraStake Security Module v4.0
 * @notice Optimized protection against front-running, flash crashes, sandwich attacks, and excessive transactions
 * - Gas-optimized storage patterns with minimal SLOADs/SSTOREs
 * - Enhanced oracle security with multi-source validation
 * - Advanced throttling with token bucket algorithm
 * - Circuit breakers with time-weighted price averaging
 * - Comprehensive attack pattern detection
 */
contract AntiBot is
    IAntiBot,
    Initializable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // ================================
    //  Custom Errors
    // ================================
    error InvalidPriceOracle();
    error InvalidPriceData();
    error TransactionThrottled(address user, uint256 cooldownEnds, uint256 multiplier);
    error TimelockNotExpired(address account, uint256 unlockTime);
    error InvalidLockPeriod();
    error CircuitBreakerActive();
    error CircuitBreakerNotActive();
    error OnlyRoleCanAccess(bytes32 requiredRole);
    error ZeroAddressProvided();
    error InvalidThresholdValue();
    error InvalidThresholdRelationship();
    error MaxGovernanceExemptionsReached();
    error NotAuthorized();
    error GovernanceStillActive();
    error FailsafeModeInactive();
    error FailsafeModeAlreadyActive();
    error RateLimitExceeded(address user, uint256 resetTime);
    error NoOracleResponse();
    error InsufficientOracleConsensus();

    // ================================
    //  Role Management - Constants
    // ================================
    bytes32 private constant BOT_ROLE = keccak256("BOT_ROLE");
    bytes32 private constant CONFIG_MANAGER_ROLE = keccak256("CONFIG_MANAGER_ROLE");
    bytes32 private constant TRANSACTION_MONITOR_ROLE = keccak256("TRANSACTION_MONITOR_ROLE");
    bytes32 private constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 private constant STAKING_CONTRACT_ROLE = keccak256("STAKING_CONTRACT_ROLE");
    bytes32 private constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ================================
    //  Security State Variables - Packed
    // ================================
    // [Slot 1]
    bool public isAntibotEnabled;
    bool public isBuybackPaused;
    bool public isCircuitBreakerTriggered;
    bool public isPriceSurgeActive;
    bool public failsafeMode;
    uint8 public governanceExemptionCount;
    uint8 public minimumOracleResponses;
    uint8 public oracleCount;

    // [Slot 2 & 3]
    uint256 public blockThreshold;
    uint256 public priceImpactThreshold;
    
    // [Slot 4 & 5]
    uint256 public circuitBreakerThreshold;
    uint256 public liquidityLockPeriod;
    
    // [Slot 6 & 7]
    uint256 public priceCheckCooldown;
    uint256 public lastPriceCheckTime;
    
    // [Slot 8 & 9]
    uint256 public baseMultiplier;
    uint256 public rapidTransactionThreshold;
    
    // [Slot 10 & 11]
    uint256 public rapidTransactionWindow;
    uint256 public maxMultiplier;
    
    // [Slot 12 & 13]
    uint256 public priceSurgeThreshold;
    uint256 public surgeCooldownPeriod;
    
    // [Slot 14 & 15]
    uint256 public lastSurgeTime;
    uint256 public governanceInactivityThreshold;
    
    // [Slot 16 & 17]
    uint256 public lastGovernanceActivity;
    int256 public lastCheckedPrice;

    // ================================
    //  Token Bucket Algorithm for Rate Limiting
    // ================================
    struct TokenBucket {
        uint128 tokens;      // Current tokens available (packed)
        uint128 capacity;    // Maximum tokens capacity (packed)
        uint128 refillRate;  // Tokens added per second (packed)
        uint128 lastRefill;  // Last refill timestamp (packed)
    }

    // ================================
    //  TWAP Implementation
    // ================================
    struct PriceObservation {
        int128 price;       // Price observation (packed)
        uint128 timestamp;  // Timestamp of observation (packed)
    }

    uint8 private constant MAX_PRICE_OBSERVATIONS = 24;
    PriceObservation[MAX_PRICE_OBSERVATIONS] private priceHistory;
    uint8 private priceHistoryCount;
    uint8 private priceHistoryIndex;

    // ================================
    //  Transaction Pattern Detection
    // ================================
    struct TransactionPattern {
        uint64 highFrequencyCount;
        uint64 suspiciousPatternCount;
        uint64 lastPatternReset;
        uint64 volumeAccumulated;
    }

    // ================================
    //  Governance Request
    // ================================
    struct GovernanceRequest {
        address account;
        uint64 unlockTime;
    }

    // ================================
    //  Storage Mappings
    // ================================
    mapping(address => uint256) private userCooldown;
    mapping(address => uint32) private userTransactionCount;
    mapping(address => uint224) private lastTransactionTime;
    mapping(address => bool) private trustedContracts;
    mapping(address => uint256) private liquidityInjectionTimestamp;
    mapping(address => GovernanceRequest) public pendingExemptions;
    mapping(address => TokenBucket) private rateLimitBuckets;
    mapping(address => TransactionPattern) private userPatterns;
    mapping(address => bool) public backupOracles;
    
    // ================================
    //  Oracle Management
    // ================================
    IAPI3PriceFeed public priceOracle;
    address[] private oracleAddresses;
    uint8 private constant MAX_ORACLE_COUNT = 5;

    // Constants
    uint8 private constant MAX_GOVERNANCE_EXEMPTIONS = 5;

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
    event OracleAdded(address indexed oracle);
    event OracleRemoved(address indexed oracle);
    event MinimumOracleResponsesUpdated(uint8 count);
    event RateLimitConfigUpdated(uint128 capacity, uint128 refillRate);
    event SuspiciousPatternDetected(address indexed user, uint64 patternCount);
    event TWAPUpdated(int256 price);

    // -------------------------------------------
    //  Constructor & Initializer
    // -------------------------------------------
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the AntiBot contract
     * @param governanceContract The governance contract address
     * @param stakingContract The staking contract address
     * @param _priceOracle The primary price oracle address
     */
    function initialize(
        address governanceContract,
        address stakingContract,
        address _priceOracle
    ) external initializer {
        __AccessControlEnumerable_init();
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
        
        // Set default values
        isAntibotEnabled = true;
        isBuybackPaused = false;
        isCircuitBreakerTriggered = false;
        isPriceSurgeActive = false;
        failsafeMode = false;
        governanceExemptionCount = 2; // Governance and Staking contracts are exempt
        minimumOracleResponses = 1;
        oracleCount = 1;
        
        blockThreshold = 1;
        priceImpactThreshold = 5;
        circuitBreakerThreshold = 15;
        liquidityLockPeriod = 1 hours;
        priceCheckCooldown = 5 minutes;
        baseMultiplier = 12;
        rapidTransactionThreshold = 5;
        rapidTransactionWindow = 5 minutes;
        maxMultiplier = 60;
        priceSurgeThreshold = 10;
        surgeCooldownPeriod = 30 minutes;
        governanceInactivityThreshold = 30 days;
        
        // Initialize oracle
        priceOracle = IAPI3PriceFeed(_priceOracle);
        oracleAddresses.push(_priceOracle);
        backupOracles[_priceOracle] = true;
        
        // Initialize price data
        lastCheckedPrice = _getLatestPrice();
        lastPriceCheckTime = block.timestamp;
        lastGovernanceActivity = block.timestamp;
        
        // Exempt core contracts from antibot measures
        trustedContracts[governanceContract] = true;
        trustedContracts[stakingContract] = true;
        
        emit GovernanceExemptionApproved(governanceContract, GOVERNANCE_ROLE);
        emit GovernanceExemptionApproved(stakingContract, STAKING_CONTRACT_ROLE);
    }

    // ================================
    //  Transaction Throttling
    // ================================
    
    /**
     * @notice Checks if a transaction should be throttled
     * @param from Address to check
     */
    modifier checkThrottle(address from) {
        if (isAntibotEnabled && !_isExempt(from)) {
            // Check rate limit first (token bucket algorithm)
            TokenBucket storage bucket = rateLimitBuckets[from];
            
            // Initialize bucket if needed
            if (bucket.capacity == 0) {
                bucket.capacity = 5;    // Allow 5 transactions in burst
                bucket.tokens = 5;      // Start with full capacity
                bucket.refillRate = 1;  // Refill 1 token per minute
                bucket.lastRefill = uint128(block.timestamp);
            } else {
                // Refill tokens based on time elapsed
                uint256 elapsed = block.timestamp - bucket.lastRefill;
                uint128 tokensToAdd = uint128((elapsed * bucket.refillRate) / 60); // Tokens per minute
                
                if (tokensToAdd > 0) {
                    bucket.tokens = uint128(min(uint256(bucket.capacity), uint256(bucket.tokens) + tokensToAdd));
                    bucket.lastRefill = uint128(block.timestamp);
                }
            }
            
            // Check if we have tokens available
            if (bucket.tokens == 0) {
                uint256 resetTime = bucket.lastRefill + (60 / bucket.refillRate);
                revert RateLimitExceeded(from, resetTime);
            }
            
            // Consume a token
            bucket.tokens--;
            
            // Check transaction multiplier-based throttling
            uint256 cooldown = userCooldown[from];
            uint256 txCount = userTransactionCount[from];
            uint256 lastTxTime = lastTransactionTime[from];
            uint256 timeSinceLastTx = block.timestamp - lastTxTime;
            
            // Calculate dynamic multiplier
            uint256 multiplier = baseMultiplier;
            if (txCount > 0 && timeSinceLastTx < rapidTransactionWindow) {
                txCount++;
                if (txCount >= rapidTransactionThreshold) {
                    uint256 factor = 1 + ((txCount - rapidTransactionThreshold + 1) / 2);
                    multiplier = baseMultiplier * factor;
                    if (multiplier > maxMultiplier) multiplier = maxMultiplier;
                }
            } else {
                // Reset counter if sufficient time has passed

                txCount = 1;
            }
            
            // Check if user is throttled
            if (block.timestamp <= cooldown + (blockThreshold * multiplier)) {
                uint256 cooldownEnds = cooldown + (blockThreshold * multiplier);
                emit UserThrottled(from, multiplier, cooldownEnds);
                revert TransactionThrottled(from, cooldownEnds, multiplier);
            }
            
            // Update user throttling state
            userCooldown[from] = block.timestamp;
            userTransactionCount[from] = uint32(txCount);
            lastTransactionTime[from] = uint224(block.timestamp);
            
            // Analyze transaction patterns for suspicious activity
            _analyzeTransactionPattern(from);
        }
        _;
    }

    /**
     * @notice Checks for circuit breaker status
     */
    modifier circuitBreakerCheck() {
        if (isCircuitBreakerTriggered || isPriceSurgeActive) revert CircuitBreakerActive();
        _;
    }

    /**
     * @notice Ensures caller is governance or failsafe admin (if failsafe mode active)
     */
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
     * @notice Authorized upgrade for UUPS pattern
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // ================================
    //  Pattern Analysis
    // ================================

    /**
     * @notice Analyzes transaction patterns for suspicious activity
     * @param user Address to analyze
     */
    function _analyzeTransactionPattern(address user) internal {
        TransactionPattern storage pattern = userPatterns[user];
        
        // Reset pattern if it's been a while
        if (block.timestamp > pattern.lastPatternReset + 1 days) {
            pattern.highFrequencyCount = 0;
            pattern.suspiciousPatternCount = 0;
            pattern.volumeAccumulated = 0;
            pattern.lastPatternReset = uint64(block.timestamp);
            return;
        }
        
        // Analyze high frequency transactions
        uint256 txCount = userTransactionCount[user];
        if (txCount > rapidTransactionThreshold) {
            pattern.highFrequencyCount++;
            
            // If we detect a suspicious pattern several times, increase the throttling
            if (pattern.highFrequencyCount > 3) {
                pattern.suspiciousPatternCount++;
                
                // Apply additional throttling if suspicious patterns detected
                if (pattern.suspiciousPatternCount > 2) {
                    // Apply stronger rate limiting
                    TokenBucket storage bucket = rateLimitBuckets[user];
                    bucket.capacity = uint128(max(1, uint256(bucket.capacity) / 2));
                    bucket.refillRate = uint128(max(1, uint256(bucket.refillRate) / 2));
                    
                    emit SuspiciousPatternDetected(user, pattern.suspiciousPatternCount);
                }
            }
        }
    }

    // ================================
    //  Price-Based Protection
    // ================================
    
    /**
     * @notice Gets the price from the primary oracle
     * @return Latest price
     */
    function _getLatestPrice() internal view returns (int256) {
        try priceOracle.readDataFeedWithDapi() returns (int224 price, uint32 timestamp) {
            // Validate price data
            if (price <= 0 || timestamp == 0 || uint256(timestamp) + 1 hours < block.timestamp) {
                revert InvalidPriceData();
            }
            return int256(price);
        } catch {
            revert NoOracleResponse();
        }
    }

    /**
     * @notice Gets consensus price from multiple oracles
     * @return Consensus price
     */
    function _getConsensusPrice() internal view returns (int256) {
        if (oracleCount <= 1) {
            return _getLatestPrice();
        }
        
        // Get prices from all oracles
        int256[] memory prices = new int256[](oracleCount);
        uint256 validResponses = 0;
        
        for (uint8 i = 0; i < oracleCount; i++) {
            try IAPI3PriceFeed(oracleAddresses[i]).readDataFeedWithDapi() returns (
                int224 price,
                uint32 timestamp
            ) {
                if (price > 0 && uint256(timestamp) + 1 hours >= block.timestamp) {
                    prices[validResponses] = int256(price);
                    validResponses++;
                }
            } catch {
                // Skip failed oracle
            }
        }
        
        if (validResponses < minimumOracleResponses) {
            revert InsufficientOracleConsensus();
        }
        
        // Sort prices (simple bubble sort for small arrays)
        for (uint8 i = 0; i < validResponses - 1; i++) {
            for (uint8 j = 0; j < validResponses - i - 1; j++) {
                if (prices[j] > prices[j + 1]) {
                    (prices[j], prices[j + 1]) = (prices[j + 1], prices[j]);
                }
            }
        }
        
        // Return median price (or average of middle two for even number)
        if (validResponses % 2 == 1) {
            return prices[validResponses / 2];
        } else {
            return (prices[validResponses / 2 - 1] + prices[validResponses / 2]) / 2;
        }
    }

    /**
     * @notice Updates time-weighted average price
     */
    function _updateTWAP() internal {
        int256 currentPrice = _getConsensusPrice();
        
        // Add to circular buffer
        priceHistory[priceHistoryIndex] = PriceObservation(
            int128(currentPrice),
            uint128(block.timestamp)
        );
        
        // Update index and count
        priceHistoryIndex = (priceHistoryIndex + 1) % MAX_PRICE_OBSERVATIONS;
        if (priceHistoryCount < MAX_PRICE_OBSERVATIONS) {
            priceHistoryCount++;
        }
        
        // Calculate and emit TWAP
        int256 twap = calculateTWAP();
        emit TWAPUpdated(twap);
    }

    /**
     * @notice Calculates time-weighted average price
     * @return TWAP price
     */
    function calculateTWAP() public view returns (int256) {
        if (priceHistoryCount == 0) return 0;
        
        int256 weightedSum = 0;
        uint256 totalWeight = 0;
        uint256 mostRecent = block.timestamp;
        
        for (uint8 i = 0; i < priceHistoryCount; i++) {
            PriceObservation memory obs = priceHistory[i];
            uint256 age = mostRecent - obs.timestamp;
            
            // Weight is inverse of age (more recent = higher weight)
            // Add small constant to avoid division by zero
            uint256 weight = 1000000 / (age + 60);
            weightedSum += int256(obs.price) * int256(weight);
            totalWeight += weight;
        }
        
        if (totalWeight == 0) return 0;
        return weightedSum / int256(totalWeight);
    }

    /**
     * @notice Checks price impact and updates circuit breakers
     */
    function checkPriceImpact() external nonReentrant {
        uint256 currentTime = block.timestamp;
        if (currentTime < lastPriceCheckTime + priceCheckCooldown) return;
        
        // Get consensus price and update TWAP
        int256 currentPrice;
        try this.calculateTWAP() returns (int256 twap) {
            if (twap > 0) {
                currentPrice = twap; // Use TWAP if available
            } else {
                currentPrice = _getConsensusPrice();
            }
        } catch {
            currentPrice = _getConsensusPrice();
        }
        
        _updateTWAP();
        
        // Safety check
        if (lastCheckedPrice == 0) {
            lastCheckedPrice = currentPrice;
            lastPriceCheckTime = currentTime;
            emit PriceMonitoringUpdated(currentTime, 0, currentPrice);
            return;
        }
        
        // Calculate price change (using integer math)
        int256 priceChange = ((currentPrice - lastCheckedPrice) * 100) / lastCheckedPrice;
        int256 oldPrice = lastCheckedPrice;
        
        // Update state
        lastCheckedPrice = currentPrice;
        lastPriceCheckTime = currentTime;
        
        emit PriceMonitoringUpdated(currentTime, oldPrice, currentPrice);
        
        // Check for price drops
        if (priceChange < -int256(priceImpactThreshold)) {
            if (!isBuybackPaused) {
                isBuybackPaused = true;
                emit BuybackPaused(true);
            }
        } else if (isBuybackPaused && priceChange >= 0) {
            isBuybackPaused = false;
            emit BuybackPaused(false);
        }
        
        // Check for price surges
        if (priceChange > int256(priceSurgeThreshold)) {
            if (!isPriceSurgeActive) {
                isPriceSurgeActive = true;
                lastSurgeTime = currentTime;
                emit PriceSurgeDetected(true, priceChange);
            }
        } else if (isPriceSurgeActive && currentTime > lastSurgeTime + surgeCooldownPeriod) {
            isPriceSurgeActive = false;
            emit PriceSurgeReset(bytes32(0)); // Auto-reset
        }
        
        // Check circuit breaker
        if (priceChange < -int256(circuitBreakerThreshold)) {
            if (!isCircuitBreakerTriggered) {
                isCircuitBreakerTriggered = true;
                emit CircuitBreakerTriggered(true, priceChange);
            }
        }
    }

    /**
     * @notice Resets the circuit breaker
     */
    function resetCircuitBreaker() external nonReentrant failsafeOrGovernance {
        if (isCircuitBreakerTriggered) {
            isCircuitBreakerTriggered = false;
            emit CircuitBreakerReset(GOVERNANCE_ROLE);
        }
    }
    
    /**
     * @notice Emergency circuit breaker reset
     */
    function emergencyResetCircuitBreaker() external nonReentrant {
        bytes32 callerRole = hasRole(GOVERNANCE_ROLE, msg.sender) ? GOVERNANCE_ROLE : DEFAULT_ADMIN_ROLE;
        
        if (callerRole != GOVERNANCE_ROLE && callerRole != DEFAULT_ADMIN_ROLE) {
            revert OnlyRoleCanAccess(GOVERNANCE_ROLE);
        }
        
        if (!isCircuitBreakerTriggered) {
            revert CircuitBreakerNotActive();
        }
        
        isCircuitBreakerTriggered = false;
        emit EmergencyCircuitBreakerReset(msg.sender, callerRole);
    }

    /**
     * @notice Resets the price surge circuit breaker
     */
    function resetPriceSurgeBreaker() external nonReentrant failsafeOrGovernance {
        if (isPriceSurgeActive) {
            isPriceSurgeActive = false;
            emit PriceSurgeReset(GOVERNANCE_ROLE);
        }
    }

    // ================================
    //  Oracle Management
    // ================================
    
    /**
     * @notice Adds a backup oracle
     * @param oracle Oracle address to add
     */
    function addOracle(address oracle) external nonReentrant failsafeOrGovernance {
        if (oracle == address(0)) revert ZeroAddressProvided();
        if (oracleCount >= MAX_ORACLE_COUNT) revert InvalidThresholdValue();
        if (backupOracles[oracle]) return; // Already added
        
        backupOracles[oracle] = true;
        oracleAddresses.push(oracle);
        oracleCount++;
        
        emit OracleAdded(oracle);
    }
    
    /**
     * @notice Removes a backup oracle
     * @param oracle Oracle address to remove
     */
    function removeOracle(address oracle) external nonReentrant failsafeOrGovernance {
        if (!backupOracles[oracle] || oracle == address(priceOracle)) return;
        
        backupOracles[oracle] = false;
        
        // Reorganize oracleAddresses array
        for (uint8 i = 0; i < oracleCount; i++) {
            if (oracleAddresses[i] == oracle) {
                // Move the last element to the removed position
                oracleAddresses[i] = oracleAddresses[oracleCount - 1];
                // Remove the last element
                oracleAddresses.pop();
                oracleCount--;
                break;
            }
        }
        
        // Ensure minimum oracle responses doesn't exceed available oracles
        if (minimumOracleResponses > oracleCount) {
            minimumOracleResponses = oracleCount;
            emit MinimumOracleResponsesUpdated(minimumOracleResponses);
        }
        
        emit OracleRemoved(oracle);
    }
    
    /**
     * @notice Sets the minimum required oracle responses for consensus
     * @param count Minimum number of oracles required
     */
    function setMinimumOracleResponses(uint8 count) external nonReentrant failsafeOrGovernance {
        if (count == 0 || count > oracleCount) revert InvalidThresholdValue();
        minimumOracleResponses = count;
        emit MinimumOracleResponsesUpdated(count);
    }

    // ================================
    //  Configuration Management
    // ================================
    
    /**
     * @notice Updates the block threshold
     * @param newThreshold New block threshold
     */
    function updateBlockThreshold(uint256 newThreshold) external nonReentrant failsafeOrGovernance {
        blockThreshold = newThreshold;
        emit BlockThresholdUpdated(newThreshold);
    }

    /**
     * @notice Updates dynamic throttling parameters
     * @param _base Base multiplier
     * @param _rapid Rapid transaction threshold
     * @param _window Time window for rapid transactions
     * @param _max Maximum multiplier
     */
    function updateDynamicThrottling(
        uint256 _base,
        uint256 _rapid, 
        uint256 _window,
        uint256 _max
    ) external nonReentrant failsafeOrGovernance {
        if (_base == 0 || _rapid == 0 || _window == 0 || _max <= _base) {
            revert InvalidThresholdValue();
        }
        
        baseMultiplier = _base;
        rapidTransactionThreshold = _rapid;
        transactionTimeWindow = _window;
        maxMultiplier = _max;
        
        emit ThrottlingParametersUpdated(_base, _rapid, _window, _max);
    }
    
    /**
     * @notice Updates price impact thresholds
     * @param _impact Price impact threshold percentage
     * @param _surge Price surge threshold percentage
     * @param _circuit Circuit breaker threshold percentage
     */
    function updatePriceThresholds(
        uint256 _impact,
        uint256 _surge,
        uint256 _circuit
    ) external nonReentrant failsafeOrGovernance {
        if (_impact == 0 || _surge == 0 || _circuit == 0) {
            revert InvalidThresholdValue();
        }
        
        priceImpactThreshold = _impact;
        priceSurgeThreshold = _surge;
        circuitBreakerThreshold = _circuit;
        
        emit PriceThresholdsUpdated(_impact, _surge, _circuit);
    }
    
    /**
     * @notice Updates price check cooldown
     * @param cooldown New cooldown in seconds
     */
    function updatePriceCheckCooldown(uint256 cooldown) external nonReentrant failsafeOrGovernance {
        if (cooldown < 60 || cooldown > 3600) revert InvalidThresholdValue();
        priceCheckCooldown = cooldown;
        emit PriceCheckCooldownUpdated(cooldown);
    }
    
    /**
     * @notice Updates surge cooldown period
     * @param period New period in seconds
     */
    function updateSurgeCooldownPeriod(uint256 period) external nonReentrant failsafeOrGovernance {
        if (period < 300 || period > 86400) revert InvalidThresholdValue();
        surgeCooldownPeriod = period;
        emit SurgeCooldownPeriodUpdated(period);
    }
    
    /**
     * @notice Updates the primary price oracle
     * @param newOracle New oracle address
     */
    function updatePriceOracle(address newOracle) external nonReentrant failsafeOrGovernance {
        if (newOracle == address(0)) revert ZeroAddressProvided();
        
        address oldOracle = address(priceOracle);
        priceOracle = IAPI3PriceFeed(newOracle);
        
        // Add to backup oracles if not already there
        if (!backupOracles[newOracle]) {
            backupOracles[newOracle] = true;
            oracleAddresses.push(newOracle);
            oracleCount++;
        }
        
        emit PriceOracleUpdated(oldOracle, newOracle);
    }
    
    /**
     * @notice Updates rate limit parameters
     * @param _capacity Maximum tokens per period
     * @param _refillRate Tokens refilled per second
     */
    function updateRateLimitParams(
        uint256 _capacity,
        uint256 _refillRate
    ) external nonReentrant failsafeOrGovernance {
        if (_capacity == 0 || _refillRate == 0) revert InvalidThresholdValue();
        
        defaultBucketCapacity = uint128(_capacity);
        defaultRefillRate = uint128(_refillRate);
        
        emit RateLimitParamsUpdated(_capacity, _refillRate);
    }
    
    /**
     * @notice Sets a custom rate limit for a specific address
     * @param user Address to set custom rate limit for
     * @param capacity Maximum tokens per period
     * @param refillRate Tokens refilled per second
     */
    function setCustomRateLimit(
        address user,
        uint256 capacity,
        uint256 refillRate
    ) external nonReentrant failsafeOrGovernance {
        if (user == address(0)) revert ZeroAddressProvided();
        if (capacity == 0 || refillRate == 0) revert InvalidThresholdValue();
        
        TokenBucket storage bucket = rateLimitBuckets[user];
        bucket.capacity = uint128(capacity);
        bucket.refillRate = uint128(refillRate);
        bucket.tokens = uint128(capacity); // Reset tokens to full capacity
        bucket.lastRefill = uint64(block.timestamp);
        
        emit CustomRateLimitSet(user, capacity, refillRate);
    }
    
    /**
     * @notice Resets rate limit for a specific address to defaults
     * @param user Address to reset
     */
    function resetRateLimit(address user) external nonReentrant failsafeOrGovernance {
        if (user == address(0)) revert ZeroAddressProvided();
        
        TokenBucket storage bucket = rateLimitBuckets[user];
        bucket.capacity = defaultBucketCapacity;
        bucket.refillRate = defaultRefillRate;
        bucket.tokens = defaultBucketCapacity;
        bucket.lastRefill = uint64(block.timestamp);
        
        emit RateLimitReset(user);
    }
    
    /**
     * @notice Adds an address to the whitelist
     * @param user Address to whitelist
     */
    function addToWhitelist(address user) external nonReentrant failsafeOrGovernance {
        if (user == address(0)) revert ZeroAddressProvided();
        whitelist[user] = true;
        emit WhitelistUpdated(user, true);
    }
    
    /**
     * @notice Removes an address from the whitelist
     * @param user Address to remove from whitelist
     */
    function removeFromWhitelist(address user) external nonReentrant failsafeOrGovernance {
        whitelist[user] = false;
        emit WhitelistUpdated(user, false);
    }
    
    /**
     * @notice Adds an address to the blacklist
     * @param user Address to blacklist
     */
    function addToBlacklist(address user) external nonReentrant failsafeOrGovernance {
        if (user == address(0)) revert ZeroAddressProvided();
        blacklist[user] = true;
        emit BlacklistUpdated(user, true);
    }
    
    /**
     * @notice Removes an address from the blacklist
     * @param user Address to remove from blacklist
     */
    function removeFromBlacklist(address user) external nonReentrant failsafeOrGovernance {
        blacklist[user] = false;
        emit BlacklistUpdated(user, false);
    }

    // ================================
    //  Failsafe Management
    // ================================
    
    /**
     * @notice Activates failsafe mode
     */
    function activateFailsafeMode() external nonReentrant {
        // Only allow if governance has been inactive for a long time
        if (block.timestamp < lastGovernanceActivity + governanceInactivityThreshold) {
            revert GovernanceStillActive();
        }
        
        failsafeMode = true;
        failsafeAdmin = msg.sender;
        emit FailsafeModeActivated(msg.sender);
    }
    
    /**
     * @notice Deactivates failsafe mode
     */
    function deactivateFailsafeMode() external nonReentrant {
        // Only governance or the failsafe admin can deactivate
        if (!hasRole(GOVERNANCE_ROLE, msg.sender) && msg.sender != failsafeAdmin) {
            revert NotAuthorized();
        }
        
        failsafeMode = false;
        emit FailsafeModeDeactivated(msg.sender);
    }
    
    /**
     * @notice Updates governance inactivity threshold
     * @param threshold New threshold in seconds
     */
    function updateGovernanceInactivityThreshold(uint256 threshold) external nonReentrant onlyRole(GOVERNANCE_ROLE) {
        if (threshold < 7 days || threshold > 90 days) revert InvalidThresholdValue();
        governanceInactivityThreshold = threshold;
        emit GovernanceInactivityThresholdUpdated(threshold);
    }

    // ================================
    //  Utility Functions
    // ================================
    
    /**
     * @notice Returns the maximum of two values
     * @param a First value
     * @param b Second value
     * @return Maximum value
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
    
    /**
     * @notice Returns the minimum of two values
     * @param a First value
     * @param b Second value
     * @return Minimum value
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
    
    /**
     * @notice Gets the current throttling multiplier for a user
     * @param user Address to check
     * @return Current multiplier
     */
    function getThrottlingMultiplier(address user) external view returns (uint256) {
        if (whitelist[user]) return 1;
        if (blacklist[user]) return maxMultiplier;
        
        uint256 txCount = userTransactionCount[user];
        uint256 lastTx = lastTransactionTime[user];
        
        // If no recent transactions, return base multiplier
        if (lastTx == 0 || block.timestamp > lastTx + transactionTimeWindow) {
            return baseMultiplier;
        }
        
        // Calculate dynamic multiplier based on transaction count
        if (txCount <= rapidTransactionThreshold) {
            return baseMultiplier;
        } else {
            uint256 multiplier = baseMultiplier + ((txCount - rapidTransactionThreshold) / 2);
            return min(multiplier, maxMultiplier);
        }
    }
    
    /**
     * @notice Gets the current rate limit status for a user
     * @param user Address to check
     * @return available Available tokens
     * @return capacity Maximum capacity
     * @return refillRate Tokens per second refill rate
     */
    function getRateLimitStatus(address user) external view returns (
        uint256 available,
        uint256 capacity,
        uint256 refillRate
    ) {
        TokenBucket storage bucket = rateLimitBuckets[user];
        
        // If no custom bucket, use defaults
        if (bucket.capacity == 0) {
            return (defaultBucketCapacity, defaultBucketCapacity, defaultRefillRate);
        }
        
        // Calculate current tokens
        uint256 elapsed = block.timestamp - bucket.lastRefill;
        uint256 tokens = min(
            uint256(bucket.capacity),
            uint256(bucket.tokens) + (elapsed * uint256(bucket.refillRate))
        );
        
        return (tokens, bucket.capacity, bucket.refillRate);
    }
    
    /**
     * @notice Gets the current circuit breaker status
     * @return status Circuit breaker status
     */
    function getCircuitBreakerStatus() external view returns (
        bool circuitBreakerActive,
        bool priceSurgeActive,
        bool buybackPaused,
        int256 lastPrice,
        uint256 lastCheck
    ) {
        return (
            isCircuitBreakerTriggered,
            isPriceSurgeActive,
            isBuybackPaused,
            lastCheckedPrice,
            lastPriceCheckTime
        );
    }
    
    /**
     * @notice Gets the price history
     * @return timestamps Array of timestamps
     * @return prices Array of prices
     */
    function getPriceHistory() external view returns (
        uint256[] memory timestamps,
        int256[] memory prices
    ) {
        timestamps = new uint256[](priceHistoryCount);
        prices = new int256[](priceHistoryCount);
        
        for (uint8 i = 0; i < priceHistoryCount; i++) {
            uint8 idx = (priceHistoryIndex + i) % MAX_PRICE_OBSERVATIONS;
            timestamps[i] = priceHistory[idx].timestamp;
            prices[i] = priceHistory[idx].price;
        }
        
        return (timestamps, prices);
    }
}            