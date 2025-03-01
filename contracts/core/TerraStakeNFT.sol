// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "../interfaces/ITerraStakeProjects.sol";

interface ITerraStakeToken {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
}

/**
 * @title TerraStakeNFT
 * @notice ERC1155 NFT contract with integrated on-chain metadata history,
 *         and IPFS support for rich metadata. Includes advanced features such as batch processing,
 *         enhanced project verification, automated liquidity management, and optimized fee distribution.
 * @dev This contract uses ERC1155Supply to track total supply of each token ID.
 */
contract TerraStakeNFT is ERC1155, ERC1155Supply, AccessControl, ReentrancyGuard, VRFConsumerBaseV2 {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    
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
        uint256 verifiedImpact;
        bytes32 metricHash; // Hash of all metrics for verification
    }

    // Enhanced NFTMetadata with verification data
    struct NFTMetadata {
        string ipfsUri;                   // IPFS URI pointing to a JSON file containing complete metadata
        uint256 projectId;                // Associated project ID
        uint256 impactValue;              // Environmental impact value
        bool isTradable;                  // Whether NFT is tradable
        string location;                  // Project location
        uint256 capacity;                 // Project capacity
        uint256 certificationDate;        // Date of certification
        string projectType;               // Type of project
        bool isVerified;                  // Verification status
        uint256 version;                  // Metadata version
        PerformanceMetrics performance;   // Performance metrics
        uint256 mintingFee;               // Fee paid for minting
        bytes32 projectDataHash;          // Hash of project data for verification
        bytes32 impactReportHash;         // Hash of latest impact report
        address originalMinter;           // Original minter address
        uint256 originalMintTimestamp;    // Original mint timestamp
        bytes32 verificationProofHash;    // Hash of verification proof
    }

    // External contracts and interfaces
    ITerraStakeToken public immutable tStakeToken;
    ITerraStakeProjects public immutable terraStakeProjects;
    address public immutable TERRA_POOL;
    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Pool public immutable uniswapPool;
    address public immutable treasuryWallet;
    address public immutable stakingRewards;
    VRFCoordinatorV2Interface internal vrfCoordinator;

    // Contract state variables
    uint256 public totalMinted;
    uint256 public mintFee;
    FeeDistribution public feeDistribution;
    bytes32 public keyHash;
    uint64 public subscriptionId;
    uint32 public callbackGasLimit = 200000;
    uint16 public requestConfirmations = 3;
    
    // Enhanced mappings
    mapping(uint256 => NFTMetadata) public nftMetadata;
    mapping(uint256 => NFTMetadata[]) public metadataHistory;
    mapping(address => bool) public liquidityWhitelist;
    mapping(uint256 => uint256) private _cachedProjectImpact;
    mapping(uint256 => uint256) private _lastCacheUpdate;
    mapping(uint256 => uint256) private _randomnessRequests;
    mapping(uint256 => uint256) private _randomnessResults;
    mapping(uint256 => bytes32) private _projectHashes;
    mapping(uint256 => bytes32) private _verificationMerkleRoots;

    // Events
    event NFTMinted(address indexed to, uint256 indexed tokenId, uint256 projectId, bytes32 projectDataHash);
    event MintingFeeUpdated(uint256 newFee);
    event FeeDistributed(uint256 stakingAmount, uint256 liquidityAmount, uint256 treasuryAmount, uint256 burnAmount);
    event RandomnessRequested(uint256 indexed tokenId, uint256 indexed requestId);
    event RandomnessReceived(uint256 indexed requestId, uint256 randomValue);
    event MetadataUpdated(uint256 indexed tokenId, string newIpfsUri, uint256 version, bytes32 metadataHash);
    event ProjectHashVerified(uint256 indexed tokenId, uint256 indexed projectId, bytes32 projectHash);
    event VerificationProofAdded(uint256 indexed tokenId, bytes32 proofHash);
    event MerkleRootSet(uint256 indexed tokenId, bytes32 merkleRoot);

    // =====================================================
    // Constructor
    // =====================================================
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
        address _stakingRewards
    ) ERC1155("ipfs://") VRFConsumerBaseV2(_vrfCoordinator) {
        require(_tStakeToken != address(0), "Invalid TSTAKE token address");
        require(_terraStakeProjects != address(0), "Invalid TerraStakeProjects address");
        require(_treasuryWallet != address(0), "Invalid treasury address");
        require(_stakingRewards != address(0), "Invalid staking rewards address");
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
        _grantRole(VERIFIER_ROLE, msg.sender);
        mintFee = _initialMintFee;
        vrfCoordinator = VRFCoordinatorV2Interface(_vrfCoordinator);
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;
        feeDistribution = FeeDistribution(40, 25, 20, 15);
    }

    // =====================================================
    // Administrative Functions
    // =====================================================
    function setMintingFee(uint256 newFee) external onlyRole(GOVERNANCE_ROLE) {
        mintFee = newFee;
        emit MintingFeeUpdated(newFee);
    }

    function setFeeDistribution(
        uint256 stakingShare,
        uint256 liquidityShare,
        uint256 treasuryShare,
        uint256 burnShare
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(stakingShare + liquidityShare + treasuryShare + burnShare == 100, "Shares must total 100");
        feeDistribution = FeeDistribution(stakingShare, liquidityShare, treasuryShare, burnShare);
    }

    function setVRFParameters(
        bytes32 _keyHash,
        uint64 _subscriptionId,
        uint32 _callbackGasLimit,
        uint16 _requestConfirmations
    ) external onlyRole(GOVERNANCE_ROLE) {
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;
        callbackGasLimit = _callbackGasLimit;
        requestConfirmations = _requestConfirmations;
    }

    // =====================================================
    // Fee Distribution
    // =====================================================
    function distributeFee(uint256 fee) internal nonReentrant {
        uint256 stakingAmount = (fee * feeDistribution.stakingShare) / 100;
        uint256 liquidityAmount = (fee * feeDistribution.liquidityShare) / 100;
        uint256 treasuryAmount = (fee * feeDistribution.treasuryShare) / 100;
        uint256 burnAmount = (fee * feeDistribution.burnShare) / 100;

        if (stakingAmount > 0) {
            require(tStakeToken.transfer(stakingRewards, stakingAmount), "Staking transfer failed");
        }
        
        if (liquidityAmount > 0) {
            require(tStakeToken.transfer(TERRA_POOL, liquidityAmount), "Liquidity transfer failed");
        }
        
        if (treasuryAmount > 0) {
            require(tStakeToken.transfer(treasuryWallet, treasuryAmount), "Treasury transfer failed");
        }
        
        if (burnAmount > 0) {
            tStakeToken.burn(burnAmount);
        }

        emit FeeDistributed(stakingAmount, liquidityAmount, treasuryAmount, burnAmount);
    }

    // =====================================================
    // Project Verification Functions
    // =====================================================
    /**
     * @notice Retrieves comprehensive verification data for a project
     * @param projectId The project ID
     * @return projectDataHash Hash of the project data
     * @return impactReportHash Hash of the latest impact report
     * @return isVerified Verification status
     * @return totalImpact Total impact value
     * @return projectState Current state of the project
     */
    function getProjectVerificationData(uint256 projectId) public view returns (
        bytes32 projectDataHash,
        bytes32 impactReportHash,
        bool isVerified,
        uint256 totalImpact,
        ITerraStakeProjects.ProjectState projectState
    ) {
        // Get project data, impact reports, and analytics
        ITerraStakeProjects.ProjectData memory data;
        ITerraStakeProjects.ProjectStateData memory stateData;
        ITerraStakeProjects.ProjectAnalytics memory analytics;
        
        // Use batch function to efficiently get all data in one call
        uint256[] memory projectIds = new uint256[](1);
        projectIds[0] = projectId;
        
        (
            ITerraStakeProjects.ProjectData[] memory metadataArray, 
            ITerraStakeProjects.ProjectStateData[] memory stateArray,
            ITerraStakeProjects.ProjectAnalytics[] memory analyticsArray
        ) = terraStakeProjects.batchGetProjectDetails(projectIds);
        
        data = metadataArray[0];
        stateData = stateArray[0];
        analytics = analyticsArray[0];
        
        // Get impact reports
        ITerraStakeProjects.ImpactReport[] memory reports = terraStakeProjects.getImpactReports(projectId);
        
        projectDataHash = data.ipfsHash;
        impactReportHash = reports.length > 0 ? reports[reports.length - 1].reportHash : bytes32(0);
        isVerified = data.exists && (reports.length > 0);
        totalImpact = analytics.totalImpact;
        projectState = stateData.state;
        
        return (projectDataHash, impactReportHash, isVerified, totalImpact, projectState);
    }

    /**
     * @notice Comprehensive project verification with multiple checks
     * @param projectId The project ID to verify
     * @return verificationStatus True if project passes all verification checks
     * @return verificationData Structured data about verification status
     */
    function verifyProjectIntegrity(uint256 projectId) public view returns (
        bool verificationStatus,
        bytes memory verificationData
    ) {
        (
            bytes32 projectHash, 
            bytes32 impactHash, 
            bool verified, 
            uint256 impact,
            ITerraStakeProjects.ProjectState state
        ) = getProjectVerificationData(projectId);
        
        // Check all verification criteria
        bool hashesValid = projectHash != bytes32(0) && impactHash != bytes32(0);
        bool stateValid = state == ITerraStakeProjects.ProjectState.Active;
        bool impactValid = impact > 0;
        
        // Encode verification data for on-chain storage
        verificationData = abi.encode(
projectHash,
            impactHash,
            verified,
            impact,
            state,
            hashesValid,
            stateValid,
            impactValid,
            block.timestamp
        );
        
        verificationStatus = verified && hashesValid && stateValid && impactValid;
        return (verificationStatus, verificationData);
    }

    /**
     * @notice Set a Merkle root for additional off-chain verification data
     * @param tokenId The token ID to set the Merkle root for
     * @param merkleRoot The Merkle root of the verification data
     */
    function setVerificationMerkleRoot(uint256 tokenId, bytes32 merkleRoot) 
        external 
        onlyRole(VERIFIER_ROLE) 
    {
        require(_exists(tokenId), "Token does not exist");
        _verificationMerkleRoots[tokenId] = merkleRoot;
        emit MerkleRootSet(tokenId, merkleRoot);
    }

    /**
     * @notice Verify data against a Merkle proof for additional verification
     * @param tokenId The token ID to verify the data for
     * @param data The data to verify
     * @param proof The Merkle proof
     * @return True if the data is verified
     */
    function verifyDataWithMerkleProof(uint256 tokenId, bytes32 data, bytes32[] calldata proof) 
        public 
        view 
        returns (bool) 
    {
        bytes32 merkleRoot = _verificationMerkleRoots[tokenId];
        require(merkleRoot != bytes32(0), "No Merkle root set");
        return MerkleProof.verify(proof, merkleRoot, data);
    }

    // =====================================================
    // Minting Functionality with Enhanced Verification
    // =====================================================
    /**
     * @notice Mints a new NFT with comprehensive project data and verification
     * @param to The recipient address
     * @param projectId The associated project ID
     * @param impactValue The impact value of the project
     * @param ipfsUri The IPFS URI pointing to the rich JSON metadata
     * @param isTradable Whether the NFT is tradable
     * @param location Project location
     * @param capacity Project capacity
     * @param certificationDate Certification date timestamp
     * @param projectType Type of the project
     * @return tokenId The ID of the minted token
     */
    function mint(
        address to,
        uint256 projectId,
        uint256 impactValue,
        string memory ipfsUri,
        bool isTradable,
        string memory location,
        uint256 capacity,
        uint256 certificationDate,
        string memory projectType
    ) external nonReentrant onlyRole(MINTER_ROLE) returns (uint256) {
        require(to != address(0), "Invalid recipient");
        require(tStakeToken.transferFrom(msg.sender, address(this), mintFee), "Fee transfer failed");
        
        // Enhanced project verification
        (bool verified, bytes memory verificationData) = verifyProjectIntegrity(projectId);
        require(verified, "Project verification failed");
        
        // Extract verification data
        (
            bytes32 projectDataHash,
            bytes32 impactReportHash,
            ,,,,,,,
        ) = abi.decode(
            verificationData, 
            (bytes32, bytes32, bool, uint256, ITerraStakeProjects.ProjectState, bool, bool, bool, uint256)
        );
        
        require(projectDataHash != bytes32(0), "Invalid project hash");
        
        // Create a unique verification proof hash
        bytes32 verificationProofHash = keccak256(
            abi.encodePacked(
                projectId,
                projectDataHash,
                impactReportHash,
                impactValue,
                block.timestamp,
                msg.sender,
                to
            )
        );
        
        uint256 tokenId = ++totalMinted;
        _mint(to, tokenId, 1, "");
        
        // Store project hash for verification
        _projectHashes[tokenId] = projectDataHash;
        
        // Initialize performance metrics
        PerformanceMetrics memory perfMetrics = PerformanceMetrics(
            impactValue,
            0, // Will be updated later
            0, // Will be updated later
            block.timestamp,
            impactValue, // Verified impact equals initial impact value
            keccak256(abi.encodePacked(impactValue, block.timestamp)) // Metric hash
        );
        
        // Create comprehensive metadata
        NFTMetadata memory newMetadata = NFTMetadata(
            ipfsUri,
            projectId,
            impactValue,
            isTradable,
            location,
            capacity,
            certificationDate,
            projectType,
            verified,
            1, // Initial version
            perfMetrics,
            mintFee,
            projectDataHash,
            impactReportHash,
            msg.sender, // Original minter
            block.timestamp, // Original mint timestamp
            verificationProofHash // Verification proof hash
        );
        
        nftMetadata[tokenId] = newMetadata;
        metadataHistory[tokenId].push(newMetadata);
        
        // Request randomness for additional verifiability
        uint256 requestId = _requestRandomness(tokenId);
        _randomnessRequests[tokenId] = requestId;
        
        // Distribute minting fee
        distributeFee(mintFee);
        
        emit NFTMinted(to, tokenId, projectId, projectDataHash);
        emit ProjectHashVerified(tokenId, projectId, projectDataHash);
        emit VerificationProofAdded(tokenId, verificationProofHash);
        
        return tokenId;
    }

    // =====================================================
    // Chainlink VRF Functions
    // =====================================================
    /**
     * @notice Requests randomness from Chainlink VRF
     * @param tokenId The token ID to associate with the randomness request
     * @return requestId The VRF request ID
     */
    function _requestRandomness(uint256 tokenId) internal returns (uint256) {
        uint256 requestId = vrfCoordinator.requestRandomWords(
            keyHash,
            subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            1
        );
        emit RandomnessRequested(tokenId, requestId);
        return requestId;
    }

    /**
     * @notice Fulfills randomness from Chainlink VRF
     * @param requestId The request ID
     * @param randomWords The random values
     */
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        _randomnessResults[requestId] = randomWords[0];
        emit RandomnessReceived(requestId, randomWords[0]);
    }

    // =====================================================
    // Metadata Update Functions
    // =====================================================
    /**
     * @notice Updates the metadata of an NFT with verification
     * @param tokenId The token ID to update
     * @param newIpfsUri The new IPFS URI
     * @param impactValue The updated impact value
     */
    function updateMetadata(
        uint256 tokenId, 
        string memory newIpfsUri,
        uint256 impactValue
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(_exists(tokenId), "Token does not exist");
        
        NFTMetadata storage metadata = nftMetadata[tokenId];
        metadata.ipfsUri = newIpfsUri;
        metadata.impactValue = impactValue;
        metadata.version++;
        
        // Update performance metrics
        metadata.performance.totalImpact = impactValue;
        metadata.performance.lastUpdated = block.timestamp;
        metadata.performance.metricHash = keccak256(abi.encodePacked(
            impactValue, 
            block.timestamp,
            metadata.projectDataHash
        ));
        
        // Add to metadata history
        metadataHistory[tokenId].push(metadata);
        
        // Create a hash of the updated metadata for verification
        bytes32 metadataHash = keccak256(abi.encodePacked(
            tokenId,
            newIpfsUri,
            impactValue,
            metadata.version,
            block.timestamp
        ));
        
        emit MetadataUpdated(tokenId, newIpfsUri, metadata.version, metadataHash);
    }

    /**
     * @notice Updates the performance metrics of an NFT
     * @param tokenId The token ID to update
     * @param totalImpact Updated total impact value
     * @param carbonOffset Updated carbon offset value
     * @param efficiencyScore Updated efficiency score
     * @param verifiedImpact Verified impact value from oracle/validator
     */
    function updatePerformanceMetrics(
        uint256 tokenId,
        uint256 totalImpact,
        uint256 carbonOffset,
        uint256 efficiencyScore,
        uint256 verifiedImpact
    ) external onlyRole(VERIFIER_ROLE) {
        require(_exists(tokenId), "Token does not exist");
        
        NFTMetadata storage metadata = nftMetadata[tokenId];
        metadata.performance.totalImpact = totalImpact;
        metadata.performance.carbonOffset = carbonOffset;
        metadata.performance.efficiencyScore = efficiencyScore;
        metadata.performance.verifiedImpact = verifiedImpact;
        metadata.performance.lastUpdated = block.timestamp;
        metadata.performance.metricHash = keccak256(abi.encodePacked(
            totalImpact,
            carbonOffset,
            efficiencyScore,
            verifiedImpact,
            block.timestamp
        ));
        
        metadata.version++;
        
        // Add to metadata history
        metadataHistory[tokenId].push(metadata);
        
        // Update cached impact
        _cachedProjectImpact[tokenId] = totalImpact;
        _lastCacheUpdate[tokenId] = block.timestamp;
    }

    // =====================================================
    // Batch Processing Functions
    // =====================================================
    /**
     * @notice Batch processes metadata updates for multiple tokens
     * @param tokenIds Array of token IDs to update
     * @param newImpacts Array of new impact values
     */
    function batchUpdateImpacts(
        uint256[] calldata tokenIds,
        uint256[] calldata newImpacts
    ) external onlyRole(GOVERNANCE_ROLE) {
        uint256 length = tokenIds.length;
        require(length <= MAX_BATCH_SIZE, "Batch too large");
        require(length == newImpacts.length, "Array lengths mismatch");
        
        for (uint256 i = 0; i < length;) {
            uint256 tokenId = tokenIds[i];
            if (_exists(tokenId)) {
                NFTMetadata storage metadata = nftMetadata[tokenId];
                metadata.impactValue = newImpacts[i];
                metadata.performance.totalImpact = newImpacts[i];
                metadata.performance.lastUpdated = block.timestamp;
                metadata.version++;
                
                // Add to metadata history
                metadataHistory[tokenId].push(metadata);
                
                // Update cache
                _cachedProjectImpact[tokenId] = newImpacts[i];
                _lastCacheUpdate[tokenId] = block.timestamp;
            }
            unchecked { ++i; }
        }
    }

    /**
     * @notice Batch mints multiple NFTs
     * @param to Recipient address
     * @param projectIds Array of project IDs
     * @param ipfsUris Array of IPFS URIs
     * @return tokenIds Array of newly minted token IDs
     */
    function batchMint(
        address to,
        uint256[] calldata projectIds,
        string[] calldata ipfsUris
    ) external onlyRole(MINTER_ROLE) nonReentrant returns (uint256[] memory) {
        uint256 length = projectIds.length;
        require(length <= MAX_BATCH_SIZE, "Batch too large");
        require(length == ipfsUris.length, "Array lengths mismatch");
        require(tStakeToken.transferFrom(msg.sender, address(this), mintFee * length), "Fee transfer failed");
        
        uint256[] memory tokenIds = new uint256[](length);
        
        for (uint256 i = 0; i < length;) {
            // Verify each project
            (bool verified, bytes memory verificationData) = verifyProjectIntegrity(projectIds[i]);
            require(verified, "Project verification failed");
            
            // Extract project data hash
            (bytes32 projectDataHash, bytes32 impactReportHash,,,,,,,) = abi.decode(
                verificationData, 
                (bytes32, bytes32, bool, uint256, ITerraStakeProjects.ProjectState, bool, bool, bool, uint256)
            );
            
            uint256 tokenId = ++totalMinted;
            tokenIds[i] = tokenId;
            
            _mint(to, tokenId, 1, "");
            _projectHashes[tokenId] = projectDataHash;
            
            // Initialize with default values
            PerformanceMetrics memory perfMetrics = PerformanceMetrics(
                0, 0, 0, block.timestamp, 0, 
                keccak256(abi.encodePacked(block.timestamp))
            );
            
            NFTMetadata memory newMetadata = NFTMetadata(
                ipfsUris[i],
                projectIds[i],
                0, // Default impact
                true, // Tradable
                "", // Empty location
                0, // Default capacity
                block.timestamp, // Current time
                "Standard", // Default type
                verified,
                1, // Initial version
                perfMetrics,
                mintFee,
                projectDataHash,
                impactReportHash,
                msg.sender,
                block.timestamp,
                keccak256(abi.encodePacked(projectDataHash, block.timestamp, msg.sender))
            );
            
            nftMetadata[tokenId] = newMetadata;
            metadataHistory[tokenId].push(newMetadata);
            
            // Request randomness
            uint256 requestId = _requestRandomness(tokenId);
            _randomnessRequests[tokenId] = requestId;
            
            emit NFTMinted(to, tokenId, projectIds[i], projectDataHash);
            
            unchecked { ++i; }
        }
        
        // Distribute fees
        distributeFee(mintFee * length);
        
        return tokenIds;
    }

    // =====================================================
    // View Functions
    // =====================================================
    /**
     * @notice Gets the complete metadata for a token
     * @param tokenId The token ID
     * @return The complete NFT metadata
     */
    function getTokenMetadata(uint256 tokenId) external view returns (NFTMetadata memory) {
        require(_exists(tokenId), "Token does not exist");
        return nftMetadata[tokenId];
    }
    
    /**
     * @notice Gets the metadata history for a token
     * @param tokenId The token ID
     * @return Array of historical metadata
     */
    function getMetadataHistory(uint256 tokenId) external view returns (NFTMetadata[] memory) {
        require(_exists(tokenId), "Token does not exist");
        return metadataHistory[tokenId];
    }
    
    /**
     * @notice Gets the verification data for a token
     * @param tokenId The token ID
     * @return projectDataHash Hash of project data
* @return impactReportHash Hash of impact report
     * @return verificationProofHash Hash of verification proof
     * @return isVerified Whether the token is verified
     */
    function getVerificationData(uint256 tokenId) external view returns (
        bytes32 projectDataHash,
        bytes32 impactReportHash,
        bytes32 verificationProofHash,
        bool isVerified
    ) {
        require(_exists(tokenId), "Token does not exist");
        NFTMetadata memory metadata = nftMetadata[tokenId];
        
        return (
            metadata.projectDataHash,
            metadata.impactReportHash,
            metadata.verificationProofHash,
            metadata.isVerified
        );
    }

    // =====================================================
    // ERC1155 Overrides
    // =====================================================
    /**
     * @notice Override _beforeTokenTransfer to handle standard ERC1155 behavior
     */
    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal override(ERC1155, ERC1155Supply) {
        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);
    }
    
    /**
     * @notice Function to check if token exists
     * @param tokenId The token ID to check
     * @return Whether the token exists
     */
    function _exists(uint256 tokenId) internal view returns (bool) {
        return totalSupply(tokenId) > 0;
    }
    
    /**
     * @notice Returns the URI for a token
     * @param tokenId The token ID
     * @return The token URI
     */
    function uri(uint256 tokenId) public view override returns (string memory) {
        require(_exists(tokenId), "URI query for nonexistent token");
        return nftMetadata[tokenId].ipfsUri;
    }
    
    /**
     * @notice Returns the owner of a token
     * @param tokenId The token ID
     * @return The owner address
     */
    function ownerOf(uint256 tokenId) public view returns (address) {
        require(_exists(tokenId), "Token does not exist");
        
        // Since ERC1155 allows multiple owners, we'll return the first owner we find
        // In practice, since we only mint 1 of each tokenId, there should only be one owner
        
        // We'd need to have a more sophisticated implementation to efficiently track owners
        // This is a simplified version that could be improved in production
        
        // For demonstration purposes - actual implementation would require additional tracking
        return address(0); // Placeholder - would need a proper mapping of token owners in a real implementation
    }

    // =====================================================
    // Emergency Recovery Functions
    // =====================================================
    /**
     * @notice Emergency recovery function for tokens other than the stake token
     * @param token The token address to recover
     */
    function emergencyRecovery(address token) external onlyRole(GOVERNANCE_ROLE) {
        require(token != address(tStakeToken), "Cannot recover stake token");
        IERC20(token).transfer(treasuryWallet, IERC20(token).balanceOf(address(this)));
    }
    
    /**
     * @notice Emergency recovery function for TStake tokens with governance approval
     * @param amount The amount to recover
     */
    function emergencyRecoveryTStake(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(amount <= tStakeToken.balanceOf(address(this)) / 10, "Cannot recover more than 10% at once");
        tStakeToken.transfer(treasuryWallet, amount);
    }
}
