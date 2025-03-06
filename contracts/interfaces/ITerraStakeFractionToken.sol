// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@chainlink/contracts/src/v0.8/interfaces/KeeperCompatibleInterface.sol";
import "./interfaces/ITerraStakeToken.sol";
import "./interfaces/ITerraStakeNFT.sol";

/**
 * @title ITerraStakeFractionsToken
 * @dev Interface for the TerraStakeFractionsToken contract
 */
interface ITerraStakeFractionsToken is KeeperCompatibleInterface {
    // =====================================================
    // Structs
    // =====================================================
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

    struct Proposal {
        bytes32 proposalHash;
        uint256 proposedTime;
        uint256 requiredThreshold;
        bool executed;
        bool isEmergency;
        address creator;
        bool canceled;
        uint256 executionTime;
        EnumerableSet.AddressSet approvers;
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
    
    event ProposalExpired(
        bytes32 indexed proposalId
    );
    
    event ProposalCanceled(
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
        bytes action
    );
    
    event RoleTransferred(
        bytes32 indexed role,
        address indexed oldAccount,
        address indexed newAccount
    );
    
    event TimelockConfigUpdated(
        uint256 duration,
        bool enabled
    );
    
    event KeeperConfigUpdated(
        uint256 interval,
        bool enabled
    );
    
    event MultisigMemberAdded(
        address indexed member
    );
    
    event MultisigMemberRemoved(
        address indexed member
    );

    // =====================================================
    // Fractionalization Functions
    // =====================================================
    function fractionalize(FractionParams calldata params) external returns (address fractionTokenAddress);
    function buyFractions(address fractionToken, uint256 amount, uint256 maxPrice) external;
    function updateMarketPrice(address fractionToken, uint256 newPrice) external;
    function getTokenPrice(address fractionToken) external view returns (uint256 price);
    function getAggregateMetrics() external view returns (AggregateMetrics memory metrics);

    // =====================================================
    // Governance Functions
    // =====================================================
    function createProposal(
        address targetContract,
        uint256 value,
        bytes calldata data,
        string calldata description,
        bool isEmergency
    ) external returns (bytes32 proposalId);
    
    function approveProposal(bytes32 proposalId) external;
    function cancelProposal(bytes32 proposalId) external;
    
    function executeProposal(
        bytes32 proposalId,
        address targetContract,
        uint256 value,
        bytes calldata data
    ) external returns (bool success);

    // =====================================================
    // Oracle Integration
    // =====================================================
    function configureOracle(
        address token,
        address oracle,
        uint256 heartbeatPeriod,
        int256 minPrice,
        int256 maxPrice,
        uint256 updateInterval
    ) external;
    
    function updatePriceFromOracle(address token) external returns (uint256 newPrice);
    function updateAllPrices() external returns (uint256 updatedCount);
    
    function getLatestOraclePrice(address token)
        external
        view
        returns (
            uint256 price,
            uint256 timestamp,
            bool isValid
        );

    // =====================================================
    // Chainlink Keeper Implementation
    // =====================================================
    function checkUpkeep(bytes calldata checkData) 
        external 
        view 
        override 
        returns (bool upkeepNeeded, bytes memory performData);
    
    function performUpkeep(bytes calldata performData) external override;
    function configureKeeper(uint256 interval, bool enabled) external;

    // =====================================================
    // Emergency Control Functions
    // =====================================================
    function executeEmergencyAction(address targetContract, bytes calldata data) external returns (bool);
    function emergencyPause() external;
    function emergencyUnpause() external;
    function emergencyWithdrawNFT(address fractionToken, address recipient) external;

    // =====================================================
    // Governance Parameter Management
    // =====================================================
    function updateGovernanceThreshold(uint256 newThreshold) external;
    function updateEmergencyThreshold(uint256 newThreshold) external;
    function updateProposalExpiryTime(uint256 newExpiryTime) external;
    function updateTimelockConfig(uint256 duration, bool enabled) external;
    function setFractionalizationFee(uint256 newFee) external;
    function setTradingFeePercentage(uint256 newFeePercentage) external;
    function updateFeeRecipients(address newTreasury, address newImpactFund) external;
    function addMultisigMember(address member) external;
    function removeMultisigMember(address member) external;
    function transferRole(bytes32 role, address from, address to) external;

    // =====================================================
    // NFT Redemption
    // =====================================================
    function offerRedemption(address fractionToken, uint256 offerPrice) external;
    function redeemNFT(address fractionToken) external;
    function claimRedemptionShare(address fractionToken) external;

    // =====================================================
    // View Functions
    // =====================================================
    function getProposalDetails(bytes32 proposalId)
        external
        view
        returns (
            bytes32 proposalHash,
            uint256 proposedTime,
            uint256 requiredThreshold,
            bool executed,
            bool isEmergency,
            bool canceled,
            uint256 executionTime,
            uint256 approvalCount,
            bool expired,
            address creator
        );

    function hasApprovedProposal(bytes32 proposalId, address approver)
        external
        view
        returns (bool hasApproved);
    
    function getActiveProposals() external view returns (bytes32[] memory activeProposalIds);
    function getActiveOracleCount() external view returns (uint256 count);
    function getActiveFractions() external view returns (address[] memory activeFractions);
    function getMarketData(address fractionToken) external view returns (FractionMarketData memory data);
    function isGovernanceMember(address member) external view returns (bool isGovernanceMember);
    
    function checkOracleUpdateNeeded() 
        external 
        view 
        returns (bool needsUpdate, address[] memory tokensToUpdate);

    // =====================================================
    // ERC1155 Receiver Interface
    // =====================================================
    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata data
    ) external returns (bytes4);

    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external returns (bytes4);
}
