// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/interfaces/IERC20Upgradeable.sol";

/**
 * @title ITerraStakeMarketplace
 * @notice Interface for the TerraStake NFT Marketplace with advanced trading capabilities
 * @dev Defines all external functions, events, and data structures for marketplace interactions
 */
interface ITerraStakeMarketplace {
    // =====================================================
    // Structs
    // =====================================================
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

    // =====================================================
    // Events
    // =====================================================
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

    // =====================================================
    // Constants
    // =====================================================
    function BASIS_POINTS() external view returns (uint256);
    function MIN_BID_INCREMENT_PERCENT() external view returns (uint256);
    function MAX_ROYALTY_PERCENTAGE() external view returns (uint256);
    function CANCELLATION_FEE() external view returns (uint256);
    
    // Roles
    function GOVERNANCE_ROLE() external view returns (bytes32);
    function OPERATOR_ROLE() external view returns (bytes32);
    function RELAYER_ROLE() external view returns (bytes32);

    // =====================================================
    // Initialization & Core Configuration
    // =====================================================
    function initialize(
        address _nftContract,
        address _tStakeToken,
        address _fractionContract,
        address _treasury,
        address _stakingPool,
        address _liquidityPool
    ) external;
    
    function updateCoreAddresses(
        address _treasury,
        address _stakingPool,
        address _liquidityPool,
        address _metadataContract
    ) external;
    
    function updateContracts(
        address _nftContract,
        address _fractionContract
    ) external;
    
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
    
    function setPaymentTokenSupport(address token, bool isSupported) external;
    
    function pause() external;
    function unpause() external;

    // =====================================================
    // Collection Management
    // =====================================================
    function addCollection(
        address collection,
        bool verified,
        uint256 royaltyPercentage,
        address royaltyReceiver
    ) external;
    
    function calculateFloorPrice(address collection) external;
    
    function collections(address) external view returns (Collection memory);

    // =====================================================
    // Listing Management
    // =====================================================
    function listNFT(
        uint256 tokenId,
        uint256 price,
        bool isAuction,
        uint256 expiry,
        address paymentToken
    ) external;
    
    function batchListNFTs(
        uint256[] calldata tokenIds,
        uint256[] calldata prices,
        bool[] calldata isAuctions,
        uint256[] calldata expiries,
        address paymentToken
    ) external;
    
    function updateListing(
        uint256 tokenId,
        uint256 newPrice,
        uint256 newExpiry
    ) external;
    
    function cancelListing(uint256 tokenId) external;
    
    function buyNFT(uint256 tokenId) external;
    
    function listings(uint256) external view returns (Listing memory);

    // =====================================================
    // Auction Functions
    // =====================================================
    function placeBid(uint256 tokenId, uint256 bidAmount) external;
    function finalizeAuction(uint256 tokenId) external;
    function bids(uint256) external view returns (Bid memory);

    // =====================================================
    // Offer Management
    // =====================================================
    function createOffer(
        uint256 tokenId,
        uint256 offerAmount,
        uint256 expiry,
        address paymentToken
    ) external;
    
    function cancelOffer(uint256 tokenId) external;
    
    function acceptOffer(uint256 tokenId, address offerer) external;
    
    function offers(uint256, address) external view returns (Offer memory);

    // =====================================================
    // Fractionalization
    // =====================================================
    function fractionalizeNFT(
        uint256 tokenId,
        uint256 fractionSupply,
        uint256 lockTime
    ) external returns (address);
    
    function fractionalTokens(uint256) external view returns (address);

    // =====================================================
    // Signature-based Listing
    // =====================================================
    function listWithSignature(
        address seller,
        uint256 tokenId,
        uint256 price,
        bool isAuction,
        uint256 expiry,
        address paymentToken,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
    
    function verifyListingSignature(
        address seller,
        uint256 tokenId,
        uint256 price,
        bool isAuction,
        uint256 expiry,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external view returns (bool);
    
    function nonces(address) external view returns (uint256);

    // =====================================================
    // Token History & Recommendations
    // =====================================================
    function tokenHistory(uint256) external view returns (TokenHistory memory);
    
    function getRecommendedPrice(uint256 tokenId) external view returns (uint256);
    
    function getTokenMetadata(uint256 tokenId) external view returns (
        string memory name,
        string memory description,
        string memory image,
        bytes memory attributes
    );
    
    function getTokenRarity(uint256 tokenId) external view returns (
        uint256 rank,
        uint256 totalSupply
    );

    // =====================================================
    // Fee Management
    // =====================================================
    function stakingFeePercent() external view returns (uint256);
    function liquidityFeePercent() external view returns (uint256);
    function treasuryFeePercent() external view returns (uint256);
    function burnFeePercent() external view returns (uint256);
    function totalFeePercent() external view returns (uint256);
    function auctionExtensionTime() external view returns (uint256);
    function auctionExtensionThreshold() external view returns (uint256);

    // =====================================================
    // Fund Management
    // =====================================================
    function withdrawPendingReturns() external;
    
    function pendingReturns(address) external view returns (uint256);
    
    function rescueTokens(
        address token,
        uint256 amount,
        address destination
    ) external;

    // =====================================================
    // Contract References
    // =====================================================
    function tStakeToken() external view returns (address);
    function nftContract() external view returns (address);
    function fractionContract() external view returns (address);
    function metadataContract() external view returns (address);
    function treasury() external view returns (address);
    function stakingPool() external view returns (address);
    function liquidityPool() external view returns (address);

    // =====================================================
    // Market Metrics
    // =====================================================
    function metrics() external view returns (MarketMetrics memory);
}
