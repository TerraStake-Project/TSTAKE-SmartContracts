// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title ITerraStakeMarketplace
 * @notice Interface for the TerraStake NFT Marketplace with fixed-price and auction functionalities.
 */
interface ITerraStakeMarketplace is UUPSUpgradeable {
    // ==========================
    // 🔹 Structs
    // ==========================
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
    /**
     * @notice Lists an NFT for sale, either as a fixed price or an auction.
     * @param tokenId The ID of the NFT to list.
     * @param amount The amount of NFTs to list.
     * @param price The fixed price or starting bid amount.
     * @param isAuction Whether this is an auction (true) or fixed-price sale (false).
     * @param expiry The expiration time of the listing.
     */
    function listNFT(
        uint256 tokenId,
        uint256 amount,
        uint256 price,
        bool isAuction,
        uint256 expiry
    ) external;

    /**
     * @notice Cancels an active listing.
     * @param tokenId The ID of the NFT listing to cancel.
     */
    function cancelListing(uint256 tokenId) external;

    /**
     * @notice Purchases a listed NFT at its fixed price.
     * @param tokenId The ID of the NFT to purchase.
     * @param seller The address of the seller.
     */
    function buyNow(uint256 tokenId, address seller) external;

    /**
     * @notice Places a bid on an NFT that is in auction mode.
     * @param tokenId The NFT's token ID.
     * @param seller The seller's address.
     * @param bidAmount The bid amount in TSTAKE tokens.
     */
    function placeBid(uint256 tokenId, address seller, uint256 bidAmount) external;

    /**
     * @notice Finalizes the auction and transfers the NFT to the highest bidder.
     * @param tokenId The NFT's token ID.
     * @param seller The seller's address.
     */
    function finalizeAuction(uint256 tokenId, address seller) external;

    // ==========================
    // 🔹 Marketplace Analytics
    // ==========================
    /**
     * @notice Gets the total marketplace trading volume.
     * @return Total volume in TSTAKE tokens.
     */
    function getTotalMarketplaceVolume() external view returns (uint256);

    /**
     * @notice Gets market statistics for a specific NFT.
     * @param tokenId The NFT's token ID.
     * @return MarketStats struct containing detailed statistics.
     */
    function getMarketPerformance(uint256 tokenId) external view returns (MarketStats memory);

    /**
     * @notice Retrieves all active listings from a seller.
     * @param seller The seller's address.
     * @return tokenIds List of token IDs.
     * @return amounts List of token amounts.
     * @return prices List of current listing prices.
     * @return expiries List of listing expiry timestamps.
     */
    function getSellerListings(address seller) external view returns (
        uint256[] memory tokenIds,
        uint256[] memory amounts,
        uint256[] memory prices,
        uint256[] memory expiries
    );

    /**
     * @notice Calculates sell-through rate for an NFT.
     * @param tokenId The NFT's token ID.
     * @return percentage Sell-through rate (0-10000, representing 0-100%).
     */
    function getSellThroughRate(uint256 tokenId) external view returns (uint256 percentage);

    /**
     * @notice Retrieves details of a specific listing.
     * @param tokenId The NFT's token ID.
     * @param seller The seller's address.
     * @return Listing struct containing all listing details.
     */
    function getListing(uint256 tokenId, address seller) external view returns (Listing memory);

    // ==========================
    // 🔹 Reward System
    // ==========================
    /**
     * @notice Claims accumulated rewards.
     */
    function claimRewards() external;

    /**
     * @notice Retrieves unclaimed rewards for a user.
     * @param user The user's address.
     * @return Unclaimed reward amount.
     */
    function getPendingRewards(address user) external view returns (uint256);

    /**
     * @notice Replenishes the reward pool.
     * @param amount Amount of TSTAKE tokens to add.
     */
    function replenishRewardPool(uint256 amount) external;

    /**
     * @notice Gets the current balance of the reward pool.
     * @return The total reward pool balance.
     */
    function getRewardPoolBalance() external view returns (uint256);

    // ==========================
    // 🔹 Governance & Market Controls
    // ==========================
    /**
     * @notice Updates the market state (Active, Suspended, or Emergency).
     * @param newState The new market state.
     */
    function updateMarketState(uint8 newState) external;

    /**
     * @notice Updates the royalty fee percentage.
     * @param newRoyalty New fee (0-1000, representing 0-10%).
     */
    function updateRoyaltyFee(uint256 newRoyalty) external;

    /**
     * @notice Emergency pause for the marketplace.
     */
    function emergencyPauseMarketplace() external;

    /**
     * @notice Resumes marketplace operations.
     */
    function resumeMarketplace() external;

    /**
     * @notice Gets the current marketplace status.
     * @return isPaused Whether the marketplace is paused.
     * @return currentRoyaltyFee The current royalty fee percentage.
     */
    function getMarketplaceStatus() external view returns (
        bool isPaused,
        uint256 currentRoyaltyFee
    );

    // ==========================
    // 🔹 Events
    // ==========================
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

    event TradingVolumeUpdated(
        uint256 indexed tokenId,
        uint256 newVolume
    );

    event RewardPoolReplenished(
        address indexed by,
        uint256 amount
    );

    event RewardsClaimed(
        address indexed user,
        uint256 amount
    );

    event MarketStateChanged(
        uint8 newState
    );

    event RoyaltyFeeUpdated(
        uint256 oldRoyalty,
        uint256 newRoyalty
    );

    event MarketplacePaused(
        address indexed by
    );

    event MarketplaceResumed(
        address indexed by
    );
}
