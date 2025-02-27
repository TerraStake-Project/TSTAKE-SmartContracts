// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title ITerraStakeGovernance
 * @notice Interface for the TerraStakeGovernance contract that manages governance operations
 * in the TerraStake ecosystem including voting, proposal creation and execution, fee adjustments,
 * and economic controls.
 */
interface ITerraStakeGovernance is IERC165 {
    // -------------------------------------------
    // 🔹 Structs
    // -------------------------------------------
    
    struct Proposal {
        uint256 id;
        address proposer;
        bytes32 hashOfProposal;
        uint256 startTime;
        uint256 endTime;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
        bytes callData;
        address target;
        uint256 timelockEnd;
    }
    
    struct FeeProposal {
        uint256 projectSubmissionFee;
        uint256 impactReportingFee;
        uint256 buybackPercentage;
        uint256 liquidityPairingPercentage;
        uint256 burnPercentage;
        uint256 treasuryPercentage;
        uint256 voteEnd;
        bool executed;
    }
    
    struct ExtendedProposalData {
        uint8 proposalType;
        FeeProposal feeData;
        address[] contractAddresses;
        uint256[] numericParams;
        address[] accountsToUpdate;
        bool[] boolParams;
    }

    // -------------------------------------------
    // 🔹 Core Governance Functions
    // -------------------------------------------
    
    function createStandardProposal(
        bytes32 proposalHash,
        string calldata description,
        bytes calldata callData,
        address target
    ) external returns (uint256);
    
    function createFeeUpdateProposal(
        bytes32 proposalHash,
        string calldata description,
        uint256 projectSubmissionFee,
        uint256 impactReportingFee,
        uint256 buybackPercentage,
        uint256 liquidityPairingPercentage,
        uint256 burnPercentage,
        uint256 treasuryPercentage
    ) external returns (uint256);
    
    function createParamUpdateProposal(
        bytes32 proposalHash,
        string calldata description,
        uint256 _votingDuration,
        uint256 _proposalThreshold,
        uint256 _minimumHolding,
        uint256 _feeUpdateCooldown
    ) external returns (uint256);
    
    function createContractUpdateProposal(
        bytes32 proposalHash,
        string calldata description,
        address _stakingContract,
        address _rewardDistributor,
        address _liquidityGuard,
        address _treasuryWallet
    ) external returns (uint256);
    
    function createPenaltyProposal(
        bytes32 proposalHash,
        string calldata description,
        address violator,
        string calldata reason
    ) external returns (uint256);
    
    function createEmergencyProposal(
        bytes32 proposalHash,
        string calldata description,
        bool haltOperations
    ) external returns (uint256);
    
    function createPardonProposal(
        bytes32 proposalHash,
        string calldata description,
        address violator
    ) external returns (uint256);
    
    function createRewardRateAdjustmentProposal(
        bytes32 proposalHash,
        string calldata description,
        uint256 newRate
    ) external returns (uint256);
    
    function createBuybackProposal(
        bytes32 proposalHash,
        string calldata description,
        uint256 usdcAmount
    ) external returns (uint256);
    
    function createLiquidityPairingProposal(
        bytes32 proposalHash,
        string calldata description,
        bool enabled
    ) external returns (uint256);
    
    function castVote(uint256 proposalId, bool support) external;
    
    function executeProposal(uint256 proposalId) external;
    
    function executeBuybackProposal(uint256 proposalId) external;
    
    function executeLiquidityPairingProposal(uint256 proposalId) external;
    
    function batchProcessProposals(uint256[] calldata proposalIds) external;
    
    function canExecuteProposal(uint256 proposalId) external view returns (bool);
    
    // -------------------------------------------
    // 🔹 Halving and Reward Management
    // -------------------------------------------
    
    function triggerAutomaticHalving() external;
    
    // -------------------------------------------
    // 🔹 Emergency Management
    // -------------------------------------------
    
    function recoverERC20(address token, uint256 amount) external;
    
    // -------------------------------------------
    // 🔹 View Functions
    // -------------------------------------------
    
    function validateGovernanceParameters() external view returns (bool);
    
    function getCurrentFeeStructure() external view returns (FeeProposal memory);
    
    function getProposal(uint256 proposalId) external view returns (Proposal memory);
    
    function getProposalExtendedData(uint256 proposalId) external view returns (ExtendedProposalData memory);
    
    function isProposalActive(uint256 proposalId) external view returns (bool);
    
    function hasProposalSucceeded(uint256 proposalId) external view returns (bool);
    
    function getUnclaimedRewardsPercentage() external view returns (uint256);
    
    function getTimeUntilNextHalving() external view returns (uint256);
    
    function getVotingPower(address account) external view returns (uint256);
    
    function getQuadraticVotingPower(address account) external view returns (uint256);
    
    function hasAccountVoted(uint256 proposalId, address account) external view returns (bool);
    
    function meetsMinimumHolding(address account) external view returns (bool);
    
    function getProposalVotingStats(uint256 proposalId) external view returns (
        uint256 forVotes,
        uint256 againstVotes,
        uint256 totalVoters
    );
    
    function getProposalTimeRemaining(uint256 proposalId) external view returns (uint256);
    
    function getImplementation() external view returns (address);
    
    function isPriceStable() external view returns (bool);
    
    function getTotalVotesCast() external view returns (uint256);
    
    function getGovernanceStats() external view returns (
        uint256 propCount,
        uint256 executedCount,
        uint256 activeProposalCount
    );
    
    function batchCheckMinimumHolding(address[] calldata accounts) external view returns (bool[] memory);
    
    function getNextHalvingTime() external view returns (uint256);

    // -------------------------------------------
    // 🔹 Events
    // -------------------------------------------
    
    event GovernanceParametersUpdated(uint256 newVotingDuration, uint256 newProposalThreshold, uint256 newMinimumHolding);
    event RewardRateAdjusted(uint256 newRate, uint256 timestamp);
    event TokenRecovered(address indexed token, uint256 amount, address indexed recipient);
    event LiquidityPairingToggled(bool enabled);
    event HalvingTriggered(uint256 epoch, uint256 timestamp, bool isAutomatic);
    event ProposalExecuted(uint256 indexed proposalId, address indexed executor);
    event GovernanceVoteCast(address indexed voter, uint256 indexed proposalId, bool vote);
    event GovernanceViolationDetected(address indexed violator, uint256 penaltyAmount);
    
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        bytes32 hashOfProposal,
        uint256 startTime,
        uint256 endTime,
        string description,
        uint8 proposalType
    );
    
    event FeeProposalCreated(
        uint256 proposalId,
        uint256 projectSubmissionFee,
        uint256 impactReportingFee,
        uint256 buybackPercentage,
        uint256 liquidityPairingPercentage,
        uint256 burnPercentage,
        uint256 treasuryPercentage
    );
    
    event FeeStructureUpdated(
        uint256 projectSubmissionFee,
        uint256 impactReportingFee,
        uint256 buybackPercentage,
        uint256 liquidityPairingPercentage,
        uint256 burnPercentage,
        uint256 treasuryPercentage
    );
    
    event GovernanceContractsUpdated(
        address stakingContract,
        address rewardDistributor,
        address liquidityGuard
    );
    
    event TreasuryWalletUpdated(address newTreasuryWallet);
    event RewardBuybackExecuted(uint256 usdcAmount, uint256 tokensReceived);
    event AutomaticHalvingScheduled(uint256 nextHalvingTime);
    event EmergencyActionTriggered(uint256 proposalId, string action);
    event EmergencyActionResolved(uint256 proposalId, string action);
    event BatchProposalsProcessed(uint256[] proposalIds, uint256 successCount);
}
