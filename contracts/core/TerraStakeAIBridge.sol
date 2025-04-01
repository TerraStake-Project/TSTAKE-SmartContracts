// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import "../interfaces/IAIEngine.sol";
import "../interfaces/ITerraStakeToken.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/ITerraStakeTreasuryManager.sol";

/**
 * @title TerraStakeAIBridge
 * @notice AI-driven bridge to dynamically manage TerraStake protocol parameters
 */
contract TerraStakeAIBridge is 
    Initializable, 
    AccessControlUpgradeable, 
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    // Roles
    bytes32 public constant AI_EXECUTOR_ROLE = keccak256("AI_EXECUTOR_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    // Protocol references
    IAIEngine public aiEngine;
    ITerraStakeToken public terraStakeToken;
    ITerraStakeStaking public staking;
    ITerraStakeTreasuryManager public treasuryManager;

    // AI Settings
    uint64 public aiUpdateFrequency;
    uint64 public lastAIUpdate;
    uint16 public recommendedStakingAPY;
    uint16 public recommendedBuybackTax;
    uint16 public confidenceScore;
    
    // Circuit Breaker
    bool public circuitBreakerEnabled;

    // Events
    event AIParametersUpdated(uint16 stakingAPY, uint16 buybackTax, uint16 confidence);
    event AIBuybackExecuted(uint256 amount);
    event AILiquidityInjected(uint256 amount);
    event AIStakingFunded(uint256 amount);
    event AIEmergencyPaused();
    event AIExecutorUpdated(address executor, bool authorized);

    /**
     * @notice Initialize the AI Bridge
     */
    function initialize(
        address _aiEngine,
        address _terraStakeToken,
        address _staking,
        address _treasuryManager,
        address _admin
    ) external initializer {
        require(_aiEngine != address(0), "Invalid AIEngine");
        require(_terraStakeToken != address(0), "Invalid TerraStakeToken");
        require(_staking != address(0), "Invalid Staking Contract");
        require(_treasuryManager != address(0), "Invalid TreasuryManager");

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        aiEngine = IAIEngine(_aiEngine);
        terraStakeToken = ITerraStakeToken(_terraStakeToken);
        staking = ITerraStakeStaking(_staking);
        treasuryManager = ITerraStakeTreasuryManager(_treasuryManager);

        aiUpdateFrequency = 1 days;
        lastAIUpdate = uint64(block.timestamp);
        circuitBreakerEnabled = true;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(AI_EXECUTOR_ROLE, _admin);
        _grantRole(GOVERNANCE_ROLE, _admin);
    }

    /**
     * @notice Update AI-driven parameters (staking APY, buyback tax)
     */
    function updateAIParameters(
        uint16 stakingAPY,
        uint16 buybackTax,
        uint16 confidence
    ) external onlyRole(AI_EXECUTOR_ROLE) whenNotPaused {
        require(block.timestamp >= lastAIUpdate + aiUpdateFrequency, "AI update too frequent");
        require(stakingAPY <= 10000, "Invalid staking APY");
        require(buybackTax <= 500, "Invalid buyback tax");
        require(confidence <= 10000, "Invalid confidence");

        recommendedStakingAPY = stakingAPY;
        recommendedBuybackTax = buybackTax;
        confidenceScore = confidence;
        lastAIUpdate = uint64(block.timestamp);

        // Apply high-confidence AI recommendations
        if (confidence >= 7500) {
            staking.updateRewardRate(stakingAPY);
            terraStakeToken.setBuybackTax(buybackTax);
        }

        emit AIParametersUpdated(stakingAPY, buybackTax, confidence);
    }

    /**
     * @notice Execute AI-driven buyback strategy
     */
    function executeAIBuyback(uint256 amount) external onlyRole(AI_EXECUTOR_ROLE) whenNotPaused {
        require(amount > 0, "Amount must be greater than zero");
        treasuryManager.executeBuyback(amount);
        emit AIBuybackExecuted(amount);
    }

    /**
     * @notice Inject liquidity into TerraStake ecosystem
     */
    function injectAILiquidity(uint256 amount) external onlyRole(AI_EXECUTOR_ROLE) whenNotPaused {
        require(amount > 0, "Amount must be greater than zero");
        treasuryManager.addLiquidity(amount);
        emit AILiquidityInjected(amount);
    }

    /**
     * @notice Allocate staking rewards dynamically
     */
    function fundStakingRewards(uint256 amount) external onlyRole(AI_EXECUTOR_ROLE) whenNotPaused {
        require(amount > 0, "Amount must be greater than zero");
        treasuryManager.allocateToReserve(amount);
        emit AIStakingFunded(amount);
    }

    /**
     * @notice AI triggers an emergency pause
     */
    function triggerAIEmergencyPause() external onlyRole(AI_EXECUTOR_ROLE) whenNotPaused {
        require(circuitBreakerEnabled, "Circuit breaker disabled");

        terraStakeToken.activateCircuitBreaker();
        treasuryManager.emergencyPause();
        _pause();

        emit AIEmergencyPaused();
    }

    /**
     * @notice Admin function to set circuit breaker state
     */
    function setCircuitBreakerState(bool enabled) external onlyRole(GOVERNANCE_ROLE) {
        circuitBreakerEnabled = enabled;
    }

    /**
     * @notice Set AI Executor role
     */
    function setAIExecutor(address executor, bool authorized) external onlyRole(GOVERNANCE_ROLE) {
        if (authorized) {
            _grantRole(AI_EXECUTOR_ROLE, executor);
        } else {
            _revokeRole(AI_EXECUTOR_ROLE, executor);
        }
        emit AIExecutorUpdated(executor, authorized);
    }
}
