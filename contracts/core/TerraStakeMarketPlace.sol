// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ITerraStakeToken is IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
}

contract TerraStakeMarketplace is AccessControl, ReentrancyGuard {
    // Role definitions
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    // TerraStake royalty fee (in basis points) and reward settings
    uint256 public royaltyFee = 500; // 5%
    address public immutable royaltyRecipient;
    ITerraStakeToken public immutable tStakeToken;

    // TSTAKE rewards
    uint256 public constant REWARD_AMOUNT = 10 * 10**18; // 10 TSTAKE tokens

    // Supported payment tokens
    mapping(address => bool) public supportedPaymentTokens;

    // Auction structure
    struct Auction {
        address seller;
        address highestBidder;
        address paymentToken;
        uint256 highestBid;
        uint256 minBid;
        uint256 endTime;
        bool active;
    }

    // Metadata for NFTs
    struct ListingMetadata {
        uint256 projectId;
        uint256 impactValue;
    }

    // Listings and auctions mappings
    mapping(address => mapping(uint256 => ListingMetadata)) public nftMetadata;
    mapping(address => mapping(uint256 => Auction)) public auctions;

    event NFTListed(address indexed nftContract, uint256 indexed tokenId, address indexed seller, uint256 price);
    event NFTPurchased(address indexed nftContract, uint256 indexed tokenId, address indexed buyer, uint256 price);
    event NFTDelisted(address indexed nftContract, uint256 indexed tokenId);
    event AuctionCreated(address indexed nftContract, uint256 indexed tokenId, uint256 minBid, uint256 endTime);
    event BidPlaced(address indexed nftContract, uint256 indexed tokenId, address indexed bidder, uint256 bid);
    event AuctionFinalized(address indexed nftContract, uint256 indexed tokenId, address indexed winner, uint256 finalBid);

    constructor(address _tStakeToken, address _royaltyRecipient) {
        require(_tStakeToken != address(0), "Invalid TSTAKE token address");
        require(_royaltyRecipient != address(0), "Invalid royalty recipient");

        tStakeToken = ITerraStakeToken(_tStakeToken);
        royaltyRecipient = _royaltyRecipient;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
    }

    /**
     * @dev Create a direct NFT listing.
     * @param nftContract Address of the NFT contract.
     * @param tokenId Token ID of the NFT.
     * @param price Sale price of the NFT.
     * @param paymentToken Address of the payment token.
     * @param projectId Associated project ID for metadata.
     * @param impactValue Impact value for metadata.
     */
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

        IERC721 nft = IERC721(nftContract);
        require(nft.ownerOf(tokenId) == msg.sender, "Caller is not the owner");
        require(nft.isApprovedForAll(msg.sender, address(this)), "Marketplace not approved");

        nftMetadata[nftContract][tokenId] = ListingMetadata({projectId: projectId, impactValue: impactValue});

        emit NFTListed(nftContract, tokenId, msg.sender, price);
    }

    /**
     * @dev Purchase an NFT.
     * @param nftContract Address of the NFT contract.
     * @param tokenId Token ID of the NFT.
     * @param price Sale price of the NFT.
     * @param seller Seller's address.
     * @param paymentToken Address of the payment token.
     */
    function purchaseNFT(
        address nftContract,
        uint256 tokenId,
        uint256 price,
        address seller,
        address paymentToken
    ) external nonReentrant {
        IERC721 nft = IERC721(nftContract);
        require(nft.ownerOf(tokenId) == seller, "Seller no longer owns the NFT");

        IERC20 payment = IERC20(paymentToken);
        uint256 royaltyAmount = (price * royaltyFee) / 10000;
        uint256 sellerAmount = price - royaltyAmount;

        // Transfer payment
        require(payment.transferFrom(msg.sender, royaltyRecipient, royaltyAmount), "Royalty transfer failed");
        require(payment.transferFrom(msg.sender, seller, sellerAmount), "Payment to seller failed");

        // Transfer NFT
        nft.safeTransferFrom(seller, msg.sender, tokenId);

        // Distribute rewards
        tStakeToken.transfer(msg.sender, REWARD_AMOUNT);
        tStakeToken.transfer(seller, REWARD_AMOUNT);

        emit NFTPurchased(nftContract, tokenId, msg.sender, price);
    }

    /**
     * @dev Create an auction.
     * @param nftContract Address of the NFT contract.
     * @param tokenId Token ID of the NFT.
     * @param minBid Minimum bid for the auction.
     * @param duration Auction duration in seconds.
     * @param paymentToken Address of the payment token.
     */
    function createAuction(
        address nftContract,
        uint256 tokenId,
        uint256 minBid,
        uint256 duration,
        address paymentToken
    ) external nonReentrant {
        require(duration > 0, "Duration must be greater than zero");
        require(supportedPaymentTokens[paymentToken], "Unsupported payment token");

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

        emit AuctionCreated(nftContract, tokenId, minBid, block.timestamp + duration);
    }

    /**
     * @dev Place a bid on an auction.
     * @param nftContract Address of the NFT contract.
     * @param tokenId Token ID of the NFT.
     * @param bid Amount of the bid.
     */
    function placeBid(
        address nftContract,
        uint256 tokenId,
        uint256 bid
    ) external nonReentrant {
        Auction storage auction = auctions[nftContract][tokenId];
        require(auction.active, "Auction is not active");
        require(block.timestamp < auction.endTime, "Auction has ended");
        require(bid >= auction.minBid, "Bid is below minimum");
        require(bid > auction.highestBid, "Bid is not higher than current highest");

        IERC20 payment = IERC20(auction.paymentToken);
        require(payment.transferFrom(msg.sender, address(this), bid), "Bid transfer failed");

        // Refund previous highest bidder
        if (auction.highestBid > 0) {
            require(payment.transfer(auction.highestBidder, auction.highestBid), "Refund failed");
        }

        auction.highestBid = bid;
        auction.highestBidder = msg.sender;

        emit BidPlaced(nftContract, tokenId, msg.sender, bid);
    }

    /**
     * @dev Finalize an auction.
     * @param nftContract Address of the NFT contract.
     * @param tokenId Token ID of the NFT.
     */
    function finalizeAuction(address nftContract, uint256 tokenId) external nonReentrant {
        Auction storage auction = auctions[nftContract][tokenId];
        require(auction.active, "Auction is not active");
        require(block.timestamp >= auction.endTime, "Auction has not ended");

        auction.active = false;

        IERC20 payment = IERC20(auction.paymentToken);
        uint256 royaltyAmount = (auction.highestBid * royaltyFee) / 10000;
        uint256 sellerAmount = auction.highestBid - royaltyAmount;

        // Transfer payment
        require(payment.transfer(royaltyRecipient, royaltyAmount), "Royalty transfer failed");
        require(payment.transfer(auction.seller, sellerAmount), "Payment to seller failed");

        // Transfer NFT
        IERC721(nftContract).safeTransferFrom(auction.seller, auction.highestBidder, tokenId);

        // Distribute rewards
        tStakeToken.transfer(auction.highestBidder, REWARD_AMOUNT);
        tStakeToken.transfer(auction.seller, REWARD_AMOUNT);

        emit AuctionFinalized(nftContract, tokenId, auction.highestBidder, auction.highestBid);
    }

    /**
     * @dev Set supported payment tokens.
     * @param token Address of the payment token.
     * @param isSupported Whether the token is supported.
     */
    function setSupportedPaymentToken(address token, bool isSupported) external onlyRole(GOVERNANCE_ROLE) {
        supportedPaymentTokens[token] = isSupported;
    }
}
