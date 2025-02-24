// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IRewardDistributor {
    /// @notice Distributes rewards to a user
    /// @param user Address of the user to distribute rewards to
    /// @param amount Amount of rewards to distribute
    function distributeReward(address user, uint256 amount) external;

    /// @notice Updates the reward source address (Admin only)
    /// @param newSource Address of the new reward source
    function updateRewardSource(address newSource) external;

    /// @notice Updates the maximum distribution limit (Admin only)
    /// @param newLimit New distribution limit in tokens
    function updateDistributionLimit(uint256 newLimit) external;

    /// @notice Funds the reward source with additional tokens (Admin only)
    /// @param amount Amount of tokens to transfer to the reward source
    function fundRewardSource(uint256 amount) external;

    /// @notice Retrieves the current state of the reward distributor
    /// @return rewardSource Address of the reward source
    /// @return totalDistributed Total tokens distributed so far
    /// @return distributionLimit Current maximum distribution limit
    function getRewardState()
        external
        view
        returns (
            address rewardSource,
            uint256 totalDistributed,
            uint256 distributionLimit
        );

    // Events
    event RewardDistributed(address indexed user, uint256 amount);
    event RewardSourceUpdated(address indexed oldSource, address indexed newSource);
    event DistributionLimitUpdated(uint256 oldLimit, uint256 newLimit);
}
