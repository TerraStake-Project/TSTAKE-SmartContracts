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
import "../interfaces/ITerraStakeFractionManager.sol";
import "@openzeppelin/contracts-upgradeable/interfaces/IERC2981Upgradeable.sol";

interface ITerraStakeToken {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function burn(uint256 amount) external;
}

/**
 * @title TerraStakeNFT
 * @notice Advanced ERC1155 NFT implementation for TerraStake impact certificates with fractionalization
 * @dev Implements UUPS upgradeable pattern with multiple advanced features and EIP-2981 support
 */
contract TerraStakeNFT is 
    Initializable, 
    ERC1155Upgradeable, 
    ERC1155SupplyUpgradeable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    VRFConsumerBaseV2,
    IERC2981Upgradeable
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
    error UpgradeTimelockActive();
    error InvalidFeeParameters();
    error InvalidRoyaltyParameters();
    error ApprovalFailed();
    
    // ====================================================
    // 🔑 Roles
    // ====================================================
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant FRACTIONALIZER_ROLE = keccak256("FRACTIONALIZER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant MARKETPLACE_ROLE = keccak256("MARKETPLACE_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant FEE_EXEMPTION_ROLE = keccak256("FEE_EXEMPTION_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    // ====================================================
    // 📌 Fee Management
    // ====================================================
    uint256 public mintFee;
    uint256 public fractionalizationFee;
    uint256 public verificationFee;
    uint256 public marketplaceFee;
    IERC20Upgradeable public tStakeToken;
    address public treasuryWallet;
    
    // Dynamic fee structure
    bool public dynamicFeesEnabled;
    uint256 public feeAdjustmentInterval;
    uint256 public lastFeeAdjustment;
    uint256 public baseMintFee;
    uint256 public baseFractionalizationFee;
    uint256 public feeMultiplier; // basis points (10000 = 100%)

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
    ITerraStakeFractionManager public fractionManager;

    // ====================================================
    // 📌 Royalty System (EIP-2981 Compliant)
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
    mapping(uint256 => bool) public tokenApprovedForMarketplace;
    mapping(address => bool) public approvedMarketplaces;
    
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
    // 📌 Upgrade Timelock
    // ====================================================
    uint256 public constant UPGRADE_TIMELOCK = 2 days;
    uint256 public upgradeProposedTime;
    address public proposedImplementation;
    uint256 public requiredUpgradeApprovals;
    mapping(address => bool) public upgradeApprovals;
    address[] public upgradeApprovers;

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
    event FractionManagerUpdated(address indexed manager);
    event TokenApprovedForMarketplace(uint256 indexed tokenId, address indexed marketplace, bool approved);
    event MarketplaceApprovalChanged(address indexed marketplace, bool approved);
    event UpgradeProposed(address indexed implementation, uint256 effectiveTime);
    event UpgradeApproved(address indexed approver, address indexed implementation);
    event UpgradeCancelled(address indexed implementation);
    event DynamicFeesUpdated(bool enabled, uint256 multiplier, uint256 interval);
    event FeesAdjusted(uint256 mintFee, uint256 fractionalizationFee, uint256 verificationFee);
    event RoyaltyInfoRequested(uint256 indexed tokenId, uint256 salePrice);

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
        verificationFee = _mintFee * 2; // Default verification fee is double the mint fee
        
        // Initialize Chainlink VRF
        COORDINATOR = VRFCoordinatorV2Interface(_vrfCoordinator);
        keyHash = _vrfKeyHash;
        subscriptionId = _vrfSubscriptionId;
        callbackGasLimit = 200000;
        requestConfirmations = 3;
        
        // Setup royalty defaults
        defaultRoyaltyPercentage = 500; // 5% default royalty
        royaltyReceiver = _treasuryWallet;
        
        // Setup dynamic fees (initially disabled)
        dynamicFeesEnabled = false;
        feeAdjustmentInterval = 1 days;
        lastFeeAdjustment = block.timestamp;
        baseMintFee = _mintFee;
        baseFractionalizationFee = _fractionalizationFee;
        feeMultiplier = 10000; // 100% - no adjustment
        
        // Setup upgrade security
        requiredUpgradeApprovals = 3; // Multisig requirement
        
        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(FRACTIONALIZER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        _grantRole(VERIFIER_ROLE, msg.sender);
        _grantRole(FEE_MANAGER_ROLE, msg.sender);
        
        _baseURI = "ipfs://";
    }
    
    // ====================================================
    // 🔒 UUPS Upgrade with Multi-Signature Security
    // ====================================================
    
    /**
     * @dev Proposes a contract upgrade with timelock
     * @param implementation New implementation address
     */
    function proposeUpgrade(address implementation) external onlyRole(UPGRADER_ROLE) {
        proposedImplementation = implementation;
        upgradeProposedTime = block.timestamp;
        
        // Reset approvals
        for (uint i = 0; i < upgradeApprovers.length; i++) {
            upgradeApprovals[upgradeApprovers[i]] = false;
        }
        delete upgradeApprovers;
        
        // Auto-approve from proposer
        upgradeApprovals[msg.sender] = true;
        upgradeApprovers.push(msg.sender);
        
        emit UpgradeProposed(implementation, block.timestamp + UPGRADE_TIMELOCK);
    }
    
    /**
     * @dev Approves a proposed upgrade
     */
    function approveUpgrade() external onlyRole(UPGRADER_ROLE) {
        if (proposedImplementation == address(0)) revert NotActiveToken();
        if (upgradeApprovals[msg.sender]) return; // Already approved
        
        upgradeApprovals[msg.sender] = true;
        upgradeApprovers.push(msg.sender);
        
        emit UpgradeApproved(msg.sender, proposedImplementation);
    }
    
    /**
     * @dev Cancels a proposed upgrade
     */
    function cancelUpgrade() external onlyRole(GOVERNANCE_ROLE) {
        address oldImplementation = proposedImplementation;
        proposedImplementation = address(0);
        upgradeProposedTime = 0;
        
        // Reset approvals
        for (uint i = 0; i < upgradeApprovers.length; i++) {
            upgradeApprovals[upgradeApprovers[i]] = false;
        }
        delete upgradeApprovers;
        
        emit UpgradeCancelled(oldImplementation);
    }

    /**
     * @dev Function that should revert when `msg.sender` is not authorized to upgrade the contract
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        // Check if the proposed implementation matches
        if (newImplementation != proposedImplementation) revert NotActiveToken();
        
        // Check timelock
        if (block.timestamp < upgradeProposedTime + UPGRADE_TIMELOCK) revert UpgradeTimelockActive();
        
        // Check if enough approvals
        if (upgradeApprovers.length < requiredUpgradeApprovals) revert NotActiveToken();
        
        // Reset the proposal after successful upgrade
        proposedImplementation = address(0);
        upgradeProposedTime = 0;
        
        // Reset approvals
        for (uint i = 0; i < upgradeApprovers.length; i++) {
            upgradeApprovals[upgradeApprovers[i]] = false;
        }
        delete upgradeApprovers;
    }
    
    // ====================================================
    // 🔹 Minting Functions
    // ====================================================
    
    /**
     * @dev Mint a new token
     * @param to Recipient address
     * @param isERC721 Whether token should be treated as ERC721
     * @param nftType Type of NFT to mint
     */
    function mint(
        address to,
        bool isERC721,
        NFTType nftType
    ) external nonReentrant whenNotPaused returns (uint256) {
        if (to == address(0)) revert InvalidRecipient();
        
        // Fee exemption check - uses role-based exemption
        if (!hasRole(FEE_EXEMPTION_ROLE, msg.sender) && !hasRole(MINTER_ROLE, msg.sender)) {
            // Apply dynamic fee adjustment if enabled
            uint256 currentMintFee = _getCurrentMintFee();
            
            // Transfer fee
            if (!tStakeToken.transferFrom(msg.sender, address(this), currentMintFee)) 
                revert FeeTransferFailed();
            
            // Process fee with split allocation
            _processFee(currentMintFee);
        }
        
        // Mint token with unchecked counter increment for gas savings
        uint256 tokenId;
        unchecked { tokenId = ++totalMinted; }
        
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
    ) external nonReentrant whenNotPaused returns (uint256) {
        if (to == address(0)) revert InvalidRecipient();
        if (mintedReports[reportHash]) revert ReportAlreadyMinted();
        
        // Fee exemption check - uses role-based exemption
        if (!hasRole(FEE_EXEMPTION_ROLE, msg.sender) && !hasRole(MINTER_ROLE, msg.sender)) {
            // Apply dynamic fee adjustment if enabled
            uint256 currentMintFee = _getCurrentMintFee();
            
            // Transfer fee
            if (!tStakeToken.transferFrom(msg.sender, address(this), currentMintFee)) 
                revert FeeTransferFailed();
            
            // Process fee with split allocation
            _processFee(currentMintFee);
        }
        
        // Verify project exists if projects contract is set
        if (projectsContract != address(0)) {
            ITerraStakeProjects(projectsContract).getProject(projectId);
        }
        
        // Mint token with unchecked counter increment for gas savings
        uint256 tokenId;
        unchecked { tokenId = ++totalMinted; }
        
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
        
        emit NFTMinted(to, tokenId, true, NFTType.IMPACT);
        emit ImpactNFTMinted(tokenId, projectId, reportHash, to);
        
        return tokenId;
    }
    
    /**
     * @dev Optimized batch mint function with gas improvements for large batches
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
    ) external nonReentrant whenNotPaused returns (uint256[] memory) {
        uint256 length = to.length;
        if (length == 0 || 
            length != count.length || 
            length != isERC721.length || 
            length != nftType.length) revert ArrayLengthMismatch();
        
        // Calculate total tokens to mint for gas efficiency
        uint256 totalCount = 0;
        for (uint256 i = 0; i < length; i++) {
            if (to[i] == address(0)) revert InvalidRecipient();
            unchecked { totalCount += count[i]; }
        }
        
        // Fee exemption check - uses role-based exemption
        if (!hasRole(FEE_EXEMPTION_ROLE, msg.sender) && !hasRole(MINTER_ROLE, msg.sender)) {
            // Apply dynamic fee adjustment if enabled
            uint256 currentMintFee = _getCurrentMintFee();
            uint256 totalFee = currentMintFee * totalCount;
            
            // Transfer fee
            if (!tStakeToken.transferFrom(msg.sender, address(this), totalFee)) 
                revert FeeTransferFailed();
            
            // Process fee with split allocation
            _processFee(totalFee);
        }
            
        uint256[] memory tokenIds = new uint256[](totalCount);
        uint256 tokenIndex = 0;
        
        for (uint256 i = 0; i < length; i++) {
            for (uint256 j = 0; j < count[i]; j++) {
                // Use unchecked for gas savings
                uint256 tokenId;
                unchecked { 
                    tokenId = ++totalMinted;
                    tokenIds[tokenIndex++] = tokenId;
                }
                
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
                
                emit NFTMinted(to[i], tokenId, isERC721[i], nftType[i]);
            }
        }
        
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
    ) external nonReentrant whenNotPaused returns (uint256) {
        if (to == address(0)) revert InvalidRecipient();
        
        // Fee exemption check - uses role-based exemption
        if (!hasRole(FEE_EXEMPTION_ROLE, msg.sender) && !hasRole(MINTER_ROLE, msg.sender)) {
            // Apply dynamic fee adjustment if enabled
            uint256 currentMintFee = _getCurrentMintFee();
            
            // Transfer fee
            if (!tStakeToken.transferFrom(msg.sender, address(this), currentMintFee)) 
                revert FeeTransferFailed();
            
            // Process fee with split allocation
            _processFee(currentMintFee);
        }
            
        // Mint token with unchecked counter increment for gas savings
        uint256 tokenId;
        unchecked { tokenId = ++totalMinted; }
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
            1 // numWords
        );
        
        // Store token information for callback
        _requestIdToTokenId[requestId] = tokenId;
        _requestIdToRecipient[requestId] = to;
        
        emit NFTMinted(to, tokenId, true, nftType);
        emit RandomnessRequested(requestId, tokenId, to);
        
        return tokenId;
    }
    
    /**
     * @dev Whitelist mint using Merkle proof
     * @param to Recipient address
     * @param nftType Type of NFT to mint 
     * @param proof Merkle proof verifying the recipient is on the whitelist
     */
    function whitelistMint(
        address to,
        NFTType nftType,
        bytes32[] calldata proof
    ) external nonReentrant whenNotPaused returns (uint256) {
        if (!whitelistMintEnabled) revert NotActiveToken();
        if (to == address(0)) revert InvalidRecipient();
        if (hasClaimed[msg.sender]) revert AlreadyClaimed();
        
        // Verify merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
        if (!MerkleProof.verify(proof, whitelistMerkleRoot, leaf)) revert InvalidProof();
        
        // Mark as claimed
        hasClaimed[msg.sender] = true;
        
        // Fee is different for whitelist mints
        if (whitelistMintPrice > 0) {
            if (!tStakeToken.transferFrom(msg.sender, address(this), whitelistMintPrice))
                revert FeeTransferFailed();
            
            // Process fee with split allocation
            _processFee(whitelistMintPrice);
        }
        
        // Mint token with unchecked counter increment for gas savings
        uint256 tokenId;
        unchecked { tokenId = ++totalMinted; }
        
        _mint(to, tokenId, 1, "");
        _isERC721[tokenId] = true;
        nftTypes[tokenId] = nftType;
        
        // Add to type index for optimized lookups
        _typeTokens[nftType].push(tokenId);
        
        // Add to owner tokens for optimized lookups
        _addToOwnerTokens(to, tokenId);
        
        // Set creation metadata
        tokenMetadata[tokenId] = NFTMetadata({
            name: string(abi.encodePacked("TerraStake Whitelist NFT #", _uint256ToString(tokenId))),
            description: "TerraStake Whitelist NFT",
            creationTime: block.timestamp,
            uriIsFrozen: false
        });
        
        emit NFTMinted(to, tokenId, true, nftType);
        
        return tokenId;
    }
    
    // ====================================================
    // 🔹 Fractionalization Functions
    // ====================================================
    
    /**
     * @dev Set the fraction manager contract
     * @param _fractionManager Address of the fraction manager
     */
    function setFractionManager(address _fractionManager) external onlyRole(GOVERNANCE_ROLE) {
        fractionManager = ITerraStakeFractionManager(_fractionManager);
        emit FractionManagerUpdated(_fractionManager);
    }
    
    /**
     * @dev Fractionalize a token into multiple ERC20 tokens
     * @param tokenId ID of the token to fractionalize
     * @param fractionCount Number of fractions to create
     */
    function fractionalize(
        uint256 tokenId,
        uint256 fractionCount
    ) external nonReentrant whenNotPaused returns (uint256) {
        if (!exists(tokenId)) revert TokenDoesNotExist();
        if (balanceOf(msg.sender, tokenId) == 0) revert NotTokenOwner();
        if (fractionCount == 0) revert InvalidAmount();
        
        // Fee exemption check - uses role-based exemption
        if (!hasRole(FEE_EXEMPTION_ROLE, msg.sender) && !hasRole(FRACTIONALIZER_ROLE, msg.sender)) {
            // Apply dynamic fee adjustment if enabled
            uint256 currentFractionalizationFee = _getCurrentFractionalizationFee();
            
            // Transfer fee
            if (!tStakeToken.transferFrom(msg.sender, address(this), currentFractionalizationFee))
                revert FeeTransferFailed();
            
            // Process fee with split allocation
            _processFee(currentFractionalizationFee);
        }
        
        // Create fraction ID
        uint256 fractionId;
        unchecked { fractionId = ++totalMinted; }
        
        // Store fraction info
        _fractionInfos[fractionId] = FractionInfo({
            originalTokenId: tokenId,
            fractionCount: fractionCount,
            fractionalizer: msg.sender,
            isActive: true,
            nftType: nftTypes[tokenId],
            projectId: projectIds[tokenId],
            reportHash: impactReportHashes[tokenId]
        });
        
        // Burn the original token
        _burn(msg.sender, tokenId, 1);
        
        // Mint the fractional token to represent the fractionalized asset
        _mint(msg.sender, fractionId, fractionCount, "");
        
        // If fraction manager is set, create ERC20 tokens
        if (address(fractionManager) != address(0)) {
            fractionManager.createFractionTokens(
                tokenId,
                fractionId,
                fractionCount,
                msg.sender
            );
        }
        
        emit TokenFractionalized(tokenId, fractionId, fractionCount);
        return fractionId;
    }
    
    /**
     * @dev Reunify fractionalized token
     * @param fractionId ID of the fraction token
     */
    function reunify(uint256 fractionId) external nonReentrant whenNotPaused returns (uint256) {
        if (!exists(fractionId)) revert TokenDoesNotExist();
        
        FractionInfo storage info = _fractionInfos[fractionId];
        if (!info.isActive) revert NotActiveToken();
        
        // Check if sender owns all fractions
        if (balanceOf(msg.sender, fractionId) != info.fractionCount) revert NotAllFractionsOwned();
        
        // Burn all fractions
        _burn(msg.sender, fractionId, info.fractionCount);
        
        // Create new token ID
        uint256 newTokenId;
        unchecked { newTokenId = ++totalMinted; }
        
        // Mint the reunified token
        _mint(msg.sender, newTokenId, 1, "");
        _isERC721[newTokenId] = _isERC721[info.originalTokenId];
        nftTypes[newTokenId] = info.nftType;
        
        // If project ID exists, store it
        if (info.projectId != 0) {
            projectIds[newTokenId] = info.projectId;
            _projectTokens[info.projectId].push(newTokenId);
        }
        
        // If report hash exists, store it
        if (info.reportHash != bytes32(0)) {
            impactReportHashes[newTokenId] = info.reportHash;
        }
        
        // If it was an impact certificate, copy it
        if (info.nftType == NFTType.IMPACT) {
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
        
        // If fraction manager is set, burn ERC20 tokens
        if (address(fractionManager) != address(0)) {
            fractionManager.burnFractionTokens(fractionId);
        }
        
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
    function submitVerification(uint256 tokenId) external nonReentrant whenNotPaused {
        if (!exists(tokenId)) revert TokenDoesNotExist();
        if (nftTypes[tokenId] != NFTType.IMPACT) revert NotImpactNFT();
        if (balanceOf(msg.sender, tokenId) < 1) revert NotTokenOwner();
        
        ImpactCertificate storage certificate = impactCertificates[tokenId];
        if (certificate.isVerified) revert AlreadyVerified();
        
        // Fee exemption check - uses role-based exemption
        if (!hasRole(FEE_EXEMPTION_ROLE, msg.sender)) {
            // Apply dynamic fee adjustment if enabled
            uint256 currentVerificationFee = verificationFee;
            if (dynamicFeesEnabled) {
                currentVerificationFee = (verificationFee * feeMultiplier) / 10000;
            }
            
            // Charge verification fee
            if (!tStakeToken.transferFrom(msg.sender, address(this), currentVerificationFee)) 
                revert VerificationFeeFailed();
                
            // Split fee: 90% to treasury, 10% to burn
            uint256 burnAmount = currentVerificationFee / 10;
            uint256 treasuryAmount = currentVerificationFee - burnAmount;
            
            tStakeToken.transfer(treasuryWallet, treasuryAmount);
            ITerraStakeToken(address(tStakeToken)).burn(burnAmount);
            emit TStakeBurned(burnAmount);
        }
    }
    
    // ====================================================
    // 🔹 Dynamic Fee Management
    // ====================================================
    
    /**
     * @dev Enable or disable dynamic fees
     * @param enabled Whether to enable dynamic fees
     * @param multiplier Fee multiplier in basis points (10000 = 100%)
     * @param interval Adjustment interval in seconds
     */
    function setDynamicFees(
        bool enabled, 
        uint256 multiplier, 
        uint256 interval
    ) external onlyRole(FEE_MANAGER_ROLE) {
        if (multiplier == 0) revert InvalidFeeParameters();
        
        dynamicFeesEnabled = enabled;
        feeMultiplier = multiplier;
        feeAdjustmentInterval = interval;
        
        emit DynamicFeesUpdated(enabled, multiplier, interval);
    }
    
    /**
     * @dev Update fees based on external conditions
     * @param newMultiplier New fee multiplier in basis points
     */
    function updateFeeMultiplier(uint256 newMultiplier) external onlyRole(FEE_MANAGER_ROLE) {
        if (newMultiplier == 0) revert InvalidFeeParameters();
        if (block.timestamp < lastFeeAdjustment + feeAdjustmentInterval) revert UpgradeTimelockActive();
        
        feeMultiplier = newMultiplier;
        lastFeeAdjustment = block.timestamp;
        
        // Calculate new fees
        uint256 newMintFee = (baseMintFee * feeMultiplier) / 10000;
        uint256 newFractionalizationFee = (baseFractionalizationFee * feeMultiplier) / 10000;
        uint256 newVerificationFee = (newMintFee * 2); // Verification fee is 2x mint fee
        
        mintFee = newMintFee;
        fractionalizationFee = newFractionalizationFee;
        verificationFee = newVerificationFee;
        
        emit FeesAdjusted(newMintFee, newFractionalizationFee, newVerificationFee);
    }
    
    /**
     * @dev Get current mint fee with dynamic adjustment if enabled
     * @return Current mint fee
     */
    function _getCurrentMintFee() internal view returns (uint256) {
        if (!dynamicFeesEnabled) return mintFee;
        return (baseMintFee * feeMultiplier) / 10000;
    }
    
    /**
     * @dev Get current fractionalization fee with dynamic adjustment if enabled
     * @return Current fractionalization fee
     */
    function _getCurrentFractionalizationFee() internal view returns (uint256) {
        if (!dynamicFeesEnabled) return fractionalizationFee;
        return (baseFractionalizationFee * feeMultiplier) / 10000;
    }
    
    /**
     * @dev Process fee with allocation to different purposes
     * @param feeAmount Total fee amount to process
     */
    function _processFee(uint256 feeAmount) internal {
        // Split fee: 70% to treasury, 20% to staking rewards, 10% to burn
        uint256 burnAmount = feeAmount / 10;
        uint256 stakingAmount = feeAmount * 2 / 10;
        uint256 treasuryAmount = feeAmount - burnAmount - stakingAmount;
        
        // Transfer to treasury
        tStakeToken.transfer(treasuryWallet, treasuryAmount);
        
        // Burn tokens
        ITerraStakeToken(address(tStakeToken)).burn(burnAmount);
        emit TStakeBurned(burnAmount);
    }
    
    // ====================================================
    // 🔹 EIP-2981 Royalty Implementation
    // ====================================================
    
    /**
     * @dev Set default royalty information
     * @param receiver Address to receive royalties
     * @param percentage Royalty percentage (in basis points, 10000 = 100%)
     */
    function setDefaultRoyalty(address receiver, uint256 percentage) external onlyRole(GOVERNANCE_ROLE) {
        if (percentage > 5000) revert InvalidRoyaltyParameters(); // Max 50%
        if (receiver == address(0)) revert InvalidRecipient();
        
        defaultRoyaltyPercentage = percentage;
        royaltyReceiver = receiver;
        
        emit RoyaltyUpdated(receiver, percentage);
    }
    
    /**
     * @dev Set custom royalty for a specific token
     * @param tokenId Token ID to set royalty for
     * @param receiver Address to receive royalties
     * @param percentage Royalty percentage (in basis points, 10000 = 100%)
     */
    function setTokenRoyalty(
        uint256 tokenId,
        address receiver,
        uint256 percentage
    ) external onlyRole(GOVERNANCE_ROLE) {
        if (!exists(tokenId)) revert TokenDoesNotExist();
        if (percentage > 5000) revert InvalidRoyaltyParameters(); // Max 50%
        if (receiver == address(0)) revert InvalidRecipient();
        
        customRoyaltyPercentages[tokenId] = percentage;
        customRoyaltyReceivers[tokenId] = receiver;
    }
    
    /**
     * @dev EIP-2981 royalty info implementation
     * @param tokenId Token ID to query
     * @param salePrice Sale price to calculate royalty from
     * @return receiver Address to receive royalties
     * @return royaltyAmount Amount of royalty to pay
     */
    function royaltyInfo(
        uint256 tokenId,
        uint256 salePrice
    ) external view override returns (address receiver, uint256 royaltyAmount) {
        emit RoyaltyInfoRequested(tokenId, salePrice);
        
        // Check for custom royalty first
        if (customRoyaltyReceivers[tokenId] != address(0)) {
            uint256 percentage = customRoyaltyPercentages[tokenId];
            return (customRoyaltyReceivers[tokenId], (salePrice * percentage) / 10000);
        }
        
        // Fall back to default royalty
        return (royaltyReceiver, (salePrice * defaultRoyaltyPercentage) / 10000);
    }
    
    // ====================================================
    // 🔹 Marketplace Integration
    // ====================================================
    
    /**
     * @dev Set marketplace status
     * @param enabled Whether to enable marketplace integration
     * @param marketplace Address of the marketplace
     */
    function setMarketplaceStatus(bool enabled, address marketplace) external onlyRole(GOVERNANCE_ROLE) {
        if (enabled && marketplace == address(0)) revert InvalidRecipient();
        
        marketplaceEnabled = enabled;
        if (enabled) {
            marketplaceAddress = marketplace;
            _grantRole(MARKETPLACE_ROLE, marketplace);
        }
        
        emit MarketplaceStatusChanged(enabled);
        emit MarketplaceAddressUpdated(marketplace);
    }
    
    /**
     * @dev Approve marketplace for all tokens (ERC1155 doesn't have single token approval)
     * @param marketplace Address of the marketplace to approve
     * @param approved Whether to approve or revoke
     */
    function setApprovedMarketplace(address marketplace, bool approved) external onlyRole(GOVERNANCE_ROLE) {
        approvedMarketplaces[marketplace] = approved;
        emit MarketplaceApprovalChanged(marketplace, approved);
    }
    
    /**
     * @dev Approve token for marketplace listing
     * @param tokenId Token ID to approve
     * @param marketplace Address of the marketplace
     * @param approved Whether to approve or revoke
     */
    function approveMarketplaceListing(uint256 tokenId, address marketplace, bool approved) external {
        if (!exists(tokenId)) revert TokenDoesNotExist();
        if (balanceOf(msg.sender, tokenId) == 0) revert NotTokenOwner();
        if (!approvedMarketplaces[marketplace]) revert ApprovalFailed();
        
        tokenApprovedForMarketplace[tokenId] = approved;
        emit TokenApprovedForMarketplace(tokenId, marketplace, approved);
    }
    
    // ====================================================
    // 🔹 Metadata Functions
    // ====================================================
    
    /**
     * @dev Set base URI for tokens
     * @param newBaseURI New base URI
     */
    function setBaseURI(string calldata newBaseURI) external onlyRole(GOVERNANCE_ROLE) {
        _baseURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }
    
    /**
     * @dev Set custom URI for a specific token
     * @param tokenId Token ID to set URI for
     * @param tokenURI New token URI
     */
    function setTokenURI(uint256 tokenId, string calldata tokenURI) external {
        if (!exists(tokenId)) revert TokenDoesNotExist();
        if (balanceOf(msg.sender, tokenId) == 0 && !hasRole(GOVERNANCE_ROLE, msg.sender)) 
            revert NotTokenOwner();
        if (tokenMetadata[tokenId].uriIsFrozen) revert TokenURIFrozen(tokenId);
        
        _tokenURIs[tokenId] = tokenURI;
    }
    
    /**
     * @dev Freeze token URI to prevent further changes
     * @param tokenId Token ID to freeze URI for
     */
    function freezeTokenURI(uint256 tokenId) external {
        if (!exists(tokenId)) revert TokenDoesNotExist();
        if (balanceOf(msg.sender, tokenId) == 0 && !hasRole(GOVERNANCE_ROLE, msg.sender)) 
            revert NotTokenOwner();
            
        tokenMetadata[tokenId].uriIsFrozen = true;
        emit TokenURIFrozen(tokenId);
    }
    
    /**
     * @dev Set attribute for a token
     * @param tokenId Token ID to set attribute for
     * @param key Attribute key
     * @param value Attribute value
     */
    function setTokenAttribute(uint256 tokenId, string calldata key, string calldata value) external {
        if (!exists(tokenId)) revert TokenDoesNotExist();
        if (balanceOf(msg.sender, tokenId) == 0 && !hasRole(GOVERNANCE_ROLE, msg.sender)) 
            revert NotTokenOwner();
            
        tokenAttributes[tokenId][key] = value;
    }
    
    /**
     * @dev Set the metadata renderer contract
     * @param _metadataRenderer Address of the metadata renderer
     */
    function setMetadataRenderer(address _metadataRenderer) external onlyRole(GOVERNANCE_ROLE) {
        metadataRenderer = ITerraStakeMetadataRenderer(_metadataRenderer);
        emit MetadataRendererUpdated(_metadataRenderer);
    }
    
    /**
     * @dev Get token URI
     * @param tokenId Token ID to get URI for
     * @return Token URI
     */
    function uri(uint256 tokenId) public view override returns (string memory) {
        if (!exists(tokenId)) revert TokenDoesNotExist();
        
        // Check for custom URI first
        string memory customURI = _tokenURIs[tokenId];
        if (bytes(customURI).length > 0) {
            return customURI;
        }
        
        // If we have a metadata renderer and this is an impact certificate
        if (address(metadataRenderer) != address(0) && nftTypes[tokenId] == NFTType.IMPACT) {
            ImpactCertificate storage certificate = impactCertificates[tokenId];
            if (certificate.reportHash != bytes32(0)) {
                // Generate dynamic SVG based on impact data
                return metadataRenderer.generateSVG(
                    uint8(certificate.projectId % 5), // Use project ID modulo 5 as category
                    certificate.impactValue,
                    certificate.impactType,
                    certificate.location
                );
            }
        }
        
        // Fall back to default URI
        return string(abi.encodePacked(_baseURI, _uint256ToString(tokenId)));
    }
    
    // ====================================================
    // 🔹 Chainlink VRF Functions
    // ====================================================
    
    /**
     * @dev Callback function used by VRF Coordinator
     * @param requestId ID of the randomness request
     * @param randomWords Random results from VRF
     */
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) internal override {
        uint256 tokenId = _requestIdToTokenId[requestId];
        address recipient = _requestIdToRecipient[requestId];
        
        if (tokenId == 0 || recipient == address(0)) return;
        
        uint256 randomNumber = randomWords[0];
        
        // Apply randomness to token attributes
        string memory rarity = _determineRarity(randomNumber);
        tokenAttributes[tokenId]["rarity"] = rarity;
        
        emit RandomnessReceived(requestId, tokenId, randomNumber);
    }
    
    // ====================================================
    // 🔹 Whitelist Functions
    // ====================================================
    
    /**
     * @dev Set whitelist status and price
     * @param enabled Whether to enable whitelist minting
     * @param price Price for whitelist minting
     */
    function setWhitelistMinting(bool enabled, uint256 price) external onlyRole(GOVERNANCE_ROLE) {
        whitelistMintEnabled = enabled;
        whitelistMintPrice = price;
        
        emit WhitelistMintingEnabled(enabled, price);
    }
    
    /**
     * @dev Set whitelist Merkle root
     * @param newRoot New Merkle root
     */
    function setWhitelistMerkleRoot(bytes32 newRoot) external onlyRole(GOVERNANCE_ROLE) {
        whitelistMerkleRoot = newRoot;
        
        emit WhitelistRootUpdated(newRoot);
    }
    
    // ====================================================
    // 🔹 Project Management Functions
    // ====================================================
    
    /**
     * @dev Set the projects contract address
     * @param _projectsContract Address of the projects contract
     */
    function setProjectsContract(address _projectsContract) external onlyRole(GOVERNANCE_ROLE) {
        projectsContract = _projectsContract;
        emit ProjectsContractUpdated(_projectsContract);
    }
    
    // ====================================================
    // 🔹 Admin Functions
    // ====================================================
    
    /**
     * @dev Set fees
     * @param _mintFee Fee for minting NFTs
     * @param _fractionalizationFee Fee for fractionalizing NFTs
     * @param _verificationFee Fee for verification
     */
    function setFees(
        uint256 _mintFee,
        uint256 _fractionalizationFee,
        uint256 _verificationFee
    ) external onlyRole(FEE_MANAGER_ROLE) {
        mintFee = _mintFee;
        baseMintFee = _mintFee;
        fractionalizationFee = _fractionalizationFee;
        baseFractionalizationFee = _fractionalizationFee;
        verificationFee = _verificationFee;
        
        emit FeesAdjusted(_mintFee, _fractionalizationFee, _verificationFee);
    }
    
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
     * @return
    function getFractionInfo(uint256 fractionId) external view returns (
        uint256 originalTokenId,
        uint256 fractionCount,
        address fractionalizer,
        bool isActive,
        NFTType nftType,
        uint256 projectId,
        bytes32 reportHash
    ) {
        FractionInfo storage info = _fractionInfos[fractionId];
        return (
            info.originalTokenId,
            info.fractionCount,
            info.fractionalizer,
            info.isActive,
            info.nftType,
            info.projectId,
            info.reportHash
        );
    }
    
    /**
     * @dev Get all tokens owned by an address
     * @param owner Owner address
     * @return Array of token IDs
     */
    function tokensOfOwner(address owner) external view returns (uint256[] memory) {
        return _ownerTokens[owner];
    }
    
    /**
     * @dev Get all tokens in a project
     * @param projectId Project ID
     * @return Array of token IDs
     */
    function tokensInProject(uint256 projectId) external view returns (uint256[] memory) {
        return _projectTokens[projectId];
    }
    
    /**
     * @dev Check if token is treated as ERC721
     * @param tokenId Token ID to check
     * @return Whether token is treated as ERC721
     */
    function isERC721(uint256 tokenId) external view returns (bool) {
        return _isERC721[tokenId];
    }
    
    // ====================================================
    // 🔹 Helper Functions
    // ====================================================
    
    /**
     * @dev Add token to owner's token list for optimized lookups
     * @param owner Owner address
     * @param tokenId Token ID to add
     */
    function _addToOwnerTokens(address owner, uint256 tokenId) internal {
        _ownerTokens[owner].push(tokenId);
    }
    
    /**
     * @dev Remove token from owner's token list
     * @param owner Owner address
     * @param tokenId Token ID to remove
     */
    function _removeFromOwnerTokens(address owner, uint256 tokenId) internal {
        uint256[] storage tokens = _ownerTokens[owner];
        uint256 length = tokens.length;
        
        for (uint256 i = 0; i < length; i++) {
            if (tokens[i] == tokenId) {
                // Swap with last element and pop
                tokens[i] = tokens[length - 1];
                tokens.pop();
                break;
            }
        }
    }
    
    /**
     * @dev Convert uint256 to string
     * @param value Value to convert
     * @return String representation
     */
    function _uint256ToString(uint256 value) internal pure returns (string memory) {
        // Special case for 0
        if (value == 0) {
            return "0";
        }
        
        // Calculate string length
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        
        // Create output string
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        
        return string(buffer);
    }
    
    /**
     * @dev Determine rarity based on random number
     * @param randomNumber Random number
     * @return Rarity string
     */
    function _determineRarity(uint256 randomNumber) internal pure returns (string memory) {
        uint256 rarityValue = randomNumber % 100;
        
        if (rarityValue < 5) return "Legendary";
        if (rarityValue < 15) return "Epic";
        if (rarityValue < 35) return "Rare";
        if (rarityValue < 65) return "Uncommon";
        return "Common";
    }
    
    // ====================================================
    // 🔹 ERC1155SupplyUpgradeable Overrides
    // ====================================================
    
    /**
     * @dev Override _beforeTokenTransfer to handle special cases
     */
    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal override(ERC1155Upgradeable, ERC1155SupplyUpgradeable) {
        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);
        
        // Handle ownership tracking for optimized lookups
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 tokenId = ids[i];
            
            // This is a transfer (not mint or burn)
            if (from != address(0) && to != address(0)) {
                _removeFromOwnerTokens(from, tokenId);
                _addToOwnerTokens(to, tokenId);
            }
            // This is a mint
            else if (from == address(0)) {
                _addToOwnerTokens(to, tokenId);
            }
            // This is a burn
            else if (to == address(0)) {
                _removeFromOwnerTokens(from, tokenId);
            }
        }
    }
    
    // ====================================================
    // 🔹 Blockchain Protection and Support Functions
    // ====================================================
    
    /**
     * @dev Check for ERC1155 support in receiver contracts
     * @param from Sender address
     * @param to Recipient address
     */
    function _checkSafeRecipient(address from, address to) internal view {
        if (to.code.length > 0 && from != address(0) && !ERC1155Upgradeable._checkContractOnERC1155Received(from, to, 0, 0, "")) {
            revert InvalidRecipient();
        }
    }

    /**
     * @dev Support for introspection
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155Upgradeable, AccessControlUpgradeable, IERC165Upgradeable)
        returns (bool)
    {
        return interfaceId == type(IERC2981Upgradeable).interfaceId ||
               super.supportsInterface(interfaceId);
    }
}
