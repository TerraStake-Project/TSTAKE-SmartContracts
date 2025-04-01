// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import "@openzeppelin/contracts-upgradeable/utils/introspection/IERC165Upgradeable.sol";

/**
 * @title ITerraStakeStaking
 * @notice Interface for the TerraStakeStaking contract with updated halving logic from TerraStakeToken
 */
interface ITerraStakeStaking is IERC165Upgradeable {
    // Structs
    struct StakingPosition {
        uint256 amount;
        uint256 stakingStart;
        uint256 duration;
        uint256 lastCheckpoint;
        uint256 projectId;
        bool isLPStaker;
        bool hasNFTBoost;
        bool autoCompounding;
        bool isLocked;
    }

    struct PenaltyEvent {
        uint256 projectId;
        uint256 timestamp;
        uint256 totalPenalty;
        uint256 burned;
        uint256 redistributed;
        uint256 toLiquidity;
    }

    struct StakingTier {
        uint256 minDuration;
        uint256 multiplier;
        bool votingRights;
    }

    // Halving Mechanism (Updated to match TerraStakeToken logic)
    function applyHalving() external; // Governance-triggered halving
    function triggerHalving() external returns (uint256); // Admin-triggered halving
    function checkAndApplyHalving() external returns (bool); // Automatic halving check
    function getHalvingDetails() external view returns (
        uint256 period,
        uint256 lastTime,
        uint256 epoch,
        uint256 nextHalving
    );
    function setHalvingPeriod(uint256 newPeriod) external;

    // LayerZero Cross-Chain Functions (Unchanged)
    function sendHalvingEpoch(uint256 epoch) external;
    function receiveHalvingEpoch(uint256 epoch, uint256 sentTime, uint256 remoteBaseAPR, uint256 remoteBoostedAPR) external;
    function batchSendHalvingEpochs(uint256 startEpoch, uint256 count) external;
    function checkRelayerPerformance(uint256 epoch) external view returns (uint256 latency, string memory status);
    function forceResync(uint256 epoch) external;
    function externalHalvingSync(uint256 epoch, uint256 remoteTime) external;
    function syncCrossChain(uint256 _targetChainId) external returns (bool);
    function syncCrossChain() external;
    function receiveHalvingState(uint256 sourceChainId, uint256 remoteEpoch, uint256 remoteBaseAPR, uint256 remoteBoostedAPR) external;

    // Staking Operations
    function stake(uint256 projectId, uint256 amount, uint256 duration, bool isLP, bool autoCompound, bool lockBoost) external;
    function batchStake(
        uint256[] calldata projectIds,
        uint256[] calldata amounts,
        uint256[] calldata durations,
        bool[] calldata isLP,
        bool[] calldata autoCompound,
        bool[] calldata lockBoosts
    ) external;
    function unstake(uint256 projectId) external;
    function batchUnstake(uint256[] calldata projectIds) external;
    function finalizeProjectStaking(uint256 projectId, bool isCompleted) external;
    function claimRewards(uint256 projectId) external;

    // Validator Operations
    function becomeValidator() external;
    function claimValidatorRewards() external;
    function updateValidatorCommission(uint256 newCommissionRate) external;

    // Governance Operations
    function voteOnProposal(uint256 proposalId, bool support) external;
    function createProposal(
        string calldata description,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas
    ) external;
    function markGovernanceViolator(address violator) external;
    function slashGovernanceVote(address user) external returns (uint256);

    // Administrative & Emergency
    function updateTiers(
        uint256[] calldata minDurations,
        uint256[] calldata multipliers,
        bool[] calldata votingRights
    ) external;
    function setLiquidityInjectionRate(uint256 newRate) external;
    function toggleAutoLiquidity(bool enabled) external;
    function setValidatorThreshold(uint256 newThreshold) external;
    function setRewardDistributor(address newDistributor) external;
    function setLiquidityPool(address newPool) external;
    function setSlashingContract(address newSlashingContract) external;
    function setGovernanceQuorum(uint256 newQuorum) external;
    function toggleDynamicRewards(bool enabled) external;
    function pause() external;
    function unpause() external;
    function recoverERC20(address token) external returns (bool);

    // Slashing
    function slash(address validator, uint256 amount) external returns (bool);
    function distributeSlashedTokens(uint256 amount) external;

    // View Functions
    function calculateRewards(address user) external view returns (uint256 totalRewards);
    function calculateRewards(address user, uint256 projectId) external view returns (uint256);
    function getApplicableTier(uint256 duration) external view returns (uint256);
    function getUserStake(address user, uint256 projectId) external view returns (uint256);
    function getUserTotalStake(address user) external view returns (uint256);
    function getUserPositions(address user) external view returns (StakingPosition[] memory positions);
    function getPenaltyHistory(address user) external view returns (PenaltyEvent[] memory);
    function isValidator(address user) external view returns (bool);
    function getValidatorCommission(address validator) external view returns (uint256);
    function isGovernanceViolator(address user) external view returns (bool);
    function getGovernanceVotes(address user) external view returns (uint256);
    function getTotalStaked() external view returns (uint256);
    function totalStakedTokens() external view returns (uint256);
    function getValidatorRewardPool() external view returns (uint256);
    function getAllTiers() external view returns (StakingTier[] memory);
    function getTopStakers(uint256 limit) external view returns (address[] memory stakers, uint256[] memory amounts);
    function getValidatorCount() external view returns (uint256);
    function version() external pure returns (string memory);
    function adjustRewardRates() external;
    function getActiveStakers() external view returns (address[] memory);

    // Events (Updated to match contract)
    event HalvingApplied(
        uint256 epoch,
        uint256 oldBaseAPR,
        uint256 newBaseAPR,
        uint256 oldBoostedAPR,
        uint256 newBoostedAPR
    );
    event HalvingSyncFailed(address targetContract);
    event HalvingPeriodUpdated(uint256 newPeriod);
    event CrossChainSyncInitiated(uint256 targetChainId, uint256 currentEpoch);
    event HalvingStateReceived(
        uint256 sourceChainId,
        uint256 remoteEpoch,
        uint256 oldBaseAPR,
        uint256 newBaseAPR,
        uint256 oldBoostedAPR,
        uint256 newBoostedAPR
    );
    event HalvingEpochSent(uint256 epoch, uint256 timestamp);
    event HalvingEpochReceived(uint256 epoch, uint256 timestamp, uint256 latency);
    event RelayerFailureDetected(uint256 epoch, string reason);
    event Staked(address indexed user, uint256 projectId, uint256 amount, uint256 duration, uint256 timestamp, uint256 newBalance);
    event Unstaked(address indexed user, uint256 projectId, uint256 amount, uint256 penalty, uint256 timestamp);
    event RewardClaimed(address indexed user, uint256 projectId, uint256 amount, uint256 timestamp);
    event RewardCompounded(address indexed user, uint256 projectId, uint256 amount, uint256 timestamp);
    event PenaltyApplied(address indexed user, uint256 projectId, uint256 totalPenalty, uint256 burned, uint256 redistributed, uint256 toLiquidity);
    event LiquidityInjected(address indexed pool, uint256 amount, uint256 timestamp);
    event ValidatorAdded(address indexed validator, uint256 timestamp);
    event ValidatorStatusChanged(address indexed validator, bool status);
    event ValidatorRewardsDistributed(address indexed validator, uint256 amount);
    event ValidatorCommissionUpdated(address indexed validator, uint256 newRate);
    event ProposalVoted(uint256 proposalId, address indexed voter, uint256 votingPower, bool support);
    event GovernanceProposalCreated(uint256 proposalId, address indexed proposer, string description);
    event GovernanceViolatorMarked(address indexed violator, uint256 timestamp);
    event GovernanceVotesUpdated(address indexed user, uint256 newVotes);
    event TiersUpdated(uint256[] minDurations, uint256[] multipliers, bool[] votingRights);
    event LiquidityInjectionRateUpdated(uint256 newRate);
    event AutoLiquidityToggled(bool enabled);
    event ValidatorThresholdUpdated(uint256 newThreshold);
    event RewardDistributorUpdated(address newDistributor);
    event LiquidityPoolUpdated(address newPool);
    event SlashingContractUpdated(address newSlashingContract);
    event GovernanceQuorumUpdated(uint256 newQuorum);
    event DynamicRewardsToggled(bool enabled);
    event TokenRecovered(address indexed token, uint256 amount, address indexed to);
    event Slashed(address indexed validator, uint256 amount, uint256 timestamp);
    event SlashedTokensDistributed(uint256 amount);
    event SlashedTokensBurned(uint256 amount);
    event ValidatorRewardsAccumulated(uint256 amount, uint256 newPool);
    event ProjectStakingCompleted(uint256 projectId, uint256 timestamp);
    event ProjectStakingCancelled(uint256 projectId, uint256 timestamp);
    event RewardRateAdjusted(uint256 oldBaseAPR, uint256 newBaseAPR);
    event TransferFailedEvent(address token, address from, address to, uint256 amount);
    event HalvingTriggered(uint256 epochNumber, uint256 timestamp); // Added from TerraStakeToken
    event EmissionRateUpdated(uint256 newRate); // Added from TerraStakeToken
}