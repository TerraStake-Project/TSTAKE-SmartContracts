// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Royalty.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

// Interface for interacting with TerraStake Token
interface ITerraStakeToken {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract TerraStakeNFT is ERC721Royalty, AccessControl {
    // Role definitions
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    // TerraStake token contract
    ITerraStakeToken public tStakeToken;

    // TerraStake pool address for royalties
    address public constant TERRA_POOL = 0xcB3705b50773e95fCe6d3Fcef62B4d753aA0059d;

    // Total amount of tokens
    uint256 public totalSupply;

    // Struct to store NFT metadata
    struct NFTMetadata {
        string uri; // Metadata URI
        uint256 projectId; // Associated project ID
        uint256 impactValue; // Measurable impact value (e.g., CO2 offset)
        bool isTradable; // If true, NFT can be sold or traded
    }

    // Mapping from token ID to metadata
    mapping(uint256 => NFTMetadata) private _nftMetadata;

    // Events
    event NFTMinted(
        address indexed to,
        uint256 indexed tokenId,
        uint256 projectId,
        uint256 impactValue,
        string uri,
        bool isTradable
    );
    event NFTBurned(uint256 indexed tokenId);
    event NFTTransferred(uint256 indexed tokenId, address indexed from, address indexed to);
    event RewardPaid(address indexed to, uint256 amount);

    constructor(address _tStakeToken) ERC721("TerraStake NFT", "TSTAKE-NFT") {
        require(_tStakeToken != address(0), "Invalid TSTAKE token address");

        tStakeToken = ITerraStakeToken(_tStakeToken);

        // Assign roles to the TerraStake pool
        _grantRole(DEFAULT_ADMIN_ROLE, TERRA_POOL);
        _grantRole(MINTER_ROLE, TERRA_POOL);
        _grantRole(GOVERNANCE_ROLE, TERRA_POOL);

        // Set default royalties (5% to TerraStake pool)
        _setDefaultRoyalty(TERRA_POOL, 500); // 500 basis points = 5%
    }

    /**
     * @dev Mint a new NFT.
     * @param to The address to receive the NFT.
     * @param projectId The associated project ID.
     * @param impactValue The measurable impact value.
     * @param uri The metadata URI.
     * @param isTradable Whether the NFT is tradable.
     */
    function mint(
        address to,
        uint256 projectId,
        uint256 impactValue,
        string memory uri,
        bool isTradable
    ) external onlyRole(MINTER_ROLE) {
        require(to != address(0), "Invalid recipient address");
        require(bytes(uri).length > 0, "Invalid URI");
        require(impactValue > 0, "Impact value must be greater than zero");

        uint256 tokenId = totalSupply + 1;

        _safeMint(to, tokenId);
        _nftMetadata[tokenId] = NFTMetadata({
            uri: uri,
            projectId: projectId,
            impactValue: impactValue,
            isTradable: isTradable
        });
        totalSupply = totalSupply + 1;

        emit NFTMinted(to, tokenId, projectId, impactValue, uri, isTradable);
    }

    /**
     * @dev Burn an NFT.
     * @param tokenId The token ID to burn.
     */
    function burn(uint256 tokenId) external onlyRole(GOVERNANCE_ROLE) {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        _burn(tokenId);
        delete _nftMetadata[tokenId];
        emit NFTBurned(tokenId);
    }

    /**
     * @dev Transfer an NFT.
     * @param to The address to transfer to.
     * @param tokenId The token ID to transfer.
     */
    function transferNFT(address to, uint256 tokenId) external {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        require(ownerOf(tokenId) == msg.sender, "Caller is not the owner");
        require(_nftMetadata[tokenId].isTradable, "NFT is not tradable");

        _transfer(msg.sender, to, tokenId);
        emit NFTTransferred(tokenId, msg.sender, to);
    }

    /**
     * @dev Pay a reward in TSTAKE tokens to the owner of an NFT.
     * @param tokenId The token ID.
     * @param rewardAmount The reward amount in TSTAKE tokens.
     */
    function rewardHolder(uint256 tokenId, uint256 rewardAmount) external onlyRole(GOVERNANCE_ROLE) {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        address owner = ownerOf(tokenId);
        require(tStakeToken.transfer(owner, rewardAmount), "Reward transfer failed");
        emit RewardPaid(owner, rewardAmount);
    }

    /**
     * @dev Get metadata for a specific NFT.
     * @param tokenId The token ID.
     * @return uri Metadata URI.
     * @return projectId Associated project ID.
     * @return impactValue Measurable impact value.
     * @return isTradable Whether the NFT is tradable.
     */
    function getNFTMetadata(uint256 tokenId)
        external
        view
        returns (
            string memory uri,
            uint256 projectId,
            uint256 impactValue,
            bool isTradable
        )
    {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        NFTMetadata memory metadata = _nftMetadata[tokenId];
        return (metadata.uri, metadata.projectId, metadata.impactValue, metadata.isTradable);
    }

    /**
     * @dev Override to support interfaces.
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721Royalty, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
