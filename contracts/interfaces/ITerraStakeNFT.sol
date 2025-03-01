// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC1155/IERC1155Upgradeable.sol";

/**
 * @title ITerraStakeNFT
 * @notice Comprehensive interface for the upgradeable TerraStakeNFT contract with advanced functionalities
 * @dev This interface defines all external functions and events for the TerraStakeNFT contract
 */
interface ITerraStakeNFT is IERC1155Upgradeable {
    // =====================================================
    // Structs
    // =====================================================
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
        bytes32 metricHash;
    }
    
    struct NFTMetadata {
        string ipfsUri;
        uint256 projectId;
        uint256 impactValue;
        bool isTradable;
        string location;
        uint256 capacity;
        uint256 certificationDate;
        string projectType;
        bool isVerified;
        uint256 version;
        PerformanceMetrics performance;
        uint256 mintingFee;
        bytes32 projectDataHash;
        bytes32 impactReportHash;
        address originalMinter;
        uint256 originalMintTimestamp;
        bytes32 verificationProofHash;
    }
    
    struct CarbonRetirement {
        uint256 tokenId;
        uint256 amount;
        address retiringEntity;
        address beneficiary;
        string reason;
        uint256 timestamp;
        bytes32 retirementId;
    }
    
    struct StakedImpact {
        uint256 tokenId;
        uint256 impactAmount;
        uint256 stakingTimestamp;
        uint256 unlockTimestamp;
        address staker;
        bool active;
    }
    
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

    // =====================================================
    // Events
    // =====================================================
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

    // =====================================================
    // Initialization & Administrative Functions
    // =====================================================
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
    ) external;
    
    function setMintingFee(uint256 newFee) external;
    function setVerificationFee(uint256 newFee) external;
    function setRetirementFee(uint256 newFee) external;
    function setFractionalizationFee(uint256 newFee) external;
    function setStakingRewardRate(uint256 newRate) external;
    function setFeeDistribution(
        uint256 stakingShare,
        uint256 liquidityShare,
        uint256 treasuryShare,
        uint256 burnShare
    ) external;
    function setVRFParameters(
        bytes32 _keyHash,
        uint64 _subscriptionId,
        uint32 _callbackGasLimit,
        uint16 _requestConfirmations
    ) external;

    // =====================================================
    // Project Verification Functions
    // =====================================================
    function getProjectVerificationData(uint256 projectId) external view returns (
        bytes32 projectDataHash,
        bytes32 impactReportHash,
        bool isVerified,
        uint256 totalImpact,
        uint8 projectState
    );
    
    function verifyProjectIntegrity(uint256 projectId) external view returns (
        bool verificationStatus,
        bytes memory verificationData
    );
    
    function setVerificationMerkleRoot(uint256 tokenId, bytes32 merkleRoot) external;
    
    function verifyDataWithMerkleProof(uint256 tokenId, bytes32 data, bytes32[] calldata proof) 
        external 
        view 
        returns (bool);

    // =====================================================
    // Carbon Credit Retirement
    // =====================================================
    function retireCarbonCredits(
        uint256 tokenId, 
        uint256 amount, 
        address retirementBeneficiary,
        string calldata retirementReason
    ) external returns (bytes32 retirementId);
    
    function batchRetireCarbonCredits(
        uint256[] calldata tokenIds,
        uint256[] calldata amounts,
        address beneficiary,
        string calldata reason
    ) external returns (bytes32[] memory);

    // =====================================================
    // Impact Staking Functionality
    // =====================================================
    function stakeTokenImpact(
        uint256 tokenId, 
        uint256 impactAmount,
        uint256 lockPeriod
    ) external returns (uint256 stakeId);
    
    function unstakeImpact(uint256 stakeId) external returns (uint256 rewardAmount);
    function getUserStakedImpacts(address user) external view returns (StakedImpact[] memory);
    function calculatePendingRewards(address user, uint256 stakeId) external view returns (uint256 pendingReward);

    // =====================================================
    // Enhanced Impact Verification
    // =====================================================
    function verifyTokenImpact(
        uint256 tokenId,
        bytes calldata impactVerificationData,
        string calldata externalVerifierId,
        bytes32 verificationProof
    ) external;
    
    function batchVerifyTokens(
        uint256[] calldata tokenIds,
        bytes[] calldata verificationData,
        string[] calldata externalIds,
        bytes32[] calldata proofs
    ) external;

    // =====================================================
    // Impact NFT Fractionalization
    // =====================================================
    function fractionalizeToken(
        uint256 tokenId,
        uint256 fractionCount,
        address[] calldata recipients,
        uint256[] calldata fractionAmounts
    ) external returns (uint256 fractionId);
    
    function reunifyFractions(uint256 fractionBaseId) external returns (uint256 newTokenId);

    // =====================================================
    // Minting Functionality
    // =====================================================
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
    ) external returns (uint256);
    
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
    ) external returns (uint256[] memory);

    // =====================================================
    // Metadata Management
    // =====================================================
    function updateTokenMetadata(
        uint256 tokenId, 
        string memory newIpfsUri,
        bool updateTradable,
        bool newTradableState
    ) external;
    
    function updatePerformanceMetrics(
        uint256 tokenId,
        uint256 newTotalImpact,
        uint256 newCarbonOffset,
        uint256 newEfficiencyScore
    ) external;
    
    function getTokenMetadataHistory(uint256 tokenId) external view returns (NFTMetadata[] memory);

    // =====================================================
    // Chainlink VRF Functions
    // =====================================================
    function requestRandomness(uint256 tokenId) external returns (uint256 requestId);
    function getRandomnessResult(uint256 tokenId) external view returns (uint256);

    // =====================================================
    // View Functions
    // =====================================================
    function nftMetadata(uint256 tokenId) external view returns (
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
    );
    
    function uri(uint256 tokenId) external view override returns (string memory);
    function totalMinted() external view returns (uint256);
    function mintFee() external view returns (uint256);
    function verificationFee() external view returns (uint256);
    function retirementFee() external view returns (uint256);
    function fractionalizationFee() external view returns (uint256);
    function impactStakingRewardRate() external view returns (uint256);
    function feeDistribution() external view returns (FeeDistribution memory);
    function carbonRetirements(bytes32 retirementId) external view returns (CarbonRetirement memory);
    function retirementRegistry(bytes32 retirementId) external view returns (bool);
    function totalCarbonRetired() external view returns (uint256);
    function totalImpactStaked() external view returns (uint256);
    function totalVerifications() external view returns (uint256);
    function verificationRecords(uint256 tokenId, uint256 index) external view returns (VerificationRecord memory);
    function fractionalSupplies(uint256 fractionBaseId) external view returns (uint256);
    
    // =====================================================
    // Utility Functions
    // =====================================================
    function batchGetImpact(uint256[] calldata tokenIds) external view returns (
        uint256 totalImpact,
        uint256 carbonOffset
    );
    
    function getProjectImpact(uint256 projectId) external returns (uint256 impact);
    function getRemainingCarbonOffset(uint256 tokenId) external view returns (uint256);
    function recoverERC20(address tokenAddress, uint256 amount) external;
    function supportsInterface(bytes4 interfaceId) external view override returns (bool);
}
