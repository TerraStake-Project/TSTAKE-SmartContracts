// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";
import "../interfaces/ICrossChainHandler.sol";
import "../interfaces/ITerraStakeToken.sol";
import "../libraries/MessageVerifier.sol";
import "../libraries/ChainContext.sol";
import "../libraries/StateEncoding.sol";

/**
 * @title StateSync
 * @notice Ultimate cross-chain state synchronization engine with multi-chain governance
 * @dev Features gas-optimized storage, bulletproof validation, and chain-aware security
 */
contract StateSync is AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeCastUpgradeable for uint256;

    // ============ Constants ============
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant SYNC_ROLE = keccak256("SYNC_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    
    uint256 public constant MIN_HALVING_INTERVAL = 7 days;
    uint256 public constant MIN_STATE_UPDATE_INTERVAL = 1 hours;
    uint256 public constant MAX_TIMESTAMP_DRIFT = 15 minutes;
    uint256 public constant MAX_EPOCH_SKIP = 1;
    uint256 public constant STATE_UPDATE_COOLDOWN = 30 minutes;

    // ============ Immutables ============
    ICrossChainHandler public immutable crossChainHandler;
    ITerraStakeToken public immutable terraStakeToken;
    uint16 public immutable currentChainId;

    // ============ Storage ============
    struct ChainState {
        uint64 halvingEpoch;
        uint64 timestamp;
        uint128 totalSupply;
        uint128 lastTWAPPrice;
        uint64 lastUpdateBlock;
    }
    
    mapping(uint16 => ChainState) public chainState;
    uint64 public currentHalvingEpoch;
    uint64 public lastHalvingTime;
    uint64 public lastStateUpdate;
    bool public isGovernanceChain;
    uint16[] public supportedChains;

    // ============ Events ============
    event StateUpdated(
        uint16 indexed chainId,
        uint64 halvingEpoch,
        uint64 timestamp,
        uint128 totalSupply,
        uint128 lastTWAPPrice,
        address indexed updater
    );
    event HalvingEpochUpdated(
        uint64 oldEpoch,
        uint64 newEpoch,
        uint64 timestamp,
        address indexed updater
    );
    event GovernanceChainUpdated(bool oldStatus, bool newStatus);
    event EmergencyStateOverride(uint16 indexed chainId, address indexed executor);
    event ChainSupportUpdated(uint16 indexed chainId, bool isSupported);
    event StateUpdateReverted(uint16 indexed chainId, string reason);

    // ============ Errors ============
    error ZeroAddress();
    error InvalidChainId();
    error FutureTimestamp(uint256 provided, uint256 maxAllowed);
    error InvalidEpoch(uint256 provided, uint256 current);
    error EpochSkipped(uint256 current, uint256 provided);
    error InvalidSupply();
    error OutdatedState(uint256 provided, uint256 current);
    error IdenticalState();
    error TooFrequentUpdate(uint256 lastUpdate, uint256 minInterval);
    error NotGovernanceChain();
    error InvalidEmergencyOverride();
    error UnsupportedChain(uint16 chainId);
    error InvalidCaller();

    // ============ Modifiers ============
    modifier onlyGovernanceChain() {
        if (!isGovernanceChain) revert NotGovernanceChain();
        _;
    }

    modifier onlySupportedChain(uint16 chainId) {
        if (!_isChainSupported(chainId)) revert UnsupportedChain(chainId);
        _;
    }

    // ============ Constructor ============
    constructor(address _crossChainHandler, address _terraStakeToken) {
        if (_crossChainHandler == address(0) || _terraStakeToken == address(0)) revert ZeroAddress();
        crossChainHandler = ICrossChainHandler(_crossChainHandler);
        terraStakeToken = ITerraStakeToken(_terraStakeToken);
        currentChainId = ChainContext.getChainId();
        _disableInitializers();
    }

    // ============ Initialization ============
    function initialize(
        address _admin,
        bool _isGovernanceChain,
        uint16[] calldata _initialSupportedChains
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(SYNC_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
        _grantRole(ORACLE_ROLE, _admin);

        _setGovernanceChain(_isGovernanceChain);
        currentHalvingEpoch = 0;
        lastHalvingTime = uint64(block.timestamp);
        lastStateUpdate = uint64(block.timestamp);

        for (uint i = 0; i < _initialSupportedChains.length; i++) {
            _addSupportedChain(_initialSupportedChains[i]);
        }
    }

    // ============ State Management ============
    function syncState(
        uint16 srcChainId,
        ICrossChainHandler.CrossChainState calldata state
    ) external onlyRole(SYNC_ROLE) onlySupportedChain(srcChainId) nonReentrant {
        _validateStateUpdateFrequency();
        _validateState(state);

        ChainState storage current = chainState[srcChainId];
        
        if (state.timestamp <= current.timestamp) {
            revert OutdatedState(state.timestamp, current.timestamp);
        }
        if (state.halvingEpoch == current.halvingEpoch && state.timestamp == current.timestamp) {
            revert IdenticalState();
        }
        if (state.halvingEpoch > current.halvingEpoch + MAX_EPOCH_SKIP && !isGovernanceChain) {
            revert EpochSkipped(current.halvingEpoch, state.halvingEpoch);
        }

        _updateChainState(srcChainId, state);
        _updateGlobalStateIfNeeded(state.halvingEpoch);

        emit StateUpdated(
            srcChainId,
            state.halvingEpoch.toUint64(),
            state.timestamp.toUint64(),
            state.totalSupply.toUint128(),
            state.lastTWAPPrice.toUint128(),
            msg.sender
        );
    }

    // ============ Governance Functions ============
    function updateHalvingEpoch(uint64 newEpoch) 
        external 
        onlyRole(ADMIN_ROLE) 
        onlyGovernanceChain
        nonReentrant
    {
        if (newEpoch <= currentHalvingEpoch) revert InvalidEpoch(newEpoch, currentHalvingEpoch);
        if (block.timestamp < lastHalvingTime + MIN_HALVING_INTERVAL) {
            revert TooFrequentUpdate(lastHalvingTime, MIN_HALVING_INTERVAL);
        }

        _updateHalvingEpoch(newEpoch);
    }

    function setGovernanceChain(bool _isGovernanceChain) external onlyRole(ADMIN_ROLE) {
        _setGovernanceChain(_isGovernanceChain);
    }

    function addSupportedChain(uint16 chainId) external onlyRole(ADMIN_ROLE) {
        _addSupportedChain(chainId);
    }

    function removeSupportedChain(uint16 chainId) external onlyRole(ADMIN_ROLE) {
        _removeSupportedChain(chainId);
    }

    // ============ Emergency Functions ============
    function emergencyStateOverride(
        uint16 chainId,
        ICrossChainHandler.CrossChainState calldata state
    ) external onlyRole(EMERGENCY_ROLE) nonReentrant {
        if (state.halvingEpoch > currentHalvingEpoch + 5) revert InvalidEmergencyOverride();
        
        chainState[chainId] = ChainState({
            halvingEpoch: state.halvingEpoch.toUint64(),
            timestamp: state.timestamp.toUint64(),
            totalSupply: state.totalSupply.toUint128(),
            lastTWAPPrice: state.lastTWAPPrice.toUint128(),
            lastUpdateBlock: uint64(block.number)
        });

        emit EmergencyStateOverride(chainId, msg.sender);
        emit StateUpdated(
            chainId,
            state.halvingEpoch.toUint64(),
            state.timestamp.toUint64(),
            state.totalSupply.toUint128(),
            state.lastTWAPPrice.toUint128(),
            msg.sender
        );
    }

    // ============ View Functions ============
    function prepareStateUpdate() external view onlyRole(SYNC_ROLE) returns (bytes memory) {
        (uint128 totalSupply, uint128 lastTWAP) = terraStakeToken.getTokenState();
        if (totalSupply == 0) revert InvalidSupply();

        ICrossChainHandler.CrossChainState memory state = ICrossChainHandler.CrossChainState({
            halvingEpoch: currentHalvingEpoch,
            timestamp: uint64(block.timestamp),
            totalSupply: totalSupply,
            lastTWAPPrice: lastTWAP
        });

        return crossChainHandler.encodeStateUpdate(state);
    }

    function validateStateUpdate(
        uint16 srcChainId, 
        bytes calldata payload
    ) external view returns (bool, string memory) {
        try this._decodeAndValidate(srcChainId, payload) {
            return (true, "");
        } catch (bytes memory reason) {
            return (false, string(reason));
        }
    }

    function getSupportedChains() external view returns (uint16[] memory) {
        return supportedChains;
    }

    // ============ Internal Functions ============
    function _updateChainState(uint16 chainId, ICrossChainHandler.CrossChainState calldata state) internal {
        chainState[chainId] = ChainState({
            halvingEpoch: state.halvingEpoch.toUint64(),
            timestamp: state.timestamp.toUint64(),
            totalSupply: state.totalSupply.toUint128(),
            lastTWAPPrice: state.lastTWAPPrice.toUint128(),
            lastUpdateBlock: uint64(block.number)
        });
        lastStateUpdate = uint64(block.timestamp);
    }

    function _updateGlobalStateIfNeeded(uint256 newEpoch) internal {
        if (isGovernanceChain || newEpoch > currentHalvingEpoch) {
            _updateHalvingEpoch(newEpoch.toUint64());
        }
    }

    function _updateHalvingEpoch(uint64 newEpoch) internal {
        uint64 oldEpoch = currentHalvingEpoch;
        currentHalvingEpoch = newEpoch;
        lastHalvingTime = uint64(block.timestamp);
        emit HalvingEpochUpdated(oldEpoch, newEpoch, lastHalvingTime, msg.sender);
    }

    function _setGovernanceChain(bool _isGovernanceChain) internal {
        bool oldStatus = isGovernanceChain;
        isGovernanceChain = _isGovernanceChain;
        emit GovernanceChainUpdated(oldStatus, _isGovernanceChain);
    }

    function _addSupportedChain(uint16 chainId) internal {
        require(!_isChainSupported(chainId), "Chain already supported");
        supportedChains.push(chainId);
        emit ChainSupportUpdated(chainId, true);
    }

    function _removeSupportedChain(uint16 chainId) internal {
        require(_isChainSupported(chainId), "Chain not supported");
        for (uint i = 0; i < supportedChains.length; i++) {
            if (supportedChains[i] == chainId) {
                supportedChains[i] = supportedChains[supportedChains.length - 1];
                supportedChains.pop();
                emit ChainSupportUpdated(chainId, false);
                return;
            }
        }
    }

    function _isChainSupported(uint16 chainId) internal view returns (bool) {
        for (uint i = 0; i < supportedChains.length; i++) {
            if (supportedChains[i] == chainId) {
                return true;
            }
        }
        return false;
    }

    function _validateState(ICrossChainHandler.CrossChainState calldata state) internal view {
        if (state.timestamp > block.timestamp + MAX_TIMESTAMP_DRIFT) {
            revert FutureTimestamp(state.timestamp, block.timestamp + MAX_TIMESTAMP_DRIFT);
        }
        if (state.halvingEpoch == 0) revert InvalidEpoch(state.halvingEpoch, 0);
        if (state.totalSupply == 0) revert InvalidSupply();
    }

    function _validateStateUpdateFrequency() internal view {
        if (block.timestamp < lastStateUpdate + STATE_UPDATE_COOLDOWN) {
            revert TooFrequentUpdate(lastStateUpdate, STATE_UPDATE_COOLDOWN);
        }
    }

    function _decodeAndValidate(uint16 srcChainId, bytes calldata payload) 
        external 
        view 
        returns (bool) 
    {
        ICrossChainHandler.CrossChainState memory state = StateEncoding.decodeStateUpdate(payload);
        ChainState memory current = chainState[srcChainId];

        if (state.timestamp > block.timestamp + MAX_TIMESTAMP_DRIFT) {
            revert("Future timestamp");
        }
        if (state.timestamp <= current.timestamp) {
            revert("Outdated state");
        }
        if (state.halvingEpoch < current.halvingEpoch) {
            revert("Invalid epoch");
        }
        if (state.totalSupply == 0) {
            revert("Invalid supply");
        }

        return true;
    }

    // ============ Versioning ============
    function getVersion() external pure returns (string memory) {
        return "3.0.0";
    }

    // ============ Storage Gap ============
    uint256[45] private __gap;
}