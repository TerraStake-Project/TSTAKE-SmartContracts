// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract StakingContract is Ownable {
    IERC20 public stakingToken;

    struct StakingPosition {
        uint256 amount;        // Total staked amount
        uint256 rewardDebt;    // Rewards already claimed
        uint256 lastCheckpoint; // Last checkpoint for reward calculations
        uint256 stakingStart;  // Timestamp when the staking started
    }

    struct ProjectData {
        bool isActive;         // Whether the project is active
        uint256 totalStaked;   // Total staked in the project
        uint32 penaltyRate;    // Penalty rate (in basis points, 1 bp = 0.01%)
    }

    uint256 public gracePeriod;  // Grace period (in seconds)
    mapping(address => mapping(uint256 => StakingPosition)) public stakingPositions; // User staking positions
    mapping(uint256 => ProjectData) public projectData; // Project-specific staking data

    event Staked(address indexed user, uint256 projectId, uint256 amount);
    event Unstaked(address indexed user, uint256 projectId, uint256 amount, uint256 penalty);
    event PenaltyRateUpdated(uint256 indexed projectId, uint32 newRate);

    constructor(address _stakingToken, uint256 _gracePeriod) Ownable(msg.sender) {
        require(_stakingToken != address(0), "Invalid token address");
        stakingToken = IERC20(_stakingToken);
        gracePeriod = _gracePeriod;
    }

    function stake(uint256 projectId, uint256 amount) external {
        require(amount > 0, "Stake amount must be greater than zero");
        require(projectData[projectId].isActive, "Project is not active");

        StakingPosition storage position = stakingPositions[msg.sender][projectId];

        require(stakingToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        position.amount += amount;
        position.stakingStart = block.timestamp;
        projectData[projectId].totalStaked += amount;

        emit Staked(msg.sender, projectId, amount);
    }

    function unstake(uint256 projectId) external {
        StakingPosition storage position = stakingPositions[msg.sender][projectId];
        require(position.amount > 0, "No tokens staked");

        uint256 penalty = 0;
        uint256 amount = position.amount;

        if (block.timestamp > position.stakingStart + gracePeriod) {
            penalty = (amount * projectData[projectId].penaltyRate) / 10000;
        }

        uint256 amountAfterPenalty = amount - penalty;

        position.amount = 0;
        projectData[projectId].totalStaked -= amount;

        require(stakingToken.transfer(msg.sender, amountAfterPenalty), "Transfer failed");

        emit Unstaked(msg.sender, projectId, amountAfterPenalty, penalty);
    }

    function updateGracePeriod(uint256 _gracePeriod) external onlyOwner {
        gracePeriod = _gracePeriod;
    }

    function updatePenaltyRate(uint256 projectId, uint32 penaltyRate) external onlyOwner {
        require(penaltyRate <= 10000, "Penalty rate cannot exceed 100%");
        projectData[projectId].penaltyRate = penaltyRate;
        emit PenaltyRateUpdated(projectId, penaltyRate);
    }

    function activateProject(uint256 projectId) external onlyOwner {
        projectData[projectId].isActive = true;
    }

    function deactivateProject(uint256 projectId) external onlyOwner {
        projectData[projectId].isActive = false;
    }
}
