// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title ITerraStakeGovernance (Upgradeable, Secure, OpenZeppelin 5.2.x)
 * @notice Secure interface for on-chain governance, treasury management, and fee control in the TerraStake ecosystem.
 */
interface ITerraStakeGovernance is IERC165 {
    // ================================
    // 🔹 Governance Enums & Structs
    // ================================
    enum ProposalStatus { Active, Timelocked, Vetoed, Executed, VotingEnded }
    enum ProposalType { General, RewardDistribution, Buyback, LiquidityInjection, FeeAdjustment }

    struct Proposal {
        bytes data;
        address target;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 endBlock;
        uint256 timelockEndTime;
        bool executed;
        bool vetoed;
        ProposalType proposalType;
        uint256 linkedProjectId;
        string description;
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

    struct TreasuryMetrics {
        uint256 availableFunds;
        uint256 totalYieldGenerated;
        uint256 totalLiquidityAdded;
        uint256 lastReinvestmentTime;
    }

    // ================================
    // 🔹 Proposal Management
    // ================================
    function createProposal(
        bytes calldata data,
        address target,
        ProposalType proposalType,
        uint256 linkedProjectId,
        string calldata description
    ) external returns (uint256);

    function voteOnProposal(uint256 proposalId, bool support) external;
    function executeProposal(uint256 proposalId) external;
    function vetoProposal(uint256 proposalId) external;
    function finalizeVoting(uint256 proposalId) external;
    function batchProcessProposals(uint256[] calldata proposalIds) external;
    function canExecuteProposal(uint256 proposalId) external view returns (bool);

    function getProposal(uint256 proposalId) external view returns (
        bytes memory data,
        address target,
        uint256 votesFor,
        uint256 votesAgainst,
        uint256 endBlock,
        uint256 timelockEndTime,
        bool executed,
        bool vetoed,
        ProposalType proposalType,
        uint256 linkedProjectId,
        string memory description
    );

    // ================================
    // 🔹 Governance Settings & Voting
    // ================================
    function setProposalThreshold(uint256 newThreshold) external;
    function setVotingDuration(uint256 newDuration) external;
    function setMinimumHolding(uint256 newMinimumHolding) external;
    function validateGovernanceParameters() external view returns (bool);

    function getGovernanceVotes(address user) external view returns (uint256);
    function penalizeGovernor(address user) external;
    function isGovernorPenalized(address user) external view returns (bool);
    function recoverERC20(address token, uint256 amount) external;

    // ================================
    // 🔹 Treasury Yield Optimization
    // ================================
    function reinvestTreasuryYield() external;
    function getTreasuryMetrics() external view returns (TreasuryMetrics memory);

    // ================================
    // 🔹 Dynamic Fee Governance
    // ================================
    function proposeFeeUpdate(
        uint256 newProjectFee, 
        uint256 newImpactFee, 
        uint256 newBuybackPercentage, 
        uint256 newLiquidityPairingPercentage, 
        uint256 newBurnPercentage, 
        uint256 newTreasuryPercentage
    ) external;

    function executeFeeUpdate() external;
    function getCurrentFees() external view returns (
        uint256 projectFee, 
        uint256 impactFee, 
        uint256 buybackPercentage, 
        uint256 liquidityPairingPercentage, 
        uint256 burnPercentage, 
        uint256 treasuryPercentage
    );

    // ================================
    // 🔹 Halving & Economic Adjustments
    // ================================
    function applyHalving() external;
    function updateHalvingPeriod(uint256 newHalvingPeriod) external;
    function getHalvingDetails() external view returns (uint256 period, uint256 lastTime, uint256 epoch);

    // ================================
    // 🔹 Buyback & Liquidity Adjustments
    // ================================
    function executeBuyback(uint256 amount) external;
    function injectLiquidity(uint256 amount) external;
    function setLiquidityPairing(bool enabled) external;
    function getLiquiditySettings() external view returns (bool isPairingEnabled);

    // ================================
    // 🔹 Governance Participation Rewards 🏆
    // ================================
    function distributeGovernanceRewards(address user, uint256 amount) external;
    function claimGovernanceRewards() external;
    function getGovernanceRewards(address user) external view returns (uint256);

    // ================================
    // 🔹 Upgradeability (UUPS Standard)
    // ================================
    function upgradeTo(address newImplementation) external;
    function getImplementation() external view returns (address);

    // ================================
    // 🔹 Events (Full Transparency)
    // ================================
    event ProposalCreated(
        uint256 indexed proposalId,
        bytes data,
        uint256 endBlock,
        address target,
        ProposalType proposalType,
        uint256 linkedProjectId,
        string description
    );

    event ProposalTimelocked(uint256 indexed proposalId, uint256 unlockTime);
    event ProposalExecuted(uint256 indexed proposalId, address target, ProposalType proposalType);
    event ProposalVetoed(uint256 indexed proposalId);
    event ProposalThresholdUpdated(uint256 newThreshold);
    event VotingDurationUpdated(uint256 newDuration);
    event MinimumHoldingUpdated(uint256 newMinimumHolding);
    event GovernanceParametersUpdated(
        uint256 newVotingDuration,
        uint256 newProposalThreshold,
        uint256 newMinimumHolding
    );
    event TreasuryYieldAdjusted(uint256 newRate, uint256 timestamp);
    event TokenRecovered(address indexed token, uint256 amount, address indexed recipient);

    event FeeUpdateProposed(
        uint256 indexed proposalId, 
        uint256 newProjectFee, 
        uint256 newImpactFee, 
        uint256 newBuybackPercentage, 
        uint256 newLiquidityPairingPercentage, 
        uint256 newBurnPercentage, 
        uint256 newTreasuryPercentage
    );

    event FeeUpdateExecuted(
        uint256 indexed proposalId, 
        uint256 newProjectFee, 
        uint256 newImpactFee, 
        uint256 newBuybackPercentage, 
        uint256 newLiquidityPairingPercentage, 
        uint256 newBurnPercentage, 
        uint256 newTreasuryPercentage
    );

    event HalvingApplied(uint256 newEpoch);
    event HalvingPeriodUpdated(uint256 newHalvingPeriod);

    event ProposalVotingEnded(uint256 indexed proposalId, uint256 votesFor, uint256 votesAgainst);
    event BuybackExecuted(uint256 usdcAmount, uint256 tStakeReceived);
    event LiquidityInjected(uint256 usdcAmount, uint256 tStakeAdded);
    event LiquidityPairingUpdated(bool isEnabled);
    event TreasuryYieldReinvested(uint256 amount, uint256 poolShare);
    event ContractUpgraded(address indexed newImplementation);

    event GovernanceRewardDistributed(address indexed user, uint256 amount);
    event GovernanceRewardClaimed(address indexed user, uint256 amount);
}
