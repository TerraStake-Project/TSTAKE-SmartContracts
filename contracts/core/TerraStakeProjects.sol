// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {ITerraStakeProjects} from "../interfaces/ITerraStakeProjects.sol";
import {ITerraStakeNFT} from "../interfaces/ITerraStakeNFT.sol";
import {ITerraStakeMarketPlace} from "../interfaces/ITerraStakeMarketPlace.sol";

/**
 * @title TerraStakeProjects 
 * @notice Manages projects, staking, impact tracking, governance-driven fees, and NFT integration.
 * @dev Implements UUPS upgradeable pattern and comprehensive role-based access control
 */
contract TerraStakeProjects is 
    Initializable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable, 
    PausableUpgradeable,
    UUPSUpgradeable,
    ITerraStakeProjects 
{
    using SafeERC20 for IERC20;
    
    // ====================================================
    // 🔑 Roles
    // ====================================================
    bytes32 public constant PROJECT_MANAGER_ROLE = keccak256("PROJECT_MANAGER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant STAKER_ROLE = keccak256("STAKER_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    // ====================================================
    // 📌 State Variables
    // ====================================================
    IERC20 public tStakeToken;
    uint256 public projectCount;
    
    // Added from context (wasn't in original but referenced)
    address public terraTokenAddress;
    address public treasuryAddress;
    uint256 public accumulatedBuybackFunds;
    uint256 public constant MIN_CLAIM_PERIOD = 1 days;
    uint256 public constant TIME_REWARD_RATE = 1; // 0.01% per day
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    
    FeeStructure public fees;
    address public treasury;
    address public liquidityPool;
    address public stakingContract;
    address public rewardsContract;
    
    // NFT Integration
    address public nftContract;
    mapping(ProjectCategory => string) private categoryImageURI;
    
    // Category metadata with real-world requirements
    mapping(ProjectCategory => CategoryInfo) public categoryInfo;
    
    // Project data storage
    mapping(uint256 => ProjectData) public projectMetadata;
    mapping(uint256 => ProjectStateData) public projectStateData;
    mapping(uint256 => ValidationData) public projectValidations;
    mapping(uint256 => VerificationData) public projectVerifications;
    mapping(uint256 => GeneralMetadata) public projectMetadataDetails;
    
    // Enhanced storage pattern for comments with pagination
    mapping(uint256 => mapping(uint256 => Comment[])) public projectCommentsPages;
    mapping(uint256 => uint256) public projectCommentsPageCount;
    uint256 public constant COMMENTS_PER_PAGE = 100;
    
    // Enhanced storage pattern for documents with pagination
    mapping(uint256 => mapping(uint256 => string[])) public projectDocumentPages;
    mapping(uint256 => uint256) public projectDocumentPageCount;
    uint256 public constant DOCUMENTS_PER_PAGE = 20;
    
    mapping(uint256 => ProjectAnalytics) public projectAnalytics;
    mapping(uint256 => ImpactReport[]) public projectImpactReports;
    mapping(uint256 => ImpactRequirement) public projectImpactRequirements;
    mapping(uint256 => RECData[]) public projectRECs;
    
    // Category requirements tracking
    mapping(ProjectCategory => ImpactRequirement) public categoryRequirements;
    
    // Granular permission system for project owners and collaborators
    mapping(uint256 => mapping(address => mapping(bytes32 => bool))) public projectPermissions;
    bytes32 public constant EDIT_METADATA_PERMISSION = keccak256("EDIT_METADATA");
    bytes32 public constant UPLOAD_DOCS_PERMISSION = keccak256("UPLOAD_DOCS");
    bytes32 public constant SUBMIT_REPORTS_PERMISSION = keccak256("SUBMIT_REPORTS");
    bytes32 public constant MANAGE_COLLABORATORS_PERMISSION = keccak256("MANAGE_COLLABORATORS");
    
    // Efficient project tracking by owner & category
    mapping(address => uint256[]) private _projectsByOwner;
    mapping(ProjectCategory => uint256[]) private _projectsByCategory;
    uint256[] private _activeProjects;
    
    // Circuit breaker security
    bool public emergencyMode;
    
    // Staking tracking
    mapping(uint256 => mapping(address => uint256)) public projectStakes;
    mapping(uint256 => address[]) public projectStakers;
    mapping(address => uint256[]) public userStakedProjects;
    mapping(uint256 => mapping(address => uint256)) public lastRewardClaim;
    
    // Verification comments
    mapping(uint256 => mapping(uint256 => string)) public projectVerificationComments;

    // Custom data structure to store real-world category information
    struct CategoryInfo {
        string name;
        string description;
        string[] standardBodies;
        string[] metricUnits;
        string verificationStandard;
        uint256 impactWeight;
    }

    // Verification struct 
    struct ProjectVerification {
        address verifier;
        uint256 verificationDate;
        string verificationStandard;
        bytes32 verificationDocumentHash;
    }

    // ====================================================
    // 📣 Enhanced Events
    // ====================================================
    // NFT related events
    event ImpactNFTMinted(uint256 indexed projectId, bytes32 indexed reportHash, address recipient);
    event NFTContractSet(address indexed nftContract);
    
    // Additional events for REC management
    event RECVerified(uint256 indexed projectId, bytes32 indexed recId, address verifier);
    event RECRetired(uint256 indexed projectId, bytes32 indexed recId, address retirer, string purpose);
    event RECTransferred(uint256 indexed projectId, bytes32 indexed recId, address from, address to);
    event RECRegistrySync(uint256 indexed projectId, bytes32 indexed recId, string externalRegistryId);
    
    // Project permission events
    event ProjectPermissionUpdated(
        uint256 indexed projectId, 
        address indexed user, 
        bytes32 permission, 
        bool granted
    );
    
    // Project metadata update event
    event ProjectMetadataUpdated(uint256 indexed projectId, string name);
    
    // Fee management events
    event TokensBurned(uint256 amount);
    
    // Emergency events
    event EmergencyModeActivated(address operator);
    event EmergencyModeDeactivated(address operator);
    
    // Initialization event
    event Initialized(address admin, address tstakeToken);
    
    // Fee updates
    event FeeStructureUpdated(uint256 projectFee, uint256 reportingFee, uint256 verificationFee, uint256 categoryChangeFee);
    event FeeCollected(address payer, uint256 amount, uint256 burnAmount, uint256 treasuryAmount, uint256 buybackAmount);
    event BuybackExecuted(uint256 amount);
    
    // Project events
    event ProjectAdded(uint256 indexed projectId, string name, ProjectCategory category);
    event ProjectStateChanged(uint256 indexed projectId, ProjectState oldState, ProjectState newState);
    event DocumentationUpdated(uint256 indexed projectId, string[] ipfsHashes);
    event ImpactReported(uint256 indexed projectId, uint256 reportIndex, bytes32 reportHash, address reporter);
    event RewardsAccumulated(uint256 indexed projectId, uint256 amount);
    event ImpactVerified(uint256 indexed projectId, uint256 reportIndex, address verifier, bool approved);
    event PermissionUpdated(uint256 indexed projectId, address indexed user, uint8 permission, bool value);
    event OwnershipTransferred(uint256 indexed projectId, address indexed oldOwner, address indexed newOwner);
    event Staked(uint256 indexed projectId, address indexed staker, uint256 amount);
    event Unstaked(uint256 indexed projectId, address indexed staker, uint256 amount);
    event RewardsClaimed(uint256 indexed projectId, address indexed staker, uint256 amount);
    event FeesUpdated(uint256 projectFee, uint256 reportingFee, uint256 updateFee);
    event EmergencyModeToggled(bool active);
    event TokensRecovered(address token, address recipient, uint256 amount);
    event TerraTokenSet(address tokenAddress);
    event TreasuryAddressSet(address treasuryAddress);
    event ProjectVerified(uint256 indexed projectId, address verifier, string standard, bytes32 documentHash);

    // ====================================================
    // 🚨 Errors
    // ====================================================
    error InvalidAddress();
    error NameRequired();
    error InvalidProjectId();
    error StateUnchanged();
    error NotAuthorized();
    error FeeTransferFailed();
    error PageDoesNotExist();
    error InvalidCategory();
    error ProjectNotActive();
    error ProjectNotVerified();
    error RECNotFound();
    error RECNotActive();
    error NotRECOwner();
    error CannotRevokeOwnerPermissions();
    error EmergencyModeActive();
    error CallerNotStakingContract();
    error InvalidReportIndex();
    error ReportAlreadyVerified();
    error ZeroAmount();
    error TokenNotConfigured();
    error TokenTransferFailed();
    error InsufficientStake();
    error NoRewardsAvailable();
    error NoBuybackFunds();
    error ExceedsRecoverableAmount();
    error InvalidPermission();

    // ====================================================
    // 🚀 Initialization & Upgrades
    // ====================================================
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin, 
        address _tstakeToken
    ) external override initializer {
        if (admin == address(0) || _tstakeToken == address(0)) revert InvalidAddress();
        
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PROJECT_MANAGER_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(STAKER_ROLE, admin);
        _grantRole(VALIDATOR_ROLE, admin);
        _grantRole(VERIFIER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(TREASURY_ROLE, admin);
        
        tStakeToken = IERC20(_tstakeToken);
        terraTokenAddress = _tstakeToken;
        
        // Initial fee structure
        fees = FeeStructure({
            projectSubmissionFee: 6100 * 10**18, // $6,100 in TSTAKE
            impactReportingFee: 2200 * 10**18,   // $2,200 in TSTAKE
            categoryChangeFee: 1500 * 10**18,    // $1,500 in TSTAKE
            verificationFee: 3000 * 10**18       // $3,000 in TSTAKE
        });
        
        // Initialize category information with real-world data
        _initializeCategoryData();
        
        emit Initialized(admin, _tstakeToken);
        emit FeeStructureUpdated(
            fees.projectSubmissionFee, 
            fees.impactReportingFee, 
            fees.verificationFee, 
            fees.categoryChangeFee
        );
    }
    
    /**
     * @dev Function that should revert when msg.sender is not authorized to upgrade the contract.
     * Called by {upgradeTo} and {upgradeToAndCall}.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
    // Initialize category data with real-world standards and requirements
    function _initializeCategoryData() internal {
        // Carbon Credit projects
        categoryInfo[ProjectCategory.CarbonCredit] = CategoryInfo({
            name: "Carbon Credit",
            description: "Projects that reduce or remove greenhouse gas emissions",
            standardBodies: ["Verra", "Gold Standard", "American Carbon Registry", "Climate Action Reserve"],
            metricUnits: ["tCO2e", "Carbon Offset Tons", "Carbon Removal Tons"],
            verificationStandard: "ISO 14064-3",
            impactWeight: 100
        });
        
        // Renewable Energy projects
        categoryInfo[ProjectCategory.RenewableEnergy] = CategoryInfo({
            name: "Renewable Energy",
            description: "Solar, wind, hydro, and other renewable energy generation projects",
            standardBodies: ["I-REC Standard", "Green-e Energy", "EKOenergy"],
            metricUnits: ["MWh", "kWh", "Installed Capacity (MW)"],
            verificationStandard: "ISO 50001",
            impactWeight: 90
        });
        
        // Ocean Cleanup projects
        categoryInfo[ProjectCategory.OceanCleanup] = CategoryInfo({
            name: "Ocean Cleanup",
            description: "Marine conservation and plastic removal initiatives",
            standardBodies: ["Ocean Cleanup Foundation", "Plastic Bank", "Ocean Conservancy"],
            metricUnits: ["Tons of Plastic Removed", "Area Protected (km²)", "Marine Species Protected"],
            verificationStandard: "UNEP Clean Seas Protocol",
            impactWeight: 85
        });
        
        // Reforestation projects
        categoryInfo[ProjectCategory.Reforestation] = CategoryInfo({
            name: "Reforestation",
            description: "Tree planting and forest protection initiatives",
            standardBodies: ["Forest Stewardship Council", "Rainforest Alliance", "One Tree Planted"],
            metricUnits: ["Trees Planted", "Area Reforested (ha)", "Biomass Added (tons)"],
            verificationStandard: "ISO 14001",
            impactWeight: 95
        });
        
        // Biodiversity projects
        categoryInfo[ProjectCategory.Biodiversity] = CategoryInfo({
            name: "Biodiversity",
            description: "Species and ecosystem protection initiatives",
            standardBodies: ["IUCN", "WWF", "The Nature Conservancy"],
            metricUnits: ["Species Protected", "Habitat Area (ha)", "Biodiversity Index"],
            verificationStandard: "Convention on Biological Diversity",
            impactWeight: 85
        });
        
        // Initialize remaining categories
        _initializeRemainingCategories();
    }
    
    function _initializeRemainingCategories() internal {
        // Sustainable Agriculture projects
        categoryInfo[ProjectCategory.SustainableAg] = CategoryInfo({
            name: "Sustainable Agriculture",
            description: "Regenerative farming and sustainable agricultural practices",
            standardBodies: ["Regenerative Organic Certified", "USDA Organic", "Rainforest Alliance"],
            metricUnits: ["Organic Produce (tons)", "Soil Carbon Added (tons)", "Water Saved (m³)"],
            verificationStandard: "Global G.A.P.",
            impactWeight: 80
        });
        
        // Waste Management projects
        categoryInfo[ProjectCategory.WasteManagement] = CategoryInfo({
            name: "Waste Management",
            description: "Recycling and waste reduction initiatives",
            standardBodies: ["Zero Waste International Alliance", "ISO 14001", "Cradle to Cradle"],
            metricUnits: ["Waste Diverted (tons)", "Recycling Rate (%)", "Landfill Reduction (m³)"],
            verificationStandard: "ISO 14001",
            impactWeight: 75
        });
        
        // Water Conservation projects
        categoryInfo[ProjectCategory.WaterConservation] = CategoryInfo({
            name: "Water Conservation",
            description: "Water efficiency and protection initiatives",
            standardBodies: ["Alliance for Water Stewardship", "Water Footprint Network", "LEED"],
            metricUnits: ["Water Saved (m³)", "Area Protected (ha)", "People Served"],
            verificationStandard: "ISO 14046",
            impactWeight: 85
        });
        
        // Pollution Control projects
        categoryInfo[ProjectCategory.PollutionControl] = CategoryInfo({
            name: "Pollution Control",
            description: "Air and environmental quality improvement initiatives",
            standardBodies: ["ISO 14001", "Clean Air Act", "EPA Standards"],
            metricUnits: ["Emissions Reduced (tons)", "AQI Improvement", "Area Remediated (ha)"],
            verificationStandard: "ISO 14001",
            impactWeight: 80
        });
        
        // Habitat Restoration projects
        categoryInfo[ProjectCategory.HabitatRestoration] = CategoryInfo({
            name: "Habitat Restoration",
            description: "Ecosystem recovery projects",
            standardBodies: ["Society for Ecological Restoration", "IUCN", "Land Life Company"],
            metricUnits: ["Area Restored (ha)", "Species Reintroduced", "Ecological Health Index"],
            verificationStandard: "SER International Standards",
            impactWeight: 90
        });
        
        // Green Building projects
        categoryInfo[ProjectCategory.GreenBuilding] = CategoryInfo({
            name: "Green Building",
            description: "Energy-efficient infrastructure & sustainable construction",
            standardBodies: ["LEED", "BREEAM", "Passive House", "Living Building Challenge"],
            metricUnits: ["Energy Saved (kWh)", "CO2 Reduced (tons)", "Water Saved (m³)"],
            verificationStandard: "LEED Certification",
            impactWeight: 70
        });
        
        // Circular Economy projects
        categoryInfo[ProjectCategory.CircularEconomy] = CategoryInfo({
            name: "Circular Economy",
            description: "Waste-to-energy, recycling loops, regenerative economy",
            standardBodies: ["Ellen MacArthur Foundation", "Cradle to Cradle", "Circle Economy"],
            metricUnits: ["Material Reused (tons)", "Product Lifecycle Extension", "Virgin Material Avoided (tons)"],
            verificationStandard: "BS 8001:2017",
            impactWeight: 85
        });
        
        // Community Development projects
        categoryInfo[ProjectCategory.CommunityDevelopment] = CategoryInfo({
            name: "Community Development",
            description: "Local sustainability initiatives and social impact projects",
            standardBodies: ["B Corp", "Social Value International", "Community Development Financial Institutions"],
            metricUnits: ["People Impacted", "Jobs Created", "Community Resources Generated"],
            verificationStandard: "Social Return on Investment Framework",
            impactWeight: 75
        });
    }

    // ====================================================
    // 🔹 NFT Integration Functions
    // ====================================================
    
    function setNFTContract(address _nftContract) external onlyRole(GOVERNANCE_ROLE) {
        if (_nftContract == address(0)) revert InvalidAddress();
        nftContract = _nftContract;
        emit NFTContractSet(_nftContract);
        
        // Initialize default category images
        _initializeCategoryImages();
    }
    
    function _initializeCategoryImages() internal {
        categoryImageURI[ProjectCategory.CarbonCredit] = "ipfs://QmXyZ1234567890carbon/";
        categoryImageURI[ProjectCategory.RenewableEnergy] = "ipfs://QmXyZ1234567890renewable/";
        categoryImageURI[ProjectCategory.OceanCleanup] = "ipfs://QmXyZ1234567890ocean/";
        categoryImageURI[ProjectCategory.Reforestation] = "ipfs://QmXyZ1234567890forest/";
        categoryImageURI[ProjectCategory.Biodiversity] = "ipfs://QmXyZ1234567890biodiversity/";
        categoryImageURI[ProjectCategory.SustainableAg] = "ipfs://QmXyZ1234567890agriculture/";
        categoryImageURI[ProjectCategory.WasteManagement] = "ipfs://QmXyZ1234567890waste/";
        categoryImageURI[ProjectCategory.WaterConservation] = "ipfs://QmXyZ1234567890water/";
        categoryImageURI[ProjectCategory.PollutionControl] = "ipfs://QmXyZ1234567890pollution/";
        categoryImageURI[ProjectCategory.HabitatRestoration] = "ipfs://QmXyZ1234567890habitat/";
        categoryImageURI[ProjectCategory.GreenBuilding] = "ipfs://QmXyZ1234567890building/";
        categoryImageURI[ProjectCategory.CircularEconomy] = "ipfs://QmXyZ1234567890circular/";
        categoryImageURI[ProjectCategory.CommunityDevelopment] = "ipfs://QmXyZ1234567890community/";
    }
    
    function setCategoryImageURI(ProjectCategory category, string calldata uri) external onlyRole(GOVERNANCE_ROLE) {
        categoryImageURI[category] = uri;
    }
    
    function getCategoryImageURI(ProjectCategory category) external view returns (string memory) {
        return categoryImageURI[category];
    }
    
    function mintImpactNFT(uint256 projectId, bytes32 reportHash, address recipient) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        // Only validators, verifiers, or governance can mint NFTs
        if (!hasRole(VALIDATOR_ROLE, msg.sender) && 
            !hasRole(VERIFIER_ROLE, msg.sender) && 
            !hasRole(GOVERNANCE_ROLE, msg.sender)) {
            revert NotAuthorized();
        }
        
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        if (nftContract == address(0)) revert InvalidAddress();
        
        // Ensure project is active and verified
        if (projectStateData[projectId].state != ProjectState.Active) revert ProjectNotActive();
        if (projectVerifications[projectId].verificationDate == 0) revert ProjectNotVerified();
        
        // Get project category and metadata for the NFT
        ProjectCategory category = projectStateData[projectId].category;
        string memory projectName = projectMetadata[projectId].name;
        
        // Create NFT metadata
        string memory tokenURI = _generateTokenURI(projectId, category, projectName, reportHash);
        
        // Call the NFT contract to mint the token
        ITerraStakeNFT nftContractInstance = ITerraStakeNFT(nftContract);
        nftContractInstance.mintImpactNFT(recipient, projectId, tokenURI, reportHash);
        
        emit ImpactNFTMinted(projectId, reportHash, recipient);
    }
    
    function _generateTokenURI(
        uint256 projectId, 
        ProjectCategory category, 
        string memory projectName, 
        bytes32 reportHash
    ) internal view returns (string memory) {
        // Simplified JSON generation for demonstration
        // In production, this would construct complete metadata JSON
        string memory baseURI = categoryImageURI[category];
        string memory tokenId = Strings.toString(projectId);
        
        return string(abi.encodePacked(
            baseURI,
            tokenId,
            "?name=", projectName,
            "&category=", Strings.toString(uint256(category)),
            "&reportHash=", _bytes32ToString(reportHash)
        ));
    }
    
    function _bytes32ToString(bytes32 _bytes) internal pure returns (string memory) {
        bytes memory bytesArray = new bytes(64);
        for (uint256 i = 0; i < 32; i++) {
            bytesArray[i*2] = _byteToChar(_bytes[i] >> 4);
            bytesArray[i*2+1] = _byteToChar(_bytes[i] & 0x0f);
        }
        return string(bytesArray);
    }
    
    function _byteToChar(bytes1 b) internal pure returns (bytes1) {
        if (b < bytes1(uint8(10))) {
            return bytes1(uint8(b) + 0x30);
        } else {
            return bytes1(uint8(b) + 0x57);
        }
    }

    // ====================================================
    // 🔹 Project Management
    // ====================================================
    
    function addProject(
        string memory name,
        string memory description,
        string memory location,
        string memory impactMetrics,
        bytes32 ipfsHash,
        ProjectCategory category,
        uint32 stakingMultiplier,
        uint48 startBlock,
        uint48 endBlock
    ) external override nonReentrant onlyRole(PROJECT_MANAGER_ROLE) whenNotPaused {
        if (bytes(name).length == 0) revert NameRequired();
        if (uint256(category) > 12) revert InvalidCategory(); // Assuming 13 categories (0-12)
        
        // Fee Collection (50% Burn, 45% Treasury, 5% Buyback)
        if (!_collectFee(msg.sender, fees.projectSubmissionFee)) revert FeeTransferFailed();
            
        // Store Project Data
        uint256 newProjectId = projectCount++;
        
        projectMetadata[newProjectId] = ProjectData(name, description, location, impactMetrics, ipfsHash, true);
        projectStateData[newProjectId] = ProjectStateData({
            category: category,
            state: ProjectState.Proposed,
            stakingMultiplier: stakingMultiplier,
            totalStaked: 0,
            rewardPool: 0,
            isActive: false,
            startBlock: startBlock,
            endBlock: endBlock,
            owner: msg.sender,
            lastReportedValue: 0,
            lastRewardUpdate: block.timestamp,
            accumulatedRewards: 0
        });
        
        // Set default impact requirements based on category
        projectImpactRequirements[newProjectId] = categoryRequirements[category];
        
        // Set up initial permissions - owner has all permissions
        projectPermissions[newProjectId][msg.sender][EDIT_METADATA_PERMISSION] = true;
        projectPermissions[newProjectId][msg.sender][UPLOAD_DOCS_PERMISSION] = true;
        projectPermissions[newProjectId][msg.sender][SUBMIT_REPORTS_PERMISSION] = true;
        projectPermissions[newProjectId][msg.sender][MANAGE_COLLABORATORS_PERMISSION] = true;
        
        // Update index tracking
        _projectsByOwner[msg.sender].push(newProjectId);
        _projectsByCategory[category].push(newProjectId);
        
        emit ProjectAdded(newProjectId, name, category);
    }
    
    function updateProjectState(uint256 projectId, ProjectState newState) 
        external 
        override 
        nonReentrant 
        onlyRole(GOVERNANCE_ROLE) 
        whenNotPaused
    {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        ProjectState oldState = projectStateData[projectId].state;
        if (oldState == newState) revert StateUnchanged();
        
        projectStateData[projectId].state = newState;
        
        // If transitioning to Active, update active projects list
        if (newState == ProjectState.Active && oldState != ProjectState.Active) {
            projectStateData[projectId].isActive = true;
            _activeProjects.push(projectId);
        }
        
        // If transitioning away from Active, update active status
        if (oldState == ProjectState.Active && newState != ProjectState.Active) {
            projectStateData[projectId].isActive = false;
            
            // Remove from active projects array
            for (uint256 i = 0; i < _activeProjects.length; i++) {
                if (_activeProjects[i] == projectId) {
                    _activeProjects[i] = _activeProjects[_activeProjects.length - 1];
                    _activeProjects.pop();
                    break;
                }
            }
        }
        
        emit ProjectStateChanged(projectId, oldState, newState);
    }
    
    function updateProjectPermission(
        uint256 projectId, 
        address user, 
        bytes32 permission, 
        bool value
    ) external whenNotPaused {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        // Only project owner or user with MANAGE_COLLABORATORS_PERMISSION can update permissions
        if (
            msg.sender != projectStateData[projectId].owner && 
            !projectPermissions[projectId][msg.sender][MANAGE_COLLABORATORS_PERMISSION] &&
            !hasRole(GOVERNANCE_ROLE, msg.sender)
        ) {
            revert NotAuthorized();
        }
        
        // Cannot revoke owner's permissions
        if (user == projectStateData[projectId].owner && !value) {
            revert CannotRevokeOwnerPermissions();
        }
        
        projectPermissions[projectId][user][permission] = value;
        
        emit ProjectPermissionUpdated(projectId, user, permission, value);
    }
    
    function transferProjectOwnership(uint256 projectId, address newOwner) 
        external 
        nonReentrant 
        whenNotPaused
    {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        if (newOwner == address(0)) revert InvalidAddress();
        
        // Only current owner or governance can transfer ownership
        if (msg.sender != projectStateData[projectId].owner && !hasRole(GOVERNANCE_ROLE, msg.sender)) {
            revert NotAuthorized();
        }
        
        address oldOwner = projectStateData[projectId].owner;
        projectStateData[projectId].owner = newOwner;
        
        // Transfer all permissions to new owner
        projectPermissions[projectId][newOwner][EDIT_METADATA_PERMISSION] = true;
        projectPermissions[projectId][newOwner][UPLOAD_DOCS_PERMISSION] = true;
        projectPermissions[projectId][newOwner][SUBMIT_REPORTS_PERMISSION] = true;
        projectPermissions[projectId][newOwner][MANAGE_COLLABORATORS_PERMISSION] = true;
        
        // Update owner tracking
        for (uint256 i = 0; i < _projectsByOwner[oldOwner].length; i++) {
            if (_projectsByOwner[oldOwner][i] == projectId) {
                _projectsByOwner[oldOwner][i] = _projectsByOwner[oldOwner][_projectsByOwner[oldOwner].length - 1];
                _projectsByOwner[oldOwner].pop();
                break;
            }
        }
        _projectsByOwner[newOwner].push(projectId);
        
        emit OwnershipTransferred(projectId, oldOwner, newOwner);
    }
    
    function addProjectDocumentation(uint256 projectId, string[] calldata ipfsHashes) 
        external 
        override 
        nonReentrant 
        whenNotPaused
    {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        // Only owner, users with permission, or governance can add documentation
        if (
            msg.sender != projectStateData[projectId].owner && 
            !projectPermissions[projectId][msg.sender][UPLOAD_DOCS_PERMISSION] &&
            !hasRole(GOVERNANCE_ROLE, msg.sender)
        ) {
            revert NotAuthorized();
        }
        
        // Calculate which page to add to
        uint256 currentPageCount = projectDocumentPageCount[projectId];
        uint256 lastPageItemCount = 0;
        
        if (currentPageCount > 0) {
            lastPageItemCount = projectDocumentPages[projectId][currentPageCount - 1].length;
        }
        
        // Add documents to appropriate page
        for (uint256 i = 0; i < ipfsHashes.length; i++) {
            if (currentPageCount == 0 || lastPageItemCount == DOCUMENTS_PER_PAGE) {
                // Start a new page
                currentPageCount++;
                lastPageItemCount = 0;
            }
            
            projectDocumentPages[projectId][currentPageCount - 1].push(ipfsHashes[i]);
            lastPageItemCount++;
        }
        
        projectDocumentPageCount[projectId] = currentPageCount;
        
        emit DocumentationUpdated(projectId, ipfsHashes);
    }
    
    function getProjectDocumentPage(uint256 projectId, uint256 pageNumber) 
        external 
        view 
        override 
        returns (string[] memory) 
    {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        if (pageNumber >= projectDocumentPageCount[projectId]) revert PageDoesNotExist();
        
        return projectDocumentPages[projectId][pageNumber];
    }
    
    function addProjectComment(uint256 projectId, string calldata comment) 
        external 
        override 
        whenNotPaused
    {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        // Calculate which page to add to
        uint256 currentPageCount = projectCommentsPageCount[projectId];
        uint256 lastPageItemCount = 0;
        
        if (currentPageCount > 0) {
            lastPageItemCount = projectCommentsPages[projectId][currentPageCount - 1].length;
        }
        
        // Create new comment
        Comment memory newComment = Comment({
            author: msg.sender,
            timestamp: uint48(block.timestamp),
            content: comment
        });
        
        // Add comment to appropriate page
        if (currentPageCount == 0 || lastPageItemCount == COMMENTS_PER_PAGE) {
            // Start a new page
            currentPageCount++;
            projectCommentsPages[projectId][currentPageCount - 1] = new Comment[](0);
        }
        
        projectCommentsPages[projectId][currentPageCount - 1].push(newComment);
        projectCommentsPageCount[projectId] = currentPageCount;
    }
    
    function getProjectCommentsPage(uint256 projectId, uint256 pageNumber) 
        external 
        view 
        override 
        returns (Comment[] memory) 
    {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        if (pageNumber >= projectCommentsPageCount[projectId]) revert PageDoesNotExist();
        
        return projectCommentsPages[projectId][pageNumber];
    }
    
    // ====================================================
    // 🔹 Impact Reporting & Verification
    // ====================================================
    
    function submitImpactReport(
        uint256 projectId,
        uint256 impactValue,
        string calldata ipfsMetadataHash,
        string calldata reportingPeriod,
        bytes32 reportHash
    ) external override nonReentrant whenNotPaused {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        // Only owner, users with permission, or validators/governance can submit reports
        if (
            msg.sender != projectStateData[projectId].owner && 
            !projectPermissions[projectId][msg.sender][SUBMIT_REPORTS_PERMISSION] &&
            !hasRole(VALIDATOR_ROLE, msg.sender) &&
            !hasRole(GOVERNANCE_ROLE, msg.sender)
        ) {
            revert NotAuthorized();
        }
        
        // Collect reporting fee (50% Burn, 45% Treasury, 5% Buyback)
        if (!_collectFee(msg.sender, fees.impactReportingFee)) revert FeeTransferFailed();
        
        // Create impact report
        ImpactReport memory newReport = ImpactReport({
            reporter: msg.sender,
            timestamp: uint48(block.timestamp),
            impactValue: impactValue,
            ipfsMetadataHash: ipfsMetadataHash,
            reportingPeriod: reportingPeriod,
            reportHash: reportHash,
            verified: false,
            verifier: address(0),
            verificationDate: 0
        });
        
        // Add to project's impact reports
        projectImpactReports[projectId].push(newReport);
        
        // Update last reported value
        projectStateData[projectId].lastReportedValue = impactValue;
        
        // Update project analytics
        projectAnalytics[projectId].totalReports++;
        projectAnalytics[projectId].cumulativeImpact += impactValue;
        projectAnalytics[projectId].lastReportDate = uint48(block.timestamp);
        
        emit ImpactReported(projectId, projectImpactReports[projectId].length - 1, reportHash, msg.sender);
    }
    
    function verifyImpactReport(
        uint256 projectId, 
        uint256 reportIndex, 
        bool approved,
        string calldata verificationComment
    ) external override nonReentrant onlyRole(VERIFIER_ROLE) whenNotPaused {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        ImpactReport[] storage reports = projectImpactReports[projectId];
        if (reportIndex >= reports.length) revert InvalidReportIndex();
        if (reports[reportIndex].verified) revert ReportAlreadyVerified();
        
        // Update verification status
        reports[reportIndex].verified = approved;
        reports[reportIndex].verifier = msg.sender;
        reports[reportIndex].verificationDate = uint48(block.timestamp);
        
        // Store verification comment
        projectVerificationComments[projectId][reportIndex] = verificationComment;
        
        // Update project analytics
        if (approved) {
            projectAnalytics[projectId].verifiedReports++;
            projectAnalytics[projectId].verifiedImpact += reports[reportIndex].impactValue;
            
            // Add to reward pool based on impact and staking multiplier
            uint256 rewardAmount = reports[reportIndex].impactValue * projectStateData[projectId].stakingMultiplier / 100;
            projectStateData[projectId].rewardPool += rewardAmount;
            projectStateData[projectId].accumulatedRewards += rewardAmount;
            
            emit RewardsAccumulated(projectId, rewardAmount);
        }
        
        emit ImpactVerified(projectId, reportIndex, msg.sender, approved);
    }
    
    // ====================================================
    // 🔹 Project Staking
    // ====================================================
    
    function stakeInProject(uint256 projectId, uint256 amount) external override nonReentrant whenNotPaused {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        if (amount == 0) revert ZeroAmount();
        if (projectStateData[projectId].state != ProjectState.Active) revert ProjectNotActive();
        
        // Transfer tokens from user to contract
        tStakeToken.safeTransferFrom(msg.sender, address(this), amount);
        
        // Update staking records
        if (projectStakes[projectId][msg.sender] == 0) {
            projectStakers[projectId].push(msg.sender);
            userStakedProjects[msg.sender].push(projectId);
            lastRewardClaim[projectId][msg.sender] = block.timestamp;
        }
        
        projectStakes[projectId][msg.sender] += amount;
        projectStateData[projectId].totalStaked += amount;
        
        // Grant staker role if they don't have it
        if (!hasRole(STAKER_ROLE, msg.sender)) {
            _grantRole(STAKER_ROLE, msg.sender);
        }
        
        emit Staked(projectId, msg.sender, amount);
    }
    
    function unstakeFromProject(uint256 projectId, uint256 amount) external override nonReentrant {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        if (amount == 0) revert ZeroAmount();
        if (projectStakes[projectId][msg.sender] < amount) revert InsufficientStake();
        
        // Claim any pending rewards first
        _claimRewards(projectId);
        
        // Update staking records
        projectStakes[projectId][msg.sender] -= amount;
        projectStateData[projectId].totalStaked -= amount;
        
        // Remove from tracking arrays if completely unstaked
        if (projectStakes[projectId][msg.sender] == 0) {
            _removeFromStakers(projectId, msg.sender);
            _removeFromUserStakedProjects(msg.sender, projectId);
        }
        
        // Transfer tokens back to user
        tStakeToken.safeTransfer(msg.sender, amount);
        
        emit Unstaked(projectId, msg.sender, amount);
    }
    
    function claimProjectRewards(uint256 projectId) external override nonReentrant {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        uint256 rewards = _claimRewards(projectId);
        if (rewards == 0) revert NoRewardsAvailable();
        
        // Transfer rewards to user
        tStakeToken.safeTransfer(msg.sender, rewards);
        
        emit RewardsClaimed(projectId, msg.sender, rewards);
    }
    
    function _claimRewards(uint256 projectId) internal returns (uint256) {
        uint256 stakedAmount = projectStakes[projectId][msg.sender];
        if (stakedAmount == 0) return 0;
        
        uint256 lastClaim = lastRewardClaim[projectId][msg.sender];
        uint256 timeSinceLastClaim = block.timestamp - lastClaim;
        
        // Must have staked for at least 1 day
        if (timeSinceLastClaim < MIN_CLAIM_PERIOD) return 0;
        
        // Calculate time-based rewards: stake * days * daily rate
        uint256 timeReward = stakedAmount * timeSinceLastClaim * TIME_REWARD_RATE / (100 * 1 days);
        
        // Calculate impact-based rewards: proportional share of verified impact
        uint256 impactReward = 0;
        if (projectStateData[projectId].totalStaked > 0 && projectStateData[projectId].rewardPool > 0) {
            impactReward = projectStateData[projectId].rewardPool * stakedAmount / projectStateData[projectId].totalStaked;
            
            // Reduce the reward pool
            projectStateData[projectId].rewardPool -= impactReward;
        }
        
        // Update last claim time
        lastRewardClaim[projectId][msg.sender] = block.timestamp;
        
        // Total rewards = time-based + impact-based
        return timeReward + impactReward;
    }
    
    function _removeFromStakers(uint256 projectId, address staker) internal {
        address[] storage stakers = projectStakers[projectId];
        for (uint256 i = 0; i < stakers.length; i++) {
            if (stakers[i] == staker) {
                stakers[i] = stakers[stakers.length - 1];
                stakers.pop();
                break;
            }
        }
    }
    
    function _removeFromUserStakedProjects(address user, uint256 projectId) internal {
        uint256[] storage projects = userStakedProjects[user];
        for (uint256 i = 0; i < projects.length; i++) {
            if (projects[i] == projectId) {
                projects[i] = projects[projects.length - 1];
                projects.pop();
                break;
            }
        }
    }
    
    // ====================================================
    // 🔹 REC Management
    // ====================================================
    
    function registerREC(
        uint256 projectId, 
        uint256 mwhAmount, 
        string calldata generation_period,
        string calldata location,
        bytes32 recId
    ) external nonReentrant onlyRole(VALIDATOR_ROLE) whenNotPaused {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        if (projectStateData[projectId].state != ProjectState.Active) revert ProjectNotActive();
        
        // Create new REC
        RECData memory newREC = RECData({
            mwhAmount: mwhAmount,
            generationPeriod: generation_period,
            location: location,
            recId: recId,
            issueDate: uint48(block.timestamp),
            owner: projectStateData[projectId].owner,
            active: true,
            retired: false,
            retirementPurpose: "",
            retirementDate: 0,
            externalRegistryId: ""
        });
        
        // Add to project's RECs
        projectRECs[projectId].push(newREC);
        
        // Add to project analytics
        projectAnalytics[projectId].totalRECs++;
        projectAnalytics[projectId].totalMWh += mwhAmount;
    }
    
    function retireREC(uint256 projectId, uint256 recIndex, string calldata purpose) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        RECData[] storage recs = projectRECs[projectId];
        if (recIndex >= recs.length) revert RECNotFound();
        if (!recs[recIndex].active || recs[recIndex].retired) revert RECNotActive();
        if (recs[recIndex].owner != msg.sender) revert NotRECOwner();
        
        // Update REC status
        recs[recIndex].retired = true;
        recs[recIndex].active = false;
        recs[recIndex].retirementPurpose = purpose;
        recs[recIndex].retirementDate = uint48(block.timestamp);
        
        // Update project analytics
        projectAnalytics[projectId].retiredRECs++;
        projectAnalytics[projectId].retiredMWh += recs[recIndex].mwhAmount;
        
        emit RECRetired(projectId, recs[recIndex].recId, msg.sender, purpose);
    }
    
    function transferREC(uint256 projectId, uint256 recIndex, address newOwner) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        if (newOwner == address(0)) revert InvalidAddress();
        
        RECData[] storage recs = projectRECs[projectId];
        if (recIndex >= recs.length) revert RECNotFound();
        if (!recs[recIndex].active || recs[recIndex].retired) revert RECNotActive();
        if (recs[recIndex].owner != msg.sender) revert NotRECOwner();
        
        // Transfer ownership
        address previousOwner = recs[recIndex].owner;
        recs[recIndex].owner = newOwner;
        
        emit RECTransferred(projectId, recs[recIndex].recId, previousOwner, newOwner);
    }
    
    function syncRECWithExternalRegistry(
        uint256 projectId, 
        uint256 recIndex, 
        string calldata externalId
    ) external nonReentrant onlyRole(VALIDATOR_ROLE) whenNotPaused {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        RECData[] storage recs = projectRECs[projectId];
        if (recIndex >= recs.length) revert RECNotFound();
        
        // Update external registry ID
        recs[recIndex].externalRegistryId = externalId;
        
        emit RECRegistrySync(projectId, recs[recIndex].recId, externalId);
    }
    
    // ====================================================
    // 🔹 Project Verification
    // ====================================================
    
    function verifyProject(
        uint256 projectId, 
        string calldata verificationStandard, 
        bytes32 documentHash
    ) external nonReentrant onlyRole(VERIFIER_ROLE) whenNotPaused {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        // Record verification data
        projectValidations[projectId] = ValidationData({
            validator: msg.sender,
            validationDate: uint48(block.timestamp),
            validStandard: verificationStandard,
            documentHash: documentHash
        });
        
        // Update project verification
        projectVerifications[projectId] = VerificationData({
            verifier: msg.sender,
            verificationDate: uint48(block.timestamp),
            verificationStandard: verificationStandard,
            documentHash: documentHash
        });
        
        emit ProjectVerified(projectId, msg.sender, verificationStandard, documentHash);
    }
    
    // ====================================================
    // 🔹 Fee Management
    // ====================================================
    
    function updateFeeStructure(
        uint256 projectFee,
        uint256 reportingFee,
        uint256 categoryChangeFee,
        uint256 verificationFee
    ) external onlyRole(GOVERNANCE_ROLE) {
        fees = FeeStructure({
            projectSubmissionFee: projectFee,
            impactReportingFee: reportingFee,
            categoryChangeFee: categoryChangeFee,
            verificationFee: verificationFee
        });
        
        emit FeeStructureUpdated(projectFee, reportingFee, verificationFee, categoryChangeFee);
    }
    
    function _collectFee(address payer, uint256 feeAmount) internal returns (bool) {
        if (feeAmount == 0) return true;
        
        // Transfer fees from payer to contract
        bool success = tStakeToken.transferFrom(payer, address(this), feeAmount);
        if (!success) return false;
        
        // Calculate fee distribution
        uint256 burnAmount = feeAmount * 50 / 100;     // 50% burn
        uint256 treasuryAmount = feeAmount * 45 / 100; // 45% to treasury
        uint256 buybackAmount = feeAmount * 5 / 100;   // 5% for buyback
        
        // Burn tokens
        tStakeToken.transfer(DEAD_ADDRESS, burnAmount);
        
        // Send to treasury if configured
        if (treasuryAddress != address(0)) {
            tStakeToken.transfer(treasuryAddress, treasuryAmount);
        } else {
            // If treasury not set, add to buyback amount
            buybackAmount += treasuryAmount;
        }
        
        // Add to buyback funds
        accumulatedBuybackFunds += buybackAmount;
        
        emit FeeCollected(payer, feeAmount, burnAmount, treasuryAmount, buybackAmount);
        emit TokensBurned(burnAmount);
        
        return true;
    }
    
    function executeBuyback() external onlyRole(TREASURY_ROLE) nonReentrant {
        if (accumulatedBuybackFunds == 0) revert NoBuybackFunds();
        
        uint256 amount = accumulatedBuybackFunds;
        accumulatedBuybackFunds = 0;
        
        // In a real implementation, this would interact with a liquidity pool
        // For this example, we'll just emit the event
        emit BuybackExecuted(amount);
    }
    
    // ====================================================
    // 🔹 Administrative Functions
    // ====================================================
    
    function setTreasuryAddress(address _treasuryAddress) external onlyRole(GOVERNANCE_ROLE) {
        if (_treasuryAddress == address(0)) revert InvalidAddress();
        treasuryAddress = _treasuryAddress;
        emit TreasuryAddressSet(_treasuryAddress);
    }
    
    function toggleEmergencyMode() external onlyRole(GOVERNANCE_ROLE) {
        emergencyMode = !emergencyMode;
        
        if (emergencyMode) {
            _pause();
            emit EmergencyModeActivated(msg.sender);
        } else {
            _unpause();
            emit EmergencyModeDeactivated(msg.sender);
        }
        
        emit EmergencyModeToggled(emergencyMode);
    }
    
    function recoverTokens(address token, uint256 amount) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        if (token == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();
        
        // For native token, can't be the system token
        if (token == address(tStakeToken)) {
            // Calculate maximum recoverable amount (excluding staked tokens and rewards)
            uint256 maxRecoverable = tStakeToken.balanceOf(address(this)) - accumulatedBuybackFunds;
            
            for (uint256 i = 0; i < _activeProjects.length; i++) {
                uint256 projectId = _activeProjects[i];
                maxRecoverable -= projectStateData[projectId].totalStaked;
                maxRecoverable -= projectStateData[projectId].rewardPool;
            }
            
            if (amount > maxRecoverable) revert ExceedsRecoverableAmount();
        }
        
        // Transfer tokens to treasury
        if (token == address(0)) {
            // Native token (ETH)
            payable(treasuryAddress).transfer(amount);
        } else {
            // ERC20 tokens
            IERC20(token).safeTransfer(treasuryAddress, amount);
        }
        
        emit TokensRecovered(token, treasuryAddress, amount);
    }
    
    // ====================================================
    // 🔹 View Functions
    // ====================================================
    
    function getProjectMetadata(uint256 projectId) 
        external 
        view 
        override 
        returns (ProjectData memory) 
    {
        return projectMetadata[projectId];
    }
    
    function getProjectStateData(uint256 projectId) 
        external 
        view 
        override 
        returns (ProjectStateData memory) 
    {
        return projectStateData[projectId];
    }
    
    function getProjectAnalytics(uint256 projectId) 
        external 
        view 
        override 
        returns (ProjectAnalytics memory) 
    {
        return projectAnalytics[projectId];
    }
    
    function getProjectsByOwner(address owner) 
        external 
        view 
        override 
        returns (uint256[] memory) 
    {
        return _projectsByOwner[owner];
    }
    
    function getProjectsByCategory(ProjectCategory category) 
        external 
        view 
        override 
        returns (uint256[] memory) 
    {
        return _projectsByCategory[category];
    }
    
    function getActiveProjects() 
        external 
        view 
        override 
        returns (uint256[] memory) 
    {
        return _activeProjects;
    }
    
    function getProjectImpactReports(uint256 projectId) 
        external 
        view 
        override 
        returns (ImpactReport[] memory) 
    {
        return projectImpactReports[projectId];
    }
    
    function getStakersForProject(uint256 projectId) 
        external 
        view 
        override 
        returns (address[] memory) 
    {
        return projectStakers[projectId];
    }
    
    function getUserStakedProjects(address user) 
        external 
        view 
        override 
        returns (uint256[] memory) 
    {
        return userStakedProjects[user];
    }
    
    function calculatePendingRewards(uint256 projectId, address staker) 
        external 
        view 
        override 
        returns (uint256) 
    {
        uint256 stakedAmount = projectStakes[projectId][staker];
        if (stakedAmount == 0) return 0;
        
        uint256 lastClaim = lastRewardClaim[projectId][staker];
        uint256 timeSinceLastClaim = block.timestamp - lastClaim;
        
        // Calculate time-based rewards
        uint256 timeReward = stakedAmount * timeSinceLastClaim * TIME_REWARD_RATE / (100 * 1 days);
        
        // Calculate impact-based rewards
        uint256 impactReward = 0;
        if (projectStateData[projectId].totalStaked > 0 && projectStateData[projectId].rewardPool > 0) {
            impactReward = projectStateData[projectId].rewardPool * stakedAmount / projectStateData[projectId].totalStaked;
        }
        
        return timeReward + impactReward;
    }
    
    // ====================================================
    // 🔹 Receive Function
    // ====================================================
    
    // Allow contract to receive ETH
    receive() external payable {}
}
