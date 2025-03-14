// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "../interfaces/IFractionToken.sol";
import "../interfaces/ITerraStakeProjects.sol";
import "../interfaces/ITerraStakeMetadataRenderer.sol";
import "../interfaces/ITerraStakeNFT.sol";
import "../interfaces/ITerraStakeGovernance.sol";
import "../interfaces/ITerraStakeStaking.sol";

// Custom errors
error NotAuthorized();
error NotOwner();
error InvalidPrice();
error ListingNotActive();
error AuctionEnded();
error AuctionNotEnded();
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
error NotAnAuction();
error BidTooLow();
error AuctionHasBids();
error NotFractional();
error InvalidFractionalParams();
error InsufficientFractions();
error ListingActive();

/// @title TerraStake Marketplace
/// @notice Optimized NFT marketplace with fractionalization, bidding, and analytics
contract TerraStakeMarketplace is
    Initializable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    ERC721HolderUpgradeable
{
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    // Constants
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

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
    ITerraStakeFractionManager public fractionContract;
    ITerraStakeMetadataRenderer public metadataContract;
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
    EnumerableSet.AddressSet private supportedPaymentTokens;

    // Collection tracking
    EnumerableSet.AddressSet private activeCollections;
    mapping(address => EnumerableSet.UintSet) private collectionTokenIds;

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

    struct PlatformMetrics {
        uint256 totalVolume;
        uint256 activeListings;
        uint256 fractionalizedAssets;
        uint256 totalOffers;
        uint256 totalCollections;
        uint256 totalSales;
        uint256 totalValueLocked;
        uint256 lastUpdateBlock;
    }

    mapping(uint256 => Listing) public listings;
    mapping(uint256 => Bid) public bids;
    mapping(address => uint256) public pendingReturns;
    mapping(uint256 => mapping(address => Offer)) public offers;
    mapping(uint256 => TokenHistory) public tokenHistory;
    mapping(uint256 => address) public fractionalTokens;
    PlatformMetrics public metrics;

    // Events
    event NFTListed(uint256 indexed tokenId, address indexed seller, uint256 price, bool isAuction, uint256 expiry, address paymentToken);
    event NFTPurchased(uint256 indexed tokenId, address indexed buyer, address indexed seller, uint256 price, address paymentToken);
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
    event AuctionCancelled(uint256 indexed tokenId, address indexed seller);
    event BidPlaced(uint256 indexed tokenId, address indexed bidder, uint256 amount, uint256 endTime);
    event AuctionFinalized(uint256 indexed tokenId, address indexed winner, address indexed seller, uint256 finalPrice, address paymentToken);
    event FractionsPurchased(uint256 indexed tokenId, address indexed buyer, address indexed seller, uint256 fractionCount, uint256 totalPrice, address paymentToken);
    event NFTRedeemed(uint256 indexed tokenId, address indexed redeemer);
    event FeesProcessed(
        uint256 indexed tokenId,
        uint256 stakingFee,
        uint256 liquidityFee,
        uint256 treasuryFee,
        uint256 burnFee,
        uint256 royaltyAmount,
        address royaltyReceiver,
        uint256 sellerProceeds
    );
    event MetricsUpdated(
        uint256 totalCollections,
        uint256 activeListings,
        uint256 totalSales,
        uint256 totalVolume,
        uint256 totalValueLocked
    );
    event EmergencyWithdraw(address token, address to, uint256 amount);
    event NFTRecovered(uint256 tokenId, address to);
    event NFTListedFractional(uint256 indexed tokenId, address indexed seller, uint256 fractionCount, uint256 pricePerFraction, address paymentToken);

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
        fractionContract = ITerraStakeFractionManager(_fractionContract);
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
        // try metadataContract.indexCollection(collection) {} catch {}
        
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
        if (_metadataContract != address(0)) metadataContract = ITerraStakeMetadataRenderer(_metadataContract);
        
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
        if (nftContract.balanceOf(msg.sender, tokenId) == 0) revert NotOwner();
        if (price == 0) revert InvalidPrice();
        if (expiry > 0 && expiry <= block.timestamp) revert InvalidExpiration();
        if (!supportedPaymentTokens.contains(paymentToken)) revert UnsupportedPaymentToken();
        
        // Check token approval
        bool isApprovedForAll = nftContract.isApprovedForAll(msg.sender, address(this));
        if (!isApprovedForAll) revert TokenNotApproved();
        
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
        nftContract.safeTransferFrom(msg.sender, address(this), tokenId, 1, "");
        
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
        if (nftContract.balanceOf(msg.sender, tokenId) == 0) revert NotOwner();
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
        
        address signer = ECDSA.recover(digest, signature);
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
        nftContract.safeTransferFrom(msg.sender, address(this), tokenId, 1, "");
        
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
            IERC20 token = IERC20(paymentToken);
            if (token.balanceOf(msg.sender) < price) revert InsufficientFunds();
            
            // Transfer tokens from buyer to marketplace
            token.transferFrom(msg.sender, address(this), price);
            
            // Process fees and royalties
            _processFees(price, tokenId, paymentToken);
        }
        
        // Update listing and transfer NFT
        listings[tokenId].active = false;
        nftContract.safeTransferFrom(address(this), msg.sender, tokenId, 1, "");
        
        // Update metrics
        unchecked {
            metrics.activeListings -= 1;
            metrics.totalVolume += price;
            metrics.totalSales += 1;
            
            address collection = address(nftContract);
            collections[collection].totalVolume += price;
            collections[collection].totalSales += 1;
            
            // Update floor price if needed
            if (collections[collection].floorPrice == 0 || price < collections[collection].floorPrice) {
                collections[collection].floorPrice = price;
            }
        }
        
        emit NFTPurchased(tokenId, msg.sender, seller, price, paymentToken);
    }

    /**
     * @notice Place a bid on an NFT auction
     * @param tokenId The ID of the NFT to bid on
     * @param amount The bid amount
     */
    function placeBid(uint256 tokenId, uint256 amount) external whenNotPaused nonReentrant {
        Listing memory listing = listings[tokenId];
        if (!listing.active) revert ListingNotActive();
        if (!listing.isAuction) revert NotAnAuction();
        
        Bid storage currentBid = bids[tokenId];
        if (currentBid.bidEndTime < block.timestamp) revert AuctionEnded();
        
        // Check if bid is high enough
        uint256 minBid = currentBid.highestBid > 0 
            ? currentBid.highestBid + (currentBid.highestBid * 5 / 100) // 5% higher than current bid
            : listing.price;
            
        if (amount < minBid) revert BidTooLow();
        
        address paymentToken = listing.paymentToken;
        
        // Process payment token
        if (paymentToken == address(tStakeToken)) {
            if (tStakeToken.balanceOf(msg.sender) < amount) revert InsufficientFunds();
            
            // Transfer tokens from bidder to marketplace
            tStakeToken.transferFrom(msg.sender, address(this), amount);
        } else {
            IERC20 token = IERC20(paymentToken);
            if (token.balanceOf(msg.sender) < amount) revert InsufficientFunds();
            
            // Transfer tokens from bidder to marketplace
            token.transferFrom(msg.sender, address(this), amount);
        }
        
        // Refund previous highest bidder
        if (currentBid.highestBidder != address(0)) {
            if (paymentToken == address(tStakeToken)) {
                tStakeToken.transfer(currentBid.highestBidder, currentBid.highestBid);
            } else {
                IERC20 token = IERC20(paymentToken);
                token.transfer(currentBid.highestBidder, currentBid.highestBid);
            }
        }
        
        // Update bid information
        currentBid.highestBidder = msg.sender;
        currentBid.highestBid = amount;
        
        // Check if we need to extend the auction
        // Check if auction should be extended based on time threshold
        if (currentBid.bidEndTime - block.timestamp < auctionExtensionThreshold) {
            currentBid.bidEndTime += auctionExtensionTime;
            emit AuctionExtended(tokenId, currentBid.bidEndTime);
        }
        
        emit NFTBidPlaced(tokenId, msg.sender, amount, paymentToken);
    }

    /**
     * @notice Finalize an auction
     * @param tokenId The ID of the NFT auction to finalize
     */
    function finalizeAuction(uint256 tokenId) external whenNotPaused nonReentrant {
        Listing memory listing = listings[tokenId];
        if (!listing.active) revert ListingNotActive();
        if (!listing.isAuction) revert NotAnAuction();
        
        Bid memory currentBid = bids[tokenId];
        if (currentBid.bidEndTime >= block.timestamp) revert AuctionNotEnded();
        
        address seller = listing.seller;
        address winner = currentBid.highestBidder;
        uint256 finalPrice = currentBid.highestBid;
        address paymentToken = listing.paymentToken;
        
        // If no bids, return to seller
        if (winner == address(0)) {
            listings[tokenId].active = false;
            nftContract.safeTransferFrom(address(this), seller, tokenId, 1, "");
            emit AuctionCancelled(tokenId, seller);
            
            // Update metrics
            unchecked {
                metrics.activeListings -= 1;
            }
            return;
        }
        
        // Process fees and royalties
        _processFees(finalPrice, tokenId, paymentToken);
        
        // Mark listing as inactive and transfer NFT to winner
        listings[tokenId].active = false;
        nftContract.safeTransferFrom(address(this), winner, tokenId, 1, "");
        
        // Update metrics
        unchecked {
            metrics.activeListings -= 1;
            metrics.totalVolume += finalPrice;
            metrics.totalSales += 1;
            
            address collection = address(nftContract);
            collections[collection].totalVolume += finalPrice;
            collections[collection].totalSales += 1;
        }
        
        emit AuctionFinalized(tokenId, winner, seller, finalPrice, paymentToken);
    }

    /**
     * @notice Cancel a listing
     * @param tokenId The ID of the NFT listing to cancel
     */
    function cancelListing(uint256 tokenId) external nonReentrant onlyListingOwner(tokenId) {
        Listing memory listing = listings[tokenId];
        if (!listing.active) revert ListingNotActive();
        
        // If it's an auction with bids, we can't cancel
        if (listing.isAuction && bids[tokenId].highestBidder != address(0)) {
            revert AuctionHasBids();
        }
        
        // Mark as inactive and return NFT to seller
        listings[tokenId].active = false;
        nftContract.safeTransferFrom(address(this), msg.sender, tokenId, 1, "");
        
        // Update metrics
        unchecked {
            metrics.activeListings -= 1;
        }
        
        emit ListingCancelled(tokenId, msg.sender);
    }

    /**
     * @notice Update a listing's price and expiry
     * @param tokenId The ID of the NFT listing to update
     * @param newPrice The new price for the listing
     * @param newExpiry The new expiry for the listing
     */
    function updateListing(
        uint256 tokenId,
        uint256 newPrice,
        uint256 newExpiry
    ) external nonReentrant onlyListingOwner(tokenId) {
        Listing storage listing = listings[tokenId];
        if (!listing.active) revert ListingNotActive();
        if (newPrice == 0) revert InvalidPrice();
        if (newExpiry != 0 && newExpiry <= block.timestamp) revert InvalidExpiration();
        
        // If it's an auction with bids, we can't update
        if (listing.isAuction && bids[tokenId].highestBidder != address(0)) {
            revert AuctionHasBids();
        }
        
        // Update price and expiry
        listing.price = newPrice;
        if (newExpiry > 0) {
            listing.expiry = newExpiry;
            if (listing.isAuction) {
                bids[tokenId].bidEndTime = newExpiry;
            }
        }
        
        emit ListingUpdated(tokenId, newPrice, listing.expiry);
    }

    /**
     * @notice Create or update an offer for an NFT
     * @param tokenId The ID of the NFT to make an offer for
     * @param offerAmount The amount to offer
     * @param expiry The expiration time for the offer
     * @param paymentToken The payment token to use for the offer
     */
    function makeOffer(
        uint256 tokenId,
        uint256 offerAmount,
        uint256 expiry,
        address paymentToken
    ) external whenNotPaused nonReentrant {
        if (offerAmount == 0) revert InvalidOffer();
        if (expiry <= block.timestamp) revert InvalidExpiration();
        if (!supportedPaymentTokens.contains(paymentToken)) revert UnsupportedPaymentToken();
        
        // Make sure NFT exists
        if (nftContract.balanceOf(msg.sender, tokenId) > 0) revert CannotBidOwnItem();
        
        // Process payment token
        if (paymentToken == address(tStakeToken)) {
            if (tStakeToken.balanceOf(msg.sender) < offerAmount) revert InsufficientFunds();
            
            // We don't transfer tokens now, we'll check approval and balance when offer is accepted
        } else {
            IERC20 token = IERC20(paymentToken);
            if (token.balanceOf(msg.sender) < offerAmount) revert InsufficientFunds();
            
            // We don't transfer tokens now, we'll check approval and balance when offer is accepted
        }
        
        // Create or update offer
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
     * @notice Cancel an offer
     * @param tokenId The ID of the NFT offer to cancel
     */
    function cancelOffer(uint256 tokenId) external nonReentrant {
        Offer storage offer = offers[tokenId][msg.sender];
        if (!offer.active) revert InvalidOffer();
        offer.active = false;
        
        emit OfferCancelled(tokenId, msg.sender);
    }

    /**
     * @notice Accept an offer for an NFT
     * @param tokenId The ID of the NFT
     * @param offerAddress The address of the offerer
     */
    function acceptOffer(uint256 tokenId, address offerAddress) external whenNotPaused nonReentrant {
        // Check if caller is NFT owner
        if (nftContract.balanceOf(msg.sender, tokenId) == 0) revert NotOwner();
        
        Offer memory offer = offers[tokenId][offerAddress];
        if (!offer.active) revert InvalidOffer();
        if (offer.expiry < block.timestamp) revert OfferExpired();
        
        uint256 offerAmount = offer.offerAmount;
        address paymentToken = offer.paymentToken;
        
        // Mark offer as inactive
        offers[tokenId][offerAddress].active = false;
        
        // Process payment
        if (paymentToken == address(tStakeToken)) {
            if (tStakeToken.balanceOf(offerAddress) < offerAmount) revert InsufficientFunds();
            if (tStakeToken.allowance(offerAddress, address(this)) < offerAmount) revert TokenNotApproved();
            
            // Transfer tokens from offerer to marketplace
            tStakeToken.transferFrom(offerAddress, address(this), offerAmount);
            
            // Process fees and royalties
            _processFees(offerAmount, tokenId, paymentToken);
        } else {
            IERC20 token = IERC20(paymentToken);
            if (token.balanceOf(offerAddress) < offerAmount) revert InsufficientFunds();
            if (token.allowance(offerAddress, address(this)) < offerAmount) revert TokenNotApproved();
            
            // Transfer tokens from offerer to marketplace
            token.transferFrom(offerAddress, address(this), offerAmount);
            
            // Process fees and royalties
            _processFees(offerAmount, tokenId, paymentToken);
        }
        
        // Transfer NFT to the offerer
        nftContract.safeTransferFrom(msg.sender, offerAddress, tokenId, 1, "");
        
        // Update metrics
        unchecked {
            metrics.totalVolume += offerAmount;
            metrics.totalSales += 1;
            
            address collection = address(nftContract);
            collections[collection].totalVolume += offerAmount;
            collections[collection].totalSales += 1;
        }
        
        emit OfferAccepted(tokenId, offerAddress, msg.sender, offerAmount);
    }

    /**
     * @notice Fractionalize an NFT
     * @param tokenId The ID of the NFT to fractionalize
     * @param fractionCount The total number of fractions to create
     * @param pricePerFraction The price per fraction
     * @param expiry The expiration time for the listing
     * @param paymentToken The payment token for fraction sales
     */
    function fractionalizeNFT(
        uint256 tokenId,
        uint256 fractionCount,
        uint256 pricePerFraction,
        uint256 expiry,
        address paymentToken
    ) external whenNotPaused nonReentrant {
        if (nftContract.balanceOf(msg.sender, tokenId) == 0) revert NotOwner();
        if (fractionCount == 0 || pricePerFraction == 0) revert InvalidFractionalParams();
        if (expiry > 0 && expiry <= block.timestamp) revert InvalidExpiration();
        if (!supportedPaymentTokens.contains(paymentToken)) revert UnsupportedPaymentToken();
        
        // Check token approval
        bool isApprovedForAll = nftContract.isApprovedForAll(msg.sender, address(this));
        if (!isApprovedForAll) revert TokenNotApproved();
        
        // Transfer NFT to contract
        nftContract.safeTransferFrom(msg.sender, address(this), tokenId, 1, "");
        
        // Create fraction token
        // string memory nftSymbol = nftContract.symbol();
        string memory nftSymbol = "NFT Symbol";
        // string memory nftName = nftContract.name();
        string memory nftName = "NFT Name";
        string memory fractionSymbol = string(abi.encodePacked("f", nftSymbol, "-", uint2str(tokenId)));
        string memory fractionName = string(abi.encodePacked("Fractional ", nftName, " #", uint2str(tokenId)));
        
        // Deploy new fraction token with special metadata
        // address fractionToken = fractionContract.createFractionToken(
        //     fractionName,
        //     fractionSymbol,
        //     fractionCount,
        //     tokenId,
        //     msg.sender
        // );
        address fractionToken;
        
        // Record fraction token address
        fractionalTokens[tokenId] = fractionToken;
        
        // Create listing for fractions
        listings[tokenId] = Listing({
            seller: msg.sender,
            tokenId: tokenId,
            price: pricePerFraction,
            isAuction: false,
            isFractional: true,
            fractions: fractionCount,
            expiry: expiry > 0 ? expiry : type(uint256).max,
            active: true,
            paymentToken: paymentToken
        });
        
        // Update metrics
        unchecked {
            metrics.activeListings += 1;
            metrics.fractionalizedAssets += 1;
            metrics.totalValueLocked += pricePerFraction * fractionCount;
        }
        
        emit NFTFractionalized(tokenId, fractionToken);
        emit NFTListedFractional(tokenId, msg.sender, fractionCount, pricePerFraction, paymentToken);
    }

    /**
     * @notice Buy fractions of an NFT
     * @param tokenId The ID of the fractionalized NFT
     * @param fractionCount The number of fractions to buy
     */
    function buyFractions(uint256 tokenId, uint256 fractionCount) external whenNotPaused nonReentrant {
        Listing memory listing = listings[tokenId];
        if (!listing.active) revert ListingNotActive();
        if (!listing.isFractional) revert NotFractional();
        if (listing.expiry < block.timestamp) revert ListingNotActive();
        
        // Verify fraction availability
        address fractionToken = fractionalTokens[tokenId];
        if (fractionToken == address(0)) revert NotFractional();
        
        uint256 availableFractions = IFractionToken(fractionToken).balanceOf(listing.seller);
        if (fractionCount > availableFractions) revert InsufficientFractions();
        
        uint256 totalPrice = listing.price * fractionCount;
        address paymentToken = listing.paymentToken;
        address seller = listing.seller;
        
        // Handle payment
        if (paymentToken == address(tStakeToken)) {
            if (tStakeToken.balanceOf(msg.sender) < totalPrice) revert InsufficientFunds();
            
            // Transfer tokens from buyer to marketplace
            tStakeToken.transferFrom(msg.sender, address(this), totalPrice);
            
            // Process fees and royalties
            _processFees(totalPrice, tokenId, paymentToken);
        } else {
            IERC20 token = IERC20(paymentToken);
            if (token.balanceOf(msg.sender) < totalPrice) revert InsufficientFunds();
            
            // Transfer tokens from buyer to marketplace
            token.transferFrom(msg.sender, address(this), totalPrice);
            
            // Process fees and royalties
            _processFees(totalPrice, tokenId, paymentToken);
        }
        
        // Transfer fractions to buyer
        IFractionToken(fractionToken).transferFrom(seller, msg.sender, fractionCount);
        
        // Check if all fractions are sold
        if (IFractionToken(fractionToken).balanceOf(seller) == 0) {
            listings[tokenId].active = false;
            
            // Update metrics
            unchecked {
                metrics.activeListings -= 1;
                metrics.totalValueLocked -= listing.price * listing.fractions;
            }
        }
        
        // Update metrics
        unchecked {
            metrics.totalVolume += totalPrice;
            metrics.totalVolume += totalPrice;
            metrics.totalSales += 1;
            metrics.totalValueLocked -= listing.price * fractionCount;
            
            address collection = address(nftContract);
            collections[collection].totalVolume += totalPrice;
            collections[collection].totalSales += 1;
        }
        
        emit FractionsPurchased(tokenId, msg.sender, seller, fractionCount, totalPrice, paymentToken);
    }

    /**
     * @notice Redeem a fractionalized NFT (requires all fractions)
     * @param tokenId The ID of the fractionalized NFT to redeem
     */
    function redeemFractionalNFT(uint256 tokenId) external nonReentrant {
        address fractionToken = fractionalTokens[tokenId];
        if (fractionToken == address(0)) revert NotFractional();
        
        uint256 totalSupply = IFractionToken(fractionToken).totalSupply();
        uint256 userBalance = IFractionToken(fractionToken).balanceOf(msg.sender);
        
        // Must own all fractions to redeem
        if (userBalance != totalSupply) revert InsufficientFractions();
        
        // Burn all fraction tokens
        IFractionToken(fractionToken).burnAll(msg.sender);
        
        // If there was an active listing, disable it
        if (listings[tokenId].active) {
            listings[tokenId].active = false;
            
            // Update metrics
            unchecked {
                metrics.activeListings -= 1;
                metrics.fractionalizedAssets -= 1;
                metrics.totalValueLocked -= listings[tokenId].price * listings[tokenId].fractions;
            }
        }
        
        // Transfer NFT to redeemer
        nftContract.safeTransferFrom(address(this), msg.sender, tokenId, 1, "");
        
        // Clear fractional token record
        delete fractionalTokens[tokenId];
        
        emit NFTRedeemed(tokenId, msg.sender);
    }

    /**
     * @notice Process fees and royalties for a sale
     * @param amount The total sale amount
     * @param tokenId The NFT token ID
     * @param paymentToken The token address used for payment
     * @return sellerAmount The amount that goes to the seller
     */
    function _processFees(
        uint256 amount,
        uint256 tokenId,
        address paymentToken
    ) internal returns (uint256 sellerAmount) {
        address seller = listings[tokenId].seller;
        address collection = address(nftContract);
        
        // Calculate fees
        uint256 stakingFee = (amount * stakingFeePercent) / BASIS_POINTS;
        uint256 liquidityFee = (amount * liquidityFeePercent) / BASIS_POINTS;
        uint256 treasuryFee = (amount * treasuryFeePercent) / BASIS_POINTS;
        uint256 burnFee = (amount * burnFeePercent) / BASIS_POINTS;
        
        // Calculate royalty
        uint256 royaltyAmount = 0;
        address royaltyReceiver = address(0);
        
        if (collections[collection].customRoyalty) {
            royaltyAmount = (amount * collections[collection].royaltyPercentage) / BASIS_POINTS;
            royaltyReceiver = collections[collection].royaltyReceiver;
        } else {
            // Try to get royalty info from NFT contract if it implements ERC2981
            try nftContract.royaltyInfo(tokenId, amount) returns (address receiver, uint256 royalty) {
                if (receiver != address(0) && royalty > 0 && royalty <= amount * MAX_ROYALTY_PERCENTAGE / BASIS_POINTS) {
                    royaltyAmount = royalty;
                    royaltyReceiver = receiver;
                }
            } catch {}
        }
        
        // Calculate seller amount
        sellerAmount = amount - stakingFee - liquidityFee - treasuryFee - burnFee - royaltyAmount;
        
        // Process payments based on token
        if (paymentToken == address(tStakeToken)) {
            // Transfer fees
            if (stakingFee > 0) tStakeToken.transfer(stakingPool, stakingFee);
            if (liquidityFee > 0) tStakeToken.transfer(liquidityPool, liquidityFee);
            if (treasuryFee > 0) tStakeToken.transfer(treasury, treasuryFee);
            if (burnFee > 0) tStakeToken.transfer(DEAD_ADDRESS, burnFee);
            
            // Transfer royalty if applicable
            if (royaltyAmount > 0 && royaltyReceiver != address(0)) {
                tStakeToken.transfer(royaltyReceiver, royaltyAmount);
                emit RoyaltyPaid(tokenId, royaltyReceiver, royaltyAmount);
            }
            
            // Transfer remaining amount to seller
            tStakeToken.transfer(seller, sellerAmount);
        } else {
            IERC20 token = IERC20(paymentToken);
            
            // Transfer fees
            if (stakingFee > 0) token.transfer(stakingPool, stakingFee);
            if (liquidityFee > 0) token.transfer(liquidityPool, liquidityFee);
            if (treasuryFee > 0) token.transfer(treasury, treasuryFee);
            if (burnFee > 0) token.transfer(DEAD_ADDRESS, burnFee);
            
            // Transfer royalty if applicable
            if (royaltyAmount > 0 && royaltyReceiver != address(0)) {
                token.transfer(royaltyReceiver, royaltyAmount);
                emit RoyaltyPaid(tokenId, royaltyReceiver, royaltyAmount);
            }
            
            // Transfer remaining amount to seller
            token.transfer(seller, sellerAmount);
        }
        
        emit FeesProcessed(
            tokenId,
            stakingFee,
            liquidityFee,
            treasuryFee,
            burnFee,
            royaltyAmount,
            royaltyReceiver,
            sellerAmount
        );
        
        return sellerAmount;
    }

    /**
     * @notice Update platform metrics
     */
    function updateMetrics() external {
        // Only update metrics once per block to prevent manipulation
        if (metrics.lastUpdateBlock == block.number) return;
        
        metrics.lastUpdateBlock = block.number;
        
        // Update metrics snapshot
        emit MetricsUpdated(
            metrics.totalCollections,
            metrics.activeListings,
            metrics.totalSales,
            metrics.totalVolume,
            metrics.totalValueLocked
        );
    }

    /**
     * @notice Emergency withdraw function for tokens
     * @param token The token address to withdraw
     * @param to The recipient address
     * @param amount The amount to withdraw
     */
    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyGovernance {
        if (token == address(0)) {
            payable(to).transfer(amount);
        } else {
            IERC20(token).transfer(to, amount);
        }
        
        emit EmergencyWithdraw(token, to, amount);
    }

    /**
     * @notice Emergency recover NFT function
     * @param tokenId The NFT token ID to recover
     * @param to The recipient address
     */
    function emergencyRecoverNFT(uint256 tokenId, address to) external onlyGovernance {
        nftContract.safeTransferFrom(address(this), to, tokenId, 1, "");
        
        emit NFTRecovered(tokenId, to);
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
     * @notice Helper function to convert uint to string
     * @param _i The uint to convert
     * @return _uintAsString The uint as a string
     */
    function uint2str(uint _i) internal pure returns (string memory _uintAsString) {
        if (_i == 0) {
            return "0";
        }
        uint j = _i;
        uint len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint k = len;
        while (_i != 0) {
            k = k-1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }

    /**
     * @notice Implementation of EIP-712 for typed data hashing
     * @param structHash The hash of the struct data
     * @return The EIP-712 typed data hash
     */
    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("TerraStakeMarketplace")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}