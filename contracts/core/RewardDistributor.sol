// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract RewardDistributor is AccessControl {
    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant STAKING_CONTRACT_ROLE = keccak256("STAKING_CONTRACT_ROLE");

    // Constants
    address public constant DEFAULT_ADMIN = 0xcB3705b50773e95fCe6d3Fcef62B4d753aA0059d;

    // State variables
    IERC20 public rewardToken;            // ERC20 reward token
    address public rewardSource;          // Address where rewards are sourced from

    uint256 public totalDistributed;      // Total rewards distributed
    uint256 public distributionLimit;     // Max rewards distributable per transaction

    // Events
    event RewardDistributed(address indexed user, uint256 amount);
    event RewardSourceUpdated(address indexed oldSource, address indexed newSource);
    event DistributionLimitUpdated(uint256 oldLimit, uint256 newLimit);

    /// @notice Constructor to initialize the RewardDistributor
    /// @param _rewardToken Address of the reward token
    /// @param _rewardSource Address of the reward source
    constructor(address _rewardToken, address _rewardSource) {
        require(_rewardToken != address(0), "Invalid reward token address");
        require(_rewardSource != address(0), "Invalid reward source address");

        rewardToken = IERC20(_rewardToken);
        rewardSource = _rewardSource;
        distributionLimit = 1_000_000 * 10**18; // Default limit: 1M tokens

        // Setup roles
        _grantRole(ADMIN_ROLE, DEFAULT_ADMIN);
        _grantRole(ADMIN_ROLE, msg.sender); // For initial deployment flexibility

        _grantRole(STAKING_CONTRACT_ROLE, msg.sender); // Add deployer as an initial staking contract
    }

    /// @notice Updates the reward source address (Admin only)
    /// @param newSource Address of the new reward source
    function updateRewardSource(address newSource) external onlyRole(ADMIN_ROLE) {
        require(newSource != address(0), "Invalid reward source address");
        emit RewardSourceUpdated(rewardSource, newSource);
        rewardSource = newSource;
    }

    /// @notice Updates the maximum distribution limit (Admin only)
    /// @param newLimit New distribution limit in tokens
    function updateDistributionLimit(uint256 newLimit) external onlyRole(ADMIN_ROLE) {
        emit DistributionLimitUpdated(distributionLimit, newLimit);
        distributionLimit = newLimit;
    }

    /// @notice Distributes rewards to a user
    /// @param user Address of the user to distribute rewards to
    /// @param amount Amount of rewards to distribute
    function distributeReward(address user, uint256 amount) external onlyRole(STAKING_CONTRACT_ROLE) {
        require(user != address(0), "Invalid user address");
        require(amount > 0, "Amount must be greater than zero");
        require(amount <= distributionLimit, "Exceeds distribution limit");

        // Transfer rewards from the reward source to the user
        bool success = rewardToken.transferFrom(rewardSource, user, amount);
        require(success, "Reward transfer failed");

        totalDistributed += amount;
        emit RewardDistributed(user, amount);
    }

    /// @notice Allows admin to fund the reward source directly
    /// @param amount Amount of tokens to transfer to the reward source
    function fundRewardSource(uint256 amount) external onlyRole(ADMIN_ROLE) {
        require(amount > 0, "Amount must be greater than zero");
        bool success = rewardToken.transferFrom(msg.sender, rewardSource, amount);
        require(success, "Funding failed");
    }

    /// @notice Retrieves details of the current reward distribution state
    function getRewardState() external view returns (
        address currentRewardSource,
        uint256 totalTokensDistributed,
        uint256 currentDistributionLimit
    ) {
        return (
            rewardSource,
            totalDistributed,
            distributionLimit
        );
    }
}
