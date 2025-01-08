// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ITerraStakeToken is IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
}

/**
 * @title TerraStakeMarketplace
 * @notice A marketplace contract supporting direct sales and simple auctions
 *         with TSTAKE reward distribution and a 5% royalty mechanism.
 */
contract TerraStakeMarketplace is AccessControl, ReentrancyGuard {
    // ------------------------------------------------------------------------
    // Roles
    // ------------------------------------------------------------------------
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    // ------------------------------------------------------------------------
    // Fees and Addresses
    // ------------------------------------------------------------------------
    uint256 public royaltyFee = 500; // 5%
    address public immutable royaltyRecipient;
    ITerraStakeToken public immutable tStakeToken;

    uint256 public constant REWARD_AMOUNT = 10 * 10**18; // 10 TSTAKE tokens

    // ------------------------------------------------------------------------
    // Supported Payment Tokens
    // ------------------------------------------------------------------------
    mapping(address => bool) public supportedPaymentTokens;

    // ------------------------------------------------------------------------
    // Direct Listing Struct
    // ------------------------------------------------------------------------
    struct Listing {
        address seller;
        address paymentToken;
        uint256 price;
        bool active;
    }

    mapping(address => mapping(uint256 => Listing)) public listings;

    // ------------------------------------------------------------------------
    // Auction Struct
    // ------------------------------------------------------------------------
    struct Auction {
        address seller;
        address highestBidder;
        address paymentToken;
        uint256 highestBid;
        uint256 minBid;
        uint256 endTime;
        bool active;
    }

    mapping(address => mapping(uint256 => Auction)) public auctions;

    // ------------------------------------------------------------------------
    // NFT Metadata (Optional / Expandable)
    // ------------------------------------------------------------------------
    struct ListingMetadata {
        uint256 projectId;
        uint256 impactValue;
    }

    mapping(address => mapping(uint256 => ListingMetadata)) public nftMetadata;

    // ------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------
    event NFTListed(
        address indexed nftContract,
        uint256 indexed tokenId,
        address indexed seller,
        uint256 price,
        address paymentToken
    );
    event NFTPurchased(
        address indexed nftContract,
        uint256 indexed tokenId,
        address indexed buyer,
        uint256 price
    );
    event NFTDelisted(address indexed nftContract, uint256 indexed tokenId);

    event AuctionCreated(
        address indexed nftContract,
        uint256 indexed tokenId,
        uint256 minBid,
        uint256 endTime,
        address paymentToken
    );
    event BidPlaced(
        address indexed nftContract,
        uint256 indexed tokenId,
        address indexed bidder,
        uint256 bid
    );
    event AuctionFinalized(
        address indexed nftContract,
        uint256 indexed tokenId,
        address indexed winner,
        uint256 finalBid
    );

    constructor(address _tStakeToken, address _royaltyRecipient) {
        require(_tStakeToken != address(0), "Invalid TSTAKE token address");
        require(_royaltyRecipient != address(0), "Invalid royalty recipient");

        tStakeToken = ITerraStakeToken(_tStakeToken);
        royaltyRecipient = _royaltyRecipient;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
    }

    function listNFT(
        address nftContract,
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 projectId,
        uint256 impactValue
    ) external nonReentrant {
        require(price > 0, "Price must be greater than zero");
        require(supportedPaymentTokens[paymentToken], "Unsupported payment token");

        Auction memory existingAuction = auctions[nftContract][tokenId];
        require(!existingAuction.active, "An active auction exists for this NFT");

        IERC721 nft = IERC721(nftContract);
        require(nft.ownerOf(tokenId) == msg.sender, "Caller is not the owner");
        require(nft.isApprovedForAll(msg.sender, address(this)), "Marketplace not approved to transfer");

        listings[nftContract][tokenId] = Listing({
            seller: msg.sender,
            paymentToken: paymentToken,
            price: price,
            active: true
        });

        nftMetadata[nftContract][tokenId] = ListingMetadata({
            projectId: projectId,
            impactValue: impactValue
        });

        emit NFTListed(nftContract, tokenId, msg.sender, price, paymentToken);
    }

    function purchaseNFT(address nftContract, uint256 tokenId) external nonReentrant {
        Listing storage listedItem = listings[nftContract][tokenId];
        require(listedItem.active, "NFT not listed");
        uint256 price = listedItem.price;
        address seller = listedItem.seller;

        IERC721 nft = IERC721(nftContract);
        require(nft.ownerOf(tokenId) == seller, "Seller no longer owns the NFT");

        IERC20 payment = IERC20(listedItem.paymentToken);
        uint256 royaltyAmount = (price * royaltyFee) / 10000;
        uint256 sellerAmount = price - royaltyAmount;

        require(payment.transferFrom(msg.sender, royaltyRecipient, royaltyAmount), "Royalty transfer failed");
        require(payment.transferFrom(msg.sender, seller, sellerAmount), "Payment to seller failed");

        nft.safeTransferFrom(seller, msg.sender, tokenId);

        tStakeToken.transfer(msg.sender, REWARD_AMOUNT);
        tStakeToken.transfer(seller, REWARD_AMOUNT);

        listedItem.active = false;

        emit NFTPurchased(nftContract, tokenId, msg.sender, price);
    }

    function delistNFT(address nftContract, uint256 tokenId) external nonReentrant {
        Listing storage listedItem = listings[nftContract][tokenId];
        require(listedItem.active, "NFT not listed");
        require(listedItem.seller == msg.sender || hasRole(GOVERNANCE_ROLE, msg.sender),
                "Not seller or governance");

        listedItem.active = false;

        emit NFTDelisted(nftContract, tokenId);
    }

    function createAuction(
        address nftContract,
        uint256 tokenId,
        uint256 minBid,
        uint256 duration,
        address paymentToken
    ) external nonReentrant {
        require(duration > 0, "Duration must be > 0");
        require(supportedPaymentTokens[paymentToken], "Unsupported payment token");

        Listing memory existingListing = listings[nftContract][tokenId];
        require(!existingListing.active, "Already listed for direct sale");

        IERC721 nft = IERC721(nftContract);
        require(nft.ownerOf(tokenId) == msg.sender, "Caller is not the owner");
        require(nft.isApprovedForAll(msg.sender, address(this)), "Marketplace not approved");

        auctions[nftContract][tokenId] = Auction({
            seller: msg.sender,
            highestBidder: address(0),
            paymentToken: paymentToken,
            highestBid: 0,
            minBid: minBid,
            endTime: block.timestamp + duration,
            active: true
        });

        emit AuctionCreated(nftContract, tokenId, minBid, block.timestamp + duration, paymentToken);
    }

    function placeBid(
        address nftContract,
        uint256 tokenId,
        uint256 bid
    ) external nonReentrant {
        Auction storage auction = auctions[nftContract][tokenId];
        require(auction.active, "Auction not active");
        require(block.timestamp < auction.endTime, "Auction ended");
        require(bid >= auction.minBid, "Bid below minimum");
        require(bid > auction.highestBid, "Bid not higher than current");

        IERC20 payment = IERC20(auction.paymentToken);

        require(payment.transferFrom(msg.sender, address(this), bid), "Bid transfer failed");

        if (auction.highestBid > 0) {
            require(payment.transfer(auction.highestBidder, auction.highestBid), "Refund failed");
        }

        auction.highestBid = bid;
        auction.highestBidder = msg.sender;

        emit BidPlaced(nftContract, tokenId, msg.sender, bid);
    }

    function finalizeAuction(address nftContract, uint256 tokenId) external nonReentrant {
        Auction storage auction = auctions[nftContract][tokenId];
        require(auction.active, "Auction not active");
        require(block.timestamp >= auction.endTime, "Auction not ended yet");

        auction.active = false;

        if (auction.highestBid == 0) {
            emit AuctionFinalized(nftContract, tokenId, address(0), 0);
            return;
        }

        IERC20 payment = IERC20(auction.paymentToken);
        uint256 royaltyAmount = (auction.highestBid * royaltyFee) / 10000;
        uint256 sellerAmount = auction.highestBid - royaltyAmount;

        require(payment.transfer(royaltyRecipient, royaltyAmount), "Royalty transfer failed");
        require(payment.transfer(auction.seller, sellerAmount), "Payment to seller failed");

        IERC721(nftContract).safeTransferFrom(auction.seller, auction.highestBidder, tokenId);

        tStakeToken.transfer(auction.highestBidder, REWARD_AMOUNT);
        tStakeToken.transfer(auction.seller, REWARD_AMOUNT);

        emit AuctionFinalized(nftContract, tokenId, auction.highestBidder, auction.highestBid);
    }

    function setSupportedPaymentToken(address token, bool isSupported)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        supportedPaymentTokens[token] = isSupported;
    }

    function setRoyaltyFee(uint256 newFee) external onlyRole(GOVERNANCE_ROLE) {
        require(newFee <= 2000, "Fee cannot exceed 20%");
        royaltyFee = newFee;
    }
}
