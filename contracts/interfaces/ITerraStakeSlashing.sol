// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title ITerraStakeSlashing
 * @notice Interface for the TerraStakeSlashing contract.
 */
interface ITerraStakeSlashing {
    // ------------------------------------------------------------------------
    // Core Functions
    // ------------------------------------------------------------------------
    /**
     * @notice Slash a participant for violating protocol rules.
     * @param participant Address to slash.
     * @param amount Amount of tokens to slash.
     * @param reason Description of the slashing reason.
     */
    function slash(
        address participant,
        uint256 amount,
        string calldata reason
    ) external;

    /**
     * @notice Propose an update to the redistribution pool address with a timelock.
     * @param newPool New redistribution pool address.
     */
    function proposeRedistributionPoolUpdate(address newPool) external;

    /**
     * @notice Execute an approved redistribution pool update after the timelock delay.
     * @param newPool New redistribution pool address.
     */
    function executeRedistributionPoolUpdate(address newPool) external;

    /**
     * @notice Propose an update to the redistribution percentage with a timelock.
     * @param newPercentage New redistribution percentage (basis points).
     */
    function proposeRedistributionUpdate(uint256 newPercentage) external;

    /**
     * @notice Execute an approved redistribution percentage update after the timelock delay.
     * @param newPercentage New redistribution percentage (basis points).
     */
    function executeRedistributionUpdate(uint256 newPercentage) external;

    /**
     * @notice Transfer a role to a new account.
     * @param role The role to transfer.
     * @param newAccount The new account to assign the role.
     */
    function transferRole(bytes32 role, address newAccount) external;

    /**
     * @notice Pause the contract to stop state-changing operations.
     */
    function pause() external;

    /**
     * @notice Unpause the contract to resume state-changing operations.
     */
    function unpause() external;

    // ------------------------------------------------------------------------
    // View Functions
    // ------------------------------------------------------------------------
    /**
     * @notice Check if the contract is currently paused.
     * @return True if the contract is paused, false otherwise.
     */
    function paused() external view returns (bool);

    /**
     * @notice Check if a participant has already been slashed.
     * @param participant Address of the participant.
     * @return True if the participant has been slashed, false otherwise.
     */
    function checkIfSlashed(address participant) external view returns (bool);

    /**
     * @notice Get the total amount of tokens slashed.
     * @return Total tokens slashed.
     */
    function getTotalSlashed() external view returns (uint256);

    /**
     * @notice Get the current redistribution percentage.
     * @return Redistribution percentage (basis points).
     */
    function getRedistributionPercentage() external view returns (uint256);

    /**
     * @notice Get the address of the current redistribution pool.
     * @return Address of the redistribution pool.
     */
    function getRedistributionPool() external view returns (address);

    /**
     * @notice Get the timelock of a pending change proposal.
     * @param proposalId Unique identifier of the proposal.
     * @return Governance timelock for changes.
     */
    function getPendingChange(bytes32 proposalId) external view returns (uint256);
}