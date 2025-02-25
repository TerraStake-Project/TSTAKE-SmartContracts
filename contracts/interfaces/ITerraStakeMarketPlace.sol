// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ITerraStakeMarketplace {
    // ================================
    // 🔹 Market Enums & Structs
    // ================================
    
    enum MarketState { Active, Suspended, Emergency }
    
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

    struct FeeDistribution {
        uint256 stakingShare;
        uint256 liquidityShare;
        uint256 treasuryShare;
        uint256 burnShare;
    }

    // ================================
    // 🔹 Marketplace Core Functions
    // ================================

    function listNFT(
        uint256 tokenId, 
        uint256 amount, 
        uint256 price, 
        bool isAuction, 
        uint256 expiry
    ) external;

    function buyNow(uint256 tokenId, address seller) external;

    function cancelListing(uint256 tokenId) external;

    function placeBid(uint256 tokenId, address seller, uint256 bidAmount) external;

    function finalizeAuction(uint256 tokenId, address seller) external;

    function getListing(uint256 tokenId, address seller) external view returns (Listing memory);

    function getBid(uint256 tokenId, address seller) external view returns (Bid memory);

    function getMarketState() external view returns (MarketState);

    // ================================
    // 🔹 Market Analytics & Risk Monitoring
    // ================================

    function updateMarketMetrics() external;

    function assessMarketRisk() external view returns (uint256);

    function getMarketMetrics() external view returns (MarketMetrics memory);

    function getMarketVolume(uint256 blockNumber) external view returns (uint256);

    // ================================
    // 🔹 Price Oracle Integration
    // ================================

    function getTokenPrice() external view returns (uint256);

    function setPriceFeed(address priceFeed) external;

    // ================================
    // 🔹 Governance & Configuration
    // ================================

    function setRoyaltyFee(uint256 newFee) external;

    function updateFeeDistribution(
        uint256 stakingShare, 
        uint256 liquidityShare, 
        uint256 treasuryShare, 
        uint256 burnShare
    ) external;

    function toggleMarketState(MarketState newState) external;

    function setRiskMonitoring(bool enabled) external;

    function updateRewardPool(uint256 amount) external;

    function setLiquidityProvisionEnabled(bool enabled) external;

    function withdrawMarketplaceFees() external;

    function recoverERC20(address token, uint256 amount) external;

    // ================================
    // 🔹 Market Maker & Liquidity Functions
    // ================================

    function provideLiquidity() external;

    function getLiquiditySettings() external view returns (bool isProvisionEnabled);

    // ================================
    // 🔹 Events
    // ================================

    event NFTListed(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 amount,
        uint256 price,
        bool isAuction,
        uint256 expiry
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

    event ListingCancelled(uint256 indexed tokenId, address indexed seller);

    event MarketStateChanged(MarketState newState);

    event RoyaltyFeeUpdated(uint256 newRoyalty);

    event MarketMetricsUpdated(
        uint256 totalVolume, 
        uint256 activeListings, 
        uint256 successfulAuctions, 
        uint256 averagePrice
    );

    event MarketRiskAssessed(uint256 riskScore);

    event FeeDistributionUpdated(
        uint256 stakingShare, 
        uint256 liquidityShare, 
        uint256 treasuryShare, 
        uint256 burnShare
    );

    event RewardPoolUpdated(uint256 newAmount);

    event LiquidityProvisionToggled(bool isEnabled);

    event PriceFeedUpdated(address newPriceFeed);

    event ERC20Recovered(address indexed token, uint256 amount);
}
