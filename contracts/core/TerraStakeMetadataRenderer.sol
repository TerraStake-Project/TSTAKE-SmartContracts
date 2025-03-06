// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Base64Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/Base64Upgradeable.sol";
import {StringsUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/StringsUpgradeable.sol";
import "./interfaces/ITerraStakeMetadataRenderer.sol";

/**
 * @title TerraStakeMetadataRenderer (Enhanced)
 * @notice Generates dynamic SVG visualizations for Impact NFTs with gas optimizations
 * @dev Uses UUPS pattern for upgradeability
 */
contract TerraStakeMetadataRenderer is 
    Initializable, 
    AccessControlUpgradeable, 
    UUPSUpgradeable,
    ITerraStakeMetadataRenderer 
{
    using StringsUpgradeable for uint256;
    
    bytes32 public constant PROJECTS_CONTRACT_ROLE = keccak256("PROJECTS_CONTRACT_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant DESIGNER_ROLE = keccak256("DESIGNER_ROLE");
    
    // Color palettes for different categories (primary,secondary)
    mapping(uint8 => string) private _categoryColors;
    
    // Category icons (stored as SVG paths)
    mapping(uint8 => string) private _categoryIcons;
    
    // Category names for better representation
    mapping(uint8 => string) private _categoryNames;
    
    // SVG templates with placeholders for gas optimization
    string private _svgTemplate;
    
    // Scaling factors for different categories
    mapping(uint8 => uint256) private _categoryScalingFactors;
    
    // Animation styles for different categories
    mapping(uint8 => string) private _categoryAnimations;
    
    // Configuration for visualization sizing
    uint256 private _minSize;
    uint256 private _maxSize;
    uint256 private _maxScalingFactor;
    
    // Interactive mode flag
    bool private _interactiveMode = false;
    
    // Additional interactive elements
    mapping(uint8 => string) private _interactiveElements;
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @notice Initializes the contract with an admin and default visual elements
     * @param admin Address that will have administrative rights
     */
    function initialize(address admin) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(DESIGNER_ROLE, admin);
        
        // Initialize default color palettes
        _categoryColors[0] = "#3CB371,#90EE90"; // Carbon Credit - Green
        _categoryColors[1] = "#4682B4,#87CEEB"; // Water Conservation - Blue
        _categoryColors[2] = "#CD853F,#F4A460"; // Reforestation - Brown
        _categoryColors[3] = "#FFD700,#FFFFE0"; // Renewable Energy - Yellow
        _categoryColors[4] = "#9370DB,#E6E6FA"; // Biodiversity - Purple
        
        // Initialize default icons
        _categoryIcons[0] = "M10,30 Q50,10 90,30 Q50,50 10,30"; // Carbon Credit
        _categoryIcons[1] = "M20,20 Q50,60 80,20 M30,30 Q50,70 70,30"; // Water
        _categoryIcons[2] = "M50,10 L40,40 L60,40 Z M50,40 L50,80"; // Tree
        _categoryIcons[3] = "M30,30 L70,30 L70,70 L30,70 Z M50,30 L50,10"; // Solar
        _categoryIcons[4] = "M20,50 Q50,20 80,50 Q50,80 20,50"; // Biodiversity
        
        // Initialize category names
        _categoryNames[0] = "Carbon Credit";
        _categoryNames[1] = "Water Conservation";
        _categoryNames[2] = "Reforestation";
        _categoryNames[3] = "Renewable Energy";
        _categoryNames[4] = "Biodiversity";
        
        // Initialize scaling factors
        _categoryScalingFactors[0] = 10; // 10 kg CO2 = 1 pixel
        _categoryScalingFactors[1] = 100; // 100 L = 1 pixel
        _categoryScalingFactors[2] = 1; // 1 tree = 1 pixel
        _categoryScalingFactors[3] = 1000; // 1 kWh = 1 pixel
        _categoryScalingFactors[4] = 1; // 1 species = 1 pixel
        
        // Initialize animations
        _categoryAnimations[0] = "<animate attributeName='r' values='10;12;10' dur='3s' repeatCount='indefinite'/>";
        _categoryAnimations[1] = "<animate attributeName='opacity' values='0.7;0.9;0.7' dur='2s' repeatCount='indefinite'/>";
        _categoryAnimations[2] = "<animate attributeName='height' values='40;42;40' dur='4s' repeatCount='indefinite'/>";
        _categoryAnimations[3] = "<animate attributeName='stroke-width' values='1;2;1' dur='2s' repeatCount='indefinite'/>";
        _categoryAnimations[4] = "<animate attributeName='d' values='M20,50 Q50,20 80,50 Q50,80 20,50;M20,50 Q50,25 80,50 Q50,75 20,50;M20,50 Q50,20 80,50 Q50,80 20,50' dur='5s' repeatCount='indefinite'/>";
        
        // Initialize sizing limits and max scaling
        _minSize = 10;
        _maxSize = 80;
        _maxScalingFactor = 1000000; // Prevent division by very small numbers
        
        // Initialize SVG template with placeholders for optimization
        _svgTemplate = string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="400" viewBox="0 0 100 100">',
            '<defs><linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%"><stop offset="0%" stop-color="{{PRIMARY_COLOR}}"/><stop offset="100%" stop-color="{{SECONDARY_COLOR}}"/></linearGradient></defs>',
            '<rect width="100" height="100" fill="url(#bg)" rx="5" ry="5"/>',
            '<g id="icon" fill="none" stroke="white" stroke-width="1.5">{{ICON}}</g>',
            '<text x="50" y="20" font-family="Arial" font-size="4" fill="white" text-anchor="middle">{{CATEGORY_NAME}}</text>',
            '<text x="50" y="90" font-family="Arial" font-size="3" fill="white" text-anchor="middle">{{PROJECT_ID}}</text>',
            '<circle cx="50" cy="50" r="{{IMPACT_SIZE}}" fill="white" fill-opacity="0.3">{{ANIMATION}}</circle>',
            '<text x="50" y="52" font-family="Arial" font-size="5" fill="white" text-anchor="middle" font-weight="bold">{{IMPACT_VALUE}}</text>',
            '<text x="50" y="58" font-family="Arial" font-size="2" fill="white" text-anchor="middle">{{IMPACT_UNIT}}</text>',
            '</svg>'
        ));
    }
    
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
    ) 
        external 
        view 
        override 
        returns (string memory) 
    {
        return _generateMetadataInternal(
            tokenId,
            impactCategory,
            impactValue,
            projectName,
            projectDescription,
            false
        );
    }
    
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
    ) 
        external 
        view 
        override 
        returns (string memory) 
    {
        // Get color values
        string memory colorPair = _categoryColors[impactCategory];
        (string memory primaryColor, string memory secondaryColor) = _parseColors(colorPair);
        
        // Calculate impact visualization size
        uint256 scalingFactor = _categoryScalingFactors[impactCategory];
        uint256 visualSize = _calculateVisualSize(impactValue, scalingFactor);
        
        // Get impact unit
        string memory impactUnit = _getImpactUnit(impactCategory);
        
        // Generate and return SVG
        return _generateSVG(
            tokenId,
            impactCategory,
            impactValue,
            visualSize,
            primaryColor,
            secondaryColor,
            impactUnit
        );
    }
    
    // =====================================================
    // Internal Helper Functions - Gas Optimized
    // =====================================================
    
    /**
     * @dev Internal version of generateMetadata to avoid external calls
     */
    function _generateMetadataInternal(
        uint256 tokenId,
        uint8 impactCategory,
        uint256 impactValue,
        string memory projectName,
        string memory projectDescription,
        bool isInteractive
    ) 
        internal 
        view 
        returns (string memory) 
    {
        // Get color values
        string memory colorPair = _categoryColors[impactCategory];
        (string memory primaryColor, string memory secondaryColor) = _parseColors(colorPair);
        
        // Calculate impact visualization size
        uint256 scalingFactor = _categoryScalingFactors[impactCategory];
        uint256 visualSize = _calculateVisualSize(impactValue, scalingFactor);
        
        // Get impact unit
        string memory impactUnit = _getImpactUnit(impactCategory);
        
        // Generate SVG based on interactive mode
        string memory svgImage;
        if (isInteractive && _interactiveMode) {
            svgImage = _generateInteractiveSVG(
                tokenId,
                impactCategory,
                impactValue,
                visualSize,
                primaryColor,
                secondaryColor,
                impactUnit
            );
        } else {
            svgImage = _generateSVG(
                tokenId,
                impactCategory,
                impactValue,
                visualSize,
                primaryColor,
                secondaryColor,
                impactUnit
            );
        }
        
        // Encode SVG as base64
        string memory encodedSVG = Base64Upgradeable.encode(bytes(svgImage));
        
        // Generate attributes with optional interactive trait
        string memory attributes;
        if (isInteractive && _interactiveMode) {
            attributes = string(abi.encodePacked(
                '{"trait_type":"Category","value":"', _categoryNames[impactCategory], '"},',
                '{"trait_type":"', _getImpactAttributeName(impactCategory), '","value":', impactValue.toString(), '},',
                '{"trait_type":"Token ID","value":', tokenId.toString(), '},',
                '{"trait_type":"Interactive","value":"Yes"}'
            ));
        } else {
            attributes = string(abi.encodePacked(
                '{"trait_type":"Category","value":"', _categoryNames[impactCategory], '"},',
                '{"trait_type":"', _getImpactAttributeName(impactCategory), '","value":', impactValue.toString(), '},',
                '{"trait_type":"Token ID","value":', tokenId.toString(), '}'
            ));
        }
        
        // Generate and return full JSON metadata
        return string(abi.encodePacked(
            'data:application/json;base64,',
            Base64Upgradeable.encode(bytes(abi.encodePacked(
                '{"name":"', projectName, ' #', tokenId.toString(), '",',
                '"description":"', projectDescription, '",',
                '"image":"data:image/svg+xml;base64,', encodedSVG, '",',
                '"attributes":[', attributes, ']}'
            )))
        ));
    }
    
    /**
     * @dev Generate SVG by substituting template placeholders
     */
    function _generateSVG(
        uint256 tokenId,
        uint8 category,
        uint256 impactValue,
        uint256 visualSize,
        string memory primaryColor,
        string memory secondaryColor,
        string memory impactUnit
    ) 
        internal 
        view 
        returns (string memory) 
    {
        // Start with template
        string memory svg = _svgTemplate;
        
        // Create an array of replacements to process in a single pass
        string[9] memory placeholders = [
            "{{PRIMARY_COLOR}}",
            "{{SECONDARY_COLOR}}",
            "{{ICON}}",
            "{{CATEGORY_NAME}}",
            "{{PROJECT_ID}}",
            "{{IMPACT_SIZE}}",
            "{{ANIMATION}}",
            "{{IMPACT_VALUE}}",
            "{{IMPACT_UNIT}}"
        ];
        
        string[9] memory replacements = [
            primaryColor,
            secondaryColor,
            _categoryIcons[category],
            _categoryNames[category],
            string(abi.encodePacked("Token #", tokenId.toString()
            primaryColor,
            secondaryColor,
            _categoryIcons[category],
            _categoryNames[category],
            string(abi.encodePacked("Token #", tokenId.toString())),
            visualSize.toString(),
            _categoryAnimations[category],
            impactValue.toString(),
            impactUnit
        ];
        
        // Apply all replacements efficiently
        for (uint256 i = 0; i < placeholders.length; i++) {
            svg = _replace(svg, placeholders[i], replacements[i]);
        }
        
        return svg;
    }
    
    /**
     * @dev Calculate visual size for impact visualization with bounds
     */
    function _calculateVisualSize(uint256 impactValue, uint256 scalingFactor) 
        internal 
        view 
        returns (uint256) 
    {
        // Ensure we don't divide by zero or very small numbers
        if (scalingFactor == 0 || scalingFactor > _maxScalingFactor) {
            return _minSize;
        }
        
        uint256 size = (impactValue * 10) / scalingFactor;
        
        // Apply bounds
        if (size < _minSize) return _minSize;
        if (size > _maxSize) return _maxSize;
        
        return size;
    }
    
    /**
     * @dev Parse color pair string into two separate colors
     */
    function _parseColors(string memory colorPair) 
        internal 
        pure 
        returns (string memory primary, string memory secondary) 
    {
        bytes memory colorBytes = bytes(colorPair);
        
        // Find the comma separator
        uint256 commaPos = type(uint256).max;
        for (uint i = 0; i < colorBytes.length; i++) {
            if (colorBytes[i] == ',') {
                commaPos = i;
                break;
            }
        }
        
        // If no comma found, return the whole string as primary color and a default for secondary
        if (commaPos == type(uint256).max) {
            return (colorPair, "#FFFFFF");
        }
        
        // Split the string
        primary = _substring(colorPair, 0, commaPos);
        secondary = _substring(colorPair, commaPos + 1, colorBytes.length - commaPos - 1);
    }
    
    /**
     * @dev Extract substring from string (gas efficient version)
     */
    function _substring(string memory str, uint256 startIndex, uint256 length) 
        internal 
        pure 
        returns (string memory) 
    {
        bytes memory strBytes = bytes(str);
        
        if (startIndex >= strBytes.length) {
            return "";
        }
        
        uint256 maxLength = strBytes.length - startIndex;
        if (length > maxLength) {
            length = maxLength;
        }
        
        bytes memory result = new bytes(length);
        for (uint i = 0; i < length; i++) {
            result[i] = strBytes[startIndex + i];
        }
        
        return string(result);
    }
    
    /**
     * @dev Replace placeholder in string (gas efficient)
     */
    function _replace(string memory source, string memory placeholder, string memory replacement) 
        internal 
        pure 
        returns (string memory) 
    {
        // If source is empty or placeholder is empty, return source
        if (bytes(source).length == 0 || bytes(placeholder).length == 0) {
            return source;
        }
        
        // Convert strings to bytes for more efficient processing
        bytes memory sourceBytes = bytes(source);
        bytes memory placeholderBytes = bytes(placeholder);
        bytes memory replacementBytes = bytes(replacement);
        
        // If placeholder is longer than source, it can't be found
        if (placeholderBytes.length > sourceBytes.length) {
            return source;
        }
        
        // Search for the placeholder
        bool found = false;
        uint256 foundIndex;
        
        for (uint256 i = 0; i <= sourceBytes.length - placeholderBytes.length; i++) {
            bool match = true;
            for (uint256 j = 0; j < placeholderBytes.length; j++) {
                if (sourceBytes[i + j] != placeholderBytes[j]) {
                    match = false;
                    break;
                }
            }
            if (match) {
                found = true;
                foundIndex = i;
                break;
            }
        }
        
        // If placeholder not found, return source
        if (!found) {
            return source;
        }
        
        // Create result with correct length
        bytes memory resultBytes = new bytes(
            sourceBytes.length - placeholderBytes.length + replacementBytes.length
        );
        
        // Copy part before placeholder
        for (uint256 i = 0; i < foundIndex; i++) {
            resultBytes[i] = sourceBytes[i];
        }
        
        // Copy replacement
        for (uint256 i = 0; i < replacementBytes.length; i++) {
            resultBytes[foundIndex + i] = replacementBytes[i];
        }
        
        // Copy part after placeholder
        for (uint256 i = foundIndex + placeholderBytes.length; i < sourceBytes.length; i++) {
            resultBytes[foundIndex + replacementBytes.length + i - (foundIndex + placeholderBytes.length)] = sourceBytes[i];
        }
        
        return string(resultBytes);
    }
    
    /**
     * @dev Get impact unit based on category
     */
    function _getImpactUnit(uint8 category) 
        internal 
        pure 
        returns (string memory) 
    {
        if (category == 0) return "kg CO2";
        if (category == 1) return "liters";
        if (category == 2) return "trees";
        if (category == 3) return "kWh";
        if (category == 4) return "species";
        return "units";
    }
    
    /**
     * @dev Get attribute name for impact category
     */
    function _getImpactAttributeName(uint8 category)
        internal
        pure
        returns (string memory)
    {
        if (category == 0) return "Carbon Offset";
        if (category == 1) return "Water Saved";
        if (category == 2) return "Trees Planted";
        if (category == 3) return "Renewable Energy";
        if (category == 4) return "Species Protected";
        return "Impact Value";
    }
    
    // =====================================================
    // Interactive SVG Elements
    // =====================================================
    
    /**
     * @notice Toggle interactive mode for SVGs
     * @param enabled Whether interactive mode should be enabled
     */
    function setInteractiveMode(bool enabled) 
        external 
        onlyRole(DESIGNER_ROLE) 
    {
        _interactiveMode = enabled;
        emit InteractiveModeSet(enabled);
    }
    
    /**
     * @notice Set interactive elements for a category
     * @param category Impact category ID
     * @param elements SVG elements with interactive features
     */
    function setInteractiveElements(uint8 category, string calldata elements) 
        external 
        onlyRole(DESIGNER_ROLE) 
    {
        _interactiveElements[category] = elements;
        emit InteractiveElementsSet(category, elements);
    }
    
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
    ) 
        external 
        view 
        returns (string memory) 
    {
        return _generateMetadataInternal(
            tokenId,
            impactCategory,
            impactValue,
            projectName,
            projectDescription,
            true
        );
    }
    
    /**
     * @dev Generate interactive SVG with additional elements
     */
    function _generateInteractiveSVG(
        uint256 tokenId,
        uint8 category,
        uint256 impactValue,
        uint256 visualSize,
        string memory primaryColor,
        string memory secondaryColor,
        string memory impactUnit
    ) 
        internal 
        view 
        returns (string memory) 
    {
        // Start with standard SVG
        string memory svg = _generateSVG(
            tokenId,
            category,
            impactValue,
            visualSize,
            primaryColor,
            secondaryColor,
            impactUnit
        );
        
        // Insert interactive elements before closing SVG tag
        if (bytes(_interactiveElements[category]).length > 0) {
            svg = _replaceLast(svg, "</svg>", string(abi.encodePacked(
                _interactiveElements[category],
                "</svg>"
            )));
        }
        
        return svg;
    }
    
    /**
     * @dev Replace last occurrence of a substring
     */
    function _replaceLast(string memory source, string memory target, string memory replacement) 
        internal 
        pure 
        returns (string memory) 
    {
        bytes memory sourceBytes = bytes(source);
        bytes memory targetBytes = bytes(target);
        
        if (sourceBytes.length < targetBytes.length) {
            return source;
        }
        
        // Find the last occurrence of target
        int256 lastIndex = -1;
        for (uint i = 0; i <= sourceBytes.length - targetBytes.length; i++) {
            bool found = true;
            for (uint j = 0; j < targetBytes.length; j++) {
                if (sourceBytes[i + j] != targetBytes[j]) {
                    found = false;
                    break;
                }
            }
            if (found) {
                lastIndex = int256(i);
            }
        }
        
        // If target not found, return source
        if (lastIndex == -1) {
            return source;
        }
        
        // Replace at the last position
        bytes memory resultBytes = new bytes(
            sourceBytes.length - targetBytes.length + bytes(replacement).length
        );
        
        // Copy part before replacement
        for (uint i = 0; i < uint256(lastIndex); i++) {
            resultBytes[i] = sourceBytes[i];
        }
        
        // Copy replacement
        for (uint i = 0; i < bytes(replacement).length; i++) {
            resultBytes[uint256(lastIndex) + i] = bytes(replacement)[i];
        }
        
        // Copy part after replacement
        for (uint i = uint256(lastIndex) + targetBytes.length; i < sourceBytes.length; i++) {
            resultBytes[uint256(lastIndex) + bytes(replacement).length + i - (uint256(lastIndex) + targetBytes.length)] = sourceBytes[i];
        }
        
        return string(resultBytes);
    }
    
    // =====================================================
    // Admin Functions
    // =====================================================
    
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
    ) 
        external 
        onlyRole(DESIGNER_ROLE) 
    {
        _categoryColors[category] = string(abi.encodePacked(primaryColor, ",", secondaryColor));
        emit CategoryColorsUpdated(category, primaryColor, secondaryColor);
    }
    
    /**
     * @notice Set icon for a category
     * @param category Impact category ID
     * @param svgPath SVG path data for the icon
     */
    function setCategoryIcon(uint8 category, string calldata svgPath) 
        external 
        onlyRole(DESIGNER_ROLE) 
    {
        _categoryIcons[category] = svgPath;
        emit CategoryIconUpdated(category, svgPath);
    }
    
    /**
     * @notice Set name for a category
     * @param category Impact category ID
     * @param name Category name
     */
    function setCategoryName(uint8 category, string calldata name) 
        external 
        onlyRole(DESIGNER_ROLE) 
    {
        _categoryNames[category] = name;
        emit CategoryNameUpdated(category, name);
    }
    
    /**
     * @notice Set scaling factor for impact visualization
     * @param category Impact category ID
     * @param scalingFactor Factor to divide impact value by for visualization
     */
    function setCategoryScalingFactor(uint8 category, uint256 scalingFactor) 
        external 
        onlyRole(DESIGNER_ROLE) 
    {
        require(scalingFactor > 0, "Scaling factor must be positive");
        require(scalingFactor <= _maxScalingFactor, "Scaling factor too large");
        _categoryScalingFactors[category] = scalingFactor;
        emit ScalingFactorUpdated(category, scalingFactor);
    }
    
    /**
     * @notice Set animation for a category
     * @param category Impact category ID
     * @param animationSvg SVG animation element
     */
    function setCategoryAnimation(uint8 category, string calldata animationSvg) 
        external 
        onlyRole(DESIGNER_ROLE) 
    {
        _categoryAnimations[category] = animationSvg;
        emit AnimationUpdated(category, animationSvg);
    }
    
    /**
     * @notice Set visualization size limits
     * @param minSize Minimum size for impact visualization
     * @param maxSize Maximum size for impact visualization
     */
    function setVisualizationSizeLimits(uint256 minSize, uint256 maxSize) 
        external 
        onlyRole(DESIGNER_ROLE) 
    {
        require(minSize > 0 && maxSize > minSize, "Invalid size limits");
        _minSize = minSize;
        _maxSize = maxSize;
        emit SizeLimitsUpdated(minSize, maxSize);
    }
    
    /**
     * @notice Set the maximum scaling factor allowed
     * @param maxScalingFactor Maximum value for scaling factors
     */
    function setMaxScalingFactor(uint256 maxScalingFactor)
        external
        onlyRole(DESIGNER_ROLE)
    {
        require(maxScalingFactor > 0, "Max scaling factor must be positive");
        _maxScalingFactor = maxScalingFactor;
        emit MaxScalingFactorUpdated(maxScalingFactor);
    }
    
    /**
     * @notice Update the entire SVG template
     * @param newTemplate New SVG template with placeholders
     */
    function updateSVGTemplate(string calldata newTemplate) 
        external 
        onlyRole(DESIGNER_ROLE) 
    {
        // Verify template has all required placeholders
        require(
            bytes(newTemplate).length > 0 &&
            _containsPlaceholder(newTemplate, "{{PRIMARY_COLOR}}") &&
            _containsPlaceholder(newTemplate, "{{SECONDARY_COLOR}}") &&
            _containsPlaceholder(newTemplate, "{{ICON}}") &&
            _containsPlaceholder(newTemplate, "{{IMPACT_VALUE}}"),
            "Template missing required placeholders"
        );
        
        _svgTemplate = newTemplate;
        emit TemplateUpdated();
    }
    
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
    ) 
        external 
        onlyRole(DESIGNER_ROLE) 
    {
        require(
            categories.length == names.length &&
            categories.length == primaryColors.length &&
            categories.length == secondaryColors.length &&
            categories.length == icons.length &&
            categories.length == scalingFactors.length,
            "Array length mismatch"
        );
        
        for (uint i = 0; i < categories.length; i++) {
            uint8 category = categories[i];
            uint256 scalingFactor = scalingFactors[i];
            
            require(scalingFactor > 0 && scalingFactor <= _maxScalingFactor, "Invalid scaling factor");
            
            _categoryNames[category] = names[i];
            _categoryColors[category] = string(abi.encodePacked(primaryColors[i], ",", secondaryColors[i]));
            _categoryIcons[category] = icons[i];
            _categoryScalingFactors[category] = scalingFactor;
            
            emit CategoryConfigured(
                category,
                names[i],
                primaryColors[i],
                secondaryColors[i],
                icons[i],
                scalingFactor
            );
        }
    }
    
    /**
     * @notice Check if a string contains a placeholder
     * @param source Source string
     * @param placeholder Placeholder to check for
     * @return True if placeholder exists in source
     */
    function _containsPlaceholder(string memory source, string memory placeholder) 
        internal 
        pure 
        returns (bool) 
    {
        bytes memory sourceBytes = bytes(source);
        bytes memory placeholderBytes = bytes(placeholder);
        
        if (sourceBytes.length < placeholderBytes.length) {
            return false;
        }
        
        for (uint i = 0; i <= sourceBytes.length - placeholderBytes.length; i++) {
            bool found = true;
            for (uint j = 0; j < placeholderBytes.length; j++) {
                if (sourceBytes[i + j] != placeholderBytes[j]) {
                    found = false;
                    break;
                }
            }
            if (found) {
                return true;
            }
        }
        
        return false;
    }
    
    /**
     * @notice Get the current size limits for impact visualization
     * @return minSize Minimum size for impact visualization
     * @return maxSize Maximum size for impact visualization
     */
    function getVisualizationSizeLimits() 
        external 
        view 
        returns (uint256 minSize, uint256 maxSize) 
    {
        return (_minSize, _maxSize);
    }
    
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
        )
    {
        name = _categoryNames[category];
        
        string memory colorPair = _categoryColors[category];
        (primaryColor, secondaryColor) = _parseColors(colorPair);
        
        icon = _categoryIcons[category];
        scalingFactor = _categoryScalingFactors[category];
    }
    
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
    ) 
        external 
        view 
        returns (string memory) 
    {
        // Get color values
        string memory colorPair = _categoryColors[impactCategory];
        (string memory primaryColor, string memory secondaryColor) = _parseColors(colorPair);
        
        // Calculate impact visualization size
        uint256 scalingFactor = _categoryScalingFactors[impactCategory];
        uint256 visualSize = _calculateVisualSize(impactValue, scalingFactor);
        
        // Get impact unit
        string memory impactUnit = _getImpactUnit(impactCategory);
        
        // For very large SVGs, process in chunks to avoid gas limits
        string memory svgHeader = string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="400" viewBox="0 0 100 100">',
            '<defs><linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">',
            '<stop offset="0%" stop-color="', primaryColor, '"/>',
            '<stop offset="100%" stop-color="', secondaryColor, '"/>',
            '</linearGradient></defs>',
            '<rect width="100" height="100" fill="url(#bg)" rx="5" ry="5"/>'
        ));
        
        string memory svgBody = string(abi.encodePacked(
            '<g id="icon" fill="none" stroke="white" stroke-width="1.5">',
            _categoryIcons[impactCategory],
            '</g>',
            '<text x="50" y="20" font-family="Arial" font-size="4" fill="white" text-anchor="middle">',
            _categoryNames[impactCategory],
            '</text>',
            '<text x="50" y="90" font-family="Arial" font-size="3" fill="white" text-anchor="middle">',
            'Token #', tokenId.toString(),
            '</text>'
        ));
        
        string memory svgFooter = string(abi.encodePacked(
            '<circle cx="50" cy="50" r="', visualSize.toString(), '" fill="white" fill-opacity="0.3">',
            _categoryAnimations[impactCategory],
            '</circle>',
            '<text x="50" y="52" font-family="Arial" font-size="5" fill="white" text-anchor="middle" font-weight="bold">',
            impactValue.toString(),
            '</text>',
            '<text x="50" y="58" font-family="Arial" font-size="2" fill="white" text-anchor="middle">',
            impactUnit,
            '</text>',
            '</svg>'
        ));
        
        return string(abi.encodePacked(svgHeader, svgBody, svgFooter));
    }
    
    // =====================================================
    // Required Overrides
    // =====================================================
    
    /**
     * @notice Authorize upgrade for UUPS pattern
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyRole(UPGRADER_ROLE) 
    {}
    
    // =====================================================
    // Events
    // =====================================================
    
    event CategoryColorsUpdated(
        uint8 indexed category,
        string primaryColor,
        string secondaryColor
    );
    
    event CategoryIconUpdated(
        uint8 indexed category,
        string svgPath
    );
    
    event CategoryNameUpdated(
        uint8 indexed category,
        string name
    );
    
    event ScalingFactorUpdated(
        uint8 indexed category,
        uint256 factor
    );
    
    event MaxScalingFactorUpdated(
        uint256 maxFactor
    );
    
    event AnimationUpdated(
        uint8 indexed category,
        string animation
    );
    
    event SizeLimitsUpdated(
        uint256 minSize,
        uint256 maxSize
    );
    
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
    
    event InteractiveElementsSet(
        uint8 indexed category,
        string elements
    );
}
