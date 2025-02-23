// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITerraStakeToken {
    // ================================
    // 🔹 Token Metadata & Supply
    // ================================

    function name() external view returns (string memory);
    
    function symbol() external view returns (string memory);

    function totalSupply() external view returns (uint256);

    function MAX_CAP() external view returns (uint256);

    // ================================
    // 🔹 Liquidity Management
    // ================================

    function liquidityPool() external view returns (address);

    function uniswapRouter() external view returns (address);

    function usdcToken() external view returns (address);

    function liquidityFee() external view returns (uint256);

    function minLiquidityFee() external view returns (uint256);

    function maxLiquidityFee() external view returns (uint256);

    function tradingVolume() external view returns (uint256);

    function lastFeeUpdateTime() external view returns (uint256);

    function addLiquidity(uint256 usdcAmount, uint256 tStakeAmount) external;

    // ================================
    // 🔹 Governance & Voting System
    // ================================

    function governanceThreshold() external view returns (uint256);

    function proposeFeeAdjustment(uint256 newFee) external;

    function executeProposal(uint256 proposalId) external;

    function proposals(uint256 proposalId) external view returns (
        address proposer,
        uint256 newLiquidityFee,
        uint256 endTime,
        bool executed
    );

    // ================================
    // 🔹 Security & Emergency Functions
    // ================================

    function pause() external;

    function unpause() external;

    function hasRole(bytes32 role, address account) external view returns (bool);

    // ================================
    // 🔹 Verification Functions
    // ================================

    function officialInfo() external pure returns (string memory);

    function verifyOwner() external pure returns (string memory);

    // ================================
    // 🔹 Events
    // ================================

    event LiquidityFeeUpdated(uint256 newFee);
    event LiquidityAdded(uint256 usdcAmount, uint256 tStakeAmount);
    event ProposalCreated(uint256 proposalId, address proposer, uint256 newFee, uint256 endTime);
    event ProposalExecuted(uint256 proposalId, uint256 newFee);
    event GovernanceFailed(uint256 proposalId, string reason);
}
