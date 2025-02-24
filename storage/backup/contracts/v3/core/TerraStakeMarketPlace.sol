// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

interface ITerraStakeToken is IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
}

contract TerraStakeMarketplace is AccessControl, ReentrancyGuard, ERC1155Holder {
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    uint256 public royaltyFee = 500; // 5%
    address public immutable royaltyRecipient;
    ITerraStakeToken public immutable tStakeToken;
    IERC1155 public immutable nftContract;
    uint256 public constant REWARD_AMOUNT = 10 * 10**18; // 10 TSTAKE tokens

    mapping(address => bool) public supportedPaymentTokens;

    struct Listing {
        address seller;
        address paymentToken;
        uint256 price;
        uint256 amount;
        bool active;
    }
    mapping(address => mapping(uint256 => Listing)) public listings;

    struct Auction {
        address seller;
        address highestBidder;
        address paymentToken;
        uint256 highestBid;
        uint256 minBid;
        uint256 amount;
        uint256 endTime;
        bool active;
    }
    mapping(address => mapping(uint256 => Auction)) public auctions;

    struct ListingMetadata {
        uint256 projectId;
        uint256 impactValue;
    }
    mapping(address => mapping(uint256 => ListingMetadata)) public nftMetadata;

    event NFTListed(address indexed nftContract, uint256 indexed tokenId, address indexed seller, uint256 amount, uint256 price, address paymentToken);
    event NFTPurchased(address indexed nftContract, uint256 indexed tokenId, address indexed buyer, uint256 amount, uint256 price);
    event NFTDelisted(address indexed nftContract, uint256 indexed tokenId);
    event AuctionCreated(address indexed nftContract, uint256 indexed tokenId, uint256 amount, uint256 minBid, uint256 endTime, address paymentToken);
    event BidPlaced(address indexed nftContract, uint256 indexed tokenId, address indexed bidder, uint256 bid);
    event AuctionFinalized(address indexed nftContract, uint256 indexed tokenId, address indexed winner, uint256 finalBid);

    constructor(
        address _nftContract,
        address _tStakeToken,
        address _royaltyRecipient
    ) {
        require(_nftContract != address(0), "Invalid NFT contract");
        require(_tStakeToken != address(0), "Invalid TSTAKE token address");
        require(_royaltyRecipient != address(0), "Invalid royalty recipient");

        nftContract = IERC1155(_nftContract);
        tStakeToken = ITerraStakeToken(_tStakeToken);
        royaltyRecipient = _royaltyRecipient;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
    }

    function listNFT(
        uint256 tokenId,
        uint256 amount,
        uint256 price,
        address paymentToken,
        uint256 projectId,
        uint256 impactValue
    ) external nonReentrant {
        require(amount > 0, "Amount must be greater than zero");
        require(price > 0, "Price must be greater than zero");
        require(supportedPaymentTokens[paymentToken], "Unsupported payment token");
        require(nftContract.balanceOf(msg.sender, tokenId) >= amount, "You do not own this NFT");
        require(nftContract.isApprovedForAll(msg.sender, address(this)), "Marketplace not approved");

        require(!listings[address(nftContract)][tokenId].active, "NFT already listed");
        require(!auctions[address(nftContract)][tokenId].active, "NFT is in an active auction");

        listings[address(nftContract)][tokenId] = Listing({
            seller: msg.sender,
            paymentToken: paymentToken,
            price: price,
            amount: amount,
            active: true
        });

        nftMetadata[address(nftContract)][tokenId] = ListingMetadata({
            projectId: projectId,
            impactValue: impactValue
        });

        emit NFTListed(address(nftContract), tokenId, msg.sender, amount, price, paymentToken);
    }

    function purchaseNFT(uint256 tokenId) external nonReentrant {
        Listing storage listedItem = listings[address(nftContract)][tokenId];
        require(listedItem.active, "NFT not listed");

        uint256 totalPrice = listedItem.price * listedItem.amount;
        uint256 royaltyAmount = (totalPrice * royaltyFee) / 10000;
        uint256 sellerAmount = totalPrice - royaltyAmount;

        IERC20 payment = IERC20(listedItem.paymentToken);
        require(payment.transferFrom(msg.sender, royaltyRecipient, royaltyAmount), "Royalty transfer failed");
        require(payment.transferFrom(msg.sender, listedItem.seller, sellerAmount), "Payment to seller failed");

        nftContract.safeTransferFrom(listedItem.seller, msg.sender, tokenId, listedItem.amount, "");

        delete listings[address(nftContract)][tokenId];

        tStakeToken.transfer(msg.sender, REWARD_AMOUNT);
        tStakeToken.transfer(listedItem.seller, REWARD_AMOUNT);

        emit NFTPurchased(address(nftContract), tokenId, msg.sender, listedItem.amount, totalPrice);
    }

    function finalizeAuction(uint256 tokenId) external nonReentrant {
        Auction storage auction = auctions[address(nftContract)][tokenId];
        require(auction.active, "Auction not active");
        require(block.timestamp >= auction.endTime, "Auction not ended");

        auction.active = false;

        if (auction.highestBid == 0) {
            emit AuctionFinalized(address(nftContract), tokenId, address(0), 0);
            return;
        }

        IERC20 payment = IERC20(auction.paymentToken);
        uint256 royaltyAmount = (auction.highestBid * royaltyFee) / 10000;
        uint256 sellerAmount = auction.highestBid - royaltyAmount;

        require(payment.transfer(royaltyRecipient, royaltyAmount), "Royalty transfer failed");
        require(payment.transfer(auction.seller, sellerAmount), "Payment to seller failed");

        nftContract.safeTransferFrom(auction.seller, auction.highestBidder, tokenId, auction.amount, "");

        emit AuctionFinalized(address(nftContract), tokenId, auction.highestBidder, auction.highestBid);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(AccessControl, ERC1155Holder) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}