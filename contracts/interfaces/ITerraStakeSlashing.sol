// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ITerraStakeSlashing {
    // ================================
    // 🔹 Slashing & Penalty Functions
    // ================================
    function slash(
        address participant,
        uint256 amount,
        string calldata reason,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function enforceSlashing(address participant, uint256 amount, string calldata reason) external;

    function isSlashed(address participant) external view returns (bool);
    function totalSlashed() external view returns (uint256 totalAmount, uint256 activeLockedStakes);

    function unlockSlashedStake(address participant) external;

    // ================================
    // 🔹 Security & Governance Functions
    // ================================
    function requestRedistributionPoolUpdate(address newPool) external;
    function executeRedistributionPoolUpdate(address newPool) external;
    function setPenaltyPercentage(uint256 newPercentage) external;
    function getPenaltyPercentage() external view returns (uint256);

    // ================================
    // 🔹 Events
    // ================================
    event ParticipantSlashed(
        address indexed participant,
        uint256 amount,
        uint256 redistributionAmount,
        uint256 burnAmount,
        string reason
    );

    event FundsRedistributed(uint256 amount, address recipient);
    event StakeLocked(address indexed participant, uint256 amount, uint256 lockUntil);
    event SlashedStakeUnlocked(address indexed participant, uint256 amount);
    event PenaltyPercentageUpdated(uint256 newPercentage);
}
