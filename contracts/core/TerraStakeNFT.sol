// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

interface ITerraStakeToken {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title TerraStakeNFT (ERC667)
 * @notice Fractionalized NFT contract with Uniswap v3 liquidity integration.
 */
contract TerraStakeNFT is ERC1155, AccessControl, ReentrancyGuard {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    ITerraStakeToken public immutable tStakeToken;
    address public immutable TERRA_POOL;

    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Pool public immutable uniswapPool;
    uint24 public constant POOL_FEE = 3000;

    uint256 public totalMinted;
    uint256 public mintFee;

    struct NFTMetadata {
        string uri;
        uint256 projectId;
        uint256 impactValue;
        bool isTradable;
    }

    mapping(uint256 => NFTMetadata) private _nftMetadata;
    mapping(uint256 => address) private _uniqueOwners;
    mapping(uint256 => bool) private _isFractionalized;

    event NFTMinted(address indexed to, uint256 indexed tokenId, uint256 projectId, uint256 impactValue, string uri, bool isTradable);
    event NFTFractionalized(uint256 indexed tokenId, address indexed owner, uint256 amount);
    event NFTBurned(uint256 indexed tokenId);
    event RewardPaid(address indexed to, uint256 amount);
    event MintFeeUpdated(uint256 oldFee, uint256 newFee);
    event LiquidityAdded(uint256 indexed tokenId, uint256 amountTSTAKE, uint256 amountUSDC);
    event MetadataUpdated(uint256 indexed tokenId, string newUri);
    event FeesWithdrawn(address indexed recipient, uint256 amount);

    constructor(
        address _tStakeToken,
        uint256 _initialMintFee,
        address _positionManager,
        address _uniswapPool,
        address _terraPool
    ) ERC1155("https://metadata.terrastake.com/{id}.json") {
        require(_tStakeToken != address(0), "Invalid TSTAKE token address");
        require(_positionManager != address(0), "Invalid Uniswap position manager");
        require(_uniswapPool != address(0), "Invalid Uniswap pool");
        require(_terraPool != address(0), "Invalid TERRA_POOL address");

        tStakeToken = ITerraStakeToken(_tStakeToken);
        positionManager = INonfungiblePositionManager(_positionManager);
        uniswapPool = IUniswapV3Pool(_uniswapPool);
        TERRA_POOL = _terraPool;

        _grantRole(DEFAULT_ADMIN_ROLE, TERRA_POOL);
        _grantRole(MINTER_ROLE, TERRA_POOL);
        _grantRole(GOVERNANCE_ROLE, TERRA_POOL);
        
        mintFee = _initialMintFee;
    }

    /**
     * @dev Mints a new NFT with project metadata.
     */
    function mint(
        address to,
        uint256 projectId,
        uint256 impactValue,
        string memory uri,
        bool isTradable
    ) external nonReentrant onlyRole(MINTER_ROLE) {
        require(to != address(0), "Invalid recipient");
        require(bytes(uri).length > 0, "URI required");
        require(impactValue > 0, "Impact value must be > 0");

        if (mintFee > 0) {
            require(tStakeToken.transferFrom(msg.sender, address(this), mintFee), "Mint fee transfer failed");
        }

        uint256 tokenId = ++totalMinted;
        _mint(to, tokenId, 1, "");
        _uniqueOwners[tokenId] = to;
        
        _nftMetadata[tokenId] = NFTMetadata({
            uri: uri,
            projectId: projectId,
            impactValue: impactValue,
            isTradable: isTradable
        });

        emit NFTMinted(to, tokenId, projectId, impactValue, uri, isTradable);
    }

    /**
     * @dev Retrieves NFT metadata.
     */
    function getNFTMetadata(uint256 tokenId) external view returns (
        string memory uri,
        uint256 projectId,
        uint256 impactValue,
        bool isTradable
    ) {
        NFTMetadata memory metadata = _nftMetadata[tokenId];
        return (
            metadata.uri,
            metadata.projectId,
            metadata.impactValue,
            metadata.isTradable
        );
    }

    /**
     * @dev Converts an NFT into fractionalized ERC1155 tokens.
     */
    function fractionalize(uint256 tokenId, uint256 amount) external nonReentrant onlyRole(GOVERNANCE_ROLE) {
        require(_uniqueOwners[tokenId] != address(0), "Invalid token");
        require(!_isFractionalized[tokenId], "Already fractionalized");

        _isFractionalized[tokenId] = true;
        _mint(_uniqueOwners[tokenId], tokenId, amount, "");

        emit NFTFractionalized(tokenId, _uniqueOwners[tokenId], amount);
    }

    /**
     * @dev Adds liquidity to Uniswap v3 for a fractionalized NFT.
     */
    function addLiquidity(
        uint256 tokenId,
        uint256 amountTSTAKE,
        uint256 amountUSDC
    ) external nonReentrant onlyRole(GOVERNANCE_ROLE) {
        require(_isFractionalized[tokenId], "Token must be fractionalized");
        require(tStakeToken.transferFrom(msg.sender, address(this), amountTSTAKE), "TSTAKE transfer failed");

        IERC20 usdc = IERC20(uniswapPool.token1());
        require(usdc.transferFrom(msg.sender, address(this), amountUSDC), "USDC transfer failed");

        emit LiquidityAdded(tokenId, amountTSTAKE, amountUSDC);
    }

    /**
     * @dev Burns an NFT or its fractionalized tokens.
     */
    function burn(uint256 tokenId) external onlyRole(GOVERNANCE_ROLE) {
        require(_uniqueOwners[tokenId] != address(0), "Invalid token");

        _burn(_uniqueOwners[tokenId], tokenId, 1);
        delete _nftMetadata[tokenId];
        delete _uniqueOwners[tokenId];

        emit NFTBurned(tokenId);
    }

    /**
     * @dev Updates the minting fee.
     */
    function updateMintFee(uint256 newFee) external onlyRole(GOVERNANCE_ROLE) {
        uint256 oldFee = mintFee;
        mintFee = newFee;
        emit MintFeeUpdated(oldFee, newFee);
    }

    /**
     * @dev Withdraws accumulated fees.
     */
    function withdrawFees(address recipient, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(tStakeToken.transfer(recipient, amount), "Withdraw failed");
        emit FeesWithdrawn(recipient, amount);
    }

    /**
     * @dev Updates NFT metadata URI.
     */
    function updateMetadata(uint256 tokenId, string calldata newUri) external onlyRole(GOVERNANCE_ROLE) {
        require(bytes(newUri).length > 0, "New URI cannot be empty");
        _nftMetadata[tokenId].uri = newUri;
        emit MetadataUpdated(tokenId, newUri);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}