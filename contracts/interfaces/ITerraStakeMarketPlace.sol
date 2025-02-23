// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ITerraStakeMarketplace {
    // ==========================
    // 🔹 Structs
    // ==========================
    struct Listing {
        address seller;
        uint256 price;
        uint256 amount;
        bool active;
        uint256 expiry;
        uint256 listingTime;
        uint256 startPrice;
        uint256 endPrice;
        uint256 priceDecrementInterval;
    }

    struct MarketStats {
        uint256 totalVolume;
        uint256 lastPrice;
        uint256 totalTrades;
        uint256 totalListings;
        uint256 activeSellers;
        uint256 averagePrice;
    }

    // ==========================
    // 🔹 NFT Listing & Trading
    // ==========================
    function listNFT(
        uint256 tokenId,
        uint256 amount,
        uint256 startPrice,
        uint256 endPrice,
        uint256 priceDecrementInterval,
        uint256 expiry
    ) external;

    function cancelListing(uint256 tokenId) external;

    function purchaseNFT(uint256 tokenId, address seller) external;

    function getCurrentPrice(uint256 tokenId, address seller) external view returns (uint256);

    function getSellerListings(address seller) external view returns (
        uint256[] memory tokenIds,
        uint256[] memory amounts,
        uint256[] memory prices,
        uint256[] memory expiries
    );

    function getListing(uint256 tokenId, address seller) external view returns (Listing memory);

    // ==========================
    // 🔹 Marketplace Analytics
    // ==========================
    function getMarketPerformance(uint256 tokenId) external view returns (MarketStats memory);

    function getTotalMarketplaceVolume() external view returns (uint256);

    function getSellThroughRate(uint256 tokenId) external view returns (uint256 percentage);

    function getActiveListingsCount() external view returns (uint256);

    function calculateRewards(address user) external view returns (uint256);

    // ==========================
    // 🔹 Reward System
    // ==========================
    function claimRewards() external;

    function getPendingRewards(address user) external view returns (uint256);

    function replenishRewardPool(uint256 amount) external;

    function getRewardPoolBalance() external view returns (uint256);

    // ==========================
    // 🔹 Governance & Risk Controls (Admin Only)
    // ==========================
    function toggleAutoRiskMonitoring() external;

    function updateRoyaltyFee(uint256 newRoyalty) external;

    function emergencyPauseMarketplace() external;

    function resumeMarketplace() external;

    function getMarketplaceStatus() external view returns (
        bool isPaused,
        bool isRiskMonitoringEnabled,
        uint256 currentRoyaltyFee
    );

    // ==========================
    // 🔹 Events
    // ==========================
    event NFTListed(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 amount,
        uint256 startPrice,
        uint256 endPrice,
        uint256 interval,
        uint256 expiry
    );
    
    event NFTPurchased(
        uint256 indexed tokenId,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        uint256 price
    );
    
    event NFTDelisted(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 timestamp
    );
    
    event TradingVolumeUpdated(
        uint256 tokenId,
        uint256 newVolume,
        uint256 timestamp
    );
    
    event RewardPoolReplenished(
        address indexed by,
        uint256 amount,
        uint256 newBalance
    );
    
    event RewardsClaimed(
        address indexed user,
        uint256 amount,
        uint256 timestamp
    );
    
    event AutoRiskMonitoringUpdated(
        bool status,
        address indexed by,
        uint256 timestamp
    );
    
    event RoyaltyFeeUpdated(
        uint256 oldRoyalty,
        uint256 newRoyalty,
        address indexed by
    );
    
    event MarketplacePaused(
        address indexed by,
        uint256 timestamp
    );
    
    event MarketplaceResumed(
        address indexed by,
        uint256 timestamp
    );
}
