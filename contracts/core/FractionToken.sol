// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@chainlink/contracts/src/v0.8/interfaces/KeeperCompatibleInterface.sol";
import "./interfaces/ITerraStakeToken.sol";
import "./interfaces/ITerraStakeNFT.sol";

/**
 * @title FractionToken
 * @dev ERC20 token representing fractions of a TerraStake NFT
 */
contract FractionToken is ERC20, ERC20Burnable, ERC20Permit {
    uint256 public immutable nftId;
    address public immutable fractionManager;
    
    // Storing impact data directly in the token for transparency
    uint256 public immutable impactValue;
    ITerraStakeNFT.ProjectCategory public immutable projectCategory;
    bytes32 public immutable projectDataHash;

    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        uint256 _nftId,
        address _fractionManager,
        uint256 _impactValue,
        ITerraStakeNFT.ProjectCategory _projectCategory,
        bytes32 _projectDataHash
    ) ERC20(name, symbol) ERC20Permit(name) {
        nftId = _nftId;
        fractionManager = _fractionManager;
        impactValue = _impactValue;
        projectCategory = _projectCategory;
        projectDataHash = _projectDataHash;
        _mint(_fractionManager, initialSupply);
    }
}

/**
 * @title FractionToken
 * @dev Combined contract for fractionalization of TerraStake NFTs and governance
 * with integrated multisig and oracle-based pricing
 */
contract FractionToken is 
    ERC1155Holder, 
    AccessControl, 
    ReentrancyGuard, 
    Pausable,
    KeeperCompatibleInterface
{
    using ECDSA for bytes32;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // =====================================================
    // Roles - Clear separation of concerns
    // =====================================================
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant FRACTIONALIZER_ROLE = keccak256("FRACTIONALIZER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant URI_SETTER_ROLE = keccak256("URI_SETTER_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 public constant MULTISIG_MEMBER_ROLE = keccak256("MULTISIG_MEMBER_ROLE");
    bytes32 public constant ORACLE_MANAGER_ROLE = keccak256("ORACLE_MANAGER_ROLE");

    // =====================================================
    // Immutable state variables for gas optimization
    // =====================================================
    ITerraStakeNFT public immutable terraStakeNFT;
    ITerraStakeToken public immutable tStakeToken;
    
    // Constants
    uint256 public constant MAX_FRACTION_SUPPLY = 1e27;  // 1 billion tokens with 18 decimals
    uint256 public constant MIN_LOCK_PERIOD = 1 days;
    uint256 public constant MAX_LOCK_PERIOD = 365 days;
    uint256 public constant BASIS_POINTS = 10000;        // 100% in basis points
    uint256 public constant DEFAULT_TIMELOCK = 2 days;   // Default timelock period
    uint256 public constant MAX_PRICE_CHANGE_PERCENT = 2000; // 20% in basis points

    // =====================================================
    // Fractionalization Structs
    // =====================================================
    struct FractionData {
        address tokenAddress;     // Address of ERC20 token representing fractions
        uint256 nftId;            // Original NFT ID
        uint256 totalSupply;      // Total supply of fraction tokens
        uint256 redemptionPrice;  // Price in TStake to redeem the NFT
        bool isActive;            // Whether fractionalization is active
        uint256 lockEndTime;      // When the NFT can be redeemed
        address creator;          // Original NFT owner
        uint256 creationTime;     // When the fractionalization was created
        uint256 impactValue;      // The impact value of the NFT
        ITerraStakeNFT.ProjectCategory category; // Category of environmental project
        bytes32 verificationHash; // Hash of project verification data
    }

    struct FractionParams {
        uint256 tokenId;          // Original NFT ID
        uint256 fractionSupply;   // Total supply of fraction tokens
        uint256 initialPrice;     // Initial price per fraction
        string name;              // Name of the fraction token
        string symbol;            // Symbol of the fraction token
        uint256 lockPeriod;       // Period in seconds the NFT is locked
    }

    struct FractionMarketData {
        uint256 totalValueLocked; // Total value in TStake tokens
        uint256 totalActiveUsers; // Number of fraction holders
        uint256 volumeTraded;     // Volume of fractions traded
        uint256 lastTradePrice;   // Last trade price
        uint256 lastTradeTime;    // Last trade timestamp
    }

    struct AggregateMetrics {
        uint256 totalMarketCap;          // Total value of all fractionalized NFTs
        uint256 totalTradingVolume;      // Combined volume across all fraction tokens
        uint256 totalEnvironmentalImpact; // Total environmental impact value
        uint256 totalActiveTokens;       // Number of active fraction tokens
        uint256 averageTokenPrice;       // Average price across all fraction tokens
    }

    // =====================================================
    // Governance Structs
    // =====================================================
    struct Proposal {
        bytes32 proposalHash;      // Hash of the proposal data
        uint256 proposedTime;      // When the proposal was created
        uint256 requiredThreshold; // Required number of approvals
        bool executed;             // Whether the proposal has been executed
        bool isEmergency;          // Whether this is an emergency proposal
        address creator;           // Who created the proposal
        bool canceled;             // Whether the proposal was canceled
        uint256 executionTime;     // When the proposal can be executed (timelock)
        EnumerableSet.AddressSet approvers; // Who has approved
    }

    struct OracleConfig {
        address oracle;           // Chainlink price feed address
        uint256 heartbeatPeriod;  // Maximum time between updates
        int256 minPrice;          // Price floor
        int256 maxPrice;          // Price ceiling
        bool active;              // Whether this oracle is active
        uint256 lastUpdateTime;   // Last time price was updated
        uint256 updateInterval;   // How often to update (for keepers)
    }

    struct TimelockConfig {
        uint256 duration;         // Timelock duration for governance actions
        bool enabled;             // Whether timelock is enabled
    }

    // =====================================================
    // Errors
    // =====================================================
    error InvalidAddress();
    error NFTAlreadyFractionalized();
    error FractionalizationNotActive();
    error NFTStillLocked();
    error NoRedemptionOffer();
    error InsufficientBalance();
    error PriceTooHigh();
    error PriceTooLow();
    error TransferFailed();
    error InvalidFractionSupply();
    error InvalidLockPeriod();
    error FeeTooHigh();
    error NFTNotVerified();
    error InvalidAmount();
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
    error StalePrice();
    error PriceChangeExceedsLimit();
    error EmergencyActionFailed();
    error Unauthorized();
    error InvalidThreshold();
    error InvalidExpiry();
    error InvalidTimelock();
    error OnlyCreatorCanCancel();

    // =====================================================
    // Fractionalization state variables
    // =====================================================
    // Fee configuration
    uint256 public fractionalizationFee;   // Fee in TStake to fractionalize an NFT
    uint256 public tradingFeePercentage;   // Percentage fee on fraction trades (basis points)
    address public treasuryWallet;         // Treasury wallet for fees
    address public impactFundWallet;       // Impact fund wallet
    
    // Fraction tracking
    mapping(address => FractionData) public fractionData;  // Fraction token address => FractionData
    mapping(uint256 => address) public nftToFractionToken; // NFT ID => Fraction token address
    mapping(address => FractionMarketData) public marketData; // Fraction token address => Market data
    
    // Redemption offers
    mapping(address => uint256) public redemptionOffers; // Fraction token => Redemption price
    mapping(address => address) public redemptionOfferors; // Fraction token => Offeror address

    // Analytics tracking
    address[] public allFractionTokens; // Array of all fraction tokens ever created
    uint256 public totalVolumeTraded; // Total volume traded across all fraction tokens

    // =====================================================
    // Governance state variables
    // =====================================================
    uint256 public governanceThreshold; // Number of signatures required for governance actions
    uint256 public emergencyThreshold;  // Number of signatures required for emergency actions
    uint256 public proposalExpiryTime;  // Time after which a proposal expires
    
    // Maps proposal IDs to proposals
    mapping(bytes32 => Proposal) public proposals;
    
    // All proposal IDs for enumeration
    EnumerableSet.Bytes32Set private allProposals;
    
    // Maps token addresses to oracle configurations
    mapping(address => OracleConfig) public tokenOracles;
    
    // Tokens with oracle price feeds
    EnumerableSet.AddressSet private tokenWithOracles;
    
    // Timelock configuration
    TimelockConfig public timelockConfig;
    
    // Keeper configuration
    uint256 public lastKeeperUpdate;
    uint256 public keeperUpdateInterval;
    bool public keeperEnabled;

    // =====================================================
    // Events
    // =====================================================
    // Fractionalization events
    event NFTFractionalized(
        uint256 indexed nftId, 
        address fractionToken, 
        uint256 totalSupply, 
        address creator,
        ITerraStakeNFT.ProjectCategory category,
        uint256 impactValue
    );

    event NFTRedeemed(
        uint256 indexed nftId, 
        address redeemer, 
        uint256 redemptionPrice
    );

    event FractionsBought(
        address indexed buyer, 
        address indexed fractionToken, 
        uint256 amount, 
        uint256 price
    );

    event FractionsSold(
        address indexed seller, 
        address indexed fractionToken, 
        uint256 amount, 
        uint256 price
    );

    event RedemptionOffered(
        uint256 indexed nftId, 
        address fractionToken, 
        uint256 price, 
        address offeror
    );

    event MarketDataUpdated(
        address indexed fractionToken,
        uint256 totalValueLocked,
        uint256 volumeTraded,
        uint256 lastTradePrice
    );

    event FeeDistributed(
        address indexed recipient,
        uint256 amount,
        string feeType
    );

    event GlobalStatsUpdated(
        uint256 totalMarketCap,
        uint256 totalTradingVolume,
        uint256 totalEnvironmentalImpact
    );

    // Governance events
    event ProposalCreated(
        bytes32 indexed proposalId,
        address indexed proposer,
        bool isEmergency,
        bytes data,
        uint256 executionTime
    );
    
    event ProposalApproved(
        bytes32 indexed proposalId,
        address indexed approver,
        uint256 approvalCount,
        uint256 threshold
    );
    
    event ProposalExecuted(
        bytes32 indexed proposalId,
        address indexed executor,
        bool success
    );
    
    event ProposalExpired(
        bytes32 indexed proposalId
    );
    
    event ProposalCanceled(
        bytes32 indexed proposalId,
        address indexed canceler
    );
    
    event OracleConfigured(
        address indexed token,
        address indexed oracle,
        uint256 heartbeatPeriod,
        int256 minPrice,
        int256 maxPrice,
        uint256 updateInterval
    );
    
    event PriceUpdated(
        address indexed token,
        uint256 oldPrice,
        uint256 newPrice,
        address indexed oracle
    );
    
    event EmergencyActionExecuted(
        address indexed executor,
        bytes action
    );
    
    event RoleTransferred(
        bytes32 indexed role,
        address indexed oldAccount,
        address indexed newAccount
    );
    
    event TimelockConfigUpdated(
        uint256 duration,
        bool enabled
    );
    
    event KeeperConfigUpdated(
        uint256 interval,
        bool enabled
    );
    
    event MultisigMemberAdded(
        address indexed member
    );
        event MultisigMemberAdded(
        address indexed member
    );
    
    event MultisigMemberRemoved(
        address indexed member
    );

    // =====================================================
    // Constructor
    // =====================================================
    /**
     * @notice Initializes the combined fractionalization and governance contract
     * @param _terraStakeNFT Address of the TerraStakeNFT contract
     * @param _tStakeToken Address of the TStake token contract
     * @param _treasury Address of the treasury wallet
     * @param _impactFund Address of the impact fund wallet
     * @param _fee Initial fractionalization fee
     * @param _tradingFee Initial trading fee percentage (in basis points)
     * @param _governanceThreshold Number of signatures required for governance actions
     * @param _emergencyThreshold Number of signatures required for emergency actions
     * @param _proposalExpiryTime Time after which a proposal expires (in seconds)
     * @param _initialMembers Initial multisig members
     */
    constructor(
        address _terraStakeNFT,
        address _tStakeToken,
        address _treasury,
        address _impactFund,
        uint256 _fee,
        uint256 _tradingFee,
        uint256 _governanceThreshold,
        uint256 _emergencyThreshold,
        uint256 _proposalExpiryTime,
        address[] memory _initialMembers
    ) {
        // Validate addresses
        if (_terraStakeNFT == address(0) || 
            _tStakeToken == address(0) || 
            _treasury == address(0) || 
            _impactFund == address(0)) revert InvalidAddress();
        
        // Validate fee
        if (_tradingFee > 1000) revert FeeTooHigh(); // Max 10%
        
        // Validate governance parameters
        if (_governanceThreshold == 0 || _emergencyThreshold == 0) revert InvalidThreshold();
        if (_proposalExpiryTime < 1 hours) revert InvalidExpiry();
        
        // Set core contract references
        terraStakeNFT = ITerraStakeNFT(_terraStakeNFT);
        tStakeToken = ITerraStakeToken(_tStakeToken);
        
        // Set fractionalization parameters
        treasuryWallet = _treasury;
        impactFundWallet = _impactFund;
        fractionalizationFee = _fee;
        tradingFeePercentage = _tradingFee;
        
        // Set governance parameters
        governanceThreshold = _governanceThreshold;
        emergencyThreshold = _emergencyThreshold;
        proposalExpiryTime = _proposalExpiryTime;
        
        // Initialize timelock configuration
        timelockConfig = TimelockConfig({
            duration: DEFAULT_TIMELOCK,
            enabled: true
        });
        
        // Initialize keeper configuration
        keeperUpdateInterval = 1 days;
        keeperEnabled = true;
        lastKeeperUpdate = block.timestamp;
        
        // Setup roles hierarchy
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(FRACTIONALIZER_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(FEE_MANAGER_ROLE, msg.sender);
        _grantRole(ORACLE_MANAGER_ROLE, msg.sender);
        
        // Add initial multisig members
        for (uint256 i = 0; i < _initialMembers.length; i++) {
            if (_initialMembers[i] != address(0)) {
                _grantRole(MULTISIG_MEMBER_ROLE, _initialMembers[i]);
                emit MultisigMemberAdded(_initialMembers[i]);
            }
        }
    }

    // =====================================================
    // Fractionalization Functions
    // =====================================================
    /**
     * @notice Fractionalize an NFT by depositing it and minting ERC20 tokens
     * @param params The fractionalization parameters
     * @return fractionTokenAddress The address of the created ERC20 token
     */
    function fractionalize(FractionParams calldata params) 
        external 
        nonReentrant 
        whenNotPaused
        onlyRole(FRACTIONALIZER_ROLE)
        returns (address fractionTokenAddress) 
    {
        if (params.fractionSupply == 0 || params.fractionSupply > MAX_FRACTION_SUPPLY) 
            revert InvalidFractionSupply();
            
        if (params.lockPeriod < MIN_LOCK_PERIOD || params.lockPeriod > MAX_LOCK_PERIOD) 
            revert InvalidLockPeriod();
            
        if (nftToFractionToken[params.tokenId] != address(0)) 
            revert NFTAlreadyFractionalized();
        
        // Transfer the fractionalization fee
        bool feeTransferred = tStakeToken.transferFrom(msg.sender, address(this), fractionalizationFee);
        if (!feeTransferred) revert TransferFailed();
        
        // Transfer the NFT from the owner to this contract
        terraStakeNFT.safeTransferFrom(msg.sender, address(this), params.tokenId, 1, "");
        
        // Get the impact certificate to extract data
        ITerraStakeNFT.ImpactCertificate memory certificate = terraStakeNFT.getImpactCertificate(params.tokenId);
        ITerraStakeNFT.NFTMetadata memory metadata = terraStakeNFT.getTokenMetadata(params.tokenId);
        
        if (!certificate.isVerified) revert NFTNotVerified();
        
        // Create verification hash for data integrity
        bytes32 verificationHash = keccak256(abi.encodePacked(
            certificate.projectId,
            certificate.impactValue,
            certificate.reportHash,
            certificate.verificationDate
        ));
        
        // Deploy a new ERC20 token for this NFT
        FractionToken newFractionToken = new FractionToken(
            params.name,
            params.symbol,
            params.fractionSupply,
            params.tokenId,
            address(this),
            certificate.impactValue,
            certificate.category,
            certificate.reportHash
        );
        
        fractionTokenAddress = address(newFractionToken);
        
        // Register the fraction data
        FractionData memory data = FractionData({
            tokenAddress: fractionTokenAddress,
            nftId: params.tokenId,
            totalSupply: params.fractionSupply,
            redemptionPrice: params.initialPrice * params.fractionSupply,
            isActive: true,
            lockEndTime: block.timestamp + params.lockPeriod,
            creator: msg.sender,
            creationTime: block.timestamp,
            impactValue: certificate.impactValue,
            category: certificate.category,
            verificationHash: verificationHash
        });
        
        fractionData[fractionTokenAddress] = data;
        nftToFractionToken[params.tokenId] = fractionTokenAddress;
        
        // Initialize market data
        marketData[fractionTokenAddress] = FractionMarketData({
            totalValueLocked: params.initialPrice * params.fractionSupply,
            totalActiveUsers: 1, // Creator starts as the only user
            volumeTraded: 0,
            lastTradePrice: params.initialPrice,
            lastTradeTime: block.timestamp
        });
        
        // Add to the list of all fraction tokens for analytics
        allFractionTokens.push(fractionTokenAddress);
        
        // Transfer all tokens to the creator
        newFractionToken.transfer(msg.sender, params.fractionSupply);
        
        // Distribute the fee
        distributeFee(fractionalizationFee, "fractionalization");
        
        // Update global metrics for analytics
        updateGlobalMetrics();
        
        emit NFTFractionalized(
            params.tokenId, 
            fractionTokenAddress, 
            params.fractionSupply, 
            msg.sender,
            certificate.category,
            certificate.impactValue
        );
        
        return fractionTokenAddress;
    }

    /**
     * @notice Buy fractions from the contract (for initial offerings)
     * @param fractionToken The address of the fraction token
     * @param amount Amount of fractions to buy
     * @param maxPrice Maximum price willing to pay in TStake
     */
    function buyFractions(address fractionToken, uint256 amount, uint256 maxPrice) 
        external 
        nonReentrant 
        whenNotPaused
    {
        FractionData memory data = fractionData[fractionToken];
        if (!data.isActive) revert FractionalizationNotActive();
        
        FractionToken token = FractionToken(fractionToken);
        
        // Calculate the price - use oracle if available
        uint256 unitPrice = getTokenPrice(fractionToken);
        uint256 totalPrice = unitPrice * amount;
        
        if (totalPrice > maxPrice) revert PriceTooHigh();
        if (token.balanceOf(address(this)) < amount) revert InsufficientBalance();
        
        // Calculate and transfer the fee
        uint256 fee = (totalPrice * tradingFeePercentage) / BASIS_POINTS;
        uint256 netPrice = totalPrice + fee;
        
        bool transferred = tStakeToken.transferFrom(msg.sender, address(this), netPrice);
        if (!transferred) revert TransferFailed();
        
        // Transfer fractions to buyer
        token.transfer(msg.sender, amount);
        
        // Update market data
        FractionMarketData storage market = marketData[fractionToken];
        market.volumeTraded += amount;
        market.lastTradePrice = unitPrice;
        market.lastTradeTime = block.timestamp;
        market.totalActiveUsers += 1; // This is approximate
        
        // Update global trading volume
        totalVolumeTraded += amount;
        
        // Distribute the fee
        distributeFee(fee, "trading");
        
        // Update global metrics
        updateGlobalMetrics();
        
        emit FractionsBought(msg.sender, fractionToken, amount, totalPrice);
        emit MarketDataUpdated(
            fractionToken,
            market.totalValueLocked,
            market.volumeTraded,
            market.lastTradePrice
        );
    }

    /**
     * @notice Distribute fees between treasury and impact fund
     * @param amount Amount to distribute
     * @param feeType Type of fee being distributed
     */
    function distributeFee(uint256 amount, string memory feeType) internal {
        // 70% to treasury, 30% to impact fund
        uint256 treasuryAmount = (amount * 70) / 100;
        uint256 impactAmount = amount - treasuryAmount;
        
        bool treasuryTransferred = tStakeToken.transfer(treasuryWallet, treasuryAmount);
        bool impactTransferred = tStakeToken.transfer(impactFundWallet, impactAmount);
        
        if (!treasuryTransferred || !impactTransferred) revert TransferFailed();
        
        emit FeeDistributed(treasuryWallet, treasuryAmount, feeType);
        emit FeeDistributed(impactFundWallet, impactAmount, feeType);
    }

    /**
     * @notice Update price of a fraction token - accessible via governance or oracle
     * @param fractionToken Address of the fraction token
     * @param newPrice New price per token
     */
    function updateMarketPrice(address fractionToken, uint256 newPrice) 
        external 
        onlyRole(OPERATOR_ROLE)
    {
        if (newPrice == 0) revert InvalidPrice();
        if (fractionData[fractionToken].tokenAddress == address(0)) revert InvalidAddress();
        
        FractionMarketData storage market = marketData[fractionToken];
        uint256 oldPrice = market.lastTradePrice;
        
        // Price guardrail: check if price change exceeds limit
        if (oldPrice > 0) {
            uint256 priceChange;
            if (newPrice > oldPrice) {
                priceChange = ((newPrice - oldPrice) * BASIS_POINTS) / oldPrice;
            } else {
                priceChange = ((oldPrice - newPrice) * BASIS_POINTS) / oldPrice;
            }
            
            if (priceChange > MAX_PRICE_CHANGE_PERCENT) {
                revert PriceChangeExceedsLimit();
            }
        }
        
        market.lastTradePrice = newPrice;
        market.lastTradeTime = block.timestamp;
        
        // Update oracle's last update time
        if (tokenOracles[fractionToken].active) {
            tokenOracles[fractionToken].lastUpdateTime = block.timestamp;
        }
        
        emit MarketDataUpdated(
            fractionToken,
            market.totalValueLocked,
            market.volumeTraded,
            newPrice
        );
        
        emit PriceUpdated(fractionToken, oldPrice, newPrice, address(0)); // Manual update
    }
    
    /**
     * @notice Get token price from oracle or fallback to last trade price
     * @param fractionToken Address of the fraction token
     * @return price Current price of the token
     */
    function getTokenPrice(address fractionToken) public view returns (uint256 price) {
        // Check if we have an active oracle for this token
        OracleConfig memory config = tokenOracles[fractionToken];
        
        if (config.active && config.oracle != address(0)) {
            try this.getLatestOraclePrice(fractionToken) returns (
                uint256 oraclePrice,
                uint256 timestamp,
                bool isValid
            ) {
                if (isValid) {
                    return oraclePrice;
                }
            } catch {
                // Fallback to last trade price
            }
        }
        
        // Return last trade price as fallback
        return marketData[fractionToken].lastTradePrice;
    }

    /**
     * @notice Get aggregate metrics across all fractionalized NFTs
     * @return metrics Aggregate metrics struct with global statistics
     */
    function getAggregateMetrics() 
        external 
        view 
        returns (AggregateMetrics memory metrics) 
    {
        metrics.totalActiveTokens = 0;
        uint256 totalPriceSum = 0;
        
        for (uint256 i = 0; i < allFractionTokens.length; i++) {
            address tokenAddress = allFractionTokens[i];
            FractionData memory data = fractionData[tokenAddress];
            FractionMarketData memory market = marketData[tokenAddress];
            
            if (data.isActive) {
                metrics.totalActiveTokens++;
                
                // Use current token price (potentially from oracle)
                uint256 currentPrice = getTokenPrice(tokenAddress);
                
                // Calculate market cap for this token
                uint256 tokenMarketCap = currentPrice * data.totalSupply;
                metrics.totalMarketCap += tokenMarketCap;
                
                // Add environmental impact
                metrics.totalEnvironmentalImpact += data.impactValue;
                
                // Add to price sum for average calculation
                totalPriceSum += currentPrice;
            }
        }
        
        // Set total trading volume from global counter
        metrics.totalTradingVolume = totalVolumeTraded;
        
        // Calculate average token price if there are active tokens
        if (metrics.totalActiveTokens > 0) {
            metrics.averageTokenPrice = totalPriceSum / metrics.totalActiveTokens;
        }
        
        return metrics;
    }
    
    /**
     * @notice Update global metrics used for analytics
     */
    function updateGlobalMetrics() internal {
        uint256 totalMarketCap = 0;
        uint256 totalImpact = 0;
        
        for (uint256 i = 0; i < allFractionTokens.length; i++) {
            address tokenAddress = allFractionTokens[i];
            FractionData memory data = fractionData[tokenAddress];
            
            if (data.isActive) {
                // Get current price (potentially from oracle)
                uint256 currentPrice = getTokenPrice(tokenAddress);
                
                // Calculate market cap
                uint256 marketCap = currentPrice * data.totalSupply;
                totalMarketCap += marketCap;
                
                // Add environmental impact
                totalImpact += data.impactValue;
            }
        }
        
        emit GlobalStatsUpdated(
            totalMarketCap,
            totalVolumeTraded,
            totalImpact
        );
    }

    // =====================================================
    // Governance Functions
    // =====================================================
    /**
     * @notice Create a governance proposal
     * @param targetContract Contract address to call
     * @param value ETH value to send
     * @param data Function call data
     * @param description Description of the proposal
     * @param isEmergency Whether this is an emergency proposal
     * @return proposalId The ID of the created proposal
     */
    function createProposal(
        address targetContract,
        uint256 value,
        bytes calldata data,
        string calldata description,
        bool isEmergency
    ) 
        external
        onlyRole(MULTISIG_MEMBER_ROLE)
        returns (bytes32 proposalId)
    {
        // Create proposal hash
        bytes32 proposalDataHash = keccak256(abi.encode(
            targetContract,
            value,
            data,
            description
        ));
        
        // Generate unique ID
        proposalId = keccak256(abi.encode(
            proposalDataHash,
            block.timestamp,
            msg.sender
        ));
        
        // Check if proposal exists
        if (proposals[proposalId].proposedTime != 0) revert ProposalAlreadyExists();
        
        // Determine threshold
        uint256 requiredThreshold = isEmergency ? emergencyThreshold : governanceThreshold;
        
        // Calculate execution time with timelock
        uint256 executionTime;
        if (timelockConfig.enabled && !isEmergency) {
            executionTime = block.timestamp + timelockConfig.duration;
        } else {
            executionTime = block.timestamp; // No timelock for emergency proposals
        }
        
        // Create new proposal
        Proposal storage newProposal = proposals[proposalId];
        newProposal.proposalHash = proposalDataHash;
        newProposal.proposedTime = block.timestamp;
        newProposal.requiredThreshold = requiredThreshold;
        newProposal.executed = false;
        newProposal.isEmergency = isEmergency;
        newProposal.creator = msg.sender;
        newProposal.canceled = false;
        newProposal.executionTime = executionTime;
        
        // Auto-approve from creator
        newProposal.approvers.add(msg.sender);
        
        // Add to set of all proposals
        allProposals.add(proposalId);
        
        emit ProposalCreated(proposalId, msg.sender, isEmergency, data, executionTime);
        emit ProposalApproved(proposalId, msg.sender, 1, requiredThreshold);
        
        return proposalId;
    }
    
    /**
     * @notice Approve a proposal
     * @param proposalId The ID of the proposal to approve
     */
    function approveProposal(bytes32 proposalId) 
        external
        onlyRole(MULTISIG_MEMBER_ROLE)
    {
        Proposal storage proposal = proposals[proposalId];
        
        // Verify proposal exists
        if (proposal.proposedTime == 0) revert ProposalDoesNotExist();
        
        // Check proposal is not executed
        if (proposal.executed) revert ProposalAlreadyExecuted();
        
        // Check proposal has not expired
        if (block.timestamp > proposal.proposedTime + proposalExpiryTime) revert ProposalExpired();
        
        // Check proposal is not canceled
        if (proposal.canceled) revert ProposalCanceled();
        
        // Check approver hasn't already approved
        if (proposal.approvers.contains(msg.sender)) revert ProposalAlreadyApproved();
        
        // Add approval
        proposal.approvers.add(msg.sender);
        
        emit ProposalApproved(
            proposalId, 
            msg.sender, 
            proposal.approvers.length(), 
            proposal.requiredThreshold
        );
    }
    
    /**
     * @notice Cancel a proposal (only creator or governance role)
     * @param proposalId The ID of the proposal to cancel
     */
    function cancelProposal(bytes32 proposalId)
        external
    {
        Proposal storage proposal = proposals[proposalId];
        
        // Verify proposal exists
        if (proposal.proposedTime == 0) revert ProposalDoesNotExist();
        
        // Check proposal is not executed
        if (proposal.executed) revert ProposalAlreadyExecuted();
        
        // Check proposal is not already canceled
        if (proposal.canceled) revert ProposalCanceled();
        
        // Only creator or governance role can cancel
        if (msg.sender != proposal.creator && !hasRole(GOVERNANCE_ROLE, msg.sender)) {
            revert OnlyCreatorCanCancel();
        }
        
        // Mark as canceled
        proposal.canceled = true;
        
        emit ProposalCanceled(proposalId, msg.sender);
    }
    
    /**
     * @notice Execute a proposal once it has sufficient approvals
     * @param proposalId The ID of the proposal to execute
     * @param targetContract Contract address to call
     * @param value ETH value to send
     * @param data Function call data
     * @return success Whether the execution was successful
     */
    function executeProposal(
        bytes32 proposalId,
        address targetContract,
        uint256 value,
        bytes calldata data
    ) 
        external
        onlyRole(MULTISIG_MEMBER_ROLE)
        returns (bool success)
    {
        Proposal storage proposal = proposals[proposalId];
        
        // Verify proposal exists
        if (proposal.proposedTime == 0) revert ProposalDoesNotExist();
        
        // Check proposal is not executed
        if (proposal.executed) revert ProposalAlreadyExecuted();
        
        // Check proposal has not expired
        if (block.timestamp > proposal.proposedTime + proposalExpiryTime) revert ProposalExpired();
        
        // Check proposal is not canceled
        if (proposal.canceled) revert ProposalCanceled();
        
        // Check timelock period has passed
        if (block.timestamp < proposal.executionTime) revert ProposalTimelocked();
        
        // Verify data hash
        bytes32 dataHash = keccak256(abi.encode(
            targetContract,
            value,
            data,
            "" // description is omitted for verification, can be different
        ));
        
        if (proposal.proposalHash != dataHash) revert Unauthorized();
        
        // Check sufficient approvals
        if (proposal.approvers.length() < proposal.requiredThreshold) revert InsufficientApprovals();
        
        // Mark proposal as executed
        proposal.executed = true;
        
        // Execute the proposal
        (success, ) = targetContract.call{value: value}(data);
        if (!success) revert ExecutionFailed();
        
        emit ProposalExecuted(proposalId, msg.sender, success);
        
        return success;
    }

    // =====================================================
    // Oracle Integration
    // =====================================================
    /**
     * @notice Configure an oracle for a fraction token
     * @param token The fraction token address
     * @param oracle The oracle price feed address
     * @param heartbeatPeriod Maximum time between updates
     * @param minPrice Price floor
     * @param maxPrice Price ceiling
     * @param updateInterval How often to update via keeper
     */
    function configureOracle(
        address token,
        address oracle,
        uint256 heartbeatPeriod,
        int256 minPrice,
        int256 maxPrice,
        uint256 updateInterval
    ) 
        external
        onlyRole(ORACLE_MANAGER_ROLE)
    {
        if (token == address(0) || oracle == address(0)) revert InvalidAddress();
        if (heartbeatPeriod == 0) revert InvalidOracleConfig();
        if (minPrice <= 0 || maxPrice <= minPrice) revert InvalidOracleConfig();
        if (updateInterval == 0) revert InvalidOracleConfig();
        
        // Store oracle configuration
        tokenOracles[token] = OracleConfig({
            oracle: oracle,
            heartbeatPeriod: heartbeatPeriod,
            minPrice: minPrice,
            maxPrice: maxPrice,
            active: true,
            lastUpdateTime: block.timestamp,
            updateInterval: updateInterval
        });
        
        // Add to tracked tokens
        tokenWithOracles.add(token);
        
        emit OracleConfigured(token, oracle, heartbeatPeriod, minPrice, maxPrice, updateInterval);
    }
    
    /**
     * @notice Update token price based on oracle data
     * @param token The fraction token address
     * @return newPrice The updated price from the oracle
     */
    function updatePriceFromOracle(address token) 
        external
        onlyRole(OPERATOR_ROLE)
        returns (uint256 newPrice)
    {
        OracleConfig memory config = tokenOracles[token];
        
        // Check oracle exists and is active
        if (!config.active || config.oracle == address(0)) revert InvalidOracleConfig();
        
        // Get price from Chainlink
        AggregatorV3Interface oracle = AggregatorV3Interface(config.oracle);
        (
            uint80 roundId,
            int256 price,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = oracle.latestRoundData();
        
        // Validate price data
        if (answeredInRound < roundId) revert StalePrice();
        if (block.timestamp - updatedAt > config.heartbeatPeriod) revert StalePrice();
        if (price < config.minPrice || price > config.maxPrice) revert InvalidPrice();
        
        // Convert to uint256 (all prices assumed positive)
        newPrice = uint256(price);
        
        // Get current price from fractions contract
        uint256 oldPrice = marketData[token].lastTradePrice;
        
        // Price guardrail: check if price change exceeds limit
        if (oldPrice > 0) {
            uint256 priceChange;
            if (newPrice > oldPrice) {
                priceChange = ((newPrice - oldPrice) * BASIS_POINTS) / oldPrice;
            } else {
                priceChange = ((oldPrice - newPrice) * BASIS_POINTS) / oldPrice;
            }
            
            if (priceChange > MAX_PRICE_CHANGE_PERCENT) {
                revert PriceChangeExceedsLimit();
            }
        }
        
        // Update price in market data
        marketData[token].lastTradePrice = newPrice;
        marketData[token].lastTradeTime = block.timestamp;
        tokenOracles[token].lastUpdateTime = block.timestamp;
        
        // Update metrics
        updateGlobalMetrics();
        
        emit PriceUpdated(token, oldPrice, newPrice, config.oracle);
        emit MarketDataUpdated(
            token,
            marketData[token].totalValueLocked,
            marketData[token].volumeTraded,
            newPrice
        );
        
        return newPrice;
    }
    
    /**
     * @notice Update prices for all tokens with oracles
     * @return updatedCount Number of tokens successfully updated
     */
    function updateAllPrices() external returns (uint256 updatedCount) {
        uint256 tokenCount = tokenWithOracles.length();
        
        for (uint256 i = 0; i < tokenCount; i++) {
            address token = tokenWithOracles.at(i);
            OracleConfig memory config = tokenOracles[token];
            
            // Skip inactive oracles or those not due for update
            if (!config.active || block.timestamp < config.lastUpdateTime + config.updateInterval) {
                continue;
            }
            
            // Try to update each token price, continue on failure
            try this.updatePriceFromOracle(token) returns (uint256) {
                updatedCount++;
            } catch {
                // Continue to next token
            }
        }
        
        return updatedCount;
    }

    /**
     * @notice Get the latest price from an oracle without updating on-chain
     * @param token The fraction token address
     * @return price The current price from the oracle
     * @return timestamp When the price was last updated
     * @return isValid Whether the price is valid and not stale
     */
    function getLatestOraclePrice(address token)
        external
        view
        returns (
            uint256 price,
            uint256 timestamp,
            bool isValid
        )
    {
        OracleConfig memory config = tokenOracles[token];
        
        // Check oracle exists and is active
        if (!config.active || config.oracle == address(0)) {
            return (0, 0, false);
        }
        
        // Get price from Chainlink
        AggregatorV3Interface oracle = AggregatorV3Interface(config.oracle);
        try oracle.latestRoundData() returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            // Check price validity
            bool valid = answeredInRound >= roundId && 
                         block.timestamp - updatedAt <= config.heartbeatPeriod &&
                         answer >= config.minPrice && 
                         answer <= config.maxPrice;
            
            return (valid ? uint256(answer) : 0, updatedAt, valid);
        } catch {
            return (0, 0, false);
        }
    }

    // =====================================================
    // Chainlink Keeper Implementation
    // =====================================================
    /**

     * @notice Check if upkeep is needed
     * @return upkeepNeeded Whether upkeep is needed
     * @return performData The data to perform the upkeep
     */
    function checkUpkeep(bytes calldata) 
        external 
        view 
        override 
        returns (bool upkeepNeeded, bytes memory performData) 
    {
        if (!keeperEnabled) {
            return (false, "");
        }
        
        // Check if global update interval has passed
        bool globalUpdateNeeded = block.timestamp >= lastKeeperUpdate + keeperUpdateInterval;
        
        // Check if any individual token needs updating
        address[] memory tokensToUpdate = new address[](tokenWithOracles.length());
        uint256 count = 0;
        
        for (uint256 i = 0; i < tokenWithOracles.length(); i++) {
            address token = tokenWithOracles.at(i);
            OracleConfig memory config = tokenOracles[token];
            
            if (config.active && block.timestamp >= config.lastUpdateTime + config.updateInterval) {
                tokensToUpdate[count] = token;
                count++;
            }
        }
        
        // Resize the array to only include tokens that need updating
        if (count > 0 || globalUpdateNeeded) {
            address[] memory finalTokens = new address[](count);
            for (uint256 i = 0; i < count; i++) {
                finalTokens[i] = tokensToUpdate[i];
            }
            
            upkeepNeeded = true;
            performData = abi.encode(finalTokens, globalUpdateNeeded);
        }
        
        return (upkeepNeeded, performData);
    }
    
    /**
     * @notice Perform keeper upkeep
     * @param performData Data needed for the upkeep
     */
    function performUpkeep(bytes calldata performData) external override {
        if (!keeperEnabled) return;
        
        // Decode perform data
        (address[] memory tokensToUpdate, bool globalUpdateNeeded) = abi.decode(
            performData, 
            (address[], bool)
        );
        
        // Update tokens based on the list
        for (uint256 i = 0; i < tokensToUpdate.length; i++) {
            try this.updatePriceFromOracle(tokensToUpdate[i]) returns (uint256) {
                // Successfully updated
            } catch {
                // Continue on failure
            }
        }
        
        // Perform global update if needed
        if (globalUpdateNeeded) {
            updateGlobalMetrics();
            lastKeeperUpdate = block.timestamp;
        }
    }
    
    /**
     * @notice Configure keeper settings
     * @param interval Update interval for keeper
     * @param enabled Whether keeper is enabled
     */
    function configureKeeper(uint256 interval, bool enabled)
        external
        onlyRole(ORACLE_MANAGER_ROLE)
    {
        keeperUpdateInterval = interval;
        keeperEnabled = enabled;
        
        emit KeeperConfigUpdated(interval, enabled);
    }

    // =====================================================
    // Emergency Control Functions
    // =====================================================
    /**
     * @notice Execute emergency action with immediate effect
     * @param targetContract Contract to call
     * @param data Function call data
     */
    function executeEmergencyAction(address targetContract, bytes calldata data) 
        external
        onlyRole(EMERGENCY_ROLE)
        returns (bool)
    {
        if (targetContract == address(0)) revert InvalidAddress();
        
        // Execute the emergency action
        (bool success, ) = targetContract.call(data);
        if (!success) revert EmergencyActionFailed();
        
        emit EmergencyActionExecuted(msg.sender, data);
        
        return success;
    }
    
    /**
     * @notice Emergency pause of all contract functions
     */
    function emergencyPause() 
        external
        onlyRole(EMERGENCY_ROLE)
    {
        _pause();
        emit EmergencyActionExecuted(msg.sender, "");
    }
    
    /**
     * @notice Unpause after emergency is resolved
     */
    function emergencyUnpause() 
        external
        onlyRole(EMERGENCY_ROLE)
    {
        _unpause();
        emit EmergencyActionExecuted(msg.sender, "");
    }
    
    /**
     * @notice Emergency withdraw of NFT in case of critical issues
     * @param fractionToken The address of the fraction token
     * @param recipient The address to receive the NFT
     */
    function emergencyWithdrawNFT(address fractionToken, address recipient)
        external
        onlyRole(EMERGENCY_ROLE)
        whenPaused  // Only callable when paused for safety
    {
        if (recipient == address(0)) revert InvalidAddress();
        
        FractionData memory data = fractionData[fractionToken];
        if (data.tokenAddress == address(0)) revert InvalidAddress();
        
        // Transfer the NFT to the recipient
        terraStakeNFT.safeTransferFrom(address(this), recipient, data.nftId, 1, "");
        
        // Mark fractionalization as inactive
        fractionData[fractionToken].isActive = false;
        
        emit EmergencyActionExecuted(msg.sender, abi.encode(fractionToken, recipient));
    }

    // =====================================================
    // Governance Parameter Management
    // =====================================================
    /**
     * @notice Update governance threshold
     * @param newThreshold New governance threshold
     */
    function updateGovernanceThreshold(uint256 newThreshold) 
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        if (newThreshold == 0) revert InvalidThreshold();
        governanceThreshold = newThreshold;
    }
    
    /**
     * @notice Update emergency threshold
     * @param newThreshold New emergency threshold
     */
    function updateEmergencyThreshold(uint256 newThreshold) 
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        if (newThreshold == 0) revert InvalidThreshold();
        emergencyThreshold = newThreshold;
    }
    
    /**
     * @notice Update proposal expiry time
     * @param newExpiryTime New expiry time in seconds
     */
    function updateProposalExpiryTime(uint256 newExpiryTime) 
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        if (newExpiryTime < 1 hours) revert InvalidExpiry();
        proposalExpiryTime = newExpiryTime;
    }

    /**
     * @notice Update timelock configuration
     * @param duration Timelock duration
     * @param enabled Whether timelock is enabled
     */
    function updateTimelockConfig(uint256 duration, bool enabled)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        if (duration < 1 hours) revert InvalidTimelock();
        
        timelockConfig.duration = duration;
        timelockConfig.enabled = enabled;
        
        emit TimelockConfigUpdated(duration, enabled);
    }

    /**
     * @notice Set fractionalization fee
     * @param newFee The new fee amount
     */
    function setFractionalizationFee(uint256 newFee) 
        external 
        onlyRole(FEE_MANAGER_ROLE)
    {
        fractionalizationFee = newFee;
    }

    /**
     * @notice Set the trading fee percentage
     * @param newFeePercentage The new fee percentage in basis points
     */
    function setTradingFeePercentage(uint256 newFeePercentage) 
        external 
        onlyRole(FEE_MANAGER_ROLE)
    {
        if (newFeePercentage > 1000) revert FeeTooHigh(); // Max 10%
        tradingFeePercentage = newFeePercentage;
    }

    /**
     * @notice Update treasury and impact fund addresses
     * @param newTreasury New treasury address
     * @param newImpactFund New impact fund address
     */
    function updateFeeRecipients(address newTreasury, address newImpactFund)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        if (newTreasury == address(0) || newImpactFund == address(0)) revert InvalidAddress();
        
        treasuryWallet = newTreasury;
        impactFundWallet = newImpactFund;
    }

    /**
     * @notice Add multisig member through governance
     * @param member Address to add as a multisig member
     */
    function addMultisigMember(address member)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        if (member == address(0)) revert InvalidAddress();
        if (hasRole(MULTISIG_MEMBER_ROLE, member)) return; // Already a member
        
        _grantRole(MULTISIG_MEMBER_ROLE, member);
        emit MultisigMemberAdded(member);
    }
    
    /**
     * @notice Remove multisig member through governance
     * @param member Address to remove from multisig
     */
    function removeMultisigMember(address member)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        if (!hasRole(MULTISIG_MEMBER_ROLE, member)) return; // Not a member
        
        _revokeRole(MULTISIG_MEMBER_ROLE, member);
        emit MultisigMemberRemoved(member);
    }
    
    /**
     * @notice Transfer a role from one address to another
     * @param role The role to transfer
     * @param from Current role holder
     * @param to New role holder
     */
    function transferRole(bytes32 role, address from, address to)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        if (to == address(0)) revert InvalidAddress();
        if (!hasRole(role, from)) revert Unauthorized();
        
        _revokeRole(role, from);
        _grantRole(role, to);
        
        emit RoleTransferred(role, from, to);
    }

    // =====================================================
    // NFT Redemption
    // =====================================================
    /**
     * @notice Offer to redeem an NFT by buying all remaining fractions
     * @param fractionToken The address of the fraction token
     * @param offerPrice The price offered for redemption
     */
    function offerRedemption(address fractionToken, uint256 offerPrice)
        external
        nonReentrant
        whenNotPaused
    {
        FractionData memory data = fractionData[fractionToken];
        if (!data.isActive) revert FractionalizationNotActive();
        
        // Ensure lock period has ended
        if (block.timestamp < data.lockEndTime) revert NFTStillLocked();
        
        // Store the redemption offer
        redemptionOffers[fractionToken] = offerPrice;
        redemptionOfferors[fractionToken] = msg.sender;
        
        emit RedemptionOffered(data.nftId, fractionToken, offerPrice, msg.sender);
    }
    
    /**
     * @notice Redeem the NFT by completing the redemption offer
     * @param fractionToken The address of the fraction token
     */
    function redeemNFT(address fractionToken)
        external
        nonReentrant
        whenNotPaused
    {
        FractionData memory data = fractionData[fractionToken];
        if (!data.isActive) revert FractionalizationNotActive();
        
        // Ensure lock period has ended
        if (block.timestamp < data.lockEndTime) revert NFTStillLocked();
        
        uint256 offerPrice = redemptionOffers[fractionToken];
        address offeror = redemptionOfferors[fractionToken];
        
        // Verify there's a valid offer
        if (offerPrice == 0 || offeror == address(0)) revert NoRedemptionOffer();
        if (offeror != msg.sender) revert Unauthorized();
        
        FractionToken token = FractionToken(fractionToken);
        uint256 remainingSupply = token.totalSupply() - token.balanceOf(msg.sender);
        
        // Calculate the redemption cost
        uint256 totalRedemptionCost = remainingSupply * marketData[fractionToken].lastTradePrice;
        if (totalRedemptionCost > offerPrice) revert InsufficientBalance();
        
        // Transfer TStake from redeemer to this contract
        bool transferred = tStakeToken.transferFrom(msg.sender, address(this), totalRedemptionCost);
        if (!transferred) revert TransferFailed();
        
        // Transfer the NFT to the redeemer
        terraStakeNFT.safeTransferFrom(address(this), msg.sender, data.nftId, 1, "");
        
        // Mark fractionalization as inactive
        fractionData[fractionToken].isActive = false;
        
        // Clear redemption offers
        delete redemptionOffers[fractionToken];
        delete redemptionOfferors[fractionToken];
        
        // Update metrics
        updateGlobalMetrics();
        
        emit NFTRedeemed(data.nftId, msg.sender, totalRedemptionCost);
    }
    
    /**
     * @notice Allow token holders to claim their portion of a redemption offer
     * @param fractionToken The fraction token address
     */
    function claimRedemptionShare(address fractionToken)
        external
        nonReentrant
        whenNotPaused
    {
        FractionData memory data = fractionData[fractionToken];
        if (data.isActive) revert FractionalizationStillActive();
        
        FractionToken token = FractionToken(fractionToken);
        uint256 balance = token.balanceOf(msg.sender);
        
        if (balance == 0) revert InsufficientBalance();
        
        // Calculate holder's share of the redemption offer
        uint256 offerPrice = redemptionOffers[fractionToken];
        uint256 share = (offerPrice * balance) / token.totalSupply();
        
        // Burn the fractions
        token.burnFrom(msg.sender, balance);
        
        // Transfer TStake to the holder
        bool transferred = tStakeToken.transfer(msg.sender, share);
        if (!transferred) revert TransferFailed();
        
        emit FractionsSold(msg.sender, fractionToken, balance, share);
    }

    // =====================================================
    // View Functions
    // =====================================================
    /**
     * @notice Get proposal details
     * @param proposalId The proposal ID
     * @return proposalHash The hash of the proposal data
     * @return proposedTime When the proposal was created
     * @return requiredThreshold Required number of approvals
     * @return executed Whether the proposal has been executed
     * @return isEmergency Whether this is an emergency proposal
     * @return canceled Whether the proposal was canceled
     * @return executionTime When the proposal can be executed
     * @return approvalCount Number of approvals
     * @return expired Whether the proposal has expired
     * @return creator Who created the proposal
     */
    function getProposalDetails(bytes32 proposalId)
        external
        view
        returns (
            bytes32 proposalHash,
            uint256 proposedTime,
            uint256 requiredThreshold,
            bool executed,
            bool isEmergency,
            bool canceled,
            uint256 executionTime,
            uint256 approvalCount,
            bool expired,
            address creator
        )
    {
        Proposal storage proposal = proposals[proposalId];
        
        // Check if proposal exists
        if (proposal.proposedTime == 0) {
            return (bytes32(0), 0, 0, false, false, false, 0, 0, false, address(0));
        }
        
        return (
            proposal.proposalHash,
            proposal.proposedTime,
            proposal.requiredThreshold,
            proposal.executed,
            proposal.isEmergency,
            proposal.canceled,
            proposal.executionTime,
            proposal.approvers.length(),
            block.timestamp > proposal.proposedTime + proposalExpiryTime,
            proposal.creator
        );
    }

    /**
     * @notice Check if an address has approved a proposal
     * @param proposalId The proposal ID
     * @param approver The address to check
     * @return hasApproved Whether the address has approved the proposal
     */
    function hasApprovedProposal(bytes32 proposalId, address approver)
        external
        view
        returns (bool hasApproved)
    {
        return proposals[proposalId].approvers.contains(approver);
    }
    
    /**
     * @notice Get all active proposals
     * @return activeProposalIds Array of active proposal IDs
     */
    function getActiveProposals() external view returns (bytes32[] memory activeProposalIds) {
        // Count active proposals
        uint256 activeCount = 0;
        for (uint256 i = 0; i < allProposals.length(); i++) {
            bytes32 proposalId = allProposals.at(i);
            Proposal storage proposal = proposals[proposalId];
            
            if (!proposal.executed && 
                !proposal.canceled && 
                block.timestamp <= proposal.proposedTime + proposalExpiryTime) {
                activeCount++;
            }
        }
        
        // Create return array
        activeProposalIds = new bytes32[](activeCount);
        
        // Populate return array
        uint256 index = 0;
        for (uint256 i = 0; i < allProposals.length() && index < activeCount; i++) {
            bytes32 proposalId = allProposals.at(i);
            Proposal storage proposal = proposals[proposalId];
            
            if (!proposal.executed && 
                !proposal.canceled && 
                block.timestamp <= proposal.proposedTime + proposalExpiryTime) {
                activeProposalIds[index] = proposalId;
                index++;
            }
        }
        
        return activeProposalIds;
    }

    /**
     * @notice Get the number of active oracles
     * @return count Number of active oracles
     */
    function getActiveOracleCount() external view returns (uint256 count) {
        uint256 tokenCount = tokenWithOracles.length();
        
        for (uint256 i = 0; i < tokenCount; i++) {
            address token = tokenWithOracles.at(i);
            if (tokenOracles[token].active) {
                count++;
            }
        }
        
        return count;
    }

    /**
     * @notice Get all active fractionalized NFTs
     * @return activeFractions Array of active fraction token addresses
     */
    function getActiveFractions() external view returns (address[] memory activeFractions) {
        // Count active fractions
        uint256 activeCount = 0;
        for (uint256 i = 0; i < allFractionTokens.length; i++) {
            if (fractionData[allFractionTokens[i]].isActive) {
                activeCount++;
            }
        }
        
        // Create return array
        activeFractions = new address[](activeCount);
        
        // Populate return array
        uint256 index = 0;
        for (uint256 i = 0; i < allFractionTokens.length && index < activeCount; i++) {
            address token = allFractionTokens[i];
            if (fractionData[token].isActive) {
                activeFractions[index] = token;
                index++;
            }
        }
        
        return activeFractions;
    }

    /**
     * @notice Get the market data for a fraction token
     * @param fractionToken The fraction token address
     * @return data The market data for the token
     */
    function getMarketData(address fractionToken) 
        external 
        view 
        returns (FractionMarketData memory data) 
    {
        return marketData[fractionToken];
    }

    /**
     * @notice Check if a member can make governance decisions
     * @param member The address to check
     * @return isGovernanceMember Whether the address is a governance member
     */
    function isGovernanceMember(address member) 
        external 
        view 
        returns (bool isGovernanceMember) 
    {
        return hasRole(MULTISIG_MEMBER_ROLE, member);
    }

    /**
     * @notice Check for required upkeep of oracles
     * @return needsUpdate Whether any oracle needs updating
     * @return tokensToUpdate Array of token addresses that need price updates
     */
    function checkOracleUpdateNeeded() external view returns (bool needsUpdate, address[] memory tokensToUpdate) {
        uint256 tokenCount = tokenWithOracles.length();
        address[] memory tokens = new address[](tokenCount);
        uint256 needUpdateCount = 0;
        
        for (uint256 i = 0; i < tokenCount; i++) {
            address token = tokenWithOracles.at(i);
            OracleConfig memory config = tokenOracles[token];
            
            if (config.active && block.timestamp >= config.lastUpdateTime + config.updateInterval) {
                tokens[needUpdateCount] = token;
                needUpdateCount++;
            }
        }
        
        // Resize array to actual count
        tokensToUpdate = new address[](needUpdateCount);
        for (uint256 i = 0; i < needUpdateCount; i++) {
            tokensToUpdate[i] = tokens[i];
        }
        
        return (needUpdateCount > 0, tokensToUpdate);
    }

    // =====================================================
    // External contract interactions
    // =====================================================
    /**
     * @notice Receive ERC1155 tokens (NFTs)
     */
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    /**
     * @notice Receive ERC1155 tokens (NFTs) in batch
     */
    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    /**
     * @notice Allow contract to receive ETH
     */
    receive() external payable {}
    
    /**
     * @notice Custom error to handle fractional state errors
     */
    error FractionalizationStillActive();
}
