// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
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

    // ====================================================
    // 📌 State Variables
    // ====================================================
    IERC20 public tStakeToken;
    uint256 public projectCount;
    
    FeeStructure public fees;
    address public treasury;
    address public liquidityPool;
    address public stakingContract;
    address public rewardsContract;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    
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
    
    // Custom data structure to store real-world category information
    struct CategoryInfo {
        string name;
        string description;
        string[] standardBodies;
        string[] metricUnits;
        string verificationStandard;
        uint256 impactWeight;
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
        
        tStakeToken = IERC20(_tstakeToken);
        
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
        
        // Update isActive flag based on state
        bool wasActive = projectStateData[projectId].isActive;
        bool willBeActive = false;
        
        if (newState == ProjectState.Active) {
            willBeActive = true;
            projectStateData[projectId].isActive = true;
        } else if (newState == ProjectState.Suspended || 
                 newState == ProjectState.Completed || 
                 newState == ProjectState.Archived) {
            willBeActive = false;
            projectStateData[projectId].isActive = false;
        }
        
        // Update active projects tracking
        if (!wasActive && willBeActive) {
            _activeProjects.push(projectId);
        } else if (wasActive && !willBeActive) {
            _removeFromActiveProjects(projectId);
        }
        
        emit ProjectStateChanged(projectId, oldState, newState);
    }
    
    function _removeFromActiveProjects(uint256 projectId) internal {
        uint256 length = _activeProjects.length;
        for (uint256 i = 0; i < length; i++) {
            if (_activeProjects[i] == projectId) {
                // Move the last element to the position of the removed element
                if (i != length - 1) {
                    _activeProjects[i] = _activeProjects[length - 1];
                }
                // Remove the last element
                _activeProjects.pop();
                break;
            }
        }
    }
    
    // Enhanced document upload with pagination
    function uploadProjectDocuments(uint256 projectId, string[] calldata ipfsHashes) 
        external 
        override 
        nonReentrant
        whenNotPaused
    {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        if (!hasProjectPermission(projectId, msg.sender, UPLOAD_DOCS_PERMISSION))
            revert NotAuthorized();
            
        uint256 currentPage = projectDocumentPageCount[projectId];
        
        // If no pages yet or current page is full, create a new page
        if (currentPage == 0 || projectDocumentPages[projectId][currentPage - 1].length + ipfsHashes.length > DOCUMENTS_PER_PAGE) {
            projectDocumentPageCount[projectId]++;
            currentPage = projectDocumentPageCount[projectId];
        }
        
        for (uint256 i = 0; i < ipfsHashes.length; i++) {
            if (projectDocumentPages[projectId][currentPage - 1].length >= DOCUMENTS_PER_PAGE) {
                // If current page is full, create new page
                projectDocumentPageCount[projectId]++;
                currentPage = projectDocumentPageCount[projectId];
            }
            projectDocumentPages[projectId][currentPage - 1].push(ipfsHashes[i]);
        }
        
        emit DocumentationUpdated(projectId, ipfsHashes);
    }
    
    // Enhanced document retrieval with pagination
    function getProjectDocuments(uint256 projectId, uint256 page) 
        external 
        view 
        override 
        returns (string[] memory) 
    {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        if (page >= projectDocumentPageCount[projectId]) revert PageDoesNotExist();
        
        return projectDocumentPages[projectId][page];
    }
    
    // Get total number of document pages
    function getProjectDocumentPageCount(uint256 projectId) 
        external 
        view 
        returns (uint256) 
    {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        return projectDocumentPageCount[projectId];
    }
    
    function submitImpactReport(
        uint256 projectId,
        uint256 periodStart,
        uint256 periodEnd,
        uint256[] memory metrics,
        bytes32 reportHash
    ) external override nonReentrant whenNotPaused {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        if (emergencyMode) revert EmergencyModeActive();
        
        // Check permissions for impact reporting
        if (!hasProjectPermission(projectId, msg.sender, SUBMIT_REPORTS_PERMISSION) && 
            !hasRole(STAKER_ROLE, msg.sender)) {
            revert NotAuthorized();
        }
        
        // Fee Collection (50% Burn, 45% Treasury, 5% Buyback)
        if (!_collectFee(msg.sender, fees.impactReportingFee)) revert FeeTransferFailed();
        
        // Add the impact report
        projectImpactReports[projectId].push(ImpactReport

            periodStart: periodStart,
            periodEnd: periodEnd,
            reportedBy: msg.sender,
            timestamp: block.timestamp,
            metrics: metrics,
            reportHash: reportHash,
            verificationStatus: VerificationStatus.Pending,
            verifiedBy: address(0),
            verificationDate: 0
        });
        
        uint256 reportIndex = projectImpactReports[projectId].length - 1;
        
        // Store the latest reported metrics for the project
        if (metrics.length > 0) {
            uint256 totalImpactValue = 0;
            for (uint256 i = 0; i < metrics.length; i++) {
                totalImpactValue += metrics[i];
            }
            
            // Update project's last reported value
            projectStateData[projectId].lastReportedValue = totalImpactValue;
            
            // Calculate & accumulate rewards based on impact
            if (projectStateData[projectId].isActive) {
                _calculateAndAccumulateRewards(projectId, totalImpactValue);
            }
        }
        
        emit ImpactReported(projectId, reportIndex, reportHash, msg.sender);
    }
    
    function _calculateAndAccumulateRewards(uint256 projectId, uint256 impactValue) internal {
        uint256 timeSinceLastUpdate = block.timestamp - projectStateData[projectId].lastRewardUpdate;
        
        // If there's no staking, no rewards are generated
        if (projectStateData[projectId].totalStaked == 0) return;
        
        // Base reward rate adjusted by impact and time
        uint256 baseReward = impactValue * projectStateData[projectId].stakingMultiplier * timeSinceLastUpdate / 1 days;
        
        // Apply category impact weight (0-100 scale)
        ProjectCategory category = projectStateData[projectId].category;
        uint256 categoryWeight = categoryInfo[category].impactWeight;
        uint256 weightedReward = baseReward * categoryWeight / 100;
        
        // Cap rewards at the available reward pool
        uint256 availableRewards = Math.min(weightedReward, projectStateData[projectId].rewardPool);
        
        // Update accumulated rewards
        projectStateData[projectId].accumulatedRewards += availableRewards;
        
        // Update the reward pool
        projectStateData[projectId].rewardPool -= availableRewards;
        
        // Update the last reward update timestamp
        projectStateData[projectId].lastRewardUpdate = block.timestamp;
        
        emit RewardsAccumulated(projectId, availableRewards);
    }
    
    function verifyImpactReport(
        uint256 projectId,
        uint256 reportIndex,
        bool approved,
        string calldata verificationComments
    ) external override nonReentrant onlyRole(VERIFIER_ROLE) whenNotPaused {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        if (reportIndex >= projectImpactReports[projectId].length) revert InvalidReportIndex();
        
        ImpactReport storage report = projectImpactReports[projectId][reportIndex];
        
        // Ensure report is pending verification
        if (report.verificationStatus != VerificationStatus.Pending) revert ReportAlreadyVerified();
        
        // Update verification status
        report.verificationStatus = approved ? VerificationStatus.Verified : VerificationStatus.Rejected;
        report.verifiedBy = msg.sender;
        report.verificationDate = block.timestamp;
        
        // Store verification comments
        projectVerificationComments[projectId][reportIndex] = verificationComments;
        
        emit ImpactVerified(projectId, reportIndex, msg.sender, approved);
    }

    // ====================================================
    // 🔹 Project Governance and Permissions
    // ====================================================
    
    function assignProjectPermission(
        uint256 projectId,
        address collaborator,
        uint8 permission,
        bool value
    ) external override nonReentrant whenNotPaused {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        // Only project owner or someone with manage collaborators permission can assign permissions
        if (projectStateData[projectId].owner != msg.sender && 
            !hasProjectPermission(projectId, msg.sender, MANAGE_COLLABORATORS_PERMISSION)) {
            revert NotAuthorized();
        }
        
        // Ensure valid permission type
        if (permission > MAX_PERMISSION) revert InvalidPermission();
        
        projectPermissions[projectId][collaborator][permission] = value;
        
        emit PermissionUpdated(projectId, collaborator, permission, value);
    }
    
    function hasProjectPermission(uint256 projectId, address user, uint8 permission) 
        public 
        view 
        override 
        returns (bool) 
    {
        // Project owners have all permissions
        if (projectStateData[projectId].owner == user) {
            return true;
        }
        
        // Governance role has all project permissions
        if (hasRole(GOVERNANCE_ROLE, user)) {
            return true;
        }
        
        // Check specific permission
        return projectPermissions[projectId][user][permission];
    }
    
    function transferProjectOwnership(uint256 projectId, address newOwner) 
        external 
        override 
        nonReentrant 
        whenNotPaused 
    {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        if (projectStateData[projectId].owner != msg.sender) revert NotAuthorized();
        if (newOwner == address(0)) revert InvalidAddress();
        
        address oldOwner = projectStateData[projectId].owner;
        projectStateData[projectId].owner = newOwner;
        
        // Update owner indices
        _removeFromOwnerProjects(oldOwner, projectId);
        _projectsByOwner[newOwner].push(projectId);
        
        emit OwnershipTransferred(projectId, oldOwner, newOwner);
    }
    
    function _removeFromOwnerProjects(address owner, uint256 projectId) internal {
        uint256[] storage projects = _projectsByOwner[owner];
        for (uint256 i = 0; i < projects.length; i++) {
            if (projects[i] == projectId) {
                // Move the last element to this position
                if (i != projects.length - 1) {
                    projects[i] = projects[projects.length - 1];
                }
                // Remove the last element
                projects.pop();
                break;
            }
        }
    }

    // ====================================================
    // 🔹 Staking & Rewards
    // ====================================================
    
    function stake(uint256 projectId, uint256 amount) 
        external 
        override 
        nonReentrant 
        whenNotPaused 
    {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        if (projectStateData[projectId].state != ProjectState.Active) revert ProjectNotActive();
        if (amount == 0) revert ZeroAmount();
        
        // Check if Terra token is defined
        if (terraTokenAddress == address(0)) revert TokenNotConfigured();
        
        // Transfer tokens from user
        IERC20 terraToken = IERC20(terraTokenAddress);
        bool success = terraToken.transferFrom(msg.sender, address(this), amount);
        if (!success) revert TokenTransferFailed();
        
        // Update staking info
        uint256 prevAmount = projectStakes[projectId][msg.sender];
        projectStakes[projectId][msg.sender] += amount;
        projectStateData[projectId].totalStaked += amount;
        
        // If this is a new staker, grant the staker role
        if (prevAmount == 0 && !hasRole(STAKER_ROLE, msg.sender)) {
            _grantRole(STAKER_ROLE, msg.sender);
        }
        
        // Add to reward pool (50% of stake goes to rewards)
        uint256 rewardAmount = amount * 50 / 100;
        projectStateData[projectId].rewardPool += rewardAmount;
        
        // Add user to project stakers if not already there
        if (!_isInProjectStakers(projectId, msg.sender)) {
            projectStakers[projectId].push(msg.sender);
        }
        
        // Track all projects user has staked in
        if (!_isInUserStakedProjects(msg.sender, projectId)) {
            userStakedProjects[msg.sender].push(projectId);
        }
        
        emit Staked(projectId, msg.sender, amount);
    }
    
    function _isInProjectStakers(uint256 projectId, address staker) internal view returns (bool) {
        for (uint256 i = 0; i < projectStakers[projectId].length; i++) {
            if (projectStakers[projectId][i] == staker) {
                return true;
            }
        }
        return false;
    }
    
    function _isInUserStakedProjects(address user, uint256 projectId) internal view returns (bool) {
        for (uint256 i = 0; i < userStakedProjects[user].length; i++) {
            if (userStakedProjects[user][i] == projectId) {
                return true;
            }
        }
        return false;
    }
    
    function unstake(uint256 projectId, uint256 amount) 
        external 
        override 
        nonReentrant 
    {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        uint256 stakedAmount = projectStakes[projectId][msg.sender];
        if (stakedAmount < amount) revert InsufficientStake();
        
        // Calculate any rewards before unstaking
        uint256 rewards = calculateRewards(projectId, msg.sender);
        
        // Update staking info
        projectStakes[projectId][msg.sender] -= amount;
        projectStateData[projectId].totalStaked -= amount;
        
        // If completely unstaked, remove from project stakers
        if (projectStakes[projectId][msg.sender] == 0) {
            _removeFromProjectStakers(projectId, msg.sender);
            _removeFromUserStakedProjects(msg.sender, projectId);
        }
        
        // Transfer staked tokens back to user
        IERC20 terraToken = IERC20(terraTokenAddress);
        bool success = terraToken.transfer(msg.sender, amount);
        if (!success) revert TokenTransferFailed();
        
        // If there are rewards, transfer them as well
        if (rewards > 0) {
            success = terraToken.transfer(msg.sender, rewards);
            if (!success) revert TokenTransferFailed();
            
            emit RewardsClaimed(projectId, msg.sender, rewards);
        }
        
        emit Unstaked(projectId, msg.sender, amount);
    }
    
    function _removeFromProjectStakers(uint256 projectId, address staker) internal {
        address[] storage stakers = projectStakers[projectId];
        for (uint256 i = 0; i < stakers.length; i++) {
            if (stakers[i] == staker) {
                // Move the last element to this position
                if (i != stakers.length - 1) {
                    stakers[i] = stakers[stakers.length - 1];
                }
                // Remove the last element
                stakers.pop();
                break;
            }
        }
    }
    
    function _removeFromUserStakedProjects(address user, uint256 projectId) internal {
        uint256[] storage projects = userStakedProjects[user];
        for (uint256 i = 0; i < projects.length; i++) {
            if (projects[i] == projectId) {
                // Move the last element to this position
                if (i != projects.length - 1) {
                    projects[i] = projects[projects.length - 1];
                }
                // Remove the last element
                projects.pop();
                break;
            }
        }
        
        // If user is no longer staking in any projects, revoke staker role
        if (projects.length == 0) {
            _revokeRole(STAKER_ROLE, user);
        }
    }
    
    function claimRewards(uint256 projectId) 
        external 
        override 
        nonReentrant 
        whenNotPaused 
    {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        uint256 rewards = calculateRewards(projectId, msg.sender);
        if (rewards == 0) revert NoRewardsAvailable();
        
        // Reset user's last claimed time
        lastRewardClaim[projectId][msg.sender] = block.timestamp;
        
        // Transfer rewards
        IERC20 terraToken = IERC20(terraTokenAddress);
        bool success = terraToken.transfer(msg.sender, rewards);
        if (!success) revert TokenTransferFailed();
        
        emit RewardsClaimed(projectId, msg.sender, rewards);
    }
    
    function calculateRewards(uint256 projectId, address staker) 
        public 
        view 
        override 
        returns (uint256) 
    {
        if (!projectMetadata[projectId].exists) return 0;
        
        uint256 userStake = projectStakes[projectId][staker];
        if (userStake == 0) return 0;
        
        uint256 totalStaked = projectStateData[projectId].totalStaked;
        if (totalStaked == 0) return 0;
        
        // Calculate the user's share of accumulated rewards
        uint256 userShare = (userStake * projectStateData[projectId].accumulatedRewards) / totalStaked;
        
        // Calculate duration-based reward if project is still active
        uint256 lastClaim = lastRewardClaim[projectId][staker];
        if (lastClaim == 0) {
            lastClaim = block.timestamp - MIN_CLAIM_PERIOD; // First time claimer gets MIN_CLAIM_PERIOD worth
        }
        
        uint256 timeSinceLastClaim = block.timestamp - lastClaim;
        if (timeSinceLastClaim < MIN_CLAIM_PERIOD) {
            // Not enough time has passed for rewards
            return 0;
        }
        
        // Time-based rewards as a portion of user's stake (0.01% per day)
        uint256 timeBasedReward = (userStake * timeSinceLastClaim * TIME_REWARD_RATE) / (1 days * 10000);
        
        return userShare + timeBasedReward;
    }

    // ====================================================
    // 🔹 Fee Management
    // ====================================================
    
    function updateFees(
        uint256 newProjectFee,
        uint256 newReportingFee,
        uint256 newUpdateFee
    ) external onlyRole(GOVERNANCE_ROLE) {
        fees.projectSubmissionFee = newProjectFee;
        fees.impactReportingFee = newReportingFee;
        fees.metadataUpdateFee = newUpdateFee;
        
        emit FeesUpdated(newProjectFee, newReportingFee, newUpdateFee);
    }
        function _collectFee(address payer, uint256 feeAmount) internal returns (bool) {
        if (feeAmount == 0) return true;
        
        // Check if Terra token is defined
        if (terraTokenAddress == address(0)) revert TokenNotConfigured();
        
        // Transfer tokens from payer
        IERC20 terraToken = IERC20(terraTokenAddress);
        bool success = terraToken.transferFrom(payer, address(this), feeAmount);
        if (!success) return false;
        
        // Fee distribution:
        // 50% Burn
        uint256 burnAmount = feeAmount * 50 / 100;
        
        // 45% Treasury
        uint256 treasuryAmount = feeAmount * 45 / 100;
        
        // 5% Buyback
        uint256 buybackAmount = feeAmount * 5 / 100;
        
        if (burnAmount > 0) {
            // Burn tokens by sending to dead address
            success = terraToken.transfer(DEAD_ADDRESS, burnAmount);
            if (!success) return false;
        }
        
        if (treasuryAmount > 0 && treasuryAddress != address(0)) {
            success = terraToken.transfer(treasuryAddress, treasuryAmount);
            if (!success) return false;
        }
        
        if (buybackAmount > 0) {
            // Accumulate for buyback
            accumulatedBuybackFunds += buybackAmount;
        }
        
        emit FeeCollected(payer, feeAmount, burnAmount, treasuryAmount, buybackAmount);
        return true;
    }
    
    function executeBuyback() external onlyRole(TREASURY_ROLE) nonReentrant {
        if (terraTokenAddress == address(0)) revert TokenNotConfigured();
        if (accumulatedBuybackFunds == 0) revert NoBuybackFunds();
        
        uint256 amount = accumulatedBuybackFunds;
        accumulatedBuybackFunds = 0;
        
        // Implementation of buyback mechanism would depend on your tokenomics
        // This could involve interaction with DEX, sending to a vault contract, etc.
        // For simplicity, we're just transferring to the treasury
        IERC20 terraToken = IERC20(terraTokenAddress);
        bool success = terraToken.transfer(treasuryAddress, amount);
        if (!success) revert TokenTransferFailed();
        
        emit BuybackExecuted(amount);
    }

    // ====================================================
    // 🔹 Query Functions
    // ====================================================
    
    function getProjectData(uint256 projectId) 
        external 
        view 
        override 
        returns (
            string memory name,
            string memory description,
            string memory location,
            string memory impactMetrics,
            bytes32 ipfsHash,
            ProjectCategory category,
            ProjectState state,
            uint32 stakingMultiplier,
            uint256 totalStaked,
            uint256 rewardPool,
            bool isActive,
            uint48 startBlock,
            uint48 endBlock,
            address owner
        ) 
    {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        ProjectData storage metadata = projectMetadata[projectId];
        ProjectStateData storage stateData = projectStateData[projectId];
        
        return (
            metadata.name,
            metadata.description,
            metadata.location,
            metadata.impactMetrics,
            metadata.ipfsHash,
            stateData.category,
            stateData.state,
            stateData.stakingMultiplier,
            stateData.totalStaked,
            stateData.rewardPool,
            stateData.isActive,
            stateData.startBlock,
            stateData.endBlock,
            stateData.owner
        );
    }
    
    function getProjectCount() external view override returns (uint256) {
        return projectCount;
    }
    
    function getImpactReportCount(uint256 projectId) external view override returns (uint256) {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        return projectImpactReports[projectId].length;
    }
    
    function getImpactReport(uint256 projectId, uint256 reportIndex) 
        external 
        view 
        override 
        returns (
            uint256 periodStart,
            uint256 periodEnd,
            address reportedBy,
            uint256 timestamp,
            uint256[] memory metrics,
            bytes32 reportHash,
            VerificationStatus verificationStatus,
            address verifiedBy,
            uint256 verificationDate
        ) 
    {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        if (reportIndex >= projectImpactReports[projectId].length) revert InvalidReportIndex();
        
        ImpactReport storage report = projectImpactReports[projectId][reportIndex];
        
        return (
            report.periodStart,
            report.periodEnd,
            report.reportedBy,
            report.timestamp,
            report.metrics,
            report.reportHash,
            report.verificationStatus,
            report.verifiedBy,
            report.verificationDate
        );
    }
    
    function getUserStakedProjects(address user) external view returns (uint256[] memory) {
        return userStakedProjects[user];
    }
    
    function getProjectStakers(uint256 projectId) external view returns (address[] memory) {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        return projectStakers[projectId];
    }
    
    function getStakedAmount(uint256 projectId, address staker) external view returns (uint256) {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        return projectStakes[projectId][staker];
    }
    
    function getProjectsByCategory(ProjectCategory category) external view returns (uint256[] memory) {
        return _projectsByCategory[category];
    }
    
    function getProjectsByOwner(address owner) external view returns (uint256[] memory) {
        return _projectsByOwner[owner];
    }
    
    function getActiveProjects() external view returns (uint256[] memory) {
        return _activeProjects;
    }
    
    function getCategoryInfo(ProjectCategory category) 
        external 
        view 
        returns (
            string memory name,
            string memory description,
            string[] memory standardBodies,
            string[] memory metricUnits,
            string memory verificationStandard,
            uint8 impactWeight
        ) 
    {
        CategoryInfo storage info = categoryInfo[category];
        return (
            info.name,
            info.description,
            info.standardBodies,
            info.metricUnits,
            info.verificationStandard,
            info.impactWeight
        );
    }
    
    function getProjectVerificationDetails(uint256 projectId) 
        external 
        view 
        returns (
            bool isVerified,
            address verifier,
            uint256 verificationDate,
            string memory verificationStandard,
            bytes32 verificationDocumentHash
        ) 
    {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        ProjectVerification storage verification = projectVerifications[projectId];
        
        return (
            verification.verificationDate > 0,
            verification.verifier,
            verification.verificationDate,
            verification.verificationStandard,
            verification.verificationDocumentHash
        );
    }

    // ====================================================
    // 🔹 Emergency & Admin Functions
    // ====================================================
    
    function toggleEmergencyMode() external onlyRole(GOVERNANCE_ROLE) {
        emergencyMode = !emergencyMode;
        if (emergencyMode) {
            _pause();
        } else {
            _unpause();
        }
        
        emit EmergencyModeToggled(emergencyMode);
    }
    
    function recoverERC20(address tokenAddress, uint256 amount) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
        nonReentrant 
    {
        if (tokenAddress == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();
        
        // Prevent recovery of staked tokens unless in emergency
        if (tokenAddress == terraTokenAddress && !emergencyMode) {
            uint256 safeTotalStaked = 0;
            for (uint256 i = 0; i < projectCount; i++) {
                safeTotalStaked += projectStateData[i].totalStaked;
            }
            
            uint256 balance = IERC20(tokenAddress).balanceOf(address(this));
            uint256 recoverableAmount = balance - safeTotalStaked;
            
            if (amount > recoverableAmount) revert ExceedsRecoverableAmount();
        }
        
        IERC20 token = IERC20(tokenAddress);
        bool success = token.transfer(treasuryAddress, amount);
        if (!success) revert TokenTransferFailed();
        
        emit TokensRecovered(tokenAddress, treasuryAddress, amount);
    }
    
    function setTerraToken(address _tokenAddress) external onlyRole(GOVERNANCE_ROLE) {
        if (_tokenAddress == address(0)) revert InvalidAddress();
        terraTokenAddress = _tokenAddress;
        emit TerraTokenSet(_tokenAddress);
    }
    
    function setTreasuryAddress(address _treasuryAddress) external onlyRole(GOVERNANCE_ROLE) {
        if (_treasuryAddress == address(0)) revert InvalidAddress();
        treasuryAddress = _treasuryAddress;
        emit TreasuryAddressSet(_treasuryAddress);
    }
    
    // ====================================================
    // 🔹 Verification Functions
    // ====================================================
    
    function verifyProject(
        uint256 projectId,
        string calldata standard,
        bytes32 documentHash
    ) external onlyRole(VERIFIER_ROLE) nonReentrant whenNotPaused {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        // Create verification record
        projectVerifications[projectId] = ProjectVerification({
            verifier: msg.sender,
            verificationDate: block.timestamp,
            verificationStandard: standard,
            verificationDocumentHash: documentHash
        });
        
        // Update project state if it's in the proposed state
        if (projectStateData[projectId].state == ProjectState.Proposed) {
            projectStateData[projectId].state = ProjectState.Verified;
        }
        
        emit ProjectVerified(projectId, msg.sender, standard, documentHash);
    }
    
    // ====================================================
    // 🔹 Interface & Standards Support
    // ====================================================
    
    function supportsInterface(bytes4 interfaceId) 
        public 
        view 
        override(AccessControl, ERC165) 
        returns (bool) 
    {
        return
            interfaceId == type(ITerraStake).interfaceId ||
            interfaceId == type(ITerraStakeProjects).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
