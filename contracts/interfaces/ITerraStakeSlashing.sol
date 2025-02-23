// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITerraStakeSlashing {
    // ------------------------------------------------------------------------
    // 🔹 Events for Transparency & Tracking
    // ------------------------------------------------------------------------
    event ParticipantSlashed(
        address indexed participant,
        uint256 amount,
        uint256 redistributionAmount,
        uint256 burnAmount,
        string reason
    );
    event StakeLocked(address indexed participant, uint256 amount, uint256 lockUntil);
    event FundsRedistributed(uint256 amount, address indexed destination);
    event FundsBurned(uint256 amount);
    
    event RedistributionPoolUpdateRequested(address indexed newPool, uint256 unlockTime);
    event RedistributionPoolUpdated(address indexed newPool);
    event RedistributionPercentageUpdated(uint256 newPercentage);
    
    event GovernanceRoleTransferred(address indexed oldAccount, address indexed newAccount);
    event GovernanceTimelockSet(bytes32 indexed setting, uint256 newValue, uint256 unlockTime);
    event GovernanceTimelockExecuted(bytes32 indexed setting, uint256 oldValue, uint256 newValue);
    event GovernanceTimelockCanceled(bytes32 indexed setting);

    event SlashingPaused();
    event SlashingResumed();
    event PenaltyUpdated(address indexed participant, uint256 newPenalty);
    
    event EmergencyWithdrawalRequested(address indexed admin, uint256 amount, uint256 unlockTime);
    event EmergencyWithdrawalExecuted(address indexed admin, uint256 amount);

    // ------------------------------------------------------------------------
    // 🔹 Governance Roles & Security
    // ------------------------------------------------------------------------
    function SLASHER_ROLE() external pure returns (bytes32);
    function GOVERNANCE_ROLE() external pure returns (bytes32);
    function STAKING_CONTRACT_ROLE() external pure returns (bytes32);
    function REWARD_DISTRIBUTOR_ROLE() external pure returns (bytes32);
    function EMERGENCY_ROLE() external pure returns (bytes32);
    function DEFAULT_ADMIN_ROLE() external pure returns (bytes32);

    // ------------------------------------------------------------------------
    // 🔹 Core System Contracts
    // ------------------------------------------------------------------------
    function tStakeToken() external view returns (address);
    function stakingContract() external view returns (address);
    function rewardDistributor() external view returns (address);
    function liquidityGuard() external view returns (address);
    function redistributionPool() external view returns (address);

    // ------------------------------------------------------------------------
    // 🔹 Slashing & Fund Redistribution
    // ------------------------------------------------------------------------
    function redistributionPercentage() external view returns (uint256);
    function totalSlashed() external view returns (uint256);
    function slashingLockPeriod() external view returns (uint256);
    
    function checkIfSlashed(address participant) external view returns (bool);
    function getTotalSlashed() external view returns (uint256);
    function getRedistributionPercentage() external view returns (uint256);
    function getRedistributionPool() external view returns (address);
    function isStakerPenalized(address participant) external view returns (bool);
    function getGovernanceTimelock(bytes32 setting) external view returns (uint256);

    function slash(
        address participant,
        uint256 amount,
        string calldata reason,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function lockStakedFunds(address participant, uint256 amount) external;

    function setPenalty(
        address participant,
        uint256 newPenalty
    ) external;

    function redistributeSlashedFunds(uint256 amount, address destination) external;

    function burnSlashedFunds(uint256 amount) external;

    function setGovernanceTimelock(
        bytes32 setting,
        uint256 newValue
    ) external;

    function executeGovernanceTimelock(
        bytes32 setting
    ) external;

    function cancelGovernanceTimelock(
        bytes32 setting
    ) external;

    // ------------------------------------------------------------------------
    // 🔹 Emergency Controls & Security Functions
    // ------------------------------------------------------------------------
    function pause() external;
    function unpause() external;

    function requestEmergencyWithdraw(uint256 amount) external;
    function executeEmergencyWithdraw() external;

    // ------------------------------------------------------------------------
    // 🔹 Governance Management & Multi-Sig
    // ------------------------------------------------------------------------
    function requestRedistributionPoolUpdate(address newPool) external;
    function executeRedistributionPoolUpdate(address newPool) external;
    
    function transferGovernanceRole(address newGovernance) external;
}
