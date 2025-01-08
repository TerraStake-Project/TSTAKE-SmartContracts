// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Royalty.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ITerraStakeToken {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract TerraStakeNFT is ERC721Royalty, AccessControl, ReentrancyGuard {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    ITerraStakeToken public tStakeToken;
    address public constant TERRA_POOL = 0xcB3705b50773e95fCe6d3Fcef62B4d753aA0059d;

    uint256 public totalSupply;
    uint256 public mintFee;

    struct NFTMetadata {
        string uri;         
        uint256 projectId;  
        uint256 impactValue;
        bool isTradable;    
    }

    mapping(uint256 => NFTMetadata) private _nftMetadata;

    event NFTMinted(
        address indexed to,
        uint256 indexed tokenId,
        uint256 projectId,
        uint256 impactValue,
        string uri,
        bool isTradable
    );
    event NFTBurned(uint256 indexed tokenId);
    event RewardPaid(address indexed to, uint256 amount);
    event MintFeeUpdated(uint256 oldFee, uint256 newFee);

    constructor(address _tStakeToken, uint256 _initialMintFee)
        ERC721("TerraStake NFT", "TSTAKE-NFT")
    {
        require(_tStakeToken != address(0), "Invalid TSTAKE token address");
        tStakeToken = ITerraStakeToken(_tStakeToken);

        _grantRole(DEFAULT_ADMIN_ROLE, TERRA_POOL);
        _grantRole(MINTER_ROLE, TERRA_POOL);
        _grantRole(GOVERNANCE_ROLE, TERRA_POOL);

        _setDefaultRoyalty(TERRA_POOL, 500);
        mintFee = _initialMintFee;
    }

    function mint(
        address to,
        uint256 projectId,
        uint256 impactValue,
        string memory uri,
        bool isTradable
    ) external nonReentrant onlyRole(MINTER_ROLE) {
        require(to != address(0), "Invalid recipient address");
        require(bytes(uri).length > 0, "URI required");
        require(impactValue > 0, "Impact value must be > 0");

        if (mintFee > 0) {
            bool success = tStakeToken.transferFrom(msg.sender, address(this), mintFee);
            require(success, "Mint fee transfer failed");
        }

        uint256 tokenId = ++totalSupply;
        _safeMint(to, tokenId);

        _nftMetadata[tokenId] = NFTMetadata({
            uri: uri,
            projectId: projectId,
            impactValue: impactValue,
            isTradable: isTradable
        });

        emit NFTMinted(to, tokenId, projectId, impactValue, uri, isTradable);
    }

    function burn(uint256 tokenId) external onlyRole(GOVERNANCE_ROLE) {
        ownerOf(tokenId);
        _burn(tokenId);
        delete _nftMetadata[tokenId];
        emit NFTBurned(tokenId);
    }

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal virtual override returns (address) {
        address from = super._update(to, tokenId, auth);
        
        // Only check tradability for transfers (not mints/burns)
        if (from != address(0) && to != address(0)) {
            require(_nftMetadata[tokenId].isTradable, "NFT not tradable");
        }
        
        return from;
    }

    function rewardHolder(uint256 tokenId, uint256 rewardAmount)
        external
        nonReentrant
        onlyRole(GOVERNANCE_ROLE)
    {
        address tokenOwner = ownerOf(tokenId);
        bool success = tStakeToken.transfer(tokenOwner, rewardAmount);
        require(success, "Reward transfer failed");
        emit RewardPaid(tokenOwner, rewardAmount);
    }

    function updateMintFee(uint256 newFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldFee = mintFee;
        mintFee = newFee;
        emit MintFeeUpdated(oldFee, newFee);
    }

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
        ownerOf(tokenId);
        NFTMetadata memory meta = _nftMetadata[tokenId];
        return (meta.uri, meta.projectId, meta.impactValue, meta.isTradable);
    }

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
