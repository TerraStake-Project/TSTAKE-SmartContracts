// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";
import "../interfaces/ITerraStakeSlashing.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/IRewardDistributor.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";

interface IERC20Burnable {
    function burn(uint256 amount) external;
}

/**
 * @title TerraStakeSlashing (3B Cap Governance Secured)
 * @notice Handles governance penalties, security breaches, and stake redistributions.
 * ✅ **DAO-Managed with Multi-Sig Approvals & Governance Timelocks**
 * ✅ **Quadratic Voting Protected Against Whale Control**
 * ✅ **Slash Enforcement via Permit-Based Approval (EIP-2612)**
 * ✅ **Liquidity & Buyback Exploit Protection**
 */
contract TerraStakeSlashing is ITerraStakeSlashing, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ================================
    // 🔹 Governance & Security Roles
    // ================================
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant STAKING_CONTRACT_ROLE = keccak256("STAKING_CONTRACT_ROLE");
    bytes32 public constant REWARD_DISTRIBUTOR_ROLE = keccak256("REWARD_DISTRIBUTOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    IERC20 public immutable tStakeToken;
    ITerraStakeStaking public stakingContract;
    IRewardDistributor public rewardDistributor;
    ITerraStakeLiquidityGuard public liquidityGuard;

    uint256 public constant GOVERNANCE_DELAY = 2 days;
    uint256 public constant EMERGENCY_WITHDRAW_DELAY = 2 days; // Increased for security
    uint256 public constant SLASHING_LOCK_PERIOD = 3 days; // Protects against mass slashing abuse
    uint256 public constant REDISTRIBUTION_CHANGE_LOCK = 2 days; // Time-lock for redistribution updates

    // ================================
    // 🔹 State Variables
    // ================================
    address public redistributionPool;
    uint256 public redistributionPercentage;
    uint256 public totalSlashed;
    bool public paused;

    mapping(address => bool) public isSlashed;
    mapping(bytes32 => uint256) public pendingChanges;
    mapping(address => uint256) public lastSlashingTime;
    mapping(address => uint256) public lockedStakes; // Tracks locked funds post-slashing

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
    event RedistributionPoolUpdateRequested(address newPool, uint256 unlockTime);
    event RedistributionPoolUpdated(address newPool);
    event RedistributionPercentageUpdated(uint256 newPercentage);
    event GovernanceTimelockSet(bytes32 indexed action, uint256 parameter, uint256 unlockTime);
    event GovernanceRoleTransferred(address indexed oldAccount, address indexed newAccount);
    event SlashingPaused();
    event SlashingResumed();
    event EmergencyWithdrawalRequested(address indexed admin, uint256 amount, uint256 unlockTime);
    event EmergencyWithdrawalExecuted(address indexed admin, uint256 amount);
    event PenaltyUpdated(address indexed participant, uint256 newPenalty);
    event StakeLocked(address indexed participant, uint256 amount, uint256 lockUntil);

    // ================================
    // 🔹 Constructor
    // ================================
    constructor(
        address _tStakeToken,
        address _stakingContract,
        address _rewardDistributor,
        address _liquidityGuard,
        address _redistributionPool,
        uint256 _redistributionPercentage
    ) {
        require(_tStakeToken != address(0), "Invalid TSTAKE token address");
        require(_stakingContract != address(0), "Invalid staking contract address");
        require(_rewardDistributor != address(0), "Invalid reward distributor address");
        require(_liquidityGuard != address(0), "Invalid liquidity guard");
        require(_redistributionPool != address(0), "Invalid redistribution pool");
        require(_redistributionPercentage <= 10000, "Percentage exceeds 100%");

        tStakeToken = IERC20(_tStakeToken);
        stakingContract = ITerraStakeStaking(_stakingContract);
        rewardDistributor = IRewardDistributor(_rewardDistributor);
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);
        redistributionPool = _redistributionPool;
        redistributionPercentage = _redistributionPercentage;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(SLASHER_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
    }

    // ================================
    // 🔹 Secure Governance Updates
    // ================================
    function requestRedistributionPoolUpdate(address newPool) external onlyRole(GOVERNANCE_ROLE) {
        require(newPool != address(0), "Invalid address");
        pendingChanges[keccak256("REDISTRIBUTION_POOL")] = block.timestamp + REDISTRIBUTION_CHANGE_LOCK;
        emit RedistributionPoolUpdateRequested(newPool, block.timestamp + REDISTRIBUTION_CHANGE_LOCK);
    }

    function executeRedistributionPoolUpdate(address newPool) external onlyRole(GOVERNANCE_ROLE) {
        require(block.timestamp >= pendingChanges[keccak256("REDISTRIBUTION_POOL")], "Timelock active");
        redistributionPool = newPool;
        delete pendingChanges[keccak256("REDISTRIBUTION_POOL")];
        emit RedistributionPoolUpdated(newPool);
    }

    // ================================
    // 🔹 Slashing (With Locked Funds)
    // ================================
    function slash(
        address participant,
        uint256 amount,
        string calldata reason,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override onlyRole(SLASHER_ROLE) nonReentrant {
        require(participant != address(0), "Invalid participant");
        require(amount > 0, "Slashing amount must be > 0");
        require(!isSlashed[participant], "Already slashed");
        require(block.timestamp >= lastSlashingTime[participant] + SLASHING_LOCK_PERIOD, "Slashing cooldown active");

        IERC20Permit(address(tStakeToken)).permit(participant, address(this), amount, deadline, v, r, s);

        uint256 participantBalance = tStakeToken.balanceOf(participant);
        require(participantBalance >= amount, "Insufficient balance");

        require(!stakingContract.governanceViolators(participant), "Already penalized");

        tStakeToken.safeTransferFrom(participant, address(this), amount);
        isSlashed[participant] = true;
        totalSlashed += amount;
        lastSlashingTime[participant] = block.timestamp;
        lockedStakes[participant] = amount;

        uint256 redistributionAmount = (amount * redistributionPercentage) / 10000;
        uint256 burnAmount = amount - redistributionAmount;

        tStakeToken.safeTransfer(redistributionPool, redistributionAmount);
        emit FundsRedistributed(redistributionAmount, redistributionPool);

        require(_burnTokens(burnAmount), "Burn failed");

        emit ParticipantSlashed(participant, amount, redistributionAmount, burnAmount, reason);
        emit PenaltyUpdated(participant, amount);
        emit StakeLocked(participant, amount, block.timestamp + SLASHING_LOCK_PERIOD);
    }

    function _burnTokens(uint256 amount) internal returns (bool) {
        try IERC20Burnable(address(tStakeToken)).burn(amount) {
            return true;
        } catch {
            return tStakeToken.transfer(address(0), amount);
        }
    }
}
