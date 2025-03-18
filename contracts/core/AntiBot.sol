// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
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
    AggregatorV3Interface public priceOracle;
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
        priceOracle = AggregatorV3Interface(_priceOracle);
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
        try priceOracle.latestRoundData() returns (
            uint80 roundId,
            int256 price,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            // Validate price data
            if (price <= 0 || updatedAt == 0 || updatedAt + 1 hours < block.timestamp) {
                revert InvalidPriceData();
            }
            return price;
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
            try AggregatorV3Interface(oracleAddresses[i]).latestRoundData() returns (
                uint80,
                int256 price,
                uint256,
                uint256 updatedAt,
                uint80
            ) {
                if (price > 0 && updatedAt + 1 hours >= block.timestamp) {
                    prices[validResponses] = price;
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
            revert InvalidThresholdRelationship();
        }
        
        baseMultiplier = _base;
        rapidTransactionThreshold = _rapid;
        rapidTransactionWindow = _window;
        maxMultiplier = _max;
        
        emit DynamicThrottlingUpdated(_base, _rapid, _window, _max);
    }
    
    /**
     * @notice Updates price impact threshold
     * @param newThreshold New price impact threshold
     */
    function updatePriceImpactThreshold(uint256 newThreshold) external nonReentrant failsafeOrGovernance {
        if (newThreshold == 0 || newThreshold >= circuitBreakerThreshold) {
            revert InvalidThresholdRelationship();
        }
        
        priceImpactThreshold = newThreshold;
        emit PriceImpactThresholdUpdated(newThreshold);
    }
    
    /**
     * @notice Updates circuit breaker threshold
     * @param newThreshold New circuit breaker threshold
     */
    function updateCircuitBreakerThreshold(uint256 newThreshold) external nonReentrant failsafeOrGovernance {
        if (newThreshold <= priceImpactThreshold) {
            revert InvalidThresholdRelationship();
        }
        
        circuitBreakerThreshold = newThreshold;
        emit CircuitBreakerThresholdUpdated(newThreshold);
    }
    
    /**
     * @notice Updates liquidity lock period
     * @param newPeriod New liquidity lock period
     */
    function updateLiquidityLockPeriod(uint256 newPeriod) external nonReentrant failsafeOrGovernance {
        if (newPeriod == 0) revert InvalidLockPeriod();
        
        liquidityLockPeriod = newPeriod;
        emit LiquidityLockPeriodUpdated(newPeriod);
    }
    
    /**
     * @notice Updates price check cooldown
     * @param newCooldown New price check cooldown
     */
    function updatePriceCheckCooldown(uint256 newCooldown) external nonReentrant failsafeOrGovernance {
        if (newCooldown == 0) revert InvalidThresholdValue();
        
        priceCheckCooldown = newCooldown;
        emit PriceCheckCooldownUpdated(newCooldown);
    }
    
    /**
     * @notice Updates price surge parameters
     * @param newThreshold New price surge threshold
     * @param newCooldown New surge cooldown period
     */
    function updatePriceSurgeThreshold(uint256 newThreshold, uint256 newCooldown) external nonReentrant failsafeOrGovernance {
        if (newThreshold == 0 || newCooldown == 0) {
            revert InvalidThresholdValue();
        }
        
        priceSurgeThreshold = newThreshold;
        surgeCooldownPeriod = newCooldown;
        
        emit PriceSurgeThresholdUpdated(newThreshold, newCooldown);
    }
    
    /**
     * @notice Updates governance inactivity threshold
     * @param newThreshold New governance inactivity threshold
     */
    function updateGovernanceInactivityThreshold(uint256 newThreshold) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newThreshold == 0) revert InvalidThresholdValue();
        
        governanceInactivityThreshold = newThreshold;
        emit GovernanceInactivityThresholdUpdated(newThreshold);
    }
    
    /**
     * @notice Updates rate limit configuration for a user
     * @param user Address to configure
     * @param capacity Maximum tokens capacity
     * @param refillRate Tokens added per minute
     */
    function updateRateLimitConfig(address user, uint128 capacity, uint128 refillRate) external nonReentrant onlyRole(CONFIG_MANAGER_ROLE) {
        if (user == address(0)) revert ZeroAddressProvided();
        if (capacity == 0 || refillRate == 0) revert InvalidThresholdValue();
        
        TokenBucket storage bucket = rateLimitBuckets[user];
        bucket.capacity = capacity;
        bucket.refillRate = refillRate;
        
        // Reset tokens to current capacity
        bucket.tokens = capacity;
        bucket.lastRefill = uint128(block.timestamp);
        
        emit RateLimitConfigUpdated(capacity, refillRate);
    }

    // ================================
    //  Trusted Contract Management
    // ================================
    
    /**
     * @notice Adds a trusted contract
     * @param contractAddress Address to exempt
     */
    function addTrustedContract(address contractAddress) external nonReentrant failsafeOrGovernance {
        if (contractAddress == address(0)) revert ZeroAddressProvided();
        trustedContracts[contractAddress] = true;
        emit TrustedContractAdded(contractAddress);
    }
    
    /**
     * @notice Removes a trusted contract
     * @param contractAddress Address to remove
     */
    function removeTrustedContract(address contractAddress) external nonReentrant failsafeOrGovernance {
        trustedContracts[contractAddress] = false;
        emit TrustedContractRemoved(contractAddress, GOVERNANCE_ROLE);
    }

    // ================================
    //  Liquidity Management
    // ================================
    
    /**
     * @notice Records a liquidity injection
     * @param provider Liquidity provider address
     */
    function recordLiquidityInjection(address provider) external override nonReentrant onlyRole(STAKING_CONTRACT_ROLE) {
        if (provider == address(0)) revert ZeroAddressProvided();
        liquidityInjectionTimestamp[provider] = block.timestamp;
    }
    
    /**
     * @notice Checks if liquidity can be withdrawn
     * @param provider Liquidity provider address
     * @return Whether liquidity can be withdrawn
     */
    function canWithdrawLiquidity(address provider) external view override returns (bool) {
        if (isCircuitBreakerTriggered) return false;
        if (_isExempt(provider)) return true;
        
        uint256 injectionTime = liquidityInjectionTimestamp[provider];
        if (injectionTime == 0) return true; // No record of injection
        
        return block.timestamp >= injectionTime + liquidityLockPeriod;
    }

    // ================================
    //  Governance Exemption Management
    // ================================
    
    /**
     * @notice Requests governance exemption
     * @param accountToExempt Address to exempt
     */
    function requestGovernanceExemption(address accountToExempt) external nonReentrant {
        if (accountToExempt == address(0)) revert ZeroAddressProvided();
        if (governanceExemptionCount >= MAX_GOVERNANCE_EXEMPTIONS) {
            revert MaxGovernanceExemptionsReached();
        }
        
        // Only allow the account itself or a transaction monitor
        if (msg.sender != accountToExempt && !hasRole(TRANSACTION_MONITOR_ROLE, msg.sender)) {
            revert NotAuthorized();
        }
        
        pendingExemptions[accountToExempt] = GovernanceRequest({
            account: accountToExempt,
            unlockTime: uint64(block.timestamp + 24 hours)
        });
        
        emit GovernanceExemptionRequested(accountToExempt, block.timestamp + 24 hours);
    }
    
    /**
     * @notice Approves governance exemption
     * @param accountToExempt Address to exempt
     */
    function approveGovernanceExemption(address accountToExempt) external nonReentrant failsafeOrGovernance {
        if (accountToExempt == address(0)) revert ZeroAddressProvided();
        
        GovernanceRequest memory request = pendingExemptions[accountToExempt];
        if (request.account != accountToExempt) revert NotAuthorized();
        
        if (block.timestamp < request.unlockTime) {
            revert TimelockNotExpired(request.account, request.unlockTime);
        }
        
        // Grant exemption
        _grantRole(GOVERNANCE_ROLE, accountToExempt);
        governanceExemptionCount++;
        
        // Clean up request
        delete pendingExemptions[accountToExempt];
        
        emit GovernanceExemptionApproved(accountToExempt, GOVERNANCE_ROLE);
    }
    
    /**
     * @notice Revokes governance exemption
     * @param accountToRevoke Address to revoke exemption from
     */
    function revokeGovernanceExemption(address accountToRevoke) external nonReentrant failsafeOrGovernance {
        if (!hasRole(GOVERNANCE_ROLE, accountToRevoke)) return;
        
        // Don't allow revoking original governance and staking contract roles
        if (accountToRevoke == getRoleMember(GOVERNANCE_ROLE, 0) || 
            accountToRevoke == getRoleMember(STAKING_CONTRACT_ROLE, 0)) {
            revert NotAuthorized();
        }
        
        _revokeRole(GOVERNANCE_ROLE, accountToRevoke);
        governanceExemptionCount--;
        
        emit ExemptionRevoked(accountToRevoke, GOVERNANCE_ROLE);
    }

    // ================================
    //  Failsafe Management
    // ================================
    
    // Failsafe admin
    address private failsafeAdmin;
    
    /**
     * @notice Checks if governance is potentially compromised
     * @return Whether governance is inactive
     */
    function isGovernanceInactive() public view returns (bool) {
        return block.timestamp > lastGovernanceActivity + governanceInactivityThreshold;
    }
    
    /**
     * @notice Updates failsafe admin
     * @param newAdmin New failsafe admin address
     */
    function updateFailsafeAdmin(address newAdmin) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAdmin == address(0)) revert ZeroAddressProvided();
        failsafeAdmin = newAdmin;
        emit FailsafeAdminUpdated(newAdmin);
    }
    
    /**
     * @notice Activates failsafe mode
     */
    function activateFailsafeMode() external nonReentrant {
        if (msg.sender != failsafeAdmin && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert NotAuthorized();
        }
        
        if (!isGovernanceInactive()) {
            revert GovernanceStillActive();
        }
        
        if (failsafeMode) {
            revert FailsafeModeAlreadyActive();
        }
        
        failsafeMode = true;
        emit FailsafeModeActivated(msg.sender);
    }
    
    /**
     * @notice Deactivates failsafe mode
     */
    function deactivateFailsafeMode() external nonReentrant {
        if (msg.sender != failsafeAdmin && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert NotAuthorized();
        }
        
        if (!failsafeMode) {
            revert FailsafeModeInactive();
        }
        
        failsafeMode = false;
        emit FailsafeModeDeactivated(msg.sender);
    }

    // ================================
    //  External Antibot Interface
    // ================================
    
    /**
     * @notice Check if address is throttled
     * @param user Address to check
     * @return Whether the address is throttled
     */
    function isThrottled(address user) external view override returns (bool) {
        if (!isAntibotEnabled || _isExempt(user)) return false;
        
        uint256 cooldown = userCooldown[user];
        uint256 multiplier = baseMultiplier;
        uint256 txCount = userTransactionCount[user];
        uint256 lastTxTime = lastTransactionTime[user];
        
        if (txCount > 0 && block.timestamp - lastTxTime < rapidTransactionWindow) {
            if (txCount >= rapidTransactionThreshold) {
                uint256 factor = 1 + ((txCount - rapidTransactionThreshold + 1) / 2);
                multiplier = baseMultiplier * factor;
                if (multiplier > maxMultiplier) multiplier = maxMultiplier;
            }
        }
        
        return block.timestamp <= cooldown + (blockThreshold * multiplier);
    }
    
    /**
     * @notice Checks if circuit breaker is active
     * @return Whether circuit breaker is active
     */
    function isCircuitBreakerActive() external view override returns (bool) {
        return isCircuitBreakerTriggered || isPriceSurgeActive;
    }
    
    /**
     * @notice Checks if buyback is paused
     * @return Whether buyback is paused
     */
    function isBuybackActive() external view override returns (bool) {
        return !isBuybackPaused;
    }
    
    /**
     * @notice Sets antibot status
     * @param status New antibot status
     */
    function setAntibotStatus(bool status) external nonReentrant failsafeOrGovernance {
        isAntibotEnabled = status;
        emit AntibotStatusUpdated(status);
    }

    // ================================
    //  Internal Helper Functions
    // ================================
    
    /**
     * @notice Checks if address is exempt from antibot
     * @param account Address to check
     * @return Whether the address is exempt
     */
    function _isExempt(address account) internal view returns (bool) {
        return hasRole(GOVERNANCE_ROLE, account) || trustedContracts[account];
    }
    
    /**
     * @notice Returns minimum of two values
     * @param a First value
     * @param b Second value
     * @return Minimum value
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
    
    /**
     * @notice Returns maximum of two values
     * @param a First value
     * @param b Second value
     * @return Maximum value
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    // ================================
    //  View Utility Functions
    // ================================
    
    /**
     * @notice Gets user throttling information
     * @param user Address to query
     * @return cooldownEnds Timestamp when cooldown ends
     * @return transactionCount Number of recent transactions
     * @return multiplier Current throttling multiplier
     */
    function getUserThrottlingInfo(address user) external view returns (
        uint256 cooldownEnds,
        uint256 transactionCount,
        uint256 multiplier
    ) {
        uint256 cooldown = userCooldown[user];
        uint256 txCount = userTransactionCount[user];
        multiplier = baseMultiplier;
        
        uint256 lastTxTime = lastTransactionTime[user];
        if (txCount > 0 && block.timestamp - lastTxTime < rapidTransactionWindow) {
            if (txCount >= rapidTransactionThreshold) {
                uint256 factor = 1 + ((txCount - rapidTransactionThreshold + 1) / 2);
                multiplier = baseMultiplier * factor;
                if (multiplier > maxMultiplier) multiplier = maxMultiplier;
            }
        }
        
        cooldownEnds = cooldown + (blockThreshold * multiplier);
        transactionCount = txCount;
        
        return (cooldownEnds, transactionCount, multiplier);
    }
    
    /**
     * @notice Gets token bucket rate limiting info for a user
     * @param user Address to query
     * @return tokens Current available tokens
     * @return capacity Maximum token capacity
     * @return refillRate Tokens added per minute
     * @return nextRefill Timestamp of next refill
     */
    function getRateLimitInfo(address user) external view returns (
        uint256 tokens,
        uint256 capacity,
        uint256 refillRate,
        uint256 nextRefill
    ) {
        TokenBucket memory bucket = rateLimitBuckets[user];
        
        // If bucket not initialized, return defaults
        if (bucket.capacity == 0) {
            return (5, 5, 1, 0);
        }
        
        // Calculate current tokens based on time elapsed
        uint256 elapsed = block.timestamp - bucket.lastRefill;
        uint256 tokensToAdd = (elapsed * bucket.refillRate) / 60; // Tokens per minute
        uint256 currentTokens = min(bucket.capacity, bucket.tokens + tokensToAdd);
        
        return (
            currentTokens,
            bucket.capacity,
            bucket.refillRate,
            bucket.lastRefill + (currentTokens < bucket.capacity ? 60 / bucket.refillRate : 0)
        );
    }
    
    /**
     * @notice Gets price monitoring info
     * @return lastPrice Last checked price
     * @return lastCheckTime Last price check timestamp
     * @return isBreaker Whether circuit breaker is active
     * @return isSurge Whether price surge breaker is active
     * @return surgeCooldownEnd Timestamp when surge cooldown ends
     */
    function getPriceMonitoringInfo() external view returns (
        int256 lastPrice,
        uint256 lastCheckTime,
        bool isBreaker,
        bool isSurge,
        uint256 surgeCooldownEnd
    ) {
        return (
            lastCheckedPrice,
            lastPriceCheckTime,
            isCircuitBreakerTriggered,
            isPriceSurgeActive,
            isPriceSurgeActive ? lastSurgeTime + surgeCooldownPeriod : 0
        );
    }
    
    /**
     * @notice Gets TWAP price history
     * @return prices Array of price observations
     * @return timestamps Array of timestamps
     * @return currentTWAP Current TWAP value
     */
    function getTWAPHistory() external view returns (
        int256[] memory prices,
        uint256[] memory timestamps,
        int256 currentTWAP
    ) {
        prices = new int256[](priceHistoryCount);
        timestamps = new uint256[](priceHistoryCount);
        
        for (uint8 i = 0; i < priceHistoryCount; i++) {
            uint8 idx = (priceHistoryIndex + MAX_PRICE_OBSERVATIONS - i - 1) % MAX_PRICE_OBSERVATIONS;
            PriceObservation memory obs = priceHistory[idx];
            prices[i] = obs.price;
            timestamps[i] = obs.timestamp;
        }
        
        currentTWAP = calculateTWAP();
        
        return (prices, timestamps, currentTWAP);
    }
    
    /**
     * @notice Gets oracle configuration
     * @return primary Primary oracle address
     * @return backups Array of backup oracle addresses
     * @return required Minimum required oracle responses
     */
    function getOracleConfig() external view returns (
        address primary,
        address[] memory backups,
        uint8 required
    ) {
        primary = address(priceOracle);
        backups = oracleAddresses;
        required = minimumOracleResponses;
        
        return (primary, backups, required);
    }
    
    /**
     * @notice Verifies if an account is exempt from antibot
     * @param account Address to check
     * @return Whether the account is exempt
     */
    function isExempt(address account) external view returns (bool) {
        return _isExempt(account);
    }
    
    /**
     * @notice Gets the address's transaction pattern information
     * @param user Address to query
     * @return highFreq High frequency transaction count
     * @return suspicious Suspicious pattern count
     * @return lastReset Last pattern reset timestamp
     * @return isSuspicious Whether account is considered suspicious
     */
    function getUserPatternInfo(address user) external view returns (
        uint64 highFreq,
        uint64 suspicious,
        uint64 lastReset,
        bool isSuspicious
    ) {
        TransactionPattern memory pattern = userPatterns[user];
        return (
            pattern.highFrequencyCount,
            pattern.suspiciousPatternCount,
            pattern.lastPatternReset,
            pattern.suspiciousPatternCount > 2
        );
    }
    
    /**
     * @notice Gets the failsafe mode status
     * @return active Whether failsafe mode is active
     * @return admin Current failsafe admin address
     * @return governanceActive Whether governance is considered active
     * @return lastActivity Last governance activity timestamp
     * @return inactivityThreshold Governance inactivity threshold
     */
    function getFailsafeStatus() external view returns (
        bool active,
        address admin,
        bool governanceActive,
        uint256 lastActivity,
        uint256 inactivityThreshold
    ) {
        return (
            failsafeMode,
            failsafeAdmin,
            !isGovernanceInactive(),
            lastGovernanceActivity,
            governanceInactivityThreshold
        );
    }
    
    /**
     * @notice Checks if a liquidity provider can withdraw
     * @param provider Liquidity provider address
     * @return canWithdraw Whether provider can withdraw liquidity
     * @return timeRemaining Time remaining until withdrawal is allowed (0 if can withdraw)
     */
    function checkLiquidityWithdrawal(address provider) external view returns (
        bool canWithdraw,
        uint256 timeRemaining
    ) {
        if (isCircuitBreakerTriggered) {
            return (false, type(uint256).max); // Cannot withdraw during circuit breaker
        }
        
        if (_isExempt(provider)) {
            return (true, 0); // Exempt accounts can always withdraw
        }
        
        uint256 injectionTime = liquidityInjectionTimestamp[provider];
        if (injectionTime == 0) {
            return (true, 0); // No record of injection
        }
        
        uint256 unlockTime = injectionTime + liquidityLockPeriod;
        if (block.timestamp >= unlockTime) {
            return (true, 0); // Lock period expired
        } else {
            return (false, unlockTime - block.timestamp); // Still locked
        }
    }
    
    /**
     * @notice Gets version information
     * @return version Contract version string
     */
    function getVersion() external pure returns (string memory) {
        return "AntiBot v4.0";
    }
}
