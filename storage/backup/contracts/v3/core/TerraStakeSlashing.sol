// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/ITerraStakeSlashing.sol"; // Import the interface

interface IERC20Burnable {
    function burn(uint256 amount) external;
}

/**
 * @title TerraStake Slashing Contract
 * @notice Manages slashing penalties for protocol violations, redistributing or burning funds as defined.
 */
contract TerraStakeSlashing is ITerraStakeSlashing, AccessControl, ReentrancyGuard {
    // ------------------------------------------------------------------------
    // Constants and Immutables
    // ------------------------------------------------------------------------
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    address public immutable ADMIN_ADDRESS = 0xcB3705b50773e95fCe6d3Fcef62B4d753aA0059d; // Admin address
    IERC20 public immutable tStakeToken;

    uint256 public constant GOVERNANCE_DELAY = 2 days; // Governance timelock delay

    // ------------------------------------------------------------------------
    // State Variables
    // ------------------------------------------------------------------------
    address public redistributionPool;
    uint256 public redistributionPercentage; // Percentage in basis points
    uint256 public totalSlashed;

    bool public paused; // Emergency pause state

    mapping(address => bool) public isSlashed; // Tracks slashed participants
    mapping(bytes32 => uint256) public pendingChanges; // Governance timelock for changes

    // ------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------
    event ParticipantSlashed(
        address indexed participant,
        uint256 amount,
        uint256 redistributionAmount,
        uint256 burnAmount,
        string reason
    );
    event RedistributionPoolUpdateProposed(address newPool, uint256 effectiveTime);
    event RedistributionPoolUpdated(address newPool);
    event RedistributionUpdateProposed(uint256 newPercentage, uint256 effectiveTime);
    event RedistributionPercentageUpdated(uint256 newPercentage);
    event ContractPaused();
    event ContractUnpaused();
    event RoleTransferred(bytes32 role, address oldAccount, address newAccount);

    // ------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------
    constructor(
        address _tStakeToken,
        address _redistributionPool,
        uint256 _redistributionPercentage
    ) {
        require(_tStakeToken != address(0), "Invalid TSTAKE token address");
        require(_redistributionPool != address(0), "Invalid redistribution pool");
        require(_redistributionPercentage <= 10000, "Percentage exceeds 100%");

        tStakeToken = IERC20(_tStakeToken);
        redistributionPool = _redistributionPool;
        redistributionPercentage = _redistributionPercentage;

        _grantRole(DEFAULT_ADMIN_ROLE, ADMIN_ADDRESS);
        _grantRole(GOVERNANCE_ROLE, ADMIN_ADDRESS);
        _grantRole(SLASHER_ROLE, ADMIN_ADDRESS);
    }

    // ------------------------------------------------------------------------
    // Emergency Controls
    // ------------------------------------------------------------------------
    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    function pause() external override onlyRole(GOVERNANCE_ROLE) {
        paused = true;
        emit ContractPaused();
    }

    function unpause() external override onlyRole(GOVERNANCE_ROLE) {
        paused = false;
        emit ContractUnpaused();
    }

    // ------------------------------------------------------------------------
    // Slash Logic
    // ------------------------------------------------------------------------
    function slash(
        address participant,
        uint256 amount,
        string calldata reason
    ) external override onlyRole(SLASHER_ROLE) nonReentrant whenNotPaused {
        require(participant != address(0), "Invalid participant address");
        require(amount > 0, "Slashing amount must be > 0");
        require(!isSlashed[participant], "Participant already slashed");
        require(
            tStakeToken.allowance(participant, address(this)) >= amount,
            "Insufficient allowance"
        );

        uint256 participantBalance = tStakeToken.balanceOf(participant);
        require(participantBalance >= amount, "Insufficient balance to slash");

        bool transferSuccess = tStakeToken.transferFrom(participant, address(this), amount);
        require(transferSuccess, "Slashing transfer failed");

        isSlashed[participant] = true;
        totalSlashed += amount;

        uint256 redistributionAmount = (amount * redistributionPercentage) / 10000;
        uint256 burnAmount = amount - redistributionAmount;

        if (redistributionAmount > 0) {
            bool redistributeSuccess = tStakeToken.transfer(redistributionPool, redistributionAmount);
            require(redistributeSuccess, "Redistribution transfer failed");
        }

        if (burnAmount > 0) {
            require(_burnTokens(burnAmount), "Burn failed");
        }

        emit ParticipantSlashed(participant, amount, redistributionAmount, burnAmount, reason);
    }

    // ------------------------------------------------------------------------
    // Governance Functions
    // ------------------------------------------------------------------------
    function proposeRedistributionPoolUpdate(address newPool) external override onlyRole(GOVERNANCE_ROLE) {
        require(newPool != address(0), "Invalid pool address");
        bytes32 proposalId = keccak256(abi.encodePacked("REDISTRIBUTION_POOL_UPDATE", newPool));
        pendingChanges[proposalId] = block.timestamp + GOVERNANCE_DELAY;

        emit RedistributionPoolUpdateProposed(newPool, pendingChanges[proposalId]);
    }

    function executeRedistributionPoolUpdate(address newPool) external override onlyRole(GOVERNANCE_ROLE) {
        bytes32 proposalId = keccak256(abi.encodePacked("REDISTRIBUTION_POOL_UPDATE", newPool));
        require(block.timestamp >= pendingChanges[proposalId], "Proposal still pending");
        require(pendingChanges[proposalId] != 0, "No such proposal");

        redistributionPool = newPool;
        delete pendingChanges[proposalId];

        emit RedistributionPoolUpdated(newPool);
    }

    function proposeRedistributionUpdate(uint256 newPercentage) external override onlyRole(GOVERNANCE_ROLE) {
        require(newPercentage <= 10000, "Percentage exceeds 100%");
        bytes32 proposalId = keccak256(abi.encodePacked("REDISTRIBUTION_UPDATE", newPercentage));
        pendingChanges[proposalId] = block.timestamp + GOVERNANCE_DELAY;

        emit RedistributionUpdateProposed(newPercentage, pendingChanges[proposalId]);
    }

    function executeRedistributionUpdate(uint256 newPercentage) external override onlyRole(GOVERNANCE_ROLE) {
        bytes32 proposalId = keccak256(abi.encodePacked("REDISTRIBUTION_UPDATE", newPercentage));
        require(block.timestamp >= pendingChanges[proposalId], "Proposal still pending");
        require(pendingChanges[proposalId] != 0, "No such proposal");

        redistributionPercentage = newPercentage;
        delete pendingChanges[proposalId];

        emit RedistributionPercentageUpdated(newPercentage);
    }

    function transferRole(bytes32 role, address newAccount) external override {
        require(hasRole(role, msg.sender), "Caller must have role");
        require(newAccount != address(0), "Invalid new account");

        revokeRole(role, msg.sender);
        grantRole(role, newAccount);

        emit RoleTransferred(role, msg.sender, newAccount);
    }

    // ------------------------------------------------------------------------
    // Internal Burn Logic
    // ------------------------------------------------------------------------
    function _burnTokens(uint256 amount) internal returns (bool) {
        try IERC20Burnable(address(tStakeToken)).burn(amount) {
            return true;
        } catch {
            return tStakeToken.transfer(address(0), amount);
        }
    }

    // ------------------------------------------------------------------------
    // View Functions
    // ------------------------------------------------------------------------
    function checkIfSlashed(address participant) external view override returns (bool) {
        return isSlashed[participant];
    }

    function getTotalSlashed() external view override returns (uint256) {
        return totalSlashed;
    }

    function getRedistributionPercentage() external view override returns (uint256) {
        return redistributionPercentage;
    }

    function getRedistributionPool() external view override returns (address) {
        return redistributionPool;
    }

    function getPendingChange(bytes32 proposalId) external view override returns (uint256) {
        return pendingChanges[proposalId];
    }
}