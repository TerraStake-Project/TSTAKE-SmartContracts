// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/IAccessControlEnumerableUpgradeable.sol";

/**
 * @title ITerraStakeStaking
 * @notice Interface for TerraStake staking contract with governance, liquidity protection, and upgradeability.
 */
interface ITerraStakeStaking is IAccessControlEnumerableUpgradeable {
    // ================================
    // 🔹 Data Structures
    // ================================
    
    struct StakingPosition {
        uint256 amount;
        uint256 lastCheckpoint;
        uint256 stakingStart;
        uint256 duration;
        uint256 projectId;
        bool isLPStaker;
        bool hasNFTBoost;
        bool autoCompounding;
    }
    
    struct StakingTier {
        uint256 minDuration;
        uint256 rewardMultiplier;
        bool governanceRights;
    }
    
    // ================================
    // 🔹 Token & Liquidity Management
    // ================================
    
    function stakingToken() external view returns (address);
    function rewardDistributor() external view returns (address);
    function liquidityPool() external view returns (address);
    function liquidityInjectionRate() external view returns (uint256);
    function autoLiquidityEnabled() external view returns (bool);
    function updateLiquidityInjectionRate(uint256 newRate) external;
    function toggleAutoLiquidity() external;
    
    // ================================
    // 🔹 Staking Functions
    // ================================
    
    function stake(
        uint256 projectId,
        uint256 amount,
        uint256 duration,
        bool isLP,
        bool autoCompound
    ) external;
    
    function unstake(uint256 projectId) external;
    function claimRewards(uint256 projectId) external;
    function calculateRewards(address user, uint256 projectId) external view returns (uint256);
    
    // ================================
    // 🔹 Governance & Validator Functions
    // ================================
    
    function getGovernanceVotes(address user) external view returns (uint256);
    function hasGovernanceRights(address user) external view returns (bool);
    function isValidator(address account) external view returns (bool);
    function addValidator(address validator) external;
    function removeValidator(address validator) external;
    function slashValidator(address validator, uint256 amount) external returns (bool);
    function getValidatorThreshold() external view returns (uint256);
    function getValidatorCount() external view returns (uint256);
    function updateValidatorThreshold(uint256 newThreshold) external;
    
    // ================================
    // 🔹 Halving Mechanism
    // ================================
    
    function halvingPeriod() external view returns (uint256);
    function lastHalvingTime() external view returns (uint256);
    function halvingEpoch() external view returns (uint256);
    function applyHalving() external;
    function updateHalvingPeriod(uint256 newPeriod) external;
    
    // ================================
    // 🔹 Security & Emergency Functions
    // ================================
    
    function toggleEmergencyPause(bool paused) external;
    function recoverERC20(address token, uint256 amount, address recipient) external;
    
    // ================================
    // 🔹 Tier Management
    // ================================
    
    function addStakingTier(
        uint256 minDuration,
        uint256 rewardMultiplier,
        bool governanceRights
    ) external;
    
    function updateStakingTier(
        uint256 tierId,
        uint256 minDuration,
        uint256 rewardMultiplier,
        bool governanceRights
    ) external;
    
    function getStakingTiers() external view returns (StakingTier[] memory);
    function getTierMultiplier(uint256 duration) external view returns (uint256);
    
    // ================================
    // 🔹 View Functions
    // ================================
    
    function getTotalStaked() external view returns (uint256);
    function getTotalStakedByUser(address user) external view returns (uint256);
    function getUserStakingPositions(address user) external view returns (
        uint256[] memory projectIds,
        StakingPosition[] memory positions
    );
    function getDynamicAPR(bool isLP, bool hasNFT) external view returns (uint256);
    function getCurrentBaseAPR() external view returns (uint256);
    function getProtocolStats() external view returns (
        uint256 totalStaked,
        uint256 validators,
        uint256 stakersCount,
        uint256 currentAPR
    );
    function version() external pure returns (string memory);
    
    // ================================
    // 🔹 Events
    // ================================
    
    event Staked(address indexed user, uint256 indexed projectId, uint256 amount, uint256 duration);
    event Unstaked(address indexed user, uint256 indexed projectId, uint256 amount, uint256 penalty);
    event RewardsDistributed(address indexed user, uint256 indexed projectId, uint256 amount);
    event RewardsCompounded(address indexed user, uint256 indexed projectId, uint256 amount);
    event ValidatorStatusChanged(address indexed validator, bool status);
    event ValidatorSlashed(address indexed validator, uint256 amount);
    event LiquidityInjected(uint256 amount);
    event LiquidityInjectionRateUpdated(uint256 newRate);
    event AutoLiquidityToggled(bool status);
    event GovernanceRightsUpdated(address indexed user, bool hasRights);
    event HalvingApplied(uint256 newEpoch, uint256 adjustedAPR);
    event HalvingPeriodUpdated(uint256 newPeriod);
    event EmergencyPauseToggled(bool paused);
    event StakingTierAdded(uint256 indexed tierId, uint256 minDuration, uint256 rewardMultiplier, bool governanceRights);
    event StakingTierUpdated(uint256 indexed tierId, uint256 minDuration, uint256 rewardMultiplier, bool governanceRights);
    event ValidatorThresholdUpdated(uint256 newThreshold);
    event ERC20Recovered(address indexed token, uint256 amount, address indexed recipient);
    event SlashingContractUpdated(address indexed slashingContract);
}
