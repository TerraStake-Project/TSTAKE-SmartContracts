// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "../interfaces/ITerraStakeRewardDistributor.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";
import "../interfaces/ITerraStakeSlashing.sol";

/**
 * @title TerraStakeRewardDistributor (Merged & Optimized)
 * @notice Handles staking rewards, liquidity injection, APR management, penalty redistribution, and randomized halving (every 2 years).
 */
contract TerraStakeRewardDistributor is AccessControl, VRFConsumerBaseV2, ITerraStakeRewardDistributor {
    // 🔑 DAO Governance Roles
    bytes32 public constant STAKING_CONTRACT_ROLE = keccak256("STAKING_CONTRACT_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant MULTISIG_ROLE = keccak256("MULTISIG_ROLE");

    // 📌 Constants
    uint256 public constant MAX_LIQUIDITY_INJECTION_RATE = 10;
    uint256 public constant MAX_HALVING_REDUCTION_RATE = 90;
    uint256 public constant TWO_YEARS_IN_SECONDS = 730 days;
    
    // 📌 State Variables
    IERC20 public immutable rewardToken;
    ITerraStakeStaking public stakingContract;
    ISwapRouter public immutable uniswapRouter;
    ITerraStakeLiquidityGuard public immutable liquidityGuard;
    ITerraStakeSlashing public immutable slashingContract;
    address public rewardSource;
    address public liquidityPool;
    
    uint256 public totalDistributed;
    uint256 public halvingEpoch;
    uint256 public lastHalvingTime;
    uint256 public halvingReductionRate = 80;
    
    bool public autoBuybackEnabled = true;

    // Chainlink VRF for Randomized Halving
    bytes32 public keyHash;
    uint64 public subscriptionId;
    mapping(bytes32 => bool) private vrfRequests;

    event RewardDistributed(address indexed user, uint256 amount);
    event HalvingApplied(uint256 newRewardRate, uint256 halvingEpoch);
    event LiquidityInjected(uint256 amount);
    
    constructor(
        address _rewardToken,
        address _rewardSource,
        address _stakingContract,
        address _uniswapRouter,
        address _liquidityPool,
        address _liquidityGuard,
        address _slashingContract,
        address _vrfCoordinator,
        bytes32 _keyHash,
        uint64 _subscriptionId
    ) VRFConsumerBaseV2(_vrfCoordinator) {
        require(_rewardToken != address(0), "Invalid reward token");
        require(_stakingContract != address(0), "Invalid staking contract address");
        
        rewardToken = IERC20(_rewardToken);
        rewardSource = _rewardSource;
        stakingContract = ITerraStakeStaking(_stakingContract);
        uniswapRouter = ISwapRouter(_uniswapRouter);
        liquidityPool = _liquidityPool;
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);
        slashingContract = ITerraStakeSlashing(_slashingContract);

        keyHash = _keyHash;
        subscriptionId = _subscriptionId;

        lastHalvingTime = block.timestamp;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
    }

    function distributeReward(address user, uint256 amount) external override onlyRole(STAKING_CONTRACT_ROLE) {
        require(user != address(0), "Invalid user address");
        require(amount > 0, "Amount must be greater than zero");

        applyHalving();
        uint256 adjustedAmount = (amount * halvingReductionRate) / 100;
        require(rewardToken.transferFrom(rewardSource, user, adjustedAmount), "Reward transfer failed");

        liquidityGuard.injectLiquidity((adjustedAmount * MAX_LIQUIDITY_INJECTION_RATE) / 100);

        totalDistributed += adjustedAmount;
        emit RewardDistributed(user, adjustedAmount);
    }

    function applyHalving() public {
        if (block.timestamp >= lastHalvingTime + TWO_YEARS_IN_SECONDS) {
            lastHalvingTime = block.timestamp;
            halvingEpoch++;
            halvingReductionRate = (halvingReductionRate * 90) / 100;
            emit HalvingApplied(halvingReductionRate, halvingEpoch);
        }
    }
}

