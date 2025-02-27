// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title ITerraStakeSlashing
 * @notice Interface for the TerraStakeSlashing contract that manages validator slashing
 */
interface ITerraStakeSlashing {
    // -------------------------------------------
    // 🔹 Structs
    // -------------------------------------------
    
    struct SlashProposal {
        uint256 id;
        address validator;
        uint256 slashPercentage;
        uint256 totalStake;
        bool executed;
        address proposer;
        uint256 proposedTime;
        string evidence;
        uint256 executionTime;
    }
    
    // -------------------------------------------
    // 🔹 Core Functions
    // -------------------------------------------
    
    function createSlashProposal(
        address validator,
        uint256 slashPercentage,
        string calldata evidence
    ) external returns (uint256);
    
    function executeSlashing(uint256 proposalId) external;
    
    function updateSlashParameters(
        uint256 _redistributionPercentage,
        uint256 _burnPercentage,
        uint256 _treasuryPercentage
    ) external;
    
    function updateCoolingOffPeriod(uint256 _coolingOffPeriod) external;
    
    function updateTreasuryWallet(address _treasuryWallet) external;
    
    function toggleEmergencyPause(bool paused) external;
    
    function recoverERC20(address token, uint256 amount) external;
    
    // -------------------------------------------
    // 🔹 View Functions
    // -------------------------------------------
    
    function getSlashProposal(uint256 proposalId) external view returns (SlashProposal memory);
    
    function getValidatorSlashInfo(address validator) external view returns (
        uint256 totalSlashed,
        uint256 lastSlashed,
        bool canBeSlashed
    );
    
    function getSlashParameters() external view returns (
        uint256 redistribution,
        uint256 burn,
        uint256 treasury,
        uint256 cooling
    );
    
    function getActiveSlashProposals() external view returns (uint256[] memory);
    
    function canSlashValidator(address validator) external view returns (bool);
    
    function calculateSlashAmounts(address validator, uint256 slashPercentage) external view returns (
        uint256 total,
        uint256 toRedistribute,
        uint256 toBurn,
        uint256 toTreasury
    );
    
    function getSlashingStats() external view returns (
        uint256 totalProposals,
        uint256 totalExecuted,
        uint256 totalAmountSlashed
    );
    
    // -------------------------------------------
    // 🔹 Events
    // -------------------------------------------
    
    event SlashProposalCreated(
        uint256 indexed proposalId,
        address indexed validator,
        uint256 slashPercentage,
        string evidence,
        uint256 timestamp
    );
    
    event ValidatorSlashed(
        address indexed validator,
        uint256 slashedAmount,
        uint256 redistributed,
        uint256 burned,
        uint256 sentToTreasury,
        uint256 timestamp
    );
    
    event SlashParametersUpdated(
        uint256 redistributionPercentage,
        uint256 burnPercentage,
        uint256 treasuryPercentage
    );
    
    event EmergencyPauseToggled(bool paused);
}
