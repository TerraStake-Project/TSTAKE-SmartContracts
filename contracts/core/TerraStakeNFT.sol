// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155SupplyUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "../interfaces/ITerraStakeProjects.sol";

interface ITerraStakeToken {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
}

/**
 * @title TerraStakeNFTUpgradeable
 * @notice Upgradeable ERC1155 NFT contract with integrated on-chain metadata history,
 *         and IPFS support for rich metadata. Includes advanced features such as batch processing,
 *         enhanced project verification, automated liquidity management, and optimized fee distribution.
 * @dev This contract uses ERC1155SupplyUpgradeable and UUPSUpgradeable for upgradeability.
 */
contract TerraStakeNFTUpgradeable is 
    Initializable, 
    ERC1155Upgradeable, 
    ERC1155SupplyUpgradeable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    VRFConsumerBaseV2
{
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    
    uint256 private constant MAX_BATCH_SIZE = 100;
    uint256 private constant CACHE_VALIDITY_PERIOD = 7 days;
    uint24 public constant POOL_FEE = 3000;
    
    struct FeeDistribution {
        uint256 stakingShare;
        uint256 liquidityShare;
        uint256 treasuryShare;
        uint256 burnShare;
    }
    
    struct PerformanceMetrics {
        uint256 totalImpact;
        uint256 carbonOffset;
        uint256 efficiencyScore;
        uint256 lastUpdated;
        uint256 verifiedImpact;
        bytes32 metricHash; // Hash of all metrics for verification
    }
    
    // Enhanced NFTMetadata with verification data
    struct NFTMetadata {
        string ipfsUri;                   // IPFS URI pointing to a JSON file containing complete metadata
        uint256 projectId;                // Associated project ID
        uint256 impactValue;              // Environmental impact value
        bool isTradable;                  // Whether NFT is tradable
        string location;                  // Project location
        uint256 capacity;                 // Project capacity
        uint256 certificationDate;        // Date of certification
        string projectType;               // Type of project
        bool isVerified;                  // Verification status
        uint256 version;                  // Metadata version
        PerformanceMetrics performance;   // Performance metrics
        uint256 mintingFee;               // Fee paid for minting
        bytes32 projectDataHash;          // Hash of project data for verification
        bytes32 impactReportHash;         // Hash of latest impact report
        address originalMinter;           // Original minter address
        uint256 originalMintTimestamp;    // Original mint timestamp
        bytes32 verificationProofHash;    // Hash of verification proof
    }
    
    // Carbon credit retirement structure
    struct CarbonRetirement {
        uint256 tokenId;
        uint256 amount;
        address retiringEntity;
        address beneficiary;
        string reason;
        uint256 timestamp;
        bytes32 retirementId;
    }
    
    // Impact staking structure
    struct StakedImpact {
        uint256 tokenId;
        uint256 impactAmount;
        uint256 stakingTimestamp;
        uint256 unlockTimestamp;
        address staker;
        bool active;
    }
    
    // Fractional token info
    struct FractionInfo {
        uint256 originalTokenId;
        uint256 fractionBaseId;
        uint256 fractionCount;
        bool isActive;
        address fractionalizer;
        mapping(address => uint256) fractionBalances;
    }
    
    // Verification records
    struct VerificationRecord {
        uint256 tokenId;
        uint256 verifiedAmount;
        uint256 timestamp;
        string methodologyId;
        string verifierName;
        string externalVerifierId;
        bytes32 verificationProof;
        address verifier;
    }
    // External contracts and interfaces
    ITerraStakeToken public tStakeToken;
    ITerraStakeProjects public terraStakeProjects;
    address public TERRA_POOL;
    INonfungiblePositionManager public positionManager;
    IUniswapV3Pool public uniswapPool;
    address public treasuryWallet;
    address public stakingRewards;
    VRFCoordinatorV2Interface internal vrfCoordinator;
    address public vrfCoordinatorAddress;
    // Contract state variables
    uint256 public totalMinted;
    uint256 public mintFee;
    FeeDistribution public feeDistribution;
    bytes32 public keyHash;
    uint64 public subscriptionId;
    uint32 public callbackGasLimit;
    uint16 public requestConfirmations;
    
    // Enhanced mappings
    mapping(uint256 => NFTMetadata) public nftMetadata;
    mapping(uint256 => NFTMetadata[]) public metadataHistory;
    mapping(address => bool) public liquidityWhitelist;
    mapping(uint256 => uint256) private _cachedProjectImpact;
    mapping(uint256 => uint256) private _lastCacheUpdate;
    mapping(uint256 => uint256) private _randomnessRequests;
    mapping(uint256 => uint256) private _randomnessResults;
    mapping(uint256 => bytes32) private _projectHashes;
    mapping(uint256 => bytes32) private _verificationMerkleRoots;
    
    // Retirement and impact staking mappings
    mapping(bytes32 => CarbonRetirement) public carbonRetirements;
    mapping(address => StakedImpact[]) private _userStakedImpacts;
    mapping(uint256 => uint256) private _tokenImpactStaked;
    mapping(uint256 => FractionInfo) private _fractionInfos;
    mapping(uint256 => VerificationRecord[]) public verificationRecords;
    mapping(uint256 => uint256) public fractionalSupplies;
    mapping(bytes32 => bool) public retirementRegistry;
    
    // Statistics and analytics
    uint256 public totalCarbonRetired;
    uint256 public totalImpactStaked;
    uint256 public totalVerifications;
    
    // Reward rates and parameters
    uint256 public impactStakingRewardRate; // In basis points
    uint256 public verificationFee;
    uint256 public retirementFee;
    uint256 public fractionalizationFee;
    // Events
    event NFTMinted(address indexed to, uint256 indexed tokenId, uint256 projectId, bytes32 projectDataHash);
    event MintingFeeUpdated(uint256 newFee);
    event FeeDistributed(uint256 stakingAmount, uint256 liquidityAmount, uint256 treasuryAmount, uint256 burnAmount);
    event RandomnessRequested(uint256 indexed tokenId, uint256 indexed requestId);
    event RandomnessReceived(uint256 indexed requestId, uint256 randomValue);
    event MetadataUpdated(uint256 indexed tokenId, string newIpfsUri, uint256 version, bytes32 metadataHash);
    event ProjectHashVerified(uint256 indexed tokenId, uint256 indexed projectId, bytes32 projectHash);
    event VerificationProofAdded(uint256 indexed tokenId, bytes32 proofHash);
    event ContractUpgraded(address newImplementation);
    
    // Additional events
    event CarbonCreditsRetired(
        uint256 indexed tokenId, 
        uint256 amount, 
        address indexed retiringEntity,
        address indexed beneficiary, 
        string reason, 
        bytes32 retirementId,
        uint256 timestamp
    );
    
    event ImpactStaked(
        address indexed staker, 
        uint256 indexed tokenId, 
        uint256 impactAmount, 
        uint256 lockPeriod, 
        uint256 stakeId
    );
    
    event ImpactUnstaked(
        address indexed staker,
        uint256 indexed tokenId,
        uint256 impactAmount,
        uint256 stakeId,
        uint256 rewardAmount
    );
    
    event ImpactVerified(
        uint256 indexed tokenId,
        uint256 verifiedAmount,
        uint256 verificationTimestamp,
        string methodologyId,
        string verifierName,
        string externalVerifierId,
        bytes32 verificationProof
    );
    
    event TokenFractionalized(
        uint256 indexed originalTokenId,
        uint256 indexed fractionBaseId,
        uint256 fractionCount,
        address indexed fractionalizer
    );
    
    event FractionsReunified(
        uint256 indexed fractionBaseId,
        uint256 indexed newTokenId,
        address indexed unifier
    );
    
    event VerificationFeeUpdated(uint256 newFee);
    event RetirementFeeUpdated(uint256 newFee);
    event FractionalizationFeeUpdated(uint256 newFee);
    event StakingRewardRateUpdated(uint256 newRate);
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() VRFConsumerBaseV2(address(0)) {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with required parameters (replaces constructor)
     * @dev This function can only be called once
     */
    function initialize(
        address _tStakeToken,
        address _terraStakeProjects,
        uint256 _initialMintFee,
        address _positionManager,
        address _uniswapPool,
        address _terraPool,
        address _vrfCoordinator,
        bytes32 _keyHash,
        uint64 _subscriptionId,
        address _treasuryWallet,
        address _stakingRewards
    ) public initializer {
        require(_tStakeToken != address(0), "Invalid TSTAKE token address");
        require(_terraStakeProjects != address(0), "Invalid TerraStakeProjects address");
        require(_treasuryWallet != address(0), "Invalid treasury address");
        require(_stakingRewards != address(0), "Invalid staking rewards address");
        
        __ERC1155_init("ipfs://");
        __ERC1155Supply_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __VRFConsumerBaseV2_init(_vrfCoordinator);
        
        tStakeToken = ITerraStakeToken(_tStakeToken);
        terraStakeProjects = ITerraStakeProjects(_terraStakeProjects);
        positionManager = INonfungiblePositionManager(_positionManager);
        uniswapPool = IUniswapV3Pool(_uniswapPool);
        TERRA_POOL = _terraPool;
        treasuryWallet = _treasuryWallet;
        stakingRewards = _stakingRewards;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(VERIFIER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        
        mintFee = _initialMintFee;
        verificationFee = _initialMintFee / 2;
        retirementFee = _initialMintFee / 4;
        fractionalizationFee = _initialMintFee / 3;
        
        // Initialize VRF components
        vrfCoordinatorAddress = _vrfCoordinator;
        vrfCoordinator = VRFCoordinatorV2Interface(_vrfCoordinator);
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;
        callbackGasLimit = 200000;
        requestConfirmations = 3;
        
        feeDistribution = FeeDistribution(40, 25, 20, 15);
        impactStakingRewardRate = 500; // 5% annual reward rate (in basis points)
    }

    // =====================================================
    // Upgradeability Functions
    // =====================================================
    /**
     * @notice Function that authorizes upgrades 
     * @dev Only the account with UPGRADER_ROLE can upgrade the implementation
     */
   function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        emit ContractUpgraded(newImplementation);
    }

    // =====================================================
    // Minting Functions
    // =====================================================
    /**
     * @notice Mints a new NFT representing a verified environmental impact project
     * @dev Only minters can call this function
     * @param to Address to receive the newly minted NFT
     * @param projectId The project identifier
     * @param ipfsUri IPFS URI for rich metadata
     * @param impactValue Environmental impact value
     * @param location Project location
     * @param capacity Project capacity
     * @param projectType Type of project
     * @param projectDataHash Hash of project data for verification
     */
    function mint(
        address to,
        uint256 projectId,
        string memory ipfsUri,
        uint256 impactValue,
        string memory location,
        uint256 capacity,
        string memory projectType,
        bytes32 projectDataHash
    ) external onlyRole(MINTER_ROLE) nonReentrant {
        require(to != address(0), "Invalid recipient");
        require(bytes(ipfsUri).length > 0, "IPFS URI required");
        require(terraStakeProjects.projectExists(projectId), "Project does not exist");
        
        // Process minting fee
        if (mintFee > 0) {
            require(tStakeToken.transferFrom(msg.sender, address(this), mintFee), "Fee transfer failed");
            _processFees(mintFee);
        }
        
        totalMinted++;
        uint256 tokenId = totalMinted;
        
        _mint(to, tokenId, 1, "");
        
        // Set metadata
        NFTMetadata memory metadata = NFTMetadata({
            ipfsUri: ipfsUri,
            projectId: projectId,
            impactValue: impactValue,
            isTradable: true,
            location: location,
            capacity: capacity,
            certificationDate: block.timestamp,
            projectType: projectType,
            isVerified: false,
            version: 1,
            performance: PerformanceMetrics({
                totalImpact: impactValue,
                carbonOffset: 0,
                efficiencyScore: 0,
                lastUpdated: block.timestamp,
                verifiedImpact: 0,
                metricHash: keccak256(abi.encodePacked(impactValue, block.timestamp))
            }),
            mintingFee: mintFee,
            projectDataHash: projectDataHash,
            impactReportHash: bytes32(0),
            originalMinter: msg.sender,
            originalMintTimestamp: block.timestamp,
            verificationProofHash: bytes32(0)
        });
        
        nftMetadata[tokenId] = metadata;
        metadataHistory[tokenId].push(metadata);
        _projectHashes[tokenId] = projectDataHash;
        
        // Request randomness for environmental impact adjustment
        _requestRandomness(tokenId);
        
        // Update project cache for optimization
        _updateImpactCache(projectId, impactValue);
        
        emit NFTMinted(to, tokenId, projectId, projectDataHash);
    }
    
    /**
     * @notice Batch mint multiple NFTs at once
     * @dev Only minters can call this function, with safeguards against excessive gas consumption
     */
    function batchMint(
        address[] calldata recipients,
        uint256[] calldata projectIds,
        string[] calldata ipfsUris,
        uint256[] calldata impactValues,
        string[] calldata locations,
        uint256[] calldata capacities,
        string[] calldata projectTypes,
        bytes32[] calldata projectDataHashes
    ) external onlyRole(MINTER_ROLE) nonReentrant {
        uint256 batchSize = recipients.length;
        require(batchSize <= MAX_BATCH_SIZE, "Batch too large");
        require(
            batchSize == projectIds.length &&
            batchSize == ipfsUris.length &&
            batchSize == impactValues.length &&
            batchSize == locations.length &&
            batchSize == capacities.length &&
            batchSize == projectTypes.length &&
            batchSize == projectDataHashes.length,
            "Array length mismatch"
        );
        
        // Calculate total fees
        uint256 totalFee = mintFee * batchSize;
        
        // Transfer total fees in one transaction
        if (totalFee > 0) {
            require(tStakeToken.transferFrom(msg.sender, address(this), totalFee), "Fee transfer failed");
            _processFees(totalFee);
        }
        
        for (uint256 i = 0; i < batchSize; i++) {
            require(recipients[i] != address(0), "Invalid recipient");
            require(bytes(ipfsUris[i]).length > 0, "IPFS URI required");
            require(terraStakeProjects.projectExists(projectIds[i]), "Project does not exist");
            
            totalMinted++;
            uint256 tokenId = totalMinted;
            
            _mint(recipients[i], tokenId, 1, "");
            
            // Set metadata (similar to single mint)
            NFTMetadata memory metadata = NFTMetadata({
                ipfsUri: ipfsUris[i],
                projectId: projectIds[i],
                impactValue: impactValues[i],
                isTradable: true,
                location: locations[i],
                capacity: capacities[i],
                certificationDate: block.timestamp,
                projectType: projectTypes[i],
                isVerified: false,
                version: 1,
                performance: PerformanceMetrics({
                    totalImpact: impactValues[i],
                    carbonOffset: 0,
                    efficiencyScore: 0,
                    lastUpdated: block.timestamp,
                    verifiedImpact: 0,
                    metricHash: keccak256(abi.encodePacked(impactValues[i], block.timestamp))
                }),
                mintingFee: mintFee,
                projectDataHash: projectDataHashes[i],
                impactReportHash: bytes32(0),
                originalMinter: msg.sender,
                originalMintTimestamp: block.timestamp,
                verificationProofHash: bytes32(0)
            });
            
            nftMetadata[tokenId] = metadata;
            metadataHistory[tokenId].push(metadata);
            _projectHashes[tokenId] = projectDataHashes[i];
            
            // Request randomness for environmental impact adjustment
            _requestRandomness(tokenId);
            
            // Update project cache
            _updateImpactCache(projectIds[i], impactValues[i]);
            
            emit NFTMinted(recipients[i], tokenId, projectIds[i], projectDataHashes[i]);
        }
    }

    // =====================================================
    // Verification and Updates
    // =====================================================
    /**
     * @notice Verifies a token's impact claims using a Merkle proof
     * @dev Can only be called by accounts with VERIFIER_ROLE
     */
    function verifyToken(
        uint256 tokenId,
        bytes32[] calldata merkleProof,
        bytes32 verificationProofHash,
        uint256 verifiedAmount,
        string calldata methodologyId,
        string calldata verifierName,
        string calldata externalVerifierId
    ) external onlyRole(VERIFIER_ROLE) nonReentrant {
        require(_exists(tokenId), "Token does not exist");
        require(verificationProofHash != bytes32(0), "Invalid verification proof");
        
        // Handle verification fee
        if (verificationFee > 0) {
            require(tStakeToken.transferFrom(msg.sender, address(this), verificationFee), "Fee transfer failed");
            _processFees(verificationFee);
        }
        
        NFTMetadata storage metadata = nftMetadata[tokenId];
        bytes32 projectDataHash = metadata.projectDataHash;
        
        // Verify the Merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(tokenId, projectDataHash, verifiedAmount));
        require(MerkleProof.verify(merkleProof, _verificationMerkleRoots[tokenId], leaf), "Invalid verification proof");
        
        // Update token metadata
        metadata.isVerified = true;
        metadata.verificationProofHash = verificationProofHash;
        metadata.version += 1;
        metadata.performance.verifiedImpact = verifiedAmount;
        metadata.performance.lastUpdated = block.timestamp;
        metadata.performance.metricHash = keccak256(abi.encodePacked(
            metadata.performance.totalImpact,
            metadata.performance.carbonOffset,
            metadata.performance.efficiencyScore,
            verifiedAmount,
            block.timestamp
        ));
        
        // Add to metadata history
        metadataHistory[tokenId].push(metadata);
        
        // Record verification details
        VerificationRecord memory record = VerificationRecord({
            tokenId: tokenId,
            verifiedAmount: verifiedAmount,
            timestamp: block.timestamp,
            methodologyId: methodologyId,
            verifierName: verifierName,
            externalVerifierId: externalVerifierId,
            verificationProof: verificationProofHash,
            verifier: msg.sender
        });
        
        verificationRecords[tokenId].push(record);
        totalVerifications++;
        
        emit VerificationProofAdded(tokenId, verificationProofHash);
        emit ImpactVerified(
            tokenId,
            verifiedAmount,
            block.timestamp,
            methodologyId,
            verifierName,
            externalVerifierId,
            verificationProofHash
        );
    }
    
    /**
     * @notice Updates token metadata with new information
     * @dev Can only be called by the token owner or a verifier
     */
    function updateTokenMetadata(
        uint256 tokenId,
        string memory newIpfsUri,
        uint256 additionalImpact,
        bytes32 impactReportHash
    ) external nonReentrant {
        require(_exists(tokenId), "Token does not exist");
        require(
            hasRole(VERIFIER_ROLE, msg.sender) || 
            msg.sender == terraStakeProjects.getProjectVerifier(nftMetadata[tokenId].projectId) ||
            balanceOf(msg.sender, tokenId) > 0,
            "Not authorized"
        );
        
        NFTMetadata storage metadata = nftMetadata[tokenId];
        
        // Update fields
        metadata.ipfsUri = newIpfsUri;
        metadata.impactValue += additionalImpact;
        metadata.impactReportHash = impactReportHash;
        metadata.version += 1;
        metadata.performance.totalImpact += additionalImpact;
        metadata.performance.lastUpdated = block.timestamp;
        metadata.performance.metricHash = keccak256(abi.encodePacked(
            metadata.performance.totalImpact,
            metadata.performance.carbonOffset,
            metadata.performance.efficiencyScore,
            metadata.performance.verifiedImpact,
            block.timestamp
        ));
        
        // Add to history
        metadataHistory[tokenId].push(metadata);
        
        // Update project impact cache
        _updateImpactCache(metadata.projectId, additionalImpact);
        
        emit MetadataUpdated(tokenId, newIpfsUri, metadata.version, impactReportHash);
    }
    
    // =====================================================
    // Carbon Retirement and Impact Staking
    // =====================================================
    /**
     * @notice Retires carbon credits from a token
     * @dev The token must be verified for retirement
     */
    function retireCarbonCredits(
        uint256 tokenId,
        uint256 amount,
        address beneficiary,
        string memory reason
    ) external nonReentrant {
        require(_exists(tokenId), "Token does not exist");
        require(balanceOf(msg.sender, tokenId) > 0, "Not token owner");
        require(nftMetadata[tokenId].isVerified, "Token not verified");
        require(amount > 0, "Amount must be positive");
        
        NFTMetadata storage metadata = nftMetadata[tokenId];
        require(amount <= metadata.performance.verifiedImpact - metadata.performance.carbonOffset, "Insufficient verified impact");
        
        // Handle retirement fee
        if (retirementFee > 0) {
            require(tStakeToken.transferFrom(msg.sender, address(this), retirementFee), "Fee transfer failed");
            _processFees(retirementFee);
        }
        
        // Generate retirement ID
        bytes32 retirementId = keccak256(abi.encodePacked(
            tokenId,
            amount,
            msg.sender,
            beneficiary,
            block.timestamp,
            totalCarbonRetired
        ));
        
        // Ensure retirement ID is unique
        require(!retirementRegistry[retirementId], "Duplicate retirement");
        retirementRegistry[retirementId] = true;
        
        // Record retirement
        CarbonRetirement memory retirement = CarbonRetirement({
            tokenId: tokenId,
            amount: amount,
            retiringEntity: msg.sender,
            beneficiary: beneficiary,
            reason: reason,
            timestamp: block.timestamp,
            retirementId: retirementId
        });
        
        carbonRetirements[retirementId] = retirement;
        
        // Update token metadata
        metadata.performance.carbonOffset += amount;
        metadata.performance.lastUpdated = block.timestamp;
        metadata.version += 1;
        
        // Add to history
        metadataHistory[tokenId].push(metadata);
        
        // Update totals
        totalCarbonRetired += amount;
        
        emit CarbonCreditsRetired(
            tokenId,
            amount,
            msg.sender,
            beneficiary,
            reason,
            retirementId,
            block.timestamp
        );
    }
    
    /**
     * @notice Allows token holders to stake their impact for rewards
     * @dev Locks impact for a period while generating rewards
     */
    function stakeImpact(
        uint256 tokenId,
        uint256 impactAmount,
        uint256 lockPeriod
    ) external nonReentrant {
        require(_exists(tokenId), "Token does not exist");
        require(balanceOf(msg.sender, tokenId) > 0, "Not token owner");
        require(impactAmount > 0, "Amount must be positive");
        require(lockPeriod >= 30 days && lockPeriod <= 365 days, "Invalid lock period");
        
        NFTMetadata storage metadata = nftMetadata[tokenId];
        uint256 availableImpact = metadata.impactValue - _tokenImpactStaked[tokenId];
        require(impactAmount <= availableImpact, "Insufficient available impact");
        
        // Create staking record
        StakedImpact memory stakedImpact = StakedImpact({
            tokenId: tokenId,
            impactAmount: impactAmount,
            stakingTimestamp: block.timestamp,
           unlockTimestamp: block.timestamp + lockPeriod,
            staker: msg.sender,
            active: true
        });
        
        // Update staking records
        _userStakedImpacts[msg.sender].push(stakedImpact);
        _tokenImpactStaked[tokenId] += impactAmount;
        totalImpactStaked += impactAmount;
        
        uint256 stakeId = _userStakedImpacts[msg.sender].length - 1;
        
        emit ImpactStaked(
            msg.sender,
            tokenId,
            impactAmount,
            lockPeriod,
            stakeId
        );
    }
    
    /**
     * @notice Allows user to unstake their impact and claim rewards
     * @dev Can only be called after the lock period has expired
     */
    function unstakeImpact(uint256 stakeId) external nonReentrant {
        require(stakeId < _userStakedImpacts[msg.sender].length, "Invalid stake ID");
        
        StakedImpact storage stake = _userStakedImpacts[msg.sender][stakeId];
        require(stake.active, "Stake not active");
        require(block.timestamp >= stake.unlockTimestamp, "Still locked");
        
        // Calculate reward based on lock period and amount
        uint256 stakingDuration = block.timestamp - stake.stakingTimestamp;
        uint256 rewardAmount = _calculateStakingReward(stake.impactAmount, stakingDuration);
        
        // Mark stake as inactive
        stake.active = false;
        
        // Update totals
        _tokenImpactStaked[stake.tokenId] -= stake.impactAmount;
        totalImpactStaked -= stake.impactAmount;
        
        // Transfer rewards
        require(tStakeToken.transfer(msg.sender, rewardAmount), "Reward transfer failed");
        
        emit ImpactUnstaked(
            msg.sender,
            stake.tokenId,
            stake.impactAmount,
            stakeId,
            rewardAmount
        );
    }
    
    /**
     * @notice Fractionalize a token into multiple parts
     * @dev Creates new fraction tokens based on the original
     */
    function fractionalizeToken(
        uint256 tokenId,
        uint256 fractionCount
    ) external nonReentrant {
        require(_exists(tokenId), "Token does not exist");
        require(balanceOf(msg.sender, tokenId) > 0, "Not token owner");
        require(fractionCount > 1 && fractionCount <= 100, "Invalid fraction count");
        
        // Handle fractionalization fee
        if (fractionalizationFee > 0) {
            require(tStakeToken.transferFrom(msg.sender, address(this), fractionalizationFee), "Fee transfer failed");
            _processFees(fractionalizationFee);
        }
        
        // Burn the original token
        _burn(msg.sender, tokenId, 1);
        
        // Generate a base ID for fractions
        uint256 fractionBaseId = totalMinted + 1;
        totalMinted += fractionCount;
        
        // Create fraction info
        FractionInfo storage fractionInfo = _fractionInfos[fractionBaseId];
        fractionInfo.originalTokenId = tokenId;
        fractionInfo.fractionBaseId = fractionBaseId;
        fractionInfo.fractionCount = fractionCount;
        fractionInfo.isActive = true;
        fractionInfo.fractionalizer = msg.sender;
        fractionInfo.fractionBalances[msg.sender] = fractionCount;
        
        // Mint fraction tokens
        for (uint256 i = 0; i < fractionCount; i++) {
            uint256 fractionId = fractionBaseId + i;
            _mint(msg.sender, fractionId, 1, "");
            
            // Copy metadata from original with fraction designation
            NFTMetadata memory originalMetadata = nftMetadata[tokenId];
            NFTMetadata memory fractionMetadata = originalMetadata;
            fractionMetadata.ipfsUri = string(abi.encodePacked(originalMetadata.ipfsUri, "/fraction/", _toString(i + 1), "_of_", _toString(fractionCount)));
            fractionMetadata.impactValue = originalMetadata.impactValue / fractionCount;
            fractionMetadata.performance.totalImpact = originalMetadata.performance.totalImpact / fractionCount;
            fractionMetadata.performance.verifiedImpact = originalMetadata.performance.verifiedImpact / fractionCount;
            fractionMetadata.version = 1;
            
            nftMetadata[fractionId] = fractionMetadata;
            metadataHistory[fractionId].push(fractionMetadata);
        }
        
        fractionalSupplies[fractionBaseId] = fractionCount;
        
        emit TokenFractionalized(
            tokenId,
            fractionBaseId,
            fractionCount,
            msg.sender
        );
    }
    
    // =====================================================
    // VRF Functions
    // =====================================================
    /**
     * @notice Requests randomness for token impact adjustment
     * @dev Internal function to interact with Chainlink VRF
     */
    function _requestRandomness(uint256 tokenId) internal {
        uint256 requestId = vrfCoordinator.requestRandomWords(
            keyHash,
            subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            1 // numWords
        );
        
        _randomnessRequests[requestId] = tokenId;
        
        emit RandomnessRequested(tokenId, requestId);
    }
    
    /**
     * @notice Callback function used by VRF Coordinator
     * @dev This function is called by the VRF Coordinator with random values
     */
    function fulfillRandomWords(
        uint256 requestId, 
        uint256[] memory randomWords
    ) internal override {
        uint256 tokenId = _randomnessRequests[requestId];
        uint256 randomValue = randomWords[0];
        
        _randomnessResults[tokenId] = randomValue;
        
        // Use randomness to adjust environmental impact metrics
        NFTMetadata storage metadata = nftMetadata[tokenId];
        
        // Create a pseudorandom adjustment between -5% and +10%
        int256 adjustment = (int256(randomValue % 150) - 50); // Range: -50 to +100
        
        if (adjustment > 0) {
            uint256 positiveAdjustment = uint256(adjustment) * metadata.impactValue / 1000; // +up to 10%
            metadata.impactValue += positiveAdjustment;
            metadata.performance.totalImpact += positiveAdjustment;
        } else if (adjustment < 0) {
            uint256 negativeAdjustment = uint256(-adjustment) * metadata.impactValue / 1000; // -up to 5%
            if (negativeAdjustment < metadata.impactValue) {
                metadata.impactValue -= negativeAdjustment;
                metadata.performance.totalImpact -= negativeAdjustment;
            }
        }
        
        // Update efficiency score based on randomness (0-100)
        metadata.performance.efficiencyScore = 50 + (randomValue % 51); // Range: 50-100
        metadata.performance.lastUpdated = block.timestamp;
        metadata.version += 1;
        
        // Update metadata history
        metadataHistory[tokenId].push(metadata);
        
        emit RandomnessReceived(requestId, randomValue);
    }
    
    // =====================================================
    // Fee Management and Processing
    // =====================================================
    /**
     * @notice Updates the minting fee
     * @dev Only governance can change the fee
     */
    function updateMintingFee(uint256 newFee) external onlyRole(GOVERNANCE_ROLE) {
        mintFee = newFee;
        emit MintingFeeUpdated(newFee);
    }
    
    /**
     * @notice Updates the verification fee
     * @dev Only governance can change the fee
     */
    function updateVerificationFee(uint256 newFee) external onlyRole(GOVERNANCE_ROLE) {
        verificationFee = newFee;
        emit VerificationFeeUpdated(newFee);
    }
    
    /**
     * @notice Updates the retirement fee
     * @dev Only governance can change the fee
     */
    function updateRetirementFee(uint256 newFee) external onlyRole(GOVERNANCE_ROLE) {
        retirementFee = newFee;
        emit RetirementFeeUpdated(newFee);
    }
    
    /**
     * @notice Updates the fractionalization fee
     * @dev Only governance can change the fee
     */
    function updateFractionalizationFee(uint256 newFee) external onlyRole(GOVERNANCE_ROLE) {
        fractionalizationFee = newFee;
        emit FractionalizationFeeUpdated(newFee);
    }
    
    /**
     * @notice Updates the fee distribution structure
     * @dev Only governance can change the distribution
     */
    function updateFeeDistribution(
        uint256 _stakingShare,
        uint256 _liquidityShare,
        uint256 _treasuryShare,
        uint256 _burnShare
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(_stakingShare + _liquidityShare + _treasuryShare + _burnShare == 100, "Shares must total 100");
        
        feeDistribution = FeeDistribution({
            stakingShare: _stakingShare,
            liquidityShare: _liquidityShare,
            treasuryShare: _treasuryShare,
            burnShare: _burnShare
        });
    }
    
    /**
     * @notice Processes collected fees according to the distribution structure
     * @dev Internal function called after fee collection
     */
    function _processFees(uint256 amount) internal {
        uint256 stakingAmount = amount * feeDistribution.stakingShare / 100;
        uint256 liquidityAmount = amount * feeDistribution.liquidityShare / 100;
        uint256 treasuryAmount = amount * feeDistribution.treasuryShare / 100;
        uint256 burnAmount = amount * feeDistribution.burnShare / 100;
        
        if (stakingAmount > 0) {
            require(tStakeToken.transfer(stakingRewards, stakingAmount), "Staking transfer failed");
        }
        
        if (liquidityAmount > 0) {
            require(tStakeToken.transfer(TERRA_POOL, liquidityAmount), "Liquidity transfer failed");
        }
        
        if (treasuryAmount > 0) {
            require(tStakeToken.transfer(treasuryWallet, treasuryAmount), "Treasury transfer failed");
        }
        
        if (burnAmount > 0) {
            tStakeToken.burn(burnAmount);
        }
        
        emit FeeDistributed(stakingAmount, liquidityAmount, treasuryAmount, burnAmount);
    }
    
    // =====================================================
    // View Functions and Utilities
    // =====================================================
    
    /**
     * @notice Get token metadata 
     * @param tokenId The ID of the token to retrieve metadata for
     * @return Complete metadata structure for the specified token
     */
    function getTokenMetadata(uint256 tokenId) external view returns (
        string memory ipfsUri,
        uint256 projectId,
        uint256 impactValue,
        bool isTradable,
        string memory location,
        uint256 capacity,
        uint256 certificationDate,
        string memory projectType,
        bool isVerified,
        uint256 version,
        PerformanceMetrics memory performance,
        uint256 mintingFee,
        bytes32 projectDataHash,
        bytes32 impactReportHash,
        address originalMinter,
        uint256 originalMintTimestamp,
        bytes32 verificationProofHash
    ) {
        require(_exists(tokenId), "Token does not exist");
        NFTMetadata memory metadata = nftMetadata[tokenId];
        
        return (
            metadata.ipfsUri,
            metadata.projectId,
            metadata.impactValue,
            metadata.isTradable,
            metadata.location,
            metadata.capacity,
            metadata.certificationDate,
            metadata.projectType,
            metadata.isVerified,
            metadata.version,
            metadata.performance,
            metadata.mintingFee,
            metadata.projectDataHash,
            metadata.impactReportHash,
            metadata.originalMinter,
            metadata.originalMintTimestamp,
            metadata.verificationProofHash
        );
    }
    
    /**
     * @notice Checks if a token exists
     * @dev Returns whether the token has been minted
     */
    function _exists(uint256 tokenId) internal view returns (bool) {
        return totalSupply(tokenId) > 0;
    }
    
    /**
     * @notice Get a token's metadata history
     * @param tokenId The token ID to query
     * @return Array of historical metadata records
     */
    function getTokenMetadataHistory(uint256 tokenId) external view returns (NFTMetadata[] memory) {
        require(_exists(tokenId), "Token does not exist");
        return metadataHistory[tokenId];
    }
    
    /**
     * @notice Retrieves the total impact for a project
     * @dev Uses caching for gas optimization
     */
    function getProjectTotalImpact(uint256 projectId) external view returns (uint256) {
        if (block.timestamp - _lastCacheUpdate[projectId] <= CACHE_VALIDITY_PERIOD) {
            return _cachedProjectImpact[projectId];
        }
        
        // If cache is stale, calculate on the fly
        uint256 total = 0;
        for (uint256 i = 1; i <= totalMinted; i++) {
            if (_exists(i) && nftMetadata[i].projectId == projectId) {
                total += nftMetadata[i].impactValue;
            }
        }
        
        return total;
    }
    
    /**
     * @notice Update the cached project impact
     * @dev Internal function to maintain efficient project impact tracking
     */
    function _updateImpactCache(uint256 projectId, uint256 additionalImpact) internal {
        _cachedProjectImpact[projectId] += additionalImpact;
        _lastCacheUpdate[projectId] = block.timestamp;
    }
    
    /**
     * @notice Calculate staking rewards based on staked amount and duration
     * @dev Internal function to compute rewards proportional to time and amount
     */
    function _calculateStakingReward(uint256 amount, uint256 duration) internal view returns (uint256) {
        // Annual reward rate in basis points (e.g., 500 = 5%)
        uint256 annualReward = amount * impactStakingRewardRate / 10000;
        
        // Calculate pro-rated reward based on staking duration
        return annualReward * duration / 365 days;
    }
    
    /**
     * @notice Converts a uint to a string
     * @dev Utility function for fraction metadata
     */
    function _toString(uint256 value) internal pure returns (string memory) {
        // Special case for 0
        if (value == 0) {
            return "0";
        }
        
        uint256 temp = value;
        uint256 digits;
        
        // Count the number of digits
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        
        bytes memory buffer = new bytes(digits);
        
        // Convert to string by getting individual digits
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        
        return string(buffer);
    }
    
    /**
     * @notice Updates the merkle root for verification
     * @dev Only verifiers can update the verification merkle root
     */
    function setVerificationMerkleRoot(uint256 tokenId, bytes32 merkleRoot) external onlyRole(VERIFIER_ROLE) {
        require(_exists(tokenId), "Token does not exist");
        _verificationMerkleRoots[tokenId] = merkleRoot;
    }
    
    /**
     * @notice Sets the staking reward rate
     * @dev Only governance can update the reward rate
     */
    function updateStakingRewardRate(uint256 newRate) external onlyRole(GOVERNANCE_ROLE) {
        require(newRate <= 2000, "Rate too high"); // Maximum 20%
        impactStakingRewardRate = newRate;
        emit StakingRewardRateUpdated(newRate);
    }
    
    /**
     * @notice Gets all active stakes for a user
     * @dev Returns array of active stake records
     */
    function getUserStakes(address user) external view returns (StakedImpact[] memory) {
        StakedImpact[] memory stakes = _userStakedImpacts[user];
        uint256 activeCount = 0;
        
        // Count active stakes first
        for (uint256 i = 0; i < stakes.length; i++) {
            if (stakes[i].active) {
                activeCount++;
            }
        }
        
        // Create array of active stakes
        StakedImpact[] memory activeStakes = new StakedImpact[](activeCount);
        uint256 j = 0;
        
        for (uint256 i = 0; i < stakes.length; i++) {
            if (stakes[i].active) {
                activeStakes[j] = stakes[i];
                j++;
            }
        }
        
        return activeStakes;
    }
    
    /**
     * @notice Gets token verification records
     * @dev Returns array of verification details
     */
    function getVerificationRecords(uint256 tokenId) external view returns (VerificationRecord[] memory) {
        require(_exists(tokenId), "Token does not exist");
        return verificationRecords[tokenId];
    }
    
    // =====================================================
    // ERC1155 Supply Overrides
    // =====================================================
    
    /**
     * @dev See {ERC1155-_beforeTokenTransfer}.
     */
    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal override(ERC1155Upgradeable, ERC1155SupplyUpgradeable) {
        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);
    }
    
    /**
     * @notice Checks if interface is supported
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
