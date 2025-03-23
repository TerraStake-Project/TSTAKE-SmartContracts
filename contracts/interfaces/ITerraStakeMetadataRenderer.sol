// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

/**
 * @title ITerraStakeMetadataRenderer
 * @notice Interface for generating dynamic SVG visualizations for Impact NFTs
 */
interface ITerraStakeMetadataRenderer {
    /**
     * @notice Generate metadata for an NFT
     * @param tokenId NFT token ID
     * @param impactCategory Impact category (0=Carbon, 1=Water, etc)
     * @param impactValue Numeric value of the impact
     * @param projectName Name of the impact project
     * @param projectDescription Description of the impact project
     * @return Full JSON metadata including SVG
     */
    function generateMetadata(
        uint256 tokenId,
        uint8 impactCategory,
        uint256 impactValue,
        string memory projectName,
        string memory projectDescription
    ) external view returns (string memory);
    
    /**
     * @notice Get just the SVG for a given token (gas optimized)
     * @param tokenId NFT token ID
     * @param impactCategory Impact category
     * @param impactValue Numeric impact value
     * @return SVG string
     */
    function generateSVG(
        uint256 tokenId,
        uint8 impactCategory,
        uint256 impactValue
    ) external view returns (string memory);
    
    /**
     * @notice Generate metadata with interactive elements if enabled
     * @param tokenId NFT token ID
     * @param impactCategory Impact category
     * @param impactValue Numeric impact value
     * @param projectName Project name
     * @param projectDescription Project description
     * @return Full JSON metadata
     */
    function generateInteractiveMetadata(
        uint256 tokenId,
        uint8 impactCategory,
        uint256 impactValue,
        string memory projectName,
        string memory projectDescription
    ) external view returns (string memory);
    
    /**
     * @notice Chunk-based string processing for very large SVGs
     * @param tokenId NFT token ID
     * @param impactCategory Impact category
     * @param impactValue Numeric impact value
     * @return Chunked SVG processing result to avoid gas limits
     */
    function generateLargeSVG(
        uint256 tokenId,
        uint8 impactCategory,
        uint256 impactValue
    ) external view returns (string memory);
    
    /**
     * @notice Generate enhanced metadata including project verification and oracle data
     * @param tokenId NFT token ID
     * @param impactCategory Impact category
     * @param impactValue Numeric impact value
     * @param projectId Project ID
     * @param reportId Report ID
     * @param verificationStatus Whether the impact has been verified
     * @param oracleData Additional data from Chainlink oracle
     * @return Full JSON metadata with extended information
     */
    function generateEnhancedMetadata(
        uint256 tokenId,
        uint8 impactCategory,
        uint256 impactValue,
        uint256 projectId,
        uint256 reportId,
        bool verificationStatus,
        bytes memory oracleData
    ) external view returns (string memory);
    
    /**
     * @notice Generate dynamic SVG with real-time oracle data visualization
     * @param tokenId NFT token ID
     * @param impactCategory Impact category
     * @param impactValue Numeric impact value
     * @param oracleData Oracle data for dynamic visualization
     * @return SVG string with dynamic elements
     */
    function generateDynamicSVG(
        uint256 tokenId,
        uint8 impactCategory,
        uint256 impactValue,
        bytes memory oracleData
    ) external view returns (string memory);

    /**
     * @notice Toggle interactive mode for SVGs
     * @param enabled Whether interactive mode should be enabled
     */
    function setInteractiveMode(bool enabled) external;
    
    /**
     * @notice Set interactive elements for a category
     * @param category Impact category ID
     * @param elements SVG elements with interactive features
     */
    function setInteractiveElements(uint8 category, string calldata elements) external;
    
    /**
     * @notice Set color palette for a category
     * @param category Impact category ID
     * @param primaryColor Primary color in hex format
     * @param secondaryColor Secondary color in hex format
     */
    function setCategoryColors(
        uint8 category,
        string calldata primaryColor,
        string calldata secondaryColor
    ) external;
    
    /**
     * @notice Set icon for a category
     * @param category Impact category ID
     * @param svgPath SVG path data for the icon
     */
    function setCategoryIcon(uint8 category, string calldata svgPath) external;
    
    /**
     * @notice Set name for a category
     * @param category Impact category ID
     * @param name Category name
     */
    function setCategoryName(uint8 category, string calldata name) external;
    
    /**
     * @notice Set scaling factor for impact visualization
     * @param category Impact category ID
     * @param scalingFactor Factor to divide impact value by for visualization
     */
    function setCategoryScalingFactor(uint8 category, uint256 scalingFactor) external;
    
    /**
     * @notice Set animation for a category
     * @param category Impact category ID
     * @param animationSvg SVG animation element
     */
    function setCategoryAnimation(uint8 category, string calldata animationSvg) external;
    
    /**
     * @notice Set visualization size limits
     * @param minSize Minimum size for impact visualization
     * @param maxSize Maximum size for impact visualization
     */
    function setVisualizationSizeLimits(uint256 minSize, uint256 maxSize) external;
    
    /**
     * @notice Set the maximum scaling factor allowed
     * @param maxScalingFactor Maximum value for scaling factors
     */
    function setMaxScalingFactor(uint256 maxScalingFactor) external;
    
    /**
     * @notice Update the entire SVG template
     * @param newTemplate New SVG template with placeholders
     */
    function updateSVGTemplate(string calldata newTemplate) external;
    
    /**
     * @notice Set project-specific template
     * @param projectId Project ID
     * @param template Custom SVG template for this project
     */
    function setProjectTemplate(uint256 projectId, string calldata template) external;
    
    /**
     * @notice Set visualization for oracle data
     * @param dataType Oracle data type identifier
     * @param visualization SVG elements for visualizing this data type
     */
    function setOracleDataVisualization(bytes32 dataType, string calldata visualization) external;
    
    /**
     * @notice Set verification badge visualization
     * @param verifiedBadge SVG for verified content
     * @param unverifiedBadge SVG for unverified content
     */
    function setVerificationBadges(string calldata verifiedBadge, string calldata unverifiedBadge) external;
    
    /**
     * @notice Batch configuration of multiple categories
     * @param categories Array of category IDs
     * @param names Array of category names
     * @param primaryColors Array of primary colors
     * @param secondaryColors Array of secondary colors
     * @param icons Array of icon SVG paths
     * @param scalingFactors Array of scaling factors
     */
    function batchConfigureCategories(
        uint8[] calldata categories,
        string[] calldata names,
        string[] calldata primaryColors,
        string[] calldata secondaryColors,
        string[] calldata icons,
        uint256[] calldata scalingFactors
    ) external;
    
    /**
     * @notice Get the current size limits for impact visualization
     * @return minSize Minimum size for impact visualization
     * @return maxSize Maximum size for impact visualization
     */
    function getVisualizationSizeLimits() external view returns (uint256 minSize, uint256 maxSize);
    
    /**
     * @notice Get category details
     * @param category Category ID
     * @return name Category name
     * @return primaryColor Primary color
     * @return secondaryColor Secondary color
     * @return icon SVG path data
     * @return scalingFactor Impact scaling factor
     */
    function getCategoryDetails(uint8 category)
        external
        view
        returns (
            string memory name,
            string memory primaryColor,
            string memory secondaryColor,
            string memory icon,
            uint256 scalingFactor
        );
    
    /**
     * @notice Get project template
     * @param projectId Project ID
     * @return template Custom SVG template for this project
     */
    function getProjectTemplate(uint256 projectId) external view returns (string memory template);
    
    /**
     * @notice Get oracle data visualization 
     * @param dataType Oracle data type identifier
     * @return visualization SVG elements for visualizing this data type
     */
    function getOracleDataVisualization(bytes32 dataType) external view returns (string memory visualization);
    
    /**
     * @notice Set projects contract address
     * @param projectsContract Address of the TerraStakeProjects contract
     */
    function setProjectsContract(address projectsContract) external;
    
    /**
     * @notice Set formatter for specific oracle data types
     * @param dataType Oracle data type
     * @param format Format string for this data type
     * @param units Units string for this data type
     */
    function setOracleDataFormat(bytes32 dataType, string calldata format, string calldata units) external;

    // Events
    event CategoryColorsUpdated(uint8 indexed category, string primaryColor, string secondaryColor);
    event CategoryIconUpdated(uint8 indexed category, string svgPath);
    event CategoryNameUpdated(uint8 indexed category, string name);
    event ScalingFactorUpdated(uint8 indexed category, uint256 factor);
    event MaxScalingFactorUpdated(uint256 maxFactor);
    event AnimationUpdated(uint8 indexed category, string animation);
    event SizeLimitsUpdated(uint256 minSize, uint256 maxSize);
    event TemplateUpdated();
    event CategoryConfigured(
        uint8 indexed category,
        string name,
        string primaryColor,
        string secondaryColor,
        string icon,
        uint256 scalingFactor
    );
    event InteractiveModeSet(bool enabled);
    event InteractiveElementsSet(uint8 indexed category, string elements);
    
    // New events
    event ProjectTemplateSet(uint256 indexed projectId, string templateHash);
    event OracleDataVisualizationSet(bytes32 indexed dataType, string visualizationHash);
    event VerificationBadgesSet(string verifiedBadgeHash, string unverifiedBadgeHash);
    event ProjectsContractSet(address projectsContract);
    event OracleDataFormatSet(bytes32 indexed dataType, string format, string units);
}
