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
    uint256 public tradingVolume;
    uint256 public totalListings;

    address public immutable royaltyRecipient;
    ITerraStakeToken public immutable tStakeToken;
    IERC1155 public immutable nftContract;
    uint256 public constant REWARD_AMOUNT = 10 * 10**18; // 10 TSTAKE tokens

    bool public isPaused;

    struct Listing {
        address seller;
        uint256 price;
        uint256 amount;
        bool active;
        uint256 expiry;
    }
    mapping(uint256 => Listing) public listings;

    struct DutchAuction {
        address seller;
        uint256 startPrice;
        uint256 reservePrice;
        uint256 amount;
        uint256 duration;
        uint256 startTime;
        bool active;
    }
    mapping(uint256 => DutchAuction) public dutchAuctions;

    struct Auction {
        address seller;
        address highestBidder;
        uint256 highestBid;
        uint256 minBid;
        uint256 amount;
        uint256 endTime;
        bool active;
    }
    mapping(uint256 => Auction) public auctions;

    // Trading analytics tracking
    mapping(uint256 => uint256) public totalTradeVolume;
    mapping(uint256 => uint256[]) public priceHistory;
    mapping(uint256 => uint256) public lastTradePrice;
    mapping(uint256 => uint256) public rewardPoints;

    event NFTListed(uint256 indexed tokenId, address indexed seller, uint256 amount, uint256 price, uint256 expiry);
    event NFTPurchased(uint256 indexed tokenId, address indexed buyer, uint256 amount, uint256 price);
    event NFTDelisted(uint256 indexed tokenId);
    event DutchAuctionCreated(uint256 indexed tokenId, uint256 startPrice, uint256 reservePrice, uint256 duration);
    event DutchAuctionFinalized(uint256 indexed tokenId, address indexed buyer, uint256 finalPrice);
    event AuctionCreated(uint256 indexed tokenId, uint256 amount, uint256 minBid, uint256 endTime);
    event BidPlaced(uint256 indexed tokenId, address indexed bidder, uint256 bid);
    event AuctionFinalized(uint256 indexed tokenId, address indexed winner, uint256 finalBid);
    event AuctionCancelled(uint256 indexed tokenId);
    event TradingVolumeUpdated(uint256 newVolume);
    event RoyaltyFeeUpdated(uint256 newRoyalty);
    event EmergencyPaused(bool status);
    event RewardDistributed(address indexed recipient, uint256 amount);

    modifier notPaused() {
        require(!isPaused, "Marketplace is paused");
        _;
    }

    constructor(address _nftContract, address _tStakeToken, address _royaltyRecipient) {
        require(_nftContract != address(0), "Invalid NFT contract");
        require(_tStakeToken != address(0), "Invalid TSTAKE token address");
        require(_royaltyRecipient != address(0), "Invalid royalty recipient");

        nftContract = IERC1155(_nftContract);
        tStakeToken = ITerraStakeToken(_tStakeToken);
        royaltyRecipient = _royaltyRecipient;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
    }

    // ====================================================
    // 🔹 Trading Analytics & Market Performance
    // ====================================================
    function getPriceHistory(uint256 tokenId) external view returns (uint256[] memory) {
        return priceHistory[tokenId];
    }

    function getMarketPerformance(uint256 tokenId) external view returns (uint256 totalVolume, uint256 lastPrice) {
        return (totalTradeVolume[tokenId], lastTradePrice[tokenId]);
    }

    function calculateRewards(address user) external view returns (uint256) {
        return rewardPoints[user];
    }

    // ====================================================
    // 🔹 NFT Trading & Rewards
    // ====================================================
    function purchaseNFT(uint256 tokenId) external notPaused nonReentrant {
        Listing storage listedItem = listings[tokenId];
        require(listedItem.active, "NFT not listed");
        require(block.timestamp <= listedItem.expiry, "Listing expired");

        uint256 totalPrice = listedItem.price * listedItem.amount;
        uint256 royaltyAmount = (totalPrice * royaltyFee) / 10000;
        uint256 sellerAmount = totalPrice - royaltyAmount;

        require(tStakeToken.transferFrom(msg.sender, royaltyRecipient, royaltyAmount), "Royalty transfer failed");
        require(tStakeToken.transferFrom(msg.sender, listedItem.seller, sellerAmount), "Payment to seller failed");

        nftContract.safeTransferFrom(listedItem.seller, msg.sender, tokenId, listedItem.amount, "");

        // Update market analytics
        tradingVolume += totalPrice;
        totalTradeVolume[tokenId] += totalPrice;
        lastTradePrice[tokenId] = listedItem.price;
        priceHistory[tokenId].push(listedItem.price);

        // Reward buyers & sellers
        rewardPoints[msg.sender] += REWARD_AMOUNT;
        rewardPoints[listedItem.seller] += REWARD_AMOUNT;
        tStakeToken.transfer(msg.sender, REWARD_AMOUNT);
        tStakeToken.transfer(listedItem.seller, REWARD_AMOUNT);

        delete listings[tokenId];

        emit NFTPurchased(tokenId, msg.sender, listedItem.amount, totalPrice);
        emit TradingVolumeUpdated(tradingVolume);
        emit RewardDistributed(msg.sender, REWARD_AMOUNT);
        emit RewardDistributed(listedItem.seller, REWARD_AMOUNT);
    }

    // ====================================================
    // 🔹 Dutch Auction System
    // ====================================================
    function finalizeDutchAuction(uint256 tokenId) external notPaused nonReentrant {
        DutchAuction storage auction = dutchAuctions[tokenId];
        require(auction.active, "Auction not active");

        uint256 elapsedTime = block.timestamp - auction.startTime;
        uint256 priceDrop = ((auction.startPrice - auction.reservePrice) * elapsedTime) / auction.duration;
        uint256 currentPrice = auction.startPrice - priceDrop;

        if (currentPrice < auction.reservePrice) {
            currentPrice = auction.reservePrice;
        }

        require(tStakeToken.transferFrom(msg.sender, auction.seller, currentPrice), "Payment failed");

        nftContract.safeTransferFrom(auction.seller, msg.sender, tokenId, auction.amount, "");
        auction.active = false;

        // Update analytics
        tradingVolume += currentPrice;
        totalTradeVolume[tokenId] += currentPrice;
        lastTradePrice[tokenId] = currentPrice;
        priceHistory[tokenId].push(currentPrice);

        emit DutchAuctionFinalized(tokenId, msg.sender, currentPrice);
        emit TradingVolumeUpdated(tradingVolume);
    }

    // ====================================================
    // 🔹 Security & Governance
    // ====================================================
    function updateRoyaltyFee(uint256 newRoyalty) external onlyRole(GOVERNANCE_ROLE) {
        require(newRoyalty <= 1000, "Max 10%");
        royaltyFee = newRoyalty;
        emit RoyaltyFeeUpdated(newRoyalty);
    }

    function togglePause() external onlyRole(GOVERNANCE_ROLE) {
        isPaused = !isPaused;
        emit EmergencyPaused(isPaused);
    }
}
