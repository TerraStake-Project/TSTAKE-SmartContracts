// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";
import "./interfaces/IFractionToken.sol";

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
    IFractionToken public fractionContract;
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
        fractionContract = IFractionToken(_fractionContract);
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
        uint256
        royaltyPercentage,
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
     * @notice Set verification status for a collection
     * @param collection The collection address to verify
     * @param isVerified Whether the collection is verified
     */
    function setCollectionVerification(address collection, bool isVerified) external onlyOperator {
        if (!activeCollections.contains(collection)) revert InvalidCollection();
        collections[collection].verified = isVerified;
        if (isVerified) {
            emit CollectionVerified(collection);
        }
    }

    /**
     * @notice Update collection royalty information
     * @param collection The collection address
     * @param royaltyPercentage The royalty percentage (in basis points)
     * @param royaltyReceiver The address that receives royalties
     */
    function updateCollectionRoyalty(
        address collection,
        uint256 royaltyPercentage,
        address royaltyReceiver
    ) external onlyOperator {
        if (!activeCollections.contains(collection)) revert InvalidCollection();
        if (royaltyPercentage > MAX_ROYALTY_PERCENTAGE) revert RoyaltyTooHigh();
        if (royaltyReceiver == address(0) && royaltyPercentage > 0) revert InvalidRoyaltyReceiver();
        
        collections[collection].royaltyPercentage = royaltyPercentage;
        collections[collection].royaltyReceiver = royaltyReceiver;
        collections[collection].customRoyalty = true;
        
        emit CollectionRoyaltyUpdated(collection, royaltyPercentage, royaltyReceiver);
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
     * @notice List an NFT for sale or auction
     * @param tokenId The ID of the NFT to list
     * @param price The listing price or auction starting price
     * @param isAuction Whether the listing is an auction
     * @param expiry The expiration time for the listing
     * @param paymentToken The token address to accept as payment
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
        if (expiry > 0 && expiry <= block.timestamp) revert InvalidExpiration();
        if (!supportedPaymentTokens.contains(paymentToken)) revert UnsupportedPaymentToken();
        
        // Check token approval
        address approvedAddress = nftContract.getApproved(tokenId);
        bool isApprovedForAll = nftContract.isApprovedForAll(msg.sender, address(this));
        if (approvedAddress != address(this) && !isApprovedForAll) revert TokenNotApproved();
        
        // Create listing
        listings[tokenId] = Listing({
            seller: msg.sender,
            tokenId: tokenId,
            price: price,
            isAuction: isAuction,
            isFractional: false,
            fractions: 0,
            expiry: expiry > 0 ? expiry : type(uint256).max,
            active: true,
            paymentToken: paymentToken
        });
        
        // Transfer NFT to marketplace
        nftContract.safeTransferFrom(msg.sender, address(this), tokenId);
        
        // Setup auction if applicable
        if (isAuction) {
            bids[tokenId] = Bid({
                highestBidder: address(0),
                highestBid: 0,
                bidEndTime: expiry,
                paymentToken: paymentToken
            });
        }
        
        // Track the token in its collection
        address collection = address(nftContract);
        if (!activeCollections.contains(collection)) {
            activeCollections.add(collection);
            unchecked {
                metrics.totalCollections += 1;
            }
        }
        collectionTokenIds[collection].add(tokenId);
        
        // Update metrics
        unchecked {
            metrics.activeListings += 1;
        }
        
        emit NFTListed(tokenId, msg.sender, price, isAuction, expiry, paymentToken);
    }

    /**
     * @notice List an NFT for sale with a trusted signature
     * @dev Uses EIP-712 signatures to validate the listing
     * @param tokenId The ID of the NFT to list
     * @param price The listing price
     * @param isAuction Whether the listing is an auction
     * @param expiry The expiration time for the listing
     * @param paymentToken The token address to accept as payment
     * @param signature ECDSA signature authorizing the listing
     */
    function listNFTWithSignature(
        uint256 tokenId,
        uint256 price,
        bool isAuction,
        uint256 expiry,
        address paymentToken,
        bytes calldata signature
    ) external whenNotPaused nonReentrant {
        if (nftContract.ownerOf(tokenId) != msg.sender) revert NotOwner();
        if (price == 0) revert InvalidPrice();
        if (expiry > 0 && expiry <= block.timestamp) revert InvalidExpiration();
        if (!supportedPaymentTokens.contains(paymentToken)) revert UnsupportedPaymentToken();
        
        // Verify signature
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    LISTING_TYPEHASH,
                    msg.sender,
                    tokenId,
                    price,
                    isAuction,
                    expiry,
                    nonces[msg.sender]++
                )
            )
        );
        
        address signer = ECDSAUpgradeable.recover(digest, signature);
        if (!hasRole(RELAYER_ROLE, signer)) revert InvalidSignature();
        
        // Create listing
        listings[tokenId] = Listing({
            seller: msg.sender,
            tokenId: tokenId,
            price: price,
            isAuction: isAuction,
            isFractional: false,
            fractions: 0,
            expiry: expiry > 0 ? expiry : type(uint256).max,
            active: true,
            paymentToken: paymentToken
        });
        
        // Transfer NFT to marketplace
        nftContract.safeTransferFrom(msg.sender, address(this), tokenId);
        
        // Setup auction if applicable
        if (isAuction) {
            bids[tokenId] = Bid({
                highestBidder: address(0),
                highestBid: 0,
                bidEndTime: expiry,
                paymentToken: paymentToken
            });
        }
        
        // Track the token in its collection
        address collection = address(nftContract);
        if (!activeCollections.contains(collection)) {
            activeCollections.add(collection);
            unchecked {
                metrics.totalCollections += 1;
            }
        }
        collectionTokenIds[collection].add(tokenId);
        
        // Update metrics
        unchecked {
            metrics.activeListings += 1;
        }
        
        emit NFTListed(tokenId, msg.sender, price, isAuction, expiry, paymentToken);
    }

    /**
     * @notice Buy a listed NFT
     * @param tokenId The ID of the NFT to buy
     */
    function buyNFT(uint256 tokenId) external whenNotPaused nonReentrant {
        Listing memory listing = listings[tokenId];
        if (!listing.active) revert ListingNotActive();
        if (listing.isAuction) revert InvalidOffer();
        if (listing.expiry < block.timestamp) revert ListingNotActive();
        
        uint256 price = listing.price;
        address paymentToken = listing.paymentToken;
        address seller = listing.seller;
        
        // Handle payment
        if (paymentToken == address(tStakeToken)) {
            if (tStakeToken.balanceOf(msg.sender) < price) revert InsufficientFunds();
            
            // Transfer tokens from buyer to marketplace
            tStakeToken.transferFrom(msg.sender, address(this), price);
            
            // Process fees and royalties
            _processFees(price, tokenId, paymentToken);
        } else {
            IERC20Upgradeable token = IERC20Upgradeable(paymentToken);
            if (token.balanceOf(msg.sender) < price) revert InsufficientFunds();
            
            // Transfer tokens from buyer to marketplace
            token.transferFrom(msg.sender, address(this), price);
            
            // Process fees and royalties
            _processFees(price, tokenId, paymentToken);
        }
        
        // Update listing state
        listings[tokenId].active = false;
        
        // Transfer NFT to buyer
        nftContract.safeTransferFrom(address(this), msg.sender, tokenId);
        
        // Update token history
        _updateTokenHistory(tokenId, price, msg.sender);
        
        // Update collection stats
        address collection = address(nftContract);
        Collection storage collectionData = collections[collection];
        collectionData.totalVolume += price;
        collectionData.totalSales += 1;
        
        // Update floor price if necessary
        if (collectionData.floorPrice == 0 || price < collectionData.floorPrice) {
            collectionData.floorPrice = price;
            emit FloorPriceUpdated(collection, price);
        }
        
        // Track volume metrics
        unchecked {
            metrics.totalVolume += price;
            metrics.activeListings -= 1;
        }
        
        emit NFTPurchased(tokenId, msg.sender, price, paymentToken);
    }

    /**
     * @notice Place a bid on an auction
     * @param tokenId The ID of the NFT to bid on
     * @param bidAmount The bid amount
     */
    function placeBid(uint256 tokenId, uint256 bidAmount) external whenNotPaused nonReentrant {
        Listing memory listing = listings[tokenId];
        if (!listing.active) revert ListingNotActive();
        if (!listing.isAuction) revert InvalidOffer();
        if (listing.expiry < block.timestamp) revert AuctionEnded();
        if (listing.seller == msg.sender) revert CannotBidOwnItem();
        
        Bid storage existingBid = bids[tokenId];
        uint256 minBidAmount = listing.price;
        
        // Calculate minimum bid
        if (existingBid.highestBid > 0) {
            minBidAmount = existingBid.highestBid + ((existingBid.highestBid * MIN_BID_INCREMENT_PERCENT) / 100);
        }
        
        if (bidAmount < minBidAmount) revert InvalidOffer();
        if (msg.sender == existingBid.highestBidder) revert AlreadyHighestBidder();
        
        IERC20Upgradeable paymentToken = IERC20Upgradeable(listing.paymentToken);
        if (paymentToken.balanceOf(msg.sender) < bidAmount) revert InsufficientFunds();
        
        // Return previous bid if there was one
        if (existingBid.highestBidder != address(0)) {
            pendingReturns[existingBid.highestBidder] += existingBid.highestBid;
        }
        
        // Transfer new bid amount
        paymentToken.transferFrom(msg.sender, address(this), bidAmount);
        
        // Update bid information
        existingBid.highestBidder = msg.sender;
        existingBid.highestBid = bidAmount;
        
        // Check if auction should be extended
        if (listing.expiry - block.timestamp < auctionExtensionThreshold) {
            bids[tokenId].bidEndTime = listing.expiry + auctionExtensionTime;
            listings[tokenId].expiry = listing.expiry + auctionExtensionTime;
            
            emit AuctionExtended(tokenId, listing.expiry + auctionExtensionTime);
        }
        
        emit NFTBidPlaced(tokenId, msg.sender, bidAmount, listing.paymentToken);
    }

    /**
     * @notice Finalize an auction after it has ended
     * @param tokenId The ID of the NFT auction to finalize
     */
    function finalizeAuction(uint256 tokenId) external nonReentrant {
        Listing memory listing = listings[tokenId];
        if (!listing.active) revert ListingNotActive();
        if (!listing.isAuction) revert InvalidOffer();
        if (listing.expiry > block.timestamp) revert InvalidOffer();
        
        Bid memory highestBid = bids[tokenId];
        if (highestBid.highestBidder == address(0)) {
            // No bids, return to seller
            listings[tokenId].active = false;
            nftContract.safeTransferFrom(address(this), listing.
            seller, tokenId);
            
            emit ListingCancelled(tokenId, listing.seller);
            return;
        }
        
        // Process payment
        _processFees(highestBid.highestBid, tokenId, listing.paymentToken);
        
        // Mark listing as inactive
        listings[tokenId].active = false;
        
        // Transfer NFT to highest bidder
        nftContract.safeTransferFrom(address(this), highestBid.highestBidder, tokenId);
        
        // Update token history
        _updateTokenHistory(tokenId, highestBid.highestBid, highestBid.highestBidder);
        
        // Update collection stats
        address collection = address(nftContract);
        Collection storage collectionData = collections[collection];
        collectionData.totalVolume += highestBid.highestBid;
        collectionData.totalSales += 1;
        
        // Update marketplace metrics
        unchecked {
            metrics.totalVolume += highestBid.highestBid;
            metrics.activeListings -= 1;
        }
        
        emit NFTAuctionFinalized(tokenId, highestBid.highestBidder, highestBid.highestBid, listing.paymentToken);
    }

    /**
     * @notice Update a listing's price or expiry
     * @param tokenId The ID of the NFT listing to update
     * @param newPrice The new listing price
     * @param newExpiry The new expiry time
     */
    function updateListing(
        uint256 tokenId,
        uint256 newPrice,
        uint256 newExpiry
    ) external whenNotPaused onlyListingOwner(tokenId) {
        Listing storage listing = listings[tokenId];
        if (!listing.active) revert ListingNotActive();
        if (listing.isAuction && bids[tokenId].highestBid > 0) revert InvalidOffer();
        if (newPrice == 0) revert InvalidPrice();
        if (newExpiry > 0 && newExpiry <= block.timestamp) revert InvalidExpiration();
        
        if (newPrice > 0) {
            listing.price = newPrice;
        }
        
        if (newExpiry > 0) {
            listing.expiry = newExpiry;
            if (listing.isAuction) {
                bids[tokenId].bidEndTime = newExpiry;
            }
        }
        
        emit ListingUpdated(tokenId, newPrice, newExpiry);
    }

    /**
     * @notice Cancel a listing and return the NFT to the seller
     * @param tokenId The ID of the NFT listing to cancel
     */
    function cancelListing(uint256 tokenId) external nonReentrant onlyListingOwner(tokenId) {
        Listing storage listing = listings[tokenId];
        if (!listing.active) revert ListingNotActive();
        
        // If auction with bids, apply cancellation fee
        if (listing.isAuction && bids[tokenId].highestBid > 0) {
            // Cannot cancel an auction with bids
            revert InvalidOffer();
        }
        
        listing.active = false;
        
        // Return NFT to seller
        nftContract.safeTransferFrom(address(this), listing.seller, tokenId);
        
        // Update metrics
        unchecked {
            metrics.activeListings -= 1;
        }
        
        emit ListingCancelled(tokenId, listing.seller);
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
        
        // Create fractionalization parameters
        IFractionToken.FractionParams memory params = IFractionToken.FractionParams({
            tokenId: tokenId,
            fractionSupply: fractionSupply,
            initialPrice: 0, // Default initial price
            name: string(abi.encodePacked("Fractional NFT #", tokenId)),
            symbol: "FNFT",
            lockPeriod: lockTime
        });
        
        // Call the fractionalization contract with new interface
        address fractionToken = fractionContract.fractionalize(params);
        
        // Store fraction token address for this NFT
        fractionalTokens[tokenId] = fractionToken;
        
        // Update metrics
        unchecked {
            metrics.fractionalizedAssets += 1;
        }
        
        emit NFTFractionalized(tokenId, fractionToken);
    }

    /**
     * @notice Create an offer for a specific NFT
     * @param tokenId The ID of the NFT to make an offer on
     * @param offerAmount The amount offered
     * @param expiry The expiry time for the offer
     * @param paymentToken The token address to use for payment
     */
    function createOffer(
        uint256 tokenId,
        uint256 offerAmount,
        uint256 expiry,
        address paymentToken
    ) external whenNotPaused nonReentrant {
        if (offerAmount == 0) revert InvalidOffer();
        if (expiry <= block.timestamp) revert InvalidExpiration();
        if (!supportedPaymentTokens.contains(paymentToken)) revert UnsupportedPaymentToken();
        
        // Ensure the NFT exists
        try nftContract.ownerOf(tokenId) returns (address owner) {
            if (owner == msg.sender) revert CannotBidOwnItem();
        } catch {
            revert InvalidOffer();
        }
        
        // Check if user has enough tokens
        IERC20Upgradeable token = IERC20Upgradeable(paymentToken);
        if (token.balanceOf(msg.sender) < offerAmount) revert InsufficientFunds();
        
        // Create offer
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
     * @notice Cancel an offer made by the caller
     * @param tokenId The ID of the NFT the offer was made on
     */
    function cancelOffer(uint256 tokenId) external nonReentrant {
        Offer storage offer = offers[tokenId][msg.sender];
        if (!offer.active) revert InvalidOffer();
        
        offer.active = false;
        
        // Update metrics
        unchecked {
            metrics.totalOffers -= 1;
        }
        
        emit OfferCancelled(tokenId, msg.sender);
    }

    /**
     * @notice Accept an offer for an NFT
     * @param tokenId The ID of the NFT
     * @param offerer The address of the user who made the offer
     */
    function acceptOffer(uint256 tokenId, address offerer) external nonReentrant {
        Offer memory offer = offers[tokenId][offerer];
        if (!offer.active) revert InvalidOffer();
        if (offer.expiry < block.timestamp) revert OfferExpired();
        
        // Check if caller is token owner or listed seller
        bool isListed = false;
        address nftOwner;
        
        try nftContract.ownerOf(tokenId) returns (address owner) {
            nftOwner = owner;
        } catch {
            revert InvalidOffer();
        }
        
        // If the NFT is listed in the marketplace, check if caller is the seller
        if (listings[tokenId].active) {
            isListed = true;
            if (msg.sender != listings[tokenId].seller) revert NotOwner();
        } else {
            // If not listed, check if caller is the NFT owner
            if (msg.sender != nftOwner) revert NotOwner();
        }
        
        // Mark offer as inactive
        offers[tokenId][offerer].active = false;
        
        // Process payment
        IERC20Upgradeable token = IERC20Upgradeable(offer.paymentToken);
        
        // Check if offerer still has enough balance
        if (token.balanceOf(offerer) < offer.offerAmount) revert InsufficientFunds();
        
        // Transfer tokens from offerer to marketplace
        token.transferFrom(offerer, address(this), offer.offerAmount);
        
        // Process fees and royalties
        _processFees(offer.offerAmount, tokenId, offer.paymentToken);
        
        // If the NFT is listed, handle accordingly
        if (isListed) {
            Listing storage listing = listings[tokenId];
            listing.active = false;
            
            // Transfer NFT to offerer
            nftContract.safeTransferFrom(address(this), offerer, tokenId);
            
            // Update metrics
            unchecked {
                metrics.activeListings -= 1;
            }
        } else {
            // If not listed, transfer directly from owner
            address approvedAddress = nftContract.getApproved(tokenId);
            bool isApprovedForAll = nftContract.isApprovedForAll(nftOwner, address(this));
            
            if (approvedAddress != address(this) && !isApprovedForAll) revert TokenNotApproved();
            
            // Transfer NFT from owner to offerer
            nftContract.safeTransferFrom(nftOwner, offerer, tokenId);
        }
        
        // Update token history
        _updateTokenHistory(tokenId, offer.offerAmount, offerer);
        
        // Update collection stats
        address collection = address(nftContract);
        Collection storage collectionData = collections[collection];
        collectionData.totalVolume += offer.offerAmount;
        collectionData.totalSales += 1;
        
        // Track volume metrics
        unchecked {
            metrics.totalVolume += offer.offerAmount;
            metrics.totalOffers -= 1;
        }
        
        emit OfferAccepted(tokenId, offerer, msg.sender, offer.offerAmount);
    }

    /**
     * @notice Withdraw funds due to the user
     */
    function withdrawFunds() external nonReentrant {
        uint256 amount = pendingReturns[msg.sender];
        if (amount == 0) revert InsufficientFunds();
        
        pendingReturns[msg.sender] = 0;
        
        // Transfer funds to user
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");
        
        emit FundsWithdrawn(msg.sender, amount);
    }

    /**
     * @notice Process batch operations for efficiency
     * @param tokenIds Array of token IDs to process
     * @param operationType Type of batch operation to perform
     */
    function processBatchOperation(
        uint256[] calldata tokenIds,
        string calldata operationType
    ) external onlyOperator {
        bytes32 opType = keccak256(abi.encodePacked(operationType));
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            
            // Different batch operations
            if (opType == keccak256(abi.encodePacked("cancelExpired"))) {
                Listing memory listing = listings[tokenId];
                if (listing.active && listing.expiry < block.timestamp) {
                    listings[tokenId].active = false;
                    
                    // Return NFT to seller
                    nftContract.safeTransferFrom(address(this), listing.seller, tokenId);
                    
                    // Update metrics
                    unchecked {
                        metrics.activeListings -= 1;
                    }
                    
                    emit ListingCancelled(tokenId, listing.seller);
                }
            } else if (opType == keccak256(abi.encodePacked("finalizeAuctions"))) {
                Listing memory listing = listings[tokenId];
                if (listing.active && listing.isAuction && listing.expiry < block.timestamp) {
                    Bid memory highestBid = bids[tokenId];
                    
                    if (highestBid.highestBidder == address(0)) {
                        // No bids, return to seller
                        listings[tokenId].active = false;
                        nftContract.safeTransferFrom(address(this), listing.seller, tokenId);
                        
                        emit ListingCancelled(tokenId, listing.seller);
                    } else {
                        // Process payment
                        _processFees(highestBid.highestBid, tokenId, listing.paymentToken);
                        
                        // Mark listing as inactive
                        listings[tokenId].active = false;
                        
                        // Transfer NFT to highest bidder
                        nftContract.safeTransferFrom(address(this), highestBid.highestBidder, tokenId);
                        
                        // Update token history
                        _updateTokenHistory(tokenId, highestBid.highestBid, highestBid.highestBidder);
                        
                        // Update collection stats
                        address collection = address(nftContract);
                        Collection storage collectionData = collections[collection];
                        collectionData.totalVolume += highestBid.highestBid;
                        collectionData.totalSales += 1;
                        
                        // Update marketplace metrics
                        unchecked {
                            metrics.totalVolume += highestBid.highestBid;
                            metrics.activeListings -= 1;
                        }
                        
                        emit NFTAuctionFinalized(tokenId, highestBid.highestBidder, highestBid.highestBid, listing.paymentToken);
                    }
                }
            }
        }
        
        emit BatchOperationProcessed(msg.sender, tokenIds.length, operationType);
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
        if (_fractionContract != address(0)) fractionContract = IFractionToken(_fractionContract);
        
        emit ContractsUpdated(_nftContract, _fractionContract);
    }

    /**
     * @notice Pause the marketplace
     */
    function pause() external onlyGovernance {
        _pause();
    }

    /**
     * @notice Unpause the marketplace
     */
    function unpause() external onlyGovernance {
        _unpause();
    }

    /**
     * @notice Process fees and distribute payments
     * @param amount Total amount to process
     * @param tokenId NFT token ID for royalty calculations
     * @param paymentToken The token address used for payment
     */
    function _processFees(uint256 amount, uint256 tokenId, address paymentToken) internal {
        IERC20Upgradeable token = IERC20Upgradeable(paymentToken);
        
        // Calculate royalty
        uint256 royaltyAmount = 0;
        address royaltyReceiver = address(0);
        
        // First check NFT's ERC2981 royalty info
        try nftContract.royaltyInfo(tokenId, amount) returns (address receiver, uint256 royalty) {
            if (receiver != address(0) && royalty > 0 && royalty <= (amount * MAX_ROYALTY_PERCENTAGE) / BASIS_POINTS) {
                royaltyAmount = royalty;
                royaltyReceiver = receiver;
            }
        } catch {}
        
        // If no ERC2981 royalty, check collection settings
        if (royaltyAmount == 0) {
            address collection = address(nftContract);
            Collection memory collectionData = collections[collection];
            
            if (collectionData.customRoyalty && collectionData.royaltyPercentage > 0) {
                royaltyAmount = (amount * collectionData.royaltyPercentage) / BASIS_POINTS;
                royaltyReceiver = collectionData.royaltyReceiver;
            }
        }
        
        // Pay royalties if applicable
        if (royaltyAmount > 0 && royaltyReceiver != address(0)) {
            token.transfer(royaltyReceiver, royaltyAmount);
            emit RoyaltyPaid(tokenId, royaltyReceiver, royaltyAmount);
        }
        
        // Calculate remaining amount after royalties
        uint256 remainingAmount = amount - royaltyAmount;
        
        // Calculate platform fees
        uint256 stakingAmount = (remainingAmount * stakingFeePercent) / BASIS_POINTS;
        uint256 liquidityAmount = (remainingAmount * liquidityFeePercent) / BASIS_POINTS;
        uint256 treasuryAmount = (remainingAmount * treasuryFeePercent) / BASIS_POINTS;
        uint256 burnAmount = (remainingAmount * burnFeePercent) / BASIS_POINTS;
        
        // Calculate seller amount
        uint256 totalFees = stakingAmount + liquidityAmount + treasuryAmount + burnAmount;
        uint256 sellerAmount = remainingAmount - totalFees;
        
        // Distribute fees
        if (stakingAmount > 0) {
            token.transfer(stakingPool, stakingAmount);
        }
        
        if (liquidityAmount > 0) {
            token.transfer(liquidityPool, liquidityAmount);
        }
        
        if (treasuryAmount > 0) {
            token.transfer(treasury, treasuryAmount);
        }
        
        // Handle token burning if it's the platform token
        if (burnAmount > 0 && paymentToken == address(tStakeToken)) {
            tStakeToken.burn(address(this), burnAmount);
        } else if (burnAmount > 0) {
            // If not platform token, send to treasury instead of burning
            token.transfer(treasury, burnAmount);
        }
        
        // Pay seller
        Listing memory listing = listings[tokenId];
        token.transfer(listing.seller, sellerAmount);
        
        emit FeesDistributed(stakingAmount, liquidityAmount, treasuryAmount, burnAmount);
    }

    /**
     * @notice Update token sales history
     * @param tokenId Token ID to update
     * @param price Sale price
     * @param buyer Buyer address
     */
    function _updateTokenHistory(uint256 tokenId, uint256 price, address buyer) internal {
        TokenHistory storage history = tokenHistory[tokenId];
        
        // Record this sale
        history.lastSoldPrice = price;
        history.lastSoldTo = buyer;
        history.lastSoldTime = block.timestamp;
        
        // Update highest ever price if applicable
        if (price > history.highestEverPrice) {
            history.highestEverPrice = price;
        }
        
        // Update price history arrays
        history.priceHistory.push(price);
        history.timestampHistory.push(block.timestamp);
    }

    /**
     * @notice Domain separator for EIP-712
     */
    function _domainSeparatorV4() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("TerraStakeMarketplace")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    /**
     * @notice Hash a structured data payload
     * @param structHash The hash of the struct data
     */
    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        return ECDSAUpgradeable.toTypedDataHash(_domainSeparatorV4(), structHash);
    }

    /**
     * @notice Check if a token is supported for payment
     * @param token The token address to check
     */
    function isPaymentTokenSupported(address token) external view returns (bool) {
        return supportedPaymentTokens.contains(token);
    }

    /**
     * @notice Get all supported payment tokens
     */
    function getSupportedPaymentTokens() external view returns (address[] memory) {
        uint256 length = supportedPaymentTokens.length();
        address[] memory tokens = new address[](length);
        
        for (uint256 i = 0; i < length; i++) {
            tokens[i] = supportedPaymentTokens.at(i);
        }
        
        return tokens;
    }

    /**
     * @notice Get all active collections
     */
    function getActiveCollections() external view returns (address[] memory) {
        uint256 length = activeCollections.length();
        address[] memory collections = new address[](length);
        
        for (uint256 i = 0; i < length; i++) {
            collections[i] = activeCollections.at(i);
        }
        
        return collections;
    }

    /**
     * @notice Get all token IDs in a collection
     * @param collection The collection address
     */
    function getCollectionTokenIds(address collection) external view returns (uint256[] memory) {
        uint256 length = collectionTokenIds[collection].length();
        uint256[] memory tokens = new uint256[](length);
        
        for (uint256 i = 0; i < length; i++) {
            tokens[i] = collectionTokenIds[collection].at(i);
        }
        
        return tokens;
    }

    /**
     * @notice Get token price history
     * @param tokenId The token ID to get history for
     */
    function getTokenPriceHistory(uint256 tokenId) external view returns (
        uint256[] memory prices,
        uint256[] memory timestamps
    ) {
        TokenHistory storage history = tokenHistory[tokenId];
        return (history.priceHistory, history.timestampHistory);
    }

    // Function to receive ETH if needed
    receive() external payable {}
}
