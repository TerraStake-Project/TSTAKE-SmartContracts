// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ITerraStakeNFT {
    // =====================================================
    // Structs
    // =====================================================
    struct FeeDistribution {
        uint256 stakingShare;
        uint256 liquidityShare;
        uint256 treasuryShare;
        uint256 burnShare;
    }

    struct PerformanceMetrics {
        uint256 totalImpact;
        uint256 carbonOffset;
        uint256 efficiencyScore;
        uint256 lastUpdated;
    }

    struct NFTMetadata {
        string ipfsUri; // IPFS URI pointing to a JSON file containing full, rich metadata.
        uint256 projectId;
        uint256 impactValue;
        bool isTradable;
        string location;
        uint256 capacity;
        uint256 certificationDate;
        string projectType;
        bool isVerified;
        uint256 version;
        PerformanceMetrics performance;
        uint256 mintingFee;
    }

    // =====================================================
    // Events
    // =====================================================
    event NFTMinted(address indexed to, uint256 indexed tokenId, uint256 projectId);
    event MintingFeeUpdated(uint256 newFee);
    event FeeDistributed(uint256 stakingAmount, uint256 liquidityAmount, uint256 treasuryAmount, uint256 burnAmount);
    event RandomnessReceived(uint256 indexed requestId, uint256 randomValue);
    event MetadataUpdated(uint256 indexed tokenId, string newIpfsUri, uint256 version);
    event ProjectHashVerified(uint256 indexed tokenId, uint256 indexed projectId, bytes32 projectHash);

    // =====================================================
    // External Administrative Functions
    // =====================================================
    function setMintingFee(uint256 newFee) external;

    // =====================================================
    // External Minting & Metadata Functions
    // =====================================================
    function mint(
        address to,
        uint256 projectId,
        uint256 impactValue,
        string calldata ipfsUri,
        bool isTradable,
        string calldata location,
        uint256 capacity,
        uint256 certificationDate,
        string calldata projectType
    ) external;

    function updateMetadata(uint256 tokenId, string calldata newIpfsUri) external;

    // =====================================================
    // Optimized & Emergency Functions
    // =====================================================
    function batchProcessMetadata(uint256[] calldata tokenIds) external;
    function emergencyRecovery(address token) external;

    // =====================================================
    // Public State Variable Getters
    // =====================================================
    function tStakeToken() external view returns (address);
    function terraStakeProjects() external view returns (address);
    function TERRA_POOL() external view returns (address);
    function positionManager() external view returns (address);
    function uniswapPool() external view returns (address);
    function treasuryWallet() external view returns (address);
    function stakingRewards() external view returns (address);
    function totalMinted() external view returns (uint256);
    function mintFee() external view returns (uint256);
    function feeDistribution() external view returns (FeeDistribution memory);
    function keyHash() external view returns (bytes32);
    function subscriptionId() external view returns (uint64);
    function liquidityWhitelist(address account) external view returns (bool);
    function metadataHistory(uint256 tokenId) external view returns (NFTMetadata[] memory);
    function POOL_FEE() external view returns (uint24);
}
