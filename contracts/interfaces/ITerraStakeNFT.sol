// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

interface ITerraStakeNFT is IERC1155 {
    // ========== Enums & Structs ==========
    enum NFTType {
        STANDARD,
        IMPACT,
        LAND,
        CARBON_LIABILITY,
        BIODIVERSITY,
        POLLUTION_LIABILITY,
        WASTE_LIABILITY,
        WATER_LIABILITY,
        HABITAT_LIABILITY,
        ENERGY_LIABILITY,
        CIRCULARITY_LIABILITY,
        COMMUNITY_LIABILITY
    }

    enum ProjectCategory {
        CarbonCredit,
        RenewableEnergy,
        OceanCleanup,
        Reforestation,
        Biodiversity,
        SustainableAg,
        WasteManagement,
        WaterConservation,
        PollutionControl,
        HabitatRestoration,
        GreenBuilding,
        CircularEconomy,
        CommunityDevelopment
    }

    struct NFTMetadata {
        string name;
        string description;
        uint256 creationTime;
        bool uriIsFrozen;
        NFTType nftType;
        ProjectCategory category;
    }

    struct ImpactCertificate {
        uint256 projectId;
        bytes32 reportHash;
        uint256 impactValue;
        string impactType;
        uint256 verificationDate;
        string location;
        address verifier;
        bool isVerified;
        ProjectCategory category;
        bool isLiability;
    }

    struct FractionInfo {
        uint256 originalTokenId;
        uint256 fractionCount;
        address fractionalizer;
        bool isActive;
        NFTType nftType;
        uint256 projectId;
        bytes32 reportHash;
        ProjectCategory category;
    }

    struct NFTData {
        address owner;
        bool verified;
        uint256 eLiability;
        ProjectCategory category;
        bytes32 auditDataHash;
    }

    // ========== Standard ERC1155 Functions (from IERC1155) ==========
    // These are inherited from IERC1155 but listed here for completeness
    /*
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids) external view returns (uint256[] memory);
    function setApprovalForAll(address operator, bool approved) external;
    function isApprovedForAll(address account, address operator) external view returns (bool);
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
    function safeBatchTransferFrom(address from, address to, uint256[] calldata ids, uint256[] calldata amounts, bytes calldata data) external;
    */

    // ========== ERC1155 Supply Extension ==========
    function totalSupply(uint256 id) external view returns (uint256);

    // ========== Token Management ==========
    event TokenMinted(
        uint256 indexed tokenId,
        address indexed to,
        NFTType nftType,
        ProjectCategory category
    );
    event ImpactCertificateCreated(
        uint256 indexed tokenId,
        uint256 indexed projectId,
        bytes32 reportHash
    );
    event LiabilityCertificateCreated(
        uint256 indexed tokenId,
        uint256 indexed liabilityAmount,
        string liabilityType
    );
    event TokenRetired(
        uint256 indexed tokenId,
        address indexed retiredBy,
        address indexed beneficiary,
        string retirementReason,
        uint256 timestamp
    );

    function mintStandardNFT(
        address to,
        uint256 amount,
        ProjectCategory category,
        string calldata _uri
    ) external returns (uint256);

    function mintImpactNFT(
        address to,
        uint256 projectId,
        string calldata _uri,
        bytes32 reportHash
    ) external returns (uint256);

    function mintLiabilityNFT(
        address to,
        uint256 liabilityAmount,
        string calldata liabilityType,
        string calldata location,
        string calldata _uri
    ) external returns (uint256);

    function mintImpact(
        address to,
        uint256 impactValue,
        ProjectCategory category,
        bytes32 auditDataHash
    ) external returns (uint256 tokenId);

    function verifyImpactCertificate(
        uint256 tokenId,
        uint256 impactValue,
        string calldata impactType,
        string calldata location
    ) external;

    function offsetCarbonLiability(
        uint256 tokenId,
        string calldata retirementReason
    ) external;

    function retireToken(
        uint256 tokenId,
        address beneficiary,
        string calldata retirementReason
    ) external;

    function batchRetireTokens(
        uint256[] calldata tokenIds,
        address beneficiary,
        string calldata retirementReason
    ) external;

    // ========== Fractionalization ==========
    event TokenFractionalized(
        uint256 indexed originalTokenId,
        uint256[] fractionIds,
        uint256 fractionCount
    );
    event TokensReassembled(uint256 indexed originalTokenId, address indexed owner);
    event LiabilityTokenSet(uint256 indexed tokenId, address liabilityToken);

    function fractionalize(uint256 originalTokenId, uint256 fractionCount) 
        external returns (uint256[] memory fractionIds);

    function reassemble(uint256 originalTokenId) external;

    function setLiabilityToken(uint256 originalTokenId, address liabilityToken) external;

    function getFractionTWAPPrice(uint256 originalTokenId) external view returns (uint256);

    // ========== Metadata & URIs ==========
    event TokenURIUpdated(uint256 indexed tokenId, string newUri);
    event TokenURILocked(uint256 indexed tokenId);

    function uri(uint256 tokenId) external view returns (string memory);

    function setTokenURI(uint256 tokenId, string calldata newUri) external;

    function lockTokenURI(uint256 tokenId) external;

    // ========== Royalty Management ==========
    event RoyaltySet(
        uint256 indexed tokenId,
        address receiver,
        uint96 royaltyFraction
    );
    event DefaultRoyaltySet(address receiver, uint96 royaltyFraction);

    function setTokenRoyalty(
        uint256 tokenId,
        address receiver,
        uint96 feeNumerator
    ) external;

    function setDefaultRoyalty(
        address receiver,
        uint96 feeNumerator
    ) external;

    // ========== Fee Management ==========
    event FeesUpdated(
        uint256 mintFee,
        uint256 fractionalizationFee,
        uint256 verificationFee,
        uint256 transferFee,
        uint256 retirementFee
    );
    event FeeDistributionUpdated(
        uint16 burnPercent,
        uint16 treasuryPercent,
        uint16 impactFundPercent,
        uint16 api3FeePercent
    );
    event TreasuryWalletUpdated(address newTreasuryWallet);
    event ImpactFundWalletUpdated(address newImpactFundWallet);
    event API3FeeWalletUpdated(address newApi3FeeWallet);
    event FeesCollected(
        address from,
        uint256 amount,
        uint256 burnAmount,
        uint256 treasuryAmount,
        uint256 impactFundAmount,
        uint256 api3FeeAmount
    );

    function setFeeAmounts(
        uint256 _mintFee,
        uint256 _fractionalizationFee,
        uint256 _verificationFee,
        uint256 _transferFee,
        uint256 _retirementFee
    ) external;

    function setFeeDistribution(
        uint16 _burnPercent,
        uint16 _treasuryPercent,
        uint16 _impactFundPercent,
        uint16 _api3FeePercent
    ) external;

    function setTreasuryWallet(address _treasuryWallet) external;

    function setImpactFundWallet(address _impactFundWallet) external;

    function setAPI3FeeWallet(address _api3FeeWallet) external;

    // ========== API3 Integration ==========
    event CarbonPriceFeedSet(address priceFeed);
    event API3ProxySet(address proxyAddress);

    function setCarbonPriceFeed(address _carbonPriceFeed) external;

    function setAPI3Proxy(address _api3Proxy) external;

    function getCarbonPrice() external view returns (uint256);

    // ========== Liability Manager Integration ==========
    event LiabilityManagerSet(address liabilityManager);
    event TokenStateSync(uint256 indexed tokenId, bytes32 syncHash, uint256 timestamp);

    function setLiabilityManager(address _liabilityManagerAddress) external;

    function emitSyncEvent(uint256 tokenId, bytes32 syncHash) external;

    function getNFTData(uint256 tokenId) external view returns (NFTData memory);

    // ========== Ownership & Utility Functions ==========
    function ownerOf(uint256 tokenId) external view returns (address);

    function exists(uint256 tokenId) external view returns (bool);

    function getTokenMetadata(uint256 tokenId) external view returns (NFTMetadata memory);

    function getImpactCertificate(uint256 tokenId) external view returns (ImpactCertificate memory);

    function getFractionInfo(uint256 tokenId) external view returns (FractionInfo memory);

    function getFractionTokens(uint256 originalTokenId) external view returns (uint256[] memory);

    function getOriginalTokenId(uint256 fractionTokenId) external view returns (uint256);

    function getRetiredTokensByAddress(address owner) external view returns (uint256[] memory);

    function getRetirementDetails(uint256 tokenId)
        external
        view
        returns (
            bool isTokenRetired,
            address beneficiary,
            uint256 retirementDate,
            string memory reason
        );

    function getTokenData(uint256 tokenId) 
        external 
        view 
        returns (
            uint256 impactValue,
            ProjectCategory category,
            bytes32 verificationHash,
            bool isLiability
        );

    function getTokensByCategory(ProjectCategory category)
        external
        view
        returns (uint256[] memory);

    // ========== Emergency Functions ==========
    event EmergencyModeTriggered(address caller);
    event EmergencyModeDisabled(address caller);

    function triggerEmergencyMode() external;

    function disableEmergencyMode() external;

    function pause() external;

    function unpause() external;
}