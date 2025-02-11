// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "../interfaces/ITerraStakeProjects.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TerraStakeProjects
 * @notice Manages projects within the TerraStake ecosystem.
 *
 * Projects can be added, updated, and managed through various functions:
 * - Project managers can add projects, update states and documentation,
 *   submit validation and verification reports, and add comments.
 * - Stakers can stake and unstake funds.
 * - Chainlink data can be used to update project metrics.
 * - Impact requirements are enforced before a project may become active.
 * - IPFS integration is provided by storing raw IPFS CID multi‑hashes for project documents.
 */
contract TerraStakeProjects is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, ITerraStakeProjects {
    // ====================================================
    // Custom Errors
    // ====================================================
    error UnauthorizedAccess();
    error InvalidProjectId();
    error ProjectNotActive();
    error InvalidStringLength();
    error InvalidStateTransition();
    error InvalidIpfsHash();
    error InvalidMultiplier();
    error InvalidValidation();
    error InvalidVerification();
    error InvalidMetadata();
    error AlreadySubmitted();
    error InvalidMinimumScale();
    error InvalidStakingAmount();
    error RewardDistributionFailed();
    error InsufficientRewardPool();
    error ImpactRequirementsNotMet();

    // ====================================================
    // Roles
    // ====================================================
    bytes32 public constant PROJECT_MANAGER_ROLE = keccak256("PROJECT_MANAGER_ROLE");
    bytes32 public constant CHAINLINK_FEEDER_ROLE = keccak256("CHAINLINK_FEEDER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant STAKER_ROLE = keccak256("STAKER_ROLE");

    // ====================================================
    // External Contracts
    // ====================================================
    // Address of the Chainlink feeder contract.
    address public immutable chainlinkFeeder;
    // TSTAKE token contract.
    IERC20 public tStakeToken;

    // ====================================================
    // State Variables
    // ====================================================
    uint256 public projectCount;
    uint256 public registrationFee;
    uint256 public verificationFee;
    uint256 public categoryChangeFee;

    // Mapping for basic project metadata.
    mapping(uint256 => ProjectData) public projectMetadata;
    // Mapping for detailed project state.
    mapping(uint256 => ProjectStateData) public projectStateData;
    // Mapping from project category to impact requirements.
    mapping(ProjectCategory => ImpactRequirement) public impactRequirements;
    // Mapping for validation data.
    mapping(uint256 => ValidationData) public projectValidations;
    // Mapping for verification data.
    mapping(uint256 => VerificationData) public projectVerifications;
    // Mapping for general metadata.
    mapping(uint256 => GeneralMetadata) public projectMetadataDetails;
    // Mapping for comments.
    mapping(uint256 => Comment[]) public projectComments;
    // Mapping for staking amounts.
    mapping(uint256 => mapping(address => uint256)) public projectStakes;
    // Mapping for IPFS document CIDs (raw bytes) per project.
    mapping(uint256 => bytes[]) public projectDocumentCIDs;

    // ====================================================
    // Modifiers
    // ====================================================
    modifier validProjectId(uint256 projectId) {
        if (!projectMetadata[projectId].exists) revert InvalidProjectId();
        _;
    }

    // ====================================================
    // Initialization Function
    // ====================================================
    /**
     * @notice Initializes the TerraStakeProjects contract.
     * @param admin The administrator address.
     * @param _tstakeToken The TSTAKE token address.
     */
    function initialize(address admin, address _tstakeToken) external override initializer {
        require(admin != address(0), "Invalid admin address");
        require(_tstakeToken != address(0), "Invalid TSTAKE token address");

        __AccessControl_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PROJECT_MANAGER_ROLE, admin);
        _grantRole(CHAINLINK_FEEDER_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(STAKER_ROLE, admin);

        tStakeToken = IERC20(_tstakeToken);
        emit Initialized(admin, _tstakeToken);
    }

    // ====================================================
    // Project Management Functions
    // ====================================================
    /**
     * @notice Adds a new project.
     * @param name The project name.
     * @param description The project description.
     * @param location The project location.
     * @param impactMetrics Impact metrics as a string.
     * @param ipfsHash A legacy IPFS hash.
     * @param category The project category.
     * @param stakingMultiplier The staking multiplier.
     * @param startBlock The starting block number.
     * @param endBlock The ending block number.
     */
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
    ) external override onlyRole(PROJECT_MANAGER_ROLE) {
        require(bytes(name).length > 0, "Name required");
        require(ipfsHash != bytes32(0), "Invalid IPFS hash");
        require(endBlock > startBlock, "End block must be after start");
        require(stakingMultiplier > 0, "Invalid multiplier");

        uint256 newProjectId = projectCount;
        projectCount++;

        projectMetadata[newProjectId] = ProjectData({
            name: name,
            description: description,
            location: location,
            impactMetrics: impactMetrics,
            ipfsHash: ipfsHash,
            exists: true
        });

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

        emit ProjectAdded(newProjectId, name, category);
    }

    /**
     * @notice Updates the state of a project.
     *
     * When setting the state to Active, the function enforces that the project meets its
     * impact requirements: the last reported value must be high enough, a recent verification must exist,
     * all required documents must be uploaded, and total staked must meet the minimum scale.
     *
     * @param projectId The project ID.
     * @param newState The new project state.
     */
    function updateProjectState(uint256 projectId, ProjectState newState) external override validProjectId(projectId) {
        require(hasRole(PROJECT_MANAGER_ROLE, msg.sender) || hasRole(GOVERNANCE_ROLE, msg.sender), "Not authorized");

        ProjectStateData storage stateData = projectStateData[projectId];
        ProjectState oldState = stateData.state;

        // If transitioning to Active, enforce impact requirements.
        if (newState == ProjectState.Active) {
            // Check impact requirements, including required documents.
            if (!meetsImpactRequirements(projectId)) {
                revert ImpactRequirementsNotMet();
            }
        }

        stateData.state = newState;
        stateData.isActive = (newState == ProjectState.Active);

        emit ProjectStateChanged(projectId, oldState, newState);
    }

    /**
     * @notice Updates project documentation using legacy document hashes.
     * @param projectId The project ID.
     * @param documentHashes An array of document hashes.
     */
    function updateProjectDocumentation(uint256 projectId, bytes32[] calldata documentHashes) external override onlyRole(PROJECT_MANAGER_ROLE) validProjectId(projectId) {
        bytes memory combined;
        for (uint256 i = 0; i < documentHashes.length; i++) {
            combined = abi.encodePacked(combined, toHexString(documentHashes[i]), i < documentHashes.length - 1 ? "," : "");
        }
        GeneralMetadata storage meta = projectMetadataDetails[projectId];
        meta.complianceDocumentation = string(combined);
        emit DocumentationUpdated(projectId, documentHashes);
    }

    /**
     * @notice Adds an IPFS document for the project by storing the raw CID bytes.
     * @param projectId The project ID.
     * @param cid The raw IPFS CID bytes.
     * @return index The index where the CID is stored.
     */
    function addProjectDocument(uint256 projectId, bytes calldata cid) external onlyRole(PROJECT_MANAGER_ROLE) validProjectId(projectId) returns (uint256 index) {
        require(cid.length > 0, "Invalid CID");
        projectDocumentCIDs[projectId].push(cid);
        index = projectDocumentCIDs[projectId].length - 1;
        emit DocumentAdded(projectId, cid);
    }

    /**
     * @notice Submits a validation report for a project.
     * @param projectId The project ID.
     * @param reportHash The hash of the validation report.
     */
    function submitValidation(uint256 projectId, bytes32 reportHash) external override validProjectId(projectId) {
        projectValidations[projectId] = ValidationData({
            vvb: msg.sender,
            validationDate: block.timestamp,
            validationReportHash: reportHash
        });
        emit ValidationSubmitted(projectId, msg.sender, reportHash);
    }

    /**
     * @notice Submits a verification report for a project.
     * @param projectId The project ID.
     * @param reportHash The hash of the verification report.
     */
    function submitVerification(uint256 projectId, bytes32 reportHash) external override validProjectId(projectId) {
        projectVerifications[projectId] = VerificationData({
            vvb: msg.sender,
            verificationDate: block.timestamp,
            verificationReportHash: reportHash
        });
        emit VerificationSubmitted(projectId, msg.sender, reportHash);
    }

    /**
     * @notice Reports a metric for a project.
     * @param projectId The project ID.
     * @param metricType The metric type.
     * @param metricValue The metric value.
     */
    function reportMetric(uint256 projectId, string calldata metricType, string calldata metricValue) external override validProjectId(projectId) {
        emit MetricsReported(projectId, metricType, metricValue);
    }

    /**
     * @notice Updates project data from Chainlink.
     * @param projectId The project ID.
     * @param dataValue The new data value.
     */
    function updateProjectDataFromChainlink(uint256 projectId, int256 dataValue)
        external
        override
        validProjectId(projectId)
        onlyRole(CHAINLINK_FEEDER_ROLE)
    {
        if (!projectStateData[projectId].isActive) revert ProjectNotActive();
        projectStateData[projectId].lastReportedValue = dataValue;
        emit ProjectDataUpdated(projectId, dataValue);
    }

    // ====================================================
    // Governance Functions
    // ====================================================
    /**
     * @notice Sets the staking multiplier for a project category.
     * @param category The project category.
     * @param multiplier The new multiplier.
     */
    function setCategoryMultiplier(ProjectCategory category, uint256 multiplier) external override onlyRole(GOVERNANCE_ROLE) {
        require(multiplier > 0, "Invalid multiplier");
        impactRequirements[category].qualityThreshold = multiplier; // Example: update qualityThreshold
        emit CategoryMultiplierUpdated(category, multiplier);
    }

    /**
     * @notice Sets impact requirements for a project category.
     * @param category The project category.
     * @param minimumImpact The minimum required impact.
     * @param verificationFrequency Maximum allowed time (in seconds) since last verification.
     * @param requiredDocuments The required document identifiers.
     * @param qualityThreshold The quality threshold.
     * @param minimumScale The minimum required staked amount.
     */
    function setImpactRequirement(
        ProjectCategory category,
        uint256 minimumImpact,
        uint256 verificationFrequency,
        string[] calldata requiredDocuments,
        uint256 qualityThreshold,
        uint256 minimumScale
    ) external override onlyRole(GOVERNANCE_ROLE) {
        impactRequirements[category] = ImpactRequirement({
            minimumImpact: minimumImpact,
            verificationFrequency: verificationFrequency,
            requiredDocuments: requiredDocuments,
            qualityThreshold: qualityThreshold,
            minimumScale: minimumScale
        });
        emit ImpactRequirementUpdated(category, minimumImpact);
    }

    /**
     * @notice Updates fee structure parameters.
     * @param _registrationFee The new registration fee.
     * @param _categoryChangeFee The new fee for category changes.
     * @param _verificationFee The new verification fee.
     */
    function updateFeeStructure(uint256 _registrationFee, uint256 _categoryChangeFee, uint256 _verificationFee)
        external
        override
        onlyRole(GOVERNANCE_ROLE)
    {
        registrationFee = _registrationFee;
        categoryChangeFee = _categoryChangeFee;
        verificationFee = _verificationFee;
        emit FeeStructureUpdated(_registrationFee, _categoryChangeFee, _verificationFee);
    }

    /**
     * @notice Adds a comment to a project.
     * @param projectId The project ID.
     * @param message The comment message.
     */
    function addComment(uint256 projectId, string calldata message) external override validProjectId(projectId) {
        Comment memory newComment = Comment({
            commenter: msg.sender,
            message: message,
            timestamp: block.timestamp
        });
        projectComments[projectId].push(newComment);
        emit CommentAdded(projectId, msg.sender, message);
    }

    // ====================================================
    // ImpactRequirement Checker
    // ====================================================
    /**
     * @notice Checks whether a project meets its impact requirements.
     * Requirements:
     * - lastReportedValue must be at least minimumImpact and qualityThreshold.
     * - If verificationFrequency > 0, a verification report must exist and be recent.
     * - The number of stored IPFS documents must be at least equal to the required documents count.
     * - totalStaked must be at least minimumScale.
     * @param projectId The project ID.
     * @return meets True if requirements are met, false otherwise.
     */
    function meetsImpactRequirements(uint256 projectId) public view validProjectId(projectId) returns (bool meets) {
        ProjectStateData memory state = projectStateData[projectId];
        ImpactRequirement memory req = impactRequirements[state.category];

        // Check that lastReportedValue meets both minimumImpact and qualityThreshold.
        if (uint256(state.lastReportedValue) < req.minimumImpact) return false;
        if (uint256(state.lastReportedValue) < req.qualityThreshold) return false;

        // Enforce verificationFrequency: if set, ensure a recent verification report exists.
        VerificationData memory verif = projectVerifications[projectId];
        if (req.verificationFrequency > 0) {
            if (verif.verificationDate == 0 || (block.timestamp - verif.verificationDate) > req.verificationFrequency) {
                return false;
            }
        }

        // Ensure required documents have been uploaded.
        if (projectDocumentCIDs[projectId].length < req.requiredDocuments.length) return false;

        // Check that total staked meets minimumScale.
        if (state.totalStaked < req.minimumScale) return false;

        return true;
    }

    // ====================================================
    // View Functions
    // ====================================================
    /**
     * @notice Returns the basic details of a project.
     * @param projectId The project ID.
     * @return The project data.
     */
    function getProjectDetails(uint256 projectId) external view override validProjectId(projectId) returns (ProjectData memory) {
        return projectMetadata[projectId];
    }

    /**
     * @notice Returns the state data of a project.
     * @param projectId The project ID.
     * @return The project state data.
     */
    function getProjectState(uint256 projectId) external view override validProjectId(projectId) returns (ProjectStateData memory) {
        return projectStateData[projectId];
    }

    /**
     * @notice Returns impact requirements for a project category.
     * @param category The project category.
     * @return The impact requirement.
     */
    function getCategoryRequirements(ProjectCategory category) external view override returns (ImpactRequirement memory) {
        return impactRequirements[category];
    }

    /**
     * @notice Returns the validation report for a project.
     * @param projectId The project ID.
     * @return The validation data.
     */
    function getValidationReport(uint256 projectId) external view override validProjectId(projectId) returns (ValidationData memory) {
        return projectValidations[projectId];
    }

    /**
     * @notice Returns the verification report for a project.
     * @param projectId The project ID.
     * @return The verification data.
     */
    function getVerificationReport(uint256 projectId) external view override validProjectId(projectId) returns (VerificationData memory) {
        return projectVerifications[projectId];
    }

    /**
     * @notice Checks if a project is active.
     * @param projectId The project ID.
     * @return True if the project is active, false otherwise.
     */
    function isProjectActive(uint256 projectId) external view override validProjectId(projectId) returns (bool) {
        return projectStateData[projectId].isActive;
    }

    /**
     * @notice Returns the total number of projects.
     * @return The project count.
     */
    function getProjectCount() external view override returns (uint256) {
        return projectCount;
    }

    /**
     * @notice Returns all comments for a project.
     * @param projectId The project ID.
     * @return messages An array of comment messages.
     * @return commenters An array of commenter addresses.
     * @return timestamps An array of timestamps.
     */
    function getComments(uint256 projectId)
        external
        view
        override
        validProjectId(projectId)
        returns (string[] memory messages, address[] memory commenters, uint256[] memory timestamps)
    {
        uint256 len = projectComments[projectId].length;
        messages = new string[](len);
        commenters = new address[](len);
        timestamps = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            Comment storage c = projectComments[projectId][i];
            messages[i] = c.message;
            commenters[i] = c.commenter;
            timestamps[i] = c.timestamp;
        }
        return (messages, commenters, timestamps);
    }

    /**
     * @notice Returns the general metadata for a project.
     * @param projectId The project ID.
     * @return The general metadata.
     */
    function getGeneralMetadata(uint256 projectId) external view override validProjectId(projectId) returns (GeneralMetadata memory) {
        return projectMetadataDetails[projectId];
    }

    /**
     * @notice Sets the general metadata for a project.
     * @param projectId The project ID.
     * @param data The new general metadata.
     */
    function setGeneralMetadata(uint256 projectId, GeneralMetadata calldata data) external override onlyRole(PROJECT_MANAGER_ROLE) validProjectId(projectId) {
        projectMetadataDetails[projectId] = data;
    }

    /**
     * @notice Returns the raw IPFS document CIDs for a project.
     * @param projectId The project ID.
     * @return cids An array of raw IPFS CID bytes.
     */
    function getProjectDocuments(uint256 projectId) external view returns (bytes[] memory cids) {
        return projectDocumentCIDs[projectId];
    }

    // ====================================================
    // Helper Function: Convert bytes32 to Hex String.
    // ====================================================
    function toHexString(bytes32 data) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(64);
        for (uint256 i = 0; i < 32; i++) {
            str[i * 2] = alphabet[uint8(data[i] >> 4)];
            str[i * 2 + 1] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }
}