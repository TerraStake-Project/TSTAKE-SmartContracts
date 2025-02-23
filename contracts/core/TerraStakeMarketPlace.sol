// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

interface ITerraStakeToken is IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
}

contract TerraStakeMarketplace is AccessControl, ReentrancyGuard, ERC1155Holder, Pausable {
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    uint256 public constant MAX_ROYALTY_FEE = 1000; // 10% Max
    uint256 public royaltyFee = 500; // 5% Default
    uint256 public tradingVolume;
    uint256 public totalListings;

    address public immutable royaltyRecipient;
    ITerraStakeToken public immutable tStakeToken;
    IERC1155 public immutable nftContract;

    uint256 public constant REWARD_AMOUNT = 10 * 10**18; // 10 TSTAKE reward per trade
    uint256 public rewardPool;
    uint256 public constant MAX_PRICE = 1_000_000 * 10**18;

    bool public autoRiskMonitoring = true;

    struct Listing {
        address seller;
        uint256 price;
        uint256 amount;
        bool active;
        uint256 expiry;
        uint256 listingTime;
        uint256 startPrice; // Added for Dutch auction support
        uint256 endPrice;   // Added for Dutch auction support
        uint256 priceDecrementInterval; // Time interval for price updates
    }

    // Added to track user's tokenIds
    mapping(address => uint256[]) private userListings;
    mapping(uint256 => mapping(address => Listing)) public listings;
    mapping(uint256 => TradingStats) public marketStats;
    mapping(address => uint256) public traderRewards;
    mapping(address => uint256) public lastTradeTimestamp;
    mapping(address => uint256) public pendingRewards; // Added for manual reward claims

    struct TradingStats {
        uint256 totalVolume;
        uint256 lastPrice;
        uint256[] priceHistory;
    }

    event NFTListed(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 amount,
        uint256 startPrice,
        uint256 endPrice,
        uint256 interval,
        uint256 expiry
    );
    event NFTPurchased(uint256 indexed tokenId, address indexed buyer, uint256 amount, uint256 price);
    event NFTDelisted(uint256 indexed tokenId, address indexed seller);
    event TradingVolumeUpdated(uint256 newVolume);
    event RoyaltyFeeUpdated(uint256 newRoyalty);
    event AutoRiskMonitoringUpdated(bool status);
    event RewardDistributed(address indexed recipient, uint256 amount);
    event RewardPoolReplenished(uint256 amount);
    event PriceUpdated(uint256 indexed tokenId, address indexed seller, uint256 newPrice);
    event RewardsClaimed(address indexed user, uint256 amount);

    uint256 public constant MIN_TRADE_DELAY = 5 minutes;
    
    modifier checkRisk() {
        if (autoRiskMonitoring) {
            require(tradingVolume < 1_000_000 * 1e18, "Risk monitoring triggered: Slow trading");
        }
        _;
    }

    modifier validTradeDelay() {
        require(
            block.timestamp >= lastTradeTimestamp[msg.sender] + MIN_TRADE_DELAY,
            "Must wait between trades"
        );
        _;
    }

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

    // Enhanced listing function with Dutch auction support
    function listNFT(
        uint256 tokenId,
        uint256 amount,
        uint256 startPrice,
        uint256 endPrice,
        uint256 priceDecrementInterval,
        uint256 expiry
    ) external nonReentrant whenNotPaused {
        require(amount > 0, "Amount must be positive");
        require(startPrice > 0 && startPrice <= MAX_PRICE, "Invalid start price");
        require(endPrice <= startPrice, "End price must be <= start price");
        require(expiry > block.timestamp + 1 hours, "Expiry too soon");
        require(expiry < block.timestamp + 30 days, "Expiry too far");
        require(priceDecrementInterval >= 1 hours, "Interval too short");
        
        require(
            nftContract.balanceOf(msg.sender, tokenId) >= amount,
            "Insufficient NFT balance"
        );
        require(
            nftContract.isApprovedForAll(msg.sender, address(this)),
            "NFT not approved"
        );

        listings[tokenId][msg.sender] = Listing({
            seller: msg.sender,
            price: startPrice,
            amount: amount,
            active: true,
            expiry: expiry,
            listingTime: block.timestamp,
            startPrice: startPrice,
            endPrice: endPrice,
            priceDecrementInterval: priceDecrementInterval
        });

        userListings[msg.sender].push(tokenId);

        emit NFTListed(
            tokenId,
            msg.sender,
            amount,
            startPrice,
            endPrice,
            priceDecrementInterval,
            expiry
        );
    }

    // Get current price for a listing (supports Dutch auction)
    function getCurrentPrice(uint256 tokenId, address seller) public view returns (uint256) {
        Listing storage listing = listings[tokenId][seller];
        if (!listing.active) return 0;
        
        if (listing.priceDecrementInterval == 0) return listing.price;
        
        uint256 timeElapsed = block.timestamp - listing.listingTime;
        uint256 totalPriceDecrement = listing.startPrice - listing.endPrice;
        uint256 intervals = timeElapsed / listing.priceDecrementInterval;
        
        if (intervals == 0) return listing.startPrice;
        
        uint256 priceDecrement = (totalPriceDecrement * intervals) / 
            ((listing.expiry - listing.listingTime) / listing.priceDecrementInterval);
        
        uint256 currentPrice = listing.startPrice - priceDecrement;
        return currentPrice > listing.endPrice ? currentPrice : listing.endPrice;
    }

    // Get all active listings for a seller
    function getSellerListings(address seller) external view returns (
        uint256[] memory tokenIds,
        uint256[] memory amounts,
        uint256[] memory prices,
        uint256[] memory expiries
    ) {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < userListings[seller].length; i++) {
            if (listings[userListings[seller][i]][seller].active) {
                activeCount++;
            }
        }

        tokenIds = new uint256[](activeCount);
        amounts = new uint256[](activeCount);
        prices = new uint256[](activeCount);
        expiries = new uint256[](activeCount);

        uint256 index = 0;
        for (uint256 i = 0; i < userListings[seller].length && index < activeCount; i++) {
            uint256 tokenId = userListings[seller][i];
            Listing storage listing = listings[tokenId][seller];
            if (listing.active) {
                tokenIds[index] = tokenId;
                amounts[index] = listing.amount;
                prices[index] = getCurrentPrice(tokenId, seller);
                expiries[index] = listing.expiry;
                index++;
            }
        }

        return (tokenIds, amounts, prices, expiries);
    }

    // Manual reward claiming function
    function claimRewards() external nonReentrant {
        uint256 rewardAmount = pendingRewards[msg.sender];
        require(rewardAmount > 0, "No rewards to claim");
        require(rewardPool >= rewardAmount, "Insufficient reward pool");

        pendingRewards[msg.sender] = 0;
        rewardPool -= rewardAmount;

        require(
            tStakeToken.transfer(msg.sender, rewardAmount),
            "Reward transfer failed"
        );

        emit RewardsClaimed(msg.sender, rewardAmount);
    }

    function purchaseNFT(uint256 tokenId, address seller) 
        external 
        checkRisk 
        nonReentrant 
        whenNotPaused 
        validTradeDelay 
    {
        Listing storage listedItem = listings[tokenId][seller];
        require(listedItem.active, "NFT not listed");
        require(block.timestamp <= listedItem.expiry, "Listing expired");
        require(block.timestamp >= listedItem.listingTime + 5 minutes, "Listing too recent");
        require(seller != msg.sender, "Cannot buy own listing");

        uint256 currentPrice = getCurrentPrice(tokenId, seller);
        uint256 totalPrice = currentPrice * listedItem.amount;
        uint256 royaltyAmount = (totalPrice * royaltyFee) / 10000;
        uint256 sellerAmount = totalPrice - royaltyAmount;

        require(
            tStakeToken.balanceOf(msg.sender) >= totalPrice,
            "Insufficient TSTAKE balance"
        );
        require(
            nftContract.balanceOf(seller, tokenId) >= listedItem.amount,
            "Seller insufficient NFT balance"
        );

        require(tStakeToken.transferFrom(msg.sender, royaltyRecipient, royaltyAmount), "Royalty transfer failed");
        require(tStakeToken.transferFrom(msg.sender, listedItem.seller, sellerAmount), "Payment failed");

        nftContract.safeTransferFrom(seller, msg.sender, tokenId, listedItem.amount, "");

        tradingVolume += totalPrice;
        marketStats[tokenId].totalVolume += totalPrice;
        marketStats[tokenId].lastPrice = currentPrice;
        marketStats[tokenId].priceHistory.push(currentPrice);

        lastTradeTimestamp[msg.sender] = block.timestamp;

        // Add rewards to pending instead of immediate distribution
        if (rewardPool >= REWARD_AMOUNT * 2) {
            pendingRewards[msg.sender] += REWARD_AMOUNT;
            pendingRewards[seller] += REWARD_AMOUNT;
        }

        delete listings[tokenId][seller];

        emit NFTPurchased(tokenId, msg.sender, listedItem.amount, totalPrice);
        emit TradingVolumeUpdated(tradingVolume);
    }

    // Rest of the contract functions remain the same...
    // (Previous functions for governance, rewards, etc.)
}
