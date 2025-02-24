// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ITerraStakeToken {
    // ================================
    // 🔹 Token & Supply Information
    // ================================
    function MAX_SUPPLY() external view returns (uint256);

    // ================================
    // 🔹 Blacklist Management
    // ================================
    function setBlacklist(address account, bool status) external;
    function batchBlacklist(address[] calldata accounts, bool status) external;
    function checkBlacklistStatus(address account) external view returns (bool status, string memory reason);

    // ================================
    // 🔹 Minting & Burning
    // ================================
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function batchBurn(address[] calldata froms, uint256[] calldata amounts) external;

    // ================================
    // 🔹 Airdrop Function
    // ================================
    function airdrop(address[] calldata recipients, uint256 amount) external;

    // ================================
    // 🔹 Security Functions
    // ================================
    function pause() external;
    function unpause() external;

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
    // 🔹 Emergency Functions
    // ================================
    function emergencyWithdrawMultiple(
        address[] calldata tokens,
        address to,
        uint256[] calldata amounts
    ) external;

    // ================================
    // 🔹 Uniswap V3 TWAP Oracle
    // ================================
    function uniswapPool() external view returns (address);

    // ================================
    // 🔹 Events
    // ================================
    event BlacklistUpdated(address indexed account, bool status);
    event AirdropExecuted(address[] recipients, uint256 amount, uint256 totalAmount);
    event TokenBurned(address indexed burner, uint256 amount);
    event EmergencyWithdrawal(address token, address to, uint256 amount);
    event GovernanceUpdated(address indexed governanceContract);
    event StakingUpdated(address indexed stakingContract);
    event LiquidityGuardUpdated(address indexed liquidityGuard);
}
