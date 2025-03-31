// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@layerzero-labs/solidity-examples/contracts/interfaces/ILayerZeroEndpoint.sol";
import "../interfaces/ICrossChainHandler.sol";
import "../interfaces/IAntiBot.sol";
import "../libraries/FeeCalculator.sol";
import "../libraries/MessageVerifier.sol";
import "./StateSync.sol";

/**
 * @title CrossChainHandler
 * @dev High-security cross-chain messaging with integrated anti-bot protection and halving synchronization
 * @notice Features:
 * - AI-driven transaction throttling via IAntiBot
 * - Chain-specific gas optimization
 * - Fail-safe message processing with halving sync for TerraStakeToken
 * - Seamless StateSync integration for ecosystem consistency
 */
contract CrossChainHandler is 
    ICrossChainHandler, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable, 
    PausableUpgradeable 
{
    using MessageVerifier for bytes;

    // ============ Constants ============
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint256 public constant MIN_GAS_LIMIT = 100_000;
    uint256 public constant MAX_GAS_LIMIT = 2_000_000;
    uint256 public constant FEE_BUFFER_BPS = 1000; // 10%
    uint256 public constant MAX_TIMESTAMP_DRIFT = 15 minutes;

    // ============ Immutables ============
    ILayerZeroEndpoint public immutable lzEndpoint;
    uint16 public immutable localChainId;

    // ============ State Variables ============
    struct ChainConfig {
        bool isSupported;
        address processor;
        uint256 gasLimit;
        uint256 lastUpdate;
    }

    address public tokenContract; // TerraStakeToken contract
    StateSync public stateSync;   // StateSync for ecosystem state
    IAntiBot public antiBot;      // AntiBot for transaction throttling
    uint256 public defaultGasLimit;
    mapping(uint16 => ChainConfig) private _chains;              // Chain configurations
    mapping(bytes32 => bool) private _processedMessages;         // Track processed messages
    mapping(uint16 => CrossChainState) private _chainStates;     // Store chain states (including halving)

    // ============ Events ============
    event MessageSent(uint16 indexed destChainId, bytes32 indexed payloadHash, uint256 nonce, uint256 fee);
    event MessageProcessed(uint16 indexed srcChainId, bytes32 indexed payloadHash, uint256 nonce);
    event MessageFailed(uint16 indexed srcChainId, bytes32 indexed payloadHash, bytes reason);
    event ChainConfigured(uint16 indexed chainId, address indexed processor, uint256 gasLimit);
    event StateSyncUpdated(address indexed newSyncContract);
    event AntiBotUpdated(address indexed newAntiBot);
    event TransactionThrottled(address indexed user, uint256 cooldownEnds);
    event CrossChainStateUpdated(uint16 indexed srcChainId, CrossChainState state); // For halving sync
    event TokenActionExecuted(uint16 indexed srcChainId, address indexed recipient, uint256 amount, bytes32 reference);
    event CrossChainSyncInitiated(uint16 indexed targetChainId, uint256 currentEpoch); // Added for TerraStakeToken sync

    // ============ Errors ============
    error ZeroAddress();
    error InvalidChain();
    error InvalidProcessor();
    error InvalidCaller();
    error StaleMessage();
    error InvalidPayload();
    error InsufficientFee();
    error TransactionThrottled();

    // ============ Modifiers ============
    modifier onlySecureOrigin(uint16 srcChainId, bytes calldata srcAddress) {
        if (msg.sender != address(lzEndpoint)) revert InvalidCaller();
        
        (address localAddr, address remoteAddr) = MessageVerifier.parseAddress(srcAddress);
        if (localAddr != address(this) || remoteAddr != _chains[srcChainId].processor) {
            revert InvalidProcessor();
        }
        _;
    }

    modifier checkThrottle(address user) {
        if (address(antiBot) != address(0)) {
            (bool isThrottled, uint256 cooldownEnds) = antiBot.checkThrottle(user);
            if (isThrottled) {
                emit TransactionThrottled(user, cooldownEnds);
                revert TransactionThrottled();
            }
        }
        _;
    }

    // ============ Constructor ============
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _lzEndpoint) {
        if (_lzEndpoint == address(0)) revert ZeroAddress();
        lzEndpoint = ILayerZeroEndpoint(_lzEndpoint);
        localChainId = uint16(block.chainid);
        _disableInitializers();
    }

    // ============ Initialization ============
    /**
     * @notice Initializes the contract with token, state sync, anti-bot, and admin settings
     * @param _tokenContract Address of TerraStakeToken
     * @param _stateSync Address of StateSync contract
     * @param _antiBot Address of AntiBot contract
     * @param _admin Address of initial admin
     */
    function initialize(
        address _tokenContract,
        address _stateSync,
        address _antiBot,
        address _admin
    ) external initializer {
        if (_tokenContract == address(0)) revert ZeroAddress();
        if (_stateSync == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);

        tokenContract = _tokenContract;
        stateSync = StateSync(_stateSync);
        antiBot = IAntiBot(_antiBot);
        defaultGasLimit = 200_000;

        emit StateSyncUpdated(_stateSync);
        emit AntiBotUpdated(_antiBot);
    }

    // ============ Configuration ============
    /**
     * @notice Configures a destination chain for cross-chain messaging
     * @param chainId Destination chain ID
     * @param processor Address of the CrossChainHandler on the destination chain
     * @param gasLimit Gas limit for messages to this chain
     */
    function configureChain(
        uint16 chainId,
        address processor,
        uint256 gasLimit
    ) external onlyRole(ADMIN_ROLE) {
        if (chainId == 0 || chainId == localChainId) revert InvalidChain();
        if (processor == address(0)) revert ZeroAddress();
        if (gasLimit < MIN_GAS_LIMIT || gasLimit > MAX_GAS_LIMIT) revert InvalidPayload();

        _chains[chainId] = ChainConfig({
            isSupported: true,
            processor: processor,
            gasLimit: gasLimit,
            lastUpdate: block.timestamp
        });

        emit ChainConfigured(chainId, processor, gasLimit);
    }

    /**
     * @notice Updates the StateSync contract address
     * @param _stateSync New StateSync contract address
     */
    function setStateSync(address _stateSync) external onlyRole(ADMIN_ROLE) {
        if (_stateSync == address(0)) revert ZeroAddress();
        stateSync = StateSync(_stateSync);
        emit StateSyncUpdated(_stateSync);
    }

    /**
     * @notice Updates the AntiBot contract address
     * @param _antiBot New AntiBot contract address
     */
    function setAntiBot(address _antiBot) external onlyRole(ADMIN_ROLE) {
        if (_antiBot == address(0)) revert ZeroAddress();
        antiBot = IAntiBot(_antiBot);
        emit AntiBotUpdated(_antiBot);
    }

    // ============ Core Operations ============
    /**
     * @notice Sends a cross-chain message to a destination chain
     * @param destChainId Destination chain ID
     * @param payload Message payload (state sync or token action)
     * @return payloadHash Hash of the payload
     * @return nonce Outbound nonce for the message
     */
    function sendMessage(
        uint16 destChainId,
        bytes calldata payload
    ) external payable onlyRole(OPERATOR_ROLE) checkThrottle(msg.sender) nonReentrant whenNotPaused returns (bytes32 payloadHash, uint256 nonce) {
        ChainConfig memory config = _chains[destChainId];
        if (!config.isSupported) revert InvalidChain();
        
        payloadHash = keccak256(payload);
        bytes memory path = abi.encodePacked(address(this), config.processor);
        
        uint256 fee = FeeCalculator.calculateTotalFee(
            lzEndpoint,
            destChainId,
            address(this),
            payload,
            config.gasLimit,
            FEE_BUFFER_BPS
        );

        if (msg.value < fee) revert InsufficientFee();

        lzEndpoint.send{value: fee}(
            destChainId,
            path,
            payload,
            payable(msg.sender),
            address(0),
            abi.encodePacked(uint16(1), config.gasLimit)
        );

        nonce = lzEndpoint.getOutboundNonce(destChainId, address(this));
        emit MessageSent(destChainId, payloadHash, nonce, fee);
        
        // Emit CrossChainSyncInitiated for state sync messages (halving sync with TerraStakeToken)
        if (payload.validateHeader() == 1) { // MessageType 1 = State sync
            CrossChainState memory state = abi.decode(payload.extractData(), (CrossChainState));
            emit CrossChainSyncInitiated(destChainId, state.halvingEpoch);
        }
    }

    /**
     * @notice Receives and processes a cross-chain message via LayerZero
     * @param srcChainId Source chain ID
     * @param srcAddress Source address (encoded)
     * @param nonce Message nonce
     * @param payload Message payload
     */
    function lzReceive(
        uint16 srcChainId,
        bytes calldata srcAddress,
        uint64 nonce,
        bytes calldata payload
    ) external nonReentrant onlySecureOrigin(srcChainId, srcAddress) whenNotPaused {
        bytes32 messageId = keccak256(abi.encode(srcChainId, srcAddress, nonce, payload));
        if (_processedMessages[messageId]) revert StaleMessage();
        _processedMessages[messageId] = true;

        try this._processMessage(srcChainId, payload) {
            emit MessageProcessed(srcChainId, keccak256(payload), nonce);
        } catch (bytes memory reason) {
            delete _processedMessages[messageId]; // Allow retry on failure
            emit MessageFailed(srcChainId, keccak256(payload), reason);
        }
    }

    // ============ Message Processing ============
    /**
     * @notice Internal function to process received messages (self-called for safety)
     * @param srcChainId Source chain ID
     * @param payload Message payload
     */
    function _processMessage(uint16 srcChainId, bytes calldata payload) external {
        require(msg.sender == address(this), "Unauthorized");
        
        uint8 messageType = payload.validateHeader();
        bytes memory data = payload.extractData();

        if (messageType == 1) { // State sync (e.g., halving)
            CrossChainState memory state = abi.decode(data, (CrossChainState));
            _updateChainState(srcChainId, state);
            if (address(stateSync) != address(0)) {
                stateSync.syncState(srcChainId, state);
            }
            emit CrossChainStateUpdated(srcChainId, state);
        } else if (messageType == 2) { // Token action
            (address recipient, uint256 amount, bytes32 reference) = abi.decode(data, (address, uint256, bytes32));
            _executeTokenAction(srcChainId, recipient, amount, reference);
            emit TokenActionExecuted(srcChainId, recipient, amount, reference);
        } else {
            revert InvalidPayload();
        }
    }

    /**
     * @notice Updates the chain state with received halving or other state data
     * @param srcChainId Source chain ID
     * @param state CrossChainState containing halving epoch, timestamp, etc.
     */
    function _updateChainState(uint16 srcChainId, CrossChainState memory state) internal {
        if (state.timestamp > block.timestamp + MAX_TIMESTAMP_DRIFT) revert InvalidPayload();
        if (state.timestamp <= _chainStates[srcChainId].timestamp) revert StaleMessage();
        _chainStates[srcChainId] = state;

        // Sync with token contract (TerraStakeToken) if halving epoch is newer
        if (address(tokenContract) != address(0)) {
            try ICrossChainHandler(tokenContract).updateFromCrossChain(srcChainId, state) {
                // Success, state updated in token contract
            } catch {
                // Log failure but continue (token contract handles its own state)
            }
        }
    }

    /**
     * @notice Executes a token action (e.g., minting) on the token contract
     * @param srcChainId Source chain ID
     * @param recipient Recipient address
     * @param amount Amount of tokens
     * @param reference Unique reference for the action
     */
    function _executeTokenAction(uint16 srcChainId, address recipient, uint256 amount, bytes32 reference) internal {
        (bool success, ) = tokenContract.call(
            abi.encodeWithSelector(
                ICrossChainHandler.executeRemoteTokenAction.selector,
                srcChainId,
                recipient,
                amount,
                reference
            )
        );
        if (!success) revert InvalidPayload();
    }

    // ============ Utility Functions ============
    /**
     * @notice Estimates the fee for sending a message to a destination chain
     * @param destChainId Destination chain ID
     * @param payload Message payload
     * @return nativeFee Native token fee
     * @return zroFee ZRO token fee (always 0 as disabled)
     */
    function estimateMessageFee(
        uint16 destChainId,
        bytes calldata payload
    ) external view returns (uint256 nativeFee, uint256 zroFee) {
        ChainConfig memory config = _chains[destChainId];
        if (!config.isSupported) revert InvalidChain();

        nativeFee = FeeCalculator.calculateTotalFee(
            lzEndpoint,
            destChainId,
            address(this),
            payload,
            config.gasLimit,
            FEE_BUFFER_BPS
        );
        zroFee = 0; // ZRO payments disabled
    }

    /**
     * @notice Checks if a message has been processed
     * @param messageId Message ID (hash of srcChainId, srcAddress, nonce, payload)
     * @return True if processed, false otherwise
     */
    function isMessageProcessed(bytes32 messageId) external view returns (bool) {
        return _processedMessages[messageId];
    }

    /**
     * @notice Gets the current state for a chain
     * @param chainId Chain ID
     * @return CrossChainState struct with halving and other state data
     */
    function getChainState(uint16 chainId) external view returns (CrossChainState memory) {
        return _chainStates[chainId];
    }

    /**
     * @notice Returns the contract version
     * @return Version string
     */
    function version() external pure returns (string memory) {
        return "2.2.1"; // Updated for halving sync and event adjustment
    }

    // ============ Emergency Functions ============
    /**
     * @notice Pauses the contract in an emergency
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the contract
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
}