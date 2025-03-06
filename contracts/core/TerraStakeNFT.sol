// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {ERC1155Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {ERC1155SupplyUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155SupplyUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC2981Upgradeable} from "@openzeppelin/contracts-upgradeable/interfaces/IERC2981Upgradeable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {VRFCoordinatorV2Interface} from "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import {VRFConsumerBaseV2} from "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title TerraStakeNFT
 * @notice Advanced environmental impact NFT system with fractionalization, verification, and impact tracking
 * @dev Implements ERC1155, ERC2981, VRF, and UUPS upgradeable patterns
 * @custom:security-contact security@terrastake.io
 */
contract TerraStakeNFT is 
    Initializable, 
    ERC1155Upgradeable, 
    ERC1155SupplyUpgradeable, 
    AccessControlUpgradeable, 
    PausableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable, 
    IERC2981Upgradeable,
    VRFConsumerBaseV2
{
    using SafeERC20 for IERC20;
    using Strings for uint256;

    // ====================================================
    // 📝 Type Definitions
    // ====================================================
    
    enum NFTType {
        STANDARD,
        IMPACT,
        LAND,
        CARBON,
        BIODIVERSITY
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

    struct TokenRoyalty {
        address receiver;
        uint96 royaltyFraction;
    }

    // ====================================================
    // 🔐 Access Control Roles
    // ====================================================
    
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant FRACTIONALIZER_ROLE = keccak256("FRACTIONALIZER_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 public constant FEE_EXEMPTION_ROLE = keccak256("FEE_EXEMPTION_ROLE");
    bytes32 public constant MARKETPLACE_ROLE = keccak256("MARKETPLACE_ROLE");
    bytes32 public constant URI_SETTER_ROLE = keccak256("URI_SETTER_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    
    // ====================================================
    // 💰 Fee Management
    // ====================================================
    
    IERC20 public tStakeToken;
    
    address public treasuryWallet;
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 public mintFee;
    uint256 public fractionalizationFee;
    uint256 public verificationFee;
    uint256 public transferFee;
    
    // Fee distribution percentages (base 1000)
    uint16 public burnPercent = 500;       // 50%
    uint16 public treasuryPercent = 450;   // 45%
    uint16 public buybackPercent = 50;     // 5%
    uint256 public accumulatedBuybackFunds;
    
    // Dynamic fee variables
    bool public dynamicFeesEnabled;
    uint256 public feeMultiplier;
    uint256 public feeAdjustmentInterval;
    uint256 public lastFeeAdjustment;
    uint256 public baseMintFee;
    uint256 public baseFractionalizationFee;
    
    // Token and metadata storage
    mapping(uint256 => NFTMetadata) public tokenMetadata;
    mapping(uint256 => string) private _tokenURIs;
    mapping(uint256 => bool) public uriLocked;
    mapping(uint256 => TokenRoyalty) internal _tokenRoyalties;
    mapping(uint256 => ImpactCertificate) public impactCertificates;
    mapping(uint256 => FractionInfo) public fractionInfo;
    
    // Project category mappings
    mapping(uint256 => ProjectCategory) public projectCategories;
    mapping(ProjectCategory => uint256[]) private _categoryProjects;
    
    // Verification registry
    mapping(uint256 => mapping(bytes32 => bool)) public verifiedReports;
    mapping(bytes32 => uint256) public reportToToken;
    
    // Fractionalization mappings
    mapping(uint256 => uint256[]) public originalToFractions;
    mapping(uint256 => uint256) public fractionToOriginal;
    
    // Default royalty settings
    address public defaultRoyaltyReceiver;
    uint96 public defaultRoyaltyPercentage;
    
    // VRF related variables
    VRFCoordinatorV2Interface public COORDINATOR;
    bytes32 public keyHash;
    uint64 public subscriptionId;
    uint32 public callbackGasLimit;
    uint16 public requestConfirmations;
    uint32 public numWords;
    mapping(uint256 => address) public vrfRequests;
    
    // Token ID tracking
    uint256 private _currentTokenId;
    
    // Marketplace integration
    address public marketplaceAddress;
    
    // ====================================================
    // 📣 Events
    // ====================================================
    
    event TokenMinted(uint256 indexed tokenId, address indexed to, NFTType nftType, ProjectCategory category);
    event ImpactCertificateCreated(uint256 indexed tokenId, uint256 indexed projectId, bytes32 reportHash);
    event TokenFractionalized(uint256 indexed originalTokenId, uint256[] fractionIds, uint256 fractionCount);
    event TokensReassembled(uint256 indexed originalTokenId, address indexed owner);
    event TokenURIUpdated(uint256 indexed tokenId, string newUri);
    event TokenURILocked(uint256 indexed tokenId);
    event RoyaltySet(uint256 indexed tokenId, address receiver, uint96 royaltyFraction);
    event DefaultRoyaltySet(address receiver, uint96 royaltyFraction);
    event FeeConfigured(uint256 mintFee, uint256 fractionalizationFee, uint256 verificationFee, uint256 transferFee);
    event FeePercentagesUpdated(uint16 burnPercent, uint16 treasuryPercent, uint16 buybackPercent);
    event TreasuryWalletUpdated(address newTreasuryWallet);
    event FeesCollected(address from, uint256 amount, uint256 burnAmount, uint256 treasuryAmount, uint256 buybackAmount);
    event DynamicFeesToggled(bool enabled);
    event MarketplaceSet(address marketplaceAddress);
    event ImpactVerified(uint256 indexed tokenId, bytes32 reportHash, address verifier);
    event VRFConfigured(address coordinator, bytes32 keyHash, uint64 subId, uint32 callbackGasLimit, uint16 requestConfirmations);
    event RandomnessRequested(uint256 requestId, address requester);
    event RandomnessReceived(uint256 requestId, uint256[] randomWords);
    event TokensBurned(uint256 amount);
    event BuybackExecuted(uint256 amount);
    event EmergencyWithdrawal(address token, address to, uint256 amount);
    
    // ====================================================
    // 🚨 Errors
    // ====================================================
    
    error InvalidAddress();
    error InsufficientFunds();
    error TransferFailed();
    error TokenNotFractionalized();
    error TokenAlreadyFractionalized();
    error NotTokenOwner();
    error URILocked();
    error ZeroAmount();
    error InvalidFeeConfiguration();
    error InvalidRoyaltyPercentage();
    error InvalidPercentages();
    error IncompleteCollection();
    error AlreadyVerified();
    error FractionMismatch();
    error InvalidTokenId();
    error NoBuybackFunds();
    error NotOriginalOwner();
    error PermissionsRequired();
    error EmergencyModeActive();
    error Unauthorized();
    
    // ====================================================
    // 🔒 Modifiers
    // ====================================================
    
    modifier onlyTokenOwner(uint256 tokenId) {
        if (balanceOf(msg.sender, tokenId) == 0) revert NotTokenOwner();
        _;
    }

    modifier notEmergencyMode() {
        if (paused()) revert EmergencyModeActive();
        _;
    }

    // ====================================================
    // 🚀 Initialization
    // ====================================================
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _vrfCoordinator) VRFConsumerBaseV2(_vrfCoordinator) {
        _disableInitializers();
    }
    
    /**
     * @notice Initializes the contract with required parameters
     * @param admin The admin address
     * @param _tStakeToken The TerraStake token address
     * @param _treasuryWallet The treasury wallet address
     * @param _uri Base URI for token metadata
     * @param _vrfCoordinator VRF coordinator address
     * @param _keyHash VRF key hash
     * @param _subscriptionId Chainlink VRF subscription ID
     */
    function initialize(
        address admin,
        address _tStakeToken,
        address _treasuryWallet,
        string memory _uri,
        address _vrfCoordinator,
        bytes32 _keyHash,
        uint64 _subscriptionId
    ) external initializer {
        if (admin == address(0) || _tStakeToken == address(0) || _treasuryWallet == address(0) || 
            _vrfCoordinator == address(0)) revert InvalidAddress();
        
        __ERC1155_init(_uri);
        __ERC1155Supply_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(FRACTIONALIZER_ROLE, admin);
        _grantRole(VERIFIER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(FEE_MANAGER_ROLE, admin);
        _grantRole(URI_SETTER_ROLE, admin);
        _grantRole(VALIDATOR_ROLE, admin);
        
        tStakeToken = IERC20(_tStakeToken);
        treasuryWallet = _treasuryWallet;
        
        // Set initial fees
        // Set initial fees
        mintFee = 100 * 10**18;  // 100 TSTAKE
        fractionalizationFee = 50 * 10**18;  // 50 TSTAKE
        verificationFee = 75 * 10**18;  // 75 TSTAKE
        transferFee = 10 * 10**18;  // 10 TSTAKE
        
        // Set base fees for dynamic fee system
        baseMintFee = mintFee;
        baseFractionalizationFee = fractionalizationFee;
        feeMultiplier = 1000; // Base 1000 (1.0)
        feeAdjustmentInterval = 7 days;
        lastFeeAdjustment = block.timestamp;
        
        // Set default royalty
        defaultRoyaltyReceiver = _treasuryWallet;
        defaultRoyaltyPercentage = 250; // 2.5% (basis points)
        
        // Configure VRF
        COORDINATOR = VRFCoordinatorV2Interface(_vrfCoordinator);
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;
        callbackGasLimit = 2500000;
        requestConfirmations = 3;
        numWords = 1;
        
        emit FeeConfigured(mintFee, fractionalizationFee, verificationFee, transferFee);
        emit FeePercentagesUpdated(burnPercent, treasuryPercent, buybackPercent);
        emit TreasuryWalletUpdated(_treasuryWallet);
        emit DefaultRoyaltySet(defaultRoyaltyReceiver, defaultRoyaltyPercentage);
        emit VRFConfigured(_vrfCoordinator, _keyHash, _subscriptionId, callbackGasLimit, requestConfirmations);
    }
    
    /**
     * @dev Function that should revert when msg.sender is not authorized to upgrade the contract.
     * Called by {upgradeTo} and {upgradeToAndCall}.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
    
    // ====================================================
    // 🏭 Token Minting Functions
    // ====================================================
    
    /**
     * @notice Mints a standard NFT
     * @param to The recipient address
     * @param amount The amount to mint
     * @param category The project category
     * @param uri The token URI
     * @return tokenId The newly minted token ID
     */
    function mintStandardNFT(
        address to,
        uint256 amount,
        ProjectCategory category,
        string calldata uri
    ) external nonReentrant notEmergencyMode returns (uint256) {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();
        
        // Handle fees unless exempt
        if (!hasRole(FEE_EXEMPTION_ROLE, msg.sender)) {
            _collectFee(msg.sender, mintFee);
        }
        
        // Generate new token ID
        uint256 tokenId = _generateTokenId();
        
        // Mint tokens
        _mint(to, tokenId, amount, "");
        
        // Store metadata
        tokenMetadata[tokenId] = NFTMetadata({
            name: string(abi.encodePacked("TerraStake NFT #", tokenId.toString())),
            description: "TerraStake Standard Environmental NFT",
            creationTime: block.timestamp,
            uriIsFrozen: false,
            nftType: NFTType.STANDARD,
            category: category
        });
        
        _tokenURIs[tokenId] = uri;
        projectCategories[tokenId] = category;
        _categoryProjects[category].push(tokenId);
        
        emit TokenMinted(tokenId, to, NFTType.STANDARD, category);
        
        return tokenId;
    }
    
    /**
     * @notice Mints an impact certificate NFT
     * @param to The recipient address
     * @param projectId The associated project ID
     * @param reportHash The unique hash of the impact report
     * @param uri The token URI
     * @param impactValue The quantified impact value
     * @param impactType The type of impact (e.g., "Carbon Reduction", "Trees Planted")
     * @param location Geographic location of the impact
     * @param category The project category
     * @return tokenId The newly minted token ID
     */
    function mintImpactNFT(
        address to,
        uint256 projectId,
        string calldata uri,
        bytes32 reportHash
    ) external nonReentrant whenNotPaused returns (uint256) {
        // Verify caller has MINTER_ROLE or VALIDATOR_ROLE
        if (!hasRole(MINTER_ROLE, msg.sender) && !hasRole(VALIDATOR_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        
        if (to == address(0)) revert InvalidAddress();
        if (reportToToken[reportHash] != 0) revert AlreadyVerified();
        
        // Generate new token ID
        uint256 tokenId = _generateTokenId();
        
        // Determine project category - for external callers we'll use a default
        ProjectCategory category = ProjectCategory.CarbonCredit;
        // Try to get the actual category if available
        if (projectCategories[projectId] != ProjectCategory(0)) {
            category = projectCategories[projectId];
        }
        
        // Mint token
        _mint(to, tokenId, 1, "");
        
        // Store metadata
        tokenMetadata[tokenId] = NFTMetadata({
            name: string(abi.encodePacked("TerraStake Impact Certificate #", tokenId.toString())),
            description: "TerraStake Environmental Impact Certificate",
            creationTime: block.timestamp,
            uriIsFrozen: false,
            nftType: NFTType.IMPACT,
            category: category
        });
        
        // Create impact certificate
        impactCertificates[tokenId] = ImpactCertificate({
            projectId: projectId,
            reportHash: reportHash,
            impactValue: 0, // To be updated with verification
            impactType: "",
            verificationDate: 0,
            location: "",
            verifier: address(0),
            isVerified: false,
            category: category
        });
        
        _tokenURIs[tokenId] = uri;
        projectCategories[tokenId] = category;
        _categoryProjects[category].push(tokenId);
        reportToToken[reportHash] = tokenId;
        
        emit TokenMinted(tokenId, to, NFTType.IMPACT, category);
        emit ImpactCertificateCreated(tokenId, projectId, reportHash);
        
        return tokenId;
    }
    
    /**
     * @notice Updates the impact certificate with verification details
     * @param tokenId The token ID to verify
     * @param impactValue The quantified impact value
     * @param impactType The type of impact
     * @param location Geographic location of the impact
     */
    function verifyImpactCertificate(
        uint256 tokenId,
        uint256 impactValue,
        string calldata impactType,
        string calldata location
    ) external nonReentrant onlyRole(VERIFIER_ROLE) notEmergencyMode {
        if (!exists(tokenId)) revert InvalidTokenId();
        if (impactCertificates[tokenId].isVerified) revert AlreadyVerified();
        
        // Handle verification fee
        if (!hasRole(FEE_EXEMPTION_ROLE, msg.sender)) {
            _collectFee(msg.sender, verificationFee);
        }
        
        ImpactCertificate storage certificate = impactCertificates[tokenId];
        
        certificate.impactValue = impactValue;
        certificate.impactType = impactType;
        certificate.location = location;
        certificate.verificationDate = block.timestamp;
        certificate.verifier = msg.sender;
        certificate.isVerified = true;
        
        verifiedReports[certificate.projectId][certificate.reportHash] = true;
        
        emit ImpactVerified(tokenId, certificate.reportHash, msg.sender);
    }
    
    // ====================================================
    // 🔄 Fractionalization Functions
    // ====================================================
    
    /**
     * @notice Fractionalizes an existing NFT into multiple shares
     * @param tokenId The token ID to fractionalize
     * @param fractionCount The number of fractions to create
     * @return fractionIds Array of new fraction token IDs
     */
    function fractionalizeToken(uint256 tokenId, uint256 fractionCount) 
        external 
        nonReentrant 
        onlyTokenOwner(tokenId) 
        notEmergencyMode 
        returns (uint256[] memory)
    {
        if (!exists(tokenId)) revert InvalidTokenId();
        if (fractionCount == 0) revert ZeroAmount();
        if (fractionInfo[tokenId].isActive) revert TokenAlreadyFractionalized();
        
        // Only original NFTs can be fractionalized, not fractions themselves
        if (fractionToOriginal[tokenId] != 0) revert TokenAlreadyFractionalized();
        
        // Handle fractionalization fee
        if (!hasRole(FEE_EXEMPTION_ROLE, msg.sender)) {
            _collectFee(msg.sender, fractionalizationFee);
        }
        
        // Burn the original token
        _burn(msg.sender, tokenId, 1);
        
        // Create the fraction tokens
        uint256[] memory fractionIds = new uint256[](fractionCount);
        
        for (uint256 i = 0; i < fractionCount; i++) {
            uint256 fractionId = _generateTokenId();
            fractionIds[i] = fractionId;
            
            // Mint fraction token
            _mint(msg.sender, fractionId, 1, "");
            
            // Create mapping from fraction to original
            fractionToOriginal[fractionId] = tokenId;
            
            // Store fraction metadata
            tokenMetadata[fractionId] = NFTMetadata({
                name: string(abi.encodePacked("Fraction #", i.toString(), " of TerraStake NFT #", tokenId.toString())),
                description: "TerraStake Fractionalized Environmental NFT",
                creationTime: block.timestamp,
                uriIsFrozen: false,
                nftType: tokenMetadata[tokenId].nftType,
                category: tokenMetadata[tokenId].category
            });
            
            // Use same URI for fractions
            _tokenURIs[fractionId] = _tokenURIs[tokenId];
            
            // Add to category projects if needed
            projectCategories[fractionId] = tokenMetadata[tokenId].category;
            _categoryProjects[tokenMetadata[tokenId].category].push(fractionId);
        }
        
        // Record fractionalization info
        fractionInfo[tokenId] = FractionInfo({
            originalTokenId: tokenId,
            fractionCount: fractionCount,
            fractionalizer: msg.sender,
            isActive: true,
            nftType: tokenMetadata[tokenId].nftType,
            projectId: tokenMetadata[tokenId].nftType == NFTType.IMPACT ? impactCertificates[tokenId].projectId : 0,
            reportHash: tokenMetadata[tokenId].nftType == NFTType.IMPACT ? impactCertificates[tokenId].reportHash : bytes32(0),
            category: tokenMetadata[tokenId].category
        });
        
        // Store relation between original and fractions
        originalToFractions[tokenId] = fractionIds;
        
        emit TokenFractionalized(tokenId, fractionIds, fractionCount);
        
        return fractionIds;
    }
    
    /**
     * @notice Reassembles fractionalized tokens back into the original
     * @param originalTokenId The original token ID
     */
    function reassembleToken(uint256 originalTokenId) external nonReentrant notEmergencyMode {
        if (!fractionInfo[originalTokenId].isActive) revert TokenNotFractionalized();
        
        FractionInfo storage info = fractionInfo[originalTokenId];
        uint256[] memory fractions = originalToFractions[originalTokenId];
        
        // Check that sender owns all fractions
        for (uint256 i = 0; i < fractions.length; i++) {
            if (balanceOf(msg.sender, fractions[i]) == 0) revert IncompleteCollection();
        }
        
        // Burn all fraction tokens
        for (uint256 i = 0; i < fractions.length; i++) {
            _burn(msg.sender, fractions[i], 1);
            fractionToOriginal[fractions[i]] = 0; // Clear mapping
        }
        
        // Restore original token
        _mint(msg.sender, originalTokenId, 1, "");
        
        // Clear fractionalization data
        fractionInfo[originalTokenId].isActive = false;
        
        emit TokensReassembled(originalTokenId, msg.sender);
    }
    
    // ====================================================
    // 🖼️ URI Management
    // ====================================================
    
    /**
     * @notice Sets the URI for a specific token
     * @param tokenId The token ID
     * @param newUri The new URI
     */
    function setTokenURI(uint256 tokenId, string calldata newUri) 
        external 
        nonReentrant 
        notEmergencyMode 
    {
        if (!exists(tokenId)) revert InvalidTokenId();
        if (uriLocked[tokenId]) revert URILocked();
        
        // Check permission - must be token owner, URI setter, or admin
        bool isOwner = balanceOf(msg.sender, tokenId) > 0;
        if (!isOwner && !hasRole(URI_SETTER_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert NotTokenOwner();
        }
        
        _tokenURIs[tokenId] = newUri;
        
        emit TokenURIUpdated(tokenId, newUri);
    }
    
    /**
     * @notice Permanently locks a token's URI so it can't be changed
     * @param tokenId The token ID to lock
     */
    function lockTokenURI(uint256 tokenId) external onlyRole(GOVERNANCE_ROLE) {
        if (!exists(tokenId)) revert InvalidTokenId();
        
        uriLocked[tokenId] = true;
        
        emit TokenURILocked(tokenId);
    }
    
    /**
     * @notice Returns the URI for a given token ID
     * @param tokenId The token ID to query
     * @return The token's URI
     */
    function uri(uint256 tokenId) public view override returns (string memory) {
        if (!exists(tokenId)) revert InvalidTokenId();
        
        string memory tokenSpecificURI = _tokenURIs[tokenId];
        
        // If token has specific URI, return it, otherwise use base URI
        if (bytes(tokenSpecificURI).length > 0) {
            return tokenSpecificURI;
        }
                return string(abi.encodePacked(super.uri(tokenId), tokenId.toString()));
    }
    
    // ====================================================
    // 📊 Metadata & Query Functions
    // ====================================================
    
    /**
     * @notice Gets all tokens for a specific project category
     * @param category The project category to query
     * @return List of token IDs in the category
     */
    function getTokensByCategory(ProjectCategory category) external view returns (uint256[] memory) {
        return _categoryProjects[category];
    }
    
    /**
     * @notice Gets metadata for a token
     * @param tokenId The token ID to query
     * @return Metadata for the token
     */
    function getTokenMetadata(uint256 tokenId) external view returns (NFTMetadata memory) {
        if (!exists(tokenId)) revert InvalidTokenId();
        return tokenMetadata[tokenId];
    }
    
    /**
     * @notice Gets impact certificate details
     * @param tokenId The token ID to query
     * @return Certificate details
     */
    function getImpactCertificate(uint256 tokenId) external view returns (ImpactCertificate memory) {
        if (!exists(tokenId)) revert InvalidTokenId();
        if (tokenMetadata[tokenId].nftType != NFTType.IMPACT) revert NotImpactCertificate();
        return impactCertificates[tokenId];
    }
    
    /**
     * @notice Gets fractionalization info for a token
     * @param tokenId The token ID to query
     * @return Fractionalization info
     */
    function getFractionInfo(uint256 tokenId) external view returns (FractionInfo memory) {
        return fractionInfo[tokenId];
    }
    
    /**
     * @notice Gets all fraction tokens for an original token
     * @param originalTokenId The original token ID
     * @return List of fraction token IDs
     */
    function getFractionTokens(uint256 originalTokenId) external view returns (uint256[] memory) {
        return originalToFractions[originalTokenId];
    }
    
    /**
     * @notice Gets the original token ID for a fraction
     * @param fractionTokenId The fraction token ID
     * @return The original token ID
     */
    function getOriginalTokenId(uint256 fractionTokenId) external view returns (uint256) {
        return fractionToOriginal[fractionTokenId];
    }
    
    /**
     * @notice Check if token exists
     * @param tokenId The token ID to check
     * @return True if token exists
     */
    function exists(uint256 tokenId) public view returns (bool) {
        return totalSupply(tokenId) > 0;
    }
    
    // ====================================================
    // 💰 Fee Management
    // ====================================================
    
    /**
     * @notice Updates the fee distribution percentages
     * @param _burnPercent Percentage of fees to burn
     * @param _treasuryPercent Percentage of fees to send to treasury
     * @param _buybackPercent Percentage of fees to use for buybacks
     */
    function updateFeePercentages(
        uint8 _burnPercent,
        uint8 _treasuryPercent,
        uint8 _buybackPercent
    ) external onlyRole(GOVERNANCE_ROLE) {
        if (_burnPercent + _treasuryPercent + _buybackPercent != 100) revert InvalidPercentages();
        
        burnPercent = _burnPercent;
        treasuryPercent = _treasuryPercent;
        buybackPercent = _buybackPercent;
        
        emit FeePercentagesUpdated(_burnPercent, _treasuryPercent, _buybackPercent);
    }
    
    /**
     * @notice Updates the treasury wallet address
     * @param _treasuryWallet New treasury wallet address
     */
    function updateTreasuryWallet(address _treasuryWallet) external onlyRole(GOVERNANCE_ROLE) {
        if (_treasuryWallet == address(0)) revert InvalidAddress();
        
        treasuryWallet = _treasuryWallet;
        
        emit TreasuryWalletUpdated(_treasuryWallet);
    }
    
    /**
     * @notice Updates the fees
     * @param _mintFee New mint fee
     * @param _fractionalizationFee New fractionalization fee
     * @param _verificationFee New verification fee
     * @param _transferFee New transfer fee
     */
    function updateFees(
        uint256 _mintFee,
        uint256 _fractionalizationFee,
        uint256 _verificationFee,
        uint256 _transferFee
    ) external onlyRole(FEE_SETTER_ROLE) {
        mintFee = _mintFee;
        fractionalizationFee = _fractionalizationFee;
        verificationFee = _verificationFee;
        transferFee = _transferFee;
        
        emit FeeConfigured(_mintFee, _fractionalizationFee, _verificationFee, _transferFee);
    }
    
    /**
     * @notice Updates the dynamic fee parameters
     * @param _baseMintFee Base fee for minting
     * @param _baseFractionalizationFee Base fee for fractionalization
     * @param _feeMultiplier Initial fee multiplier (base 1000)
     * @param _feeAdjustmentInterval Interval for fee adjustments
     */
    function updateDynamicFeeParams(
        uint256 _baseMintFee,
        uint256 _baseFractionalizationFee,
        uint256 _feeMultiplier,
        uint256 _feeAdjustmentInterval
    ) external onlyRole(GOVERNANCE_ROLE) {
        baseMintFee = _baseMintFee;
        baseFractionalizationFee = _baseFractionalizationFee;
        feeMultiplier = _feeMultiplier;
        feeAdjustmentInterval = _feeAdjustmentInterval;
        
        emit DynamicFeeParamsUpdated(_baseMintFee, _baseFractionalizationFee, _feeMultiplier, _feeAdjustmentInterval);
    }
    
    /**
     * @notice Adjusts fees dynamically based on platform usage
     */
    function adjustFeesBasedOnUsage() external {
        if (block.timestamp < lastFeeAdjustment + feeAdjustmentInterval) revert TooEarly();
        
        // Calculate activity in the last period
        uint256 timeSinceLastAdjustment = block.timestamp - lastFeeAdjustment;
        uint256 periodMints = tokensMintedCounter - lastPeriodMintCount;
        uint256 periodFractionalizations = fractionalizationsCount - lastPeriodFractionalizationCount;
        
        // Simple algorithm to adjust fees based on activity
        // High activity → increase fees, low activity → decrease fees
        uint256 activityScore = (periodMints * 2) + periodFractionalizations;
        uint256 newMultiplier = feeMultiplier;
        
        if (activityScore > 100) {
            // High activity - increase fees (max 50%)
            newMultiplier = Math.min(feeMultiplier * 15 / 10, 1500);
        } else if (activityScore < 10) {
            // Low activity - decrease fees (min 50%)
            newMultiplier = Math.max(feeMultiplier * 85 / 100, 500);
        }
        
        // Update multiplier and recalculate fees
        if (newMultiplier != feeMultiplier) {
            feeMultiplier = newMultiplier;
            
            // Adjust fees based on new multiplier
            mintFee = baseMintFee * newMultiplier / 1000;
            fractionalizationFee = baseFractionalizationFee * newMultiplier / 1000;
            
            emit FeeMultiplierUpdated(newMultiplier);
            emit FeeConfigured(mintFee, fractionalizationFee, verificationFee, transferFee);
        }
        
        // Update tracking variables
        lastFeeAdjustment = block.timestamp;
        lastPeriodMintCount = tokensMintedCounter;
        lastPeriodFractionalizationCount = fractionalizationsCount;
    }
    
    /**
     * @notice Handles fee collection and distribution
     * @param from Address paying the fee
     * @param feeAmount Amount of the fee
     */
    function _collectFee(address from, uint256 feeAmount) internal {
        if (feeAmount == 0) return;
        
        // Get tokens from user
        bool success = IERC20(tstakeToken).transferFrom(from, address(this), feeAmount);
        if (!success) revert FeeTransferFailed();
        
        // Distribute fee
        uint256 burnAmount = feeAmount * burnPercent / 100;
        uint256 treasuryAmount = feeAmount * treasuryPercent / 100;
        uint256 buybackAmount = feeAmount * buybackPercent / 100;
        
        // Burn portion
        if (burnAmount > 0) {
            IERC20Burnable(tstakeToken).burn(burnAmount);
        }
        
        // Treasury portion
        if (treasuryAmount > 0) {
            success = IERC20(tstakeToken).transfer(treasuryWallet, treasuryAmount);
            if (!success) revert FeeTransferFailed();
        }
        
        // Buyback portion (remains in contract for later use)
        if (buybackAmount > 0) {
            buybackBalance += buybackAmount;
        }
        
        emit FeeCollected(from, feeAmount, burnAmount, treasuryAmount, buybackAmount);
    }
    
    // ====================================================
    // 🏆 Royalties Implementation
    // ====================================================
    
    /**
     * @notice Sets the default royalty information
     * @param receiver Royalty recipient address
     * @param feeNumerator Fee percentage in basis points (e.g., 250 = 2.5%)
     */
    function setDefaultRoyalty(address receiver, uint96 feeNumerator) 
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        if (receiver == address(0)) revert InvalidAddress();
        if (feeNumerator > 1000) revert ExcessiveRoyalty(); // Max 10%
        
        defaultRoyaltyReceiver = receiver;
        defaultRoyaltyPercentage = feeNumerator;
        
        emit DefaultRoyaltySet(receiver, feeNumerator);
    }
    
    /**
     * @notice Sets royalty information for a specific token
     * @param tokenId Token ID
     * @param receiver Royalty recipient address
     * @param feeNumerator Fee percentage in basis points
     */
    function setTokenRoyalty(
        uint256 tokenId,
        address receiver,
        uint96 feeNumerator
    ) external {
        if (!exists(tokenId)) revert InvalidTokenId();
        if (receiver == address(0)) revert InvalidAddress();
        if (feeNumerator > 1000) revert ExcessiveRoyalty(); // Max 10%
        
        // Only the token owner or governance can set royalties
        bool isOwner = balanceOf(msg.sender, tokenId) > 0;
        if (!isOwner && !hasRole(GOVERNANCE_ROLE, msg.sender)) {
            revert NotTokenOwner();
        }
        
        tokenRoyalties[tokenId] = RoyaltyInfo({
            receiver: receiver,
            royaltyFraction: feeNumerator
        });
        
        emit TokenRoyaltySet(tokenId, receiver, feeNumerator);
    }
    
    /**
     * @notice ERC2981 royalty info implementation
     * @param tokenId Token ID
     * @param salePrice Sale price
     * @return receiver Royalty recipient address
     * @return royaltyAmount Amount of royalty
     */
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount)
    {
        if (!exists(tokenId)) revert InvalidTokenId();
        
        // Check if token has specific royalty setting
        RoyaltyInfo memory info = tokenRoyalties[tokenId];
        
        if (info.receiver != address(0)) {
            // Use token-specific royalty
            receiver = info.receiver;
            royaltyAmount = (salePrice * info.royaltyFraction) / 10000;
        } else {
            // Use default royalty
            receiver = defaultRoyaltyReceiver;
            royaltyAmount = (salePrice * defaultRoyaltyPercentage) / 10000;
        }
        
        return (receiver, royaltyAmount);
    }
    
    // ====================================================
    // 🛠️ Utility Functions
    // ====================================================
    
    /**
     * @notice Generates a new unique token ID
     * @return A new token ID
     */
    function _generateTokenId() internal returns (uint256) {
        tokenCounter++;
        tokensMintedCounter++;
        return tokenCounter;
    }
    
    /**
     * @notice Use VRF to generate a random seed for token minting
     * @return requestId The VRF request ID
     */
    function requestRandomSeed() external onlyRole(MINTER_ROLE) returns (uint256 requestId) {
        requestId = COORDINATOR.requestRandomWords(
            keyHash,
            subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            numWords
        );
        
        vrfRequests[requestId] = true;
        emit RandomSeedRequested(requestId, msg.sender);
        
        return requestId;
    }
    
    /**
     * @notice Callback for VRF
     * @param requestId The request ID
     * @param randomWords The random values from VRF
     */
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        if (!vrfRequests[requestId]) revert InvalidRequest();
        
        uint256 randomValue = randomWords[0];
        randomSeeds[requestId] = randomValue;
        
        emit RandomSeedReceived(requestId, randomValue);
        
        vrfRequests[requestId] = false;
    }
    
    /**
     * @notice Get a random seed for a VRF request
     * @param requestId The VRF request ID
     * @return The random seed
     */
    function getRandomSeed(uint256 requestId) external view returns (uint256) {
        if (randomSeeds[requestId] == 0) revert NotFulfilled();
        return randomSeeds[requestId];
    }
    
    /**
     * @notice Emergency pause for critical situations
     */
    function emergencyPause() external onlyRole(EMERGENCY_ROLE) {
        emergencyMode = true;
        emit EmergencyModeActivated(msg.sender);
    }
    
    /**
     * @notice Resume after emergency
     */
    function emergencyResume() external onlyRole(GOVERNANCE_ROLE) {
        emergencyMode = false;
        emit EmergencyModeDeactivated(msg.sender);
    }
    
    /**
     * @notice Updates VRF configuration
     * @param _coordinator VRF coordinator address
     * @param _keyHash Key hash for VRF
     * @param _subscriptionId Subscription ID for VRF
     * @param _callbackGasLimit Gas limit for callback
     * @param _requestConfirmations Number of confirmations required
     */
    function updateVRFConfig(
        address _coordinator,
        bytes32 _keyHash,
        uint64 _subscriptionId,
        uint32 _callbackGasLimit,
        uint16 _requestConfirmations
    ) external onlyRole(GOVERNANCE_ROLE) {
        COORDINATOR = VRFCoordinatorV2Interface(_coordinator);
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;
        callbackGasLimit = _callbackGasLimit;
        requestConfirmations = _requestConfirmations;
        
        emit VRFConfigured(_coordinator, _keyHash, _subscriptionId, _callbackGasLimit, _requestConfirmations);
    }
    
    // ====================================================
    // ♻️ ERC1155 Overrides
    // ====================================================
    
    /**
     * @notice Override _beforeTokenTransfer to apply transfer fees
     */
    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal override(ERC1155Upgradeable) {
        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);
        
        // Don't apply fees to minting, burning, or exempt addresses
        if (from == address(0) || to == address(0) || hasRole(FEE_EXEMPTION_ROLE, from)) {
            return;
        }
        
        // Don't apply fees if the operator is the contract itself (internal transfers)
        if (operator == address(this)) {
            return;
        }
        
        // Apply transfer fee for non-exempt users on regular transfers
        _collectFee(from, transferFee);
    }
    
    /**
     * @notice Supports ERC-165 interface detection
     * @param interfaceId The interface identifier to check
     * @return True if the interface is supported
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return
            interfaceId == type(IERC2981Upgradeable).interfaceId ||
            interfaceId == type(ILockable).interfaceId ||
            super.supportsInterface(interfaceId);
    }
    
    // ====================================================
    // 🔒 Locking Mechanism Implementation (ILockable)
    // ====================================================
    
    /**
     * @notice Locks a token, preventing transfers
     * @param tokenId The token ID to lock
     * @param duration The lock duration in seconds (0 for permanent)
     */
    function lockToken(uint256 tokenId, uint256 duration) external {
        if (!exists(tokenId)) revert InvalidTokenId();
        
        // Only the token owner or governance can lock tokens
        bool isOwner = balanceOf(msg.sender, tokenId) > 0;
        if (!isOwner && !hasRole(GOVERNANCE_ROLE, msg.sender)) {
            revert NotTokenOwner();
        }
        
        uint256 unlockTime = duration == 0 ? type(uint256).max : block.timestamp + duration;
        
        tokenLocks[tokenId] = TokenLock({
            isLocked: true,
            lockedBy: msg.sender,
            lockTime: block.timestamp,
            unlockTime: unlockTime
        });
        
        emit TokenLocked(tokenId, msg.sender, unlockTime);
    }
    
    /**
     * @notice Unlocks a token if the lock period has expired
     * @param tokenId The token ID to unlock
     */
    function unlockToken(uint256 tokenId) external {
        if (!exists(tokenId)) revert InvalidTokenId();
        if (!tokenLocks[tokenId].isLocked) revert TokenNotLocked();
        
        TokenLock memory lock = tokenLocks[tokenId];
        
        // Check if permanent lock
        if (lock.unlockTime == type(uint256).max) {
            revert PermanentlyLocked();
        }
        
        // Check if unlock time has passed
        if (block.timestamp < lock.unlockTime) {
            revert LockNotExpired();
        }
        
        // Clear lock
        tokenLocks[tokenId].isLocked = false;
        
        emit TokenUnlocked(tokenId, msg.sender);
    }
    
    /**
     * @notice Checks if a token is locked
     * @param tokenId The token ID to check
     * @return True if the token is locked
     */
    function isLocked(uint256 tokenId) external view returns (bool) {
        if (!exists(tokenId)) revert InvalidTokenId();
        
        // Check if locked
        if (!tokenLocks[tokenId].isLocked) {
            return false;
        }
        
        // If has an unlock time and it's in the past, it's effectively unlocked
        if (
            tokenLocks[tokenId].unlockTime != type(uint256).max &&
            block.timestamp >= tokenLocks[tokenId].unlockTime
        ) {
            return false;
        }
        
        return true;
    }
    
    /**
     * @notice Gets lock information for a token
     * @param tokenId The token ID to check
     * @return Lock information
     */
    function getLockInfo(uint256 tokenId) external view returns (TokenLock memory) {
        if (!exists(tokenId)) revert InvalidTokenId();
        return tokenLocks[tokenId];
    }
    
    // ====================================================
    // 💵 Token Recovery
    // ====================================================
    
    /**
     * @notice Allows governance to recover any ERC20 tokens sent to the contract by mistake
     * @param tokenAddress Address of the token to recover
     * @param amount Amount to recover
     */
    function recoverERC20(address tokenAddress, uint256 amount) external onlyRole(GOVERNANCE_ROLE) {
        // Cannot withdraw TSTAKE tokens allocated for buybacks
        if (tokenAddress == tstakeToken) {
            uint256 contractBalance = IERC20(tstakeToken).balanceOf(address(this));
            require(contractBalance - buybackBalance >= amount, "Cannot withdraw buyback funds");
        }
        
        IERC20(tokenAddress).transfer(treasuryWallet, amount);
        
        emit TokensRecovered(tokenAddress, amount, treasuryWallet);
    }
    
    /**
     * @notice Execute a buyback from the allocated buyback funds
     * @param amount Amount of TSTAKE to use for buyback
     */
    function executeBuyback(uint256 amount) external onlyRole(GOVERNANCE_ROLE) {
        if (amount > buybackBalance) revert InsufficientFunds();
        
        buybackBalance -= amount;
        
        // Transfer to the buyback executor
        bool success = IERC20(tstakeToken).transfer(msg.sender, amount);
        if (!success) revert FeeTransferFailed();
        
        emit BuybackExecuted(amount, msg.sender);
    }
}
