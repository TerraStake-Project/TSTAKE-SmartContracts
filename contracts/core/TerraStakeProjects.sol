// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Burnable} from "./interfaces/IERC20Burnable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ITerraStakeProjects} from "../interfaces/ITerraStakeProjects.sol";
import {ITerraStakeMarketPlace} from "../interfaces/ITerraStakeMarketPlace.sol";

/**
 * @title TerraStakeProjects 
 * @notice Manages projects, staking, impact tracking, governance-driven fees, and NFT integration.
 */
contract TerraStakeProjects is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, ITerraStakeProjects {
    // ====================================================
    // 🔑 Roles
    // ====================================================
    bytes32 public constant PROJECT_MANAGER_ROLE = keccak256("PROJECT_MANAGER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant STAKER_ROLE = keccak256("STAKER_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");

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

    // ====================================================
    // 🚀 Initialization
    // ====================================================
    function initialize(
        address admin, 
        address _tstakeToken
    ) external override initializer {
        if (admin == address(0) || _tstakeToken == address(0)) revert("Invalid addresses");

        __AccessControl_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PROJECT_MANAGER_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(STAKER_ROLE, admin);
        _grantRole(VALIDATOR_ROLE, admin);
        _grantRole(VERIFIER_ROLE, admin);

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
        if (_nftContract == address(0)) revert("Invalid address");
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
    
    function mintImpactNFT(uint256 projectId, bytes32 reportHash, address recipient) external {
        // Only validators, verifiers, or governance can mint NFTs
        if (!hasRole(VALIDATOR_ROLE, msg.sender) && 
            !hasRole(VERIFIER_ROLE, msg.sender) && 
            !hasRole(GOVERNANCE_ROLE, msg.sender)) {
            revert("Not authorized");
        }
        
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        if (nftContract == address(0)) revert("NFT contract not set");
        
        // Ensure project is active and verified
        if (projectStateData[projectId].state != ProjectState.Active) revert("Project not active");
        if (projectVerifications[projectId].verificationDate == 0) revert("Project not verified");
        
        // Get project category and metadata for the NFT
        ProjectCategory category = projectStateData[projectId].category;
        string memory projectName = projectMetadata[projectId].name;
        
        // Create NFT metadata
        string memory tokenURI = _generateTokenURI(projectId, category, projectName, reportHash);
        
        // Call the NFT contract to mint the token
        (bool success, ) = nftContract.call(
            abi.encodeWithSignature(
                "mintImpactNFT(address,uint256,string,bytes32)", 
                recipient, 
                projectId, 
                tokenURI, 
                reportHash
            )
        );
        require(success, "NFT minting failed");
        
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
    ) external override nonReentrant onlyRole(PROJECT_MANAGER_ROLE) {
        if (bytes(name).length == 0) revert("Name required");

        // Fee Collection (50% Burn, 45% Treasury, 5% Buyback)
        if (!tStakeToken.transferFrom(msg.sender, address(this), fees.projectSubmissionFee)) 
            revert("Fee transfer failed");
            
        uint256 treasuryAmount = (fees.projectSubmissionFee * 45) / 100;
        uint256 buybackAmount = (fees.projectSubmissionFee * 5) / 100;

        tStakeToken.transfer(treasury, treasuryAmount);
        _executeBuyback(buybackAmount);

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

        emit ProjectAdded(newProjectId, name, category);
    }

    function updateProjectState(uint256 projectId, ProjectState newState) 
        external 
        override 
        nonReentrant 
        onlyRole(GOVERNANCE_ROLE) 
    {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        
        ProjectState oldState = projectStateData[projectId].state;
        if (oldState == newState) revert("State unchanged");
        
        projectStateData[projectId].state = newState;
        
        // Update isActive flag based on state
        if (newState == ProjectState.Active) {
            projectStateData[projectId].isActive = true;
        } else if (newState == ProjectState.Suspended || 
                 newState == ProjectState.Completed || 
                 newState == ProjectState.Archived) {
            projectStateData[projectId].isActive = false;
        }
        
        emit ProjectStateChanged(projectId, oldState, newState);
    }

    // Enhanced document upload with pagination
    function uploadProjectDocuments(uint256 projectId, string[] calldata ipfsHashes) 
        external 
        override 
        nonReentrant
    {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        if (!hasProjectPermission(projectId, msg.sender, UPLOAD_DOCS_PERMISSION))
            revert("Not authorized");
            
        uint256 currentPage = projectDocumentPageCount[projectId];
        if (currentPage == 0 || projectDocumentPages[projectId][currentPage - 1].length + ipfsHashes.length > DOCUMENTS_PER_PAGE) {
            // Create a new page if needed
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
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        if (page >= projectDocumentPageCount[projectId]) revert("Page does not exist");
        
        return projectDocumentPages[projectId][page];
    }
    
    // Get total number of document pages
    function getProjectDocumentPageCount(uint256 projectId) 
        external 
        view 
        returns (uint256) 
    {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        return projectDocumentPageCount[projectId];
    }

    function submitImpactReport(
        uint256 projectId,
        uint256 periodStart,
        uint256 periodEnd,
        uint256[] memory metrics,
        bytes32 reportHash
    ) external override nonReentrant {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        
        // Check permissions for impact reporting
        if (!hasProjectPermission(projectId, msg.sender, SUBMIT_REPORTS_PERMISSION) && 
            !hasRole(STAKER_ROLE, msg.sender)) {
            revert("Not authorized");
        }

        // Fee Collection (50% Burn, 45% Treasury, 5% Buyback)
        if (!tStakeToken.transferFrom(msg.sender, address(this), fees.impactReportingFee))
            revert("Fee transfer failed");
            
        uint256 treasuryAmount = (fees.impactReportingFee * 45) / 100;
        uint256 buybackAmount = (fees.impactReportingFee * 5) / 100;

        tStakeToken.transfer(treasury, treasuryAmount);
        _executeBuyback(buybackAmount);

        // Add the impact report
        projectImpactReports[projectId].push(ImpactReport(periodStart, periodEnd, metrics, reportHash));
        
        // Update analytics with the reported impact
        uint256 totalImpact = 0;
        for (uint256 i = 0; i < metrics.length; i++) {
            totalImpact += metrics[i];
        }
        
        projectAnalytics[projectId].totalImpact += totalImpact;
        
        emit ImpactReportSubmitted(projectId, reportHash);
    }
    
    // ====================================================
    // 🔹 Enhanced Comment Management
    // ====================================================
    
    // Add comment with pagination for gas efficiency
    function addComment(uint256 projectId, string calldata message) 
        external 
        override 
        nonReentrant 
    {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        
        uint256 currentPage = projectCommentsPageCount[projectId];
        if (currentPage == 0 || projectCommentsPages[projectId][currentPage - 1].length >= COMMENTS_PER_PAGE) {
            // Create a new page
            projectCommentsPageCount[projectId]++;
            currentPage = projectCommentsPageCount[projectId];
        }
        
        projectCommentsPages[projectId][currentPage - 1].push(Comment({
            commenter: msg.sender,
            message: message,
            timestamp: block.timestamp
        }));
        
        emit CommentAdded(projectId, msg.sender, message);
    }
    
    // Get comments with pagination
    function getProjectComments(uint256 projectId, uint256 page) 
        external 
        view 
        returns (Comment[] memory) 
    {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        if (page >= projectCommentsPageCount[projectId]) revert("Page does not exist");
        
        return projectCommentsPages[projectId][page];
    }
    
    // Get total number of comment pages
    function getProjectCommentPageCount(uint256 projectId) 
        external 
        view 
        returns (uint256) 
    {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        return projectCommentsPageCount[projectId];
    }

    // ====================================================
    // 🔹 Governance Functions
    // ====================================================
    function submitValidation(uint256 projectId, bytes32 reportHash) 
        external 
        override 
        nonReentrant 
        onlyRole(VALIDATOR_ROLE) 
    {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        
        projectValidations[projectId] = ValidationData({
            validator: msg.sender,
            validationDate: block.timestamp,
            validationReportHash: reportHash
        });
        
        // Move from Proposed to UnderReview if in Proposed state
        if (projectStateData[projectId].state == ProjectState.Proposed) {
            ProjectState oldState = projectStateData[projectId].state;
            projectStateData[projectId].state = ProjectState.UnderReview;
            emit ProjectStateChanged(projectId, oldState, ProjectState.UnderReview);
        }
        
        emit ValidationSubmitted(projectId, msg.sender, reportHash);
    }
    
    function submitVerification(uint256 projectId, bytes32 reportHash) 
        external 
        override 
        nonReentrant 
        onlyRole(VERIFIER_ROLE) 
    {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        
        projectVerifications[projectId] = VerificationData({
            verifier: msg.sender,
            verificationDate: block.timestamp,
            verificationReportHash: reportHash
        });
        
        // Move to Active state after verification
        ProjectState oldState = projectStateData[projectId].state;
        projectStateData[projectId].state = ProjectState.Active;
        projectStateData[projectId].isActive = true;
        
        emit ProjectStateChanged(projectId, oldState, ProjectState.Active);
        emit VerificationSubmitted(projectId, msg.sender, reportHash);
    }
    
    function updateFeeStructure(
        uint256 projectSubmissionFee,
        uint256 impactReportingFee,
        uint256 verificationFee,
        uint256 categoryChangeFee
    ) external onlyRole(GOVERNANCE_ROLE) {
        fees = FeeStructure({
            projectSubmissionFee: projectSubmissionFee,
            impactReportingFee: impactReportingFee,
            verificationFee: verificationFee,
            categoryChangeFee: categoryChangeFee
        });
        
        emit FeeStructureUpdated(
            projectSubmissionFee,
            impactReportingFee,
            verificationFee,
            categoryChangeFee
        );
    }
    
    function updateCategoryRequirements(
        ProjectCategory category,
        uint256 minImpact,
        uint256 minReportFrequency,
        uint256 minStakingPeriod,
        uint256 minValidations
    ) external onlyRole(GOVERNANCE_ROLE) {
        categoryRequirements[category] = ImpactRequirement({
            minimumImpactValue: minImpact,
            minimumReportingFrequency: minReportFrequency,
            minimumStakingPeriod: minStakingPeriod,
            minimumValidations: minValidations
        });
        
        emit CategoryRequirementsUpdated(
            category,
            minImpact,
            minReportFrequency,
            minStakingPeriod,
            minValidations
        );
    }
    
    function setTreasuryAddress(address _treasury) external onlyRole(GOVERNANCE_ROLE) {
        require(_treasury != address(0), "Invalid treasury address");
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }
    
    function setLiquidityPoolAddress(address _liquidityPool) external onlyRole(GOVERNANCE_ROLE) {
        require(_liquidityPool != address(0), "Invalid liquidity pool address");
        liquidityPool = _liquidityPool;
        emit LiquidityPoolUpdated(_liquidityPool);
    }
    
    function setStakingContract(address _stakingContract) external onlyRole(GOVERNANCE_ROLE) {
        require(_stakingContract != address(0), "Invalid staking contract address");
        stakingContract = _stakingContract;
        emit StakingContractUpdated(_stakingContract);
    }
    
    function setRewardsContract(address _rewardsContract) external onlyRole(GOVERNANCE_ROLE) {
        require(_rewardsContract != address(0), "Invalid rewards contract address");
        rewardsContract = _rewardsContract;
        emit RewardsContractUpdated(_rewardsContract);
    }

    // ====================================================
    // 🔹 Project Collaboration & Permission Management
    // ====================================================
    function grantProjectPermission(
        uint256 projectId, 
        address user, 
        bytes32 permission
    ) external nonReentrant {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        
        // Only the project owner or someone with manage collaborators permission can grant permissions
        if (projectStateData[projectId].owner != msg.sender && 
            !projectPermissions[projectId][msg.sender][MANAGE_COLLABORATORS_PERMISSION]) {
            revert("Not authorized");
        }
        
        projectPermissions[projectId][user][permission] = true;
        emit ProjectPermissionUpdated(projectId, user, permission, true);
    }
    
    function revokeProjectPermission(
        uint256 projectId, 
        address user, 
        bytes32 permission
    ) external nonReentrant {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        
        // Only the project owner or someone with manage collaborators permission can revoke permissions
        if (projectStateData[projectId].owner != msg.sender && 
            !projectPermissions[projectId][msg.sender][MANAGE_COLLABORATORS_PERMISSION]) {
            revert("Not authorized");
        }
        
        // Cannot revoke owner's permissions
        if (projectStateData[projectId].owner == user) {
            revert("Cannot revoke owner permissions");
        }
        
        projectPermissions[projectId][user][permission] = false;
        emit ProjectPermissionUpdated(projectId, user, permission, false);
    }
    
    function hasProjectPermission(
        uint256 projectId, 
        address user, 
        bytes32 permission
    ) public view returns (bool) {
        // Project owner always has all permissions
        return projectStateData[projectId].owner == user || 
               projectPermissions[projectId][user][permission];
    }
    
    function transferProjectOwnership(uint256 projectId, address newOwner) external nonReentrant {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        if (projectStateData[projectId].owner != msg.sender) revert("Not project owner");
        if (newOwner == address(0)) revert("Invalid new owner");
        
        // Transfer ownership
        address oldOwner = projectStateData[projectId].owner;
        projectStateData[projectId].owner = newOwner;
        
        // Grant all permissions to new owner
        projectPermissions[projectId][newOwner][EDIT_METADATA_PERMISSION] = true;
        projectPermissions[projectId][newOwner][UPLOAD_DOCS_PERMISSION] = true;
        projectPermissions[projectId][newOwner][SUBMIT_REPORTS_PERMISSION] = true;
        projectPermissions[projectId][newOwner][MANAGE_COLLABORATORS_PERMISSION] = true;
        
        emit ProjectOwnershipTransferred(projectId, oldOwner, newOwner);
    }

    // ====================================================
    // 🔹 REC (Renewable Energy Certificate) Management
    // ====================================================
    function registerREC(
        uint256 projectId, 
        uint256 energyAmount, 
        uint256 issuanceDate, 
        string calldata source, 
        bytes32 recId
    ) external onlyRole(VERIFIER_ROLE) {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        if (projectStateData[projectId].category != ProjectCategory.RenewableEnergy) 
            revert("Project not in renewable energy category");
        
        projectRECs[projectId].push(RECData({
            recId: recId,
            energyAmount: energyAmount,
            issuanceDate: issuanceDate,
            expirationDate: issuanceDate + 365 days,
            source: source,
            status: RECStatus.Active,
            owner: projectStateData[projectId].owner,
            retirementReason: "",
            externalRegistryId: ""
        }));
        
        emit RECRegistered(projectId, recId, energyAmount);
    }
    
    function retireREC(uint256 projectId, bytes32 recId, string calldata purpose) external {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        
        // Find and update the REC
        bool found = false;
        for (uint256 i = 0; i < projectRECs[projectId].length; i++) {
            if (projectRECs[projectId][i].recId == recId) {
                // Only the REC owner can retire it
                if (projectRECs[projectId][i].owner != msg.sender) revert("Not REC owner");
                if (projectRECs[projectId][i].status != RECStatus.Active) revert("REC not active");
                
                projectRECs[projectId][i].status = RECStatus.Retired;
                projectRECs[projectId][i].retirementReason = purpose;
                found = true;
                
                emit RECRetired(projectId, recId, msg.sender, purpose);
                break;
            }
        }
        
        if (!found) revert("REC not found");
    }
    
    function transferREC(uint256 projectId, bytes32 recId, address to) external {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        if (to == address(0)) revert("Invalid recipient");
        
        // Find and update the REC
        bool found = false;
        for (uint256 i = 0; i < projectRECs[projectId].length; i++) {
            if (projectRECs[projectId][i].recId == recId) {
                // Only the REC owner can transfer it
                if (projectRECs[projectId][i].owner != msg.sender) revert("Not REC owner");
                if (projectRECs[projectId][i].status != RECStatus.Active) revert("REC not active");
                
                projectRECs[projectId][i].owner = to;
                found = true;
                
                emit RECTransferred(projectId, recId, msg.sender, to);
                break;
            }
        }
        
        if (!found) revert("REC not found");
    }
    
    function setRECExternalRegistry(uint256 projectId, bytes32 recId, string calldata externalId) 
        external 
        onlyRole(VERIFIER_ROLE) 
    {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        
        // Find and update the REC
        bool found = false;
        for (uint256 i = 0; i < projectRECs[projectId].length; i++) {
            if (projectRECs[projectId][i].recId == recId) {
                projectRECs[projectId][i].externalRegistryId = externalId;
                found = true;
                
                emit RECRegistrySync(projectId, recId, externalId);
                break;
            }
        }
        
        if (!found) revert("REC not found");
    }
    
    function getProjectRECs(uint256 projectId) external view returns (RECData[] memory) {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        return projectRECs[projectId];
    }
    
    // ====================================================
    // 🔹 Project Data Management
    // ====================================================
    function updateProjectMetadata(
        uint256 projectId,
        string calldata name,
        string calldata description,
        string calldata location,
        string calldata impactMetrics,
        bytes32 ipfsHash
    ) external {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        
        // Check edit permissions
        if (!hasProjectPermission(projectId, msg.sender, EDIT_METADATA_PERMISSION)) {
            revert("Not authorized");
        }
        
        // Update the metadata
        if (bytes(name).length > 0) projectMetadata[projectId].name = name;
        if (bytes(description).length > 0) projectMetadata[projectId].description = description;
        if (bytes(location).length > 0) projectMetadata[projectId].location = location;
        if (bytes(impactMetrics).length > 0) projectMetadata[projectId].impactMetrics = impactMetrics;
        if (ipfsHash != bytes32(0)) projectMetadata[projectId].ipfsHash = ipfsHash;
        
        emit ProjectMetadataUpdated(projectId, projectMetadata[projectId].name);
    }
    
    function setProjectImpactRequirements(
        uint256 projectId,
        uint256 minImpact,
        uint256 minReportFrequency,
        uint256 minStakingPeriod,
        uint256 minValidations
    ) external onlyRole(GOVERNANCE_ROLE) {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        
        projectImpactRequirements[projectId] = ImpactRequirement({
            minimumImpactValue: minImpact,
            minimumReportingFrequency: minReportFrequency,
            minimumStakingPeriod: minStakingPeriod,
            minimumValidations: minValidations
        });
        
        emit ProjectImpactRequirementsUpdated(
            projectId,
            minImpact,
            minReportFrequency,
            minStakingPeriod,
            minValidations
        );
    }
    
    function changeProjectCategory(uint256 projectId, ProjectCategory newCategory) 
        external 
        nonReentrant 
    {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        
        // Only governance or project owner can change category
        if (!hasRole(GOVERNANCE_ROLE, msg.sender) && 
            projectStateData[projectId].owner != msg.sender) {
            revert("Not authorized");
        }
        
        // Collect category change fee if sender is not governance
        if (!hasRole(GOVERNANCE_ROLE, msg.sender)) {
            if (!tStakeToken.transferFrom(msg.sender, address(this), fees.categoryChangeFee))
                revert("Fee transfer failed");
                
            uint256 treasuryAmount = (fees.categoryChangeFee * 45) / 100;
            uint256 buybackAmount = (fees.categoryChangeFee * 5) / 100;
    
            tStakeToken.transfer(treasury, treasuryAmount);
            _executeBuyback(buybackAmount);
        }
        
        ProjectCategory oldCategory = projectStateData[projectId].category;
        projectStateData[projectId].category = newCategory;
        
        // Update the project's impact requirements to match the new category
        projectImpactRequirements[projectId] = categoryRequirements[newCategory];
        
        emit ProjectCategoryChanged(projectId, oldCategory, newCategory);
    }
    
    // ====================================================
    // 🔹 Utility Functions
    // ====================================================
    function _executeBuyback(uint256 amount) internal {
        if (amount == 0) return;
        
        // Burn 50% of tokens by sending to dead address
        uint256 burnAmount = amount / 2;
        if (burnAmount > 0) {
            // Instead of trying to call a burn method, transfer to burn address
            tStakeToken.transfer(BURN_ADDRESS, burnAmount);
            emit TokensBurned(burnAmount);
        }
        
        // Send remaining to liquidity pool for buyback
        uint256
 remainingAmount = amount - burnAmount;
        if (remainingAmount > 0 && liquidityPool != address(0)) {
            // Transfer tokens to liquidity pool for buyback
            tStakeToken.transfer(liquidityPool, remainingAmount);
        }
    }
    
    function getProject(uint256 projectId) 
        external 
        view 
        returns (
            ProjectData memory metadata,
            ProjectStateData memory stateData,
            ValidationData memory validation,
            VerificationData memory verification,
            ProjectAnalytics memory analytics
        ) 
    {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        
        return (
            projectMetadata[projectId],
            projectStateData[projectId],
            projectValidations[projectId],
            projectVerifications[projectId],
            projectAnalytics[projectId]
        );
    }
    
    function getProjectCount() external view returns (uint256) {
        return projectCount;
    }
    
    function getProjectImpactReports(uint256 projectId) 
        external 
        view 
        returns (ImpactReport[] memory) 
    {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        return projectImpactReports[projectId];
    }
    
    function getCategoryInfo(ProjectCategory category) 
        external 
        view 
        returns (CategoryInfo memory) 
    {
        return categoryInfo[category];
    }
    
    function getProjectsByOwner(address owner) 
        external 
        view 
        returns (uint256[] memory) 
    {
        uint256[] memory ownedProjects = new uint256[](projectCount);
        uint256 count = 0;
        
        for (uint256 i = 0; i < projectCount; i++) {
            if (projectStateData[i].owner == owner && projectMetadata[i].exists) {
                ownedProjects[count] = i;
                count++;
            }
        }
        
        // Resize array to actual count
        uint256[] memory result = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = ownedProjects[i];
        }
        
        return result;
    }
    
    function getProjectsByCategory(ProjectCategory category) 
        external 
        view 
        returns (uint256[] memory) 
    {
        uint256[] memory categoryProjects = new uint256[](projectCount);
        uint256 count = 0;
        
        for (uint256 i = 0; i < projectCount; i++) {
            if (projectStateData[i].category == category && projectMetadata[i].exists) {
                categoryProjects[count] = i;
                count++;
            }
        }
        
        // Resize array to actual count
        uint256[] memory result = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = categoryProjects[i];
        }
        
        return result;
    }
    
    function getActiveProjects() 
        external 
        view 
        returns (uint256[] memory) 
    {
        uint256[] memory activeProjects = new uint256[](projectCount);
        uint256 count = 0;
        
        for (uint256 i = 0; i < projectCount; i++) {
            if (projectStateData[i].isActive && projectMetadata[i].exists) {
                activeProjects[count] = i;
                count++;
            }
        }
        
        // Resize array to actual count
        uint256[] memory result = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = activeProjects[i];
        }
        
        return result;
    }
    
    // Allows staking contract to update project staking data
    function updateProjectStaking(uint256 projectId, uint256 newTotalStaked, uint256 newRewardPool) 
        external 
    {
        if (msg.sender != stakingContract && !hasRole(GOVERNANCE_ROLE, msg.sender)) 
            revert("Not authorized");
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        
        projectStateData[projectId].totalStaked = newTotalStaked;
        projectStateData[projectId].rewardPool = newRewardPool;
        
        emit ProjectStakingUpdated(projectId, newTotalStaked, newRewardPool);
    }
    
    // Emergency function to recover tokens accidentally sent to contract
    function recoverERC20(address tokenAddress, uint256 amount) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        IERC20(tokenAddress).transfer(msg.sender, amount);
        emit TokenRecovered(tokenAddress, msg.sender, amount);
    }
}
