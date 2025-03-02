// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title ITerraStakeFractionalizer
 * @dev Interface for TerraStake NFT fractionalization contract
 * @notice This interface supports the fractionalization of impact NFTs into tradable ERC-20 tokens
 * with TSTAKE as the ecosystem token
 */
interface ITerraStakeFractionalizer is IERC165 {
    // ====================================================
    // 🔹 Structs
    // ====================================================
    
    /**
     * @dev Struct to store vault information for a fractionalized NFT
     */
    struct Vault {
        uint256 tokenId;             // Original NFT token ID
        uint256 projectId;           // Project ID associated with the NFT
        address nftContract;         // Address of the NFT contract
        address originalOwner;       // Original owner who fractionalized the NFT
        address fractionsToken;      // ERC-20 token address representing fractions
        uint256 totalSupply;         // Total supply of fraction tokens
        uint256 fractionPrice;       // Initial price per fraction in TSTAKE
        uint256 reservePrice;        // Minimum price to buy back the entire NFT in TSTAKE
        bool isActive;               // Whether the vault is currently active
        uint256 creationTime;        // When the vault was created
        bool isRedeemable;           // Whether the NFT can be redeemed
        string name;                 // Name of the fractions token
        string symbol;               // Symbol of the fractions token
    }

    // ====================================================
    // 🔹 Events
    // ====================================================
    
    /**
     * @dev Emitted when a new NFT is fractionalized
     */
    event NFTFractionalized(
        uint256 indexed vaultId,
        uint256 indexed tokenId,
        uint256 indexed projectId,
        address nftContract,
        address fractionToken,
        uint256 totalSupply,
        address owner
    );
    
    /**
     * @dev Emitted when an NFT is redeemed (all fractions recombined)
     */
    event NFTRedeemed(
        uint256 indexed vaultId,
        uint256 indexed tokenId,
        address indexed redeemer,
        uint256 redemptionPriceInTSTAKE
    );
    
    /**
     * @dev Emitted when fractions are purchased
     */
    event FractionsPurchased(
        uint256 indexed vaultId,
        address indexed buyer,
        uint256 amount,
        uint256 tstakeAmount
    );
    
    /**
     * @dev Emitted when a curator fee is distributed
     */
    event CuratorFeeDistributed(
        uint256 indexed vaultId,
        address indexed curator,
        uint256 tstakeAmount
    );
    
    /**
     * @dev Emitted when impact rewards are distributed to fraction holders
     */
    event ImpactRewardsDistributed(
        uint256 indexed vaultId,
        uint256 totalTSTAKEAmount,
        uint256 holderCount
    );
    
    /**
     * @dev Emitted when the TSTAKE token address is updated
     */
    event TSTAKETokenUpdated(address indexed newTSTAKEToken);
    
    /**
     * @dev Emitted when a buyout offer is made
     */
    event BuyoutOfferMade(
        uint256 indexed vaultId,
        address indexed bidder,
        uint256 tstakeAmount
    );

    // ====================================================
    // 🔹 Core Fractionalization Functions
    // ====================================================
    
    /**
     * @dev Fractionalizes an NFT into ERC-20 tokens
     * @param tokenId The ID of the NFT to fractionalize
     * @param nftContract The address of the NFT contract
     * @param name The name for the fraction token
     * @param symbol The symbol for the fraction token
     * @param totalSupply The total number of fractions to create
     * @param fractionPriceInTSTAKE The initial price per fraction in TSTAKE
     * @param reservePriceInTSTAKE The reserve price for buyout in TSTAKE
     * @return vaultId The ID of the newly created vault
     * @return fractionToken The address of the ERC-20 token representing fractions
     */
    function fractionalizeNFT(
        uint256 tokenId,
        address nftContract,
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        uint256 fractionPriceInTSTAKE,
        uint256 reservePriceInTSTAKE
    ) external returns (uint256 vaultId, address fractionToken);
    
    /**
     * @dev Fractionalizes a TerraStake impact NFT
     * @param tokenId The ID of the impact NFT to fractionalize
     * @param name The name for the fraction token
     * @param symbol The symbol for the fraction token
     * @param totalSupply The total number of fractions to create
     * @param fractionPriceInTSTAKE The initial price per fraction in TSTAKE
     * @param reservePriceInTSTAKE The reserve price for buyout in TSTAKE
     * @return vaultId The ID of the newly created vault
     * @return fractionToken The address of the ERC-20 token representing fractions
     */
    function fractionalizeImpactNFT(
        uint256 tokenId,
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        uint256 fractionPriceInTSTAKE,
        uint256 reservePriceInTSTAKE
    ) external returns (uint256 vaultId, address fractionToken);
    
    /**
     * @dev Purchases fractions of a fractionalized NFT using TSTAKE
     * @param vaultId The ID of the vault
     * @param amount The number of fractions to purchase
     * @param maxTSTAKEAmount The maximum amount of TSTAKE to spend
     */
    function purchaseFractions(uint256 vaultId, uint256 amount, uint256 maxTSTAKEAmount) external;
    
    /**
     * @dev Redeems an NFT by burning all fraction tokens
     * @param vaultId The ID of the vault to redeem
     */
    function redeemNFT(uint256 vaultId) external;
    
    /**
     * @dev Makes a buyout offer for a fractionalized NFT using TSTAKE
     * @param vaultId The ID of the vault
     * @param tstakeAmount The amount of TSTAKE offered for buyout
     */
    function makeBuyoutOffer(uint256 vaultId, uint256 tstakeAmount) external;
    
    /**
     * @dev Accepts a buyout offer if conditions are met
     * @param vaultId The ID of the vault
     */
    function acceptBuyoutOffer(uint256 vaultId) external;
    
    /**
     * @dev Cancels a buyout offer made by the caller
     * @param vaultId The ID of the vault
     */
    function cancelBuyoutOffer(uint256 vaultId) external;

    // ====================================================
    // 🔹 Reward and Fee Functions
    // ====================================================
    
    /**
     * @dev Distributes impact rewards in TSTAKE to fraction holders
     * @param vaultId The ID of the vault
     * @param tstakeRewardAmount The total amount of TSTAKE to distribute
     */
    function distributeImpactRewards(uint256 vaultId, uint256 tstakeRewardAmount) external;
    
    /**
     * @dev Claims accumulated TSTAKE rewards for a fraction holder
     * @param vaultId The ID of the vault
     */
    function claimFractionRewards(uint256 vaultId) external;
    
    /**
     * @dev Calculates the curator fee in TSTAKE for a transaction
     * @param tstakeAmount The transaction amount in TSTAKE
     * @return fee The calculated curator fee in TSTAKE
     */
    function calculateCuratorFee(uint256 tstakeAmount) external view returns (uint256 fee);
    
    /**
     * @dev Distributes curator fees in TSTAKE to the original NFT owner
     * @param vaultId The ID of the vault
     * @param tstakeAmount The amount of TSTAKE to distribute
     */
    function distributeCuratorFee(uint256 vaultId, uint256 tstakeAmount) external;

    // ====================================================
    // 🔹 Administrative Functions
    // ====================================================
    
    /**
     * @dev Sets the TerraStake token (TSTAKE) address
     * @param newTSTAKEToken The address of the TSTAKE token contract
     */
    function setTSTAKEToken(address newTSTAKEToken) external;
    
    /**
     * @dev Sets the NFT contract address
     * @param newNFTContract The address of the new NFT contract
     */
    function setNFTContract(address newNFTContract) external;
    
    /**
     * @dev Sets the projects contract address
     * @param newProjectsContract The address of the new projects contract
     */
    function setProjectsContract(address newProjectsContract) external;
    
    /**
     * @dev Updates the curator fee percentage
     * @param newFeePercentage The new fee percentage (in basis points)
     */
    function setCuratorFee(uint256 newFeePercentage) external;
    
    /**
     * @dev Updates the redemption status of a vault
     * @param vaultId The ID of the vault
     * @param isRedeemable Whether the vault is redeemable
     */
    function setVaultRedeemable(uint256 vaultId, bool isRedeemable) external;
    
    /**
     * @dev Pauses all fractionalization operations
     */
    function pause() external;
    
    /**
     * @dev Unpauses all fractionalization operations
     */
    function unpause() external;
    
    /**
     * @dev Recovers TSTAKE tokens sent to the contract by mistake
     * @param recipient The address to send the tokens to
     * @param amount The amount of TSTAKE to recover
     */
    function recoverTSTAKE(address recipient, uint256 amount) external;
    
    /**
     * @dev Recovers ERC-20 tokens sent to the contract by mistake
     * @param tokenAddress The address of the token contract
     * @param recipient The address to send the tokens to
     * @param amount The amount of tokens to recover
     */
    function recoverERC20(address tokenAddress, address recipient, uint256 amount) external;

    // ====================================================
    // 🔹 View Functions
    // ====================================================
    
    /**
     * @dev Returns the TSTAKE token address
     * @return The address of the TSTAKE token contract
     */
    function tstakeToken() external view returns (address);
    
    /**
     * @dev Returns the NFT contract address
     * @return The address of the NFT contract
     */
    function nftContract() external view returns (address);
    
    /**
     * @dev Returns the projects contract address
     * @return The address of the projects contract
     */
    function projectsContract() external view returns (address);
    
    /**
     * @dev Gets vault information
     * @param vaultId The ID of the vault
     * @return Vault struct containing the vault information
     */
    function getVault(uint256 vaultId) external view returns (Vault memory);
    
    /**
     * @dev Gets the current buyout offer for a vault
     * @param vaultId The ID of the vault
     * @return bidder The address of the bidder
     * @return tstakeAmount The offer amount in TSTAKE
     * @return timestamp The timestamp of the offer
     */
    function getBuyoutOffer(uint256 vaultId) external view returns (address bidder, uint256 tstakeAmount, uint256 timestamp);
    
    /**
     * @dev Calculates the current buyout price in TSTAKE for a vault
     * @param vaultId The ID of the vault
     * @return price The current buyout price in TSTAKE
     */
    function calculateBuyoutPrice(uint256 vaultId) external view returns (uint256 price);
    
    /**
     * @dev Checks if a user holds fractions of a vault
     * @param vaultId The ID of the vault
     * @param user The address of the user
     * @return True if the user holds fractions, false otherwise
     */
    function isVaultFractionHolder(uint256 vaultId, address user) external view returns (bool);
    
    /**
     * @dev Gets the fraction balance of a user for a vault
     * @param vaultId The ID of the vault
     * @param user The address of the user
     * @return The number of fractions held
     */
    function getFractionBalance(uint256 vaultId, address user) external view returns (uint256);
    
    /**
     * @dev Gets the accumulated TSTAKE rewards for a fraction holder
     * @param vaultId The ID of the vault
     * @param holder The address of the fraction holder
     * @return The accumulated TSTAKE rewards
     */
    function getAccumulatedTSTAKERewards(uint256 vaultId, address holder) external view returns (uint256);
    
    /**
     * @dev Gets the TSTAKE price for a specific number of fractions
     * @param vaultId The ID of the vault
     * @param fractionAmount The number of fractions
     * @return The price in TSTAKE
     */
    function getTSTAKEPriceForFractions(uint256 vaultId, uint256 fractionAmount) external view returns (uint256);
    
    /**
     * @dev Gets all vaults for a specific project
     * @param projectId The ID of the project
     * @return Array of vault IDs
     */
    function getVaultsByProject(uint256 projectId) external view returns (uint256[] memory);
    
    /**
     * @dev Gets all vaults with impact rewards available in TSTAKE
     * @return Array of vault IDs with available rewards
     */
    function getVaultsWithAvailableRewards() external view returns (uint256[] memory);
}
