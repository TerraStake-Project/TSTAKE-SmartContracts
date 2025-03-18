// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

/**
 * @title ITerraStakeStaking
 * @dev Interface for the TerraStake staking system
 */
interface ITerraStakeStaking {
    // Structs
    struct StakingPosition {
        uint256 projectId;
        uint256 amount;
        uint256 stakingStart;
        uint256 lastCheckpoint;
        uint256 duration;
        bool isLPStaker;
        bool hasNFTBoost;
        bool autoCompounding;
    }
    
    struct StakingTier {
        uint256 minDuration;
        uint256 multiplier;
        bool hasVotingRights;
    }
    
    struct PenaltyEvent {
        uint256 projectId;
        uint256 timestamp;
        uint256 totalPenalty;
        uint256 redistributed;
        uint256 burned;
        uint256 toLiquidity;
    }
    
    // Events
    event Staked(address indexed user, uint256 indexed projectId, uint256 amount, uint256 duration, uint256 timestamp, uint256 totalStaked);
    event Unstaked(address indexed user, uint256 indexed projectId, uint256 amount, uint256 penalty, uint256 timestamp);
    event RewardClaimed(address indexed user, uint256 indexed projectId, uint256 amount, uint256 timestamp);
    event RewardCompounded(address indexed user, uint256 indexed projectId, uint256 amount, uint256 timestamp);
    event PenaltyApplied(address indexed user, uint256 indexed projectId, uint256 totalPenalty, uint256 burned, uint256 redistributed, uint256 toLiquidity);
    event LiquidityInjected(address indexed liquidityPool, uint256 amount, uint256 timestamp);
    event ValidatorAdded(address indexed validator, uint256 timestamp);
    event ValidatorRemoved(address indexed validator, uint256 timestamp);
    event ValidatorStatusChanged(address indexed validator, bool isActive);
    event ValidatorCommissionUpdated(address indexed validator, uint256 newCommission);
    event ValidatorRewardsDistributed(address indexed validator, uint256 amount);
    event ValidatorRewardsAccumulated(uint256 amount, uint256 newTotal);
    event ProposalVoted(uint256 indexed proposalId, address indexed voter, uint256 weight, bool support);
    event GovernanceProposalCreated(uint256 indexed proposalId, address indexed creator, string description);
    event GovernanceViolatorMarked(address indexed violator, uint256 timestamp);
    event TiersUpdated(uint256[] minDurations, uint256[] multipliers, bool[] votingRights);
    event LiquidityInjectionRateUpdated(uint256 newRate);
    event AutoLiquidityToggled(bool enabled);
    event ValidatorThresholdUpdated(uint256 newThreshold);
    event RewardDistributorUpdated(address indexed newDistributor);
    event LiquidityPoolUpdated(address indexed newPool);
    event TokenRecovered(address indexed token, uint256 amount, address recipient);
    event Slashed(address indexed validator, uint256 amount, uint256 timestamp);
    event SlashingContractUpdated(address indexed newContract);
    event ProjectApprovalVoted(uint256 indexed projectId, address voter, bool approved, uint256 votingPower);
    event RewardRateAdjusted(uint256 oldRate, uint256 newRate);
    event HalvingApplied(uint256 indexed epoch, uint256 oldBaseAPR, uint256 newBaseAPR, uint256 oldBoostedAPR, uint256 newBoostedAPR);
    event DynamicRewardsToggled(bool enabled);
    event GovernanceQuorumUpdated(uint256 newQuorum);
    event SlashedTokensDistributed(uint256 amount);
    event SlashedTokensBurned(uint256 amount);
    event SlashedTokensSentToTreasury(uint256 amount, address treasury);
    
    // Core staking functions
    function stake(uint256 projectId, uint256 amount, uint256 duration, bool isLP, bool autoCompound) external;
    function batchStake(uint256[] calldata projectIds, uint256[] calldata amounts, uint256[] calldata durations, bool[] calldata isLP, bool[] calldata autoCompound) external;
    function unstake(uint256 projectId) external;
    function batchUnstake(uint256[] calldata projectIds) external;
    function claimRewards(uint256 projectId) external;
    
    // Validator functions
    function becomeValidator() external;
    function claimValidatorRewards() external;
    function updateValidatorCommission(uint256 newCommissionRate) external;
    
    // Governance functions
    function voteOnProposal(uint256 proposalId, bool support) external;
    function createProposal(string calldata description, address[] calldata targets, uint256[] calldata values, bytes[] calldata calldatas) external;
    function markGovernanceViolator(address violator) external;
    function slashGovernanceVote(address user) external returns (uint256);
    
    // Admin functions
    function updateTiers(uint256[] calldata minDurations, uint256[] calldata multipliers, bool[] calldata votingRights) external;
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
    function slash(address validator, uint256 amount) external returns (bool);
    function adjustRewardRates() external;
    function applyHalvingIfNeeded() external;
    function applyHalving() external returns (uint256);
    
    // View functions
    function calculateRewards(address user, uint256 projectId) external view returns (uint256);
    function getApplicableTier(uint256 duration) external view returns (uint256);
    function getUserStake(address user, uint256 projectId) external view returns (uint256);
    function getUserTotalStake(address user) external view returns (uint256);
    function getUserPositions(address user) external view returns (StakingPosition[] memory);
    function getPenaltyHistory(address user) external view returns (PenaltyEvent[] memory);
    function isValidator(address user) external view returns (bool);
    function getValidatorCommission(address validator) external view returns (uint256);
    function isGovernanceViolator(address user) external view returns (bool);
    function getGovernanceVotes(address user) external view returns (uint256);
    function getTotalStaked() external view returns (uint256);
    function getValidatorRewardPool() external view returns (uint256);
    function getAllTiers() external view returns (StakingTier[] memory);
    function getTopStakers(uint256 limit) external view returns (address[] memory stakers, uint256[] memory amounts);
    function getActiveStakers() external view returns (address[] memory);
    function version() external pure returns (string memory);
    
    // Contract property getters
    function halvingPeriod() external view returns (uint256);
    function lastHalvingTime() external view returns (uint256);
    function halvingEpoch() external view returns (uint256);
    function dynamicRewardsEnabled() external view returns (bool);
    function dynamicBaseAPR() external view returns (uint256);
    function dynamicBoostedAPR() external view returns (uint256);
    function governanceQuorum() external view returns (uint256);
    function validatorThreshold() external view returns (uint256);
    function liquidityInjectionRate() external view returns (uint256);
    function autoLiquidityEnabled() external view returns (bool);
}
