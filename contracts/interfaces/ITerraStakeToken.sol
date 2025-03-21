// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ITerraStakeToken
 * @notice Interface for the core TerraStake token functionality
 * @dev Defines token operations including standard ERC20, governance, and liquidity functions
 */
interface ITerraStakeToken is IERC20 {
    // ================================
    //  Structs
    // ================================
    
    struct BuybackStats {
        uint256 totalTokensBought;
        uint256 totalUSDCSpent;
        uint256 lastBuybackTime;
        uint256 buybackCount;
    }

    // ================================
    //  Token & Supply Information
    // ================================
    
    /**
     * @notice Returns the maximum token supply cap
     * @return The maximum supply value
     */
    function MAX_SUPPLY() external view returns (uint256);

    // ================================
    //  Blacklist Management
    // ================================
    
    /**
     * @notice Adds or removes an address from the blacklist
     * @param account Address to update
     * @param status True to blacklist, false to remove from blacklist
     */
    function setBlacklist(address account, bool status) external;
    
    /**
     * @notice Batch blacklist management for multiple addresses
     * @param accounts Addresses to update
     * @param status True to blacklist, false to remove from blacklist
     */
    function batchBlacklist(address[] calldata accounts, bool status) external;
    
    /**
     * @notice Checks if an address is blacklisted
     * @param account Address to check
     * @return True if blacklisted, false otherwise
     */
    function isBlacklisted(address account) external view returns (bool);

    // ================================
    //  Minting
    // ================================
    
    /**
     * @notice Mint new tokens
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external;

    // ================================
    //  Permit Functions
    // ================================
        
    /**
     * @notice Executes a permit operation and transfers tokens in one transaction
     * @param owner Token owner
     * @param spender Token spender
     * @param value Approval amount
     * @param deadline Permit deadline
     * @param v Signature parameter
     * @param r Signature parameter
     * @param s Signature parameter
     * @param to Transfer recipient
     * @param amount Transfer amount
     */
    function permitAndTransfer(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        address to,
        uint256 amount
    ) external;

    // ================================
    //  Airdrop Function
    // ================================
    
    /**
     * @notice Perform an airdrop to multiple addresses
     * @param recipients Recipient addresses
     * @param amount Amount per recipient
     */
    function airdrop(address[] calldata recipients, uint256 amount) external;

    // ================================
    //  Security Functions
    // ================================
    
    /**
     * @notice Pause all token transfers
     */
    function pause() external;
    
    /**
     * @notice Unpause token transfers
     */
    function unpause() external;
    
    // ================================
    //  Ecosystem Integrations
    // ================================
    
    /**
     * @notice Update the governance contract
     * @param _governanceContract New governance contract address
     */
    function updateGovernanceContract(address _governanceContract) external;
    
    /**
     * @notice Update the staking contract
     * @param _stakingContract New staking contract address
     */
    function updateStakingContract(address _stakingContract) external;
    
    /**
     * @notice Update the liquidity guard
     * @param _liquidityGuard New liquidity guard address
     */
    function updateLiquidityGuard(address _liquidityGuard) external;
    
    // ================================
    //  Staking Integration
    // ================================
    
    /**
     * @notice Stake tokens from a user
     * @param from User address
     * @param amount Amount to stake
     * @return success Operation status
     */
    function stakeTokens(address from, uint256 amount) external returns (bool);
    
    /**
     * @notice Unstake tokens to a user
     * @param to User address
     * @param amount Amount to unstake
     * @return success Operation status
     */
    function unstakeTokens(address to, uint256 amount) external returns (bool);
    
    /**
     * @notice Get governance votes for an account
     * @param account The address to query
     * @return The number of governance votes
     */
    function getGovernanceVotes(address account) external view returns (uint256);
    
    /**
     * @notice Check if an account is penalized for governance violations
     * @param account The address to check
     * @return True if penalized, false otherwise
     */
    function isGovernorPenalized(address account) external view returns (bool);

    // ================================
    //  TWAP Oracle & Liquidity
    // ================================
    
    /**
     * @notice Get the TWAP price from Uniswap
     * @param twapInterval Time period for TWAP
     * @return price The TWAP price
     */
    function getTWAPPrice(uint32 twapInterval) external returns (uint256 price);
    
    /**
     * @notice Execute buyback
     * @param usdcAmount Amount of USDC to use
     * @return tokensReceived Amount of tokens received
     */
    function executeBuyback(uint256 usdcAmount) external returns (uint256 tokensReceived);
    
    /**
     * @notice Inject liquidity
     * @param amount Amount to inject
     * @return success Operation status
     */
    function injectLiquidity(uint256 amount) external returns (bool);
    
    /**
     * @notice Get buyback statistics
     * @return The buyback statistics struct
     */
    function getBuybackStatistics() external view returns (BuybackStats memory);

    // ================================
    //  Halving & Governance
    // ================================
    
    /**
     * @notice Trigger halving mechanism
     * @return Current halving epoch
     */
    function triggerHalving() external returns (uint256);
    
    /**
     * @notice Get halving details
     * @return period Halving period
     * @return lastTime Last halving time
     * @return epoch Current epoch
     */
    function getHalvingDetails() external view returns (
        uint256 period,
        uint256 lastTime,
        uint256 epoch
    );
    
    /**
     * @notice Get the current halving epoch
     * @return The current epoch
     */
    function currentHalvingEpoch() external view returns (uint256);
    
    /**
     * @notice Get the timestamp of the last halving
     * @return The timestamp
     */
    function lastHalvingTime() external view returns (uint256);
    
    /**
     * @notice Check governance approval for a transaction
     * @param account Address to check
     * @param amount Amount to check
     * @return approval status
     */
    function checkGovernanceApproval(address account, uint256 amount) external view returns (bool);
    
    /**
     * @notice Penalize governance violator
     * @param account Address to penalize
     */
    function penalizeGovernanceViolator(address account) external;

    // ================================
    //  Emergency Functions
    // ================================
    
    /**
     * @notice Emergency withdraw stuck tokens
     * @param token Token address
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, address to, uint256 amount) external;
    
    /**
     * @notice Emergency withdraw multiple tokens
     * @param tokens Array of token addresses
     * @param to Recipient address
     * @param amounts Array of amounts
     */
    function emergencyWithdrawMultiple(
        address[] calldata tokens,
        address to,
        uint256[] calldata amounts
    ) external;
    
    /**
     * @notice Activate circuit breaker
     */
    function activateCircuitBreaker() external;
    
    /**
     * @notice Reset circuit breaker
     */
    function resetCircuitBreaker() external;

    // ================================
    //  Events
    // ================================
    
    event BlacklistUpdated(address indexed account, bool status);
    event AirdropExecuted(address[] recipients, uint256 amount, uint256 totalAmount);
    event TWAPPriceQueried(uint32 twapInterval, uint256 price);
    event EmergencyWithdrawal(address token, address to, uint256 amount);
    event TokenBurned(address indexed burner, uint256 amount);
    event GovernanceUpdated(address indexed governanceContract);
    event StakingUpdated(address indexed stakingContract);
    event LiquidityGuardUpdated(address indexed liquidityGuard);
    event BuybackExecuted(uint256 amount, uint256 tokensReceived);
    event LiquidityInjected(uint256 amount, uint256 tokensUsed);
    event HalvingTriggered(uint256 epochNumber, uint256 timestamp);
    event TransferBlocked(address indexed from, address indexed to, uint256 amount, string reason);
    event StakingOperationExecuted(address indexed user, uint256 amount, bool isStake);
    event PermitUsed(address indexed owner, address indexed spender, uint256 amount);
    event ITOContractUpdated(address indexed itoContract);
}
