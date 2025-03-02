// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

interface ITerraStakeMarketplace {
    // Structs
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

    struct Collection {
        bool verified;
        uint256 floorPrice;
        uint256 totalVolume;
        uint256 totalSales;
        uint256 royaltyPercentage;
        address royaltyReceiver;
        bool customRoyalty;
    }

    struct MarketMetrics {
        uint256 totalVolume;
        uint256 activeListings;
        uint256 fractionalizedAssets;
        uint256 totalOffers;
        uint256 totalCollections;
        uint256 lastUpdateBlock;
    }

    // View Functions
    function nftContract() external view returns (address);
    function tStakeToken() external view returns (address);
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
    function listings(uint256 tokenId) external view returns (Listing memory);
    function bids(uint256 tokenId) external view returns (Bid memory);
    function offers(uint256 tokenId, address offerer) external view returns (Offer memory);
    function tokenHistory(uint256 tokenId) external view returns (TokenHistory memory);
    function fractionalTokens(uint256 tokenId) external view returns (address);
    function collections(address collection) external view returns (Collection memory);
    function pendingReturns(address user) external view returns (uint256);
    function metrics() external view returns (MarketMetrics memory);

    // Governance/Admin Functions
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
    
    function calculateFloorPrice(address collection) external;
    
    function pause() external;
    
    function unpause() external;
    
    function rescueTokens(
        address token,
        uint256 amount,
        address destination
    ) external;

    // User Functions
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
    
    function placeBid(uint256 tokenId, uint256 bidAmount) external;
    
    function finalizeAuction(uint256 tokenId) external;
    
    function createOffer(
        uint256 tokenId,
        uint256 offerAmount,
        uint256 expiry,
        address paymentToken
    ) external;
    
    function cancelOffer(uint256 tokenId) external;
    
    function acceptOffer(uint256 tokenId, address offerer) external;
    
    function withdrawPendingReturns() external;
    
    function fractionalizeNFT(
        uint256 tokenId,
        uint256 fractionSupply,
        uint256 lockTime
    ) external;
    
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

    // Utility Functions
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
    
    function getRecommendedPrice(uint256 tokenId) external view returns (uint256);
    
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
}
