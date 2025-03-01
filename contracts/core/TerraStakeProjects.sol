// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITerraStakeProjects} from "../interfaces/ITerraStakeProjects.sol";

/**
 * @title TerraStakeProjects 
 * @notice Manages projects, staking, impact tracking, and governance-driven fees.
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
        projectPermissions[newProjectId][msg.sender][
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
        
        // Require payment of verification fee
        if (!tStakeToken.transferFrom(msg.sender, address(this), fees.verificationFee))
            revert("Fee transfer failed");
            
        uint256 treasuryAmount = (fees.verificationFee * 70) / 100;
        uint256 buybackAmount = (fees.verificationFee * 30) / 100;

        tStakeToken.transfer(treasury, treasuryAmount);
        _executeBuyback(buybackAmount);
        
        projectVerifications[projectId] = VerificationData({
            verifier: msg.sender,
            verificationDate: block.timestamp,
            verificationReportHash: reportHash
        });
        
        emit VerificationSubmitted(projectId, msg.sender, reportHash);
    }
    
    function reportMetric(uint256 projectId, string calldata metricType, string calldata metricValue) 
        external 
        override 
        nonReentrant
    {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        
        // Check permissions for metrics reporting
        if (!hasProjectPermission(projectId, msg.sender, SUBMIT_REPORTS_PERMISSION) && 
            !hasRole(STAKER_ROLE, msg.sender)) {
            revert("Not authorized");
        }
        
        emit MetricsReported(projectId, metricType, metricValue);
    }
    
    function setCategoryMultiplier(ProjectCategory category, uint256 multiplier) 
        external 
        override 
        onlyRole(GOVERNANCE_ROLE) 
    {
        categoryInfo[category].impactWeight = multiplier;
        
        emit CategoryMultiplierUpdated(category, multiplier);
    }
    
    function setImpactRequirement(
        ProjectCategory category,
        uint256 minimumImpact,
        uint256 verificationFrequency,
        string[] calldata requiredDocuments,
        uint256 qualityThreshold,
        uint256 minimumScale
    ) external override onlyRole(GOVERNANCE_ROLE) {
        ImpactRequirement memory requirement = ImpactRequirement({
            minimumImpact: minimumImpact,
            verificationFrequency: verificationFrequency,
            requiredDocuments: requiredDocuments,
            qualityThreshold: qualityThreshold,
            minimumScale: minimumScale
        });
        
        categoryRequirements[category] = requirement;
        
        emit ImpactRequirementUpdated(category, minimumImpact);
    }
    
    function updateFeeStructure(
        uint256 projectSubmissionFee, 
        uint256 categoryChangeFee, 
        uint256 impactReportingFee, 
        uint256 verificationFee
    ) external override onlyRole(GOVERNANCE_ROLE) {
        fees = FeeStructure({
            projectSubmissionFee: projectSubmissionFee,
            impactReportingFee: impactReportingFee,
            categoryChangeFee: categoryChangeFee,
            verificationFee: verificationFee
        });
        
        emit FeeStructureUpdated(
            projectSubmissionFee, 
            impactReportingFee, 
            verificationFee, 
            categoryChangeFee
        );
    }

    // ====================================================
    // 🔹 Project Analytics & Reporting
    // ====================================================
    function updateProjectDataFromChainlink(uint256 projectId, int256 price) external {
        // This function would typically be called by an oracle contract
        // For demonstration, we'll allow governance role to update
        if (!hasRole(GOVERNANCE_ROLE, msg.sender)) revert("Not authorized");
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        
        projectStateData[projectId].lastReportedValue = price;
        
        emit ProjectDataUpdated(projectId, price);
    }
    
    function updateProjectAnalytics(
        uint256 projectId,
        uint256 totalImpact,
        uint256 carbonOffset,
        uint256 stakingEfficiency,
        uint256 communityEngagement
    ) external override onlyRole(GOVERNANCE_ROLE) {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        
        projectAnalytics[projectId] = ProjectAnalytics({
            totalImpact: totalImpact,
            carbonOffset: carbonOffset,
            stakingEfficiency: stakingEfficiency,
            communityEngagement: communityEngagement
        });
        
        emit AnalyticsUpdated(projectId, totalImpact);
    }
    
    function getProjectAnalytics(uint256 projectId) 
        external 
        view 
        override 
        returns (ProjectAnalytics memory) 
    {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        return projectAnalytics[projectId];
    }
    
    function getImpactReports(uint256 projectId) 
        external 
        view 
        override 
        returns (ImpactReport[] memory) 
    {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        return projectImpactReports[projectId];
    }

    // ====================================================
    // 🔹 Enhanced REC Management
    // ====================================================
    function submitRECReport(uint256 projectId, RECData memory rec) 
        external 
        override 
        nonReentrant 
    {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        if (projectStateData[projectId].category != ProjectCategory.RenewableEnergy)
            revert("Project not renewable energy");
            
        // Check permissions for REC reporting
        if (!hasProjectPermission(projectId, msg.sender, SUBMIT_REPORTS_PERMISSION) && 
            !hasRole(STAKER_ROLE, msg.sender)) {
            revert("Not authorized");
        }
            
        projectRECs[projectId].push(rec);
        
        emit RECReportSubmitted(projectId, rec.recId);
    }
    
    function verifyRECOnchain(uint256 projectId, bytes32 recId) 
        external 
        onlyRole(VERIFIER_ROLE) 
    {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        
        bool found = false;
        RECData[] storage recs = projectRECs[projectId];
        
        for (uint256 j = 0; j < recs.length; j++) {
            if (recs[j].recId == recId) {
                recs[j].isVerified = true;
                recs[j].verificationDate = block.timestamp;
                recs[j].verifier = msg.sender;
                found = true;
                break;
            }
        }
require(found, "REC not found");
        emit RECVerified(projectId, recId, msg.sender);
    }

    function retireREC(uint256 projectId, bytes32 recId, string calldata purpose) 
        external 
        nonReentrant 
    {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        
        bool found = false;
        RECData[] storage recs = projectRECs[projectId];
        
        for (uint256 j = 0; j < recs.length; j++) {
            if (recs[j].recId == recId && !recs[j].isRetired) {
                // Ensure it's verified before retiring
                require(recs[j].isVerified, "REC not verified");
                
                recs[j].isRetired = true;
                recs[j].retirementDate = block.timestamp;
                recs[j].retirer = msg.sender;
                recs[j].retirementPurpose = purpose;
                found = true;
                break;
            }
        }
        
        require(found, "REC not found or already retired");
        emit RECRetired(projectId, recId, msg.sender, purpose);
    }

    function transferREC(uint256 projectId, bytes32 recId, address to)
        external
        nonReentrant
    {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        if (to == address(0)) revert("Invalid recipient");
        
        bool found = false;
        RECData[] storage recs = projectRECs[projectId];
        
        for (uint256 j = 0; j < recs.length; j++) {
            if (recs[j].recId == recId) {
                // Only owner can transfer
                require(recs[j].owner == msg.sender, "Not the REC owner");
                // Cannot transfer retired RECs
                require(!recs[j].isRetired, "REC already retired");
                
                address from = recs[j].owner;
                recs[j].owner = to;
                found = true;
                
                emit RECTransferred(projectId, recId, from, to);
                break;
            }
        }
        
        require(found, "REC not found");
    }

    function syncRECWithExternalRegistry(uint256 projectId, bytes32 recId, string calldata externalId)
        external
        onlyRole(VALIDATOR_ROLE)
    {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        
        bool found = false;
        RECData[] storage recs = projectRECs[projectId];
        
        for (uint256 j = 0; j < recs.length; j++) {
            if (recs[j].recId == recId) {
                recs[j].externalRegistryId = externalId;
                found = true;
                break;
            }
        }
        
        require(found, "REC not found");
        emit RECRegistrySync(projectId, recId, externalId);
    }
    
    function getREC(uint256 projectId) 
        external 
        view 
        override 
        returns (RECData memory) 
    {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        if (projectRECs[projectId].length == 0) revert("No RECs for project");
        
        // Return the most recent REC
        return projectRECs[projectId][projectRECs[projectId].length - 1];
    }
    
    function getAllRECs(uint256 projectId)
        external
        view
        returns (RECData[] memory)
    {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        return projectRECs[projectId];
    }
    
    function verifyREC(bytes32 recId) 
        external 
        view 
        override 
        returns (bool) 
    {
        // In a real implementation, this would verify the REC against an external registry
        // For demonstration, we'll just check if it exists in any project
        for (uint256 i = 0; i < projectCount; i++) {
            RECData[] storage recs = projectRECs[i];
            for (uint256 j = 0; j < recs.length; j++) {
                if (recs[j].recId == recId && recs[j].isVerified && !recs[j].isRetired) {
                    return true;
                }
            }
        }
        
        return false;
    }
    
    // ====================================================
    // 🔹 Enhanced Permission Management
    // ====================================================
    function setProjectPermission(
        uint256 projectId, 
        address user, 
        bytes32 permission, 
        bool granted
    ) external {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        
        // Only the project owner or governance/admin can change permissions
        if (projectStateData[projectId].owner != msg.sender && 
            !hasRole(GOVERNANCE_ROLE, msg.sender) && 
            !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert("Not authorized");
        }
        
        // Users can't modify their own collaborator management permissions
        if (user == msg.sender && permission == MANAGE_COLLABORATORS_PERMISSION && !granted) {
            revert("Cannot revoke own management");
        }
        
        projectPermissions[projectId][user][permission] = granted;
        emit ProjectPermissionUpdated(projectId, user, permission, granted);
    }
    
    // Helper function to check project-specific permissions
    function hasProjectPermission(uint256 projectId, address user, bytes32 permission) 
        public 
        view 
        returns (bool) 
    {
        // Project owner, governance, and admin always have permissions
        if (projectStateData[projectId].owner == user || 
            hasRole(GOVERNANCE_ROLE, user) || 
            hasRole(DEFAULT_ADMIN_ROLE, user)) {
            return true;
        }
        
        return projectPermissions[projectId][user][permission];
    }
    
    // Check multiple permissions at once for a user on a project
    function checkProjectPermissions(uint256 projectId, address user, bytes32[] calldata permissions)
        external
        view
        returns (bool[] memory)
    {
        bool[] memory results = new bool[](permissions.length);
        
        for (uint256 i = 0; i < permissions.length; i++) {
            results[i] = hasProjectPermission(projectId, user, permissions[i]);
        }
        
        return results;
    }
    
    // Update project metadata with permission checks
    function updateProjectMetadata(
        uint256 projectId,
        string memory name,
        string memory description,
        string memory location,
        string memory impactMetrics
    ) external {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        
        // Check if user has metadata edit permission
        if (!hasProjectPermission(projectId, msg.sender, EDIT_METADATA_PERMISSION)) {
            revert("Not authorized to edit metadata");
        }
        
        projectMetadata[projectId].name = name;
        projectMetadata[projectId].description = description;
        projectMetadata[projectId].location = location;
        projectMetadata[projectId].impactMetrics = impactMetrics;
        
        emit ProjectMetadataUpdated(projectId, name);
    }

    // ====================================================
    // 🔹 Contract Management
    // ====================================================
    function setContracts(address _stakingContract, address _rewardsContract) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        if (_stakingContract == address(0) || _rewardsContract == address(0))
            revert("Invalid addresses");
            
        stakingContract = _stakingContract;
        rewardsContract = _rewardsContract;
        
        emit ContractsSet(_stakingContract, _rewardsContract);
    }
    
    function setTreasury(address _treasury) external onlyRole(GOVERNANCE_ROLE) {
        if (_treasury == address(0)) revert("Invalid address");
        treasury = _treasury;
    }
    
    function setLiquidityPool(address _liquidityPool) external onlyRole(GOVERNANCE_ROLE) {
        if (_liquidityPool == address(0)) revert("Invalid address");
        liquidityPool = _liquidityPool;
    }
    
    // ====================================================
    // 🔹 Internal Fee Management
    // ====================================================
    function _executeBuyback(uint256 amount) private {
        if (amount > 0 && liquidityPool != address(0)) {
            tStakeToken.transfer(liquidityPool, amount);
        }
    }
    
    // ====================================================
    // 🔹 Category-Specific Utilities
    // ====================================================
    function getCategoryRequirements(ProjectCategory category)
        external
        view
        returns (ImpactRequirement memory)
    {
        return categoryRequirements[category];
    }
    
    function getCategoryInfo(ProjectCategory category)
        external
        view
        returns (CategoryInfo memory)
    {
        return categoryInfo[category];
    }
    
    function calculateCategoryImpact(uint256 projectId, uint256 baseImpact)
        external
        view
        returns (uint256)
    {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        
        ProjectCategory category = projectStateData[projectId].category;
        uint256 weight = categoryInfo[category].impactWeight;
        
        return (baseImpact * weight) / 100;
    }
    
    // ====================================================
    // 🔹 Convenience Batch Functions for Gas Efficiency
    // ====================================================
    function batchGetProjectDetails(uint256[] calldata projectIds) 
        external 
        view 
        returns (
            ProjectData[] memory metadata,
            ProjectStateData[] memory state,
            ProjectAnalytics[] memory analytics
        ) 
    {
        metadata = new ProjectData[](projectIds.length);
        state = new ProjectStateData[](projectIds.length);
        analytics = new ProjectAnalytics[](projectIds.length);
        
        for (uint256 i = 0; i < projectIds.length; i++) {
            uint256 projectId = projectIds[i];
            if (projectMetadata[projectId].exists) {
                metadata[i] = projectMetadata[projectId];
                state[i] = projectStateData[projectId];
                analytics[i] = projectAnalytics[projectId];
            }
        }
        
        return (metadata, state, analytics);
    }
    
    // Batch operation to update multiple permissions at once
    function batchSetProjectPermissions(
        uint256 projectId,
        address[] calldata users,
        bytes32[] calldata permissions,
        bool[] calldata values
    ) external {
        if (!projectMetadata[projectId].exists) revert("Invalid project ID");
        
        // Only the project owner or someone with collaborator management permission can do this
        if (projectStateData[projectId].owner != msg.sender && 
            !hasRole(GOVERNANCE_ROLE, msg.sender) &&
            !hasProjectPermission(projectId, msg.sender, MANAGE_COLLABORATORS_PERMISSION)) {
            revert("Not authorized");
        }
        
        require(users.length == permissions.length && permissions.length == values.length, "Array lengths mismatch");
        
        for (uint256 i = 0; i < users.length; i++) {
            // Skip attempts to remove own management permission
            if (users[i] == msg.sender && permissions[i] == MANAGE_COLLABORATORS_PERMISSION && !values[i]) {
                continue;
            }
            
            projectPermissions[projectId][users[i]][permissions[i]] = values[i];
            emit ProjectPermissionUpdated(projectId, users[i], permissions[i], values[i]);
        }
    }
}
