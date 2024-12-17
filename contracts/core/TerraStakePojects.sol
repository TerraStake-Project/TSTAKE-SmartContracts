// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "../interfaces/ITerraStakeProjects.sol";

contract TerraStakeProjects is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, ITerraStakeProjects {
    // Role Definitions
    bytes32 public constant PROJECT_MANAGER_ROLE = keccak256("PROJECT_MANAGER_ROLE");

    // Storage
    mapping(uint256 => ProjectData) private projectMetadata;
    mapping(uint256 => GeneralMetadata) private generalMetadataMapping;
    mapping(uint256 => ProjectStateData) private projectStateData;
    mapping(ProjectCategory => ImpactRequirement) private categoryRequirements;
    uint256 private projectCount;

    function initialize(address admin, address /*rewardToken*/) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PROJECT_MANAGER_ROLE, admin);
    }

    // Add Oracle to a project
    function addOracle(uint256 projectId, address oracle) external override onlyRole(PROJECT_MANAGER_ROLE) {
        require(projectMetadata[projectId].exists, "Project does not exist");
        emit ContractsSet(address(this), oracle);
    }

    // Set General Metadata for a project
    function setGeneralMetadata(uint256 projectId, GeneralMetadata calldata metadata) external override onlyRole(PROJECT_MANAGER_ROLE) {
        require(projectMetadata[projectId].exists, "Project does not exist");
        generalMetadataMapping[projectId] = metadata;
    }

    // Report metrics for a project
    function reportMetric(
        uint256 projectId,
        string calldata metricType,
        string calldata metricValue
    ) external override onlyRole(PROJECT_MANAGER_ROLE) {
        require(projectMetadata[projectId].exists, "Project does not exist");
        emit MetricsReported(projectId, metricType, metricValue);
    }

    // Update Fee Structure
    function updateFeeStructure(
        uint256 registrationFee,
        uint256 categoryChangeFee,
        uint256 verificationFee
    ) external override onlyRole(PROJECT_MANAGER_ROLE) {
        emit FeeStructureUpdated(registrationFee, verificationFee, categoryChangeFee);
    }

    // Update Project State
    function updateProjectState(uint256 projectId, ProjectState newState) external override onlyRole(PROJECT_MANAGER_ROLE) {
        require(projectMetadata[projectId].exists, "Project does not exist");
        ProjectStateData storage stateData = projectStateData[projectId];
        ProjectState oldState = stateData.state;
        stateData.state = newState;
        emit ProjectStateChanged(projectId, oldState, newState);
    }

    // Update Project Documentation
    function updateProjectDocumentation(uint256 projectId, bytes32[] calldata documentHashes)
        external
        override
        onlyRole(PROJECT_MANAGER_ROLE)
    {
        require(projectMetadata[projectId].exists, "Project does not exist");
        emit DocumentationUpdated(projectId, documentHashes);
    }

    // Set Impact Requirement
    function setImpactRequirement(
        ProjectCategory category,
        uint256 minimumImpact,
        uint256 verificationFrequency,
        string[] calldata requiredDocuments,
        uint256 qualityThreshold,
        uint256 minimumScale
    ) external override onlyRole(PROJECT_MANAGER_ROLE) {
        categoryRequirements[category] = ImpactRequirement({
            minimumImpact: minimumImpact,
            verificationFrequency: verificationFrequency,
            requiredDocuments: requiredDocuments,
            qualityThreshold: qualityThreshold,
            minimumScale: minimumScale
        });
        emit ImpactRequirementUpdated(category, minimumImpact);
    }

    // View Functions
    function getCategoryRequirements(ProjectCategory category)
        external
        view
        override
        returns (ImpactRequirement memory)
    {
        return categoryRequirements[category];
    }

    function getGeneralMetadata(uint256 projectId) external view override returns (GeneralMetadata memory) {
        return generalMetadataMapping[projectId];
    }

    function getProjectCount() external view override returns (uint256) {
        return projectCount;
    }

    function getProjectDetails(uint256 projectId) external view override returns (ProjectData memory) {
        require(projectMetadata[projectId].exists, "Project does not exist");
        return projectMetadata[projectId];
    }

    function getProjectState(uint256 projectId) external view override returns (ProjectStateData memory) {
        require(projectMetadata[projectId].exists, "Project does not exist");
        return projectStateData[projectId];
    }

    // Stub functions from the interface
    function addProject(
        string calldata /*name*/,
        string calldata /*description*/,
        string calldata /*location*/,
        string calldata /*impactMetrics*/,
        bytes32 /*ipfsHash*/,
        ProjectCategory /*category*/,
        uint32 /*stakingMultiplier*/,
        uint48 /*startBlock*/,
        uint48 /*endBlock*/
    ) external payable override {
        // Not implemented
    }

    function validateProjectImpact(
        uint256 /*projectId*/,
        uint256 /*impactValue*/,
        uint256 /*dataQuality*/,
        uint256 /*projectScale*/
    ) external override {
        // Not implemented
    }

    function updateProject(
        uint256 /*projectId*/,
        string calldata /*name*/,
        string calldata /*description*/,
        string calldata /*location*/,
        string calldata /*impactMetrics*/,
        bytes32 /*ipfsHash*/
    ) external override {
        // Not implemented
    }

    function setCategoryMultiplier(ProjectCategory /*category*/, uint256 /*multiplier*/) external override {
        // Not implemented
    }

    function getProjectsByCategory(ProjectCategory /*category*/) external pure override returns (uint256[] memory) {
        // returns empty array, no state read
        uint256[] memory emptyArray = new uint256[](0);
        return emptyArray;
    }

    function getCategoryMultiplier(ProjectCategory /*category*/) external pure override returns (uint256) {
        // returns 0, no state read
        return 0;
    }

    function isProjectActive(uint256 /*projectId*/) external pure override returns (bool) {
        // returns false, no state read
        return false;
    }
}
