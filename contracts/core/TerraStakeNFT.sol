// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "../interfaces/ITerraStakeProjects.sol";

interface ITerraStakeToken {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function burn(address account, uint256 amount) external;
}

contract TerraStakeNFT is ERC1155, AccessControl, ReentrancyGuard, VRFConsumerBaseV2 {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    uint256 private constant MAX_BATCH_SIZE = 100;
    uint256 private constant CACHE_VALIDITY_PERIOD = 7 days;
    uint24 public constant POOL_FEE = 3000;

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
        uint256 mintingFee;
    }

    // External contracts and interfaces.
    ITerraStakeToken public immutable tStakeToken;
    ITerraStakeProjects public immutable terraStakeProjects;
    address public immutable TERRA_POOL;
    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Pool public immutable uniswapPool;
    address public immutable treasuryWallet;
    address public immutable stakingRewards; // New variable for staking rewards
    VRFCoordinatorV2Interface internal vrfCoordinator;

    uint256 public totalMinted;
    uint256 public mintFee;
    FeeDistribution public feeDistribution;
    bytes32 public keyHash;
    uint64 public subscriptionId;

    // Mappings for NFT metadata, randomness, project hashes, and cache.
    mapping(uint256 => NFTMetadata) private _nftMetadata;
    mapping(address => bool) public liquidityWhitelist;
    mapping(uint256 => NFTMetadata[]) public metadataHistory;
    mapping(uint256 => uint256) private _cachedProjectImpact;
    mapping(uint256 => uint256) private _lastCacheUpdate;
    mapping(uint256 => uint256) private _randomnessResults;
    mapping(uint256 => bytes32) private _projectHashes; // Stores the approved project hash per token.

    // ================================
    // 🔹 Events
    // ================================
    event NFTMinted(address indexed to, uint256 indexed tokenId, uint256 projectId);
    event MintingFeeUpdated(uint256 newFee);
    event FeeDistributed(uint256 stakingAmount, uint256 liquidityAmount, uint256 treasuryAmount, uint256 burnAmount);
    event RandomnessReceived(uint256 indexed requestId, uint256 randomValue);
    event MetadataUpdated(uint256 indexed tokenId, string newUri, uint256 version);
    event ProjectHashVerified(uint256 indexed tokenId, uint256 indexed projectId, bytes32 projectHash);

    constructor(
        address _tStakeToken,
        address _terraStakeProjects,
        uint256 _initialMintFee,
        address _positionManager,
        address _uniswapPool,
        address _terraPool,
        address _vrfCoordinator,
        bytes32 _keyHash,
        uint64 _subscriptionId,
        address _treasuryWallet,
        address _stakingRewards   // New parameter for staking rewards
    ) ERC1155("https://metadata.terrastake.com/{id}.json") VRFConsumerBaseV2(_vrfCoordinator) {
        require(_tStakeToken != address(0), "Invalid TSTAKE token address");
        require(_terraStakeProjects != address(0), "Invalid TerraStakeProjects address");

        tStakeToken = ITerraStakeToken(_tStakeToken);
        terraStakeProjects = ITerraStakeProjects(_terraStakeProjects);
        positionManager = INonfungiblePositionManager(_positionManager);
        uniswapPool = IUniswapV3Pool(_uniswapPool);
        TERRA_POOL = _terraPool;
        treasuryWallet = _treasuryWallet;
        stakingRewards = _stakingRewards;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);

        mintFee = _initialMintFee;
        vrfCoordinator = VRFCoordinatorV2Interface(_vrfCoordinator);
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;

        feeDistribution = FeeDistribution(40, 25, 20, 15);
    }

    function setMintingFee(uint256 newFee) external onlyRole(GOVERNANCE_ROLE) {
        mintFee = newFee;
        emit MintingFeeUpdated(newFee);
    }

    function distributeMintingFee(uint256 fee) internal nonReentrant {
        uint256 stakingAmount = (fee * feeDistribution.stakingShare) / 100;
        uint256 liquidityAmount = (fee * feeDistribution.liquidityShare) / 100;
        uint256 treasuryAmount = (fee * feeDistribution.treasuryShare) / 100;
        uint256 burnAmount = (fee * feeDistribution.burnShare) / 100;

        tStakeToken.transfer(treasuryWallet, treasuryAmount);
        tStakeToken.burn(address(this), burnAmount);
        emit FeeDistributed(stakingAmount, liquidityAmount, treasuryAmount, burnAmount);
    }

    /// @notice Retrieves verification data for a given project.
    /// @param projectId The project ID.
    /// @return projectHash The IPFS hash of the project data.
    /// @return impactHash The hash of the latest impact report.
    /// @return isVerified Whether the project is verified.
    function getProjectVerification(uint256 projectId) internal view returns (
        bytes32 projectHash,
        bytes32 impactHash,
        bool isVerified
    ) {
        ITerraStakeProjects.ProjectData memory data = terraStakeProjects.getProjectData(projectId);
        ITerraStakeProjects.ImpactReport[] memory reports = terraStakeProjects.getProjectImpactReports(projectId);

        projectHash = data.ipfsHash;
        impactHash = reports.length > 0 ? reports[reports.length - 1].reportHash : bytes32(0);
        isVerified = data.exists && (reports.length > 0);
        return (projectHash, impactHash, isVerified);
    }

    /**
     * @notice Mints a new NFT with verified project data.
     * @param to The recipient address.
     * @param projectId The associated project ID.
     * @param impactValue The impact value of the project.
     * @param uri The metadata URI.
     * @param isTradable Whether the NFT is tradable.
     * @param location Project location.
     * @param capacity Project capacity.
     * @param certificationDate Certification date timestamp.
     * @param projectType Type of the project.
     */
    function mint(
        address to,
        uint256 projectId,
        uint256 impactValue,
        string memory uri,
        bool isTradable,
        string memory location,
        uint256 capacity,
        uint256 certificationDate,
        string memory projectType
    ) external nonReentrant onlyRole(MINTER_ROLE) {
        require(to != address(0), "Invalid recipient");
        require(tStakeToken.transferFrom(msg.sender, address(this), mintFee), "Fee transfer failed");
        
        // Enhanced project verification.
        (bytes32 verifiedProjectHash, bytes32 impactHash, bool verified) = getProjectVerification(projectId);
        require(verified, "Project not verified");
        require(verifiedProjectHash != bytes32(0), "Invalid project hash");
        require(verifyProjectIntegrity(projectId), "Project integrity check failed");

        uint256 tokenId = ++totalMinted;
        _projectHashes[tokenId] = verifiedProjectHash;
        _mint(to, tokenId, 1, "");

        NFTMetadata memory newMetadata = NFTMetadata(
            uri,
            projectId,
            impactValue,
            isTradable,
            location,
            capacity,
            certificationDate,
            projectType,
            verified,
            1,
            PerformanceMetrics(0, 0, 0, block.timestamp),
            mintFee
        );

        _nftMetadata[tokenId] = newMetadata;
        metadataHistory[tokenId].push(newMetadata);

        uint256 requestId = requestRandomness();
        _randomnessResults[tokenId] = requestId;

        distributeMintingFee(mintFee);

        emit NFTMinted(to, tokenId, projectId);
        emit ProjectHashVerified(tokenId, projectId, verifiedProjectHash);
    }

    function requestRandomness() internal returns (uint256) {
        return vrfCoordinator.requestRandomWords(keyHash, subscriptionId, 3, 100000, 1);
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        _randomnessResults[requestId] = randomWords[0];
        emit RandomnessReceived(requestId, randomWords[0]);
    }

    function updateMetadata(uint256 tokenId, string memory newUri) external onlyRole(GOVERNANCE_ROLE) {
        NFTMetadata storage metadata = _nftMetadata[tokenId];
        metadata.uri = newUri;
        metadata.version++;

        metadataHistory[tokenId].push(metadata);
        emit MetadataUpdated(tokenId, newUri, metadata.version);
    }

    // ===================================================
    // Optimizations and Advanced Functions
    // ===================================================

    /// @notice Batch process metadata updates for a list of tokenIds.
    function batchProcessMetadata(uint256[] calldata tokenIds) external onlyRole(GOVERNANCE_ROLE) {
        uint256 length = tokenIds.length;
        require(length <= MAX_BATCH_SIZE, "Batch too large");
        
        for (uint256 i = 0; i < length;) {
            _updateMetadataCache(tokenIds[i]);
            unchecked { ++i; }
        }
    }

    /// @notice Internal function to update metadata cache for a token.
    function _updateMetadataCache(uint256 tokenId) internal {
        _lastCacheUpdate[tokenId] = block.timestamp;
        NFTMetadata storage metadata = _nftMetadata[tokenId];
        // Dummy update: set cached project impact to the current impactValue.
        _cachedProjectImpact[tokenId] = metadata.impactValue;
    }

    /// @notice Enhanced project verification including an active state check.
    function verifyProjectIntegrity(uint256 projectId) internal view returns (bool) {
        (bytes32 projectHash, bytes32 impactHash, bool verified) = getProjectVerification(projectId);
        return verified 
            && projectHash != bytes32(0) 
            && terraStakeProjects.getProjectState(projectId) == ITerraStakeProjects.ProjectState.Active;
    }

    /// @notice Automated liquidity management function.
    function reinvestLiquidity(uint256 amount) internal returns (bool) {
        if (amount == 0) return false;
        tStakeToken.approve(address(positionManager), amount);
        // Insert liquidity management logic as needed.
        return true;
    }

    /// @notice Advanced fee distribution transferring staking rewards.
    function optimizedFeeDistribution(uint256 fee) internal returns (bool) {
        uint256 stakingAmount = (fee * feeDistribution.stakingShare) / 100;
        _addToStakingRewards(stakingAmount);
        return true;
    }

    /// @notice Internal function to add an amount to staking rewards.
    function _addToStakingRewards(uint256 amount) internal {
        require(tStakeToken.transfer(stakingRewards, amount), "Staking reward transfer failed");
    }

    /// @notice Emergency recovery function for tokens other than the stake token.
    function emergencyRecovery(address token) external onlyRole(GOVERNANCE_ROLE) {
        require(token != address(tStakeToken), "Cannot recover stake token");
        IERC20(token).transfer(treasuryWallet, IERC20(token).balanceOf(address(this)));
    }
}
