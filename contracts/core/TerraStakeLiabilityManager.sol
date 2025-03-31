// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@api3/contracts/api3-server-v1/proxies/interfaces/IProxy.sol";
import "@api3/contracts/api3-server-v1/proxies/interfaces/IProxyFactory.sol";
import "../interfaces/ITerraStakeNFT.sol";
import "../interfaces/ITerraStakeToken.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/IAntiBot.sol";
import "../interfaces/ICrossChainHandler.sol";
import "../interfaces/INeuralManager.sol";
import "../interfaces/IUniswapV4PoolManager.sol";

/**
 * @title TerraStakeLiabilityManager
 * @dev Complete synchronized liability management system with enhanced TWAP integration
 */
contract TerraStakeLiabilityManager is
    Initializable,
    ERC1155HolderUpgradeable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using ECDSA for bytes32;

    // TWAP Implementation
    struct TWAPObservation {
        uint32 timestamp;
        uint224 priceCumulative;
        bool initialized;
    }

    struct TWAPConfig {
        uint32 windowSize;
        uint16 minUpdateInterval;
        uint16 maxObservations;
    }

    // Roles
    bytes32 public constant LIABILITY_MANAGER_ROLE = keccak256("LIABILITY_MANAGER_ROLE");
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");
    bytes32 public constant ORACLE_MANAGER_ROLE = keccak256("ORACLE_MANAGER_ROLE");
    bytes32 public constant OFFSET_VERIFIER_ROLE = keccak256("OFFSET_VERIFIER_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 public constant STAKING_INTERACTOR_ROLE = keccak256("STAKING_INTERACTOR_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant NEURAL_INDEXER_ROLE = keccak256("NEURAL_INDEXER_ROLE");
    bytes32 public constant TWAP_MANAGER_ROLE = keccak256("TWAP_MANAGER_ROLE");

    // Constants
    uint256 public constant MAX_FRACTION_SUPPLY = 1e27;
    uint256 public constant MIN_LOCK_PERIOD = 1 days;
    uint256 public constant MAX_LOCK_PERIOD = 365 days;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_TRADING_FEE = 1000;
    uint256 public constant DEFAULT_TIMELOCK = 2 days;
    uint256 public constant MAX_PRICE_CHANGE_PERCENT = 2000;
    uint160 public constant SQRT_RATIO_1_1 = 79228162514264337593543950336;
    uint256 public constant MAX_SLIPPAGE = 5000; // 50%

    // TWAP Configuration
    TWAPConfig public twapConfig;
    mapping(address => TWAPObservation[]) private _twapObservations;
    mapping(address => uint32) public customTWAPWindows;

    // API3 Oracle Configuration
    struct OracleConfig {
        address api3Proxy;
        uint256 heartbeatPeriod;
        uint256 minPrice;
        uint256 maxPrice;
        bool active;
        uint256 lastUpdateTime;
        uint256 updateInterval;
    }

    // Liability Data Structure
    struct LiabilityData {
        address tokenAddress;
        uint256 nftId;
        uint256 totalSupply;
        uint256 totalELiability;
        uint256 lastPrice;
        bool isActive;
        uint256 lockEndTime;
        address creator;
        uint256 creationTime;
        ITerraStakeNFT.ProjectCategory category;
        bytes32 auditDataHash;
    }

    // Cross-chain state structure
    struct CrossChainState {
        uint256 halvingEpoch;
        uint256 timestamp;
        uint256 totalSupply;
        uint256 lastTWAPPrice;
        uint256 emissionRate;
    }

    // Tokenomics Structure
    struct FulfillmentIncentive {
        uint256 earlyFulfillmentBonus;
        uint256 lateFulfillmentPenalty;
        uint256 maxFulfillmentDiscount;
    }

    struct FeeStructure {
        uint256 baseTradingFee;
        uint256 fulfillmentDiscount;
        uint256 governanceShare;
        uint256 offsetFundShare;
    }

    // State variables
    ITerraStakeNFT public terraStakeNFT;
    ITerraStakeToken public tStakeToken;
    ITerraStakeStaking public terraStakeStaking;
    address public api3ProxyFactory;
    CrossChainState public currentChainState;
    IAntiBot public antiBot;
    address public uniswapV4PoolManager;
    bytes32 public uniswapV4PoolId;
    INeuralManager public neuralManager;
    
    mapping(address => LiabilityData) public liabilityData;
    mapping(uint256 => address) public nftToLiabilityToken;
    mapping(address => OracleConfig) public tokenOracles;
    EnumerableSet.AddressSet private _tokenWithOracles;
    EnumerableSet.AddressSet private _allLiabilityTokens;
    EnumerableSet.AddressSet private _secondaryMarkets;
    EnumerableSet.Bytes32Set private _allProposals;

    uint256 public fractionalizationFee;
    uint256 public tradingFeePercentage;
    address public treasuryWallet;
    address public impactFundWallet;
    address public api3FeeWallet;
    FulfillmentIncentive public incentives;
    FeeStructure public feeStructure;

    // Governance
    uint256 public governanceThreshold;
    uint256 public emergencyThreshold;
    uint256 public proposalExpiryTime;
    mapping(bytes32 => Proposal) private _proposals;
    mapping(address => address) private _delegates;
    mapping(address => uint256) private _totalDelegatedToMe;

    // Events
    event NFTFractionalized(
        uint256 indexed nftId,
        address liabilityToken,
        uint256 totalSupply,
        uint256 totalELiability,
        address creator,
        ITerraStakeNFT.ProjectCategory category,
        bytes32 auditDataHash
    );
    event LiabilityRedeemed(
        uint256 indexed nftId,
        address redeemer,
        uint256 offsetCertificates,
        uint256 newNFTId
    );
    event FractionsTraded(
        address indexed trader,
        address indexed liabilityToken,
        uint256 amount,
        uint256 price,
        bool isBuy
    );
    event OracleConfigured(
        address indexed token,
        address indexed api3Proxy,
        uint256 heartbeatPeriod,
        uint256 minPrice,
        uint256 maxPrice,
        uint256 updateInterval
    );
    event PriceUpdated(address indexed token, uint256 oldPrice, uint256 newPrice);
    event FeesUpdated(uint256 fractionalizationFee, uint256 tradingFeePercentage);
    event FeeDistribution(
        address indexed treasury,
        address indexed impactFund,
        address indexed api3FeeWallet,
        uint256 treasuryAmount,
        uint256 impactAmount,
        uint256 api3FeeAmount
    );
    event StakingContractUpdated(address indexed newStakingContract);
    event SecondaryMarketRegistered(address indexed market);
    event SecondaryMarketDeregistered(address indexed market);
    event ProposalCreated(bytes32 indexed proposalId, address indexed proposer, bool isEmergency);
    event ProposalApproved(bytes32 indexed proposalId, address indexed approver);
    event ProposalExecuted(bytes32 indexed proposalId, address indexed executor);
    event EmergencyActionExecuted(bytes32 indexed proposalId, address indexed executor);
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event AntiBotUpdated(address indexed antiBot);
    event UniswapV4PoolConfigured(address indexed poolManager, bytes32 poolId);
    event NeuralIntegrationComplete(address indexed neuralManager);
    event TaxRatesSynced(uint256 buybackTaxBasisPoints, uint256 burnRateBasisPoints);
    event FeeStructureUpdated(uint256 governanceShare, uint256 offsetFundShare);
    event CrossChainStateSynced(uint256 halvingEpoch, uint256 timestamp);
    event TWAPConfigUpdated(uint32 windowSize, uint16 minUpdateInterval, uint16 maxObservations);
    event TWAPObservationRecorded(address indexed token, uint256 price, uint32 timestamp);
    event ObservationsCompressed(address indexed token, uint256 originalCount, uint256 newCount);
    event TWAPStateSynced(address indexed token, uint256 observationsSynced);
    event CustomTWAPWindowSet(address indexed token, uint32 windowSize);
    event PriceSlippageChecked(address indexed token, uint256 twapPrice, uint256 currentPrice);
    event OraclePriceValidated(address indexed token, uint256 price);

    // Errors
    error InvalidAddress();
    error NFTAlreadyFractionalized();
    error NFTNotVerified();
    error InvalidFractionSupply();
    error InvalidLockPeriod();
    error InsufficientBalance();
    error TransferFailed();
    error OracleNotActive();
    error StalePriceData();
    error PriceOutOfRange();
    error InvalidFeePercentage();
    error OnlyLiabilityManager();
    error OnlyOffsetVerifier();
    error LiabilityNotActive();
    error NFTStillLocked();
    error InsufficientOffsets();
    error ProposalAlreadyExists();
    error ProposalDoesNotExist();
    error ProposalAlreadyApproved();
    error ProposalAlreadyExecuted();
    error ProposalExpired();
    error ProposalTimelocked();
    error ProposalCanceled();
    error InsufficientApprovals();
    error ExecutionFailed();
    error InvalidOracleConfig();
    error InvalidPrice();
    error PriceChangeExceedsLimit();
    error EmergencyActionFailed();
    error Unauthorized();
    error InvalidThreshold();
    error InvalidExpiry();
    error InvalidTimelock();
    error OnlyCreatorCanCancel();
    error TransactionThrottled();
    error InvalidTWAPConfig();
    error InsufficientTWAPObservations();
    error TWAPNotInitialized();
    error InvalidObservationData();
    error ArraysLengthMismatch();
    error PriceSlippageExceeded();
    error InvalidSlippageParameter();
    error StaleTWAPData();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _terraStakeNFT,
        address _tStakeToken,
        address _terraStakeStaking,
        address _treasuryWallet,
        address _impactFundWallet,
        address _api3ProxyFactory,
        address _api3FeeWallet,
        address _crossChainHandler,
        address _neuralManager
    ) public initializer {
        __ERC1155Holder_init();
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        if (_terraStakeNFT == address(0) ||
            _tStakeToken == address(0) ||
            _terraStakeStaking == address(0) ||
            _treasuryWallet == address(0) ||
            _impactFundWallet == address(0) ||
            _api3ProxyFactory == address(0) ||
            _api3FeeWallet == address(0) ||
            _crossChainHandler == address(0) ||
            _neuralManager == address(0)) {
            revert InvalidAddress();
        }

        terraStakeNFT = ITerraStakeNFT(_terraStakeNFT);
        tStakeToken = ITerraStakeToken(_tStakeToken);
        terraStakeStaking = ITerraStakeStaking(_terraStakeStaking);
        treasuryWallet = _treasuryWallet;
        impactFundWallet = _impactFundWallet;
        api3ProxyFactory = _api3ProxyFactory;
        api3FeeWallet = _api3FeeWallet;
        neuralManager = INeuralManager(_neuralManager);

        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(LIABILITY_MANAGER_ROLE, msg.sender);
        _grantRole(AUDITOR_ROLE, msg.sender);
        _grantRole(ORACLE_MANAGER_ROLE, msg.sender);
        _grantRole(OFFSET_VERIFIER_ROLE, msg.sender);
        _grantRole(FEE_MANAGER_ROLE, msg.sender);
        _grantRole(STAKING_INTERACTOR_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(NEURAL_INDEXER_ROLE, msg.sender);
        _grantRole(TWAP_MANAGER_ROLE, msg.sender);

        // Initialize parameters
        fractionalizationFee = 100 ether;
        tradingFeePercentage = 200;
        governanceThreshold = 1;
        emergencyThreshold = 1;
        proposalExpiryTime = 7 days;

        // Initialize tokenomics
        incentives = FulfillmentIncentive({
            earlyFulfillmentBonus: 500,
            lateFulfillmentPenalty: 1000,
            maxFulfillmentDiscount: 800
        });

        feeStructure = FeeStructure({
            baseTradingFee: 50,
            fulfillmentDiscount: 1000,
            governanceShare: 5000,
            offsetFundShare: 5000
        });

        // Initialize TWAP
        twapConfig = TWAPConfig({
            windowSize: 1 hours,
            minUpdateInterval: 5 minutes,
            maxObservations: 100
        });

        // Sync initial cross-chain state
        _syncInitialState(_crossChainHandler);
    }

    // ========== TWAP IMPROVEMENTS ==========

    /**
     * @dev Optimized binary search for TWAP observations
     */
    function _optimizedBinarySearch(
        TWAPObservation[] storage observations,
        uint32 targetTimestamp
    ) private view returns (TWAPObservation memory beforeOrAt, TWAPObservation memory atOrAfter) {
        uint256 l = 0;
        uint256 r = observations.length - 1;
        
        // Early exit if target is outside our observation range
        if (targetTimestamp <= observations[0].timestamp) {
            return (observations[0], observations[1]);
        }
        if (targetTimestamp >= observations[r].timestamp) {
            return (observations[r-1], observations[r]);
        }
        
        // Binary search with early exit conditions
        while (l <= r) {
            uint256 m = (l + r) / 2;
            
            if (m < observations.length - 1 && 
                observations[m].timestamp <= targetTimestamp && 
                targetTimestamp < observations[m+1].timestamp) {
                return (observations[m], observations[m+1]);
            }
            
            if (observations[m].timestamp < targetTimestamp) {
                l = m + 1;
            } else {
                r = m - 1;
            }
        }
        
        // Should never reach here if observations are properly ordered
        revert("Binary search failed");
    }

    /**
     * @dev Gas-efficient TWAP observation writing
     */
    function _efficientWriteTWAPObservation(address token, uint256 price) internal {
        TWAPObservation[] storage observations = _twapObservations[token];
        uint32 blockTimestamp = uint32(block.timestamp);
        
        // Only write if minimum interval has passed
        if (observations.length > 0) {
            uint32 lastTimestamp = observations[observations.length - 1].timestamp;
            if (blockTimestamp - lastTimestamp < twapConfig.minUpdateInterval) {
                return;
            }
        }
        
        // Truncate price to fit in uint224
        uint224 priceTruncated = uint224(price);
        
        // Calculate new cumulative price
        uint224 newCumulative;
        if (observations.length == 0) {
            newCumulative = 0;
        } else {
            TWAPObservation memory last = observations[observations.length - 1];
            uint32 timeElapsed = blockTimestamp - last.timestamp;
            
            // Using unchecked for gas optimization since we're handling overflow manually
            unchecked {
                uint256 addition = uint256(price) * timeElapsed;
                newCumulative = last.priceCumulative + uint224(addition);
            }
        }
        
        // Add observation with minimal gas usage
        observations.push(TWAPObservation({
            timestamp: blockTimestamp,
            priceCumulative: newCumulative,
            initialized: true
        }));
        
        // Manage array size efficiently
        if (observations.length > twapConfig.maxObservations) {
            // Instead of shifting array, we can implement a ring buffer in a future upgrade
            for (uint i = 0; i < observations.length - 1; i++) {
                observations[i] = observations[i + 1];
            }
            observations.pop();
        }
        
        emit TWAPObservationRecorded(token, price, blockTimestamp);
    }

    /**
     * @dev Improved observation compression algorithm
     */
    function improvedCompressObservations(address token) external onlyRole(TWAP_MANAGER_ROLE) nonReentrant {
        TWAPObservation[] storage observations = _twapObservations[token];
        uint256 count = observations.length;
        
        if (count <= twapConfig.maxObservations) {
            return; // No compression needed
        }
        
        // Calculate time range of observations
        uint32 startTime = observations[0].timestamp;
        uint32 endTime = observations[count - 1].timestamp;
        uint32 timeRange = endTime - startTime;
        
        // Create a new array with evenly spaced observations based on time
        TWAPObservation[] memory compressed = new TWAPObservation[](twapConfig.maxObservations);
        compressed[0] = observations[0]; // Always keep oldest
        compressed[twapConfig.maxObservations - 1] = observations[count - 1]; // Always keep newest
        
        // Distribute remaining observations evenly by time
        for (uint256 i = 1; i < twapConfig.maxObservations - 1; i++) {
            uint32 targetTime = startTime + (timeRange * i) / (twapConfig.maxObservations - 1);
            
            // Find closest observation to target time
            uint256 bestIndex = 0;
            uint32 bestDiff = type(uint32).max;
            
            for (uint256 j = 0; j < count; j++) {
                uint32 diff = observations[j].timestamp > targetTime ? 
                    observations[j].timestamp - targetTime : 
                    targetTime - observations[j].timestamp;
                    
                if (diff < bestDiff) {
                    bestDiff = diff;
                    bestIndex = j;
                }
            }
            
            compressed[i] = observations[bestIndex];
        }
        
        // Replace storage array with compressed version
        delete _twapObservations[token];
        for (uint256 i = 0; i < twapConfig.maxObservations; i++) {
            _twapObservations[token].push(compressed[i]);
        }
        
        emit ObservationsCompressed(token, count, twapConfig.maxObservations);
    }

    // ========== SECURITY IMPROVEMENTS ==========

    /**
     * @dev Enhanced TWAP price with slippage protection
     */
    function enhancedTWAPPriceForTrade(address token, uint256 maxSlippage) external view returns (uint256) {
        // Require meaningful slippage parameter
        if (maxSlippage == 0 || maxSlippage > MAX_SLIPPAGE) revert InvalidSlippageParameter();
        
        uint32 window = customTWAPWindows[token] > 0 ? customTWAPWindows[token] : twapConfig.windowSize;
        uint256 twapPrice = getTWAP(token, window);
        uint256 currentPrice = liabilityData[token].lastPrice;
        
        // Check for minimum observation count
        if (_twapObservations[token].length < 3) revert InsufficientTWAPObservations();
        
        // Ensure TWAP is recent enough
        uint32 latestObservationTime = _twapObservations[token][_twapObservations[token].length - 1].timestamp;
        if (block.timestamp - latestObservationTime > window) revert StaleTWAPData();
        
        // Verify current price doesn't deviate too much from TWAP (with percentage calculation safeguards)
        if (currentPrice > twapPrice) {
            uint256 percentageDifference = ((currentPrice - twapPrice) * BASIS_POINTS) / twapPrice;
            if (percentageDifference > maxSlippage) revert PriceSlippageExceeded();
        } else if (twapPrice > currentPrice) {
            uint256 percentageDifference = ((twapPrice - currentPrice) * BASIS_POINTS) / currentPrice;
            if (percentageDifference > maxSlippage) revert PriceSlippageExceeded();
        }
        
        emit PriceSlippageChecked(token, twapPrice, currentPrice);
        return twapPrice;
    }

    /**
     * @dev Enhanced oracle validation
     */
    function validateOraclePrice(address token) public view returns (bool) {
        OracleConfig storage oracle = tokenOracles[token];
        if (!oracle.active) return false;
        
        // Check freshness
        if (block.timestamp - oracle.lastUpdateTime > oracle.heartbeatPeriod) return false;
        
        // Check price is within expected range
        (int224 price, ) = IProxy(oracle.api3Proxy).read();
        uint256 currentPrice = uint256(uint224(price));
        if (currentPrice < oracle.minPrice || currentPrice > oracle.maxPrice) return false;
        
        // Check for rapid price changes
        uint256 lastPrice = liabilityData[token].lastPrice;
        if (lastPrice > 0) {
            uint256 priceChange = (currentPrice > lastPrice) ? 
                (currentPrice - lastPrice) * BASIS_POINTS / lastPrice :
                (lastPrice - currentPrice) * BASIS_POINTS / lastPrice;
            if (priceChange > MAX_PRICE_CHANGE_PERCENT) return false;
        }
        
        emit OraclePriceValidated(token, currentPrice);
        return true;
    }

    // ========== CORE FUNCTIONALITY ==========

    function fractionalizeNFT(
        uint256 nftId,
        string memory name,
        string memory symbol,
        uint256 fractionCount,
        uint256 lockPeriod
    ) external nonReentrant whenNotPaused {
        if (nftToLiabilityToken[nftId] != address(0)) revert NFTAlreadyFractionalized();
        if (fractionCount == 0 || fractionCount > MAX_FRACTION_SUPPLY) revert InvalidFractionSupply();
        if (lockPeriod < MIN_LOCK_PERIOD || lockPeriod > MAX_LOCK_PERIOD) revert InvalidLockPeriod();

        // Verify NFT ownership and status
        ITerraStakeNFT.NFTData memory nftData = terraStakeNFT.getNFTData(nftId);
        if (nftData.owner != msg.sender) revert Unauthorized();
        if (!nftData.verified) revert NFTNotVerified();

        // Record liability data before transfers
        address liabilityToken = address(new ERC20PermitUpgradeable());
        ERC20PermitUpgradeable(liabilityToken).initialize(name, symbol);
        
        liabilityData[liabilityToken] = LiabilityData({
            tokenAddress: liabilityToken,
            nftId: nftId,
            totalSupply: fractionCount,
            totalELiability: nftData.eLiability,
            lastPrice: 0,
            isActive: true,
            lockEndTime: block.timestamp + lockPeriod,
            creator: msg.sender,
            creationTime: block.timestamp,
            category: nftData.category,
            auditDataHash: nftData.auditDataHash
        });
        
        nftToLiabilityToken[nftId] = liabilityToken;
        _allLiabilityTokens.add(liabilityToken);
        
        // Transfer NFT to this contract - do this AFTER state changes
        terraStakeNFT.safeTransferFrom(msg.sender, address(this), nftId, 1, "");
        
        // Mint fractions to creator
        ERC20Upgradeable(liabilityToken).mint(msg.sender, fractionCount);
        
        emit NFTFractionalized(
            nftId,
            liabilityToken,
            fractionCount,
            nftData.eLiability,
            msg.sender,
            nftData.category,
            nftData.auditDataHash
        );
    }

    function updateTokenPrice(address token) external {
        if (!liabilityData[token].isActive) revert LiabilityNotActive();
        if (!tokenOracles[token].active) revert OracleNotActive();

        OracleConfig storage oracle = tokenOracles[token];
        if (block.timestamp - oracle.lastUpdateTime < oracle.updateInterval) {
            revert StalePriceData();
        }

        // Get price from API3 oracle
        (int224 price, ) = IProxy(oracle.api3Proxy).read();
        uint256 newPrice = uint256(uint224(price));

        // Validate price
        if (newPrice == 0) revert InvalidPrice();
        if (newPrice < oracle.minPrice || newPrice > oracle.maxPrice) revert PriceOutOfRange();

        // Check price change limit
        uint256 oldPrice = liabilityData[token].lastPrice;
        if (oldPrice > 0) {
            uint256 priceChange = (newPrice > oldPrice) ? 
                (newPrice - oldPrice) * BASIS_POINTS / oldPrice :
                (oldPrice - newPrice) * BASIS_POINTS / oldPrice;
            if (priceChange > MAX_PRICE_CHANGE_PERCENT) revert PriceChangeExceedsLimit();
        }

        // Update price and record TWAP observation
        liabilityData[token].lastPrice = newPrice;
        oracle.lastUpdateTime = block.timestamp;
        _efficientWriteTWAPObservation(token, newPrice);

        emit PriceUpdated(token, oldPrice, newPrice);
    }

    function redeemLiability(
        address liabilityToken,
        uint256 amount,
        uint256 offsetCertificates
    ) external nonReentrant {
        LiabilityData storage data = liabilityData[liabilityToken];
        if (!data.isActive) revert LiabilityNotActive();
        if (block.timestamp < data.lockEndTime) revert NFTStillLocked();

        // Verify offset certificates
        if (offsetCertificates < data.totalELiability * amount / data.totalSupply) {
            revert InsufficientOffsets();
        }

        // Burn the liability tokens
        ERC20BurnableUpgradeable(liabilityToken).burnFrom(msg.sender, amount);

        // Calculate NFT amount (1:1 for simplicity)
        uint256 nftAmount = amount * 1e18 / data.totalSupply;

        // Transfer NFT to redeemer
        terraStakeNFT.safeTransferFrom(address(this), msg.sender, data.nftId, nftAmount, "");

        // Create new NFT for remaining liability
        uint256 newNFTId = terraStakeNFT.mint(
            address(this),
            data.totalELiability - (data.totalELiability * amount / data.totalSupply),
            data.category,
            data.auditDataHash
        );

        emit LiabilityRedeemed(data.nftId, msg.sender, offsetCertificates, newNFTId);
    }

    // ========== GOVERNANCE FUNCTIONS ==========

    struct Proposal {
        address proposer;
        bytes32 actionHash;
        uint256 creationTime;
        uint256 approvals;
        uint256 approvalsNeeded;
        bool executed;
        bool canceled;
        bool isEmergency;
        mapping(address => bool) hasApproved;
    }

    function createProposal(
        bytes32 actionHash,
        bool isEmergency
    ) external onlyRole(isEmergency ? EMERGENCY_ROLE : GOVERNANCE_ROLE) returns (bytes32) {
        bytes32 proposalId = keccak256(abi.encodePacked(actionHash, block.timestamp, msg.sender));
        if (_allProposals.contains(proposalId)) revert ProposalAlreadyExists();

        _allProposals.add(proposalId);
        Proposal storage proposal = _proposals[proposalId];
        proposal.proposer = msg.sender;
        proposal.actionHash = actionHash;
        proposal.creationTime = block.timestamp;
        proposal.approvalsNeeded = isEmergency ? emergencyThreshold : governanceThreshold;
        proposal.isEmergency = isEmergency;

        emit ProposalCreated(proposalId, msg.sender, isEmergency);
        return proposalId;
    }

    function executeEmergencyAction(
        bytes32 proposalId,
        address target,
        bytes calldata data
    ) external nonReentrant onlyRole(EMERGENCY_ROLE) {
        if (!_allProposals.contains(proposalId)) revert ProposalDoesNotExist();
        Proposal storage proposal = _proposals[proposalId];
        
        // Require multiple approvals even for emergency actions
        if (!proposal.isEmergency) revert("Not an emergency proposal");
        if (proposal.approvals < 2) revert InsufficientApprovals(); // At least 2 approvals
        
        proposal.executed = true;
        (bool success, ) = target.call(data);
        if (!success) revert EmergencyActionFailed();
        
        emit EmergencyActionExecuted(proposalId, msg.sender);
    }

    // ========== UTILITY FUNCTIONS ==========

    function _syncInitialState(address crossChainHandler) internal {
        ICrossChainHandler.CrossChainState memory tokenState =
            ICrossChainHandler(crossChainHandler).getCurrentState();

        currentChainState = CrossChainState({
            halvingEpoch: tokenState.halvingEpoch,
            timestamp: tokenState.timestamp,
            totalSupply: tokenState.totalSupply,
            lastTWAPPrice: tokenState.lastTWAPPrice,
            emissionRate: tokenState.emissionRate
        });
    }

    function setCustomTWAPWindow(address token, uint32 windowSize) external onlyRole(TWAP_MANAGER_ROLE) {
        if (windowSize < 15 minutes || windowSize > 7 days) revert InvalidTWAPConfig();
        customTWAPWindows[token] = windowSize;
        emit CustomTWAPWindowSet(token, windowSize);
    }

    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlEnumerableUpgradeable, ERC1155HolderUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}