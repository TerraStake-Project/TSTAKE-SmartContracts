// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts/interfaces/IERC1155.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";

/**
 * @title ITerraStakeNFT
 * @dev Interface for the TerraStakeNFT contract
 */
interface ITerraStakeNFT is IERC1155, IERC2981 {
    // ====================================================
    //  Structs
    // ====================================================
    
    enum NFTType { STANDARD, IMPACT, GOVERNANCE }
    enum ProjectCategory { CarbonCredit, RenewableEnergy, Biodiversity, Reforestation, WaterConservation, WasteManagement, SustainableAgriculture, ClimateAdaptation }
    
    struct NFTMetadata {
        string name;
        string description;
        uint256 creationTime;
        bool uriIsFrozen;
        NFTType nftType;
        ProjectCategory category;
    }
    
    struct ImpactCertificate {
        uint256 projectId;
        bytes32 reportHash;
        uint256 impactValue;
        string impactType;
        uint256 verificationDate;
        string location;
        address verifier;
        bool isVerified;
        ProjectCategory category;
    }
    
    struct FractionInfo {
        uint256 original__tokenID;
        uint256 fractionCount;
        address fractionalizer;
        bool isActive;
        NFTType nftType;
        uint256 projectId;
        bytes32 reportHash;
        ProjectCategory category;
    }
    
    struct RoyaltyInfo {
        address receiver;
        uint96 royaltyFraction;
    }
    
    struct TokenLock {
        bool isLocked;
        address lockedBy;
        uint256 lockTime;
        uint256 unlockTime;
    }
    
    // ====================================================
    //  Token Minting Functions
    // ====================================================
    
    function mintStandardNFT(
        address to,
        uint256 amount,
        ProjectCategory category,
        string calldata uri
    ) external returns (uint256);
    
    function mintImpactNFT(
        address to,
        uint256 projectId,
        string calldata uri,
        bytes32 reportHash
    ) external returns (uint256);
    
    function verifyImpactCertificate(
        uint256 _tokenID,
        uint256 impactValue,
        string calldata impactType,
        string calldata location
    ) external;
    
    // ====================================================
    //  Fractionalization Functions
    // ====================================================
    
    function fractionalizeToken(uint256 _tokenID, uint256 fractionCount) 
        external 
        returns (uint256[] memory);
    
    function reassembleToken(uint256 original__tokenID) external;
    
    // ====================================================
    //  URI Management
    // ====================================================
    
    function setTokenURI(uint256 _tokenID, string calldata newUri) external;
    
    function lockTokenURI(uint256 _tokenID) external;
    
    function uri(uint256 _tokenID) external view returns (string memory);
    
    // ====================================================
    //  Metadata & Query Functions
    // ====================================================
    
    function getTokensByCategory(ProjectCategory category) external view returns (uint256[] memory);
    
    function getTokenMetadata(uint256 _tokenID) external view returns (NFTMetadata memory);
    
    function getImpactCertificate(uint256 _tokenID) external view returns (ImpactCertificate memory);
    
    function getFractionInfo(uint256 _tokenID) external view returns (FractionInfo memory);
    
    function getFractionTokens(uint256 original__tokenID) external view returns (uint256[] memory);
    
    function getOriginal__tokenID(uint256 fraction__tokenID) external view returns (uint256);
    
    function exists(uint256 _tokenID) external view returns (bool);
    
    // ====================================================
    //  Fee Management
    // ====================================================
    
    function updateFeePercentages(
        uint8 _burnPercent,
        uint8 _treasuryPercent,
        uint8 _buybackPercent
    ) external;
    
    function updateTreasuryWallet(address _treasuryWallet) external;
    
    function updateFees(
        uint256 _mintFee,
        uint256 _fractionalizationFee,
        uint256 _verificationFee,
        uint256 _transferFee
    ) external;
    
    function updateDynamicFeeParams(
        uint256 _baseMintFee,
        uint256 _baseFractionalizationFee,
        uint256 _feeMultiplier,
        uint256 _feeAdjustmentInterval
    ) external;
    
    function adjustFeesBasedOnUsage() external;
    
    // ====================================================
    //  Royalties Implementation
    // ====================================================
    
    function setDefaultRoyalty(address receiver, uint96 feeNumerator) external;
    
    function setTokenRoyalty(
        uint256 _tokenID,
        address receiver,
        uint96 feeNumerator
    ) external;
    
    function royaltyInfo(uint256 _tokenID, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount);
    
    // ====================================================
    //  Utility Functions
    // ====================================================
    
    function requestRandomSeed() external returns (uint256 requestId);
    
    function getRandomSeed(uint256 requestId) external view returns (uint256);
    
    function emergencyPause() external;
    
    function emergencyResume() external;
    
    function updateVRFConfig(
        address _coordinator,
        bytes32 _keyHash,
        uint64 _subscriptionId,
        uint32 _callbackGasLimit,
        uint16 _requestConfirmations
    ) external;
    
    // ====================================================
    //  Locking Mechanism Implementation
    // ====================================================
    
    function lockToken(uint256 _tokenID, uint256 duration) external;
    
    function unlockToken(uint256 _tokenID) external;
    
    function isLocked(uint256 _tokenID) external view returns (bool);
    
    function getLockInfo(uint256 _tokenID) external view returns (TokenLock memory);
    
    // ====================================================
    //  Token Recovery
    // ====================================================
    
    function recoverERC20(address tokenAddress, uint256 amount) external;
    
    function executeBuyback(uint256 amount) external;
    
    // ====================================================
    //  Events
    // ====================================================
    
    event TokenMinted(uint256 indexed _tokenID, address indexed recipient, NFTType nftType, ProjectCategory category);
    event ImpactCertificateCreated(uint256 indexed _tokenID, uint256 indexed projectId, bytes32 reportHash);
    event ImpactVerified(uint256 indexed _tokenID, bytes32 reportHash, address verifier);
    event TokenFractionalized(uint256 indexed original__tokenID, uint256[] fractionIds, uint256 fractionCount);
    event TokensReassembled(uint256 indexed original__tokenID, address collector);
    event TokenURIUpdated(uint256 indexed _tokenID, string newUri);
    event TokenURILocked(uint256 indexed _tokenID);
    event FeePercentagesUpdated(uint8 burnPercent, uint8 treasuryPercent, uint8 buybackPercent);
    event TreasuryWalletUpdated(address treasuryWallet);
    event FeeConfigured(uint256 mintFee, uint256 fractionalizationFee, uint256 verificationFee, uint256 transferFee);
    event DynamicFeeParamsUpdated(uint256 baseMintFee, uint256 baseFractionalizationFee, uint256 feeMultiplier, uint256 feeAdjustmentInterval);
    event FeeMultiplierUpdated(uint256 newMultiplier);
    event FeeCollected(address from, uint256 feeAmount, uint256 burnAmount, uint256 treasuryAmount, uint256 buybackAmount);
    event DefaultRoyaltySet(address receiver, uint96 feeNumerator);
    event TokenRoyaltySet(uint256 indexed _tokenID, address receiver, uint96 feeNumerator);
    event RandomSeedRequested(uint256 indexed requestId, address requester);
    event RandomSeedReceived(uint256 indexed requestId, uint256 randomValue);
    event EmergencyModeActivated(address activator);
    event EmergencyModeDeactivated(address deactivator);
    event VRFConfigured(address coordinator, bytes32 keyHash, uint64 subscriptionId, uint32 callbackGasLimit, uint16 requestConfirmations);
    event TokenLocked(uint256 indexed _tokenID, address locker, uint256 unlockTime);
    event TokenUnlocked(uint256 indexed _tokenID, address unlocker);
    event TokensRecovered(address tokenAddress, uint256 amount, address recipient);
    event BuybackExecuted(uint256 amount, address executor);
}

/**
 * @title ILockable
 * @dev Interface for token locking functionality
 */
interface ILockable {
    function lockToken(uint256 _tokenID, uint256 duration) external;
    function unlockToken(uint256 _tokenID) external;
    function isLocked(uint256 _tokenID) external view returns (bool);
}
