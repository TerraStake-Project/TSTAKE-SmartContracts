// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

/**
 * @title ITerraStakeRewardDistributor
 * @author TerraStake Protocol Team
 * @notice Interface for the TerraStake reward distribution system
 */
interface ITerraStakeRewardDistributor {
    /**
     * @notice Distribute reward to a user
     * @param user Address of the user
     * @param amount Reward amount before halving adjustment
     */
    function distributeReward(address user, uint256 amount) external;

    function claimRewards(address user) external returns(uint256);

    /**
     * @notice Redistribute penalties from slashed validators
     * @param from Address of the slashed validator
     * @param amount Amount of the penalty
     */
    function redistributePenalty(address from, uint256 amount) external;

    /**
     * @notice Distribute accumulated penalties to active stakers in batches
     * @param startIndex Start index in the stakers array
     * @param endIndex End index in the stakers array (inclusive)
     */
    function batchDistributePenalties(uint256 startIndex, uint256 endIndex) external;

    /**
     * @notice Force update of the stake total cache
     * @dev Can be called by governance to ensure accurate distributions
     */
    function updateStakeTotalCache() external;
    
    /**
     * @notice Request randomness for halving from Chainlink VRF
     * @return requestId The VRF request ID
     */
    function requestRandomHalving() external returns (bytes32);
    
    /**
     * @notice Manually force a halving (emergency only)
     */
    function forceHalving() external;
    
    /**
     * @notice Pause or unpause the halving mechanism
     * @param paused Whether the halving mechanism should be paused
     */
    function pauseHalvingMechanism(bool paused) external;
    
    /**
     * @notice Pause or unpause reward distribution
     * @param paused Whether distribution should be paused
     */
    function pauseDistribution(bool paused) external;
    
    /**
     * @notice Emergency circuit breaker to pause all operations
     * @param reason Reason for activation
     */
    function activateEmergencyCircuitBreaker(string calldata reason) external;
    
    /**
     * @notice Propose update to the reward source address
     * @param newRewardSource New reward source address
     */
    function proposeRewardSource(address newRewardSource) external;
    
    /**
     * @notice Execute proposed reward source update after timelock
     */
    function executeRewardSourceUpdate() external;
    
    /**
     * @notice Propose new liquidity injection rate
     * @param newRate New liquidity injection rate (percentage)
     */
    function proposeLiquidityInjectionRate(uint256 newRate) external;
    
    /**
     * @notice Execute proposed liquidity injection rate update after timelock
     */
    function executeLiquidityInjectionRateUpdate() external;
    
    /**
     * @notice Set the maximum daily distribution limit
     * @param newLimit New maximum daily distribution amount
     */
    function setMaxDailyDistribution(uint256 newLimit) external;
    
    /**
     * @notice Toggle auto-buyback functionality
     * @param enabled Whether buybacks should be enabled
     */
    function setAutoBuyback(bool enabled) external;
    
    /**
     * @notice Update the Chainlink VRF callback gas limit
     * @param newLimit New gas limit for VRF callbacks
     */
    function setCallbackGasLimit(uint32 newLimit) external;
    
    /**
     * @notice Update Chainlink VRF subscription
     * @param newSubscriptionId New VRF subscription ID
     */
    function setSubscriptionId(uint64 newSubscriptionId) external;
    
    /**
     * @notice Propose update to the staking contract
     * @param newStakingContract New staking contract address
     */
    function proposeStakingContract(address newStakingContract) external;
    
    /**
     * @notice Execute proposed staking contract update after timelock
     */
    function executeStakingContractUpdate() external;
    
    /**
     * @notice Propose update to the liquidity guard contract
     * @param newLiquidityGuard New liquidity guard address
     */
    function proposeLiquidityGuard(address newLiquidityGuard) external;
    
    /**
     * @notice Execute proposed liquidity guard update after timelock
     */
    function executeLiquidityGuardUpdate() external;
    
    /**
     * @notice Propose update to the slashing contract
     * @param newSlashingContract New slashing contract address
     */
    function proposeSlashingContract(address newSlashingContract) external;
    
    /**
     * @notice Execute proposed slashing contract update after timelock
     */
    function executeSlashingContractUpdate() external;
    
    /**
     * @notice Propose update to the Uniswap router
     * @param newUniswapRouter New Uniswap router address
     */
    function proposeUniswapRouter(address newUniswapRouter) external;
    
    /**
     * @notice Execute proposed Uniswap router update after timelock
     */
    function executeUniswapRouterUpdate() external;
    
    /**
     * @notice Propose update to the liquidity pool address
     * @param newLiquidityPool New liquidity pool address
     */
    function proposeLiquidityPool(address newLiquidityPool) external;
    
    /**
     * @notice Execute proposed liquidity pool update after timelock
     */
    function executeLiquidityPoolUpdate() external;
    
    /**
     * @notice Recover ERC20 tokens accidentally sent to the contract
     * @param tokenAddress Address of the token to recover
     * @param amount Amount to recover
     */
    function recoverERC20(address tokenAddress, uint256 amount) external;
    
    /**
     * @notice Cancel a pending parameter update
     * @param paramName Name of the parameter update to cancel
     */
    function cancelPendingUpdate(string calldata paramName) external;
    
    /**
     * @notice Get the current reward rate after halving
     * @param baseAmount Base reward amount
     * @return adjustedAmount Adjusted reward amount after halving
     */
    function getAdjustedRewardAmount(uint256 baseAmount) external view returns (uint256);
    
    /**
     * @notice Get time until next halving
     * @return timeRemaining Seconds until next halving
     */
    function getTimeUntilNextHalving() external view returns (uint256);
    
    /**
     * @notice Get effective time for a pending parameter update
     * @param paramName Name of the parameter
     * @return effectiveTime Time when the update can be executed (0 if no pending update)
     */
    function getPendingUpdateTime(string calldata paramName) external view returns (uint256);
    
    /**
     * @notice Get pending parameter value
     * @param paramName Name of the parameter
     * @return value Pending numeric value
     * @return isAddress Whether this is an address update
     * @return addrValue Pending address value (if isAddress is true)
     */
    function getPendingUpdateValue(string calldata paramName) 
        external 
        view 
        returns (uint256 value, bool isAddress, address addrValue);
    
    /**
     * @notice Get pending penalty for a validator
     * @param validator Validator address
     * @return amount Pending penalty amount
     */
    function getPendingPenalty(address validator) external view returns (uint256);
    
    /**
     * @notice Get halving status information
     * @return currentRate Current halving rate
     * @return epoch Current halving epoch
     * @return lastHalvingTimestamp Timestamp of last halving
     * @return nextHalvingTimestamp Timestamp of next halving
     * @return isPaused Whether halving mechanism is paused
     */
    function getHalvingStatus() external view returns (
        uint256 currentRate,
        uint256 epoch,
        uint256 lastHalvingTimestamp,
        uint256 nextHalvingTimestamp,
        bool isPaused
    );
    
    /**
     * @notice Get distribution statistics
     * @return total Total rewards distributed
     * @return daily Today's distribution
     * @return dailyLimit Maximum daily distribution
     * @return nextResetTime Time when daily counter resets
     * @return isPaused Whether distribution is paused
     */
    function getDistributionStats() external view returns (
        uint256 total,
        uint256 daily,
        uint256 dailyLimit,
        uint256 nextResetTime,
        bool isPaused
    );
    
    /**
     * @notice Return the contract version
     * @return version Contract version
     */
    function version() external pure returns (string memory);
}
