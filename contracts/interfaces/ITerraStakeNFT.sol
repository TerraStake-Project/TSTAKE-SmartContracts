// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/IERC1155MetadataURI.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title ITerraStakeERC667
 * @notice Interface for TerraStakeERC667, defining NFT minting, fractionalization, liquidity, and governance controls.
 */
interface ITerraStakeERC667 is IERC1155, IERC1155MetadataURI, IAccessControl {
    // Events
    event NFTMinted(address indexed to, uint256 indexed tokenId, uint256 projectId, uint256 impactValue, string uri, bool isTradable);
    event NFTFractionalized(uint256 indexed tokenId, address indexed owner, uint256 amount);
    event NFTBurned(uint256 indexed tokenId);
    event RewardPaid(address indexed to, uint256 amount);
    event MintFeeUpdated(uint256 oldFee, uint256 newFee);
    event LiquidityAdded(uint256 indexed tokenId, uint256 amountTSTAKE, uint256 amountUSDC);
    event MetadataUpdated(uint256 indexed tokenId, string newUri);
    event FeesWithdrawn(address indexed recipient, uint256 amount);

    // Structs
    struct NFTMetadata {
        string uri;
        uint256 projectId;
        uint256 impactValue;
        bool isTradable;
    }

    // Minting & Metadata
    function mint(
        address to,
        uint256 projectId,
        uint256 impactValue,
        string memory uri,
        bool isTradable
    ) external;

    function updateMetadata(uint256 tokenId, string calldata newUri) external;

    function getNFTMetadata(uint256 tokenId) external view returns (
        string memory uri,
        uint256 projectId,
        uint256 impactValue,
        bool isTradable
    );

    // Fractionalization & Liquidity
    function fractionalize(uint256 tokenId, uint256 amount) external;

    function addLiquidity(
        uint256 tokenId,
        uint256 amountTSTAKE,
        uint256 amountUSDC
    ) external;

    // Token Burning & Governance
    function burn(uint256 tokenId) external;

    function updateMintFee(uint256 newFee) external;

    function withdrawFees(address recipient, uint256 amount) external;

    // ERC1155 Standard Functions
    function setApprovalForAll(address operator, bool approved) external;

    function isApprovedForAll(address account, address operator) external view returns (bool);

    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) external;

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) external;
}