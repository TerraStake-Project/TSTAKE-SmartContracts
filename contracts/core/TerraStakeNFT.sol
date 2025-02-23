// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "../interfaces/ITerraStakeProjects.sol";

interface ITerraStakeToken {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract TerraStakeNFT is ERC1155, AccessControl, ReentrancyGuard, VRFConsumerBaseV2 {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    ITerraStakeToken public immutable tStakeToken;
    ITerraStakeProjects public immutable terraStakeProjects;
    address public immutable TERRA_POOL;

    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Pool public immutable uniswapPool;
    uint24 public constant POOL_FEE = 3000;

    uint256 public totalMinted;
    uint256 public mintFee;
    uint256 public liquidityReinvestmentRate = 5; // 5% reinvestment

    struct PerformanceMetrics {
        uint256 totalImpact;
        uint256 carbonOffset;
        uint256 efficiencyScore;
        uint256 lastUpdated;
    }

    struct NFTMetadata {
        string uri;
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
    }

    struct LiquidityLock {
        uint256 unlockStart;
        uint256 unlockEnd;
        uint256 releaseRate;
        bool isLocked;
    }

    mapping(uint256 => NFTMetadata) private _nftMetadata;
    mapping(uint256 => address) private _uniqueOwners;
    mapping(uint256 => bool) private _isFractionalized;
    mapping(uint256 => LiquidityLock) private _liquidityLocks;
    mapping(address => bool) public liquidityWhitelist;
    mapping(uint256 => NFTMetadata[]) public metadataHistory; // Metadata versioning

    VRFCoordinatorV2Interface internal vrfCoordinator;
    bytes32 public keyHash;
    uint64 public subscriptionId;

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
    event MetadataUpdated(uint256 indexed tokenId, string newUri, uint256 version);
    event PerformanceMetricsUpdated(uint256 indexed tokenId, uint256 totalImpact, uint256 carbonOffset, uint256 efficiencyScore);
    event ImpactValueSynced(uint256 indexed tokenId, uint256 newImpactValue);

    // ====================================================
    // 🔹 Constructor
    // ====================================================
    constructor(
        address _tStakeToken,
        address _terraStakeProjects,
        uint256 _initialMintFee,
        address _positionManager,
        address _uniswapPool,
        address _terraPool,
        address _vrfCoordinator,
        bytes32 _keyHash,
        uint64 _subscriptionId
    ) ERC1155("https://metadata.terrastake.com/{id}.json") VRFConsumerBaseV2(_vrfCoordinator) {
        require(_tStakeToken != address(0), "Invalid TSTAKE token address");
        require(_terraStakeProjects != address(0), "Invalid TerraStakeProjects address");

        tStakeToken = ITerraStakeToken(_tStakeToken);
        terraStakeProjects = ITerraStakeProjects(_terraStakeProjects);
        positionManager = INonfungiblePositionManager(_positionManager);
        uniswapPool = IUniswapV3Pool(_uniswapPool);
        TERRA_POOL = _terraPool;

        _grantRole(DEFAULT_ADMIN_ROLE, TERRA_POOL);
        _grantRole(MINTER_ROLE, TERRA_POOL);
        _grantRole(GOVERNANCE_ROLE, TERRA_POOL);

        mintFee = _initialMintFee;
        vrfCoordinator = VRFCoordinatorV2Interface(_vrfCoordinator);
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;
    }

    // ====================================================
    // 🔹 NFT Management
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
    ) external nonReentrant onlyRole(MINTER_ROLE) {
        require(to != address(0), "Invalid recipient");

        uint256 tokenId = ++totalMinted;
        _mint(to, tokenId, 1, "");
        _uniqueOwners[tokenId] = to;

        NFTMetadata memory newMetadata = NFTMetadata({
            uri: uri,
            projectId: projectId,
            impactValue: impactValue,
            isTradable: isTradable,
            location: location,
            capacity: capacity,
            certificationDate: certificationDate,
            projectType: projectType,
            isVerified: isVerified,
            version: 1,
            performance: PerformanceMetrics(0, 0, 0, block.timestamp)
        });

        _nftMetadata[tokenId] = newMetadata;
        metadataHistory[tokenId].push(newMetadata);

        emit NFTMinted(to, tokenId, projectId, impactValue, uri, isTradable, location, capacity, certificationDate, projectType, isVerified);
    }

    function syncImpactValue(uint256 tokenId) external {
        require(_uniqueOwners[tokenId] != address(0), "NFT does not exist");

        uint256 newImpact = terraStakeProjects.getProjectAnalytics(_nftMetadata[tokenId].projectId).totalImpact;
        _nftMetadata[tokenId].impactValue = newImpact;
        emit ImpactValueSynced(tokenId, newImpact);
    }

    function updatePerformanceMetrics(uint256 tokenId, uint256 totalImpact, uint256 carbonOffset, uint256 efficiencyScore) external onlyRole(GOVERNANCE_ROLE) {
        NFTMetadata storage metadata = _nftMetadata[tokenId];
        metadata.performance = PerformanceMetrics(totalImpact, carbonOffset, efficiencyScore, block.timestamp);
        emit PerformanceMetricsUpdated(tokenId, totalImpact, carbonOffset, efficiencyScore);
    }

    function updateMetadata(uint256 tokenId, string memory newUri) external onlyRole(GOVERNANCE_ROLE) {
        NFTMetadata storage metadata = _nftMetadata[tokenId];
        metadata.uri = newUri;
        metadata.version++;

        metadataHistory[tokenId].push(metadata);
        emit MetadataUpdated(tokenId, newUri, metadata.version);
    }

    function getMetadataHistory(uint256 tokenId) external view returns (NFTMetadata[] memory) {
        return metadataHistory[tokenId];
    }
}
