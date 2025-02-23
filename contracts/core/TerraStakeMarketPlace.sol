// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "./IPriceFeed.sol";
import "./TerraStakeGovernance.sol";

interface ITerraStakeToken is IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
}

/**
 * @title TerraStake Marketplace
 * @notice Optimized for NFT trading, featuring buy now, auctions, batch processing, and upgradability.
 */
contract TerraStakeMarketplace is 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable, 
    ERC1155Holder, 
    PausableUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    uint256 public constant MAX_ROYALTY_FEE = 1000; // 10% Max
    uint256 public constant MIN_BID_INCREMENT = 5 * 10**18; // 5 TSTAKE min bid increase
    uint256 public constant MAX_PRICE = 1_000_000 * 10**18;

    uint256 public royaltyFee;
    address public royaltyRecipient;
    ITerraStakeToken public tStakeToken;
    IERC1155 public nftContract;
    IPriceFeed public priceFeed;
    TerraStakeGovernance public governanceContract;

    uint256 public rewardPool;
    bool public riskMonitoringEnabled;
    
    enum MarketState { Active, Suspended, Emergency }
    MarketState public currentState;

    struct Listing {
        address seller;
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
        bool finalized;
    }

    mapping(uint256 => mapping(address => Listing)) public listings;
    mapping(uint256 => mapping(address => Bid)) public bids;

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

    modifier onlyGovernance() {
        require(hasRole(GOVERNANCE_ROLE, msg.sender), "Caller is not governance");
        _;
    }

    modifier marketActive() {
        require(currentState == MarketState.Active, "Market is not active");
        _;
    }

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
        governanceContract = TerraStakeGovernance(_governanceContract);
        priceFeed = IPriceFeed(_priceFeed);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);

        royaltyFee = 500; // 5%
        riskMonitoringEnabled = true;
        currentState = MarketState.Active;
    }

    function _authorizeUpgrade(address) internal override onlyGovernance {}

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
        require(startPrice > 0 && startPrice <= MAX_PRICE, "Invalid start price");
        require(expiry > block.timestamp + 1 hours, "Expiry too soon");
        require(expiry < block.timestamp + 30 days, "Expiry too far");

        nftContract.safeTransferFrom(msg.sender, address(this), tokenId, amount, "");

        listings[tokenId][msg.sender] = Listing({
            seller: msg.sender,
            price: startPrice,
            amount: amount,
            active: true,
            expiry: expiry,
            startPrice: startPrice,
            endPrice: endPrice,
            priceDecrementInterval: priceDecrementInterval,
            isAuction: isAuction
        });

        emit NFTListed(tokenId, msg.sender, uint256(keccak256(abi.encodePacked(block.timestamp, msg.sender, tokenId))), amount, startPrice, isAuction);
    }

    function placeBid(uint256 tokenId, address seller, uint256 bidAmount) external marketActive nonReentrant {
        require(bidAmount >= MIN_BID_INCREMENT, "Bid too low");
        require(listings[tokenId][seller].isAuction, "Not an auction");
        require(block.timestamp < listings[tokenId][seller].expiry, "Auction ended");

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

    function finalizeBid(uint256 tokenId, address seller) external nonReentrant {
        Bid storage bid = bids[tokenId][seller];
        require(block.timestamp >= listings[tokenId][seller].expiry, "Auction not ended");

        require(bid.highestBid > 0, "No valid bids");

        uint256 finalPrice = bid.highestBid;
        uint256 royaltyAmount = (finalPrice * royaltyFee) / 10000;
        uint256 sellerAmount = finalPrice - royaltyAmount;

        tStakeToken.transfer(royaltyRecipient, royaltyAmount);
        tStakeToken.transfer(seller, sellerAmount);

        nftContract.safeTransferFrom(address(this), bid.highestBidder, tokenId, listings[tokenId][seller].amount, "");

        delete listings[tokenId][seller];
        delete bids[tokenId][seller];

        emit NFTBidFinalized(tokenId, bid.highestBidder, finalPrice);
    }
}
