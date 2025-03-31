// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

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
import "@api3/contracts/v0.8/interfaces/IProxy.sol";

interface ITerraStakeLiabilityManager {
    function getTWAP(address token, uint32 period) external view returns (uint256);
}

/// @dev Minimal interface extending IERC20 to include burning functionality.
interface IBurnableERC20 is IERC20 {
    function burn(uint256 amount) external;
}

/**
 * @title TerraStakeNFT
 * @notice Advanced environmental impact NFT system with fractionalization, verification, and impact tracking
 * @dev Implements ERC1155, ERC2981, API3 data feeds, and UUPS upgradeable patterns
 * @custom:security-contact security@terrastake.io
 */
contract TerraStakeNFT is
    Initializable,
    ERC1155SupplyUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    ERC2981Upgradeable
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
    bytes32 public constant LIABILITY_MANAGER_ROLE = keccak256("LIABILITY_MANAGER_ROLE");

    // ====================================================
    //  State Variables
    // ====================================================

    IBurnableERC20 public feeToken;
    address public treasuryWallet;
    address public impactFundWallet;
    address public api3FeeWallet;
    address public liabilityManagerAddress;

    // Fee distribution (in basis points, where BASIS_POINTS = 10000)
    uint16 public burnPercent = 100;       // 1%
    uint16 public treasuryPercent = 6300;  // 63%
    uint16 public impactFundPercent = 3100; // 31%
    uint16 public api3FeePercent = 500;    // 5%
    uint256 public constant BASIS_POINTS = 10000;

    // Fee amounts (assuming TSTAKE token has 18 decimals)
    uint256 public mintFee = 25e18;             // 25 TSTAKE
    uint256 public fractionalizationFee = 15e18; // 15 TSTAKE
    uint256 public verificationFee = 20e18;      // 20 TSTAKE
    uint256 public transferFee = 1e18;           // 1 TSTAKE
    uint256 public retirementFee = 5e18;         // 5 TSTAKE

    // Token and metadata storage
    mapping(uint256 => NFTMetadata) public tokenMetadata;
    mapping(uint256 => string) private _tokenURIs;
    mapping(uint256 => bool) public uriLocked;
    mapping(uint256 => ImpactCertificate) public impactCertificates;
    mapping(uint256 => FractionInfo) public fractionInfo;
    mapping(uint256 => address) public nftToLiabilityToken;

    // Project category mappings
    mapping(uint256 => ProjectCategory) public projectCategories;
    mapping(ProjectCategory => uint256[]) private _categoryProjects;

    // Verification registry
    mapping(uint256 => mapping(bytes32 => bool)) public verifiedReports;
    mapping(bytes32 => uint256) public reportToToken;

    // Fractionalization mappings
    mapping(uint256 => uint256[]) public originalToFractions;
    mapping(uint256 => uint256) public fractionToOriginal;

    // API3 Data Feed
    IAPI3DataFeed public carbonPriceFeed;
    IProxy public api3Proxy;

    // Token ID tracking
    uint256 private currentTokenId;

    // Marketplace integration
    address public marketplaceAddress;

    // Emergency Mode
    bool public emergencyMode = false;

    // Retirement tracking
    mapping(uint256 => bool) public isRetired;
    mapping(address => uint256[]) private _addressRetirements;
    mapping(uint256 => address) public retirementBeneficiary;
    mapping(uint256 => uint256) public retirementTimestamp;
    mapping(uint256 => string) public retirementReason;

    // Token ownership tracking
    mapping(uint256 => address) private _tokenOwners;

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
    event LiabilityCertificateCreated(
        uint256 indexed tokenId,
        uint256 indexed liabilityAmount,
        string liabilityType
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
    event MarketplaceSet(address marketplaceAddress);
    event ImpactVerified(
        uint256 indexed tokenId,
        bytes32 reportHash,
        address verifier
    );
    event LiabilityOffset(
        uint256 indexed tokenId,
        uint256 indexed offsetAmount,
        address indexed offsetBy
    );
    event CarbonPriceFeedSet(address priceFeed);
    event API3ProxySet(address proxyAddress);
    event TokenRetired(
        uint256 indexed tokenId,
        address indexed retiredBy,
        address indexed beneficiary,
        string retirementReason,
        uint256 timestamp
    );
    event EmergencyModeTriggered(address caller);
    event EmergencyModeDisabled(address caller);
    event LiabilityManagerSet(address liabilityManager);
    event LiabilityTokenSet(uint256 indexed tokenId, address liabilityToken);
    event TokenStateSync(uint256 indexed tokenId, bytes32 syncHash, uint256 timestamp);

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
    error TokenAlreadyRetired();
    error CannotRetireFraction();
    error InvalidLiabilityType();
    error CarbonPriceUnavailable();

    // ====================================================
    //  Modifiers
    // ====================================================

    modifier onlyTokenOwner(uint256 tokenId) {
        if (balanceOf(msg.sender, tokenId) == 0) revert NotTokenOwner();
        _;
    }

    modifier notEmergencyMode() {
        if (emergencyMode) revert EmergencyModeActive();
        _;
    }

    // ====================================================
    // Initialization
    // ====================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with required parameters
     * @param admin The admin address
     * @param _feeToken The fee token address
     * @param _treasuryWallet The treasury wallet address
     * @param _impactFundWallet The impact fund wallet address
     * @param _api3FeeWallet The API3 fee wallet address
     * @param _api3Proxy API3 proxy address
     * @param _uri Base URI for token metadata
     */
    function initialize(
        address admin,
        address _feeToken,
        address _treasuryWallet,
        address _impactFundWallet,
        address _api3FeeWallet,
        address _api3Proxy,
        string memory _uri
    ) external initializer {
        if (
            admin == address(0) ||
            _feeToken == address(0) ||
            _treasuryWallet == address(0) ||
            _impactFundWallet == address(0) ||
            _api3FeeWallet == address(0)
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
        _grantRole(LIABILITY_MANAGER_ROLE, admin);

        feeToken = IBurnableERC20(_feeToken);
        treasuryWallet = _treasuryWallet;
        impactFundWallet = _impactFundWallet;
        api3FeeWallet = _api3FeeWallet;

        if (_api3Proxy != address(0)) {
            api3Proxy = IProxy(_api3Proxy);
            emit API3ProxySet(_api3Proxy);
        }

        emit FeesUpdated(mintFee, fractionalizationFee, verificationFee, transferFee, retirementFee);
        emit FeeDistributionUpdated(burnPercent, treasuryPercent, impactFundPercent, api3FeePercent);
        emit TreasuryWalletUpdated(_treasuryWallet);
        emit ImpactFundWalletUpdated(_impactFundWallet);
        emit API3FeeWalletUpdated(_api3FeeWallet);
    }

    // ====================================================
    //  Upgradeability
    // ====================================================

    /**
     * @dev Function that should revert when msg.sender is not authorized to upgrade the contract.
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}

    // ====================================================
    //  Token Minting Functions
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
            description: "TerraStake Standard Environmental NFT",
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
        if (!hasRole(MINTER_ROLE, msg.sender) && !hasRole(VALIDATOR_ROLE, msg.sender)) {
            revert Unauthorized();
        }

        if (to == address(0)) revert InvalidAddress();
        if (reportToToken[reportHash] != 0) revert AlreadyVerified();

        // Generate new token ID
        uint256 tokenId = _generateTokenId();

        // Determine project category
        ProjectCategory category = ProjectCategory.CarbonCredit;
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
            category: category,
            isLiability: false
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
     * @notice Mints a liability NFT (e.g., carbon, pollution, etc.)
     * @param to The recipient address
     * @param liabilityAmount The amount/quantity of the liability
     * @param liabilityType The type of liability (e.g., "carbon", "waste")
     * @param location Geographic location of the liability
     * @param _uri The token URI
     * @return tokenId The newly minted token ID
     */
    function mintLiabilityNFT(
        address to,
        uint256 liabilityAmount,
        string calldata liabilityType,
        string calldata location,
        string calldata _uri
    ) external nonReentrant onlyRole(LIABILITY_MANAGER_ROLE) returns (uint256) {
        if (to == address(0)) revert InvalidAddress();
        if (liabilityAmount == 0) revert ZeroAmount();

        // Generate new token ID
        uint256 tokenId = _generateTokenId();

        // Determine NFT type and category based on liability type
        (NFTType nftType, ProjectCategory category) = _getLiabilityTypeAndCategory(liabilityType);

        // Mint token
        _mint(to, tokenId, 1, "");

        // Store metadata
        tokenMetadata[tokenId] = NFTMetadata({
            name: string(
                abi.encodePacked("TerraStake ", liabilityType, " Liability #", tokenId.toString())
            ),
            description: string(abi.encodePacked("TerraStake ", liabilityType, " Liability Certificate")),
            creationTime: block.timestamp,
            uriIsFrozen: false,
            nftType: nftType,
            category: category
        });

        // Create liability certificate
        bytes32 reportHash = keccak256(abi.encodePacked(liabilityType, liabilityAmount, block.timestamp));
        impactCertificates[tokenId] = ImpactCertificate({
            projectId: 0,
            reportHash: reportHash,
            impactValue: liabilityAmount,
            impactType: liabilityType,
            verificationDate: block.timestamp,
            location: location,
            verifier: msg.sender,
            isVerified: true,
            category: category,
            isLiability: true
        });

        _tokenURIs[tokenId] = _uri;
        projectCategories[tokenId] = category;
        _categoryProjects[category].push(tokenId);
        reportToToken[reportHash] = tokenId;

        emit TokenMinted(tokenId, to, nftType, category);
        emit LiabilityCertificateCreated(tokenId, liabilityAmount, liabilityType);

        return tokenId;
    }

    // ====================================================
    //  Impact Verification
    // ====================================================

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
    //  Liability Management Functions
    // ====================================================

    /**
     * @notice Offsets a carbon liability by burning the NFT and creating an offset certificate
     * @param tokenId The carbon liability token ID to offset
     * @param retirementReason Reason for the offset/retirement
     */
    function offsetCarbonLiability(
        uint256 tokenId,
        string calldata retirementReason
    ) external nonReentrant onlyTokenOwner(tokenId) notEmergencyMode {
        if (!exists(tokenId)) revert InvalidTokenId();
        if (tokenMetadata[tokenId].nftType != NFTType.CARBON_LIABILITY) {
            revert InvalidLiabilityType();
        }

        // Handle retirement fee
        if (!hasRole(FEE_EXEMPTION_ROLE, msg.sender)) {
            _collectFee(msg.sender, retirementFee);
        }

        // Get carbon price from API3
        uint256 carbonPricePerTon = getCarbonPrice();
        if (carbonPricePerTon == 0) revert CarbonPriceUnavailable();

        // Calculate total cost based on liability amount
        uint256 liabilityAmount = impactCertificates[tokenId].impactValue;
        uint256 totalCost = liabilityAmount * carbonPricePerTon;

        // Transfer funds from user (using feeToken as the payment token)
        feeToken.safeTransferFrom(msg.sender, address(this), totalCost);

        // Distribute the payment
        uint256 burnAmount = (totalCost * burnPercent) / BASIS_POINTS;
        uint256 treasuryAmount = (totalCost * treasuryPercent) / BASIS_POINTS;
        uint256 impactFundAmount = (totalCost * impactFundPercent) / BASIS_POINTS;
        uint256 api3FeeAmount = totalCost - burnAmount - treasuryAmount - impactFundAmount;

        if (burnAmount > 0) {
            feeToken.burn(burnAmount);
        }
        if (treasuryAmount > 0) {
            feeToken.safeTransfer(treasuryWallet, treasuryAmount);
        }
        if (impactFundAmount > 0) {
            feeToken.safeTransfer(impactFundWallet, impactFundAmount);
        }
        if (api3FeeAmount > 0) {
            feeToken.safeTransfer(api3FeeWallet, api3FeeAmount);
        }

        // Mark token as retired
        isRetired[tokenId] = true;
        retirementBeneficiary[tokenId] = msg.sender;
        retirementTimestamp[tokenId] = block.timestamp;
        retirementReason[tokenId] = retirementReason;
        _addressRetirements[msg.sender].push(tokenId);

        // Burn the liability token
        _burn(msg.sender, tokenId, 1);

        // Mint an offset certificate
        uint256 newNFTId = _generateTokenId();
        _mint(msg.sender, newNFTId, 1, "");

        tokenMetadata[newNFTId] = NFTMetadata({
            name: string(abi.encodePacked("Carbon Offset Certificate #", newNFTId.toString())),
            description: "TerraStake Carbon Offset Certificate",
            creationTime: block.timestamp,
            uriIsFrozen: true,
            nftType: NFTType.IMPACT,
            category: ProjectCategory.CarbonCredit
        });

        impactCertificates[newNFTId] = ImpactCertificate({
            projectId: 0,
            reportHash: keccak256(abi.encodePacked(tokenId, block.timestamp)),
            impactValue: liabilityAmount,
            impactType: "Carbon Offset",
            verificationDate: block.timestamp,
            location: impactCertificates[tokenId].location,
            verifier: msg.sender,
            isVerified: true,
            category: ProjectCategory.CarbonCredit,
            isLiability: false
        });

        emit LiabilityOffset(tokenId, liabilityAmount, msg.sender);
        emit TokenRetired(
            tokenId,
            msg.sender,
            msg.sender,
            retirementReason,
            block.timestamp
        );
        emit TokenMinted(newNFTId, msg.sender, NFTType.IMPACT, ProjectCategory.CarbonCredit);
    }

    // ====================================================
    //  Retirement Functions
    // ====================================================

    /**
     * @notice Retires a token, permanently removing it from circulation
     * @param tokenId The token ID to retire
     * @param beneficiary Address on whose behalf the retirement is made
     * @param retirementReason Reason for the retirement
     */
    function retireToken(
        uint256 tokenId,
        address beneficiary,
        string calldata retirementReason
    ) external nonReentrant onlyTokenOwner(tokenId) notEmergencyMode {
        if (!exists(tokenId)) revert InvalidTokenId();
        if (isRetired[tokenId]) revert TokenAlreadyRetired();
        if (fractionToOriginal[tokenId] != 0) revert CannotRetireFraction();
        
        // Handle retirement fee for non-liability tokens
        if (!impactCertificates[tokenId].isLiability && !hasRole(FEE_EXEMPTION_ROLE, msg.sender)) {
            _collectFee(msg.sender, retirementFee);
        }

        // Mark token as retired
        isRetired[tokenId] = true;
        retirementBeneficiary[tokenId] = beneficiary == address(0) ? msg.sender : beneficiary;
        retirementTimestamp[tokenId] = block.timestamp;
        retirementReason[tokenId] = retirementReason;
        
        // Add to user's retirement list
        _addressRetirements[msg.sender].push(tokenId);
        
        // Emit retirement event
        emit TokenRetired(
            tokenId,
            msg.sender,
            retirementBeneficiary[tokenId],
            retirementReason,
            block.timestamp
        );

        // For non-liability tokens, burn them upon retirement
        if (!impactCertificates[tokenId].isLiability) {
            _burn(msg.sender, tokenId, 1);
        }
    }

    /**
     * @notice Retires multiple tokens in a single transaction
     * @param tokenIds Array of token IDs to retire
     * @param beneficiary Address on whose behalf the retirement is made
     * @param retirementReason Reason for the retirement
     */
    function batchRetireTokens(
        uint256[] calldata tokenIds,
        address beneficiary,
        string calldata retirementReason
    ) external nonReentrant notEmergencyMode {
        address finalBeneficiary = beneficiary == address(0) ? msg.sender : beneficiary;
        bool hasExemption = hasRole(FEE_EXEMPTION_ROLE, msg.sender);
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            
            // Verify owner and validity
            if (balanceOf(msg.sender, tokenId) == 0) revert NotTokenOwner();
            if (!exists(tokenId)) revert InvalidTokenId();
            if (isRetired[tokenId]) revert TokenAlreadyRetired();
            if (fractionToOriginal[tokenId] != 0) revert CannotRetireFraction();
            
            // Handle retirement fee for non-liability tokens
            if (!impactCertificates[tokenId].isLiability && !hasExemption) {
                _collectFee(msg.sender, retirementFee);
            }

            // Mark token as retired
            isRetired[tokenId] = true;
            retirementBeneficiary[tokenId] = finalBeneficiary;
            retirementTimestamp[tokenId] = block.timestamp;
            retirementReason[tokenId] = retirementReason;
            
            // Add to user's retirement list
            _addressRetirements[msg.sender].push(tokenId);
            
            // Emit retirement event
            emit TokenRetired(
                tokenId,
                msg.sender,
                finalBeneficiary,
                retirementReason,
                block.timestamp
            );

            // For non-liability tokens, burn them upon retirement
            if (!impactCertificates[tokenId].isLiability) {
                _burn(msg.sender, tokenId, 1);
            }
        }
    }

    // ====================================================
    //  Fractionalization Functions
    // ====================================================

    /**
     * @notice Fractionalizes an NFT into smaller tokens
     * @param originalTokenId The token ID to fractionalize
     * @param fractionCount The number of fractions to create
     * @return fractionIds Array of created fraction token IDs
     */
    function fractionalize(uint256 originalTokenId, uint256 fractionCount) 
        external 
        nonReentrant 
        onlyRole(FRACTIONALIZER_ROLE) 
        returns (uint256[] memory fractionIds) 
    {
        if (!exists(originalTokenId)) revert InvalidTokenId();
        if (fractionInfo[originalTokenId].isActive) revert TokenAlreadyFractionalized();
        if (balanceOf(msg.sender, originalTokenId) == 0) revert NotTokenOwner();
        if (fractionCount == 0) revert ZeroAmount();
        
        // Handle fractionalization fee unless exempt
        if (!hasRole(FEE_EXEMPTION_ROLE, msg.sender)) {
            _collectFee(msg.sender, fractionalizationFee);
        }

        // Create fraction IDs
        fractionIds = new uint256[](fractionCount);
        for (uint256 i = 0; i < fractionCount; i++) {
            uint256 fractionId = _generateTokenId();
            fractionIds[i] = fractionId;
            
            // Mint fraction tokens to this contract
            _mint(msg.sender, fractionId, 1, "");
            
            // Record fraction relationship
            fractionToOriginal[fractionId] = originalTokenId;
            originalToFractions[originalTokenId].push(fractionId);
            
            // Copy metadata with fraction designation
            NFTMetadata memory metadata = tokenMetadata[originalTokenId];
            tokenMetadata[fractionId] = metadata;
            
            // Set fraction URI based on original
            _tokenURIs[fractionId] = string(abi.encodePacked(_tokenURIs[originalTokenId], "/fraction/", i.toString()));
        }
        
        // Record fractionalization info
        fractionInfo[originalTokenId] = FractionInfo({
            originalTokenId: originalTokenId,
            fractionCount: fractionCount,
            fractionalizer: msg.sender,
            isActive: true,
            nftType: tokenMetadata[originalTokenId].nftType,
            projectId: impactCertificates[originalTokenId].projectId,
            reportHash: impactCertificates[originalTokenId].reportHash,
            category: tokenMetadata[originalTokenId].category
        });
        
        // Burn or lock original token
        _burn(msg.sender, originalTokenId, 1);
        
        emit TokenFractionalized(originalTokenId, fractionIds, fractionCount);
        
        return fractionIds;
    }

    /**
     * @notice Reassembles fractionalized tokens back into the original NFT
     * @param originalTokenId The original token ID
     */
    function reassemble(uint256 originalTokenId) 
        external 
        nonReentrant 
        notEmergencyMode
    {
        if (!fractionInfo[originalTokenId].isActive) revert TokenNotFractionalized();
        
        FractionInfo storage info = fractionInfo[originalTokenId];
        uint256[] storage fractions = originalToFractions[originalTokenId];
        
        // Verify sender owns all fractions
        for (uint256 i = 0; i < fractions.length; i++) {
            if (balanceOf(msg.sender, fractions[i]) == 0) revert IncompleteCollection();
        }
        
        // Burn all fractions
        for (uint256 i = 0; i < fractions.length; i++) {
            _burn(msg.sender, fractions[i], 1);
        }
        
        // Recreate original token
        _mint(msg.sender, originalTokenId, 1, "");
        
        // Deactivate fractionalization
        fractionInfo[originalTokenId].isActive = false;
        
        emit TokensReassembled(originalTokenId, msg.sender);
    }

    // ====================================================
    //  Liability Manager Integration
    // ====================================================

    /**
     * @notice Gets NFT data needed by the liability manager
     * @param tokenId The token ID to query
     * @return NFT data structure
     */
    function getNFTData(uint256 tokenId) external view returns (NFTData memory) {
        if (!exists(tokenId)) revert InvalidTokenId();
        
        NFTData memory data;
        data.owner = ownerOf(tokenId);
        data.verified = impactCertificates[tokenId].isVerified;
        data.eLiability = impactCertificates[tokenId].impactValue;
        data.category = tokenMetadata[tokenId].category;
        data.auditDataHash = impactCertificates[tokenId].reportHash;
        
        return data;
    }

    /**
     * @notice Creates a new impact NFT (used by liability manager)
     * @param to Recipient address
     * @param impactValue Amount of impact/liability
     * @param category The project category
     * @param auditDataHash Hash of the audit data
     * @return tokenId The newly minted token ID
     */
    function mintImpact(
        address to,
        uint256 impactValue,
        ProjectCategory category,
        bytes32 auditDataHash
    ) external onlyRole(LIABILITY_MANAGER_ROLE) returns (uint256 tokenId) {
        if (to == address(0)) revert InvalidAddress();
        
        // Generate new token ID
        tokenId = _generateTokenId();
        
        // Mint token
        _mint(to, tokenId, 1, "");
        
        // Create metadata
        tokenMetadata[tokenId] = NFTMetadata({
            name: string(abi.encodePacked("TerraStake Impact #", tokenId.toString())),
            description: "TerraStake Environmental Impact Certificate",
            creationTime: block.timestamp,
            uriIsFrozen: false,
            nftType: NFTType.IMPACT,
            category: category
        });
        
        // Create impact certificate
        impactCertificates[tokenId] = ImpactCertificate({
            projectId: 0,
            reportHash: auditDataHash,
            impactValue: impactValue,
            impactType: "Environmental Impact",
            verificationDate: block.timestamp,
            location: "",
            verifier: msg.sender,
            isVerified: true,
            category: category,
            isLiability: false
        });
        
        _tokenURIs[tokenId] = "";
        projectCategories[tokenId] = category;
        _categoryProjects[category].push(tokenId);
        
        emit TokenMinted(tokenId, to, NFTType.IMPACT, category);
        
        return tokenId;
    }

    /**
     * @notice Sets the liability manager contract address
     * @param _liabilityManagerAddress The new liability manager address
     */
    function setLiabilityManager(address _liabilityManagerAddress) external onlyRole(GOVERNANCE_ROLE) {
        if (_liabilityManagerAddress == address(0)) revert InvalidAddress();
        liabilityManagerAddress = _liabilityManagerAddress;
        emit LiabilityManagerSet(_liabilityManagerAddress);
    }

    /**
     * @notice Links a liability token to a fractionalized NFT
     * @param originalTokenId The original token ID
     * @param liabilityToken The liability token address
     */
    function setLiabilityToken(uint256 originalTokenId, address liabilityToken) 
        external 
        onlyRole(LIABILITY_MANAGER_ROLE) 
    {
        if (!fractionInfo[originalTokenId].isActive) revert TokenNotFractionalized();
        if (liabilityToken == address(0)) revert InvalidAddress();
        
        nftToLiabilityToken[originalTokenId] = liabilityToken;
        emit LiabilityTokenSet(originalTokenId, liabilityToken);
    }

    /**
     * @notice Gets the TWAP price for a fraction token
     * @param originalTokenId The original token ID
     * @return The TWAP price of the fraction
     */
    function getFractionTWAPPrice(uint256 originalTokenId) external view returns (uint256) {
        address liabilityToken = nftToLiabilityToken[originalTokenId];
        if (liabilityToken == address(0)) revert TokenNotFractionalized();
        if (liabilityManagerAddress == address(0)) revert InvalidAddress();
        
        return ITerraStakeLiabilityManager(liabilityManagerAddress).getTWAP(liabilityToken, 1 hours);
    }

    // ====================================================
    //  Event Syncing
    // ====================================================

    /**
     * @notice Emits a sync event for off-chain tracking
     * @param tokenId The token ID being synced
     * @param syncHash Hash of the sync data
     */
    function emitSyncEvent(uint256 tokenId, bytes32 syncHash) external onlyRole(LIABILITY_MANAGER_ROLE) {
        if (!exists(tokenId)) revert InvalidTokenId();
        emit TokenStateSync(tokenId, syncHash, block.timestamp);
    }

    // ====================================================
    //  API3 Integration
    // ====================================================

    /**
     * @notice Sets the API3 carbon price feed address
     * @param _carbonPriceFeed The new API3 data feed address
     */
    function setCarbonPriceFeed(address _carbonPriceFeed) external onlyRole(GOVERNANCE_ROLE) {
        carbonPriceFeed = IAPI3DataFeed(_carbonPriceFeed);
        emit CarbonPriceFeedSet(_carbonPriceFeed);
    }

    /**
     * @notice Sets the API3 proxy address
     * @param _api3Proxy The new API3 proxy address
     */
    function setAPI3Proxy(address _api3Proxy) external onlyRole(GOVERNANCE_ROLE) {
        api3Proxy = IProxy(_api3Proxy);
        emit API3ProxySet(_api3Proxy);
    }

    /**
     * @notice Gets the current carbon price from API3
     * @return The current carbon price in USD per metric ton
     */
    function getCarbonPrice() public view returns (uint256) {
        if (address(carbonPriceFeed) == address(0)) return 0;
        
        // Try to read from the API3 data feed first
        try carbonPriceFeed.read() returns (uint256 value, uint256 timestamp) {
            return value;
        } catch {
            // Fallback to proxy if available
            if (address(api3Proxy) != address(0)) {
                try api3Proxy.read() returns (int224 value, uint32 timestamp) {
                    return uint256(int256(value));
                } catch {
                    return 0;
                }
            }
            return 0;
        }
    }

    // ====================================================
    //  Utility Functions
    // ====================================================

    /**
     * @dev Maps liability types to NFT types and project categories
     */
    function _getLiabilityTypeAndCategory(string memory liabilityType) 
        internal 
        pure 
        returns (NFTType nftType, ProjectCategory category) 
    {
        // Compute the hash only once for efficiency
        bytes32 typeHash = keccak256(bytes(liabilityType));
        
        if (typeHash == keccak256(bytes("carbon"))) {
            return (NFTType.CARBON_LIABILITY, ProjectCategory.CarbonCredit);
        } else if (typeHash == keccak256(bytes("pollution"))) {
            return (NFTType.POLLUTION_LIABILITY, ProjectCategory.PollutionControl);
        } else if (typeHash == keccak256(bytes("waste"))) {
            return (NFTType.WASTE_LIABILITY, ProjectCategory.WasteManagement);
        } else if (typeHash == keccak256(bytes("water"))) {
            return (NFTType.WATER_LIABILITY, ProjectCategory.WaterConservation);
        } else if (typeHash == keccak256(bytes("habitat"))) {
            return (NFTType.HABITAT_LIABILITY, ProjectCategory.HabitatRestoration);
        } else if (typeHash == keccak256(bytes("energy"))) {
            return (NFTType.ENERGY_LIABILITY, ProjectCategory.RenewableEnergy);
        } else if (typeHash == keccak256(bytes("circularity"))) {
            return (NFTType.CIRCULARITY_LIABILITY, ProjectCategory.CircularEconomy);
        } else if (typeHash == keccak256(bytes("community"))) {
            return (NFTType.COMMUNITY_LIABILITY, ProjectCategory.CommunityDevelopment);
        } else {
            revert InvalidLiabilityType();
        }
    }

    /**
     * @dev Generates a unique token ID
     */
    function _generateTokenId() internal returns (uint256) {
        return ++currentTokenId;
    }

    /**
     * @dev Handles fee collection and distribution
     */
    function _collectFee(address from, uint256 feeAmount) internal {
        if (feeAmount == 0 || hasRole(FEE_EXEMPTION_ROLE, from)) return;
        
        // Get tokens from user
        feeToken.safeTransferFrom(from, address(this), feeAmount);
        
        // Distribute fee
        uint256 burnAmount = (feeAmount * burnPercent) / BASIS_POINTS;
        uint256 treasuryAmount = (feeAmount * treasuryPercent) / BASIS_POINTS;
        uint256 impactFundAmount = (feeAmount * impactFundPercent) / BASIS_POINTS;
        // Use remainder for API3 fee to avoid rounding issues
        uint256 api3FeeAmount = feeAmount - burnAmount - treasuryAmount - impactFundAmount;
        
        if (burnAmount > 0) {
            feeToken.burn(burnAmount);
        }
        if (treasuryAmount > 0) {
            feeToken.safeTransfer(treasuryWallet, treasuryAmount);
        }
        if (impactFundAmount > 0) {
            feeToken.safeTransfer(impactFundWallet, impactFundAmount);
        }
        if (api3FeeAmount > 0) {
            feeToken.safeTransfer(api3FeeWallet, api3FeeAmount);
        }
        
        emit FeesCollected(from, feeAmount, burnAmount, treasuryAmount, impactFundAmount, api3FeeAmount);
    }

    // ====================================================
    //  Token Transfer and Ownership Tracking
    // ====================================================

    /**
     * @dev Overrides the _update hook to handle fees, fractionalization, and retirement checks
     */
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override whenNotPaused {
        // Check if any token is retired
        for (uint256 i = 0; i < ids.length; i++) {
            if (isRetired[ids[i]]) {
                revert("Cannot transfer retired token");
            }
            
            // Ownership update logic:
            if (from == address(0)) {
                // Minting: assign new owner
                _tokenOwners[ids[i]] = to;
            } else if (to == address(0)) {
                // Burning: remove owner record
                delete _tokenOwners[ids[i]];
            } else if (values[i] == 1 || balanceOf(from, ids[i]) == values[i]) {
                // Full transfer (or single token transfer)
                _tokenOwners[ids[i]] = to;
            }
        }
        
        // Collect transfer fee for non-fraction tokens
        if (from != address(0) && to != address(0)) {
            for (uint256 i = 0; i < ids.length; i++) {
                if (fractionToOriginal[ids[i]] == 0) {
                    _collectFee(from, transferFee);
                }
            }
        }
        
        super._update(from, to, ids, values);
    }

    /**
     * @notice Gets the owner of a token (for tokens that are non-fungible)
     * @param tokenId The token ID to query
     * @return The owner address
     */
    function ownerOf(uint256 tokenId) public view returns (address) {
        require(exists(tokenId), "Token does not exist");
        return _tokenOwners[tokenId];
    }

    // ====================================================
    //  View Functions
    // ====================================================

    /**
     * @notice Gets all retired tokens for an address
     * @param owner The address to query
     * @return List of retired token IDs
     */
    function getRetiredTokensByAddress(address owner) 
        external 
        view 
        returns (uint256[] memory) 
    {
        return _addressRetirements[owner];
    }

    /**
     * @notice Gets retirement details for a token
     * @param tokenId The token ID to query
     * @return isTokenRetired Whether the token is retired
     * @return beneficiary Address that benefited from the retirement
     * @return retirementDate When the token was retired
     * @return reason The retirement reason
     */
    function getRetirementDetails(uint256 tokenId)
        external
        view
        returns (
            bool isTokenRetired,
            address beneficiary,
            uint256 retirementDate,
            string memory reason
        )
    {
        return (
            isRetired[tokenId],
            retirementBeneficiary[tokenId],
            retirementTimestamp[tokenId],
            retirementReason[tokenId]
        );
    }

    /**
     * @notice Gets comprehensive data for a token including impact and verification details
     * @param tokenId The token ID to query
     * @return impactValue The quantified impact value of the token
     * @return category The project category of the token
     * @return verificationHash The hash of the verification report
     * @return isLiability Whether the token represents a liability
     */
    function getTokenData(uint256 tokenId) 
        external 
        view 
        returns (
            uint256 impactValue,
            ProjectCategory category,
            bytes32 verificationHash,
            bool isLiability
        ) 
    {
        if (!exists(tokenId)) revert InvalidTokenId();
        
        category = tokenMetadata[tokenId].category;
        
        ImpactCertificate memory certificate = impactCertificates[tokenId];
        impactValue = certificate.impactValue;
        verificationHash = certificate.reportHash;
        isLiability = certificate.isLiability;
        
        return (impactValue, category, verificationHash, isLiability);
    }

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
    //  Royalty Management
    // ====================================================

    /**
     * @notice Sets the royalty information for a specific token id
     * @param tokenId The token ID to set royalty for
     * @param receiver Address of who should receive royalties
     * @param feeNumerator The royalty fee numerator (basis points)
     */
    function setTokenRoyalty(
        uint256 tokenId,
        address receiver,
        uint96 feeNumerator
    ) external onlyRole(ROYALTY_ROLE) {
        if (feeNumerator > 1000) revert InvalidRoyaltyPercentage(); // Max 10%
        _setTokenRoyalty(tokenId, receiver, feeNumerator);
        emit RoyaltySet(tokenId, receiver, feeNumerator);
    }

    /**
     * @notice Sets the default royalty information
     * @param receiver Address of who should receive royalties
     * @param feeNumerator The royalty fee numerator (basis points)
     */
    function setDefaultRoyalty(
        address receiver,
        uint96 feeNumerator
    ) external onlyRole(ROYALTY_ROLE) {
        if (feeNumerator > 1000) revert InvalidRoyaltyPercentage(); // Max 10%
        _setDefaultRoyalty(receiver, feeNumerator);
        emit DefaultRoyaltySet(receiver, feeNumerator);
    }

    // ====================================================
    //  Emergency Functions
    // ====================================================

    /**
     * @notice Triggers emergency mode which pauses most functions
     */
    function triggerEmergencyMode() external onlyRole(EMERGENCY_ROLE) {
        emergencyMode = true;
        _pause();
        emit EmergencyModeTriggered(msg.sender);
    }

    /**
     * @notice Disables emergency mode
     */
    function disableEmergencyMode() external onlyRole(EMERGENCY_ROLE) {
        emergencyMode = false;
        _unpause();
        emit EmergencyModeDisabled(msg.sender);
    }

    // ====================================================
    //  Pausable Overrides
    // ====================================================

    /**
     * @dev Pauses all token transfers
     */
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /**
     * @dev Unpauses all token transfers
     */
    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    // ====================================================
    //  Interface Support
    // ====================================================

    /**
     * @dev Checks interface support
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