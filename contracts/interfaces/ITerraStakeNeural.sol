// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

/**
 * @title ITerraStakeNeural
 * @notice Interface for the neural/DNA components of the TerraStakeToken contract
 * @dev Defines just the AI-related functionality without conflicting with ERC20 implementation
 */
interface ITerraStakeNeural {
    // ===============================
    // Structs
    // ===============================
    
    struct NeuralWeight {
        uint256 currentWeight;      // EMA-based value (1e18 scale)
        uint256 rawSignal;          // raw input signal
        uint256 lastUpdateTime;     // track update time
        uint256 emaSmoothingFactor; // e.g. 1-100
    }

    struct ConstituentData {
        bool isActive;
        uint256 activationTime;
        uint256 evolutionScore;
    }

    // ===============================
    // Events
    // ===============================
    
    event NeuralWeightUpdated(address indexed asset, uint256 weight, uint256 smoothingFactor);
    event ConstituentAdded(address indexed asset, uint256 timestamp);
    event ConstituentRemoved(address indexed asset, uint256 timestamp);
    event DiversityIndexUpdated(uint256 newIndex);
    event AdaptiveRebalanceTriggered(string reason, uint256 timestamp);
    event SelfOptimizationExecuted(uint256 counter, uint256 timestamp);

    // ===============================
    // Constants
    // ===============================
    
    function MIN_CONSTITUENTS() external view returns (uint256);
    function MAX_EMA_SMOOTHING() external view returns (uint256);
    function DEFAULT_EMA_SMOOTHING() external view returns (uint256);
    function MIN_DIVERSITY_INDEX() external view returns (uint256);
    function MAX_DIVERSITY_INDEX() external view returns (uint256);
    function VOLATILITY_THRESHOLD() external view returns (uint256);
    
    // ===============================
    // Roles
    // ===============================
    
    function NEURAL_INDEXER_ROLE() external view returns (bytes32);

    // ===============================
    // State Variables
    // ===============================
    
    function assetNeuralWeights(address asset) external view returns (NeuralWeight memory);
    function constituents(address asset) external view returns (ConstituentData memory);
    function constituentList(uint256 index) external view returns (address);
    function diversityIndex() external view returns (uint256);
    function geneticVolatility() external view returns (uint256);
    function rebalanceInterval() external view returns (uint256);
    function lastRebalanceTime() external view returns (uint256);
    function adaptiveVolatilityThreshold() external view returns (uint256);
    function rebalancingFrequencyTarget() external view returns (uint256);
    function lastAdaptiveLearningUpdate() external view returns (uint256);
    function selfOptimizationCounter() external view returns (uint256);

    // ===============================
    // Neural Weight Management
    // ===============================
    
    function updateNeuralWeight(
        address asset,
        uint256 newRawSignal,
        uint256 smoothingFactor
    ) external;
    
    function batchUpdateNeuralWeights(
        address[] calldata assets,
        uint256[] calldata signals,
        uint256[] calldata smoothingFactors
    ) external;

    // ===============================
    // Constituent Management
    // ===============================
    
    function addConstituent(address asset, uint256 initialWeight) external;
    function removeConstituent(address asset) external;
    function updateEvolutionScore(address asset, uint256 newScore) external;
    function getActiveConstituentsCount() external view returns (uint256 count);
    function getEvolutionScore(address asset) external view returns (uint256 score);

    // ===============================
    // Rebalancing Logic
    // ===============================
    
    function shouldAdaptiveRebalance() external view returns (bool, string memory);
    function triggerAdaptiveRebalance() external returns (string memory reason);
    function executeSelfOptimization() external;

    // ===============================
    // Batch & Data Retrieval
    // ===============================
    
    function getEcosystemHealthMetrics() external view returns (
        uint256 diversityIdx,
        uint256 geneticVol,
        uint256 activeConstituents,
        uint256 adaptiveThreshold,
        uint256 currentPrice,
        uint256 selfOptCounter
    );
    
    function batchGetNeuralWeights(address[] calldata assets) 
        external 
        view 
        returns (
            uint256[] memory weights,
            uint256[] memory signals,
            uint256[] memory updateTimes
        );
}
