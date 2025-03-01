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
    UUPSUpgradeable
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
    event MerkleRootSet(uint256 indexed tokenId, bytes32 merkleRoot);
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
    constructor() {
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
    // Administrative Functions
    // =====================================================
    function setMintingFee(uint256 newFee) external onlyRole(GOVERNANCE_ROLE) {
        mintFee = newFee;
        emit MintingFeeUpdated(newFee);
    }
    
    function setVerificationFee(uint256 newFee) external onlyRole(GOVERNANCE_ROLE) {
        verificationFee = newFee;
        emit VerificationFeeUpdated(newFee);
    }
    
    function setRetirementFee(uint256 newFee) external onlyRole(GOVERNANCE_ROLE) {
        retirementFee = newFee;
        emit RetirementFeeUpdated(newFee);
    }
    
    function setFractionalizationFee(uint256 newFee) external onlyRole(GOVERNANCE_ROLE) {
        fractionalizationFee = newFee;
        emit FractionalizationFeeUpdated(newFee);
    }
    
    function setStakingRewardRate(uint256 newRate) external onlyRole(GOVERNANCE_ROLE) {
        require(newRate <= 5000, "Rate too high"); // Max 50% annual
        impactStakingRewardRate = newRate;
        emit StakingRewardRateUpdated(newRate);
    }
    
    function setFeeDistribution(
        uint256 stakingShare,
        uint256 liquidityShare,
        uint256 treasuryShare,
        uint256 burnShare
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(
            stakingShare + liquidityShare + treasuryShare + burnShare == 100,
            "Shares must total 100"
        );
        
        feeDistribution.stakingShare = stakingShare;
        feeDistribution.liquidityShare = liquidityShare;
        feeDistribution.treasuryShare = treasuryShare;
        feeDistribution.burnShare = burnShare;
    }
    
    function setVRFParameters(
        bytes32 _keyHash,
        uint64 _subscriptionId,
        uint32 _callbackGasLimit,
        uint16 _requestConfirmations
    ) external onlyRole(GOVERNANCE_ROLE) {
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;
        callbackGasLimit = _callbackGasLimit;
        requestConfirmations = _requestConfirmations;
    }

    // =====================================================
    // Fee Distribution
    // =====================================================
    function distributeFee(uint256 fee) internal nonReentrant {
        uint256 stakingAmount = (fee * feeDistribution.stakingShare) / 100;
        uint256 liquidityAmount = (fee * feeDistribution.liquidityShare) / 100;
        uint256 treasuryAmount = (fee * feeDistribution.treasuryShare) / 100;
        uint256 burnAmount = (fee * feeDistribution.burnShare) / 100;

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
    // Project Verification Functions
    // =====================================================
    /**
     * @notice Retrieves comprehensive verification data for a project
     * @param projectId The project ID
     * @return projectDataHash Hash of the project data
     * @return impactReportHash Hash of the latest impact report
     * @return isVerified Verification status
     * @return totalImpact Total impact value
     * @return projectState Current state of the project
     */
    function getProjectVerificationData(uint256 projectId) public view returns (
        bytes32 projectDataHash,
        bytes32 impactReportHash,
        bool isVerified,
        uint256 totalImpact,
        ITerraStakeProjects.ProjectState projectState
    ) {
        // Get project data, impact reports, and analytics
        ITerraStakeProjects.ProjectData memory data;
        ITerraStakeProjects.ProjectStateData memory stateData;
        ITerraStakeProjects.ProjectAnalytics memory analytics;
        
        // Use batch function to efficiently get all data in one call
        uint256[] memory projectIds = new uint256[](1);
        projectIds[0] = projectId;
        
        (
            ITerraStakeProjects.ProjectData[] memory metadataArray, 
            ITerraStakeProjects.ProjectStateData[] memory stateArray,
            ITerraStakeProjects.ProjectAnalytics[] memory analyticsArray
        ) = terraStakeProjects.batchGetProjectDetails(projectIds);
        
        data = metadataArray[0];
        stateData = stateArray[0];
        analytics = analyticsArray[0];
        
        // Get impact reports
        ITerraStakeProjects.ImpactReport[] memory reports = terraStakeProjects.getImpactReports(projectId);
        
        projectDataHash = data.ipfsHash;
        impactReportHash = reports.length > 0 ? reports[reports.length - 1].reportHash : bytes32(0);
        isVerified = data.exists && (reports.length > 0);
        totalImpact = analytics.totalImpact;
        projectState = stateData.state;
        
        return (projectDataHash, impactReportHash, isVerified, totalImpact, projectState);
    }

    /**
     * @notice Comprehensive project verification with multiple checks
     * @param projectId The project ID to verify
     * @return verificationStatus True if project passes all verification checks
     * @return verificationData Structured data about verification status
     */
    function verifyProjectIntegrity(uint256 projectId) public view returns (
        bool verificationStatus,
        bytes memory verificationData
    ) {
        (
            bytes32 projectHash, 
            bytes32 impactHash, 
            bool verified, 
            uint256 impact,
            ITerraStakeProjects.ProjectState state
        ) = getProjectVerificationData(projectId);
        
        // Check all verification criteria
        bool hashesValid = projectHash != bytes32(0) && impactHash != bytes32(0);
        bool stateValid = state == ITerraStakeProjects.ProjectState.Active;
        bool impactValid = impact > 0;
        
        // Encode verification data for on-chain storage
        verificationData = abi.encode(
            projectHash,
            impactHash,
            verified,
            impact,
            state,
            hashesValid,
            stateValid,
            impactValid,
            block.timestamp
        );
        
        verificationStatus = verified && hashesValid && stateValid && impactValid;
        return (verificationStatus, verificationData);
    }

    /**
     * @notice Set a Merkle root for additional off-chain verification data
     * @param tokenId The token ID to set the Merkle root for
     * @param merkleRoot The Merkle root of the verification data
     */
    function setVerificationMerkleRoot(uint256 tokenId, bytes32 merkleRoot) 
        external 
        onlyRole(VERIFIER_ROLE) 
    {
        require(_exists(tokenId), "Token does not exist");
        _verificationMerkleRoots[tokenId] = merkleRoot;
        emit MerkleRootSet(tokenId, merkleRoot);
    }

    /**
     * @notice Verify data against a Merkle proof for additional verification
     * @param tokenId The token ID to verify the data for
     * @param data The data to verify
     * @param proof The Merkle proof
     * @return True if the data is verified
     */
    function verifyDataWithMerkleProof(uint256 tokenId, bytes32 data, bytes32[] calldata proof) 
        public 
        view 
        returns (bool) 
    {
        bytes32 merkleRoot = _verificationMerkleRoots[tokenId];
        require(merkleRoot != bytes32(0), "No Merkle root set");
        return MerkleProof.verify(proof, merkleRoot, data);
    }

    // =====================================================
    // Carbon Credit Retirement
    // =====================================================
    /**
     * @notice Retires carbon credits represented by a token, making them non-transferable
     * @param tokenId The token ID to retire
     * @param amount The amount of carbon credits to retire (CO2e)
     * @param retirementBeneficiary Who receives the retirement benefit
     * @param retirementReason Reason for retirement (offsetting, etc.)
     * @return retirementId Unique identifier for this retirement event
     */
    function retireCarbonCredits(
        uint256 tokenId, 
        uint256 amount, 
        address retirementBeneficiary,
        string calldata retirementReason
    ) external nonReentrant returns (bytes32 retirementId) {
        require(_exists(tokenId), "Token does not exist");
        require(balanceOf(msg.sender, tokenId) > 0, "Not token owner");
        require(tStakeToken.transferFrom(msg.sender, address(this), retirementFee), "Fee transfer failed");
        
        NFTMetadata storage metadata = nftMetadata[tokenId];
        require(metadata.performance.carbonOffset >= amount, "Insufficient carbon credits");
        
        // Reduce available carbon in token
        metadata.performance.carbonOffset -= amount;
        
        // Generate unique retirement ID
        retirementId = keccak256(abi.encodePacked(
            tokenId, amount, block.timestamp, retirementBeneficiary, msg.sender
        ));
        
        require(!retirementRegistry[retirementId], "Retirement already exists");
        retirementRegistry[retirementId] = true;
        
        // Record retirement details
        CarbonRetirement memory retirement = CarbonRetirement({
            tokenId: tokenId,
            amount: amount,
            retiringEntity: msg.sender,
            beneficiary: retirementBeneficiary,
            reason: retirementReason,
            timestamp: block.timestamp,
            retirementId: retirementId
        });
        
        carbonRetirements[retirementId] = retirement;
        totalCarbonRetired += amount;
        
        // Record retirement in history
        emit CarbonCreditsRetired(
            tokenId, amount, msg.sender, retirementBeneficiary, 
            retirementReason, retirementId, block.timestamp
        );
        
        // Update token metadata
        metadata.version++;
        metadataHistory[tokenId].push(metadata);
        
        // Distribute fee
        distributeFee(retirementFee);
        
        return retirementId;
    }
    
    /**
     * @notice Batch retires carbon credits from multiple tokens
     * @param tokenIds Array of token IDs
     * @param amounts Array of carbon credit amounts to retire
     * @param beneficiary Retirement beneficiary address
     * @param reason Retirement reason
     * @return retirementIds Array of unique retirement identifiers
     */
    function batchRetireCarbonCredits(
        uint256[] calldata tokenIds,
        uint256[] calldata amounts,
        address beneficiary,
        string calldata reason
    ) external nonReentrant returns (bytes32[] memory) {
        uint256 length = tokenIds.length;
        require(length <= MAX_BATCH_SIZE, "Batch too large");
        require(length == amounts.length, "Array lengths mismatch");
        require(tStakeToken.transferFrom(msg.sender, address(this), retirementFee * length), "Fee transfer failed");
        
        bytes32[] memory retirementIds = new bytes32[](length);
        uint256 totalAmount = 0;
        
        for (uint256 i = 0; i < length;) {
            require(_exists(tokenIds[i]), "Token does not exist");
            require(balanceOf(msg.sender, tokenIds[i]) > 0, "Not token owner");
            
            NFTMetadata storage metadata = nftMetadata[tokenIds[i]];
            require(metadata.performance.carbonOffset >= amounts[i], "Insufficient carbon credits");
            
            // Reduce available carbon in token
            metadata.performance.carbonOffset -= amounts[i];
            
            // Generate unique retirement ID
            retirementIds[i] = keccak256(abi.encodePacked(
                tokenIds[i], amounts[i], block.timestamp, beneficiary, msg.sender, i
            ));
            
            require(!retirementRegistry[retirementIds[i]], "Retirement already exists");
            retirementRegistry[retirementIds[i]] = true;
            
            // Record retirement details
            CarbonRetirement memory retirement = CarbonRetirement({
                tokenId: tokenIds[i],
                amount: amounts[i],
                retiringEntity: msg.sender,
                beneficiary: beneficiary,
                reason: reason,
                timestamp: block.timestamp,
                retirementId: retirementIds[i]
            });
            
            carbonRetirements[retirementIds[i]] = retirement;
            totalAmount += amounts[i];
            
            // Record retirement in history
            emit CarbonCreditsRetired(
                tokenIds[i], amounts[i], msg.sender, beneficiary, 
                reason, retirementIds[i], block.timestamp
            );
            
            // Update token metadata
            metadata.version++;
            metadataHistory[tokenIds[i]].push(metadata);
            
            unchecked { ++i; }
        }
        
        totalCarbonRetired += totalAmount;
        
        // Distribute fee
        distributeFee(retirementFee * length);
        
        return retirementIds;
    }

    // =====================================================
    // Impact Staking Functionality
    // =====================================================
    /**
     * @notice Stakes impact from a token to earn additional rewards
     * @param tokenId The token ID containing environmental impact
     * @param impactAmount Amount of impact value to stake
     * @param lockPeriod Period in seconds to lock the stake
     * @return stakeId Index of the stake in user's stake array
     */
    function stakeTokenImpact(
        uint256 tokenId, 
        uint256 impactAmount,
        uint256 lockPeriod
    ) external nonReentrant returns (uint256 stakeId) {
        require(_exists(tokenId), "Token does not exist");
        require(balanceOf(msg.sender, tokenId) > 0, "Not token owner");
        require(lockPeriod >= 7 days && lockPeriod <= 365 days, "Invalid lock period");
        
        NFTMetadata storage metadata = nftMetadata[tokenId];
        uint256 availableImpact = metadata.impactValue - _tokenImpactStaked[tokenId];
        require(availableImpact >= impactAmount, "Insufficient available impact");
        
        // Create stake
        StakedImpact memory stake = StakedImpact({
            tokenId: tokenId,
            impactAmount: impactAmount,
            stakingTimestamp: block.timestamp,
            unlockTimestamp: block.timestamp + lockPeriod,
            staker: msg.sender,
            active: true
        });
        
        _userStakedImpacts[msg.sender].push(stake);
        stakeId = _userStakedImpacts[msg.sender].length - 1;
        
        // Update token staked impact
        _tokenImpactStaked[tokenId] += impactAmount;
        totalImpactStaked += impactAmount;
        
        emit ImpactStaked(msg.sender, tokenId, impactAmount, lockPeriod, stakeId);
        
        return stakeId;
    }
    
    /**
     * @notice Unstakes impact and claims rewards
     * @param stakeId The ID of the stake to unstake
     * @return rewardAmount Amount of tokens rewarded
     */
    function unstakeImpact(uint256 stakeId) external nonReentrant returns (uint256 rewardAmount) {
        require(stakeId < _userStakedImpacts[msg.sender].length, "Invalid stake ID");
        StakedImpact storage stake = _userStakedImpacts[msg.sender][stakeId];
        
        require(stake.active, "Stake not active");
        require(block.timestamp >= stake.unlockTimestamp, "Stake still locked");
        
        // Calculate reward amount
        uint256 duration = stake.unlockTimestamp - stake.stakingTimestamp;
        rewardAmount = (stake.impactAmount * duration * impactStakingRewardRate) / (365 days * 10000);
        
        // Transfer reward
        require(tStakeToken.transfer(msg.sender, rewardAmount), "Reward transfer failed");
        
        // Update token staked impact
        _tokenImpactStaked[stake.tokenId] -= stake.impactAmount;
        totalImpactStaked -= stake.impactAmount;
        
        // Mark stake as inactive
        stake.active = false;
        
        emit ImpactUnstaked(msg.sender, stake.tokenId, stake.impactAmount, stakeId, rewardAmount);
        
        return rewardAmount;
    }
    
    /**
     * @notice Gets all staked impacts for a user
     * @param user The user address
     * @return Array of staked impacts
     */
    function getUserStakedImpacts(address user) external view returns (StakedImpact[] memory) {
        return _userStakedImpacts[user];
    }
    
    /**
     * @notice Calculates pending rewards for a stake
     * @param user User address
     * @param stakeId Stake ID
     * @return pendingReward Calculated pending reward
     */
    function calculatePendingRewards(address user, uint256 stakeId) external view returns (uint256 pendingReward) {
        require(stakeId < _userStakedImpacts[user].length, "Invalid stake ID");
        StakedImpact storage stake = _userStakedImpacts[user][stakeId];
        
        if (!stake.active) return 0;
        
        uint256 duration = block.timestamp < stake.unlockTimestamp ? 
            block.timestamp - stake.stakingTimestamp : 
            stake.unlockTimestamp - stake.stakingTimestamp;
            
        pendingReward = (stake.impactAmount * duration * impactStakingRewardRate) / (365 days * 10000);
        return pendingReward;
    }

    // =====================================================
    // Enhanced Impact Verification
    // =====================================================
    /**
     * @notice Allows authorized verifiers to formally verify project impact claims
     * @param tokenId The token ID to verify
     * @param impactVerificationData Multi-dimensional verification data points
     * @param externalVerifierId ID from external verification registry (optional)
     * @param verificationProof Cryptographic proof of verification process
     */
    function verifyTokenImpact(
        uint256 tokenId,
        bytes calldata impactVerificationData,
        string calldata externalVerifierId,
        bytes32 verificationProof
    ) external onlyRole(VERIFIER_ROLE) nonReentrant {
        require(_exists(tokenId), "Token does not exist");
        require(tStakeToken.transferFrom(msg.sender, address(this), verificationFee), "Fee transfer failed");
        
        NFTMetadata storage metadata = nftMetadata[tokenId];
        
        // Extract verification parameters
        (
            uint256 verifiedImpactAmount,
            uint256 verificationTimestamp,
            string memory methodologyId,
            string memory verifierName
        ) = abi.decode(impactVerificationData, (uint256, uint256, string, string));
        
        // Update verification status
        metadata.isVerified = true;
        metadata.performance.verifiedImpact = verifiedImpactAmount;
        metadata.performance.lastUpdated = block.timestamp;
        metadata.performance.metricHash = keccak256(abi.encodePacked(
            verifiedImpactAmount,
            methodologyId,
            verificationTimestamp,
            verificationProof
        ));
        
        // Create verification record
        VerificationRecord memory record = VerificationRecord({
            tokenId: tokenId,
            verifiedAmount: verifiedImpactAmount,
            timestamp: block.timestamp,
            methodologyId: methodologyId,
            verifierName: verifierName,
            externalVerifierId: externalVerifierId,
            verificationProof: verificationProof,
            verifier: msg.sender
        });
        
        // Store verification record
        verificationRecords[tokenId].push(record);
        totalVerifications++;
        
        // Record detailed verification event
        emit ImpactVerified(
            tokenId,
            verifiedImpactAmount,
            verificationTimestamp,
            methodologyId,
            verifierName,
            externalVerifierId,
            verificationProof
        );
        
        // Update metadata history
        metadata.version++;
        metadataHistory[tokenId].push(metadata);
        
        // Distribute verification fee
        distributeFee(verificationFee);
    }
    
    /**
     * @notice Batch verification of multiple tokens
     * @param tokenIds Array of token IDs to verify
     * @param verificationData Array of encoded verification data
     * @param externalIds Array of external verifier IDs
     * @param proofs Array of verification proofs
     */
    function batchVerifyTokens(
        uint256[] calldata tokenIds,
        bytes[] calldata verificationData,
        string[] calldata externalIds,
        bytes32[] calldata proofs
    ) external onlyRole(VERIFIER_ROLE) nonReentrant {
        uint256 length = tokenIds.length;
        require(length <= MAX_BATCH_SIZE, "Batch too large");
        require(length == verificationData.length && length == externalIds.length && length == proofs.length, 
                "Array lengths mismatch");
        require(tStakeToken.transferFrom(msg.sender, address(this), verificationFee * length), "Fee transfer failed");
        
        for(uint256 i = 0; i < length;) {
            require(_exists(tokenIds[i]), "Token does not exist");
            
            NFTMetadata storage metadata = nftMetadata[tokenIds[i]];
            
            // Extract verification parameters
            (
                uint256 verifiedImpactAmount,
                uint256 verificationTimestamp,
                string memory methodologyId,
                string memory verifierName
            ) = abi.decode(verificationData[i], (uint256, uint256, string, string));
            
            // Update verification status
            metadata.isVerified = true;
            metadata.performance.verifiedImpact = verifiedImpactAmount;
            metadata.performance.lastUpdated = block.timestamp;
            metadata.performance.metricHash = keccak256(abi.encodePacked(
                verifiedImpactAmount,
                methodologyId,
                verificationTimestamp,
                proofs[i]
            ));
            
            // Create and store verification record
            VerificationRecord memory record = VerificationRecord({
                tokenId: tokenIds[i],
                verifiedAmount: verifiedImpactAmount,
                timestamp: block.timestamp,
                methodologyId: methodologyId,
                verifierName: verifierName,
                externalVerifierId: externalIds[i],
                verificationProof: proofs[i],
                verifier: msg.sender
            });
            
            verificationRecords[tokenIds[i]].push(record);
            
            // Record event
            emit ImpactVerified(
                tokenIds[i],
                verifiedImpactAmount,
                verificationTimestamp,
                methodologyId,
                verifierName,
                externalIds[i],
                proofs[i]
            );
            
            // Update metadata
            metadata.version++;
            metadataHistory[tokenIds[i]].push(metadata);
            
            unchecked { ++i; }
        }
        
        totalVerifications += length;
        distributeFee(verificationFee * length);
    }

    // =====================================================
    // Impact NFT Fractionalization
    // =====================================================
    /**
     * @notice Fractionalizes a token into smaller units for broader ownership
     * @param tokenId The token ID to fractionalize
     * @param fractionCount Number of fractions to create
     * @param recipients Array of recipient addresses
     * @param fractionAmounts Array of fraction amounts per recipient
     * @return fractionId Identifier for this fractionalization
     */
    function fractionalizeToken(
        uint256 tokenId,
        uint256 fractionCount,
        address[] calldata recipients,
        uint256[] calldata fractionAmounts
    ) external nonReentrant returns (uint256 fractionId) {
        require(_exists(tokenId), "Token does not exist");
        require(balanceOf(msg.sender, tokenId) > 0, "Not token owner");
        require(recipients.length == fractionAmounts.length, "Array length mismatch");
        require(tStakeToken.transferFrom(msg.sender, address(this), fractionalizationFee), "Fee transfer failed");
        
        uint256 totalFractions = 0;
        for (uint256 i = 0; i < fractionAmounts.length; i++) {
            totalFractions += fractionAmounts[i];
        }
        require(totalFractions == fractionCount, "Fraction sum mismatch");
        
        // Burn the original token
        _burn(msg.sender, tokenId, 1);
        
        // Create a new token ID for fractions
        uint256 newFractionBaseId = totalMinted + 1;
        totalMinted++;
        
        // Set up fraction info
        FractionInfo storage fractionInfo = _fractionInfos[newFractionBaseId];
        fractionInfo.originalTokenId = tokenId;
        fractionInfo.fractionBaseId = newFractionBaseId;
        fractionInfo.fractionCount = fractionCount;
        fractionInfo.isActive = true;
        fractionInfo.fractionalizer = msg.sender;
        
        // Mint fractions to recipients
        for (uint256 i = 0; i < recipients.length; i++) {
            if (fractionAmounts[i] > 0) {
                _mint(recipients[i], newFractionBaseId, fractionAmounts[i], "");
                fractionInfo.fractionBalances[recipients[i]] = fractionAmounts[i];
            }
        }
        
        // Track total supply of this fraction
        fractionalSupplies[newFractionBaseId] = fractionCount;
        
        // Copy metadata but mark as fraction
        NFTMetadata storage originalMetadata = nftMetadata[tokenId];
        NFTMetadata memory fractionMetadata = originalMetadata;
        fractionMetadata.version = 1;
        
        // Update metadata to indicate fractionalization
        nftMetadata[newFractionBaseId] = fractionMetadata;
        metadataHistory[newFractionBaseId].push(fractionMetadata);
        
        // Distribute fee
        distributeFee(fractionalizationFee);
        
        emit TokenFractionalized(tokenId, newFractionBaseId, fractionCount, msg.sender);
        
        return newFractionBaseId;
    }
    
    /**
     * @notice Reunifies fractions back into a whole token
     * @param fractionBaseId The base ID of the fractions
     * @return newTokenId ID of the reunified token
     */
    function reunifyFractions(uint256 fractionBaseId) external nonReentrant returns (uint256 newTokenId) {
        require(_fractionInfos[fractionBaseId].isActive, "Not an active fraction");
        require(balanceOf(msg.sender, fractionBaseId) == fractionalSupplies[fractionBaseId], 
                "Must own all fractions");
        
        // Burn all fractions
        _burn(msg.sender, fractionBaseId, fractionalSupplies[fractionBaseId]);
        
        // Create new token ID for reunified token
        newTokenId = ++totalMinted;
        
        // Mint reunified token
        _mint(msg.sender, newTokenId, 1, "");
        
        // Copy metadata from fractions
        nftMetadata[newTokenId] = nftMetadata[fractionBaseId];
        nftMetadata[newTokenId].version++;
        metadataHistory[newTokenId].push(nftMetadata[newTokenId]);
        
        // Deactivate fraction
        _fractionInfos[fractionBaseId].isActive = false;
        
        emit FractionsReunified(fractionBaseId, newTokenId, msg.sender);
        
        return newTokenId;
    }

    // =====================================================
    // Minting Functionality with Enhanced Verification
    // =====================================================
    /**
     * @notice Mints a new NFT with comprehensive project data and verification
     * @param to The recipient address
     * @param projectId The associated project ID
     * @param impactValue The impact value of the project
     * @param ipfsUri The IPFS URI pointing to the rich JSON metadata
     * @param isTradable Whether the NFT is tradable
     * @param location Project location
     * @param capacity Project capacity
     * @param certificationDate Certification date timestamp
     * @param projectType Type of the project
     * @return tokenId The ID of the minted token
     */
    function mint(
        address to,
        uint256 projectId,
        uint256 impactValue,
        string memory ipfsUri,
        bool isTradable,
        string memory location,
        uint256 capacity,
        uint256 certificationDate,
        string memory projectType
    ) external nonReentrant onlyRole(MINTER_ROLE) returns (uint256) {
        require(to != address(0), "Invalid recipient");
        require(tStakeToken.transferFrom(msg.sender, address(this), mintFee), "Fee transfer failed");
        
        // Enhanced project verification
        (bool verified, bytes memory verificationData) = verifyProjectIntegrity(projectId);
        require(verified, "Project verification failed");
                // Extract verification data
        (
            bytes32 projectDataHash,
            bytes32 impactReportHash,
            ,,,,,,,
        ) = abi.decode(
            verificationData, 
            (bytes32, bytes32, bool, uint256, ITerraStakeProjects.ProjectState, bool, bool, bool, uint256)
        );
        
        // Create token
        uint256 tokenId = ++totalMinted;
        
        // Create verification proof hash
        bytes32 verificationProofHash = keccak256(
            abi.encodePacked(
                projectId,
                projectDataHash,
                impactReportHash,
                impactValue,
                block.timestamp,
                msg.sender,
                to
            )
        );
        
        // Mint token
        _mint(to, tokenId, 1, "");
        
        // Store project hash
        _projectHashes[tokenId] = projectDataHash;
        
        // Create performance metrics
        PerformanceMetrics memory perfMetrics = PerformanceMetrics(
            impactValue,
            impactValue / 2, // Initial carbon offset is half of impact value
            85, // Base efficiency score
            block.timestamp,
            impactValue,
            keccak256(abi.encodePacked(impactValue, block.timestamp))
        );
        
        // Create metadata
        NFTMetadata memory newMetadata = NFTMetadata(
            ipfsUri,
            projectId,
            impactValue,
            isTradable,
            location,
            capacity,
            certificationDate,
            projectType,
            verified,
            1,
            perfMetrics,
            mintFee,
            projectDataHash,
            impactReportHash,
            to,
            block.timestamp,
            verificationProofHash
        );
        
        // Store metadata
        nftMetadata[tokenId] = newMetadata;
        metadataHistory[tokenId].push(newMetadata);
        
        // Distribute fee
        distributeFee(mintFee);
        
        emit NFTMinted(to, tokenId, projectId, projectDataHash);
        emit VerificationProofAdded(tokenId, verificationProofHash);
        
        return tokenId;
    }
    
    /**
     * @notice Batch mints NFTs with significant gas optimization
     * @param recipients Array of recipient addresses
     * @param projectIds Array of associated project IDs
     * @param impactValues Array of impact values
     * @param ipfsUris Array of IPFS URIs for metadata
     * @param tradableFlags Array of tradable flags
     * @param locations Array of project locations
     * @param capacities Array of project capacities
     * @param certificationDates Array of certification dates
     * @param projectTypes Array of project types
     * @return tokenIds Array of minted token IDs
     */
    function batchMint(
        address[] calldata recipients,
        uint256[] calldata projectIds,
        uint256[] calldata impactValues,
        string[] calldata ipfsUris,
        bool[] calldata tradableFlags,
        string[] calldata locations,
        uint256[] calldata capacities,
        uint256[] calldata certificationDates,
        string[] calldata projectTypes
    ) external nonReentrant onlyRole(MINTER_ROLE) returns (uint256[] memory) {
        uint256 batchSize = recipients.length;
        require(batchSize <= MAX_BATCH_SIZE, "Batch too large");
        require(
            projectIds.length == batchSize &&
            impactValues.length == batchSize &&
            ipfsUris.length == batchSize &&
            tradableFlags.length == batchSize &&
            locations.length == batchSize &&
            capacities.length == batchSize &&
            certificationDates.length == batchSize &&
            projectTypes.length == batchSize,
            "Array lengths mismatch"
        );
        
        uint256 totalFee = mintFee * batchSize;
        require(tStakeToken.transferFrom(msg.sender, address(this), totalFee), "Fee transfer failed");
        
        uint256[] memory tokenIds = new uint256[](batchSize);
        
        for (uint256 i = 0; i < batchSize;) {
            require(recipients[i] != address(0), "Invalid recipient");
            
            // Verify project
            (bool verified, bytes memory verificationData) = verifyProjectIntegrity(projectIds[i]);
            require(verified, "Project verification failed");
            
            // Extract verification data
            (
                bytes32 projectDataHash,
                bytes32 impactReportHash,
                ,,,,,,,
            ) = abi.decode(
                verificationData, 
                (bytes32, bytes32, bool, uint256, ITerraStakeProjects.ProjectState, bool, bool, bool, uint256)
            );
            
            // Create verification proof hash
            bytes32 verificationProofHash = keccak256(
                abi.encodePacked(
                    projectIds[i],
                    projectDataHash,
                    impactReportHash,
                    impactValues[i],
                    block.timestamp,
                    msg.sender,
                    recipients[i],
                    i // Include index for uniqueness
                )
            );
            
            uint256 tokenId = ++totalMinted;
            tokenIds[i] = tokenId;
            
            // Mint token
            _mint(recipients[i], tokenId, 1, "");
            
            // Store project hash
            _projectHashes[tokenId] = projectDataHash;
            
            // Create performance metrics
            PerformanceMetrics memory perfMetrics = PerformanceMetrics(
                impactValues[i],
                impactValues[i] / 2,
                85,
                block.timestamp,
                impactValues[i],
                keccak256(abi.encodePacked(impactValues[i], block.timestamp))
            );
            
            // Create metadata
            NFTMetadata memory newMetadata = NFTMetadata(
                ipfsUris[i],
                projectIds[i],
                impactValues[i],
                tradableFlags[i],
                locations[i],
                capacities[i],
                certificationDates[i],
                projectTypes[i],
                verified,
                1,
                perfMetrics,
                mintFee,
                projectDataHash,
                impactReportHash,
                recipients[i],
                block.timestamp,
                verificationProofHash
            );
            
            // Store metadata
            nftMetadata[tokenId] = newMetadata;
            metadataHistory[tokenId].push(newMetadata);
            
            emit NFTMinted(recipients[i], tokenId, projectIds[i], projectDataHash);
            emit VerificationProofAdded(tokenId, verificationProofHash);
            
            unchecked { ++i; }
        }
        
        // Distribute fee
        distributeFee(totalFee);
        
        return tokenIds;
    }

    // =====================================================
    // Metadata Management
    // =====================================================
    function updateTokenMetadata(
        uint256 tokenId, 
        string memory newIpfsUri,
        bool updateTradable,
        bool newTradableState
    ) external onlyRole(MINTER_ROLE) {
        require(_exists(tokenId), "Token does not exist");
        
        NFTMetadata storage metadata = nftMetadata[tokenId];
        metadata.ipfsUri = newIpfsUri;
        
        if (updateTradable) {
            metadata.isTradable = newTradableState;
        }
        
        metadata.version++;
        metadataHistory[tokenId].push(metadata);
        
        bytes32 metadataHash = keccak256(abi.encodePacked(tokenId, newIpfsUri, metadata.version));
        emit MetadataUpdated(tokenId, newIpfsUri, metadata.version, metadataHash);
    }
    
    function updatePerformanceMetrics(
        uint256 tokenId,
        uint256 newTotalImpact,
        uint256 newCarbonOffset,
        uint256 newEfficiencyScore
    ) external onlyRole(VERIFIER_ROLE) {
        require(_exists(tokenId), "Token does not exist");
        
        NFTMetadata storage metadata = nftMetadata[tokenId];
        
        metadata.performance.totalImpact = newTotalImpact;
        metadata.performance.carbonOffset = newCarbonOffset;
        metadata.performance.efficiencyScore = newEfficiencyScore;
        metadata.performance.lastUpdated = block.timestamp;
        metadata.performance.metricHash = keccak256(abi.encodePacked(
            newTotalImpact,
            newCarbonOffset,
            newEfficiencyScore,
            block.timestamp
        ));
        
        metadata.version++;
        metadataHistory[tokenId].push(metadata);
        
        bytes32 metadataHash = keccak256(abi.encodePacked(tokenId, metadata.ipfsUri, metadata.version));
        emit MetadataUpdated(tokenId, metadata.ipfsUri, metadata.version, metadataHash);
    }
    
    function getTokenMetadataHistory(uint256 tokenId) external view returns (NFTMetadata[] memory) {
        require(_exists(tokenId), "Token does not exist");
        return metadataHistory[tokenId];
    }

    // =====================================================
    // Chainlink VRF Functions
    // =====================================================
    /**
     * @notice Requests randomness for environmental benefit determination
     * @param tokenId The token ID to get random value for
     * @return requestId The VRF request ID
     */
    function requestRandomness(uint256 tokenId) external onlyRole(MINTER_ROLE) returns (uint256 requestId) {
        require(_exists(tokenId), "Token does not exist");
        
        requestId = VRFCoordinatorV2Interface(vrfCoordinatorAddress).requestRandomWords(
            keyHash,
            subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            1
        );
        
        _randomnessRequests[requestId] = tokenId;
        emit RandomnessRequested(tokenId, requestId);
        
        return requestId;
    }
    
    /**
     * @notice Callback function used by VRF Coordinator
     * @param requestId The request ID
     * @param randomWords The random result
     */
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal {
        uint256 tokenId = _randomnessRequests[requestId];
        uint256 randomValue = randomWords[0];
        _randomnessResults[tokenId] = randomValue;
        
        // Use randomness to adjust environmental impact metrics
        NFTMetadata storage metadata = nftMetadata[tokenId];
        
        // Randomized adjustments to impact values (±10%)
        uint256 impactAdjustment = (metadata.impactValue * (randomValue % 21)) / 100;
        if (randomValue % 2 == 0) {
            metadata.performance.totalImpact += impactAdjustment;
            metadata.performance.carbonOffset += impactAdjustment / 2;
        } else {
            if (metadata.performance.totalImpact > impactAdjustment) {
                metadata.performance.totalImpact -= impactAdjustment;
            }
            if (metadata.performance.carbonOffset > impactAdjustment / 2) {
                metadata.performance.carbonOffset -= impactAdjustment / 2;
            }
        }
        
        // Update metadata version
        metadata.version++;
        metadataHistory[tokenId].push(metadata);
        
        emit RandomnessReceived(requestId, randomValue);
    }
    
    function getRandomnessResult(uint256 tokenId) external view returns (uint256) {
        require(_exists(tokenId), "Token does not exist");
        return _randomnessResults[tokenId];
    }

    // =====================================================
    // ERC-1155 Overrides with Enhanced Functionality
    // =====================================================
    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal override(ERC1155Upgradeable, ERC1155SupplyUpgradeable) {
        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);
        
        // Check if tokens are tradable
        for (uint256 i = 0; i < ids.length; i++) {
            if (from != address(0) && to != address(0)) { // Skip minting and burning
                require(nftMetadata[ids[i]].isTradable, "Token not tradable");
            }
        }
    }
    
    function setApprovalForAll(address operator, bool approved) public override {
        require(operator != address(0), "Operator cannot be zero address");
        super.setApprovalForAll(operator, approved);
    }
    
    function uri(uint256 tokenId) public view override returns (string memory) {
        require(_exists(tokenId), "Token does not exist");
        return nftMetadata[tokenId].ipfsUri;
    }
    
    function _exists(uint256 tokenId) internal view returns (bool) {
        return totalSupply(tokenId) > 0;
    }
    
    // =====================================================
    // Utility Functions
    // =====================================================
    /**
     * @notice Efficiently calculates total impact across a batch of tokens
     * @param tokenIds Array of token IDs
     * @return totalImpact Combined total impact
     * @return carbonOffset Combined carbon offset
     */
    function batchGetImpact(uint256[] calldata tokenIds) external view returns (
        uint256 totalImpact,
        uint256 carbonOffset
    ) {
        uint256 length = tokenIds.length;
        for (uint256 i = 0; i < length;) {
            if (_exists(tokenIds[i])) {
                NFTMetadata storage metadata = nftMetadata[tokenIds[i]];
                totalImpact += metadata.performance.totalImpact;
                carbonOffset += metadata.performance.carbonOffset;
            }
            unchecked { ++i; }
        }
        
        return (totalImpact, carbonOffset);
    }
    
    /**
     * @notice Get cached project impact with automatic refresh
     * @param projectId The project ID
     * @return impact The current total impact for the project
     */
    function getProjectImpact(uint256 projectId) external returns (uint256 impact) {
        if (block.timestamp > _lastCacheUpdate[projectId] + CACHE_VALIDITY_PERIOD) {
            // Cache expired, refresh from project contract
            ITerraStakeProjects.ProjectAnalytics memory analytics = terraStakeProjects.getProjectAnalytics(projectId);
            _cachedProjectImpact[projectId] = analytics.totalImpact;
            _lastCacheUpdate[projectId] = block.timestamp;
        }
        
        return _cachedProjectImpact[projectId];
    }
    
    /**
     * @notice Calculate remaining carbon offset available for a token
     * @param tokenId The token ID
     * @return remainingOffset Amount of carbon offset remaining
     */
    function getRemainingCarbonOffset(uint256 tokenId) external view returns (uint256) {
        require(_exists(tokenId), "Token does not exist");
        return nftMetadata[tokenId].performance.carbonOffset;
    }
    
    /**
     * @notice Allows recovery of accidentally sent ERC20 tokens
     * @param tokenAddress The address of the token to recover
     * @param amount The amount to recover
     */
    function recoverERC20(address tokenAddress, uint256 amount) external onlyRole(GOVERNANCE_ROLE) {
        require(tokenAddress != address(tStakeToken), "Cannot recover governance token");
        IERC20Upgradeable token = IERC20Upgradeable(tokenAddress);
        token.transfer(treasuryWallet, amount);
    }
    
    /**
     * @notice Checks if contract supports a given interface
     * @param interfaceId The interface identifier
     * @return True if supported
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
    
    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[50] private __gap;
}
