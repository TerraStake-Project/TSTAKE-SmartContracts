// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155SupplyUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "../interfaces/ITerraStakeProjects.sol";
import "../interfaces/ITerraStakeMetadataRenderer.sol";

interface ITerraStakeToken {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function burn(uint256 amount) external;
}

/**
 * @title TerraStakeNFT
 * @notice Advanced ERC1155 NFT implementation for TerraStake impact certificates with fractionalization
 * @dev Implements UUPS upgradeable pattern with multiple advanced features
 */
contract TerraStakeNFT is 
    Initializable, 
    ERC1155Upgradeable, 
    ERC1155SupplyUpgradeable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    VRFConsumerBaseV2
{
    // ====================================================
    // ⚠️ Custom Errors
    // ====================================================
    error InvalidRecipient();
    error FeeTransferFailed();
    error VerificationFeeFailed();
    error NotTokenOwner();
    error TokenDoesNotExist();
    error AlreadyVerified();
    error NotImpactNFT();
    error InsufficientBalance();
    error InvalidAmount();
    error ArrayLengthMismatch();
    error ReportAlreadyMinted();
    error InvalidProof();
    error AlreadyClaimed();
    error TotalAmountMismatch();
    error NotActiveToken();
    error NotAllFractionsOwned();
    error TokenURIFrozen(uint256 tokenId);
    
    // ====================================================
    // 🔑 Roles
    // ====================================================
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant FRACTIONALIZER_ROLE = keccak256("FRACTIONALIZER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant MARKETPLACE_ROLE = keccak256("MARKETPLACE_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");

    // ====================================================
    // 📌 Fee Management
    // ====================================================
    uint256 public mintFee;
    uint256 public fractionalizationFee;
    uint256 public verificationFee;
    uint256 public marketplaceFee;
    IERC20Upgradeable public tStakeToken;
    address public treasuryWallet;

    // ====================================================
    // 📌 Token State Management
    // ====================================================
    uint256 public totalMinted;
    mapping(uint256 => bool) private _isERC721; // Tracks if the token is ERC721
    mapping(uint256 => string) private _tokenURIs; // Custom URIs for tokens
    string private _baseURI;
    bool private _customURIsLocked;

    // ====================================================
    // 📌 NFT Type Management
    // ====================================================
    enum NFTType { IMPACT, MEMBERSHIP, PROJECT, BADGE, LAND, CARBON_CREDIT }
    mapping(uint256 => NFTType) public nftTypes;
    
    // Optimized lookups
    mapping(NFTType => uint256[]) private _typeTokens;

    // ====================================================
    // 📌 Project Integration
    // ====================================================
    address public projectsContract;
    mapping(uint256 => uint256) public projectIds; // tokenId => projectId
    mapping(uint256 => bytes32) public impactReportHashes;
    mapping(bytes32 => bool) public mintedReports;
    
    // Optimized lookups
    mapping(uint256 => uint256[]) private _projectTokens; // projectId => tokenIds

    // ====================================================
    // 📌 Fractionalization
    // ====================================================
    struct FractionInfo {
        uint256 originalTokenId;
        uint256 fractionCount;
        address fractionalizer;
        bool isActive;
        NFTType nftType;
        uint256 projectId;
        bytes32 reportHash;
    }
    mapping(uint256 => FractionInfo) private _fractionInfos;

    // ====================================================
    // 📌 Royalty System
    // ====================================================
    uint256 public defaultRoyaltyPercentage;
    address public royaltyReceiver;
    mapping(uint256 => uint256) public customRoyaltyPercentages;
    mapping(uint256 => address) public customRoyaltyReceivers;

    // ====================================================
    // 📌 Marketplace Integration
    // ====================================================
    bool public marketplaceEnabled;
    address public marketplaceAddress;
    
    // ====================================================
    // 📌 Metadata Storage
    // ====================================================
    struct NFTMetadata {
        string name;
        string description;
        uint256 creationTime;
        bool uriIsFrozen;
    }
    mapping(uint256 => NFTMetadata) public tokenMetadata;
    mapping(uint256 => mapping(string => string)) public tokenAttributes;
    
    // ====================================================
    // 📌 Certificate of Impact
    // ====================================================
    struct ImpactCertificate {
        uint256 projectId;
        bytes32 reportHash;
        uint256 impactValue;
        string impactType;
        uint256 verificationDate;
        string location;
        address verifier;
        bool isVerified;
    }
    mapping(uint256 => ImpactCertificate) public impactCertificates;
    
    // Optimized lookups
    uint256[] private _verifiedImpactCertificates;
    mapping(uint256 => uint256) private _verifiedCertificateIndex; // tokenId => index+1 in _verifiedImpactCertificates

    // ====================================================
    // 📌 Chainlink VRF
    // ====================================================
    VRFCoordinatorV2Interface private COORDINATOR;
    bytes32 private keyHash;
    uint64 private subscriptionId;
    uint32 private callbackGasLimit;
    uint16 private requestConfirmations;
    mapping(uint256 => uint256) private _requestIdToTokenId;
    mapping(uint256 => address) private _requestIdToRecipient;

    // ====================================================
    // 📌 Whitelist & Airdrop
    // ====================================================
    bytes32 public whitelistMerkleRoot;
    mapping(address => bool) public hasClaimed;
    bool public whitelistMintEnabled;
    uint256 public whitelistMintPrice;
    
    // ====================================================
    // 📌 Ownership Tracking for Gas Optimization
    // ====================================================
    mapping(address => uint256[]) private _ownerTokens;

    // ====================================================
    // 📌 Metadata Renderer
    // ====================================================
    ITerraStakeMetadataRenderer public metadataRenderer;

    // ====================================================
    // 📣 Events
    // ====================================================
    event NFTMinted(address indexed to, uint256 indexed tokenId, bool isERC721, NFTType nftType);
    event ImpactNFTMinted(uint256 indexed tokenId, uint256 indexed projectId, bytes32 reportHash, address recipient);
    event TokenFractionalized(uint256 indexed tokenId, uint256 fractionId, uint256 fractionCount);
    event FractionsReunified(uint256 indexed fractionId, uint256 newTokenId);
    event BaseURIUpdated(string newBaseURI);
    event TokenURIFrozen(uint256 indexed tokenId);
    event ProjectsContractUpdated(address indexed newProjectsContract);
    event RoyaltyUpdated(address receiver, uint256 percentage);
    event MarketplaceStatusChanged(bool enabled);
    event MarketplaceAddressUpdated(address indexed newMarketplace);
    event ImpactCertificateVerified(uint256 indexed tokenId, address verifier);
    event RandomnessRequested(uint256 indexed requestId, uint256 indexed tokenId, address recipient);
    event RandomnessReceived(uint256 indexed requestId, uint256 indexed tokenId, uint256 randomNumber);
    event WhitelistMintingEnabled(bool enabled, uint256 price);
    event WhitelistRootUpdated(bytes32 newRoot);
    event TStakeRecovered(address indexed tokenAddress, uint256 amount);
    event TStakeBurned(uint256 amount);
    event MetadataRendererUpdated(address indexed renderer);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() VRFConsumerBaseV2(address(0)) {
        _disableInitializers();
    }

    /**
     * @dev Initializes the TerraStakeNFT contract
     * @param _tStakeToken Address of the TStake token
     * @param _treasuryWallet Address of the treasury wallet
     * @param _mintFee Fee for minting NFTs
     * @param _fractionalizationFee Fee for fractionalizing NFTs
     * @param _vrfCoordinator Address of the VRF Coordinator
     * @param _vrfKeyHash Key hash for VRF
     * @param _vrfSubscriptionId Subscription ID for VRF
     */
    function initialize(
        address _tStakeToken,
        address _treasuryWallet,
        uint256 _mintFee,
        uint256 _fractionalizationFee,
        address _vrfCoordinator,
        bytes32 _vrfKeyHash,
        uint64 _vrfSubscriptionId
    ) public initializer {
        if (_tStakeToken == address(0)) revert InvalidRecipient();
        if (_treasuryWallet == address(0)) revert InvalidRecipient();
        if (_vrfCoordinator == address(0)) revert InvalidRecipient();
        
        // Initialize all inherited contracts using OZ 5.2.x pattern
        __ERC1155_init("ipfs://");
        __ERC1155Supply_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        
        tStakeToken = IERC20Upgradeable(_tStakeToken);
        treasuryWallet = _treasuryWallet;
        mintFee = _mintFee;
        fractionalizationFee = _fractionalizationFee;
        
        // VRF initialization
        COORDINATOR = VRFCoordinatorV2Interface(_vrfCoordinator);
        keyHash = _vrfKeyHash;
        subscriptionId = _vrfSubscriptionId;
        callbackGasLimit = 100000;
        requestConfirmations = 3;
        
        // Default royalty settings
        defaultRoyaltyPercentage = 250; // 2.5%
        royaltyReceiver = _treasuryWallet;
        
        // Set base URI
        _baseURI = "ipfs://";
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(FRACTIONALIZER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // ====================================================
    // 🔹 Minting Functions
    // ====================================================
    
    /**
     * @dev Standard mint function
     * @param to Recipient address
     * @param isERC721 Whether to treat as an ERC721 token (only one copy)
     * @param nftType Type of NFT being minted
     */
    function mint(
        address to,
        bool isERC721,
        NFTType nftType
    ) external nonReentrant onlyRole(MINTER_ROLE) returns (uint256) {
        if (to == address(0)) revert InvalidRecipient();
        if (!tStakeToken.transferFrom(msg.sender, address(this), mintFee)) 
            revert FeeTransferFailed();
            
        uint256 tokenId = ++totalMinted;
        _mint(to, tokenId, 1, "");
        _isERC721[tokenId] = isERC721;
        nftTypes[tokenId] = nftType;
        
        // Add to type index for optimized lookups
        _typeTokens[nftType].push(tokenId);
        
        // Add to owner tokens for optimized lookups
        _addToOwnerTokens(to, tokenId);
        
        // Set creation metadata
        tokenMetadata[tokenId] = NFTMetadata({
            name: string(abi.encodePacked("TerraStake NFT #", _uint256ToString(tokenId))),
            description: "TerraStake NFT",
            creationTime: block.timestamp,
            uriIsFrozen: false
        });
                // Split fee: 90% to treasury, 10% to burn
        uint256 burnAmount = mintFee / 10;
        uint256 treasuryAmount = mintFee - burnAmount;
        
        tStakeToken.transfer(treasuryWallet, treasuryAmount);
        ITerraStakeToken(address(tStakeToken)).burn(burnAmount);
        emit TStakeBurned(burnAmount);
        
        emit NFTMinted(to, tokenId, isERC721, nftType);
        return tokenId;
    }
    
    /**
     * @dev Mint an impact certificate NFT linked to a verified impact report
     * @param to Recipient address
     * @param projectId ID of the project
     * @param reportHash Hash of the impact report
     * @param impactValue Quantified impact value
     * @param impactType Type of impact (e.g., "CO2 reduction")
     * @param location Geographic location
     */
    function mintImpactCertificate(
        address to,
        uint256 projectId,
        bytes32 reportHash, 
        uint256 impactValue,
        string calldata impactType,
        string calldata location
    ) external nonReentrant onlyRole(MINTER_ROLE) returns (uint256) {
        if (to == address(0)) revert InvalidRecipient();
        if (mintedReports[reportHash]) revert ReportAlreadyMinted();
        if (!tStakeToken.transferFrom(msg.sender, address(this), mintFee)) 
            revert FeeTransferFailed();
        
        // Verify project exists if projects contract is set
        if (projectsContract != address(0)) {
            ITerraStakeProjects(projectsContract).getProject(projectId);
        }
        
        uint256 tokenId = ++totalMinted;
        _mint(to, tokenId, 1, "");
        _isERC721[tokenId] = true;
        nftTypes[tokenId] = NFTType.IMPACT;
        
        // Store project and report info
        projectIds[tokenId] = projectId;
        impactReportHashes[tokenId] = reportHash;
        mintedReports[reportHash] = true;
        
        // Add to type index for optimized lookups
        _typeTokens[NFTType.IMPACT].push(tokenId);
        
        // Add to project tokens for optimized lookups
        _projectTokens[projectId].push(tokenId);
        
        // Add to owner tokens for optimized lookups
        _addToOwnerTokens(to, tokenId);
        
        // Create impact certificate
        impactCertificates[tokenId] = ImpactCertificate({
            projectId: projectId,
            reportHash: reportHash,
            impactValue: impactValue,
            impactType: impactType,
            verificationDate: 0, // Not verified yet
            location: location,
            verifier: address(0), // Not verified yet
            isVerified: false
        });
        
        // Set creation metadata
        tokenMetadata[tokenId] = NFTMetadata({
            name: string(abi.encodePacked("Impact Certificate #", _uint256ToString(tokenId))),
            description: string(abi.encodePacked("Impact Certificate for ", impactType)),
            creationTime: block.timestamp,
            uriIsFrozen: false
        });
        
        // Split fee: 90% to treasury, 10% to burn
        uint256 burnAmount = mintFee / 10;
        uint256 treasuryAmount = mintFee - burnAmount;
        
        tStakeToken.transfer(treasuryWallet, treasuryAmount);
        ITerraStakeToken(address(tStakeToken)).burn(burnAmount);
        emit TStakeBurned(burnAmount);
        
        emit NFTMinted(to, tokenId, true, NFTType.IMPACT);
        emit ImpactNFTMinted(tokenId, projectId, reportHash, to);
        
        return tokenId;
    }
    
    /**
     * @dev Batch mint function
     * @param to Array of recipient addresses
     * @param count Array of token counts to mint per recipient
     * @param isERC721 Array of flags indicating if tokens should be treated as ERC721
     * @param nftType Array of NFT types
     */
    function batchMint(
        address[] calldata to,
        uint256[] calldata count,
        bool[] calldata isERC721,
        NFTType[] calldata nftType
    ) external nonReentrant onlyRole(MINTER_ROLE) returns (uint256[] memory) {
        uint256 length = to.length;
        if (length == 0 || 
            length != count.length || 
            length != isERC721.length || 
            length != nftType.length) revert ArrayLengthMismatch();
        
        uint256 totalCount = 0;
        for (uint256 i = 0; i < length; i++) {
            totalCount += count[i];
        }
        
        uint256 totalFee = mintFee * totalCount;
        if (!tStakeToken.transferFrom(msg.sender, address(this), totalFee)) 
            revert FeeTransferFailed();
            
        uint256[] memory tokenIds = new uint256[](totalCount);
        uint256 tokenIndex = 0;
        
        for (uint256 i = 0; i < length; i++) {
            if (to[i] == address(0)) revert InvalidRecipient();
            
            for (uint256 j = 0; j < count[i]; j++) {
                uint256 tokenId = ++totalMinted;
                _mint(to[i], tokenId, 1, "");
                _isERC721[tokenId] = isERC721[i];
                nftTypes[tokenId] = nftType[i];
                
                // Add to type index for optimized lookups
                _typeTokens[nftType[i]].push(tokenId);
                
                // Add to owner tokens for optimized lookups
                _addToOwnerTokens(to[i], tokenId);
                
                // Set creation metadata
                tokenMetadata[tokenId] = NFTMetadata({
                    name: string(abi.encodePacked("TerraStake NFT #", _uint256ToString(tokenId))),
                    description: "TerraStake NFT",
                    creationTime: block.timestamp,
                    uriIsFrozen: false
                });
                
                tokenIds[tokenIndex++] = tokenId;
                emit NFTMinted(to[i], tokenId, isERC721[i], nftType[i]);
            }
        }
        
        // Split fee: 90% to treasury, 10% to burn
        uint256 burnAmount = totalFee / 10;
        uint256 treasuryAmount = totalFee - burnAmount;
        
        tStakeToken.transfer(treasuryWallet, treasuryAmount);
        ITerraStakeToken(address(tStakeToken)).burn(burnAmount);
        emit TStakeBurned(burnAmount);
        
        return tokenIds;
    }
    
    /**
     * @dev Mint with VRF-based randomized metadata
     * @param to Recipient address
     * @param nftType Type of NFT to mint
     */
    function mintRandomized(
        address to,
        NFTType nftType
    ) external nonReentrant onlyRole(MINTER_ROLE) returns (uint256) {
        if (to == address(0)) revert InvalidRecipient();
        if (!tStakeToken.transferFrom(msg.sender, address(this), mintFee)) 
            revert FeeTransferFailed();
            
        uint256 tokenId = ++totalMinted;
        _mint(to, tokenId, 1, "");
        _isERC721[tokenId] = true;
        nftTypes[tokenId] = nftType;
        
        // Add to type index for optimized lookups
        _typeTokens[nftType].push(tokenId);
        
        // Add to owner tokens for optimized lookups
        _addToOwnerTokens(to, tokenId);
        
        // Request randomness from Chainlink VRF
        uint256 requestId = COORDINATOR.requestRandomWords(
            keyHash,
            subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            1
        );
        
        _requestIdToTokenId[requestId] = tokenId;
        _requestIdToRecipient[requestId] = to;
        
        emit NFTMinted(to, tokenId, true, nftType);
        emit RandomnessRequested(requestId, tokenId, to);
        
        return tokenId;
    }
    
    /**
     * @dev Whitelist mint function
     * @param proof Merkle proof verifying whitelist status
     * @param nftType Type of NFT to mint
     */
    function whitelistMint(
        bytes32[] calldata proof,
        NFTType nftType
    ) external nonReentrant returns (uint256) {
        if (!whitelistMintEnabled) revert NotActiveToken();
        if (hasClaimed[msg.sender]) revert AlreadyClaimed();
        
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
        if (!MerkleProof.verify(proof, whitelistMerkleRoot, leaf)) revert InvalidProof();
        
        if (!tStakeToken.transferFrom(msg.sender, address(this), whitelistMintPrice)) 
            revert FeeTransferFailed();
            
        hasClaimed[msg.sender] = true;
        
        uint256 tokenId = ++totalMinted;
        _mint(msg.sender, tokenId, 1, "");
        _isERC721[tokenId] = true;
        nftTypes[tokenId] = nftType;
        
        // Add to type index for optimized lookups
        _typeTokens[nftType].push(tokenId);
        
        // Add to owner tokens for optimized lookups
        _addToOwnerTokens(msg.sender, tokenId);
        
        // Set creation metadata
        tokenMetadata[tokenId] = NFTMetadata({
            name: string(abi.encodePacked("TerraStake NFT #", _uint256ToString(tokenId))),
            description: "TerraStake Whitelist NFT",
            creationTime: block.timestamp,
            uriIsFrozen: false
        });
        
        // Split fee: 90% to treasury, 10% to burn
        uint256 burnAmount = whitelistMintPrice / 10;
        uint256 treasuryAmount = whitelistMintPrice - burnAmount;
        
        tStakeToken.transfer(treasuryWallet, treasuryAmount);
        ITerraStakeToken(address(tStakeToken)).burn(burnAmount);
        emit TStakeBurned(burnAmount);
        
        emit NFTMinted(msg.sender, tokenId, true, nftType);
        
        return tokenId;
    }
    
    // ====================================================
    // 🔹 Fractionalization Functions
    // ====================================================
    
    /**
     * @dev Fractionalize an NFT into multiple pieces
     * @param tokenId ID of the token to fractionalize
     * @param fractionCount Number of fractions to create
     */
    function fractionalize(
        uint256 tokenId,
        uint256 fractionCount
    ) external nonReentrant returns (uint256) {
        if (!exists(tokenId)) revert TokenDoesNotExist();
        if (balanceOf(msg.sender, tokenId) < 1) revert NotTokenOwner();
        if (fractionCount < 2) revert InvalidAmount();
        
        // Check if the caller has the FRACTIONALIZER_ROLE or is the token owner
        bool isFractionalizerRole = hasRole(FRACTIONALIZER_ROLE, msg.sender);
        if (!isFractionalizerRole) {
            // Charge a fee for non-role users
            if (!tStakeToken.transferFrom(msg.sender, address(this), fractionalizationFee)) 
                revert FeeTransferFailed();
                
            // Split fee: 90% to treasury, 10% to burn
            uint256 burnAmount = fractionalizationFee / 10;
            uint256 treasuryAmount = fractionalizationFee - burnAmount;
            
            tStakeToken.transfer(treasuryWallet, treasuryAmount);
            ITerraStakeToken(address(tStakeToken)).burn(burnAmount);
            emit TStakeBurned(burnAmount);
        }
        
        // Burn the original token
        _burn(msg.sender, tokenId, 1);
        
        // Create a new fractionID
        uint256 fractionId = ++totalMinted;
        
        // Mint the fractional tokens to the sender
        _mint(msg.sender, fractionId, fractionCount, "");
        
        // Store fraction information
        _fractionInfos[fractionId] = FractionInfo({
            originalTokenId: tokenId,
            fractionCount: fractionCount,
            fractionalizer: msg.sender,
            isActive: true,
            nftType: nftTypes[tokenId],
            projectId: projectIds[tokenId],
            reportHash: impactReportHashes[tokenId]
        });
        
        // Add to owner tokens for optimized lookups
        _addToOwnerTokens(msg.sender, fractionId);
        
        emit TokenFractionalized(tokenId, fractionId, fractionCount);
        return fractionId;
    }
    
    /**
     * @dev Reunify fractions back into a whole NFT
     * @param fractionId ID of the fractionalized tokens
     */
    function reunify(uint256 fractionId) external nonReentrant returns (uint256) {
        FractionInfo storage info = _fractionInfos[fractionId];
        if (!info.isActive) revert NotActiveToken();
        
        uint256 fractionCount = info.fractionCount;
        if (balanceOf(msg.sender, fractionId) != fractionCount) revert NotAllFractionsOwned();
        
        // Burn all fractions
        _burn(msg.sender, fractionId, fractionCount);
        
        // Create new token
        uint256 newTokenId = ++totalMinted;
        _mint(msg.sender, newTokenId, 1, "");
        
        // Copy metadata and attributes from original token
        _isERC721[newTokenId] = _isERC721[info.originalTokenId];
        nftTypes[newTokenId] = info.nftType;
        
        // If it was an impact NFT, copy the impact details
        if (info.nftType == NFTType.IMPACT) {
            projectIds[newTokenId] = info.projectId;
            impactReportHashes[newTokenId] = info.reportHash;
            
            // Add to project tokens for optimized lookups
            _projectTokens[info.projectId].push(newTokenId);
                        // Copy impact certificate if exists
            if (impactCertificates[info.originalTokenId].reportHash != bytes32(0)) {
                impactCertificates[newTokenId] = impactCertificates[info.originalTokenId];
                
                // If certificate was verified, add to verified certificates
                if (impactCertificates[newTokenId].isVerified) {
                    _verifiedImpactCertificates.push(newTokenId);
                    _verifiedCertificateIndex[newTokenId] = _verifiedImpactCertificates.length;
                }
            }
        }
        
        // Add to type index for optimized lookups
        _typeTokens[info.nftType].push(newTokenId);
        
        // Add to owner tokens for optimized lookups
        _addToOwnerTokens(msg.sender, newTokenId);
        
        // Set creation metadata
        tokenMetadata[newTokenId] = NFTMetadata({
            name: string(abi.encodePacked("Reunified #", _uint256ToString(newTokenId))),
            description: "Reunified from fractions",
            creationTime: block.timestamp,
            uriIsFrozen: false
        });
        
        // Deactivate fraction info
        info.isActive = false;
        
        emit FractionsReunified(fractionId, newTokenId);
        return newTokenId;
    }
    
    // ====================================================
    // 🔹 Verification Functions
    // ====================================================
    
    /**
     * @dev Verify an impact certificate
     * @param tokenId ID of the impact certificate to verify
     */
    function verifyImpactCertificate(uint256 tokenId) external nonReentrant onlyRole(VERIFIER_ROLE) {
        if (!exists(tokenId)) revert TokenDoesNotExist();
        if (nftTypes[tokenId] != NFTType.IMPACT) revert NotImpactNFT();
        
        ImpactCertificate storage certificate = impactCertificates[tokenId];
        if (certificate.isVerified) revert AlreadyVerified();
        
        certificate.isVerified = true;
        certificate.verificationDate = block.timestamp;
        certificate.verifier = msg.sender;
        
        // Add to verified certificates list
        _verifiedImpactCertificates.push(tokenId);
        _verifiedCertificateIndex[tokenId] = _verifiedImpactCertificates.length;
        
        emit ImpactCertificateVerified(tokenId, msg.sender);
    }
    
    /**
     * @dev Submit verification with fee
     * @param tokenId ID of the impact certificate to verify
     */
    function submitVerification(uint256 tokenId) external nonReentrant {
        if (!exists(tokenId)) revert TokenDoesNotExist();
        if (nftTypes[tokenId] != NFTType.IMPACT) revert NotImpactNFT();
        if (balanceOf(msg.sender, tokenId) < 1) revert NotTokenOwner();
        
        ImpactCertificate storage certificate = impactCertificates[tokenId];
        if (certificate.isVerified) revert AlreadyVerified();
        
        // Charge verification fee
        if (!tStakeToken.transferFrom(msg.sender, address(this), verificationFee)) 
            revert VerificationFeeFailed();
            
        // Split fee: 90% to treasury, 10% to burn
        uint256 burnAmount = verificationFee / 10;
        uint256 treasuryAmount = verificationFee - burnAmount;
        
        tStakeToken.transfer(treasuryWallet, treasuryAmount);
        ITerraStakeToken(address(tStakeToken)).burn(burnAmount);
        emit TStakeBurned(burnAmount);
    }
    
    // ====================================================
    // 🔹 VRF Callback
    // ====================================================
    
    /**
     * @dev Callback function used by VRF Coordinator
     * @param requestId ID of the randomness request
     * @param randomWords Array of random results from VRF
     */
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) internal override {
        uint256 tokenId = _requestIdToTokenId[requestId];
        address recipient = _requestIdToRecipient[requestId];
        
        uint256 randomNumber = randomWords[0];
        
        // Set random attributes based on randomNumber
        tokenAttributes[tokenId]["rarity"] = _determineRarity(randomNumber);
        tokenAttributes[tokenId]["random_seed"] = _uint256ToString(randomNumber);
        
        // Set creation metadata
        tokenMetadata[tokenId] = NFTMetadata({
            name: string(abi.encodePacked("Random NFT #", _uint256ToString(tokenId))),
            description: string(abi.encodePacked("Randomized NFT with seed: ", _uint256ToString(randomNumber))),
            creationTime: block.timestamp,
            uriIsFrozen: false
        });
        
        emit RandomnessReceived(requestId, tokenId, randomNumber);
    }
    
    // ====================================================
    // 🔹 URI & Metadata Functions
    // ====================================================
    
    /**
     * @dev Sets the base URI for all token IDs
     * @param newBaseURI New base URI to set
     */
    function setBaseURI(string memory newBaseURI) external onlyRole(GOVERNANCE_ROLE) {
        _baseURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }
    
    /**
     * @dev Sets the URI for a specific token ID
     * @param tokenId ID of the token to set URI for
     * @param newTokenURI New URI to set
     */
    function setTokenURI(uint256 tokenId, string memory newTokenURI) external {
        if (!exists(tokenId)) revert TokenDoesNotExist();
        if (balanceOf(msg.sender, tokenId) == 0 && !hasRole(GOVERNANCE_ROLE, msg.sender)) 
            revert NotTokenOwner();
        if (tokenMetadata[tokenId].uriIsFrozen) revert TokenURIFrozen(tokenId);
        
        _tokenURIs[tokenId] = newTokenURI;
    }
    
    /**
     * @dev Freezes token URI to prevent future changes
     * @param tokenId ID of the token to freeze URI for
     */
    function freezeTokenURI(uint256 tokenId) external {
        if (!exists(tokenId)) revert TokenDoesNotExist();
        if (balanceOf(msg.sender, tokenId) == 0 && !hasRole(GOVERNANCE_ROLE, msg.sender)) 
            revert NotTokenOwner();
            
        tokenMetadata[tokenId].uriIsFrozen = true;
        emit TokenURIFrozen(tokenId);
    }
    
    /**
     * @dev Set token attribute
     * @param tokenId ID of the token
     * @param key Attribute key
     * @param value Attribute value
     */
    function setTokenAttribute(
        uint256 tokenId,
        string calldata key,
        string calldata value
    ) external {
        if (!exists(tokenId)) revert TokenDoesNotExist();
        if (balanceOf(msg.sender, tokenId) == 0 && !hasRole(GOVERNANCE_ROLE, msg.sender)) 
            revert NotTokenOwner();
            
        tokenAttributes[tokenId][key] = value;
    }
    
    /**
     * @dev Set metadata renderer contract
     * @param renderer Address of the renderer contract
     */
    function setMetadataRenderer(address renderer) external onlyRole(GOVERNANCE_ROLE) {
        metadataRenderer = ITerraStakeMetadataRenderer(renderer);
        emit MetadataRendererUpdated(renderer);
    }
    
    /**
     * @dev Get token URI
     * @param tokenId ID of the token
     * @return URI string
     */
    function uri(uint256 tokenId) public view override returns (string memory) {
        if (!exists(tokenId)) revert TokenDoesNotExist();
        
        // If metadata renderer is set, use it
        if (address(metadataRenderer) != address(0)) {
            return metadataRenderer.getTokenURI(tokenId);
        }
        
        // If custom URI is set, return it
        string memory tokenURI = _tokenURIs[tokenId];
        if (bytes(tokenURI).length > 0) {
            return tokenURI;
        }
        
        // Otherwise return default URI
        return string(abi.encodePacked(_baseURI, _uint256ToString(tokenId)));
    }
    
    // ====================================================
    // 🔹 Project Integration Functions
    // ====================================================
    
    /**
     * @dev Set the projects contract address
     * @param _projectsContract Address of the projects contract
     */
    function setProjectsContract(address _projectsContract) external onlyRole(GOVERNANCE_ROLE) {
        projectsContract = _projectsContract;
        emit ProjectsContractUpdated(_projectsContract);
    }
    
    /**
     * @dev Get all tokens for a specific project
     * @param projectId ID of the project
     * @return Array of token IDs
     */
    function getProjectTokens(uint256 projectId) external view returns (uint256[] memory) {
        return _projectTokens[projectId];
    }
    
    // ====================================================
    // 🔹 Royalty Functions
    // ====================================================
    
    /**
     * @dev Set the default royalty percentage
     * @param percentage Royalty percentage (in basis points, 100 = 1%)
     */
    function setDefaultRoyalty(uint256 percentage) external onlyRole(GOVERNANCE_ROLE) {
        defaultRoyaltyPercentage = percentage;
        emit RoyaltyUpdated(royaltyReceiver, percentage);
    }
    
    /**
     * @dev Set the royalty receiver
     * @param receiver Address of the royalty receiver
     */
    function setRoyaltyReceiver(address receiver) external onlyRole(GOVERNANCE_ROLE) {
        if (receiver == address(0)) revert InvalidRecipient();
        royaltyReceiver = receiver;
        emit RoyaltyUpdated(receiver, defaultRoyaltyPercentage);
    }
    
    /**
     * @dev Set custom royalty for a specific token
     * @param tokenId ID of the token
     * @param percentage Royalty percentage (in basis points, 100 = 1%)
     * @param receiver Address of the royalty receiver
     */
    function setTokenRoyalty(
        uint256 tokenId,
        uint256 percentage,
        address receiver
    ) external {
        if (!exists(tokenId)) revert TokenDoesNotExist();
        if (receiver == address(0)) revert InvalidRecipient();
        if (balanceOf(msg.sender, tokenId) == 0 && !hasRole(GOVERNANCE_ROLE, msg.sender)) 
            revert NotTokenOwner();
            
        customRoyaltyPercentages[tokenId] = percentage;
        customRoyaltyReceivers[tokenId] = receiver;
    }
    
    /**
     * @dev Get royalty info for a token
     * @param tokenId ID of the token
     * @param salePrice Sale price to calculate royalty from
     * @return receiver Address of royalty receiver
     * @return royaltyAmount Amount of royalty to pay
     */
    function royaltyInfo(
        uint256 tokenId, 
        uint256 salePrice
    ) external view returns (address receiver, uint256 royaltyAmount) {
        if (customRoyaltyReceivers[tokenId] != address(0)) {
            // Use custom royalty
            receiver = customRoyaltyReceivers[tokenId];
            royaltyAmount = (salePrice * customRoyaltyPercentages[tokenId]) / 10000;
        } else {
            // Use default royalty
            receiver = royaltyReceiver;
            royaltyAmount = (salePrice * defaultRoyaltyPercentage) / 10000;
        }
    }
    
    // ====================================================
    // 🔹 Marketplace Functions
    // ====================================================
    
    /**
     * @dev Enable or disable marketplace integration
     * @param enabled Whether to enable marketplace
     */
    function setMarketplaceEnabled(bool enabled) external onlyRole(GOVERNANCE_ROLE) {
        marketplaceEnabled = enabled;
        emit MarketplaceStatusChanged(enabled);
    }
    
    /**
     * @dev Set marketplace address
     * @param marketplace Address of the marketplace
     */
    function setMarketplaceAddress(address marketplace) external onlyRole(GOVERNANCE_ROLE) {
        marketplaceAddress = marketplace;
        emit MarketplaceAddressUpdated(marketplace);
    }
    
    // ====================================================
    // 🔹 Whitelist Functions
    // ====================================================
    
    /**
     * @dev Set whitelist merkle root
     * @param merkleRoot New merkle root
     */
    function setWhitelistMerkleRoot(bytes32 merkleRoot) external onlyRole(GOVERNANCE_ROLE) {
        whitelistMerkleRoot = merkleRoot;
        emit WhitelistRootUpdated(merkleRoot);
    }
    
    /**
     * @dev Enable or disable whitelist minting
     * @param enabled Whether to enable whitelist minting
     * @param price Price for whitelist minting
     */
    function setWhitelistMintingEnabled(bool enabled, uint256 price) external onlyRole(GOVERNANCE_ROLE) {
        whitelistMintEnabled = enabled;
        whitelistMintPrice = price;
        emit WhitelistMintingEnabled(enabled, price);
    }
    
    // ====================================================
    // 🔹 Fee Management Functions
    // ====================================================
    
    /**
     * @dev Set mint fee
     * @param fee New mint fee
     */
    function setMintFee(uint256 fee) external onlyRole(GOVERNANCE_ROLE) {
        mintFee = fee;
    }
    
    /**
     * @dev Set fractionalization fee
     * @param fee New fractionalization fee
     */
    function setFractionalizationFee(uint256 fee) external onlyRole(GOVERNANCE_ROLE) {
        fractionalizationFee = fee;
    }
    
    /**
     * @dev Set verification fee
     * @param fee New verification fee
     */
    function setVerificationFee(uint256 fee) external onlyRole(GOVERNANCE_ROLE) {
        verificationFee = fee;
    }
    
    /**
     * @dev Set treasury wallet
     * @param wallet New treasury wallet address
     */
    function setTreasuryWallet(address wallet) external onlyRole(GOVERNANCE_ROLE) {
        if (wallet == address(0)) revert InvalidRecipient();
        treasuryWallet = wallet;
    }
    
    // ====================================================
    // 🔹 Administrative Functions
    // ====================================================
    
    /**
     * @dev Pause contract
     */
    function pause() external onlyRole(GOVERNANCE_ROLE) {
        _pause();
    }
    
    /**
     * @dev Unpause contract
     */
    function unpause() external onlyRole(GOVERNANCE_ROLE) {
        _unpause();
    }
    
    /**
     * @dev Recover TStake tokens accidentally sent to contract
     * @param amount Amount to recover
     */
    function recoverTStake(uint256 amount) external onlyRole(GOVERNANCE_ROLE) {
        uint256 balance = tStakeToken.balanceOf(address(this));
        if (amount > balance) revert InsufficientBalance();
        
        tStakeToken.transfer(treasuryWallet, amount);
        emit TStakeRecovered(address(tStakeToken), amount);
    }
    
    /**
     * @dev Set VRF parameters
     * @param _keyHash New key hash for VRF
     * @param _subscriptionId New subscription ID for VRF
     * @param _callbackGasLimit New callback gas limit
     * @param _requestConfirmations New request confirmations
     */
    function setVRFParams(
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
    
    // ====================================================
    // 🔹 View Functions
    // ====================================================
    
    /**
     * @dev Get all tokens of a specific type
     * @param nftType Type of NFT to retrieve
     * @return Array of token IDs
     */
    function getTokensByType(NFTType nftType) external view returns (uint256[] memory) {
        return _typeTokens[nftType];
    }
    
    /**
     * @dev Get all verified impact certificates
     * @return Array of token IDs
     */
    function getVerifiedImpactCertificates() external view returns (uint256[] memory) {
        return _verifiedImpactCertificates;
    }
    
    /**
     * @dev Get fraction info
     * @param fractionId ID of fraction
     * @return FractionInfo struct
     */
    function getFractionInfo(uint256 fractionId) external view returns (FractionInfo memory) {
        return _fractionInfos[fractionId];
    }
    
    /**
     * @dev Get all tokens owned by an address
     * @param owner Address to query
     * @return Array of token IDs
     */
    function getOwnerTokens(address owner) external view returns (uint256[] memory) {
        return _ownerTokens[owner];
    }
    
    /**
     * @dev Check if token is an ERC721
     * @param tokenId ID of token to check
     * @return Whether token is an ERC721
     */
    function isERC721(uint256 tokenId) external view returns (bool) {
        return _isERC721[tokenId];
    }
    
    // ====================================================
    // 🔹 Internal Utility Functions
    // ====================================================
    
    /**
     * @dev Add token to owner's token list
     * @param owner Address of owner
     * @param tokenId ID of token
     */
    function _addToOwnerTokens(address owner, uint256 tokenId) internal {
        _ownerTokens[owner].push(tokenId);
    }
    
    /**
     * @dev Determine rarity from random number
     * @param randomNumber Random number input
     * @return Rarity string
     */
    function _determineRarity(uint256 randomNumber) internal pure returns (string memory) {
        uint256 rarityValue = randomNumber % 100;
        
        if (rarityValue < 1) return "Legendary";
        if (rarityValue < 5) return "Epic";
        if (rarityValue < 15) return "Rare";
        if (rarityValue < 40) return "Uncommon";
        return "Common";
    }
    
    /**
     * @dev Convert uint256 to string
     * @param value Number to convert
     * @return String representation
     */
    function _uint256ToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        
        uint256 temp = value;
        uint256 digits;
        
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        
        return string(buffer);
    }
    
    // ====================================================
    // 🔹 Override Functions
    // ====================================================
    
    /**
     * @dev See {ERC1155-_beforeTokenTransfer}
     */
    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal override(ERC1155Upgradeable, ERC1155SupplyUpgradeable) whenNotPaused {
        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);
        
        // Add to new owner's token list if not a zero address (minting handled separately)
        if (from != address(0) && to != address(0)) {
            for (uint256 i = 0; i < ids.length; i++) {
                if (amounts[i] > 0) {
                    _addToOwnerTokens(to, ids[i]);
                }
            }
        }
    }
    
    /**
     * @dev See {IERC165-supportsInterface}
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
