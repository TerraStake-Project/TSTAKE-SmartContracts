// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/automation/interfaces/KeeperCompatibleInterface.sol";
import "./ITerraStakeToken.sol";
import "./ITerraStakeNFT.sol";

interface IFractionToken is IERC20 {
    function burnAll(address account) external;
}

/**
 * @title ITerraStakeFractionManager
 * @dev Interface for the TerraStakeFractionManager contract
 */
interface ITerraStakeFractionManager is KeeperCompatibleInterface {
    // =====================================================
    // Structs
    // =====================================================
    struct Proposal {
        bytes32 proposalHash;
        uint256 proposedTime;
        uint256 requiredThreshold;
        bool executed;
        bool isEmergency;
        address creator;
        bool canceled;
        uint256 executionTime;
        address[] approvers; // Using array instead of EnumerableSet
    }

    struct FractionData {
        address tokenAddress;
        uint256 nftId;
        uint256 totalSupply;
        uint256 redemptionPrice;
        bool isActive;
        uint256 lockEndTime;
        address creator;
        uint256 creationTime;
        uint256 impactValue;
        ITerraStakeNFT.ProjectCategory category;
        bytes32 verificationHash;
    }

    struct FractionParams {
        uint256 tokenId;
        uint256 fractionSupply;
        uint256 initialPrice;
        string name;
        string symbol;
        uint256 lockPeriod;
    }

    struct FractionMarketData {
        uint256 totalValueLocked;
        uint256 totalActiveUsers;
        uint256 volumeTraded;
        uint256 lastTradePrice;
        uint256 lastTradeTime;
    }

    struct AggregateMetrics {
        uint256 totalMarketCap;
        uint256 totalTradingVolume;
        uint256 totalEnvironmentalImpact;
        uint256 totalActiveTokens;
        uint256 averageTokenPrice;
    }

    struct OracleConfig {
        address oracle;
        uint256 heartbeatPeriod;
        int256 minPrice;
        int256 maxPrice;
        bool active;
        uint256 lastUpdateTime;
        uint256 updateInterval;
    }

    struct TimelockConfig {
        uint256 duration;
        bool enabled;
    }

    // =====================================================
    // Events
    // =====================================================
    event NFTFractionalized(
        uint256 indexed nftId, 
        address fractionToken, 
        uint256 totalSupply, 
        address creator,
        ITerraStakeNFT.ProjectCategory category,
        uint256 impactValue
    );

    event NFTRedeemed(
        uint256 indexed nftId, 
        address redeemer, 
        uint256 redemptionPrice
    );

    event FractionsBought(
        address indexed buyer, 
        address indexed fractionToken, 
        uint256 amount, 
        uint256 price
    );

    event FractionsSold(
        address indexed seller, 
        address indexed fractionToken, 
        uint256 amount, 
        uint256 price
    );

    event RedemptionOffered(
        uint256 indexed nftId, 
        address fractionToken, 
        uint256 price, 
        address offeror
    );

    event MarketDataUpdated(
        address indexed fractionToken,
        uint256 totalValueLocked,
        uint256 volumeTraded,
        uint256 lastTradePrice
    );

    event FeeDistributed(
        address indexed recipient,
        uint256 amount,
        string feeType
    );

    event GlobalStatsUpdated(
        uint256 totalMarketCap,
        uint256 totalTradingVolume,
        uint256 totalEnvironmentalImpact
    );

    event ProposalCreated(
        bytes32 indexed proposalId,
        address indexed proposer,
        bool isEmergency,
        bytes data,
        uint256 executionTime
    );
    
    event ProposalApproved(
        bytes32 indexed proposalId,
        address indexed approver,
        uint256 approvalCount,
        uint256 threshold
    );
    
    event ProposalExecuted(
        bytes32 indexed proposalId,
        address indexed executor,
        bool success
    );
    
    event ProposalExpiredEvent(
        bytes32 indexed proposalId
    );
    
    event ProposalCanceledEvent(
        bytes32 indexed proposalId,
        address indexed canceler
    );
    
    event OracleConfigured(
        address indexed token,
        address indexed oracle,
        uint256 heartbeatPeriod,
        int256 minPrice,
        int256 maxPrice,
        uint256 updateInterval
    );
    
    event PriceUpdated(
        address indexed token,
        uint256 oldPrice,
        uint256 newPrice,
        address indexed oracle
    );
    
    event EmergencyActionExecuted(
        address indexed executor,
        bytes32 indexed actionId,
        string description
    );
    
    event TimelockConfigUpdated(
        uint256 newDuration,
        bool enabled
    );
    
    event KeeperConfigUpdated(
        uint256 updateInterval,
        bool enabled
    );

    // =====================================================
    // Fractionalization Functions
    // =====================================================
    function fractionalizeNFT(FractionParams calldata params) external;
    function offerRedemption(address fractionToken, uint256 price) external;
    function redeemNFT(address fractionToken) external;
    function acceptRedemptionOffer(address fractionToken) external;
    function buyFractions(address fractionToken, uint256 amount) external;
    function sellFractions(address fractionToken, uint256 amount) external;
    function getTokenPrice(address fractionToken) external view returns (uint256);
    function getAggregateMetrics() external view returns (AggregateMetrics memory metrics);
    function getTotalFractionTokens() external view returns (uint256);

    // =====================================================
    // Oracle Functions
    // =====================================================
    function configureOracle(
        address token,
        address oracle,
        uint256 heartbeatPeriod,
        int256 minPrice,
        int256 maxPrice,
        uint256 updateInterval
    ) external;
    
    function updateTokenPrice(address token) external;

    // =====================================================
    // Governance Functions
    // =====================================================
    function createProposal(
        bytes calldata data,
        string calldata description,
        bool isEmergency
    ) external returns (bytes32);
    
    function approveProposal(bytes32 proposalId) external;
    
    function executeProposal(
        bytes32 proposalId,
        address target,
        bytes calldata data
    ) external returns (bool);
    
    function cancelProposal(bytes32 proposalId) external;
    
    function cleanupExpiredProposal(bytes32 proposalId) external;
    
    function setGovernanceParams(
        uint256 _governanceThreshold,
        uint256 _emergencyThreshold,
        uint256 _proposalExpiryTime
    ) external;
    
    function setTimelockConfig(uint256 _duration, bool _enabled) external;
    
    function executeEmergencyAction(
        address target,
        bytes calldata data,
        string calldata description
    ) external returns (bool);
    
    function getActiveProposals() external view returns (bytes32[] memory);
    
    function getProposalDetails(bytes32 proposalId) 
        external 
        view 
        returns (Proposal memory, uint256);
    
    function hasApprovedProposal(bytes32 proposalId, address account) 
        external 
        view 
        returns (bool);

    // =====================================================
    // Fee Management
    // =====================================================
    function setFees(uint256 _fractionalizationFee, uint256 _tradingFeePercentage) external;
    function setFeeWallets(address _treasuryWallet, address _impactFundWallet) external;

    // =====================================================
    // Keeper Functions
    // =====================================================
    function setKeeperConfig(uint256 _updateInterval, bool _enabled) external;
    function checkUpkeep(bytes calldata checkData) 
        external 
        view 
        override 
        returns (bool upkeepNeeded, bytes memory performData);
    function performUpkeep(bytes calldata performData) external override;

    // =====================================================
    // Admin Functions
    // =====================================================
    function pause() external;
    function unpause() external;
}