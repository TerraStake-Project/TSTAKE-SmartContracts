// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155SupplyUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@chainlink/contracts/src/v0.8/vrf/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import "../interfaces/IChainlinkDataFeeder.sol";
import "../interfaces/IFractionToken.sol";
import "../interfaces/ITerraStakeMarketplace.sol";
import "../interfaces/ITerraStakeNFT.sol";
import "../interfaces/ITerraStakeProjects.sol";
import "../interfaces/ITerraStakeMetadataRenderer.sol";
import "../interfaces/ITerraStakeToken.sol";

/// @dev Minimal interface extending IERC20 to include burning functionality.
interface IBurnableERC20 is IERC20 {
    function burn(uint256 amount) external;
}

/**
 * @title TerraStakeNFT
 * @notice Advanced environmental impact NFT system with fractionalization, verification, and impact tracking
 * @dev Implements ERC1155, ERC2981, VRF, and UUPS upgradeable patterns
 * @custom:security-contact security@terrastake.io
 */
contract TerraStakeNFT is
    Initializable,
    ERC1155SupplyUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    ERC2981Upgradeable,
    VRFConsumerBaseV2
{
    using SafeERC20 for IBurnableERC20;
    using Strings for uint256;

    // ====================================================
    //  Type Definitions
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

    // ====================================================
    // Access Control Roles
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
    bytes32 public constant ROYALTY_ROLE = keccak256("ROYALTY_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant VRF_REQUESTER_ROLE = keccak256("VRF_REQUESTER_ROLE");

    // ====================================================
    //  Fee Management
    // ====================================================

    IBurnableERC20 public feeToken; // Use a generic fee token

    address public treasuryWallet;
    address public buybackAndBurnWallet; // Dedicated wallet for buyback and burn
    uint256 public mintFee;
    uint256 public fractionalizationFee;
    uint256 public verificationFee;
    uint256 public transferFee; // Consider removing or making very small

    // Fee distribution percentages (base 100)
    uint8 public burnPercent = 50; // 50%
    uint8 public treasuryPercent = 45; // 45%
    uint8 public buybackPercent = 5; // 5%

    // Token and metadata storage
    mapping(uint256 => NFTMetadata) public tokenMetadata;
    mapping(uint256 => string) private _tokenURIs;
    mapping(uint256 => bool) public uriLocked;
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

    // VRF related variables
    address public vrfCoordinator;
    VRFCoordinatorV2Interface public COORDINATOR;
    bytes32 public keyHash;
    uint64 public subscriptionId;
    uint32 public callbackGasLimit;
    uint16 public requestConfirmations;
    uint32 public numWords = 1;
    mapping(uint256 => bool) public pendingRequests;

    // Token ID tracking
    uint256 private currentTokenId;

    // Marketplace integration
    address public marketplaceAddress;

    // Emergency Mode
    bool public emergencyMode = false;

    // ====================================================
    //  Events
    // ====================================================

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
    event TokenFractionalized(
        uint256 indexed originalTokenId,
        uint256[] fractionIds,
        uint256 fractionCount
    );
    event TokensReassembled(uint256 indexed originalTokenId, address indexed owner);
    event TokenURIUpdated(uint256 indexed tokenId, string newUri);
    event TokenURILocked(uint256 indexed tokenId);
    event RoyaltySet(
        uint256 indexed tokenId,
        address receiver,
        uint96 royaltyFraction
    );
    event DefaultRoyaltySet(address receiver, uint96 royaltyFraction);
    event FeeConfigured(
        uint256 mintFee,
        uint256 fractionalizationFee,
        uint256 verificationFee,
        uint256 transferFee
    );
    event FeePercentagesUpdated(
        uint8 burnPercent,
        uint8 treasuryPercent,
        uint8 buybackPercent
    );
    event TreasuryWalletUpdated(address newTreasuryWallet);
    event BuybackAndBurnWalletUpdated(address newBuybackAndBurnWallet);
    event FeesCollected(
        address from,
        uint256 amount,
        uint256 burnAmount,
        uint256 treasuryAmount,
        uint256 buybackAmount
    );
    event MarketplaceSet(address marketplaceAddress);
    event ImpactVerified(
        uint256 indexed tokenId,
        bytes32 reportHash,
        address verifier
    );
    event VRFConfigured(
        address coordinator,
        bytes32 keyHash,
        uint64 subId,
        uint32 callbackGasLimit,
        uint16 requestConfirmations
    );
    event RandomnessRequested(uint256 requestId, address requester);
    event RandomnessReceived(uint256 requestId, uint256[] randomWords);
    event EmergencyModeTriggered(address caller);
    event EmergencyModeDisabled(address caller);
    event LINKWithdrawn(address to, uint256 amount);

    // ====================================================
    //  Errors
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
    error InsufficientLINK();
    error InsufficientLINKBalance();

    // ====================================================
    //  Modifiers
    // ====================================================

    modifier onlyTokenOwner(uint256 tokenId) {
        if (balanceOf(msg.sender, tokenId) == 0) revert NotTokenOwner();
        _;
    }

    modifier notEmergencyMode() {
        require(!emergencyMode, "Emergency mode is active");
        _;
    }

    // ====================================================
    // Initialization
    // ====================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _vrfCoordinator) VRFConsumerBaseV2(_vrfCoordinator) {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with required parameters
     * @param admin The admin address
     * @param _feeToken The  fee token address
     * @param _treasuryWallet The treasury wallet address
     * @param _buybackAndBurnWallet The buyback and burn wallet address
     * @param _uri Base URI for token metadata
     * @param _vrfCoordinator VRF coordinator address
     * @param _keyHash VRF key hash
     * @param _subscriptionId Chainlink VRF subscription ID
     */
    function initialize(
        address admin,
        address _feeToken,
        address _treasuryWallet,
        address _buybackAndBurnWallet,
        string memory _uri,
        address _vrfCoordinator,
        bytes32 _keyHash,
        uint64 _subscriptionId
    ) external initializer {
        if (
            admin == address(0) ||
            _feeToken == address(0) ||
            _treasuryWallet == address(0) ||
            _buybackAndBurnWallet == address(0) ||
            _vrfCoordinator == address(0)
        ) revert InvalidAddress();

        __ERC1155_init(_uri);
        __ERC1155Supply_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __ERC2981_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(FRACTIONALIZER_ROLE, admin);
        _grantRole(VERIFIER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(FEE_MANAGER_ROLE, admin);
        _grantRole(URI_SETTER_ROLE, admin);
        _grantRole(VALIDATOR_ROLE, admin);
        _grantRole(ROYALTY_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, admin);
        _grantRole(VRF_REQUESTER_ROLE, admin);

        feeToken = IBurnableERC20(_feeToken);
        treasuryWallet = _treasuryWallet;
        buybackAndBurnWallet = _buybackAndBurnWallet;

        // Set initial fees (example values, adjust as needed)
        mintFee = 1 * 10**18; // 1 token
        fractionalizationFee = 0.5 * 10**18; // 0.5 token
        verificationFee = 0.75 * 10**18; // 0.75 token
        transferFee = 0.01 * 10**18;

        // Configure VRF
        vrfCoordinator = _vrfCoordinator;
        COORDINATOR = VRFCoordinatorV2Interface(_vrfCoordinator);
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;
        callbackGasLimit = 2500000;
        requestConfirmations = 3;

        emit FeeConfigured(
            mintFee,
            fractionalizationFee,
            verificationFee,
            transferFee
        );
        emit FeePercentagesUpdated(burnPercent, treasuryPercent, buybackPercent);
        emit TreasuryWalletUpdated(_treasuryWallet);
        emit BuybackAndBurnWalletUpdated(_buybackAndBurnWallet);
        emit VRFConfigured(
            _vrfCoordinator,
            _keyHash,
            _subscriptionId,
            callbackGasLimit,
            requestConfirmations
        );
    }

    /**
     * @dev Function that should revert when msg.sender is not authorized to upgrade the contract.
     * Called by {upgradeTo} and {upgradeToAndCall}.
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}

    // ====================================================
    // Token Minting Functions
    // ====================================================

    /**
     * @notice Mints a standard NFT
     * @param to The recipient address
     * @param amount The amount to mint
     * @param category The project category
     * @param _uri The token URI
     * @return tokenId The newly minted token ID
     */
    function mintStandardNFT(
        address to,
        uint256 amount,
        ProjectCategory category,
        string calldata _uri
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
            description: "TerraStakeStandard Environmental NFT",
            creationTime: block.timestamp,
            uriIsFrozen: false,
            nftType: NFTType.STANDARD,
            category: category
        });

        _tokenURIs[tokenId] = _uri;
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
     * @param _uri The token URI
     * @return tokenId The newly minted token ID
     */
    function mintImpactNFT(
        address to,
        uint256 projectId,
        string calldata _uri,
        bytes32 reportHash
    ) external nonReentrant whenNotPaused returns (uint256) {
        // Verify caller has MINTER_ROLE or VALIDATOR_ROLE
        if (
            !hasRole(MINTER_ROLE, msg.sender) && !hasRole(VALIDATOR_ROLE, msg.sender)
        ) {
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
            name: string(
                abi.encodePacked("TerraStake Impact Certificate #", tokenId.toString())
            ),
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

        _tokenURIs[tokenId] = _uri;
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
    //  Fractionalization Functions
    // ====================================================

    /**
     * @notice Fractionalizes an existing NFT into multiple shares
     * @param tokenId The token ID to fractionalize
     * @param fractionCount The number of fractions to create
     * @return fractionIds Array of new fraction token IDs
     */
    function fractionalizeToken(
        uint256 tokenId,
        uint256 fractionCount
    )
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
                name: string(
                    abi.encodePacked(
                        "Fraction #",
                        i.toString(),
                        " of TerraStake NFT #",
                        tokenId.toString()
                    )
                ),
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
            projectId: tokenMetadata[tokenId].nftType == NFTType.IMPACT
                ? impactCertificates[tokenId].projectId
                : 0,
            reportHash: tokenMetadata[tokenId].nftType == NFTType.IMPACT
                ? impactCertificates[tokenId].reportHash
                : bytes32(0),
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
    function reassembleToken(uint256 originalTokenId)
        external
        nonReentrant
        notEmergencyMode
    {
        if (!fractionInfo[originalTokenId].isActive)
            revert TokenNotFractionalized();

        FractionInfo storage info = fractionInfo[originalTokenId];
        uint256[] memory fractions = originalToFractions[originalTokenId];

        // Check that sender owns all fractions
        for (uint256 i = 0; i < fractions.length; i++) {
            if (balanceOf(msg.sender, fractions[i]) == 0)
                revert IncompleteCollection();
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
        delete originalToFractions[originalTokenId];

        emit TokensReassembled(originalTokenId, msg.sender);
    }

    // ====================================================
    // URI Management
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
        if (
            !isOwner &&
            !hasRole(URI_SETTER_ROLE, msg.sender) &&
            !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)
        ) {
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
    //  Metadata & Query Functions
    // ====================================================

    /**
     * @notice Gets all tokens for a specific project category
     * @param category The project category to query
     * @return List of token IDs in the category
     */
    function getTokensByCategory(ProjectCategory category)
        external
        view
        returns (uint256[] memory)
    {
        return _categoryProjects[category];
    }

    /**
     * @notice Gets metadata for a token
     * @param tokenId The token ID to query
     * @return Metadata for the token
     */
    function getTokenMetadata(uint256 tokenId)
        external
        view
        returns (NFTMetadata memory)
    {
        if (!exists(tokenId)) revert InvalidTokenId();
        return tokenMetadata[tokenId];
    }

    /**
     * @notice Gets impact certificate details
     * @param tokenId The token ID to query
     * @return Certificate details
     */
    function getImpactCertificate(uint256 tokenId)
        external
        view
        returns (ImpactCertificate memory)
    {
        if (!exists(tokenId)) revert InvalidTokenId();
        if (tokenMetadata[tokenId].nftType != NFTType.IMPACT)
            revert("Not an Impact Certificate"); //Added specific error
        return impactCertificates[tokenId];
    }

    /**
     * @notice Gets fractionalization info for a token
     * @param tokenId The token ID to query
     * @return Fractionalization info
     */
    function getFractionInfo(uint256 tokenId)
        external
        view
        returns (FractionInfo memory)
    {
        return fractionInfo[tokenId];
    }

    /**
     * @notice Gets all fraction tokens for an original token
     * @param originalTokenId The original token ID
     * @return List of fraction token IDs
     */
    function getFractionTokens(uint256 originalTokenId)
        external
        view
        returns (uint256[] memory)
    {
        return originalToFractions[originalTokenId];
    }

    /**
     * @notice Gets the original token ID for a fraction
     * @param fractionTokenId The fraction token ID
     * @return The original token ID
     */
    function getOriginalTokenId(uint256 fractionTokenId)
        external
        view
        returns (uint256)
    {
        return fractionToOriginal[fractionTokenId];
    }

    /**
     * @notice Check if token exists
     * @param tokenId The token ID to check
     * @return True if token exists
     */
    function exists(uint256 tokenId) public view override returns (bool) {
        return totalSupply(tokenId) > 0;
    }

    // ====================================================
    //  Fee Management
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
        if (_burnPercent + _treasuryPercent + _buybackPercent != 100)
            revert InvalidPercentages();

        burnPercent = _burnPercent;
        treasuryPercent = _treasuryPercent;
        buybackPercent = _buybackPercent;

        emit FeePercentagesUpdated(
            _burnPercent,
            _treasuryPercent,
            _buybackPercent
        );
    }

    /**
     * @notice Updates the treasury wallet address
     * @param _treasuryWallet New treasury wallet address
     */
    function updateTreasuryWallet(address _treasuryWallet)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        if (_treasuryWallet == address(0)) revert InvalidAddress();

        treasuryWallet = _treasuryWallet;

        emit TreasuryWalletUpdated(_treasuryWallet);
    }

    /**
     * @notice Updates the buyback and burn wallet
     * @param _buybackAndBurnWallet The new buyback and burn wallet address
     */
    function updateBuybackAndBurnWallet(address _buybackAndBurnWallet)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        if (_buybackAndBurnWallet == address(0)) revert InvalidAddress();
        buybackAndBurnWallet = _buybackAndBurnWallet;
        emit BuybackAndBurnWalletUpdated(buybackAndBurnWallet);
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
    ) external onlyRole(FEE_MANAGER_ROLE) {
        mintFee = _mintFee;
        fractionalizationFee = _fractionalizationFee;
        verificationFee = _verificationFee;
        transferFee = _transferFee;

        emit FeeConfigured(
            _mintFee,
            _fractionalizationFee,
            _verificationFee,
            _transferFee
        );
    }

    /**
     * @notice Handles fee collection and distribution
     * @param from Address paying the fee
     * @param feeAmount Amount of the fee
     */
    function _collectFee(address from, uint256 feeAmount) internal {
        if (feeAmount == 0) return;

        // Get tokens from user
        feeToken.safeTransferFrom(from, address(this), feeAmount);

        // Distribute fee
        uint256 burnAmount = (feeAmount * burnPercent) / 100;

        uint256 treasuryAmount = (feeAmount * treasuryPercent) / 100;
        uint256 buybackAmount = (feeAmount * buybackPercent) / 100;

        if (burnAmount > 0) {
            feeToken.burn(burnAmount);
        }

        if (treasuryAmount > 0) {
            feeToken.safeTransfer(treasuryWallet, treasuryAmount);
        }

        if (buybackAmount > 0) {
            feeToken.safeTransfer(buybackAndBurnWallet, buybackAmount);
        }

        emit FeesCollected(from, feeAmount, burnAmount, treasuryAmount, buybackAmount);
    }

    /**
     * @notice Sets the admin role for a given role
     * @param role The role to set the admin for
     * @param adminRole The new admin role
     */
    function setRoleAdmin(bytes32 role, bytes32 adminRole) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRoleAdmin(role, adminRole);
    }

    // ====================================================
    //  Emergency & Pausable
    // ====================================================

    /**
     * @notice Pauses the contract
     */
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the contract
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Triggers emergency mode, disabling certain functions
     */
    function triggerEmergencyMode() external onlyRole(EMERGENCY_ROLE) {
        emergencyMode = true;
        emit EmergencyModeTriggered(msg.sender);
    }

    /**
     * @notice Disables emergency mode
     */
    function disableEmergencyMode() external onlyRole(EMERGENCY_ROLE) {
        emergencyMode = false;
        emit EmergencyModeDisabled(msg.sender);
    }

    // ====================================================
    //  Internal Utility Functions
    // ====================================================

    /**
     * @notice Generates a unique token ID
     * @return The new token ID
     */
    function _generateTokenId() internal returns (uint256) {
        return ++currentTokenId;
    }

    /**
     * @notice Overrides the _update hook to handle fees and fractionalization logic
     */
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override whenNotPaused {
        // Skip fee logic for minting and burning
        if (from == address(0) || to == address(0)) {
            return;
        }

        // Handle transfer fee
        if (!hasRole(FEE_EXEMPTION_ROLE, from) && !hasRole(FEE_EXEMPTION_ROLE, to)) {
            for (uint256 i = 0; i < ids.length; i++) {
                // Only charge fee on original tokens, not fractions
                if (fractionToOriginal[ids[i]] == 0) {
                    _collectFee(from, transferFee);
                }
            }
        }
    }

    /**
     * @notice Checks if a given address supports a specific interface
     * @param interfaceId The interface ID to check
     * @return True if the interface is supported
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlUpgradeable, ERC1155Upgradeable, ERC2981Upgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
