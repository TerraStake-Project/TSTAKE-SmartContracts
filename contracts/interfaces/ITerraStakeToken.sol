// SPDX-License-Identifier: GPL 3-0
pragma solidity 0.8.28;

interface ITerraStakeToken {
    // ================================
    // 🔹 Token & Supply Information
    // ================================
    function MAX_SUPPLY() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);

    // ================================
    // 🔹 Blacklist Management
    // ================================
    function setBlacklist(address account, bool status) external;
    function batchBlacklist(address[] calldata accounts, bool status) external;
    function isBlacklisted(address account) external view returns (bool);

    // ================================
    // 🔹 Minting & Burning
    // ================================
    function mint(address to, uint256 amount) external;
    function burnFrom(address from, uint256 amount) external;
    function burn(uint256 amount) external;

    // ================================
    // 🔹 Transfer & Allowance Functions
    // ================================
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);

    // ================================
    // 🔹 Permit Functions
    // ================================
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
    function permitAndTransfer(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s, address to, uint256 amount) external;

    // ================================
    // 🔹 Airdrop Function
    // ================================
    function airdrop(address[] calldata recipients, uint256 amount) external;

    // ================================
    // 🔹 Security Functions
    // ================================
    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);

    // ================================
    // 🔹 Ecosystem Integrations
    // ================================
    function updateGovernanceContract(address _governanceContract) external;
    function updateStakingContract(address _stakingContract) external;
    function updateLiquidityGuard(address _liquidityGuard) external;
    function governanceContract() external view returns (address);
    function stakingContract() external view returns (address);
    function liquidityGuard() external view returns (address);
    
    // ================================
    // 🔹 Staking Integration
    // ================================
    function stakeTokens(address from, uint256 amount) external returns (bool);
    function unstakeTokens(address to, uint256 amount) external returns (bool);
    function getGovernanceVotes(address account) external view returns (uint256);
    function isGovernorPenalized(address account) external view returns (bool);

    // ================================
    // 🔹 TWAP Oracle & Liquidity
    // ================================
    function uniswapPool() external view returns (address);
    function getTWAPPrice(uint32 twapInterval) external returns (uint256 price);
    function executeBuyback(uint256 usdcAmount) external returns (uint256 tokensReceived);
    function injectLiquidity(uint256 amount) external returns (bool);
    function getBuybackStatistics() external view returns (
        uint256 totalTokensBought,
        uint256 totalUSDCSpent,
        uint256 lastBuybackTime,
        uint256 buybackCount
    );

    // ================================
    // 🔹 Halving & Governance
    // ================================
    function triggerHalving() external returns (uint256);
    function getHalvingDetails() external view returns (uint256 period, uint256 lastTime, uint256 epoch);
    function currentHalvingEpoch() external view returns (uint256);
    function lastHalvingTime() external view returns (uint256);
    function checkGovernanceApproval(address account, uint256 amount) external view returns (bool);
    function penalizeGovernanceViolator(address account) external;

    // ================================
    // 🔹 Emergency Functions
    // ================================
    function emergencyWithdraw(address token, address to, uint256 amount) external;
    function emergencyWithdrawMultiple(
        address[] calldata tokens,
        address to,
        uint256[] calldata amounts
    ) external;
    function activateCircuitBreaker() external;
    function resetCircuitBreaker() external;

    // ================================
    // 🔹 Upgradeability
    // ================================
    function getImplementation() external view returns (address);

    // ================================
    // 🔹 Events
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
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
