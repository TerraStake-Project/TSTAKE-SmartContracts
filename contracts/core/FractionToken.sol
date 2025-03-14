// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

import "@openzeppelin/contracts-upgradeable/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@chainlink/contracts/src/v0.8/automation/interfaces/KeeperCompatibleInterface.sol";
import "../interfaces/ITerraStakeNFT.sol";
import "../interfaces/ITerraStakeToken.sol";

/**
 * @title FractionToken
 * @dev ERC20 token representing fractions of a TerraStake NFT
 */
contract FractionToken is ERC20Upgradeable, ERC20BurnableUpgradeable, ERC20PermitUpgradeable {
    uint256 public immutable nftId;
    address public immutable fractionManager;
    
    // Storing impact data directly in the token for transparency
    uint256 public immutable impactValue;
    ITerraStakeNFT.ProjectCategory public immutable projectCategory;
    bytes32 public immutable projectDataHash;

    function initialize(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        uint256 _nftId,
        address _fractionManager,
        uint256 _impactValue,
        ITerraStakeNFT.ProjectCategory _projectCategory,
        bytes32 _projectDataHash
    ) public initializer {
        __ERC20_init(name, symbol);
        __ERC20Burnable_init();
        __ERC20Permit_init(name);
        
        nftId = _nftId;
        fractionManager = _fractionManager;
        impactValue = _impactValue;
        projectCategory = _projectCategory;
        projectDataHash = _projectDataHash;
        _mint(_fractionManager, initialSupply);
    }

    /**
     * @dev Destroys all amount of tokens from `account`
     * @param account The address to burn tokens from
     */
    function burnAll(address account) public {
        uint256 balance = balanceOf(account); // Get the caller's balance
        require(balance > 0, "No tokens to burn"); // Ensure the caller has tokens

        _burn(account, balance); // Burn all tokens from the caller
    }
}

/**
 * @title TerraStakeFractionManager
 * @dev Combined contract for fractionalization of TerraStake NFTs and governance
 * with integrated multisig and oracle-based pricing
 */
contract TerraStakeFractionManager is 
    ERC1155HolderUpgradeable, 
    AccessControlEnumerableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    PausableUpgradeable,
    UUPSUpgradeable,
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
    error FractionalizationStillActive();

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
    mapping(bytes32 => Proposal) private proposals;
    
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
    
    event ProposalExpiredEvent(
        bytes32 indexed proposalId
    );
    
    event ProposalCanceledEvent(
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
        bytes32 indexed actionId,
        string description
    );
    
    event TimelockConfigUpdated(
        uint256 newDuration,
        bool enabled
    );
    
    event KeeperConfigUpdated(
        uint256 updateInterval,
        bool enabled
    );

    /**
     * @dev Initializer function (replaces constructor for upgradeable contracts)
     * @param _terraStakeNFT Address of the TerraStake NFT contract
     * @param _tStakeToken Address of the TStake token contract
     * @param _treasuryWallet Address of the treasury wallet
     * @param _impactFundWallet Address of the impact fund wallet
     */
    function initialize(
        address _terraStakeNFT,
        address _tStakeToken,
        address _treasuryWallet,
        address _impactFundWallet
    ) public initializer {
        __ERC1155Holder_init();
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        
        if (_terraStakeNFT == address(0) || 
            _tStakeToken == address(0) ||
            _treasuryWallet == address(0) ||
            _impactFundWallet == address(0)) {
            revert InvalidAddress();
        }
        
        terraStakeNFT = ITerraStakeNFT(_terraStakeNFT);
        tStakeToken = ITerraStakeToken(_tStakeToken);
        treasuryWallet = _treasuryWallet;
        impactFundWallet = _impactFundWallet;
        
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(VERIFIER_ROLE, msg.sender);
        _grantRole(FRACTIONALIZER_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(URI_SETTER_ROLE, msg.sender);
        _grantRole(FEE_MANAGER_ROLE, msg.sender);
        _grantRole(MULTISIG_MEMBER_ROLE, msg.sender);
        _grantRole(ORACLE_MANAGER_ROLE, msg.sender);
        
        // Initialize governance parameters
        governanceThreshold = 1;
        emergencyThreshold = 1;
        proposalExpiryTime = 7 days;
        
        // Initialize fee parameters
        fractionalizationFee = 100 ether; // 100 TStake tokens
        tradingFeePercentage = 200;       // 2% in basis points
        
        // Initialize timelock
        timelockConfig = TimelockConfig({
            duration: DEFAULT_TIMELOCK,
            enabled: true
        });
        
        // Initialize keeper settings
        keeperUpdateInterval = 1 days;
        keeperEnabled = false;
    }

    /**
     * @dev Required function for UUPS upgradeable contracts
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @dev Fractionalize a TerraStake NFT into ERC20 tokens
     * @param params The fractionalization parameters
     */
    function fractionalizeNFT(FractionParams calldata params) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        if (nftToFractionToken[params.tokenId] != address(0)) {
            revert NFTAlreadyFractionalized();
        }
        
        if (params.fractionSupply == 0 || params.fractionSupply > MAX_FRACTION_SUPPLY) {
            revert InvalidFractionSupply();
        }
        
        if (params.lockPeriod < MIN_LOCK_PERIOD || params.lockPeriod > MAX_LOCK_PERIOD) {
            revert InvalidLockPeriod();
        }
        
        // Transfer NFT to this contract
        terraStakeNFT.safeTransferFrom(msg.sender, address(this), params.tokenId, 1, "");
        
        // Collect fractionalization fee
        if (fractionalizationFee > 0) {
            if (!tStakeToken.transferFrom(msg.sender, treasuryWallet, fractionalizationFee)) {
                revert TransferFailed();
            }
            
            emit FeeDistributed(treasuryWallet, fractionalizationFee, "FRACTIONALIZATION_FEE");
        }
        
        // Get NFT data for enriching the fraction token
        (uint256 impactValue, ITerraStakeNFT.ProjectCategory category, bytes32 verificationHash) = 
            terraStakeNFT.getTokenData(params.tokenId);
            
        if (verificationHash == bytes32(0)) {
            revert NFTNotVerified();
        }
        
        // Create new fraction token
        FractionToken fractionToken = new FractionToken(
            params.name,
            params.symbol,
            params.fractionSupply,
            params.tokenId,
            address(this),
            impactValue,
            category,
            verificationHash
        );
        
        // Update fractionalization data
        address tokenAddress = address(fractionToken);
        fractionData[tokenAddress] = FractionData({
            tokenAddress: tokenAddress,
            nftId: params.tokenId,
            totalSupply: params.fractionSupply,
            redemptionPrice: params.initialPrice * params.fractionSupply,
            isActive: true,
            lockEndTime: block.timestamp + params.lockPeriod,
            creator: msg.sender,
            creationTime: block.timestamp,
            impactValue: impactValue,
            category: category,
            verificationHash: verificationHash
        });
        
        // Initialize market data
        marketData[tokenAddress] = FractionMarketData({
            totalValueLocked: params.initialPrice * params.fractionSupply,
            totalActiveUsers: 1, // Creator is first holder
            volumeTraded: 0,
            lastTradePrice: params.initialPrice,
            lastTradeTime: block.timestamp
        });
        
        // Map the NFT ID to the fraction token
        nftToFractionToken[params.tokenId] = tokenAddress;
        allFractionTokens.push(tokenAddress);
        
        // Transfer all tokens to the creator
        fractionToken.transfer(msg.sender, params.fractionSupply);
        
        emit NFTFractionalized(
            params.tokenId,
            tokenAddress,
            params.fractionSupply,
            msg.sender,
            category,
            impactValue
        );
        
        // Update global metrics
        _updateGlobalMetrics();
    }

    /**
     * @dev Make an offer to redeem the NFT
     * @param fractionToken The fraction token address
     * @param price The price offered for redeeming the NFT
     */
    function offerRedemption(address fractionToken, uint256 price) 
        external 
        nonReentrant 
        whenNotPaused
    {
        FractionData storage data = fractionData[fractionToken];
        
        if (!data.isActive) {
            revert FractionalizationNotActive();
        }
        
        if (block.timestamp < data.lockEndTime) {
            revert NFTStillLocked();
        }
        
        // Make sure price is reasonable
        if (price < data.redemptionPrice / 2) {
            revert PriceTooLow();
        }
        
        // Transfer the offered TStake tokens to this contract
        if (!tStakeToken.transferFrom(msg.sender, address(this), price)) {
            revert TransferFailed();
        }
        
        // Store the redemption offer
        redemptionOffers[fractionToken] = price;
        redemptionOfferors[fractionToken] = msg.sender;
        
        emit RedemptionOffered(data.nftId, fractionToken, price, msg.sender);
    }

    /**
     * @dev Redeem an NFT by burning all fractions
     * @param fractionToken The fraction token address
     */
    function redeemNFT(address fractionToken) external nonReentrant whenNotPaused {
        FractionData storage data = fractionData[fractionToken];
        
        if (!data.isActive) {
            revert FractionalizationNotActive();
        }
        
        if (block.timestamp < data.lockEndTime) {
            revert NFTStillLocked();
        }
        
        // Check if the caller holds all tokens
        uint256 supply = data.totalSupply;
        uint256 balance = IERC20(fractionToken).balanceOf(msg.sender);
        
        if (balance != supply) {
            revert InsufficientBalance();
        }
        
        // Burn all fraction tokens
        FractionToken(fractionToken).burnFrom(msg.sender, supply);
        
        // Transfer NFT to redeemer
        terraStakeNFT.safeTransferFrom(address(this), msg.sender, data.nftId, 1, "");
        
        // Mark fractionalization as inactive
        data.isActive = false;
        
        emit NFTRedeemed(data.nftId, msg.sender, data.redemptionPrice);
        
        // Update global metrics
        _updateGlobalMetrics();
    }

    /**
     * @dev Accept a redemption offer by holding all fractions
     * @param fractionToken The fraction token address
     */
    function acceptRedemptionOffer(address fractionToken) external nonReentrant whenNotPaused {
        FractionData storage data = fractionData[fractionToken];
        
        uint256 offeredPrice = redemptionOffers[fractionToken];
        address offeror = redemptionOfferors[fractionToken];
        
        if (offeredPrice == 0 || offeror == address(0)) {
            revert NoRedemptionOffer();
        }
        
        if (!data.isActive) {
            revert FractionalizationNotActive();
        }
        
        // Check if the caller holds all tokens
        uint256 supply = data.totalSupply;
        uint256 balance = IERC20(fractionToken).balanceOf(msg.sender);
        
        if (balance != supply) {
            revert InsufficientBalance();
        }
        
        // Burn all fraction tokens
        FractionToken(fractionToken).burnFrom(msg.sender, supply);
        
        // Transfer NFT to the offeror
        terraStakeNFT.safeTransferFrom(address(this), offeror, data.nftId, 1, "");
        
        // Transfer payment to the fraction holder
        if (!tStakeToken.transfer(msg.sender, offeredPrice)) {
            revert TransferFailed();
        }
        
        // Mark fractionalization as inactive
        data.isActive = false;
        
        // Clear offer
        delete redemptionOffers[fractionToken];
        delete redemptionOfferors[fractionToken];
        
        emit NFTRedeemed(data.nftId, offeror, offeredPrice);
        
        // Update global metrics
        _updateGlobalMetrics();
    }

    /**
     * @dev Buy fractions at the current oracle price
     * @param fractionToken The fraction token address
     * @param amount The amount of fractions to buy
     */
    function buyFractions(address fractionToken, uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        FractionData storage data = fractionData[fractionToken];
        
        if (!data.isActive) {
            revert FractionalizationNotActive();
        }
        
        if (amount == 0) {
            revert InvalidAmount();
        }
        
        // Get current price from oracle or use market price
        uint256 currentPrice = getTokenPrice(fractionToken);
        uint256 totalCost = amount * currentPrice;
        
        // Calculate fee
        uint256 fee = (totalCost * tradingFeePercentage) / BASIS_POINTS;
        uint256 totalPayment = totalCost + fee;
        
        // Transfer payment
        if (!tStakeToken.transferFrom(msg.sender, address(this), totalPayment)) {
            revert TransferFailed();
        }
        
        // Distribute fees
        _distributeFees(fee);
        
        // Transfer tokens to buyer
        if (!IERC20(fractionToken).transferFrom(data.creator, msg.sender, amount)) {
            revert TransferFailed();
        }
        
        // Transfer payment to seller
        if (!tStakeToken.transfer(data.creator, totalCost)) {
            revert TransferFailed();
        }
        
        // Update market data
        FractionMarketData storage market = marketData[fractionToken];
        market.volumeTraded += amount;
        market.lastTradePrice = currentPrice;
        market.lastTradeTime = block.timestamp;
        
        // Update global volume
        totalVolumeTraded += amount;
        
        emit FractionsBought(msg.sender, fractionToken, amount, currentPrice);
        
        // Update global metrics
        _updateGlobalMetrics();
    }

    /**
     * @dev Sell fractions at the current oracle price
     * @param fractionToken The fraction token address
     * @param amount The amount of fractions to sell
     */
    function sellFractions(address fractionToken, uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        FractionData storage data = fractionData[fractionToken];
        
        if (!data.isActive) {
            revert FractionalizationNotActive();
        }
        
        if (amount == 0) {
            revert InvalidAmount();
        }
        
        // Get current price from oracle or use market price
        uint256 currentPrice = getTokenPrice(fractionToken);
        uint256 totalValue = amount * currentPrice;
        
        // Calculate fee
        uint256 fee = (totalValue * tradingFeePercentage) / BASIS_POINTS;
        uint256 sellerPayment = totalValue - fee;
        
        // Transfer fractions to contract
        if (!IERC20(fractionToken).transferFrom(msg.sender, data.creator, amount)) {
            revert TransferFailed();
        }
        
        // Transfer payment to seller
        if (!tStakeToken.transferFrom(data.creator, msg.sender, sellerPayment)) {
            revert TransferFailed();
        }
        
        // Transfer fee from creator to contract then distribute
        if (!tStakeToken.transferFrom(data.creator, address(this), fee)) {
            revert TransferFailed();
        }
        _distributeFees(fee);
        
        // Update market data
        FractionMarketData storage market = marketData[fractionToken];
        market.volumeTraded += amount;
        market.lastTradePrice = currentPrice;
        market.lastTradeTime = block.timestamp;
        
        // Update global volume
        totalVolumeTraded += amount;
        
        emit FractionsSold(msg.sender, fractionToken, amount, currentPrice);
        
        // Update global metrics
        _updateGlobalMetrics();
    }

    /**
     * @dev Get the current price of a fraction token
     * @param fractionToken The fraction token address
     * @return The current price
     */
    function getTokenPrice(address fractionToken) public view returns (uint256) {
        // First check if we have an oracle for this token
        if (tokenWithOracles.contains(fractionToken)) {
            OracleConfig storage config = tokenOracles[fractionToken];
            if (config.active) {
                // Get price from Chainlink oracle
                AggregatorV3Interface oracle = AggregatorV3Interface(config.oracle);
                (
                    /* uint80 roundID */,
                    int256 price,
                    /* uint256 startedAt */,
                    uint256 timeStamp,
                    /* uint80 answeredInRound */
                ) = oracle.latestRoundData();
                
                // Ensure price is within valid range
                if (price < config.minPrice || price > config.maxPrice) {
                    revert InvalidPrice();
                }
                
                // Check for stale price data
                if (block.timestamp - timeStamp > config.heartbeatPeriod) {
                    revert StalePrice();
                }
                
                return uint256(price);
            }
        }
        
        // Fallback to last trade price
        FractionMarketData storage market = marketData[fractionToken];
        if (market.lastTradePrice > 0) {
            return market.lastTradePrice;
        }
        
        // If no trade has happened, use initial redemption price
        FractionData storage data = fractionData[fractionToken];
        return data.redemptionPrice / data.totalSupply;
    }

    /**
     * @dev Configure an oracle for a token
     * @param token The fraction token address
     * @param oracle The Chainlink oracle address
     * @param heartbeatPeriod Maximum time between oracle updates
     * @param minPrice Minimum valid price
     * @param maxPrice Maximum valid price
     * @param updateInterval How often to update price (for keepers)
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
        if (token == address(0) || oracle == address(0)) {
            revert InvalidAddress();
        }
        
        if (heartbeatPeriod == 0 || updateInterval == 0 || minPrice >= maxPrice) {
            revert InvalidOracleConfig();
        }
        
        tokenOracles[token] = OracleConfig({
            oracle: oracle,
            heartbeatPeriod: heartbeatPeriod,
            minPrice: minPrice,
            maxPrice: maxPrice,
            active: true,
            lastUpdateTime: block.timestamp,
            updateInterval: updateInterval
        });
        
        tokenWithOracles.add(token);
        
        emit OracleConfigured(
            token,
            oracle,
            heartbeatPeriod,
            minPrice,
            maxPrice,
            updateInterval
        );
    }

    /**
     * @dev Update price data for a token
     * @param token The fraction token address
     */
    function updateTokenPrice(address token) 
        external
        whenNotPaused
    {
        OracleConfig storage config = tokenOracles[token];
        
        if (!config.active) {
            revert InvalidOracleConfig();
        }
        
        // Get current market data
        FractionMarketData storage market = marketData[token];
        uint256 oldPrice = market.lastTradePrice;
        
        // Get new price from oracle
        AggregatorV3Interface oracle = AggregatorV3Interface(config.oracle);
        (
            /* uint80 roundID */,
            int256 rawPrice,
            /* uint256 startedAt */,
            /* uint256 timeStamp */,
            /* uint80 answeredInRound */
        ) = oracle.latestRoundData();
        
        uint256 newPrice = uint256(rawPrice);
        
        // Verify price is within valid range
        if (rawPrice < config.minPrice || rawPrice > config.maxPrice) {
            revert InvalidPrice();
        }
        
        // Verify price change is not too extreme
        if (oldPrice > 0) {
            uint256 priceChange;
            uint256 changePercent;
            
            if (newPrice > oldPrice) {
                priceChange = newPrice - oldPrice;
                changePercent = (priceChange * BASIS_POINTS) / oldPrice;
            } else {
                priceChange = oldPrice - newPrice;
                changePercent = (priceChange * BASIS_POINTS) / oldPrice;
            }
            
            if (changePercent > MAX_PRICE_CHANGE_PERCENT) {
                revert PriceChangeExceedsLimit();
            }
        }
        
        // Update market data
        market.lastTradePrice = newPrice;
        market.lastTradeTime = block.timestamp;
        
        // Update oracle config
        config.lastUpdateTime = block.timestamp;
        
        emit PriceUpdated(token, oldPrice, newPrice, config.oracle);
    }

    /**
     * @dev Set fees for fractionalization and trading
     * @param _fractionalizationFee Fee to fractionalize an NFT
     * @param _tradingFeePercentage Percentage fee on trading (basis points)
     */
    function setFees(uint256 _fractionalizationFee, uint256 _tradingFeePercentage) 
        external 
        onlyRole(FEE_MANAGER_ROLE) 
    {
        if (_tradingFeePercentage > 1000) { // Max 10%
            revert FeeTooHigh();
        }
        
        fractionalizationFee = _fractionalizationFee;
        tradingFeePercentage = _tradingFeePercentage;
    }

    /**
     * @dev Set wallets for fee distribution
     * @param _treasuryWallet Address for treasury fees
     * @param _impactFundWallet Address for impact fund fees
     */
    function setFeeWallets(address _treasuryWallet, address _impactFundWallet) 
        external 
        onlyRole(FEE_MANAGER_ROLE) 
    {
        if (_treasuryWallet == address(0) || _impactFundWallet == address(0)) {
            revert InvalidAddress();
        }
        
        treasuryWallet = _treasuryWallet;
        impactFundWallet = _impactFundWallet;
    }

    /**
     * @dev Internal function to distribute fees
     * @param amount Amount of fees to distribute
     */
    function _distributeFees(uint256 amount) internal {
        // Split fees: 70% to treasury, 30% to impact fund
        uint256 treasuryAmount = (amount * 7000) / BASIS_POINTS;
        uint256 impactAmount = amount - treasuryAmount;
        
        tStakeToken.transfer(treasuryWallet, treasuryAmount);
        tStakeToken.transfer(impactFundWallet, impactAmount);
        
        emit FeeDistributed(treasuryWallet, treasuryAmount, "TRADING_FEE_TREASURY");
        emit FeeDistributed(impactFundWallet, impactAmount, "TRADING_FEE_IMPACT");
    }

    /**
     * @dev Update global market metrics
     */
    function _updateGlobalMetrics() internal {
        uint256 totalMarketCap = 0;
        uint256 totalEnvironmentalImpact = 0;
        uint256 activeTokens = 0;
        
        for (uint256 i = 0; i < allFractionTokens.length; i++) {
            address tokenAddress = allFractionTokens[i];
            FractionData storage data = fractionData[tokenAddress];
            
            if (data.isActive) {
                FractionMarketData storage market = marketData[tokenAddress];
                uint256 currentPrice = market.lastTradePrice;
                if (currentPrice == 0) {
                    currentPrice = data.redemptionPrice / data.totalSupply;
                }
                
                uint256 marketCap = data.totalSupply * currentPrice;
                totalMarketCap += marketCap;
                totalEnvironmentalImpact += data.impactValue;
                activeTokens++;
            }
        }
        
        emit GlobalStatsUpdated(
            totalMarketCap,
            totalVolumeTraded,
            totalEnvironmentalImpact
        );
    }

    /**
     * @dev Pause all functions on the contract
     */
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause the contract
     */
    function unpause() external onlyRole(GOVERNANCE_ROLE) {
        _unpause();
    }

    /**
     * @dev Get total count of all fractionalized NFTs
     * @return The total count
     */
    function getTotalFractionTokens() external view returns (uint256) {
        return allFractionTokens.length;
    }

    /**
     * @dev Get aggregate market metrics
     * @return metrics The aggregate metrics
     */
    function getAggregateMetrics() external view returns (AggregateMetrics memory metrics) {
        metrics.totalTradingVolume = totalVolumeTraded;
        
        uint256 totalMarketCap = 0;
        uint256 totalEnvironmentalImpact = 0;
        uint256 activeTokens = 0;
        uint256 totalTokenPrice = 0;
        
        for (uint256 i = 0; i < allFractionTokens.length; i++) {
            address tokenAddress = allFractionTokens[i];
            FractionData storage data = fractionData[tokenAddress];
            
            if (data.isActive) {
                FractionMarketData storage market = marketData[tokenAddress];
                uint256 currentPrice = market.lastTradePrice;
                if (currentPrice == 0) {
                    currentPrice = data.redemptionPrice / data.totalSupply;
                }
                
                uint256 marketCap = data.totalSupply * currentPrice;
                totalMarketCap += marketCap;
                totalEnvironmentalImpact += data.impactValue;
                totalTokenPrice += currentPrice;
                activeTokens++;
            }
        }
        
        metrics.totalMarketCap = totalMarketCap;
        metrics.totalEnvironmentalImpact = totalEnvironmentalImpact;
        metrics.totalActiveTokens = activeTokens;
        
        if (activeTokens > 0) {
            metrics.averageTokenPrice = totalTokenPrice / activeTokens;
        }
        
        return metrics;
    }

    // =====================================================
    // Governance functions
    // =====================================================

    /**
     * @dev Create a governance proposal
     * @param data The calldata for the proposal
     * @param description A human-readable description of the proposal
     * @param isEmergency Whether this is an emergency proposal
     */
    function createProposal(
        bytes calldata data,
        string calldata description,
        bool isEmergency
    ) 
        external 
        onlyRole(GOVERNANCE_ROLE)
        whenNotPaused 
        returns (bytes32)
    {
        bytes32 proposalId = keccak256(abi.encodePacked(data, description, block.timestamp, msg.sender));
        
        if (proposals[proposalId].proposalHash != bytes32(0)) {
            revert ProposalAlreadyExists();
        }
        
        EnumerableSet.AddressSet storage approvers = proposals[proposalId].approvers;
        approvers.add(msg.sender); // Creator automatically approves
        
        uint256 requiredThreshold = isEmergency ? emergencyThreshold : governanceThreshold;
        uint256 executionTime = block.timestamp;
        
        // Apply timelock for non-emergency proposals
        if (!isEmergency && timelockConfig.enabled) {
            executionTime += timelockConfig.duration;
        }
        
        proposals[proposalId] = Proposal({
            proposalHash: proposalId,
            proposedTime: block.timestamp,
            requiredThreshold: requiredThreshold,
            executed: false,
            isEmergency: isEmergency,
            creator: msg.sender,
            canceled: false,
            executionTime: executionTime,
            approvers: approvers
        });
        
        allProposals.add(proposalId);
        
        emit ProposalCreated(proposalId, msg.sender, isEmergency, data, executionTime);
        
        return proposalId;
    }

    /**
     * @dev Approve a governance proposal
     * @param proposalId The ID of the proposal to approve
     */
    function approveProposal(bytes32 proposalId) 
        external 
        onlyRole(GOVERNANCE_ROLE)
        whenNotPaused 
    {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.proposalHash == bytes32(0)) {
            revert ProposalDoesNotExist();
        }
        
        if (proposal.executed) {
            revert ProposalAlreadyExecuted();
        }
        
        if (proposal.canceled) {
            revert ProposalCanceled();
        }
        
        if (block.timestamp > proposal.proposedTime + proposalExpiryTime) {
            revert ProposalExpired();
        }
        
        if (proposal.approvers.contains(msg.sender)) {
            revert ProposalAlreadyApproved();
        }
        
        proposal.approvers.add(msg.sender);
        
        emit ProposalApproved(
            proposalId, 
            msg.sender, 
            proposal.approvers.length(), 
            proposal.requiredThreshold
        );
    }

    /**
     * @dev Execute a governance proposal
     * @param proposalId The ID of the proposal to execute
     * @param target The target address to call
     * @param data The calldata to send
     */
    function executeProposal(
        bytes32 proposalId,
        address target,
        bytes calldata data
    ) 
        external 
        whenNotPaused 
        returns (bool)
    {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.proposalHash == bytes32(0)) {
            revert ProposalDoesNotExist();
        }
        
        if (proposal.executed) {
            revert ProposalAlreadyExecuted();
        }
        
        if (proposal.canceled) {
            revert ProposalCanceled();
        }
        
        if (block.timestamp > proposal.proposedTime + proposalExpiryTime) {
            revert ProposalExpired();
        }
        
        // Check timelock
        if (!proposal.isEmergency && block.timestamp < proposal.executionTime) {
            revert ProposalTimelocked();
        }
        
        // Check threshold
        if (proposal.approvers.length() < proposal.requiredThreshold) {
            revert InsufficientApprovals();
        }

        // Execute proposal
        (bool success, ) = target.call(data);
        if (!success) {
            revert ExecutionFailed();
        }
        
        // Mark as executed
        proposal.executed = true;
        
        emit ProposalExecuted(proposalId, msg.sender, true);
        
        return true;
    }

    /**
     * @dev Cancel a governance proposal
     * @param proposalId The ID of the proposal to cancel
     */
    function cancelProposal(bytes32 proposalId) external whenNotPaused {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.proposalHash == bytes32(0)) {
            revert ProposalDoesNotExist();
        }
        
        if (proposal.executed) {
            revert ProposalAlreadyExecuted();
        }
        
        if (proposal.canceled) {
            revert ProposalCanceled();
        }
        
        // Only the creator or admin can cancel
        if (msg.sender != proposal.creator && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert OnlyCreatorCanCancel();
        }
        
        proposal.canceled = true;
        
        emit ProposalCanceledEvent(proposalId, msg.sender);
    }

    /**
     * @dev Clean up expired proposals
     * @param proposalId The ID of the expired proposal
     */
    function cleanupExpiredProposal(bytes32 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.proposalHash == bytes32(0)) {
            revert ProposalDoesNotExist();
        }
        
        if (proposal.executed || proposal.canceled) {
            return;
        }
        
        if (block.timestamp <= proposal.proposedTime + proposalExpiryTime) {
            revert ProposalExpired();
        }
        
        // Mark as canceled
        proposal.canceled = true;
        
        emit ProposalExpiredEvent(proposalId);
    }

    /**
     * @dev Set governance parameters
     * @param _governanceThreshold New governance threshold
     * @param _emergencyThreshold New emergency threshold
     * @param _proposalExpiryTime New proposal expiry time
     */
    function setGovernanceParams(
        uint256 _governanceThreshold,
        uint256 _emergencyThreshold,
        uint256 _proposalExpiryTime
    ) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        if (_governanceThreshold == 0 || _emergencyThreshold == 0) {
            revert InvalidThreshold();
        }
        
        if (_proposalExpiryTime < 1 days || _proposalExpiryTime > 30 days) {
            revert InvalidExpiry();
        }
        
        governanceThreshold = _governanceThreshold;
        emergencyThreshold = _emergencyThreshold;
        proposalExpiryTime = _proposalExpiryTime;
    }

    /**
     * @dev Set timelock configuration
     * @param _duration New timelock duration
     * @param _enabled Whether timelock is enabled
     */
    function setTimelockConfig(uint256 _duration, bool _enabled) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        if (_duration < 1 hours || _duration > 7 days) {
            revert InvalidTimelock();
        }
        
        timelockConfig = TimelockConfig({
            duration: _duration,
            enabled: _enabled
        });
        
        emit TimelockConfigUpdated(_duration, _enabled);
    }

    /**
     * @dev Execute emergency action (bypass governance process)
     * @param target The target address
     * @param data The calldata to execute
     * @param description Description of the emergency action
     */
    function executeEmergencyAction(
        address target,
        bytes calldata data,
        string calldata description
    ) 
        external 
        onlyRole(EMERGENCY_ROLE) 
        returns (bool)
    {
        bytes32 actionId = keccak256(abi.encodePacked(target, data, description, block.timestamp));
        
        (bool success, ) = target.call(data);
        if (!success) {
            revert EmergencyActionFailed();
        }
        
        emit EmergencyActionExecuted(msg.sender, actionId, description);
        
        return true;
    }

    /**
     * @dev Set keeper configuration
     * @param _updateInterval New update interval
     * @param _enabled Whether keeper is enabled
     */
    function setKeeperConfig(uint256 _updateInterval, bool _enabled) 
        external 
        onlyRole(OPERATOR_ROLE) 
    {
        keeperUpdateInterval = _updateInterval;
        keeperEnabled = _enabled;
        
        emit KeeperConfigUpdated(_updateInterval, _enabled);
    }

    /**
     * @dev Check if upkeep is needed (Chainlink Keeper)
     */
    function checkUpkeep(bytes calldata /* checkData */) 
        external 
        view 
        override 
        returns (bool upkeepNeeded, bytes memory performData) 
    {
        if (!keeperEnabled) {
            return (false, "");
        }
        
        if (block.timestamp < lastKeeperUpdate + keeperUpdateInterval) {
            return (false, "");
        }
        
        address[] memory tokensNeedingUpdate = new address[](tokenWithOracles.length());
        uint256 count = 0;
        
        for (uint256 i = 0; i < tokenWithOracles.length(); i++) {
            address token = tokenWithOracles.at(i);
            OracleConfig storage config = tokenOracles[token];
            
            if (config.active && block.timestamp >= config.lastUpdateTime + config.updateInterval) {
                tokensNeedingUpdate[count] = token;
                count++;
            }
        }
        
        if (count > 0) {
            // Pack tokens into performData
            return (true, abi.encode(tokensNeedingUpdate, count));
        }
        
        return (false, "");
    }

    /**
     * @dev Perform upkeep (Chainlink Keeper)
     */
    function performUpkeep(bytes calldata performData) external override {
        if (!keeperEnabled) {
            return;
        }
        
        (address[] memory tokens, uint256 count) = abi.decode(performData, (address[], uint256));
        
        for (uint256 i = 0; i < count; i++) {
            address token = tokens[i];
            try this.updateTokenPrice(token) {
                // Successfully updated price
            } catch {
                // Failed to update this token's price, continue with others
            }
        }
        
        lastKeeperUpdate = block.timestamp;
    }

    /**
     * @dev Get active proposals
     * @return List of active proposal IDs
     */
    function getActiveProposals() external view returns (bytes32[] memory) {
        uint256 totalProposals = allProposals.length();
        bytes32[] memory activeProposalIds = new bytes32[](totalProposals);
        uint256 count = 0;
        
        for (uint256 i = 0; i < totalProposals; i++) {
            bytes32 proposalId = allProposals.at(i);
            Proposal storage proposal = proposals[proposalId];
            
            if (!proposal.executed && !proposal.canceled) {
                activeProposalIds[count] = proposalId;
                count++;
            }
        }
        
        // Resize array to actual count
        bytes32[] memory result = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = activeProposalIds[i];
        }
        
        return result;
    }

    /**
     * @dev Get proposal details
     * @param proposalId The proposal ID
     * @return proposal The proposal details
     * @return approvalCount Number of approvals
     */
    function getProposalDetails(bytes32 proposalId) 
        external 
        view 
        returns (Proposal memory, uint256) 
    {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.proposalHash == bytes32(0)) {
            revert ProposalDoesNotExist();
        }
        
        return (proposal, proposal.approvers.length());
    }

    /**
     * @dev Check if an account has approved a proposal
     * @param proposalId The proposal ID
     * @param account The account to check
     * @return Whether the account has approved
     */
    function hasApprovedProposal(bytes32 proposalId, address account) 
        external 
        view 
        returns (bool) 
    {
        return proposals[proposalId].approvers.contains(account);
    }

    // Required override for multiple inheritance
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlEnumerableUpgradeable, ERC1155HolderUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}