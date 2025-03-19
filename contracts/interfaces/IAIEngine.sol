// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

interface IAIEngine {
    // ================================
    //  Chainlink Integration
    // ================================
    function fetchLatestPrice() external returns (uint256);
    function getLatestPrice() external view returns (uint256 price, bool isFresh);
    function updatePriceFeedAddress(address newPriceFeed) external;
    
    // ================================
    //  Constituent Management
    // ================================
    function addConstituent(address asset) external;
    function deactivateConstituent(address asset) external;
    function getActiveConstituents() external view returns (address[] memory activeAssets);
    
    // ================================
    //  Neural Weight Management
    // ================================
    function updateNeuralWeight(
        address asset,
        uint256 newRawSignal,
        uint256 smoothingFactor
    ) external;
    function batchUpdateNeuralWeights(
        address[] calldata assets,
        uint256[] calldata newRawSignals,
        uint256[] calldata smoothingFactors
    ) external;
    
    // ================================
    //  Diversity Index Management
    // ================================
    function recalculateDiversityIndex() external;
    
    // ================================
    //  Rebalancing Logic
    // ================================
    function shouldAdaptiveRebalance() external view returns (bool shouldRebalance, string memory reason);
    function triggerAdaptiveRebalance() external;
    function updateGeneticVolatility(uint256 newVolatility) external;
    
    // ================================
    //  Chainlink Keeper Methods
    // ================================
    function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory performData);
    function performUpkeep(bytes calldata performData) external;
    function manualKeeper() external;
    
    // ================================
    //  Configuration Management
    // ================================
    function setRebalanceInterval(uint256 newInterval) external;
    function setVolatilityThreshold(uint256 newThreshold) external;
    function setRequiredApprovals(uint256 newRequiredApprovals) external;
    
    // ================================
    //  Multi-signature Functionality
    // ================================
    function approveOperation(bytes32 operationId) external;
    function revokeApproval(bytes32 operationId) external;
    function getOperationId(string calldata action, bytes calldata data) external view returns (bytes32);
    
    // ================================
    //  Emergency & Safety Controls
    // ================================
    function pause() external;
    function unpause() external;
    function emergencyResetWeights() external;
}

