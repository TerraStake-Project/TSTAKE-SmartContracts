// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/IAccessControlEnumerableUpgradeable.sol";

/**
 * @title ITerraStakeStaking (Upgradeable, Secure)
 * @notice Interface for TerraStake staking contract with governance, liquidity protection, and upgradeability.
 */
interface ITerraStakeStaking {
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
        uint256 amount,
        uint256 duration,
        bool autoCompound
    ) external;

    function unstake(uint256 timestamp) external;

    function claimRewards() external;

    // ================================
    // 🔹 NFT Integration
    // ================================
    function applyNFTBoost(uint256 projectId, uint256 tokenId) external;
    function removeNFTBoost(uint256 projectId, uint256 tokenId) external;

    // ================================
    // 🔹 Project-Based Staking
    // ================================
    function setProjectTier(uint256 projectId, uint256 rewardMultiplier) external;
    function distributeProjectRewards(uint256 projectId, uint256 rewardAmount) external;

    // ================================
    // 🔹 Governance & Voting
    // ================================
    function governanceVotes(address user) external view returns (uint256);
    function governanceViolators(address user) external view returns (bool);
    function slashGovernanceVote(address user) external;
    function calculateVotingPower(address user) external view returns (uint256);

    // ================================
    // 🔹 Governance Reward Management
    // ================================
    function distributeGovernanceReward(address user, uint256 amount) external;
    function claimGovernanceRewards() external;

    function getPendingGovernanceRewards(address user) 
        external 
        view 
        returns (uint256 totalPending, uint256 totalClaimable);

    // ================================
    // 🔹 Halving Mechanism
    // ================================
    function halvingPeriod() external view returns (uint256);
    function lastHalvingTime() external view returns (uint256);
    function halvingEpoch() external view returns (uint256);
    function applyHalving() external;

    // ================================
    // 🔹 Security & Emergency Functions
    // ================================
    function pause() external;
    function unpause() external;

    function emergencyWithdraw(address token, uint256 amount, address recipient) external;
    function withdrawExcessTokens(address token, uint256 amount, address recipient) external;

    // ================================
    // 🔹 Role-Based Access Control
    // ================================
    function hasRole(bytes32 role, address account) external view returns (bool);
    function getRoleAdmin(bytes32 role) external view returns (bytes32);
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;

    // ================================
    // 🔹 View Functions
    // ================================
    function totalStaked() external view returns (uint256);

    function stakingPositions(address user, uint256 timestamp)
        external
        view
        returns (
            uint256 amount,
            uint256 lastCheckpoint,
            uint256 stakingStart,
            uint256 duration,
            bool autoCompounding
        );

    function tiers(uint256 index)
        external
        view
        returns (
            uint256 minDuration,
            uint256 rewardMultiplier,
            bool governanceRights
        );

    function getDynamicAPR(bool hasNFT) external view returns (uint256);

    // ================================
    // 🔹 Upgradeability (UUPS Standard)
    // ================================
    function upgradeTo(address newImplementation) external;
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;

    // ================================
    // 🔹 Events (Full Transparency)
    // ================================
    event Staked(address indexed user, uint256 amount, uint256 duration);
    event Unstaked(address indexed user, uint256 amount);
    event NFTBoostApplied(address indexed user, uint256 projectId, uint256 tokenId, uint256 boostAmount);
    event NFTBoostRemoved(address indexed user, uint256 projectId, uint256 tokenId);
    event ProjectTierSet(uint256 indexed projectId, uint256 rewardMultiplier);
    event RewardsDistributed(address indexed user, uint256 amount);
    event GovernanceRewardsClaimed(address indexed user, uint256 amount);
    event LiquidityInjectionRateUpdated(uint256 newRate);
    event AutoLiquidityToggled(bool status);
    event GovernanceVoteSlashed(address indexed user);
    event HalvingApplied(uint256 newEpoch, uint256 adjustedAPR);
    event EmergencyWithdraw(address indexed token, uint256 amount, address indexed recipient);
    event ExcessTokensWithdrawn(address indexed token, uint256 amount, address indexed recipient);
    event ContractUpgraded(address indexed newImplementation);
}
