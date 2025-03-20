// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28; 

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "../interfaces/ITerraStakeProjects.sol";
import "../interfaces/ITerraStakeNFT.sol";
import "../interfaces/ITerraStakeMarketplace.sol";
import "../interfaces/ITerraStakeStaking.sol";


/**
 * @title TerraStakeProjects 
 * @notice Manages projects, staking, impact tracking, governance-driven fees, and NFT integration.
 * @dev Implements UUPS upgradeable pattern and comprehensive role-based access control
 */
contract TerraStakeProjects is 
    ITerraStakeProjects,
    Initializable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    
    // ====================================================
    //  Roles
    // ====================================================
    bytes32 public constant PROJECT_MANAGER_ROLE = keccak256("PROJECT_MANAGER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant STAKER_ROLE = keccak256("STAKER_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    // ====================================================
    //  State Variables
    // ====================================================
    IERC20 public tStakeToken;
    uint256 public projectCount;
    
    // Added from context
    address public terraTokenAddress;
    address public treasuryAddress;
    uint256 public buybackFund;
    uint256 public constant MIN_CLAIM_PERIOD = 1 days;
    uint256 public constant TIME_REWARD_RATE = 1; // 0.01% per day
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    
    FeeStructure public fees;
    address public treasury;
    address public liquidityPool;
    address public stakingContract;
    address public rewardsContract;
    
    uint256[] private allProjectIds;
    uint256 private totalFeesCollected;
    uint256 private totalFeesWithdrawn;
    mapping(FeeType => uint256) private feesByType;

    uint256 public minimumStakeAmount;

    // NFT Integration
    address public nftContract;
    mapping(ProjectCategory => string) private categoryImageURI;
    
    // Category metadata with real-world requirements
    mapping(ProjectCategory => CategoryInfo) public categoryInfo;
    
    // Project data storage
    mapping(uint256 => ProjectMetaData) public projectMetadata;
    mapping(uint256 => ProjectStateData) public projectStateData;

    mapping(uint256 => VerificationData) public projectVerifications;
    mapping(uint256 => mapping(uint256 => ValidationData)) public reportValidations;
    mapping(uint256 => GeneralMetadata) public projectMetadataDetails;

    mapping(uint256 => Comment[]) public projectComments;
    
    mapping(uint256 => mapping(uint256 => ProjectDocument)) public projectDocuments;
    mapping(uint256 => uint256) public projectDocumentCount;
    mapping(uint256 => uint256[]) private _projectDocumentIndex;
    
    mapping(uint256 => ProjectAnalytics) public projectAnalytics;
    mapping(uint256 => ImpactReport[]) public projectImpactReports;
    mapping(uint256 => ImpactRequirement) public projectImpactRequirements;
    mapping(uint256 => RECData[]) public projectRECs;
    mapping(uint256 => ProjectTargets) public projectTargets;
    
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
    uint256[] private _projectsPendingVerification;
    
    // Circuit breaker security
    bool public emergencyMode;
    
    // Staking tracking
    StakingAction[] public stakingHistory;
    mapping(address => mapping(uint256 => uint256)) public userStakes;
    mapping(uint256 => uint256) public totalStakedOnProject;
    mapping(address => uint256) public totalStakedByUser;
    uint256 public totalStaked;

    // Project impact metrics tracking
    mapping(uint256 => uint256) public totalValidatedImpact;
    mapping(uint256 => uint256) public totalWeightedImpact;

    // Project rewards tracking
    mapping(address => mapping(uint256 => uint48)) public lastRewardClaim;
    uint256 public totalRewardsClaimed;
    mapping(address => uint256) public userRewardsClaimed;

    // Verification comments
    mapping(uint256 => mapping(uint256 => string)) public projectVerificationComments;


    // ====================================================
    //  Initialization & Upgrades
    // ====================================================
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin, 
        address _tstakeToken
    ) external initializer {
        if (admin == address(0) || _tstakeToken == address(0)) revert InvalidAddress();
        
        __AccessControlEnumerable_init();
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
        
        minimumStakeAmount = 1_000_000 * 10**18; // 1,000,000 TSTAKE
        
        // Initialize category information with real-world data
        _initializeCategories();
        
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

    // Initialize all categories with complete metadata
    function _initializeCategories() internal {
        // 1. Carbon Credit projects
        categoryInfo[ProjectCategory.CarbonCredit] = CategoryInfo({
            name: "Carbon Credit",
            description: "Projects that reduce or remove greenhouse gas emissions",
            standardBodies: new string[](4),
            metricUnits: new string[](3),
            verificationStandard: "ISO 14064-3",
            impactWeight: 100,
            keyMetrics: new string[](5),
            esgFocus: "Climate Change Mitigation"
        });
        categoryInfo[ProjectCategory.CarbonCredit].standardBodies = ["Verra", "Gold Standard", "American Carbon Registry", "Climate Action Reserve"];
        categoryInfo[ProjectCategory.CarbonCredit].metricUnits = ["tCO2e", "Carbon Offset Tons", "Carbon Removal Tons"];
        categoryInfo[ProjectCategory.CarbonCredit].keyMetrics = [
            "Direct CO2e measurements",
            "Satellite-verified forest coverage",
            "Industrial emissions monitoring",
            "Methane capture quantification",
            "Third-party offset verification"
        ];
        
        // 2. Renewable Energy projects
        categoryInfo[ProjectCategory.RenewableEnergy] = CategoryInfo({
            name: "Renewable Energy",
            description: "Solar, wind, hydro, and other renewable energy generation projects",
            standardBodies: new string[](3),
            metricUnits: new string[](3),
            verificationStandard: "ISO 50001",
            impactWeight: 90,
            keyMetrics: new string[](4),
            esgFocus: "Clean Energy Transition"
        });
        categoryInfo[ProjectCategory.RenewableEnergy].standardBodies = ["I-REC Standard", "Green-e Energy", "EKOenergy"];
        categoryInfo[ProjectCategory.RenewableEnergy].metricUnits = ["MWh", "kWh", "Installed Capacity (MW)"];
        categoryInfo[ProjectCategory.RenewableEnergy].keyMetrics = [
            "Real-time MWh and kWh tracking",
            "Grid integration and storage efficiency",
            "Transmission loss calculations",
            "Peak load reduction impact"
        ];
        
        // 3. Ocean Cleanup projects
        categoryInfo[ProjectCategory.OceanCleanup] = CategoryInfo({
            name: "Ocean Cleanup",
            description: "Marine conservation and plastic removal initiatives",
            standardBodies: new string[](3),
            metricUnits: new string[](3),
            verificationStandard: "UNEP Clean Seas Protocol",
            impactWeight: 85,
            keyMetrics: new string[](4),
            esgFocus: "Marine Ecosystem Protection"
        });
        categoryInfo[ProjectCategory.OceanCleanup].standardBodies = ["Ocean Cleanup Foundation", "Plastic Bank", "Ocean Conservancy"];
        categoryInfo[ProjectCategory.OceanCleanup].metricUnits = ["Tons of Plastic Removed", unicode"Area Protected (km²)", "Marine Species Protected"];
        categoryInfo[ProjectCategory.OceanCleanup].keyMetrics = [
            "Tons of marine debris removed",
            "Ocean current plastic concentration",
            "Microplastic density and marine ecosystem health",
            "Coastal cleanup impact and species recovery"
        ];
        
        // 4. Reforestation projects
        categoryInfo[ProjectCategory.Reforestation] = CategoryInfo({
            name: "Reforestation",
            description: "Tree planting and forest protection initiatives",
            standardBodies: new string[](3),
            metricUnits: new string[](3),
            verificationStandard: "ISO 14001",
            impactWeight: 95,
            keyMetrics: new string[](4),
            esgFocus: "Carbon Sequestration and Biodiversity"
        });
        categoryInfo[ProjectCategory.Reforestation].standardBodies = ["Forest Stewardship Council", "Rainforest Alliance", "One Tree Planted"];
        categoryInfo[ProjectCategory.Reforestation].metricUnits = ["Trees Planted", "Area Reforested (ha)", "Biomass Added (tons)"];
        categoryInfo[ProjectCategory.Reforestation].keyMetrics = [
            "Satellite-tracked tree planting",
            "Reforested area in hectares",
            "Soil quality and biodiversity assessments",
            "Carbon sequestration rates"
        ];
        
        // 5. Biodiversity projects
        categoryInfo[ProjectCategory.Biodiversity] = CategoryInfo({
            name: "Biodiversity",
            description: "Species and ecosystem protection initiatives",
            standardBodies: new string[](3),
            metricUnits: new string[](3),
            verificationStandard: "Convention on Biological Diversity",
            impactWeight: 85,
            keyMetrics: new string[](4),
            esgFocus: "Ecosystem and Wildlife Protection"
        });
        categoryInfo[ProjectCategory.Biodiversity].standardBodies = ["IUCN", "WWF", "The Nature Conservancy"];
        categoryInfo[ProjectCategory.Biodiversity].metricUnits = ["Species Protected", "Habitat Area (ha)", "Biodiversity Index"];
        categoryInfo[ProjectCategory.Biodiversity].keyMetrics = [
            "Species population tracking",
            "Habitat quality and ecosystem service valuations",
            "Migration pattern analysis",
            "Invasive species control"
        ];

        // Initialize remaining categories
        _initializeRemainingCategories();
    }

    function _initializeRemainingCategories() internal {
        // 6. Sustainable Agriculture projects
        categoryInfo[ProjectCategory.SustainableAg] = CategoryInfo({
            name: "Sustainable Agriculture",
            description: "Regenerative farming and sustainable agricultural practices",
            standardBodies: new string[](3),
            metricUnits: new string[](3),
            verificationStandard: "Global G.A.P.",
            impactWeight: 80,
            keyMetrics: new string[](4),
            esgFocus: "Food Security and Land Regeneration"
        });
        categoryInfo[ProjectCategory.SustainableAg].standardBodies = ["Regenerative Organic Certified", "USDA Organic", "Rainforest Alliance"];
        categoryInfo[ProjectCategory.SustainableAg].metricUnits = ["Organic Produce (tons)", "Soil Carbon Added (tons)", unicode"Water Saved (m³)"];
        categoryInfo[ProjectCategory.SustainableAg].keyMetrics = [
            "Soil organic carbon content",
            "Water use efficiency",
            "Chemical input reduction",
            "Sustainable yield data"
        ];
        
        // 7. Waste Management projects
        categoryInfo[ProjectCategory.WasteManagement] = CategoryInfo({
            name: "Waste Management",
            description: "Recycling and waste reduction initiatives",
            standardBodies: new string[](3),
            metricUnits: new string[](3),
            verificationStandard: "ISO 14001",
            impactWeight: 75,
            keyMetrics: new string[](3),
            esgFocus: "Circular Economy and Pollution Reduction"
        });
        categoryInfo[ProjectCategory.WasteManagement].standardBodies = ["Zero Waste International Alliance", "ISO 14001", "Cradle to Cradle"];
        categoryInfo[ProjectCategory.WasteManagement].metricUnits = ["Waste Diverted (tons)", "Recycling Rate (%)", unicode"Landfill Reduction (m³)"];
        categoryInfo[ProjectCategory.WasteManagement].keyMetrics = [
            "Recycling and landfill diversion rates",
            "Hazardous waste management",
            "Composting volumes and resource recovery"
        ];
        
        // 8. Water Conservation projects
        categoryInfo[ProjectCategory.WaterConservation] = CategoryInfo({
            name: "Water Conservation",
            description: "Water efficiency and protection initiatives",
            standardBodies: new string[](3),
            metricUnits: new string[](3),
            verificationStandard: "ISO 14046",
            impactWeight: 85,
            keyMetrics: new string[](3),
            esgFocus: "Sustainable Water Use"
        });
        categoryInfo[ProjectCategory.WaterConservation].standardBodies = ["Alliance for Water Stewardship", "Water Footprint Network", "LEED"];
        categoryInfo[ProjectCategory.WaterConservation].metricUnits = [unicode"Water Saved (m³)", "Area Protected (ha)", "People Served"];
        categoryInfo[ProjectCategory.WaterConservation].keyMetrics = [
            "Groundwater recharge rates",
            "Water quality indicators",
            "Usage efficiency and ecosystem impact"
        ];
        
        // 9. Pollution Control projects
        categoryInfo[ProjectCategory.PollutionControl] = CategoryInfo({
            name: "Pollution Control",
            description: "Air and environmental quality improvement initiatives",
            standardBodies: new string[](3),
            metricUnits: new string[](3),
            verificationStandard: "ISO 14001",
            impactWeight: 80,
            keyMetrics: new string[](3),
            esgFocus: "Air and Soil Quality Improvement"
        });
        categoryInfo[ProjectCategory.PollutionControl].standardBodies = ["ISO 14001", "Clean Air Act", "EPA Standards"];
        categoryInfo[ProjectCategory.PollutionControl].metricUnits = ["Emissions Reduced (tons)", "AQI Improvement", "Area Remediated (ha)"];
        categoryInfo[ProjectCategory.PollutionControl].keyMetrics = [
            "Air quality and particulate matter levels",
            "Chemical contamination data",
            "Noise and soil pollution mitigation"
        ];
        
        // 10. Habitat Restoration projects
        categoryInfo[ProjectCategory.HabitatRestoration] = CategoryInfo({
            name: "Habitat Restoration",
            description: "Ecosystem recovery projects",
            standardBodies: new string[](3),
            metricUnits: new string[](3),
            verificationStandard: "SER International Standards",
            impactWeight: 90,
            keyMetrics: new string[](4),
            esgFocus: "Ecosystem Recovery and Biodiversity"
        });
        categoryInfo[ProjectCategory.HabitatRestoration].standardBodies = ["Society for Ecological Restoration", "IUCN", "Land Life Company"];
        categoryInfo[ProjectCategory.HabitatRestoration].metricUnits = ["Area Restored (ha)", "Species Reintroduced", "Ecological Health Index"];
        categoryInfo[ProjectCategory.HabitatRestoration].keyMetrics = [
            "Native species reintroduction",
            "Ecosystem function restoration",
            "Habitat connectivity improvements",
            "Ecological resilience measurements"
        ];
        
        // 11. Green Building projects
        categoryInfo[ProjectCategory.GreenBuilding] = CategoryInfo({
            name: "Green Building",
            description: "Energy-efficient infrastructure & sustainable construction",
            standardBodies: new string[](4),
            metricUnits: new string[](3),
            verificationStandard: "LEED Certification",
            impactWeight: 70,
            keyMetrics: new string[](4),
            esgFocus: "Sustainable Infrastructure"
        });
        categoryInfo[ProjectCategory.GreenBuilding].standardBodies = ["LEED", "BREEAM", "Passive House", "Living Building Challenge"];
        categoryInfo[ProjectCategory.GreenBuilding].metricUnits = ["Energy Saved (kWh)", "CO2 Reduced (tons)", unicode"Water Saved (m³)"];
        categoryInfo[ProjectCategory.GreenBuilding].keyMetrics = [
            "Energy efficiency ratings",
            "Sustainable material usage",
            "Water conservation systems",
            "Indoor environmental quality"
        ];
        
        // 12. Circular Economy projects
        categoryInfo[ProjectCategory.CircularEconomy] = CategoryInfo({
            name: "Circular Economy",
            description: "Waste-to-energy, recycling loops, regenerative economy",
            standardBodies: new string[](3),
            metricUnits: new string[](3),
            verificationStandard: "BS 8001:2017",
            impactWeight: 85,
            keyMetrics: new string[](4),
            esgFocus: "Resource Efficiency"
        });
        categoryInfo[ProjectCategory.CircularEconomy].standardBodies = ["Ellen MacArthur Foundation", "Cradle to Cradle", "Circle Economy"];
        categoryInfo[ProjectCategory.CircularEconomy].metricUnits = ["Material Reused (tons)", "Product Lifecycle Extension", "Virgin Material Avoided (tons)"];
        categoryInfo[ProjectCategory.CircularEconomy].keyMetrics = [
            "Material circularity index",
            "Product lifecycle extension",
            "Waste stream conversion rates",
            "Resource productivity improvements"
        ];
        
        // 13. Community Development projects
        categoryInfo[ProjectCategory.CommunityDevelopment] = CategoryInfo({
            name: "Community Development",
            description: "Local sustainability initiatives and social impact projects",
            standardBodies: new string[](3),
            metricUnits: new string[](3),
            verificationStandard: "Social Return on Investment Framework",
            impactWeight: 75,
            keyMetrics: new string[](4),
            esgFocus: "Social Sustainability"
        });
        categoryInfo[ProjectCategory.CommunityDevelopment].standardBodies = ["B Corp", "Social Value International", "Community Development Financial Institutions"];
        categoryInfo[ProjectCategory.CommunityDevelopment].metricUnits = ["People Impacted", "Jobs Created", "Community Resources Generated"];
        categoryInfo[ProjectCategory.CommunityDevelopment].keyMetrics = [
            "Community engagement levels",
            "Quality of life improvements",
            "Local economic development",
            "Equitable resource distribution"
        ];
    }

    // ====================================================
    //  NFT Integration Functions
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

    function _finalizeProjectStaking(uint256 projectId, bool isCompleted) internal {
        // Notify staking contract about project completion
        // This allows for special handling of staked tokens
        ITerraStakeStaking(stakingContract).finalizeProjectStaking(projectId, isCompleted);
            
        emit ProjectStakingFinalized(projectId, isCompleted, block.timestamp);
    }

    // ====================================================
    //  Project Management
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
        if (bytes(name).length == 0) revert EmptyProjectName();
        if (bytes(description).length == 0) revert EmptyProjectDescription();
        if (bytes(location).length == 0) revert EmptyProjectLocation();
        if (bytes(impactMetrics).length == 0) revert EmptyImpactMetrics();
        if (ipfsHash == bytes32(0)) revert InvalidIpfsHash();
        if (stakingMultiplier == 0) revert InvalidStakingMultiplier();
        if (startBlock >= endBlock) revert InvalidBlockRange();
        
        // Fee handling
        uint256 submissionFee = fees.projectSubmissionFee;
        if (submissionFee > 0) {
            bool success = tStakeToken.transferFrom(msg.sender, address(this), submissionFee);
            if (!success) revert TokenTransferFailed();
            
            // Update fee collections
            totalFeesCollected += submissionFee;
            feesByType[FeeType.ProjectSubmission] += submissionFee;
            
            emit FeeCollected(projectCount + 1, FeeType.ProjectSubmission, submissionFee);
        }
        
        projectCount ++;
        uint256 projectId = projectCount;
        
        // Store project metadata
        projectMetadata[projectId] = ProjectMetaData({
            name: name,
            description: description,
            location: location,
            impactMetrics: impactMetrics,
            ipfsHash: ipfsHash,
            exists: true,
            creationTime: uint48(block.timestamp)
        });
        
        // Store project state
        projectStateData[projectId] = ProjectStateData({
            category: category,
            stakingMultiplier: stakingMultiplier,
            state: ProjectState.Pending,
            startBlock: startBlock,
            endBlock: endBlock
        });
        
        allProjectIds.push(projectId);
        _projectsByCategory[category].push(projectId);
        
        emit ProjectCreated(
            projectId,
            msg.sender,
            name,
            category,
            stakingMultiplier,
            startBlock,
            endBlock
        );
    }
    
    function updateProject(
        uint256 projectId,
        string memory name,
        string memory description,
        string memory location,
        string memory impactMetrics,
        bytes32 ipfsHash,
        uint48 startBlock,
        uint48 endBlock
    ) external nonReentrant onlyRole(PROJECT_MANAGER_ROLE) whenNotPaused {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        // Ensure project isn't in a terminal state
        ProjectState currentState = projectStateData[projectId].state;
        if (currentState == ProjectState.Completed || 
            currentState == ProjectState.Cancelled) {
            revert ProjectInTerminalState();
        }
        
        // Validate new data
        if (bytes(name).length == 0) revert EmptyProjectName();
        if (bytes(description).length == 0) revert EmptyProjectDescription();
        if (bytes(location).length == 0) revert EmptyProjectLocation();
        if (bytes(impactMetrics).length == 0) revert EmptyImpactMetrics();
        if (ipfsHash == bytes32(0)) revert InvalidIpfsHash();
        if (startBlock >= endBlock) revert InvalidBlockRange();
        
        // Update project metadata
        projectMetadata[projectId].name = name;
        projectMetadata[projectId].description = description;
        projectMetadata[projectId].location = location;
        projectMetadata[projectId].impactMetrics = impactMetrics;
        projectMetadata[projectId].ipfsHash = ipfsHash;
        
        // Update project state data
        projectStateData[projectId].startBlock = startBlock;
        projectStateData[projectId].endBlock = endBlock;
        
        emit ProjectUpdated(
            projectId,
            msg.sender,
            name,
            startBlock,
            endBlock
        );
    }
    
    function changeProjectCategory(
        uint256 projectId,
        ProjectCategory newCategory
    ) external nonReentrant onlyRole(PROJECT_MANAGER_ROLE) whenNotPaused {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        ProjectStateData storage project = projectStateData[projectId];
        
        // Ensure project isn't in a terminal state
        if (project.state == ProjectState.Completed || 
            project.state == ProjectState.Cancelled) {
            revert ProjectInTerminalState();
        }
        
        // Don't do anything if category is the same
        if (project.category == newCategory) {
            return;
        }
        
        // Fee handling
        uint256 categoryChangeFee = fees.categoryChangeFee;
        if (categoryChangeFee > 0) {
            bool success = tStakeToken.transferFrom(msg.sender, address(this), categoryChangeFee);
            if (!success) revert TokenTransferFailed();
            
            // Update fee collections
            totalFeesCollected += categoryChangeFee;
            feesByType[FeeType.CategoryChange] += categoryChangeFee;
            
            emit FeeCollected(projectId, FeeType.CategoryChange, categoryChangeFee);
        }
        
        // Update category arrays
        ProjectCategory oldCategory = project.category;
        
        // Remove from old category array
        uint256 indexInOld = type(uint256).max;
        for (uint256 i = 0; i < _projectsByCategory[oldCategory].length; i++) {
            if (_projectsByCategory[oldCategory][i] == projectId) {
                indexInOld = i;
                break;
            }
        }
        
        if (indexInOld != type(uint256).max) {
            // Replace with the last element and pop
            _projectsByCategory[oldCategory][indexInOld] = _projectsByCategory[oldCategory][_projectsByCategory[oldCategory].length - 1];
            _projectsByCategory[oldCategory].pop();
        }
        
        // Add to new category array
        _projectsByCategory[newCategory].push(projectId);
        
        // Update project state
        project.category = newCategory;
        
        emit ProjectCategoryChanged(projectId, oldCategory, newCategory);
    }
    
    function updateProjectState(
        uint256 projectId,
        ProjectState newState
    ) external override nonReentrant onlyRole(PROJECT_MANAGER_ROLE) whenNotPaused {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        ProjectStateData storage project = projectStateData[projectId];
        
        // Check for valid state transitions
        ProjectState currentState = project.state;
        
        // Cannot change from terminal states
        if (currentState == ProjectState.Completed || 
            currentState == ProjectState.Cancelled) {
            revert ProjectInTerminalState();
        }
        
        // Cannot set to same state
        if (currentState == newState) {
            return;
        }
        
        // Validation for specific state transitions
        if (newState == ProjectState.Active) {
            // Only projects that are Pending or Paused can be set to Active
            if (currentState != ProjectState.Pending && 
                currentState != ProjectState.Paused) {
                revert InvalidStateTransition();
            }
            
            // Require verification before activation
            if (projectVerifications[projectId].verificationDate == 0) {
                revert ProjectNotVerified();
            }
        }
        
        // Terminal state logic
        if (newState == ProjectState.Completed || newState == ProjectState.Cancelled) {
            // Process final staking and cleanup logic
            _finalizeProjectStaking(projectId, newState == ProjectState.Completed);
        }
        
        // Update project state
        project.state = newState;
        
        emit ProjectStateChanged(projectId, currentState, newState);
    }

    function updateStakingMultiplier(
        uint256 projectId,
        uint32 newMultiplier
    ) external nonReentrant onlyRole(PROJECT_MANAGER_ROLE) whenNotPaused {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        if (newMultiplier == 0) revert InvalidStakingMultiplier();
        
        ProjectStateData storage project = projectStateData[projectId];
        
        // Ensure project isn't in a terminal state
        if (project.state == ProjectState.Completed || 
            project.state == ProjectState.Cancelled) {
            revert ProjectInTerminalState();
        }
        
        // Update multiplier
        uint32 oldMultiplier = project.stakingMultiplier;
        project.stakingMultiplier = newMultiplier;
        
        emit StakingMultiplierUpdated(projectId, oldMultiplier, newMultiplier);
    }

    // ====================================================
    //  Verification, Validation & Impact Reporting
    // ====================================================
    function verifyProject(
        uint256 projectId,
        address verifier,
        string calldata verificationDetails,
        bytes32 documentHash
    ) external nonReentrant onlyRole(VERIFIER_ROLE) whenNotPaused {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        // Fee handling
        uint256 verificationFee = fees.verificationFee;
        if (verificationFee > 0) {
            bool success = tStakeToken.transferFrom(msg.sender, address(this), verificationFee);
            if (!success) revert TokenTransferFailed();
            
            // Update fee collections
            totalFeesCollected += verificationFee;
            feesByType[FeeType.Verification] += verificationFee;
            
            emit FeeCollected(projectId, FeeType.Verification, verificationFee);
        }
        
        // Create or update verification record
        projectVerifications[projectId] = VerificationData({
            verifier: verifier,
            verificationDate: uint48(block.timestamp),
            verificationDocumentHash: documentHash,
            verifierNotes: verificationDetails
        });
        
        emit ProjectVerified(projectId, verifier, documentHash);
    }

    function submitImpactReport(
        uint256 projectId,
        string calldata reportTitle,
        string calldata reportDetails,
        bytes32 ipfsReportHash,
        uint256 impactMetricValue
    ) external override nonReentrant whenNotPaused {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        // Ensure project is active
        if (projectStateData[projectId].state != ProjectState.Active) revert ProjectNotActive();
        
        // Fee handling
        uint256 reportingFee = fees.impactReportingFee;
        if (reportingFee > 0) {
            bool success = tStakeToken.transferFrom(msg.sender, address(this), reportingFee);
            if (!success) revert TokenTransferFailed();
            
            // Update fee collections
            totalFeesCollected += reportingFee;
            feesByType[FeeType.ImpactReporting] += reportingFee;
            
            emit FeeCollected(projectId, FeeType.ImpactReporting, reportingFee);
        }
        
        // Create impact report
        ImpactReport memory impactReport = ImpactReport({
            projectId: projectId,
            reporter: msg.sender,
            timestamp: uint48(block.timestamp),
            title: reportTitle,
            details: reportDetails,
            ipfsHash: ipfsReportHash,
            metricValue: impactMetricValue,
            validated: false
        });
        
        projectImpactReports[projectId].push(impactReport);
        
        uint256 reportId = projectImpactReports[projectId].length;
        emit ImpactReportSubmitted(projectId, reportId, msg.sender, ipfsReportHash, impactMetricValue);
    }

    function validateImpactReport(
        uint256 projectId,
        uint256 reportId,
        bool isValid,
        string calldata validationNotes
    ) external nonReentrant onlyRole(VALIDATOR_ROLE) whenNotPaused {
        ImpactReport storage report = projectImpactReports[projectId][reportId];
        
        // Check if report exists
        if (report.timestamp == 0) revert InvalidReportId();
        
        // Check if already validated
        if (report.validated) revert ReportAlreadyValidated();
        
        // Update validation status
        report.validated = isValid;
        
        // Store validation
        reportValidations[projectId][reportId] = ValidationData({
            validator: msg.sender,
            validationTime: uint48(block.timestamp),
            validationNotes: validationNotes,
            isValid: isValid
        });
        
        // Update project impact metrics if valid
        if (isValid) {
            projectId = report.projectId;
            totalValidatedImpact[projectId] += report.metricValue;
            
            // Apply category weight to the impact value for weighted metrics
            ProjectCategory category = projectStateData[projectId].category;
            uint256 weight = categoryInfo[category].impactWeight;
            uint256 weightedImpact = (report.metricValue * weight) / 100;
            
            totalWeightedImpact[projectId] += weightedImpact;
        }
        
        emit ImpactReportValidated(report.projectId, reportId, msg.sender, isValid);
    }

    function getProjectReportStats(uint256 projectId) external view returns (
        uint256 totalReports,
        uint256 validatedReports,
        uint256 rejectedReports,
        uint256 pendingReports,
        uint256 averageValidationTime
    ) {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        // Get all reports for this project
        ImpactReport[] memory reports = projectImpactReports[projectId];
        totalReports = reports.length;
        
        // Initialize counters
        validatedReports = 0;
        rejectedReports = 0;
        pendingReports = 0;
        
        // Track validation times for average calculation
        uint256 totalValidationTime = 0;
        uint256 validationTimeCount = 0;
        
        // Iterate through all reports
        for (uint256 i = 0; i < totalReports; i++) {
            ImpactReport memory report = reports[i];
            
            // Check validation status
            ValidationData memory validation = reportValidations[projectId][i];
            
            if (validation.validationTime > 0) {
                // Report has been validated
                if (validation.isValid) {
                    validatedReports++;
                } else {
                    rejectedReports++;
                }
                
                // Calculate validation time (time between report submission and validation)
                uint256 validationDuration = validation.validationTime - report.timestamp;
                totalValidationTime += validationDuration;
                validationTimeCount++;
            } else {
                // Report is pending validation
                pendingReports++;
            }
        }
        
        // Calculate average validation time (in seconds)
        averageValidationTime = validationTimeCount > 0 ? totalValidationTime / validationTimeCount : 0;
        
        return (
            totalReports,
            validatedReports,
            rejectedReports,
            pendingReports,
            averageValidationTime
        );
    }
    
    // ====================================================
    //  Staking & Rewards
    // ====================================================
    
    function stakeOnProject(
        uint256 projectId,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        // Ensure project is in an active state for staking
        ProjectState state = projectStateData[projectId].state;
        if (state != ProjectState.Active) revert ProjectNotActive();
        
        // Check for minimum stake amount
        if (amount < minimumStakeAmount) revert StakeTooSmall();
        
        // Transfer tokens from user to contract
        bool success = tStakeToken.transferFrom(msg.sender, address(this), amount);
        if (!success) revert TokenTransferFailed();
        
        // Update staking records
        userStakes[msg.sender][projectId] += amount;
        totalStakedOnProject[projectId] += amount;
        totalStakedByUser[msg.sender] += amount;
        totalStaked += amount;
        
        // Track staking history
        stakingHistory.push(StakingAction({
            user: msg.sender,
            projectId: projectId,
            amount: amount,
            timestamp: uint48(block.timestamp),
            actionType: StakingActionType.Stake
        }));
        
        // Grant staker role if this is their first stake
        if (!hasRole(STAKER_ROLE, msg.sender)) {
            _grantRole(STAKER_ROLE, msg.sender);
        }
        
        emit ProjectStaked(projectId, msg.sender, amount);
    }
        function unstakeFromProject(
        uint256 projectId,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        // Check if user has enough staked
        uint256 userStake = userStakes[msg.sender][projectId];
        if (userStake < amount) revert InsufficientStake();
        
        // Update staking records
        userStakes[msg.sender][projectId] -= amount;
        totalStakedOnProject[projectId] -= amount;
        totalStakedByUser[msg.sender] -= amount;
        totalStaked -= amount;
        
        // Track unstaking history
        stakingHistory.push(StakingAction({
            user: msg.sender,
            projectId: projectId,
            amount: amount,
            timestamp: uint48(block.timestamp),
            actionType: StakingActionType.Unstake
        }));
        
        // Transfer tokens from contract to user
        bool success = tStakeToken.transfer(msg.sender, amount);
        if (!success) revert TokenTransferFailed();
        
        emit ProjectUnstaked(projectId, msg.sender, amount);
    }
    
    function calculateRewards(
        address user,
        uint256 projectId
    ) external view returns (uint256) {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        uint256 userStake = userStakes[user][projectId];
        if (userStake == 0) return 0;
        
        // Get staking multiplier for this project
        uint32 multiplier = projectStateData[projectId].stakingMultiplier;
        
        // Calculate base rewards based on time staked, amount, and project multiplier
        uint256 baseRewards = _calculateBaseRewards(user, projectId, userStake, multiplier);
        
        // Apply impact performance bonus if applicable
        uint256 impactBonus = _calculateImpactBonus(projectId, baseRewards);
        
        return baseRewards + impactBonus;
    }
    
    function _calculateBaseRewards(
        address user,
        uint256 projectId,
        uint256 userStake,
        uint32 multiplier
    ) internal view returns (uint256) {
        // Get the earliest staking action for this user and project
        uint48 stakingStartTime = type(uint48).max;
        
        for (uint256 i = 0; i < stakingHistory.length; i++) {
            StakingAction memory action = stakingHistory[i];
            if (action.user == user && action.projectId == projectId && action.actionType == StakingActionType.Stake) {
                if (action.timestamp < stakingStartTime) {
                    stakingStartTime = action.timestamp;
                }
            }
        }
        
        // Calculate staking duration in days (minimum 1 day for calculation purposes)
        uint256 stakingDuration = block.timestamp > stakingStartTime 
            ? (block.timestamp - stakingStartTime) / 1 days 
            : 1;
        
        // Base annual reward rate: 5% (500 basis points)
        uint256 baseRewardRate = 500;
        
        // Apply multiplier (scaled to basis points, where 100 = 1x)
        uint256 adjustedRate = (baseRewardRate * multiplier) / 100;
        
        // Calculate daily reward rate
        uint256 dailyRate = adjustedRate / 365;
        
        // Calculate rewards based on stake amount, daily rate and duration
        // Formula: (stake * dailyRate * duration) / 10000
        return (userStake * dailyRate * stakingDuration) / 10000;
    }
    
    function _calculateImpactBonus(
        uint256 projectId,
        uint256 baseRewards
    ) internal view returns (uint256) {
        // Get total validated impact
        uint256 impact = totalValidatedImpact[projectId];
        
        // Get impact targets
        uint256 targetImpact = projectTargets[projectId].impactTarget;
        
        // If no target set or impact is zero, no bonus
        if (targetImpact == 0 || impact == 0) return 0;
        
        // Calculate achievement percentage (capped at 150%)
        uint256 achievementPercentage = (impact * 100) / targetImpact;
        achievementPercentage = achievementPercentage > 150 ? 150 : achievementPercentage;
        
        // Bonus starts at 5% achievement, maxes at 50% bonus at 150% achievement
        if (achievementPercentage < 5) return 0;
        
        // Scale bonus from 0-50% based on achievement
        uint256 bonusPercentage = ((achievementPercentage - 5) * 50) / 145;
        
        // Apply bonus to base rewards
        return (baseRewards * bonusPercentage) / 100;
    }
    
    function claimRewards(
        uint256 projectId
    ) external nonReentrant whenNotPaused {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        // Get claimable rewards
        uint256 rewards = this.calculateRewards(msg.sender, projectId);
        if (rewards == 0) revert NoRewardsToClaim();
        
        // Reset last claimed timestamp
        lastRewardClaim[msg.sender][projectId] = uint48(block.timestamp);
        
        // Update total rewards claimed
        totalRewardsClaimed += rewards;
        userRewardsClaimed[msg.sender] += rewards;
        
        // Transfer rewards to user
        bool success = tStakeToken.transfer(msg.sender, rewards);
        if (!success) revert TokenTransferFailed();
        
        emit RewardsClaimed(projectId, msg.sender, rewards);
    }
    
    function setProjectTargets(
        uint256 projectId,
        uint256 impactTarget,
        uint256 stakingTarget
    ) external nonReentrant onlyRole(PROJECT_MANAGER_ROLE) whenNotPaused {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        projectTargets[projectId] = ProjectTargets({
            impactTarget: impactTarget,
            stakingTarget: stakingTarget
        });
        
        emit ProjectTargetsSet(projectId, impactTarget, stakingTarget);
    }

    function incrementStakerCount(uint256 projectId) external override nonReentrant onlyRole(STAKER_ROLE) whenNotPaused {
        // if (projectMetadata[projectId].exists) revert InvalidProjectId();
        // projectStakerCount[projectId]++;
    }

    function decrementStakerCount(uint256 projectId) external override nonReentrant onlyRole(STAKER_ROLE) whenNotPaused {
        // if (projectMetadata[projectId].exists) revert InvalidProjectId();
        // projectStakerCount[projectId]--;
    }
    
    function setMinimumStakeAmount(
        uint256 amount
    ) external onlyRole(GOVERNANCE_ROLE) {
        minimumStakeAmount = amount;
        emit MinimumStakeAmountSet(amount);
    }
    
    // ====================================================
    // 🔹 Fee Management
    // ====================================================
    
    function updateFeeStructure(
        uint256 newProjectSubmissionFee,
        uint256 newImpactReportingFee,
        uint256 newVerificationFee,
        uint256 newCategoryChangeFee
    ) external override onlyRole(GOVERNANCE_ROLE) {
        fees = FeeStructure({
            projectSubmissionFee: newProjectSubmissionFee,
            impactReportingFee: newImpactReportingFee,
            verificationFee: newVerificationFee,
            categoryChangeFee: newCategoryChangeFee
        });
        
        emit FeeStructureUpdated(
            newProjectSubmissionFee,
            newImpactReportingFee,
            newVerificationFee,
            newCategoryChangeFee
        );
    }
    
    function withdrawFees(
        address recipient, 
        uint256 amount
    ) external nonReentrant onlyRole(TREASURY_ROLE) {
        if (recipient == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        
        // Check available fees to withdraw
        uint256 availableFees = totalFeesCollected - totalFeesWithdrawn;
        if (amount > availableFees) revert InsufficientFees();
        
        // Update withdrawn amount
        totalFeesWithdrawn += amount;
        
        // Transfer fees to recipient
        bool success = tStakeToken.transfer(recipient, amount);
        if (!success) revert TokenTransferFailed();
        
        emit FeesWithdrawn(recipient, amount);
    }
    
    // ====================================================
    // 🔹 Query & View Functions
    // ====================================================
    
    function getProjectMetadata(
        uint256 projectId
    ) external view returns (ProjectMetaData memory) {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        return projectMetadata[projectId];
    }
    
    function getProjectState(
        uint256 projectId
    ) external view returns (ProjectStateData memory) {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        return projectStateData[projectId];
    }
    
    function getProjectVerification(
        uint256 projectId
    ) external view returns (VerificationData memory) {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        return projectVerifications[projectId];
    }
    
    function getImpactReport(
        uint256 projectId,
        uint256 reportId
    ) external view returns (ImpactReport memory) {
        if (projectImpactReports[projectId][reportId].timestamp == 0) revert InvalidReportId();
        return projectImpactReports[projectId][reportId];
    }
    
    function getProjectImpactReports(
        uint256 projectId
    ) external view returns (ImpactReport[] memory) {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        return projectImpactReports[projectId];
    }
    
    function getReportValidation(
        uint256 projectId,
        uint256 reportId
    ) external view returns (ValidationData memory) {
        if (projectImpactReports[projectId][reportId].timestamp == 0) revert InvalidReportId();
        return reportValidations[projectId][reportId];
    }
    
    function getProjectsByCategory(
        ProjectCategory category
    ) external view returns (uint256[] memory) {
        return _projectsByCategory[category];
    }
    
    function getAllProjectIds() external view returns (uint256[] memory) {
        return allProjectIds;
    }
    
    function getProjectCount() external view returns (uint256) {
        return projectCount;
    }
    
    // Get full category information
    function getCategoryInfo(
        ProjectCategory category
    ) external view returns (CategoryInfo memory) {
        return categoryInfo[category];
    }

    // Function to update category metrics (admin only)
    function updateCategoryKeyMetrics(
        ProjectCategory category,
        string[] calldata newKeyMetrics
    ) external onlyRole(GOVERNANCE_ROLE) {
        categoryInfo[category].keyMetrics = newKeyMetrics;
    }

    // Function to update category ESG focus (admin only)
    function updateCategoryESGFocus(
        ProjectCategory category,
        string calldata newESGFocus
    ) external onlyRole(GOVERNANCE_ROLE) {
        categoryInfo[category].esgFocus = newESGFocus;
    }
    
    function getStakedAmount(
        address user,
        uint256 projectId
    ) external view returns (uint256) {
        return userStakes[user][projectId];
    }
    
    function getTotalStakedByUser(
        address user
    ) external view returns (uint256) {
        return totalStakedByUser[user];
    }
    
    function getTotalStakedOnProject(
        uint256 projectId
    ) external view returns (uint256) {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        return totalStakedOnProject[projectId];
    }
    
    function getProjectTargets(
        uint256 projectId
    ) external view returns (ProjectTargets memory) {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        return projectTargets[projectId];
    }
    
    function getTotalValidatedImpact(
        uint256 projectId
    ) external view returns (uint256) {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        return totalValidatedImpact[projectId];
    }
    
    function getTotalWeightedImpact(
        uint256 projectId
    ) external view returns (uint256) {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        return totalWeightedImpact[projectId];
    }
    
    function getFeeStructure() external view returns (FeeStructure memory) {
        return fees;
    }
    
    function getTotalFeesCollected() external view returns (uint256) {
        return totalFeesCollected;
    }
    
    function getTotalFeesWithdrawn() external view returns (uint256) {
        return totalFeesWithdrawn;
    }
    
    function getFeesByType(
        FeeType feeType
    ) external view returns (uint256) {
        return feesByType[feeType];
    }

    /**
     * @notice Adds a comment to a project
     * @param projectId ID of the project
     * @param message Comment content
     */
    function addComment(uint256 projectId, string calldata message) external {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        // Create comment
        Comment memory comment = Comment({
            commenter: msg.sender,
            message: message,
            timestamp: uint48(block.timestamp)
        });
        
        projectComments[projectId].push(comment);
        
        emit CommentAdded(projectId, msg.sender, message);
    }
    
    // ====================================================
    // 🔹 Admin & Emergency Functions
    // ====================================================
    
    function pause() external onlyRole(GOVERNANCE_ROLE) {
        _pause();
        emit ContractPaused(msg.sender);
    }
    
    function unpause() external onlyRole(GOVERNANCE_ROLE) {
        _unpause();
        emit ContractUnpaused(msg.sender);
    }
    
    function recoverERC20(
        address tokenAddress,
        address to,
        uint256 amount
    ) external nonReentrant onlyRole(GOVERNANCE_ROLE) {
        // Prevent recovering the primary TSTAKE token
        if (tokenAddress == terraTokenAddress) revert CannotRecoverPrimaryToken();
        
        IERC20 token = IERC20(tokenAddress);
        bool success = token.transfer(to, amount);
        if (!success) revert TokenTransferFailed();
        
        emit TokenRecovered(tokenAddress, to, amount);
    }
    
    function setRoleAdmin(
        bytes32 role,
        bytes32 adminRole
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRoleAdmin(role, adminRole);
        emit RoleAdminChanged(role, getRoleAdmin(role), adminRole);
    }
    
    // ====================================================
    // 🔹 Implementation-specific functions
    // ====================================================
    
    // Function to get staking history for a specific user
    function getUserStakingHistory(
        address user
    ) external view returns (StakingAction[] memory) {
        // Count user's actions first
        uint256 count = 0;
        for (uint256 i = 0; i < stakingHistory.length; i++) {
            if (stakingHistory[i].user == user) {
                count++;
            }
        }
        
        // Create appropriately sized array
        StakingAction[] memory userHistory = new StakingAction[](count);
        
        // Fill the array
        uint256 index = 0;
        for (uint256 i = 0; i < stakingHistory.length; i++) {
            if (stakingHistory[i].user == user) {
                userHistory[index] = stakingHistory[i];
                index++;
            }
        }
        
        return userHistory;
    }
    
    // Function to get active projects (pagination supported)
    function getActiveProjects(
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory) {
        // Count active projects
        uint256 activeCount = 0;
        for (uint256 i = 0; i < allProjectIds.length; i++) {
            uint256 projectId = allProjectIds[i];
            if (projectStateData[projectId].state == ProjectState.Active) {
                activeCount++;
            }
        }
        
        // Adjust limit if needed
        if (offset >= activeCount) {
            return new uint256[](0);
        }
        
        uint256 resultSize = (offset + limit > activeCount) ? activeCount - offset : limit;
        uint256[] memory activeProjects = new uint256[](resultSize);
        
        // Fill the result array
        uint256 index = 0;
        uint256 skipped = 0;
        
        for (uint256 i = 0; i < allProjectIds.length && index < resultSize; i++) {
            uint256 projectId = allProjectIds[i];
            if (projectStateData[projectId].state == ProjectState.Active) {
                if (skipped < offset) {
                    skipped++;
                } else {
                    activeProjects[index] = projectId;
                    index++;
                }
            }
        }
        
        return activeProjects;
    }
    
    // Function to get validated impact reports for a project
    function getValidatedReports(
        uint256 projectId
    ) external view returns (ImpactReport[] memory) {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        // Create result array
        ImpactReport[] memory validatedReports;
        uint256 validatedCount = 0;
        
        ImpactReport[] memory allReports = projectImpactReports[projectId];

        for (uint256 i = 0; i < allReports.length; i++) {
            if (allReports[i].validated) {
                validatedReports[validatedCount] = allReports[i];
                validatedCount = validatedCount + 1;
            }
        }
        
        return validatedReports;
    }
    
    // Function to get project performance metrics
    function getProjectPerformance(
        uint256 projectId
    ) external view returns (
        uint256 _totalStaked,
        uint256 totalImpact,
        uint256 stakingTargetPercentage,
        uint256 impactTargetPercentage
    ) {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        
        _totalStaked = totalStakedOnProject[projectId];
        totalImpact = totalValidatedImpact[projectId];
        
        ProjectTargets memory targets = projectTargets[projectId];
        
        // Calculate percentages (100% = 10000 for precision)
        stakingTargetPercentage = targets.stakingTarget > 0 
            ? (_totalStaked * 10000) / targets.stakingTarget 
            : 0;
            
        impactTargetPercentage = targets.impactTarget > 0 
            ? (totalImpact * 10000) / targets.impactTarget 
            : 0;
            
        return (_totalStaked, totalImpact, stakingTargetPercentage, impactTargetPercentage);
    }
    
    // Function to get project leaderboard by impact
    function getProjectLeaderboard(
    uint256 limit
) external view returns (
    uint256[] memory projectIds,
    uint256[] memory impactValues
) {
    // Limit the number of projects to return
    uint256 resultSize = limit > allProjectIds.length ? allProjectIds.length : limit;
    
    // Initialize arrays
    projectIds = new uint256[](resultSize);
    impactValues = new uint256[](resultSize);
    
    // Create temporary array of project IDs and impact values
    uint256[] memory tempProjectIds = new uint256[](allProjectIds.length);
    uint256[] memory tempImpactValues = new uint256[](allProjectIds.length);
    
    // Fill temporary arrays
    for (uint256 i = 0; i < allProjectIds.length; i++) {
        uint256 projectId = allProjectIds[i];
        tempProjectIds[i] = projectId;
        tempImpactValues[i] = totalWeightedImpact[projectId];
    }
    
    // Sort projects by impact (optimized bubble sort)
    for (uint256 i = 0; i < tempProjectIds.length - 1; i++) {
        for (uint256 j = 0; j < tempProjectIds.length - i - 1; j++) {
            if (tempImpactValues[j] < tempImpactValues[j + 1]) {
                // Swap impact values
                uint256 tempImpact = tempImpactValues[j];
                tempImpactValues[j] = tempImpactValues[j + 1];
                tempImpactValues[j + 1] = tempImpact;
                
                // Swap project IDs
                uint256 tempId = tempProjectIds[j];
                tempProjectIds[j] = tempProjectIds[j + 1];
                tempProjectIds[j + 1] = tempId;
            }
        }
    }
    
    // Take the top 'resultSize' projects
    for (uint256 i = 0; i < resultSize; i++) {
        projectIds[i] = tempProjectIds[i];
        impactValues[i] = tempImpactValues[i];
    }
    
    return (projectIds, impactValues);
}
    
    // Function to generate a summary of the platform
    function getPlatformSummary() external view returns (
        uint256 numberOfProjects,
        uint256 activeProjects,
        uint256 totalStakedAmount,
        uint256 totalImpactGenerated,
        uint256 totalRewards,
        uint256 numberOfStakers
    ) {
        numberOfProjects = projectCount;
        
        // Count active projects
        for (uint256 i = 0; i < allProjectIds.length; i++) {
            if (projectStateData[allProjectIds[i]].state == ProjectState.Active) {
                activeProjects++;
            }
        }
        
        totalStakedAmount = totalStaked;
        
        // Sum impact across all projects
        for (uint256 i = 0; i < allProjectIds.length; i++) {
            totalImpactGenerated += totalValidatedImpact[allProjectIds[i]];
        }
        
        totalRewards = totalRewardsClaimed;
        
        // Count unique stakers (approximate using role - not perfect but efficient)
        numberOfStakers = _getRoleMemberCount(STAKER_ROLE);
        
        return (
            numberOfProjects,
            activeProjects,
            totalStakedAmount,
            totalImpactGenerated,
            totalRewards,
            numberOfStakers
        );
    }

    /**
     * @dev Function to check if a project exists
     * @param projectId The ID of the project to check
     * @return bool True if the project exists, false otherwise
     */
    function projectExists(uint256 projectId) external view returns (bool) {
        return projectMetadata[projectId].exists;
    }
    
    // Helper function to efficiently get count of role members
    function _getRoleMemberCount(bytes32 role) internal view returns (uint256) {
        return getRoleMemberCount(role);
    }
    
    // ====================================================
    // 🔹 External Configuration Functions
    // ====================================================
    
    function updateCategoryInfo(
        ProjectCategory category,
        string calldata name,
        string calldata description,
        string[] calldata standardBodies,
        string[] calldata metricUnits,
        string calldata verificationStandard,
        uint8 impactWeight,
        string[] calldata keyMetrics,
        string calldata esgFocus
    ) external onlyRole(GOVERNANCE_ROLE) {
        // Validate impact weight
        if (impactWeight == 0 || impactWeight > 100) revert InvalidImpactWeight();
        
        // Update category info
        categoryInfo[category] = CategoryInfo({
            name: name,
            description: description,
            standardBodies: standardBodies,
            metricUnits: metricUnits,
            verificationStandard: verificationStandard,
            impactWeight: impactWeight,
            keyMetrics: keyMetrics,
            esgFocus: esgFocus
        });
        
        emit CategoryInfoUpdated(category, name, impactWeight);
    }
    
    // ====================================================
    // 🔹 Analytics & Reporting Functions
    // ====================================================
    
    function getUserAnalytics(
        address user
    ) external view returns (
        uint256 userTotalStaked,
        uint256 userTotalRewardsClaimed,
        uint256 projectsStaked,
        uint256 averageStakePerProject
    ) {
        userTotalStaked = totalStakedByUser[user];
        userTotalRewardsClaimed = userRewardsClaimed[user];
        
        // Count projects with active stakes
        for (uint256 i = 0; i < allProjectIds.length; i++) {
            uint256 projectId = allProjectIds[i];
            if (userStakes[user][projectId] > 0) {
                projectsStaked++;
            }
        }
        
        // Calculate average stake per project
        averageStakePerProject = projectsStaked > 0 ? userTotalStaked / projectsStaked : 0;
        
        return (
            userTotalStaked,
            userTotalRewardsClaimed,
            projectsStaked,
            averageStakePerProject
        );
    }
    
    // Function to get fee analytics
    function getFeeAnalytics() external view onlyRole(TREASURY_ROLE) returns (
        uint256 totalFees,
        uint256 projectSubmissionFees,
        uint256 impactReportingFees,
        uint256 verificationFees,
        uint256 categoryChangeFees,
        uint256 feesWithdrawn,
        uint256 feesAvailable
    ) {
        totalFees = totalFeesCollected;
        projectSubmissionFees = feesByType[FeeType.ProjectSubmission];
        impactReportingFees = feesByType[FeeType.ImpactReporting];
        verificationFees = feesByType[FeeType.Verification];
        categoryChangeFees = feesByType[FeeType.CategoryChange];
        feesWithdrawn = totalFeesWithdrawn;
        feesAvailable = totalFees - feesWithdrawn;
        
        return (
            totalFees,
            projectSubmissionFees,
            impactReportingFees,
            verificationFees,
            categoryChangeFees,
            feesWithdrawn,
            feesAvailable
        );
    }
}
