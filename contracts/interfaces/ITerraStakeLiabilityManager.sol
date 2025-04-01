// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

// ========== Expanded ITerraStakeLiabilityManager Interface ==========
interface ITerraStakeLiabilityManager {
    // ========== Enums & Structs ==========
    enum ProjectCategory {
        RENEWABLE_ENERGY,
        CARBON_CAPTURE,
        REFORESTATION,
        SUSTAINABLE_AGRICULTURE,
        OTHER
    }

    struct LiabilityData {
        address tokenAddress;
        uint256 nftId;
        uint256 totalSupply;
        uint256 totalELiability;
        uint256 lastPrice;
        bool isActive;
        uint256 lockEndTime;
        address creator;
        uint256 creationTime;
        ProjectCategory category;
        bytes32 auditDataHash;
    }

    struct OracleConfig {
        address api3Proxy;
        uint256 heartbeatPeriod;
        uint256 minPrice;
        uint256 maxPrice;
        bool active;
        uint256 lastUpdateTime;
        uint256 updateInterval;
    }

    struct TWAPConfig {
        uint32 windowSize;
        uint16 minUpdateInterval;
        uint16 maxObservations;
    }

    // ========== Core Fractionalization Functions ==========
    event NFTFractionalized(
        uint256 indexed nftId,
        address liabilityToken,
        uint256 totalSupply,
        uint256 totalELiability,
        address creator,
        ProjectCategory category,
        bytes32 auditDataHash
    );

    event LiabilityRedeemed(
        uint256 indexed nftId,
        address redeemer,
        uint256 offsetCertificates,
        uint256 newNFTId
    );

    function fractionalizeNFT(
        uint256 nftId,
        string memory name,
        string memory symbol,
        uint256 fractionCount,
        uint256 lockPeriod
    ) external;

    function redeemLiability(
        address liabilityToken,
        uint256 amount,
        uint256 offsetCertificates
    ) external;

    // ========== TWAP Management ==========
    event TWAPConfigUpdated(uint32 windowSize, uint16 minUpdateInterval, uint16 maxObservations);
    event CustomTWAPWindowSet(address indexed token, uint32 windowSize);
    event TWAPObservationRecorded(address indexed token, uint256 price, uint32 timestamp);
    event ObservationsCompressed(address indexed token, uint256 originalCount, uint256 newCount);

    function setCustomTWAPWindow(address token, uint32 windowSize) external;
    function getTWAP(address token, uint32 secondsAgo) external view returns (uint256);
    function getTWAPPriceForTrade(address token, uint256 maxSlippage) external view returns (uint256);
    function improvedCompressObservations(address token) external;
    function syncTWAPState(
        address token,
        uint32[] calldata timestamps,
        uint224[] calldata priceCumulatives
    ) external;

    // ========== Oracle Management ==========
    event OracleConfigured(
        address indexed token,
        address indexed api3Proxy,
        uint256 heartbeatPeriod,
        uint256 minPrice,
        uint256 maxPrice,
        uint256 updateInterval
    );
    event PriceUpdated(address indexed token, uint256 oldPrice, uint256 newPrice);

    function configureOracle(
        address token,
        address api3Proxy,
        uint256 heartbeatPeriod,
        uint256 minPrice,
        uint256 maxPrice,
        uint256 updateInterval
    ) external;

    function updateTokenPrice(address token) external;
    function validateOraclePrice(address token) external view returns (bool);

    // ========== Governance ==========
    event ProposalCreated(bytes32 indexed proposalId, address indexed proposer, bool isEmergency);
    event ProposalApproved(bytes32 indexed proposalId, address indexed approver);
    event ProposalExecuted(bytes32 indexed proposalId, address indexed executor);
    event EmergencyActionExecuted(bytes32 indexed proposalId, address indexed executor);

    function createProposal(bytes32 actionHash, bool isEmergency) external returns (bytes32);
    function approveProposal(bytes32 proposalId) external;
    function executeProposal(bytes32 proposalId, address target, bytes calldata data) external;
    function executeEmergencyAction(bytes32 proposalId, address target, bytes calldata data) external;
    function cancelProposal(bytes32 proposalId) external;

    // ========== Administrative ==========
    event FeesUpdated(uint256 fractionalizationFee, uint256 tradingFeePercentage);
    event FeeStructureUpdated(uint256 governanceShare, uint256 offsetFundShare);
    event Paused(address account);
    event Unpaused(address account);

    function pause() external;
    function unpause() external;
    function updateFeeStructure(uint256 governanceShare, uint256 offsetFundShare) external;
    function registerSecondaryMarket(address market) external;
    function deregisterSecondaryMarket(address market) external;
    function updateStakingContract(address newStaking) external;
    function updateAntiBot(address newAntiBot) external;

    // ========== View Functions ==========
    function liabilityData(address token) external view returns (
        address tokenAddress,
        uint256 nftId,
        uint256 totalSupply,
        uint256 totalELiability,
        uint256 lastPrice,
        bool isActive,
        uint256 lockEndTime,
        address creator,
        uint256 creationTime,
        ProjectCategory category,
        bytes32 auditDataHash
    );

    function nftToLiabilityToken(uint256 nftId) external view returns (address);
    function tokenOracles(address token) external view returns (OracleConfig memory);
    function customTWAPWindows(address token) external view returns (uint32);
    function twapConfig() external view returns (TWAPConfig memory);
    function isSecondaryMarket(address market) external view returns (bool);
}