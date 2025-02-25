// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

interface IPriceFeed {
    function getPrice() external view returns (uint256);
}

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
        bool isAuction;
    }

    struct Bid {
        address highestBidder;
        uint256 highestBid;
        uint256 bidEndTime;
    }

    struct MarketMetrics {
        uint256 totalVolume;
        uint256 activeListings;
        uint256 successfulAuctions;
        uint256 averagePrice;
        uint256 lastUpdateBlock;
    }

    MarketMetrics public metrics;

    mapping(uint256 => mapping(address => Listing)) public listings;
    mapping(uint256 => mapping(address => Bid)) public bids;
    mapping(address => uint256[]) public userListings;
    mapping(uint256 => uint256) public marketVolume;
    mapping(uint256 => address[]) public bidQueue;

    // ==========================
    // 🔹 Events
    // ==========================
    event NFTListed(uint256 indexed tokenId, address indexed seller, uint256 amount, uint256 price, bool isAuction, uint256 expiry);
    event NFTPurchased(uint256 indexed tokenId, address indexed buyer, address indexed seller, uint256 amount, uint256 price);
    event NFTBidPlaced(uint256 indexed tokenId, address indexed bidder, uint256 amount);
    event NFTBidFinalized(uint256 indexed tokenId, address indexed winner, uint256 winningBid);
    event MarketStateChanged(MarketState newState);
    event RoyaltyFeeUpdated(uint256 newRoyalty);
    event RewardPoolReplenished(uint256 amount);
    event MarketMetricsUpdated(uint256 totalVolume, uint256 activeListings, uint256 successfulAuctions, uint256 averagePrice);

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
        address _priceFeed,
        address _royaltyRecipient
    ) external initializer {
        require(_nftContract != address(0), "Invalid NFT contract");
        require(_tStakeToken != address(0), "Invalid TSTAKE token");
        require(_priceFeed != address(0), "Invalid price feed");
        require(_royaltyRecipient != address(0), "Invalid royalty recipient");

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        nftContract = IERC1155(_nftContract);
        tStakeToken = ITerraStakeToken(_tStakeToken);
        priceFeed = IPriceFeed(_priceFeed);
        royaltyRecipient = _royaltyRecipient;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);

        royaltyFee = 500; // 5%
        riskMonitoringEnabled = true;
        currentState = MarketState.Active;
    }

    function _authorizeUpgrade(address) internal override onlyGovernance {}

    // ==========================
    // 🔹 Market Analytics & Risk
    // ==========================
    function updateMarketMetrics() internal {
        metrics.lastUpdateBlock = block.number;
        metrics.activeListings = metrics.activeListings + 1;
        metrics.totalVolume += marketVolume[block.number];
        metrics.averagePrice = marketVolume[block.number] / (metrics.activeListings + 1);
        
        emit MarketMetricsUpdated(metrics.totalVolume, metrics.activeListings, metrics.successfulAuctions, metrics.averagePrice);
    }

    function assessMarketRisk() public view returns (uint256) {
        return marketVolume[block.number] / (metrics.activeListings + 1);
    }

    function getTokenPrice() public view returns (uint256) {
        return priceFeed.getPrice();
    }

    // ==========================
    // 🔹 Listing an NFT (Fixed Price & Auction)
    // ==========================
    function listNFT(uint256 tokenId, uint256 amount, uint256 price, bool isAuction, uint256 expiry) external marketActive nonReentrant {
        require(amount > 0, "Invalid amount");
        require(price > 0 && price <= MAX_PRICE, "Invalid price");
        require(expiry > block.timestamp + 1 hours, "Expiry too soon");
        require(expiry < block.timestamp + 30 days, "Expiry too far");

        nftContract.safeTransferFrom(msg.sender, address(this), tokenId, amount, "");

        listings[tokenId][msg.sender] = Listing(msg.sender, tokenId, price, amount, true, expiry, isAuction);

        updateMarketMetrics();
        emit NFTListed(tokenId, msg.sender, amount, price, isAuction, expiry);
    }

    // ==========================
    // 🔹 Buying an NFT
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
    // 🔹 Market Maker Functions
    // ==========================
    function provideLiquidity() external onlyGovernance {
        require(riskMonitoringEnabled, "Risk monitoring disabled");
        rewardPool += 10 * 10**18; // Example of automated liquidity provisioning
    }

    function processBidQueue(uint256 tokenId) internal {
        uint256 queueLength = bidQueue[tokenId].length;
        for (uint256 i = 0; i < queueLength; i++) {
            delete bidQueue[tokenId][i]; // Process each bid
        }
    }
}
