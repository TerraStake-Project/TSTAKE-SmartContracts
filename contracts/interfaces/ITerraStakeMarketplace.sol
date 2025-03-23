// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ITerraStakeMarketPlace
 * @notice Interface for the TerraStake NFT marketplace with fractionalization, bidding and analytics
 */
interface ITerraStakeMarketPlace {
    // Custom errors
    error NotAuthorized();
    error NotOwner();
    error InvalidPrice();
    error ListingNotActive();
    error AuctionEnded();
    error InsufficientFunds();
    error NotBidder();
    error RoyaltyTooHigh();
    error AlreadyHighestBidder();
    error OfferExpired();
    error CannotBidOwnItem();
    error SignatureExpired();
    error TokenNotApproved();
    error InvalidExpiration();
    error InvalidOffer();
    error InvalidCollection();
    error UnsupportedPaymentToken();
    error FeesTooHigh();
    error InvalidSignature();
    error InvalidRoyaltyReceiver();
    error PriceFeedNotConfigured();
    error InvalidPriceFeed();
    error InvalidNFTToken();
    error NotImpactNFT();

    // Structs
    struct Collection {
        bool verified;
        uint256 floorPrice;
        uint256 totalVolume;
        uint256 totalSales;
        uint256 royaltyPercentage;
        address royaltyReceiver;
        bool customRoyalty;
    }

    struct Listing {
        address seller;
        uint256 tokenId;
        uint256 price;
        bool isAuction;
        bool isFractional;
        uint256 fractions;
        uint256 expiry;
        bool active;
        address paymentToken;
    }

    struct Bid {
        address highestBidder;
        uint256 highestBid;
        uint256 bidEndTime;
        address paymentToken;
    }

    struct Offer {
        address offerer;
        uint256 offerAmount;
        uint256 expiry;
        bool active;
        address paymentToken;
    }

    struct TokenHistory {
        uint256 lastSoldPrice;
        address lastSoldTo;
        uint256 lastSoldTime;
        uint256 highestEverPrice;
        uint256[] priceHistory;
        uint256[] timestampHistory;
    }

    struct MarketMetrics {
        uint256 totalVolume;
        uint256 activeListings;
        uint256 fractionalizedAssets;
        uint256 totalOffers;
        uint256 totalCollections;
        uint256 lastUpdateBlock;
    }

    // New struct for Chainlink price feed configuration
    struct PriceFeedConfig {
        address priceFeed;
        uint8 decimals;
        bool isActive;
        uint256 lastUpdatedAt;
    }

    // New struct for NFT impact verification data
    struct ImpactNFTData {
        uint256 projectId;
        uint256 reportId;
        uint256 impactValue;
        bool isVerified;
        bool hasMetaData;
    }

    // Constants
    function BASIS_POINTS() external pure returns (uint256);
    function MIN_BID_INCREMENT_PERCENT() external pure returns (uint256);
    function MAX_ROYALTY_PERCENTAGE() external pure returns (uint256);
    function CANCELLATION_FEE() external pure returns (uint256);
    function GOVERNANCE_ROLE() external pure returns (bytes32);
    function OPERATOR_ROLE() external pure returns (bytes32);
    function RELAYER_ROLE() external pure returns (bytes32);

    // State variables
    function tStakeToken() external view returns (address);
    function nftContract() external view returns (address);
    function fractionContract() external view returns (address);
    function metadataContract() external view returns (address);
    function treasury() external view returns (address);
    function stakingPool() external view returns (address);
    function liquidityPool() external view returns (address);
    function stakingFeePercent() external view returns (uint256);
    function liquidityFeePercent() external view returns (uint256);
    function treasuryFeePercent() external view returns (uint256);
    function burnFeePercent() external view returns (uint256);
    function totalFeePercent() external view returns (uint256);
    function auctionExtensionTime() external view returns (uint256);
    function auctionExtensionThreshold() external view returns (uint256);
    function nonces(address user) external view returns (uint256);
    function collections(address collection) external view returns (Collection memory);
    function listings(uint256 tokenId) external view returns (Listing memory);
    function bids(uint256 tokenId) external view returns (Bid memory);
    function pendingReturns(address user) external view returns (uint256);
    function offers(uint256 tokenId, address offerer) external view returns (Offer memory);
    function tokenHistory(uint256 tokenId) external view returns (TokenHistory memory);
    function fractionalTokens(uint256 tokenId) external view returns (address);
    function metrics() external view returns (MarketMetrics memory);
    function projectsContract() external view returns (address);
    function tokenPriceFeeds(address token) external view returns (PriceFeedConfig memory);

    // Core functions
    function initialize(
        address _nftContract,
        address _tStakeToken,
        address _fractionContract,
        address _treasury,
        address _stakingPool,
        address _liquidityPool
    ) external;

    function setPaymentTokenSupport(address token, bool isSupported) external;

    function updateFeeStructure(
        uint256 _stakingFeePercent,
        uint256 _liquidityFeePercent,
        uint256 _treasuryFeePercent,
        uint256 _burnFeePercent
    ) external;

    function updateAuctionParameters(
        uint256 _extensionTime,
        uint256 _extensionThreshold
    ) external;

    function addCollection(
        address collection,
        bool verified,
        uint256 royaltyPercentage,
        address royaltyReceiver
    ) external;

    function setCollectionVerification(address collection, bool isVerified) external;

    function updateCollectionRoyalty(
        address collection,
        uint256 royaltyPercentage,
        address royaltyReceiver
    ) external;

    function updateCoreAddresses(
        address _treasury,
        address _stakingPool,
        address _liquidityPool,
        address _metadataContract
    ) external;

    // Listing and sales functions
    function listNFT(
        uint256 tokenId,
        uint256 price,
        bool isAuction,
        uint256 expiry,
        address paymentToken
    ) external;

    function listNFTWithSignature(
        uint256 tokenId,
        uint256 price,
        bool isAuction,
        uint256 expiry,
        address paymentToken,
        bytes calldata signature
    ) external;

    function buyNFT(uint256 tokenId) external;

    function placeBid(uint256 tokenId, uint256 bidAmount) external;

    function finalizeAuction(uint256 tokenId) external;

    function updateListing(
        uint256 tokenId,
        uint256 newPrice,
        uint256 newExpiry
    ) external;

    function cancelListing(uint256 tokenId) external;

    // Fractionalization function
    function fractionalizeNFT(
        uint256 tokenId,
        uint256 fractionSupply,
        uint256 lockTime
    ) external;

    // Offer functions
    function createOffer(
        uint256 tokenId,
        uint256 offerAmount,
        uint256 expiry,
        address paymentToken
    ) external;

    function cancelOffer(uint256 tokenId) external;

    function acceptOffer(uint256 tokenId, address offerer) external;

    // Financial functions
    function withdrawFunds() external;

    // Admin functions
    function processBatchOperation(
        uint256[] calldata tokenIds,
        string calldata operationType
    ) external;

    function updateContracts(
        address _nftContract,
        address _fractionContract
    ) external;

    function pause() external;

    function unpause() external;

    // View functions
    function isPaymentTokenSupported(address token) external view returns (bool);

    function getSupportedPaymentTokens() external view returns (address[] memory);

    function getActiveCollections() external view returns (address[] memory);

    function getCollectionTokenIds(address collection) external view returns (uint256[] memory);

    function getTokenPriceHistory(uint256 tokenId) external view returns (
        uint256[] memory prices,
        uint256[] memory timestamps
    );

    // New functions for NFT-Project verification
    /**
     * @notice Sets the projects contract address
     * @param _projectsContract The TerraStakeProjects contract address
     */
    function setProjectsContract(address _projectsContract) external;

    /**
     * @notice Verifies if an NFT is associated with a valid impact report before purchase
     * @param tokenId The NFT token ID
     * @return isValid Whether the NFT represents a valid impact report
     */
    function verifyImpactNFT(uint256 tokenId) external view returns (bool isValid);

    /**
     * @notice Gets project details associated with an NFT
     * @param tokenId The NFT token ID
     * @return projectId The project ID
     * @return reportId The impact report ID
     * @return impactValue The impact metric value
     */
    function getNFTProjectDetails(uint256 tokenId) external view returns (
        uint256 projectId,
        uint256 reportId,
        uint256 impactValue
    );

    /**
     * @notice Adds or updates impact data for an NFT
     * @param tokenId The NFT token ID
     * @param projectId The project ID
     * @param reportId The impact report ID
     * @param impactValue The impact metric value
     */
    function updateNFTImpactData(
        uint256 tokenId,
        uint256 projectId,
        uint256 reportId,
        uint256 impactValue
    ) external;

    /**
     * @notice Gets all impact NFTs from a specific project
     * @param projectId The project ID
     * @return tokenIds Array of NFT token IDs
     */
    function getProjectNFTs(uint256 projectId) external view returns (uint256[] memory tokenIds);

    // New functions for Chainlink price feed integration
    /**
     * @notice Sets a Chainlink price feed for a payment token
     * @param token The payment token address
     * @param priceFeed The Chainlink price feed address
     * @param decimals The number of decimals in the price feed
     */
    function setTokenPriceFeed(address token, address priceFeed, uint8 decimals) external;

    /**
     * @notice Gets the USD value of a token amount using Chainlink
     * @param token The payment token
     * @param amount The token amount
     * @return usdValue The equivalent USD value
     */
    function getTokenUSDValue(address token, uint256 amount) external view returns (uint256 usdValue);

    /**
     * @notice Gets the latest price from a token's Chainlink feed
     * @param token The token address
     * @return price The latest price
     * @return updatedAt The timestamp of the latest update
     */
    function getLatestTokenPrice(address token) external view returns (int256 price, uint256 updatedAt);

    /**
     * @notice Converts a price from one token to another using Chainlink
     * @param fromToken The source token
     * @param toToken The target token
     * @param amount The amount to convert
     * @return convertedAmount The converted amount
     */
    function convertPrice(address fromToken, address toToken, uint256 amount) external view returns (uint256 convertedAmount);

    // Events
    event NFTListed(uint256 indexed tokenId, address indexed seller, uint256 price, bool isAuction, uint256 expiry, address paymentToken);
    event NFTPurchased(uint256 indexed tokenId, address indexed buyer, uint256 price, address paymentToken);
    event NFTBidPlaced(uint256 indexed tokenId, address indexed bidder, uint256 bidAmount, address paymentToken);
    event NFTAuctionFinalized(uint256 indexed tokenId, address indexed winner, uint256 finalPrice, address paymentToken);
    event NFTFractionalized(uint256 indexed tokenId, address fractionToken);
    event ListingCancelled(uint256 indexed tokenId, address indexed seller);
    event ListingUpdated(uint256 indexed tokenId, uint256 newPrice, uint256 newExpiry);
    event FeesDistributed(uint256 stakingAmount, uint256 liquidityAmount, uint256 treasuryAmount, uint256 burnAmount);
    event RoyaltyPaid(uint256 indexed tokenId, address indexed receiver, uint256 amount);
    event OfferCreated(uint256 indexed tokenId, address indexed offerer, uint256 amount, uint256 expiry, address paymentToken);
    event OfferCancelled(uint256 indexed tokenId, address indexed offerer);
    event OfferAccepted(uint256 indexed tokenId, address indexed offerer, address indexed seller, uint256 amount);
    event AuctionExtended(uint256 indexed tokenId, uint256 newEndTime);
    event FundsWithdrawn(address indexed user, uint256 amount);
    event FeeStructureUpdated(uint256 stakingFee, uint256 liquidityFee, uint256 treasuryFee, uint256 burnFee);
    event CollectionAdded(address indexed collection, bool verified);
    event CollectionVerified(address indexed collection);
    event CollectionRoyaltyUpdated(address indexed collection, uint256 royaltyPercentage, address royaltyReceiver);
    event FloorPriceUpdated(address indexed collection, uint256 newFloorPrice);
    event BatchOperationProcessed(address indexed operator, uint256 count, string operationType);
    event CoreAddressesUpdated(address treasury, address stakingPool, address liquidityPool, address metadataContract);
    event ContractsUpdated(address nftContract, address fractionContract);
    event PaymentTokenAdded(address indexed token);
    event PaymentTokenRemoved(address indexed token);
    event AuctionParametersUpdated(uint256 extensionTime, uint256 extensionThreshold);

    // New events for NFT and Chainlink integrations
    event ImpactNFTTraded(uint256 indexed tokenId, uint256 indexed projectId, uint256 indexed reportId, uint256 price);
    event NFTImpactDataUpdated(uint256 indexed tokenId, uint256 projectId, uint256 reportId, uint256 impactValue);
    event ProjectsContractSet(address projectsContract);
    event TokenPriceFeedSet(address indexed token, address indexed priceFeed, uint8 decimals);
    event PriceFeedUpdated(address indexed token, int256 price, uint256 timestamp);
}
