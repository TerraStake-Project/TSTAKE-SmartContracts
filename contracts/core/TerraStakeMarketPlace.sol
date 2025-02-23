// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/ITerraStakeGovernance.sol"; // ✅ Governance Integration
import "./interfaces/IPriceFeed.sol"; // ✅ Live Price Feeds

interface ITerraStakeToken is IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
}

contract TerraStakeMarketplace is 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable, 
    ERC1155Holder, 
    PausableUpgradeable,
    UUPSUpgradeable
{
    // ==========================
    // 🔹 Roles & Constants
    // ==========================
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    uint256 public constant MAX_ROYALTY_FEE = 1000; // 10% max
    uint256 public constant MIN_BID_INCREMENT = 5 * 10**18; // 5 TSTAKE min bid increase
    uint256 public constant MAX_PRICE = 1_000_000 * 10**18;

    uint256 public royaltyFee;
    address public royaltyRecipient;
    ITerraStakeToken public tStakeToken;
    IERC1155 public nftContract;
    IPriceFeed public priceFeed;
    ITerraStakeGovernance public governanceContract;

    uint256 public rewardPool;
    bool public riskMonitoringEnabled;

    enum MarketState { Active, Suspended, Emergency }
    MarketState public currentState;

    struct Listing {
        address seller;
        uint256 tokenId;
        uint256 price;
        uint256 amount;
        bool active;
        uint256 expiry;
        uint256 startPrice;
        uint256 endPrice;
        uint256 priceDecrementInterval;
        bool isAuction;
    }

    struct Bid {
        address highestBidder;
        uint256 highestBid;
        uint256 bidEndTime;
    }

    mapping(uint256 => mapping(address => Listing)) public listings;
    mapping(uint256 => mapping(address => Bid)) public bids;
    mapping(address => uint256[]) public userListings;
    mapping(uint256 => uint256) public marketVolume;

    // ==========================
    // 🔹 Events
    // ==========================
    event NFTListed(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 indexed listingId,
        uint256 amount,
        uint256 price,
        bool isAuction
    );

    event NFTPurchased(
        uint256 indexed tokenId,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        uint256 price
    );

    event NFTBidPlaced(
        uint256 indexed tokenId,
        address indexed bidder,
        uint256 amount
    );

    event NFTBidFinalized(
        uint256 indexed tokenId,
        address indexed winner,
        uint256 winningBid
    );

    event MarketStateChanged(MarketState newState);
    event RoyaltyFeeUpdated(uint256 newRoyalty);
    event RewardPoolReplenished(uint256 amount);

    // ==========================
    // 🔹 Modifiers
    // ==========================
    modifier onlyGovernance() {
        require(hasRole(GOVERNANCE_ROLE, msg.sender), "Caller is not governance");
        _;
    }

    modifier marketActive() {
        require(currentState == MarketState.Active, "Market is not active");
        _;
    }

    // ==========================
    // 🔹 Constructor & Upgradability
    // ==========================
    function initialize(
        address _nftContract,
        address _tStakeToken,
        address _royaltyRecipient,
        address _governanceContract,
        address _priceFeed
    ) external initializer {
        require(_nftContract != address(0), "Invalid NFT contract");
        require(_tStakeToken != address(0), "Invalid TSTAKE token");
        require(_royaltyRecipient != address(0), "Invalid royalty recipient");
        require(_governanceContract != address(0), "Invalid governance contract");
        require(_priceFeed != address(0), "Invalid price feed");

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        nftContract = IERC1155(_nftContract);
        tStakeToken = ITerraStakeToken(_tStakeToken);
        royaltyRecipient = _royaltyRecipient;
        governanceContract = ITerraStakeGovernance(_governanceContract);
        priceFeed = IPriceFeed(_priceFeed);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);

        royaltyFee = 500; // 5%
        riskMonitoringEnabled = true;
        currentState = MarketState.Active;
    }

    function _authorizeUpgrade(address) internal override onlyGovernance {}

    // ==========================
    // 🔹 Listing an NFT (Fixed Price & Auction)
    // ==========================
    function listNFT(
        uint256 tokenId,
        uint256 amount,
        uint256 startPrice,
        uint256 endPrice,
        uint256 priceDecrementInterval,
        uint256 expiry,
        bool isAuction
    ) external marketActive nonReentrant {
        require(amount > 0, "Invalid amount");
        require(startPrice > 0 && startPrice <= MAX_PRICE, "Invalid price");
        require(expiry > block.timestamp + 1 hours, "Expiry too soon");
        require(expiry < block.timestamp + 30 days, "Expiry too far");

        nftContract.safeTransferFrom(msg.sender, address(this), tokenId, amount, "");

        listings[tokenId][msg.sender] = Listing({
            seller: msg.sender,
            tokenId: tokenId,
            price: startPrice,
            amount: amount,
            active: true,
            expiry: expiry,
            startPrice: startPrice,
            endPrice: endPrice,
            priceDecrementInterval: priceDecrementInterval,
            isAuction: isAuction
        });

        emit NFTListed(tokenId, msg.sender, block.timestamp, amount, startPrice, isAuction);
    }

    // ==========================
    // 🔹 Buying an NFT (Buy Now)
    // ==========================
    function buyNow(uint256 tokenId, address seller) external marketActive whenNotPaused {
        Listing storage listing = listings[tokenId][seller];
        require(listing.active, "Not listed");

        uint256 totalPrice = listing.price * listing.amount;
        uint256 royalty = (totalPrice * royaltyFee) / 10000;
        uint256 sellerAmount = totalPrice - royalty;

        require(tStakeToken.transferFrom(msg.sender, royaltyRecipient, royalty), "Royalty failed");
        require(tStakeToken.transferFrom(msg.sender, seller, sellerAmount), "Payment failed");

        nftContract.safeTransferFrom(address(this), msg.sender, tokenId, listing.amount, "");

        delete listings[tokenId][seller];

        emit NFTPurchased(tokenId, msg.sender, seller, listing.amount, totalPrice);
    }

    // ==========================
    // 🔹 Bidding System (Auctions)
    // ==========================
    function placeBid(uint256 tokenId, address seller, uint256 bidAmount) external marketActive nonReentrant {
        require(bidAmount >= MIN_BID_INCREMENT, "Bid too low");
        require(listings[tokenId][seller].isAuction, "Not an auction");

        Bid storage bid = bids[tokenId][seller];
        require(bidAmount > bid.highestBid, "Must outbid");

        if (bid.highestBid > 0) {
            tStakeToken.transfer(bid.highestBidder, bid.highestBid);
        }

        tStakeToken.transferFrom(msg.sender, address(this), bidAmount);

        bid.highestBid = bidAmount;
        bid.highestBidder = msg.sender;

        emit NFTBidPlaced(tokenId, msg.sender, bidAmount);
    }

    // ==========================
    // 🔹 Finalizing an Auction
    // ==========================
    function finalizeAuction(uint256 tokenId, address seller) external nonReentrant {
        Bid storage bid = bids[tokenId][seller];
        require(block.timestamp >= listings[tokenId][seller].expiry, "Auction not ended");
        require(bid.highestBid > 0, "No valid bids");

        tStakeToken.transfer(seller, bid.highestBid);
        nftContract.safeTransferFrom(address(this), bid.highestBidder, tokenId, listings[tokenId][seller].amount, "");

        delete listings[tokenId][seller];
        delete bids[tokenId][seller];

        emit NFTBidFinalized(tokenId, bid.highestBidder, bid.highestBid);
    }
}
