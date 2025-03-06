// SPDX-License-Identifier: GPL 3-0
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

    /**
     * @notice Initializes the FractionToken contract
     * @param name The name of the token
     * @param symbol The symbol of the token
     * @param initialSupply The initial token supply
     * @param _nftId The ID of the fractionalized NFT
     * @param _fractionManager The address of the fraction manager contract
     * @param _impactValue The environmental impact value
     * @param _projectCategory The project category
     * @param _projectDataHash The project data hash
     */
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
 * @title TerraStakeFractions
 * @dev Contract that allows fractionalization of TerraStake NFTs into tradable ERC20 tokens
 * representing verified environmental impact projects
 */
contract TerraStakeFractions is 
    ERC1155Holder, 
    AccessControl, 
    ReentrancyGuard, 
    Pausable 
{
    using ECDSA for bytes32;

    // =====================================================
    // Roles - Synchronized with TerraStakeNFT contract
    // =====================================================
    // These role definitions match exactly with TerraStakeNFT for unified permissions
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant FRACTIONALIZER_ROLE = keccak256("FRACTIONALIZER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant URI_SETTER_ROLE = keccak256("URI_SETTER_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

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

    // =====================================================
    // Structs
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

    // =====================================================
    // Mutable state variables
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
    // Events
    // =====================================================
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

    // =====================================================
    // Constructor
    // =====================================================
    /**
     * @notice Initializes the TerraStakeFractions contract
     * @param _terraStakeNFT Address of the TerraStakeNFT contract
     * @param _tStakeToken Address of the TStake token contract
     * @param _treasury Address of the treasury wallet
     * @param _impactFund Address of the impact fund wallet
     * @param _fee Initial fractionalization fee
     * @param _tradingFee Initial trading fee percentage (in basis points)
     */
    constructor(
        address _terraStakeNFT,
        address _tStakeToken,
        address _treasury,
        address _impactFund,
        uint256 _fee,
        uint256 _tradingFee
    ) {
        if (_terraStakeNFT == address(0) || 
            _tStakeToken == address(0) || 
            _treasury == address(0) || 
            _impactFund == address(0)) revert InvalidAddress();
            
        if (_tradingFee > 1000) revert FeeTooHigh(); // Max 10%
        
        terraStakeNFT = ITerraStakeNFT(_terraStakeNFT);
        tStakeToken = ITerraStakeToken(_tStakeToken);
        treasuryWallet = _treasury;
        impactFundWallet = _impactFund;
        fractionalizationFee = _fee;
        tradingFeePercentage = _tradingFee;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(FRACTIONALIZER_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(FEE_MANAGER_ROLE, msg.sender);
    }

    // Function implementations remain the same as before, with the addition of analytics functions
    
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
                
                // Calculate market cap for this token
                uint256 tokenMarketCap = market.lastTradePrice * data.totalSupply;
                metrics.totalMarketCap += tokenMarketCap;
                
                // Add environmental impact
                metrics.totalEnvironmentalImpact += data.impactValue;
                
                // Add to price sum for average calculation
                totalPriceSum += market.lastTradePrice;
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
     * @notice Get environmental impact breakdown by category
     * @return categories Array of project categories
     * @return impacts Corresponding impact values for each category
     */
    function getImpactByCategory()
        external
        view
        returns (ITerraStakeNFT.ProjectCategory[] memory categories, uint256[] memory impacts)
    {
        // Create arrays for each project category
        categories = new ITerraStakeNFT.ProjectCategory[](8); // Assuming 8 categories in the enum
        impacts = new uint256[](8);
        
        // Initialize the categories array
        for (uint256 i = 0; i < 8; i++) {
            categories[i] = ITerraStakeNFT.ProjectCategory(i);
        }
        
        // Accumulate impact values by category
        for (uint256 i = 0; i < allFractionTokens.length; i++) {
            address tokenAddress = allFractionTokens[i];
            FractionData memory data = fractionData[tokenAddress];
            
            if (data.isActive) {
                // Add impact to the appropriate category
                uint8 categoryIndex = uint8(data.category);
                if (categoryIndex < impacts.length) {
                    impacts[categoryIndex] += data.impactValue;
                }
            }
        }
        
        return (categories, impacts);
    }

    /**
     * @notice Fractionalize an NFT by depositing it and minting ERC20 tokens
     * @param params The fractionalization parameters
     * @return fractionTokenAddress The address of the created ERC20 token
     */
    function fractionalize(FractionParams calldata params) 
        external 
        nonReentrant 
        whenNotPaused
        onlyRole(FRACTIONALIZER_ROLE) // Unified with TerraStakeNFT permissions
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
        
        // Create verification hash
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
        
        // Calculate the price
        uint256 unitPrice = marketData[fractionToken].lastTradePrice;
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
     * @notice Update global metrics used for analytics
     */
    function updateGlobalMetrics() internal {
        uint256 totalMarketCap = 0;
        uint256 totalImpact = 0;
        
        for (uint256 i = 0; i < allFractionTokens.length; i++) {
            address tokenAddress = allFractionTokens[i];
            FractionData memory data = fractionData[tokenAddress];
            
            if (data.isActive) {
                FractionMarketData memory market = marketData[tokenAddress];
                
                // Calculate market cap
                uint256 marketCap = market.lastTradePrice * data.totalSupply;
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

    /**
     * @notice Set fractionalization fee (with unified role management)
     * @param newFee The new fee amount
     */
    function setFractionalizationFee(uint256 newFee) 
        external 
        onlyRole(FEE_MANAGER_ROLE) // Unified with TerraStakeNFT
    {
        fractionalizationFee = newFee;
    }

    /**
     * @notice Set the trading fee percentage (with unified role management)
     * @param newFeePercentage The new fee percentage in basis points
     */
    function setTradingFeePercentage(uint256 newFeePercentage) 
        external 
        onlyRole(FEE_MANAGER_ROLE) // Unified with TerraStakeNFT
    {
        if (newFeePercentage > 1000) revert FeeTooHigh(); // Max 10%
        tradingFeePercentage = newFeePercentage;
    }

    /**
     * @notice Get paginated list of all fractionalized tokens with their metrics
     * @param offset Starting index
     * @param limit Maximum number of items to return
     * @return tokens Array of fraction token addresses
     * @return prices Array of current prices
     * @return volumes Array of trading volumes
     * @return impacts Array of environmental impact values
     */
    function getFractionTokensWithMetrics(uint256 offset, uint256 limit)
        external
        view
        returns (
            address[] memory tokens,
            uint256[] memory prices,
            uint256[] memory volumes,
            uint256[] memory impacts
        )
    {
        // Determine actual count based on offset and limit
        uint256 actualCount = 0;
        uint256 endIndex = offset + limit;
        
        if (offset < allFractionTokens.length) {
            actualCount = endIndex > allFractionTokens.length ? 
                allFractionTokens.length - offset : limit;
        }
        
        // Initialize return arrays
        tokens = new address[](actualCount);
        prices = new uint256[](actualCount);
        volumes = new uint256[](actualCount);
        impacts = new uint256[](actualCount);
        
        // Populate arrays with data
        for (uint256 i = 0; i < actualCount; i++) {
            uint256 tokenIndex = offset + i;
            address tokenAddress = allFractionTokens[tokenIndex];
            
            tokens[i] = tokenAddress;
            prices[i] = marketData[tokenAddress].lastTradePrice;
            volumes[i] = marketData[tokenAddress].volumeTraded;
            impacts[i] = fractionData[tokenAddress].impactValue;
        }
        
        return (tokens, prices, volumes, impacts);
    }
}
