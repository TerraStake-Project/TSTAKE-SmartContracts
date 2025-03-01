// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";

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

interface ITerraStakeToken is IERC20Upgradeable {
    function burn(address account, uint256 amount) external;
}

interface ITerraStakeNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function royaltyInfo(uint256 tokenId, uint256 salePrice) external view returns (address receiver, uint256 royaltyAmount);
    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function approve(address to, uint256 tokenId) external;
}

interface ITerraStakeFractions {
    function fractionalize(address owner, uint256 tokenId, uint256 fractionSupply, uint256 lockTime) external returns (address);
    function buyFractions(address fractionToken, uint256 amount) external;
    function sellFractions(address fractionToken, uint256 amount) external;
}

interface ITerraStakeMetadata {
    function getTokenMetadata(address collection, uint256 tokenId) external view returns (
        string memory name,
        string memory description,
        string memory image,
        bytes memory attributes
    );
    function getRarityRank(address collection, uint256 tokenId) external view returns (uint256 rank, uint256 totalSupply);
    function indexCollection(address collection) external;
}

/// @title TerraStake Marketplace
/// @notice Optimized NFT marketplace with fractionalization, bidding, and analytics
contract TerraStakeMarketplace is
    Initializable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    ERC721HolderUpgradeable
{
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.UintSet;

    // Roles
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");

    // Domain Separator for EIP-712
    bytes32 private constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant LISTING_TYPEHASH = keccak256("Listing(address seller,uint256 tokenId,uint256 price,bool isAuction,uint256 expiry,uint256 nonce)");
    mapping(address => uint256) public nonces;

    // Constants
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MIN_BID_INCREMENT_PERCENT = 10; // 10% bid increment
    uint256 public constant MAX_ROYALTY_PERCENTAGE = 1000; // 10% max royalty
    uint256 public constant CANCELLATION_FEE = 50; // 0.5% cancellation fee

    // Contract references
    ITerraStakeToken public tStakeToken;
    ITerraStakeNFT public nftContract;
    ITerraStakeFractions public fractionContract;
    ITerraStakeMetadata public metadataContract;
    address public treasury;
    address public stakingPool;
    address public liquidityPool;

    // Fee structure
    uint256 public stakingFeePercent;
    uint256 public liquidityFeePercent;
    uint256 public treasuryFeePercent;
    uint256 public burnFeePercent;
    uint256 public totalFeePercent;

    // Auction parameters
    uint256 public auctionExtensionTime;
    uint256 public auctionExtensionThreshold;

    // Supported payment tokens
    EnumerableSetUpgradeable.AddressSet private supportedPaymentTokens;

    // Collection tracking
    EnumerableSetUpgradeable.AddressSet private activeCollections;
    mapping(address => EnumerableSetUpgradeable.UintSet) private collectionTokenIds;

    // Collection metadata
    struct Collection {
        bool verified;
        uint256 floorPrice;
        uint256 totalVolume;
        uint256 totalSales;
        uint256 royaltyPercentage;
        address royaltyReceiver;
        bool customRoyalty;
    }
    mapping(address => Collection) public collections;

    // Marketplace State
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

    mapping(uint256 => Listing) public listings;
    mapping(uint256 => Bid) public bids;
    mapping(address => uint256) public pendingReturns;
    mapping(uint256 => mapping(address => Offer)) public offers;
    mapping(uint256 => TokenHistory) public tokenHistory;
    mapping(uint256 => address) public fractionalTokens;
    MarketMetrics public metrics;

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

    modifier onlyGovernance() {
        if (!hasRole(GOVERNANCE_ROLE, msg.sender)) revert NotAuthorized();
        _;
    }

    modifier onlyOperator() {
        if (!hasRole(OPERATOR_ROLE, msg.sender) && !hasRole(GOVERNANCE_ROLE, msg.sender)) 
            revert NotAuthorized();
        _;
    }

    modifier onlyListingOwner(uint256 tokenId) {
        if (msg.sender != listings[tokenId].seller) revert NotOwner();
        _;
    }

    function initialize(
        address _nftContract,
        address _tStakeToken,
        address _fractionContract,
        address _treasury,
        address _stakingPool,
        address _liquidityPool
    ) external initializer {
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __ERC721Holder_init();

        nftContract = ITerraStakeNFT(_nftContract);
        tStakeToken = ITerraStakeToken(_tStakeToken);
        fractionContract = ITerraStakeFractions(_fractionContract);
        treasury = _treasury;
        stakingPool = _stakingPool;
        liquidityPool = _liquidityPool;

        // Add platform token as supported payment
        supportedPaymentTokens.add(_tStakeToken);

        // Set initial fee structure (5% total fee by default)
        stakingFeePercent = 200; // 2%
        liquidityFeePercent = 100; // 1%
        treasuryFeePercent = 100; // 1%
        burnFeePercent = 100; // 1%
        totalFeePercent = 500; // 5%

        // Set auction parameters
        auctionExtensionTime = 15 minutes;
        auctionExtensionThreshold = 15 minutes;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);

        metrics.lastUpdateBlock = block.number;
    }

    /**
     * @notice Add or remove a supported payment token
     * @param token The token address
     * @param isSupported Whether to add or remove support
     */
    function setPaymentTokenSupport(address token, bool isSupported) external onlyGovernance {
        if (token == address(0)) revert InvalidCollection();

        if (isSupported && !supportedPaymentTokens.contains(token)) {
            supportedPaymentTokens.add(token);
            emit PaymentTokenAdded(token);
        } else if (!isSupported && supportedPaymentTokens.contains(token)) {
            supportedPaymentTokens.remove(token);
            emit PaymentTokenRemoved(token);
        }
    }

    /**
     * @notice Update fee structure
     * @dev Only callable by governance
     */
    function updateFeeStructure(
        uint256 _stakingFeePercent,
        uint256 _liquidityFeePercent,
        uint256 _treasuryFeePercent,
        uint256 _burnFeePercent
    ) external onlyGovernance {
        stakingFeePercent = _stakingFeePercent;
        liquidityFeePercent = _liquidityFeePercent;
        treasuryFeePercent = _treasuryFeePercent;
        burnFeePercent = _burnFeePercent;
        
        totalFeePercent = _stakingFeePercent + _liquidityFeePercent + _treasuryFeePercent + _burnFeePercent;
        
        if (totalFeePercent >= BASIS_POINTS) revert FeesTooHigh();
        
        emit FeeStructureUpdated(_stakingFeePercent, _liquidityFeePercent, _treasuryFeePercent, _burnFeePercent);
    }
/**
     * @notice Update auction parameters
     * @dev Only callable by governance
     */
    function updateAuctionParameters(
        uint256 _extensionTime,
        uint256 _extensionThreshold
    ) external onlyGovernance {
        auctionExtensionTime = _extensionTime;
        auctionExtensionThreshold = _extensionThreshold;
        
        emit AuctionParametersUpdated(_extensionTime, _extensionThreshold);
    }

    /**
     * @notice Add a collection and set its royalty information
     * @param collection The collection address
     * @param verified Whether the collection is verified
     * @param royaltyPercentage The royalty percentage (in basis points)
     * @param royaltyReceiver The address that receives royalties
     */
    function addCollection(
        address collection,
        bool verified,
        uint256 royaltyPercentage,
        address royaltyReceiver
    ) external onlyOperator {
        if (collection == address(0)) revert InvalidCollection();
        if (royaltyPercentage > MAX_ROYALTY_PERCENTAGE) revert RoyaltyTooHigh();
        if (royaltyReceiver == address(0) && royaltyPercentage > 0) revert InvalidRoyaltyReceiver();

        activeCollections.add(collection);
        
        collections[collection] = Collection({
            verified: verified,
            floorPrice: 0,
            totalVolume: 0,
            totalSales: 0,
            royaltyPercentage: royaltyPercentage,
            royaltyReceiver: royaltyReceiver,
            customRoyalty: true
        });
        
        // Try to index collection metadata
        try metadataContract.indexCollection(collection) {} catch {}
        
        // Update metrics
        unchecked {
            metrics.totalCollections += 1;
        }
        
        emit CollectionAdded(collection, verified);
        
        if (royaltyPercentage > 0) {
            emit CollectionRoyaltyUpdated(collection, royaltyPercentage, royaltyReceiver);
        }
    }

    /**
     * @notice List an NFT for sale
     * @param tokenId The ID of the NFT to list
     * @param price The listing price
     * @param isAuction Whether to list as auction
     * @param expiry Listing expiry timestamp
     * @param paymentToken The token to accept as payment
     */
    function listNFT(
        uint256 tokenId,
        uint256 price,
        bool isAuction,
        uint256 expiry,
        address paymentToken
    ) external whenNotPaused nonReentrant {
        if (nftContract.ownerOf(tokenId) != msg.sender) revert NotOwner();
        if (price == 0) revert InvalidPrice();
        if (expiry <= block.timestamp) revert InvalidExpiration();
        if (!supportedPaymentTokens.contains(paymentToken)) revert UnsupportedPaymentToken();
        
        // Transfer NFT to marketplace
        nftContract.safeTransferFrom(msg.sender, address(this), tokenId);
        
        // Create listing
        listings[tokenId] = Listing({
            seller: msg.sender,
            tokenId: tokenId,
            price: price,
            isAuction: isAuction,
            isFractional: false,
            fractions: 0,
            expiry: expiry,
            active: true,
            paymentToken: paymentToken
        });
        
        // Set up auction if needed
        if (isAuction) {
            bids[tokenId] = Bid({
                highestBidder: address(0),
                highestBid: 0,
                bidEndTime: expiry,
                paymentToken: paymentToken
            });
        }
        
        // Add to collection tracking
        address collection = address(nftContract);
        collectionTokenIds[collection].add(tokenId);
        
        // Update metrics
        unchecked {
            metrics.activeListings += 1;
        }
        
        emit NFTListed(tokenId, msg.sender, price, isAuction, expiry, paymentToken);
    }

    /**
     * @notice Batch list multiple NFTs
     * @param tokenIds Array of token IDs to list
     * @param prices Array of prices
     * @param isAuctions Array of auction flags
     * @param expiries Array of expiry timestamps
     * @param paymentToken The token to accept as payment for all listings
     */
    function batchListNFTs(
        uint256[] calldata tokenIds,
        uint256[] calldata prices,
        bool[] calldata isAuctions,
        uint256[] calldata expiries,
        address paymentToken
    ) external whenNotPaused nonReentrant {
        if (tokenIds.length != prices.length || 
            tokenIds.length != isAuctions.length || 
            tokenIds.length != expiries.length) revert InvalidOffer();
        
        if (!supportedPaymentTokens.contains(paymentToken)) revert UnsupportedPaymentToken();
        
        uint256 successCount = 0;
        address collection = address(nftContract);
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            uint256 price = prices[i];
            bool isAuction = isAuctions[i];
            uint256 expiry = expiries[i];
            
            if (nftContract.ownerOf(tokenId) == msg.sender && 
                price > 0 && 
                expiry > block.timestamp) {
                
                // Transfer NFT to marketplace
                nftContract.safeTransferFrom(msg.sender, address(this), tokenId);
                
                // Create listing
                listings[tokenId] = Listing({
                    seller: msg.sender,
                    tokenId: tokenId,
                    price: price,
                    isAuction: isAuction,
                    isFractional: false,
                    fractions: 0,
                    expiry: expiry,
                    active: true,
                    paymentToken: paymentToken
                });
                
                // Set up auction if needed
                if (isAuction) {
                    bids[tokenId] = Bid({
                        highestBidder: address(0),
                        highestBid: 0,
                        bidEndTime: expiry,
                        paymentToken: paymentToken
                    });
                }
                
                // Add to collection tracking
                collectionTokenIds[collection].add(tokenId);
                
                unchecked {
                    successCount++;
                }
                
                emit NFTListed(tokenId, msg.sender, price, isAuction, expiry, paymentToken);
            }
        }
        
        // Update metrics
        unchecked {
            metrics.activeListings += successCount;
        }
        
        emit BatchOperationProcessed(msg.sender, successCount, "BatchList");
    }

    /**
     * @notice Update a listing's price and expiry
     * @param tokenId The ID of the NFT
     * @param newPrice The new price
     * @param newExpiry The new expiry timestamp
     */
    function updateListing(
        uint256 tokenId,
        uint256 newPrice,
        uint256 newExpiry
    ) external nonReentrant onlyListingOwner(tokenId) {
        Listing storage listing = listings[tokenId];
        
        if (!listing.active) revert ListingNotActive();
        if (listing.isAuction && bids[tokenId].highestBidder != address(0)) revert NotAuthorized();
        if (newPrice == 0) revert InvalidPrice();
        if (newExpiry <= block.timestamp) revert InvalidExpiration();
        
        listing.price = newPrice;
        listing.expiry = newExpiry;
        
        // Also update auction end time if it's an auction
        if (listing.isAuction) {
            bids[tokenId].bidEndTime = newExpiry;
        }
        
        emit ListingUpdated(tokenId, newPrice, newExpiry);
    }

    /**
     * @notice Cancel a listing
     * @param tokenId The ID of the NFT to cancel
     */
    function cancelListing(uint256 tokenId) external nonReentrant onlyListingOwner(tokenId) {
        Listing storage listing = listings[tokenId];
        if (!listing.active) revert ListingNotActive();
        
        // For auctions, check if there are bids
        if (listing.isAuction && bids[tokenId].highestBidder != address(0)) {
            if (block.timestamp <= listing.expiry) revert NotAuthorized();
            
            // Return the NFT to seller but don't reset the auction - it needs to be finalized
            nftContract.safeTransferFrom(address(this), listing.seller, tokenId);
            listing.active = false;
        } else {
            address paymentToken = listing.paymentToken;
            
            // Charge cancellation fee if the listing is recent
            if (block.timestamp < listing.expiry - 1 days) {
                uint256 cancellationFee = (listing.price * CANCELLATION_FEE) / BASIS_POINTS;
                
                // Only charge if the seller has the tokens
                if (cancellationFee > 0 && 
                    IERC20Upgradeable(paymentToken).balanceOf(msg.sender) >= cancellationFee && 
                    IERC20Upgradeable(paymentToken).allowance(msg.sender, address(this)) >= cancellationFee) {
                    
                    // Take cancellation fee
                    IERC20Upgradeable(paymentToken).transferFrom(msg.sender, treasury, cancellationFee);
                }
            }
            
            // For regular listings or auctions without bids, return the NFT and deactivate
            nftContract.safeTransferFrom(address(this), listing.seller, tokenId);
            listing.active = false;
            
            // Update metrics
            unchecked {
                metrics.activeListings -= 1;
            }
        }

        emit ListingCancelled(tokenId, msg.sender);
    }

    /**
     * @notice Buy an NFT at the listed price
     * @param tokenId The ID of the NFT to buy
     */
    function buyNFT(uint256 tokenId) external whenNotPaused nonReentrant {
        Listing storage listing = listings[tokenId];
        if (!listing.active) revert ListingNotActive();
        if (listing.isAuction) revert NotAuthorized();
        if (block.timestamp > listing.expiry) revert AuctionEnded();

        uint256 price = listing.price;
        address seller = listing.seller;
        address paymentToken = listing.paymentToken;
        
        // Get collection from which token came (needed for royalties)
        address collection = address(nftContract);
        
        // Calculate royalties
        (address royaltyReceiver, uint256 royaltyAmount) = _calculateRoyalties(collection, tokenId, price);
        
        // Mark listing as inactive (checks-effects-interactions pattern)
        listing.active = false;
        
        // Update metrics
        unchecked {
            metrics.activeListings -= 1;
            metrics.totalVolume += price;
            collections[collection].totalVolume += price;
            collections[collection].totalSales += 1;
        }
        
        // Update token history
        _updateTokenHistory(tokenId, price, msg.sender);
        
        // Process fees and royalties
        uint256 sellerAmount = _processFeesAndRoyalties(price, tokenId, royaltyReceiver, royaltyAmount, paymentToken);
        
        // Transfer payment tokens from buyer to contract
        bool success = IERC20Upgradeable(paymentToken).transferFrom(msg.sender, address(this), price);
        if (!success) revert InsufficientFunds();
        
        // Transfer remaining amount to seller
        IERC20Upgradeable(paymentToken).transfer(seller, sellerAmount);
        
        // Transfer NFT to buyer
        nftContract.safeTransferFrom(address(this), msg.sender, tokenId);
        
        emit NFTPurchased(tokenId, msg.sender, price, paymentToken);
    }

    /**
     * @notice Place a bid on an NFT auction
     * @param tokenId The ID of the NFT to bid on
     * @param bidAmount The bid amount
     */
    function placeBid(uint256 tokenId, uint256 bidAmount) external whenNotPaused nonReentrant {
        Listing storage listing = listings[tokenId];
        if (!listing.active) revert ListingNotActive();
        if (!listing.isAuction) revert NotAuthorized();
        
        Bid storage auction = bids[tokenId];
        if (block.timestamp > auction.bidEndTime) revert AuctionEnded();
        if (listing.seller == msg.sender) revert CannotBidOwnItem();
        if (auction.highestBidder == msg.sender) revert AlreadyHighestBidder();

        // Check if bid is higher than current highest bid plus minimum increment
        uint256 minBidRequired;
        if (auction.highestBidder == address(0)) {
            // First bid must be at least the reserve price
            minBidRequired = listing.price;
        } else {
            // Subsequent bids must increase by at least MIN_BID_INCREMENT_PERCENT
            minBidRequired = auction.highestBid + (auction.highestBid * MIN_BID_INCREMENT_PERCENT / 100);
        }
        
        if (bidAmount < minBidRequired) revert InvalidPrice();

        address paymentToken = auction.paymentToken;

        // Store previous bidder info for refund
        address previousBidder = auction.highestBidder;
        uint256 previousBid = auction.highestBid;
        
        // Update auction data (checks-effects-interactions pattern)
        auction.highestBidder = msg.sender;
        auction.highestBid = bidAmount;
        
        // Extend auction if bid is placed close to end time
        if (auction.bidEndTime - block.timestamp < auctionExtensionThreshold) {
            auction.bidEndTime += auctionExtensionTime;
            emit AuctionExtended(tokenId, auction.bidEndTime);
        }

        // Transfer bid amount from bidder to contract
        bool success = IERC20Upgradeable(paymentToken).transferFrom(msg.sender, address(this), bidAmount);
        if (!success) revert InsufficientFunds();
        
        // Refund previous bidder if there was one
if (previousBidder != address(0)) {
            IERC20Upgradeable(paymentToken).transfer(previousBidder, previousBid);
        }
        
        emit NFTBidPlaced(tokenId, msg.sender, bidAmount, paymentToken);
    }

    /**
     * @notice Finalize an auction after it has ended
     * @param tokenId The ID of the NFT auction to finalize
     */
    function finalizeAuction(uint256 tokenId) external nonReentrant {
        Listing storage listing = listings[tokenId];
        Bid storage auction = bids[tokenId];
        
        if (!listing.active) revert ListingNotActive();
        if (!listing.isAuction) revert NotAuthorized();
        if (block.timestamp <= auction.bidEndTime) revert NotAuthorized();
        
        address highestBidder = auction.highestBidder;
        uint256 highestBid = auction.highestBid;
        address paymentToken = auction.paymentToken;
        
        if (highestBidder == address(0)) {
            // No bids were placed, return NFT to seller
            nftContract.safeTransferFrom(address(this), listing.seller, tokenId);
        } else {
            // Get collection for royalties
            address collection = address(nftContract);
            
            // Calculate royalties
            (address royaltyReceiver, uint256 royaltyAmount) = _calculateRoyalties(collection, tokenId, highestBid);
            
            // Process fees and royalties
            uint256 sellerAmount = _processFeesAndRoyalties(highestBid, tokenId, royaltyReceiver, royaltyAmount, paymentToken);
            
            // Update metrics
            unchecked {
                metrics.totalVolume += highestBid;
                collections[collection].totalVolume += highestBid;
                collections[collection].totalSales += 1;
            }
            
            // Update token history
            _updateTokenHistory(tokenId, highestBid, highestBidder);
            
            // Transfer NFT to highest bidder
            nftContract.safeTransferFrom(address(this), highestBidder, tokenId);
            
            // Transfer remaining amount to seller - highestBid already in contract from placeBid
            IERC20Upgradeable(paymentToken).transfer(listing.seller, sellerAmount);
            
            emit NFTAuctionFinalized(tokenId, highestBidder, highestBid, paymentToken);
        }
        
        // Mark listing as inactive
        listing.active = false;
        
        // Update metrics
        unchecked {
            metrics.activeListings -= 1;
        }
    }

    /**
     * @notice Make an offer for an NFT
     * @param tokenId The ID of the NFT
     * @param offerAmount The offer amount
     * @param expiry Offer expiry timestamp
     * @param paymentToken The token used for payment
     */
    function createOffer(
        uint256 tokenId,
        uint256 offerAmount,
        uint256 expiry,
        address paymentToken
    ) external whenNotPaused nonReentrant {
        if (expiry <= block.timestamp) revert InvalidExpiration();
        if (offerAmount == 0) revert InvalidPrice();
        if (!supportedPaymentTokens.contains(paymentToken)) revert UnsupportedPaymentToken();
        
        address owner = nftContract.ownerOf(tokenId);
        if (owner == address(0)) revert InvalidOffer();
        if (owner == msg.sender) revert CannotBidOwnItem();
        
        // Refund old offer if exists
        if (offers[tokenId][msg.sender].active) {
            address oldPaymentToken = offers[tokenId][msg.sender].paymentToken;
            uint256 oldOfferAmount = offers[tokenId][msg.sender].offerAmount;
            
            IERC20Upgradeable(oldPaymentToken).transfer(msg.sender, oldOfferAmount);
        }
        
        // Transfer offer amount to contract
        bool success = IERC20Upgradeable(paymentToken).transferFrom(msg.sender, address(this), offerAmount);
        if (!success) revert InsufficientFunds();
        
        // Create the offer
        offers[tokenId][msg.sender] = Offer({
            offerer: msg.sender,
            offerAmount: offerAmount,
            expiry: expiry,
            active: true,
            paymentToken: paymentToken
        });
        
        // Update metrics
        unchecked {
            metrics.totalOffers += 1;
        }
        
        emit OfferCreated(tokenId, msg.sender, offerAmount, expiry, paymentToken);
    }

    /**
     * @notice Cancel an offer for an NFT
     * @param tokenId The ID of the NFT
     */
    function cancelOffer(uint256 tokenId) external nonReentrant {
        Offer storage offer = offers[tokenId][msg.sender];
        
        if (!offer.active) revert InvalidOffer();
        
        offer.active = false;
        
        // Update metrics
        unchecked {
            metrics.totalOffers -= 1;
        }
        
        // Refund the offer amount
        IERC20Upgradeable(offer.paymentToken).transfer(msg.sender, offer.offerAmount);
        
        emit OfferCancelled(tokenId, msg.sender);
    }

    /**
     * @notice Accept an offer for an NFT
     * @param tokenId The ID of the NFT
     * @param offerer The address of the user who made the offer
     */
    function acceptOffer(uint256 tokenId, address offerer) external whenNotPaused nonReentrant {
        Offer storage offer = offers[tokenId][offerer];
        
        if (!offer.active) revert InvalidOffer();
        if (block.timestamp > offer.expiry) revert OfferExpired();
        
        // Verify NFT ownership
        address nftOwner = nftContract.ownerOf(tokenId);
        if (nftOwner != msg.sender) revert NotOwner();
        
        uint256 offerAmount = offer.offerAmount;
        address paymentToken = offer.paymentToken;
        
        // Calculate royalties
        address collection = address(nftContract);
        (address royaltyReceiver, uint256 royaltyAmount) = _calculateRoyalties(collection, tokenId, offerAmount);
        
        // Mark the offer as inactive
        offer.active = false;
        
        // Update metrics
        unchecked {
            metrics.totalOffers -= 1;
            metrics.totalVolume += offerAmount;
            collections[collection].totalVolume += offerAmount;
            collections[collection].totalSales += 1;
        }
        
        // Update token history
        _updateTokenHistory(tokenId, offerAmount, offerer);
        
        // Process fees and royalties (funds already in contract from createOffer)
        uint256 sellerAmount = _processFeesAndRoyalties(offerAmount, tokenId, royaltyReceiver, royaltyAmount, paymentToken);
        
        // Transfer NFT from seller to offerer
        nftContract.safeTransferFrom(msg.sender, offerer, tokenId);
        
        // Transfer payment to seller
        IERC20Upgradeable(paymentToken).transfer(msg.sender, sellerAmount);
        
        // If there was an active listing for this NFT, deactivate it
        if (listings[tokenId].active && listings[tokenId].seller == msg.sender) {
            listings[tokenId].active = false;
            
            unchecked {
                metrics.activeListings -= 1;
            }
        }
        
        emit OfferAccepted(tokenId, offerer, msg.sender, offerAmount);
    }

    /**
     * @notice Process marketplace fees and creator royalties
     * @param amount The total transaction amount
     * @param tokenId The NFT token ID for royalty calculation
     * @param royaltyReceiver The address to receive royalties
     * @param royaltyAmount The amount of royalties to pay
     * @param paymentToken The token used for payment
     * @return sellerAmount The remaining amount for the seller after fees and royalties
     */
    function _processFeesAndRoyalties(
        uint256 amount,
        uint256 tokenId,
        address royaltyReceiver,
        uint256 royaltyAmount,
        address paymentToken
    ) internal returns (uint256) {
        // Calculate fee amounts
        uint256 stakingAmount = amount * stakingFeePercent / BASIS_POINTS;
        uint256 liquidityAmount = amount * liquidityFeePercent / BASIS_POINTS;
        uint256 treasuryAmount = amount * treasuryFeePercent / BASIS_POINTS;
        uint256 burnAmount = amount * burnFeePercent / BASIS_POINTS;
        uint256 totalFees = stakingAmount + liquidityAmount + treasuryAmount + burnAmount + royaltyAmount;
        
        // Distribute marketplace fees
        if (stakingAmount > 0) {
            IERC20Upgradeable(paymentToken).transfer(stakingPool, stakingAmount);
        }
        
        if (liquidityAmount > 0) {
            IERC20Upgradeable(paymentToken).transfer(liquidityPool, liquidityAmount);
        }
        
        if (treasuryAmount > 0) {
            IERC20Upgradeable(paymentToken).transfer(treasury, treasuryAmount);
        }
        
        if (burnAmount > 0 && paymentToken == address(tStakeToken)) {
            tStakeToken.burn(address(this), burnAmount);
        } else if (burnAmount > 0) {
            // If not the platform token, send to burn address
            IERC20Upgradeable(paymentToken).transfer(address(0xdead), burnAmount);
        }
        
        // Pay royalties to creator if applicable
        if (royaltyAmount > 0 && royaltyReceiver != address(0)) {
            IERC20Upgradeable(paymentToken).transfer(royaltyReceiver, royaltyAmount);
            emit RoyaltyPaid(tokenId, royaltyReceiver, royaltyAmount);
        }
        
        emit FeesDistributed(stakingAmount, liquidityAmount, treasuryAmount, burnAmount);
        
        // Return remaining amount for seller
        return amount - totalFees;
    }

    /**
     * @notice Calculate royalties for a token sale
     * @param collection The NFT collection address
     * @param tokenId The token ID
     * @param amount The sale amount
     * @return receiver Royalty receiver address
     * @return royaltyAmount Royalty amount to pay
     */
    function _calculateRoyalties(
        address collection,
        uint256 tokenId,
        uint256 amount
    ) internal view returns (address receiver, uint256 royaltyAmount) {
        try ITerraStakeNFT(collection).royaltyInfo(tokenId, amount) returns (address _receiver, uint256 _royaltyAmount) {
            // Use ERC2981 royalty if available and not exceeding maximum
            if (_royaltyAmount <= amount * MAX_ROYALTY_PERCENTAGE / BASIS_POINTS) {
                return (_receiver, _royaltyAmount);
            }
        } catch {
            // Fall back to collection-level royalty settings if ERC2981 not supported
        }
        
        // Use collection-level royalty settings
        if (collections[collection].customRoyalty) {
            receiver = collections[collection].royaltyReceiver;
            royaltyAmount = amount * collections[collection].royaltyPercentage / BASIS_POINTS;
        } else {
            // No royalty info available
            receiver = address(0);
            royaltyAmount = 0;
        }
    }

    /**
     * @notice Update token price history
     * @param tokenId The token ID
     * @param price The sale price
     * @param buyer The buyer address
     */
    function _updateTokenHistory(uint256 tokenId, uint256 price, address buyer) internal {
        TokenHistory storage history = tokenHistory[tokenId];
        
        // Update last sold information
        history.lastSoldPrice = price;
        history.lastSoldTo = buyer;
        history.lastSoldTime = block.timestamp;
        
        // Update highest ever price if applicable
        if (price > history.highestEverPrice) {
            history.highestEverPrice = price;
        }
        
        // Add to price history (up to 10 entries)
        if (history.priceHistory.length < 10) {
            history.priceHistory.push(price);
            history.timestampHistory.push(block.timestamp);
        } else {
            // Shift array and add new entry
            for (uint256 i = 0; i < 9; i++) {
                history.priceHistory[i] = history.priceHistory[i + 1];
                history.timestampHistory[i] = history.timestampHistory[i + 1];
            }
            history.priceHistory[9] = price;
            history.timestampHistory[9] = block.timestamp;
        }
    }

    /**
     * @notice Withdraw pending returns (e.g., from outbid auctions)
     */
    function withdrawPendingReturns() external nonReentrant {
        uint256 amount = pendingReturns[msg.sender];
        if (amount == 0) revert InsufficientFunds();
        
        // Reset pending returns before transfer to prevent reentrancy
        pendingReturns[msg.sender] = 0;
        
        // Transfer funds back to user
        IERC20Upgradeable(address(tStakeToken)).transfer(msg.sender, amount);
        
        emit FundsWithdrawn(msg.sender, amount);
    }

    /**
     * @notice Fractionalize an NFT into ERC20 tokens
     * @param tokenId The ID of the NFT to fractionalize
     * @param fractionSupply Total number of fraction tokens to create
     * @param lockTime Duration the NFT remains locked in fractionalization
     */
    function fractionalizeNFT(
        uint256 tokenId,
        uint256 fractionSupply,
        uint256 lockTime
    ) external whenNotPaused nonReentrant {
        if (nftContract.ownerOf(tokenId) != msg.sender) revert NotOwner();
        if (fractionSupply == 0) revert InvalidPrice();
        
        // Transfer NFT to marketplace
        nftContract.safeTransferFrom(msg.sender, address(this), tokenId);
        
        // Approve the fractionalization contract to take the NFT
        nftContract.approve(address(fractionContract), tokenId);
        
        // Call the fractionalization contract
        address fractionToken = fractionContract.fractionalize(msg.sender, tokenId, fractionSupply, lockTime);
        
        // Store fraction token address for this NFT
        fractionalTokens[tokenId] = fractionToken;
        
        // Update metrics
        unchecked {
            metrics.fractionalizedAssets += 1;
        }
        
        emit NFTFractionalized(tokenId, fractionToken);
    }

    /**
     * @notice Calculate the current floor price for a collection
     * @param collection The collection address
     */
/**
     * @notice Calculate the current floor price for a collection
     * @param collection The collection address
     */
    function calculateFloorPrice(address collection) external onlyOperator {
        EnumerableSetUpgradeable.UintSet storage tokenIds = collectionTokenIds[collection];
        uint256 length = tokenIds.length();
        
        if (length == 0) {
            collections[collection].floorPrice = 0;
            return;
        }
        
        uint256 lowestPrice = type(uint256).max;
        
        for (uint256 i = 0; i < length; i++) {
            uint256 tokenId = tokenIds.at(i);
            Listing storage listing = listings[tokenId];
            
            if (listing.active && !listing.isAuction && listing.price < lowestPrice) {
                lowestPrice = listing.price;
            }
        }
        
        if (lowestPrice != type(uint256).max) {
            collections[collection].floorPrice = lowestPrice;
            emit FloorPriceUpdated(collection, lowestPrice);
        }
    }

    /**
     * @notice Update core contract addresses
     * @param _treasury New treasury address
     * @param _stakingPool New staking pool address
     * @param _liquidityPool New liquidity pool address
     * @param _metadataContract New metadata contract address
     */
    function updateCoreAddresses(
        address _treasury,
        address _stakingPool,
        address _liquidityPool,
        address _metadataContract
    ) external onlyGovernance {
        if (_treasury != address(0)) treasury = _treasury;
        if (_stakingPool != address(0)) stakingPool = _stakingPool;
        if (_liquidityPool != address(0)) liquidityPool = _liquidityPool;
        if (_metadataContract != address(0)) metadataContract = ITerraStakeMetadata(_metadataContract);
        
        emit CoreAddressesUpdated(_treasury, _stakingPool, _liquidityPool, _metadataContract);
    }

    /**
     * @notice Update contract references
     * @param _nftContract New NFT contract address
     * @param _fractionContract New fractionalization contract address
     */
    function updateContracts(
        address _nftContract,
        address _fractionContract
    ) external onlyGovernance {
        if (_nftContract != address(0)) nftContract = ITerraStakeNFT(_nftContract);
        if (_fractionContract != address(0)) fractionContract = ITerraStakeFractions(_fractionContract);
        
        emit ContractsUpdated(_nftContract, _fractionContract);
    }

    /**
     * @notice Pause the marketplace
     */
    function pause() external onlyOperator {
        _pause();
    }

    /**
     * @notice Unpause the marketplace
     */
    function unpause() external onlyOperator {
        _unpause();
    }

    /**
     * @notice Emergency function to rescue accidentally sent tokens
     * @param token Address of the token to rescue
     * @param amount Amount to rescue
     * @param destination Address to send the rescued tokens to
     */
    function rescueTokens(
        address token,
        uint256 amount,
        address destination
    ) external onlyGovernance {
        IERC20Upgradeable(token).transfer(destination, amount);
    }

    /**
     * @notice Get token metadata from the metadata contract
     * @param tokenId The NFT token ID
     */
    function getTokenMetadata(uint256 tokenId) external view returns (
        string memory name,
        string memory description,
        string memory image,
        bytes memory attributes
    ) {
        return metadataContract.getTokenMetadata(address(nftContract), tokenId);
    }

    /**
     * @notice Get token rarity information
     * @param tokenId The NFT token ID
     */
    function getTokenRarity(uint256 tokenId) external view returns (
        uint256 rank,
        uint256 totalSupply
    ) {
        return metadataContract.getRarityRank(address(nftContract), tokenId);
    }

    /**
     * @notice Get recommended listing price based on history and rarity
     * @param tokenId The NFT token ID
     */
    function getRecommendedPrice(uint256 tokenId) external view returns (uint256) {
        TokenHistory storage history = tokenHistory[tokenId];
        
        if (history.lastSoldPrice > 0) {
            // If we have price history, use it as a base
            uint256 basePrice = history.lastSoldPrice;
            
            // Attempt to get rarity data
            (uint256 rank, uint256 totalSupply) = metadataContract.getRarityRank(address(nftContract), tokenId);
            
            if (totalSupply > 0) {
                // Adjust price based on rarity percentile
                uint256 rarityPercentile = (totalSupply - rank) * 100 / totalSupply;
                
                if (rarityPercentile > 90) {
                    // Top 10% rarity: 50% premium
                    return basePrice * 150 / 100;
                } else if (rarityPercentile > 70) {
                    // Top 30% rarity: 20% premium
                    return basePrice * 120 / 100;
                } else if (rarityPercentile < 20) {
                    // Bottom 20% rarity: 10% discount
                    return basePrice * 90 / 100;
                }
            }
            
            return basePrice;
        } else {
            // If no price history for this specific token, use collection floor price
            return collections[address(nftContract)].floorPrice;
        }
    }

    /**
     * @notice Check if a signature is valid for listing
     * @param tokenId The NFT token ID
     * @param price The listing price
     * @param isAuction Whether this is an auction
     * @param expiry Listing expiry timestamp
     * @param deadline Signature deadline
     * @param v Signature component v
     * @param r Signature component r
     * @param s Signature component s
     */
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
    ) public view returns (bool) {
        if (block.timestamp > deadline) revert SignatureExpired();
        
        bytes32 domainSeparator = keccak256(abi.encode(
            DOMAIN_TYPEHASH,
            keccak256(bytes("TerraStakeMarketplace")),
            keccak256(bytes("1")),
            block.chainid,
            address(this)
        ));
        
        bytes32 structHash = keccak256(abi.encode(
            LISTING_TYPEHASH,
            seller,
            tokenId,
            price,
            isAuction,
            expiry,
            nonces[seller]
        ));
        
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            domainSeparator,
            structHash
        ));
        
        address recoveredAddress = ECDSAUpgradeable.recover(digest, v, r, s);
        return recoveredAddress == seller;
    }

    /**
     * @notice List with a signature (gasless listing)
     * @param seller The NFT seller
     * @param tokenId The NFT token ID
     * @param price The listing price
     * @param isAuction Whether this is an auction
     * @param expiry Listing expiry timestamp
     * @param paymentToken The token to accept as payment
     * @param deadline Signature deadline
     * @param v Signature component v
     * @param r Signature component r
     * @param s Signature component s
     */
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
    ) external whenNotPaused nonReentrant {
        if (!hasRole(RELAYER_ROLE, msg.sender)) revert NotAuthorized();
        if (!verifyListingSignature(seller, tokenId, price, isAuction, expiry, deadline, v, r, s)) 
            revert InvalidSignature();
        if (expiry <= block.timestamp) revert InvalidExpiration();
        if (price == 0) revert InvalidPrice();
        if (!supportedPaymentTokens.contains(paymentToken)) revert UnsupportedPaymentToken();
        
        // Verify NFT ownership
        if (nftContract.ownerOf(tokenId) != seller) revert NotOwner();
        
        // Verify NFT approval
        if (nftContract.getApproved(tokenId) != address(this) && 
            !nftContract.isApprovedForAll(seller, address(this))) 
            revert TokenNotApproved();
        
        // Transfer NFT to marketplace
        nftContract.safeTransferFrom(seller, address(this), tokenId);
        
        // Increment nonce to prevent signature reuse
        nonces[seller]++;
        
        // Create listing
        listings[tokenId] = Listing({
            seller: seller,
            tokenId: tokenId,
            price: price,
            isAuction: isAuction,
            isFractional: false,
            fractions: 0,
            expiry: expiry,
            active: true,
            paymentToken: paymentToken
        });
        
        // Set up auction if needed
        if (isAuction) {
            bids[tokenId] = Bid({
                highestBidder: address(0),
                highestBid: 0,
                bidEndTime: expiry,
                paymentToken: paymentToken
            });
        }
        
        // Add to collection tracking
        address collection = address(nftContract);
        collectionTokenIds[collection].add(tokenId);
        
        // Update metrics
        unchecked {
            metrics.activeListings += 1;
        }
        
        emit NFTListed(tokenId, seller, price, isAuction, expiry, paymentToken);
    }

    // Function to receive ETH if needed
    receive() external payable {}
}
