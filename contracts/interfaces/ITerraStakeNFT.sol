// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITerraStakeNFT {
    // ====================================================
    // 🔹 Governance & Roles
    // ====================================================
    function MINTER_ROLE() external view returns (bytes32);
    function GOVERNANCE_ROLE() external view returns (bytes32);

    // ====================================================
    // 🔹 Token & Liquidity References
    // ====================================================
    function tStakeToken() external view returns (address);
    function TERRA_POOL() external view returns (address);
    function positionManager() external view returns (address);
    function uniswapPool() external view returns (address);
    function POOL_FEE() external pure returns (uint24);

    function totalMinted() external view returns (uint256);
    function mintFee() external view returns (uint256);
    function liquidityReinvestmentRate() external view returns (uint256);

    // ====================================================
    // 🔹 NFT Metadata Structure (With Impact Tracking)
    // ====================================================
    struct NFTMetadata {
        string uri;
        uint256 projectId;
        uint256 impactValue;       // Updated impact metrics
        bool isTradable;
        string location;
        uint256 capacity;
        uint256 certificationDate;
        string projectType;
        bool isVerified;
        uint256 version;           // Metadata version tracking
        PerformanceMetrics performance; // Tracks dynamic impact changes
    }

    struct PerformanceMetrics {
        uint256 totalImpact;
        uint256 carbonOffset;
        uint256 efficiencyScore;
        uint256 lastUpdated;
    }

    struct LiquidityLock {
        uint256 unlockStart;
        uint256 unlockEnd;
        uint256 releaseRate;
        bool isLocked;
    }

    // ====================================================
    // 🔹 Minting & NFT Management
    // ====================================================
    function mint(
        address to,
        uint256 projectId,
        uint256 impactValue,
        string memory uri,
        bool isTradable,
        string memory location,
        uint256 capacity,
        uint256 certificationDate,
        string memory projectType,
        bool isVerified
    ) external;

    function batchMint(
        address to,
        uint256[] memory projectIds,
        uint256[] memory impactValues,
        string[] memory uris,
        bool[] memory isTradableFlags,
        string[] memory locations,
        uint256[] memory capacities,
        uint256[] memory certificationDates,
        string[] memory projectTypes,
        bool[] memory isVerifiedFlags
    ) external;

    function updateMintFee(uint256 newFee) external;

    function updateLiquidityReinvestmentRate(uint256 newRate) external;

    function fractionalize(uint256 tokenId, uint256 amount) external;

    function burnNFT(uint256 tokenId) external;

    // ====================================================
    // 🔹 Liquidity & Locking
    // ====================================================
    function lockLiquidity(
        uint256 tokenId,
        uint256 unlockStart,
        uint256 unlockEnd,
        uint256 releaseRate
    ) external;

    function withdrawLiquidity(uint256 tokenId, uint256 amount) external;

    function whitelistAddress(address user, bool status) external;

    // ====================================================
    // 🔹 Metadata & Impact Tracking
    // ====================================================
    function getNFTMetadata(uint256 tokenId)
        external
        view
        returns (
            string memory uri,
            uint256 projectId,
            uint256 impactValue,
            bool isTradable,
            string memory location,
            uint256 capacity,
            uint256 certificationDate,
            string memory projectType,
            bool isVerified,
            uint256 version,
            PerformanceMetrics memory performance
        );

    function getMetadataHistory(uint256 tokenId) external view returns (NFTMetadata[] memory);

    function syncImpactValue(uint256 tokenId) external;

    function updatePerformanceMetrics(
        uint256 tokenId,
        uint256 totalImpact,
        uint256 carbonOffset,
        uint256 efficiencyScore
    ) external;

    // ====================================================
    // 🔹 View Functions
    // ====================================================
    function getLiquidityLock(uint256 tokenId)
        external
        view
        returns (
            uint256 unlockStart,
            uint256 unlockEnd,
            uint256 releaseRate,
            bool isLocked
        );

    function getUniqueOwner(uint256 tokenId) external view returns (address);

    function isFractionalized(uint256 tokenId) external view returns (bool);

    function liquidityWhitelist(address user) external view returns (bool);

    // ====================================================
    // 🔹 Chainlink VRF Functions
    // ====================================================
    function requestRandomUnlockTime(uint256 tokenId) external;

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external;

    function keyHash() external view returns (bytes32);
    function subscriptionId() external view returns (uint64);

    // ====================================================
    // 🔹 Metadata & Admin Functions
    // ====================================================
    function uri(uint256 tokenId) external view returns (string memory);

    function updateMetadata(uint256 tokenId, string memory newUri) external;

    function setMintFee(uint256 newFee) external;

    function setLiquidityReinvestmentRate(uint256 newRate) external;

    // ====================================================
    // 🔹 Events
    // ====================================================
    event NFTMinted(
        address indexed to,
        uint256 indexed tokenId,
        uint256 projectId,
        uint256 impactValue,
        string uri,
        bool isTradable,
        string location,
        uint256 capacity,
        uint256 certificationDate,
        string projectType,
        bool isVerified
    );

    event BatchNFTMinted(address indexed to, uint256[] tokenIds);

    event NFTFractionalized(uint256 indexed tokenId, address indexed owner, uint256 amount);

    event NFTBurned(uint256 indexed tokenId);

    event LiquidityLocked(uint256 indexed tokenId, uint256 unlockStart, uint256 unlockEnd, uint256 releaseRate);

    event LiquidityWithdrawn(uint256 indexed tokenId, uint256 amount);

    event MetadataUpdated(uint256 indexed tokenId, string newUri, uint256 version);

    event PerformanceMetricsUpdated(
        uint256 indexed tokenId,
        uint256 totalImpact,
        uint256 carbonOffset,
        uint256 efficiencyScore,
        uint256 lastUpdated
    );

    event ImpactValueSynced(uint256 indexed tokenId, uint256 newImpactValue);

    event FeesWithdrawn(address indexed recipient, uint256 amount);

    event RandomUnlockTimeRequested(uint256 indexed tokenId, uint256 requestId);

    event LiquidityReinvested(uint256 amount);

    event MintFeeUpdated(uint256 newFee);

    event LiquidityReinvestmentRateUpdated(uint256 newRate);
}
