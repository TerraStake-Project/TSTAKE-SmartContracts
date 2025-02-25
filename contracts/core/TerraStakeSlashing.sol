// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";
import "../interfaces/ITerraStakeSlashing.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/ITerraStakeRewardDistributor.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";

interface IERC20Burnable {
    function burn(uint256 amount) external;
}

interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/**
 * @title TerraStakeSlashing
 * @notice Handles governance penalties, security breaches, and stake redistributions.
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
    ITerraStakeRewardDistributor public rewardDistributor;
    ITerraStakeLiquidityGuard public liquidityGuard;
    AggregatorV3Interface public priceOracle;

    uint256 public constant SLASHING_LOCK_PERIOD = 3 days;
    uint256 public constant PRICE_VALIDITY_PERIOD = 1 hours;
    uint256 public constant PRICE_DEVIATION_THRESHOLD = 10; // 10% maximum deviation from TWAP

    address public redistributionPool;
    uint256 public redistributionPercentage;
    uint256 public totalSlashed;
    uint256 public lastTWAPPrice;
    uint256 public lastTWAPTimestamp;

    mapping(address => bool) public isSlashed;
    mapping(address => uint256) public lastSlashingTime;
    mapping(address => uint256) public lockedStakes;

    event ParticipantSlashed(
        address indexed participant,
        uint256 amount,
        uint256 redistributionAmount,
        uint256 burnAmount,
        string reason
    );
    event FundsRedistributed(uint256 amount, address recipient);
    event PriceValidationFailed(uint256 currentPrice, uint256 twapPrice, uint256 deviationPercentage);
    event StakeLocked(address indexed participant, uint256 amount, uint256 lockUntil);

    constructor(
        address _tStakeToken,
        address _stakingContract,
        address _rewardDistributor,
        address _liquidityGuard,
        address _redistributionPool,
        uint256 _redistributionPercentage,
        address _priceOracle
    ) {
        require(_tStakeToken != address(0), "Invalid TSTAKE token address");
        require(_stakingContract != address(0), "Invalid staking contract address");
        require(_rewardDistributor != address(0), "Invalid reward distributor address");
        require(_liquidityGuard != address(0), "Invalid liquidity guard");
        require(_redistributionPool != address(0), "Invalid redistribution pool");
        require(_priceOracle != address(0), "Invalid price oracle address");
        require(_redistributionPercentage <= 10000, "Percentage exceeds 100%");

        tStakeToken = IERC20(_tStakeToken);
        stakingContract = ITerraStakeStaking(_stakingContract);
        rewardDistributor = ITerraStakeRewardDistributor(_rewardDistributor);
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);
        redistributionPool = _redistributionPool;
        redistributionPercentage = _redistributionPercentage;
        priceOracle = AggregatorV3Interface(_priceOracle);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(SLASHER_ROLE, msg.sender);
    }

    // ================================
    // 🔹 Price Validation
    // ================================
    function validatePrice() internal view returns (bool) {
        (, int256 answer, , uint256 updatedAt, ) = priceOracle.latestRoundData();
        require(answer > 0, "Invalid price feed response");
        require(updatedAt >= block.timestamp - PRICE_VALIDITY_PERIOD, "Stale price data");

        uint256 currentPrice = uint256(answer);
        
        if (lastTWAPPrice > 0) {
            uint256 deviation = currentPrice > lastTWAPPrice
                ? ((currentPrice - lastTWAPPrice) * 100) / lastTWAPPrice
                : ((lastTWAPPrice - currentPrice) * 100) / lastTWAPPrice;
                
            if (deviation > PRICE_DEVIATION_THRESHOLD) {
                emit PriceValidationFailed(currentPrice, lastTWAPPrice, deviation);
                return false;
            }
        }

        if (block.timestamp >= lastTWAPTimestamp + 1 hours) {
            lastTWAPPrice = currentPrice;
            lastTWAPTimestamp = block.timestamp;
        }
        
        return true;
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
        require(block.timestamp >= lastSlashingTime[participant] + SLASHING_LOCK_PERIOD, "Cooldown active");
        require(validatePrice(), "Price validation failed");

        IERC20Permit(address(tStakeToken)).permit(participant, address(this), amount, deadline, v, r, s);

        uint256 participantBalance = tStakeToken.balanceOf(participant);
        require(participantBalance >= amount, "Insufficient balance");

        tStakeToken.safeTransferFrom(participant, address(this), amount);
        isSlashed[participant] = true;
        totalSlashed += amount;
        lastSlashingTime[participant] = block.timestamp;
        lockedStakes[participant] = amount;

        uint256 redistributionAmount = (amount * redistributionPercentage) / 10000;
        uint256 burnAmount = amount - redistributionAmount;

        rewardDistributor.distributePenaltyRewards(redistributionAmount);
        emit FundsRedistributed(redistributionAmount, address(rewardDistributor));

        require(_burnTokens(burnAmount), "Burn failed");

        emit ParticipantSlashed(participant, amount, redistributionAmount, burnAmount, reason);
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
