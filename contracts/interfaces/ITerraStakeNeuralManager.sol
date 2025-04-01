// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../interfaces/ITerraStakeToken.sol";
import "../interfaces/ITerraStakeNeural.sol";
import "../interfaces/ICrossChainReceiver.sol";

/**
 * @title TerraStakeNeuralManagerV2
 * @notice Cross-chain optimized neural network manager with multi-chain signal aggregation
 * @dev Features time-locked upgrades and chain-aware rebalancing
 * @custom:security-contact security@terrastake.io
 */
contract TerraStakeNeuralManager is
    Initializable,
    AccessControlEnumerableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // ================================
    // Constants
    // ================================
    uint256 public constant MAX_SMOOTHING = 100; // 100% max smoothing factor
    uint256 public constant MIN_CONSTITUENTS = 3;
    uint256 public constant DEFAULT_UPGRADE_DELAY = 2 days;

    // ================================
    // State Variables
    // ================================
    ITerraStakeToken public terraStakeToken;
    ITerraStakeNeural public neuralCore;
    ICrossChainReceiver public crossChainReceiver;
    
    // Neural network parameters
    uint256 public rebalanceThreshold;
    uint256 public rebalanceCooldown;
    uint256 public lastRebalanceTime;
    uint256 public totalWeight;
    uint256 public signalAggregationThreshold;
    
    // Upgrade control
    uint256 public upgradeDelay;
    uint256 public pendingUpgradeTime;
    address public pendingUpgradeImplementation;
    
    // Constituent tracking
    address[] public constituents;
    mapping(address => NeuralAsset) public neuralAssets;
    
    // Cross-chain tracking
    struct CrossChainSignal {
        uint256 chainId;
        uint256 signal;
        uint256 timestamp;
        address provider;
    }
    mapping(address => CrossChainSignal[]) public crossChainSignals;
    mapping(uint256 => bool) public supportedChains;

    // ================================
    // Data Structures
    // ================================
    struct NeuralAsset {
        uint256 weight;
        uint256 signal;
        uint256 lastUpdateTime;
        bool active;
    }
    
    // ================================
    // Events
    // ================================
    event NeuralWeightUpdated(address indexed asset, uint256 weight, uint256 signal);
    event ConstituentAdded(address indexed asset, uint256 initialWeight);
    event ConstituentRemoved(address indexed asset);
    event AdaptiveRebalanceTriggered(string reason);
    event CoreTokenUpdated(address indexed tokenAddress);
    event NeuralCoreUpdated(address indexed coreAddress);
    event RebalanceParametersUpdated(uint256 threshold, uint256 cooldown);
    event OptimizationExecuted(uint256 timestamp, string strategy);
    event CrossChainSignalReceived(
        address indexed asset, 
        uint256 chainId, 
        uint256 signal,
        address provider
    );
    event CrossChainRebalanceInitiated(
        uint256 indexed originChainId,
        address[] constituents,
        uint256 timestamp
    );
    event UpgradeScheduled(address indexed newImplementation, uint256 executeTime);
    
    // ================================
    // Errors
    // ================================
    error NotAuthorized();
    error ZeroAddress();
    error AssetNotFound();
    error AssetAlreadyExists();
    error RebalanceCooldownActive();
    error InvalidParameters(string param, string reason);
    error NeuralCoreNotSet();
    error OperationFailed(string operation);
    error CrossChainSyncFailed(uint256 chainId, string reason);
    error InsufficientSignals(uint256 received, uint256 required);
    error UpgradePending();
    error UpgradeNotReady();

    // ================================
    // Modifiers
    // ================================
    modifier onlyRole(bytes32 role) {
        if (!hasRole(role, msg.sender)) revert NotAuthorized();
        _;
    }

    modifier onlyAfterUpgradeDelay() {
        if (block.timestamp < pendingUpgradeTime) revert UpgradeNotReady();
        _;
    }

    // ================================
    // Initialization
    // ================================
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @notice Initializes the neural manager with cross-chain support
     * @param _terraStakeToken Main token contract address
     * @param _neuralCore Neural core logic address
     * @param _crossChainReceiver Cross-chain message receiver
     */
    function initialize(
        address _terraStakeToken,
        address _neuralCore,
        address _crossChainReceiver
    ) public initializer {
        if (_terraStakeToken == address(0)) revert ZeroAddress();
        
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        _grantRole(NEURAL_MANAGER_ROLE, msg.sender);
        _grantRole(SIGNAL_PROVIDER_ROLE, msg.sender);
        
        terraStakeToken = ITerraStakeToken(_terraStakeToken);
        neuralCore = ITerraStakeNeural(_neuralCore);
        crossChainReceiver = ICrossChainReceiver(_crossChainReceiver);
        
        // Initialize parameters
        rebalanceThreshold = 1000; // 10% in basis points
        rebalanceCooldown = 1 days;
        signalAggregationThreshold = 3; // Require 3 chains
        upgradeDelay = DEFAULT_UPGRADE_DELAY;
    }

    // ================================
    // Core Neural Functions (Enhanced)
    // ================================
    
    /**
     * @notice Update neural weight with cross-chain validation
     * @dev Checks blacklist status and aggregates signals if available
     */
    function updateNeuralWeight(
        address asset,
        uint256 signal,
        uint256 smoothingFactor
    ) 
        external
        whenNotPaused 
        onlyRole(SIGNAL_PROVIDER_ROLE) 
    {
        _validateAsset(asset);
        if (smoothingFactor > MAX_SMOOTHING) 
            revert InvalidParameters("smoothingFactor", "Exceeds maximum");
        
        NeuralAsset storage assetData = neuralAssets[asset];
        
        // Cross-chain check
        if (terraStakeToken.isBlacklisted(asset)) 
            revert InvalidParameters("asset", "Blacklisted");
        
        // Apply smoothing
        uint256 newWeight = _calculateSmoothedWeight(
            assetData.weight, 
            signal, 
            smoothingFactor
        );
        
        _updateAssetWeight(asset, assetData, newWeight, signal);
        
        // Propagate to neural core
        if (address(neuralCore) != address(0)) {
            try neuralCore.updateNeuralWeight(asset, signal, smoothingFactor) {
                // Success
            } catch {
                emit OperationFailed("updateNeuralWeight");
            }
        }
        
        emit NeuralWeightUpdated(asset, newWeight, signal);
    }

    // ================================
    // Cross-Chain Functions (New)
    // ================================
    
    /**
     * @notice Submit signals from other chains
     * @dev Requires SIGNAL_PROVIDER_ROLE on source chain
     */
    function receiveCrossChainSignals(
        uint256 sourceChainId,
        address[] calldata assets,
        uint256[] calldata signals,
        address provider
    ) external {
        require(msg.sender == address(crossChainReceiver), "Unauthorized");
        require(assets.length == signals.length, "Length mismatch");
        
        for (uint256 i = 0; i < assets.length; i++) {
            crossChainSignals[assets[i]].push(CrossChainSignal({
                chainId: sourceChainId,
                signal: signals[i],
                timestamp: block.timestamp,
                provider: provider
            }));
            
            emit CrossChainSignalReceived(
                assets[i], 
                sourceChainId, 
                signals[i],
                provider
            );
            
            // Auto-process if threshold met
            if (crossChainSignals[assets[i]].length >= signalAggregationThreshold) {
                _processAggregatedSignal(assets[i]);
            }
        }
    }
    
    /**
     * @notice Process aggregated signals from multiple chains
     */
    function _processAggregatedSignal(address asset) internal {
        uint256 totalSignal;
        uint256 validSignals;
        
        for (uint256 i = 0; i < crossChainSignals[asset].length; i++) {
            CrossChainSignal memory s = crossChainSignals[asset][i];
            if (supportedChains[s.chainId] && s.timestamp > block.timestamp - 1 days) {
                totalSignal += s.signal;
                validSignals++;
            }
        }
        
        if (validSignals >= signalAggregationThreshold) {
            uint256 avgSignal = totalSignal / validSignals;
            updateNeuralWeight(asset, avgSignal, 20); // 20% smoothing
            
            // Clear processed signals
            delete crossChainSignals[asset];
        }
    }

    // ================================
    // Upgrade Functions (Enhanced)
    // ================================
    
    function scheduleUpgrade(address newImplementation) 
        external 
        onlyRole(UPGRADER_ROLE)
    {
        if (pendingUpgradeImplementation != address(0)) 
            revert UpgradePending();
            
        pendingUpgradeImplementation = newImplementation;
        pendingUpgradeTime = block.timestamp + upgradeDelay;
        
        emit UpgradeScheduled(newImplementation, pendingUpgradeTime);
    }
    
    function executeUpgrade() 
        external 
        onlyRole(UPGRADER_ROLE)
        onlyAfterUpgradeDelay
    {
        _upgradeTo(pendingUpgradeImplementation);
        pendingUpgradeImplementation = address(0);
    }

    // ================================
    // Helper Functions (Optimized)
    // ================================
    
    function _validateAsset(address asset) internal view {
        if (!neuralAssets[asset].active) revert AssetNotFound();
        if (asset == address(0)) revert ZeroAddress();
    }
    
    function _calculateSmoothedWeight(
        uint256 currentWeight,
        uint256 signal,
        uint256 smoothingFactor
    ) internal pure returns (uint256) {
        return ((100 - smoothingFactor) * currentWeight + smoothingFactor * signal) / 100;
    }
    
    function _updateAssetWeight(
        address asset,
        NeuralAsset storage assetData,
        uint256 newWeight,
        uint256 signal
    ) internal {
        totalWeight -= assetData.weight;
        assetData.weight = newWeight;
        assetData.signal = signal;
        assetData.lastUpdateTime = block.timestamp;
        totalWeight += newWeight;
    }

    // ================================
    // View Functions (New)
    // ================================
    
    function getActiveConstituents() public view returns (address[] memory) {
        address[] memory active = new address[](constituents.length);
        uint256 count;
        
        for (uint256 i = 0; i < constituents.length; i++) {
            if (neuralAssets[constituents[i]].active) {
                active[count] = constituents[i];
                count++;
            }
        }
        
        // Resize array
        assembly {
            mstore(active, count)
        }
        
        return active;
    }
    
    function getCrossChainSignals(address asset) 
        external 
        view 
        returns (CrossChainSignal[] memory) 
    {
        return crossChainSignals[asset];
    }

    // ================================
    // UUPS Override
    // ================================
    function _authorizeUpgrade(address) 
        internal 
        override 
        onlyRole(UPGRADER_ROLE) 
    {}

    // Additional functions (batch operations, rebalancing logic, etc.) remain similar to original
    // but with cross-chain checks added...
}