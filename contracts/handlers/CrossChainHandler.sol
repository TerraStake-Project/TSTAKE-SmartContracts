// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

// Replace LayerZero with Chainlink CCIP imports
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.0/token/ERC20/IERC20.sol";

import "../interfaces/ICrossChainHandler.sol";
import "../interfaces/IAntiBot.sol";
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
    PausableUpgradeable,
    Client.EVMTokenReceiver // Implement CCIP receiver interface
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
    IRouterClient public immutable ccipRouter; // CCIP Router instead of LayerZero endpoint
    uint64 public immutable localChainId; // Chain selector ID format for CCIP

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
    mapping(uint64 => ChainConfig) private _chains;              // Chain configurations (uint64 for CCIP)
    mapping(bytes32 => bool) private _processedMessages;         // Track processed messages
    mapping(uint64 => CrossChainState) private _chainStates;     // Store chain states (including halving)
    mapping(address => bool) private _allowedSenders;            // Authorized source contracts on other chains

    // ============ Events ============
    event MessageSent(uint64 indexed destChainId, bytes32 indexed payloadHash, uint64 messageId, uint256 fee);
    event MessageProcessed(uint64 indexed srcChainId, bytes32 indexed payloadHash, bytes32 messageId);
    event MessageFailed(uint64 indexed srcChainId, bytes32 indexed payloadHash, bytes reason);
    event ChainConfigured(uint64 indexed chainId, address indexed processor, uint256 gasLimit);
    event StateSyncUpdated(address indexed newSyncContract);
    event AntiBotUpdated(address indexed newAntiBot);
    event TransactionThrottled(address indexed user, uint256 cooldownEnds);
    event CrossChainStateUpdated(uint64 indexed srcChainId, CrossChainState state); // For halving sync
    event TokenActionExecuted(uint64 indexed srcChainId, address indexed recipient, uint256 amount, bytes32 reference);
    event CrossChainSyncInitiated(uint64 indexed targetChainId, uint256 currentEpoch); // Added for TerraStakeToken sync
    event MessageSenderAuthorized(address indexed sender, bool status);

    // ============ Errors ============
    error ZeroAddress();
    error InvalidChain();
    error InvalidProcessor();
    error InvalidCaller();
    error StaleMessage();
    error InvalidPayload();
    error InsufficientFee();
    error TransactionThrottled();
    error UnauthorizedSender(address sender);

    // ============ Modifiers ============
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
    constructor(address _ccipRouter) {
        if (_ccipRouter == address(0)) revert ZeroAddress();
        ccipRouter = IRouterClient(_ccipRouter);
        localChainId = uint64(block.chainid); // Convert to uint64 for CCIP compatibility
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
     * @param chainId Destination chain ID (CCIP chain selector)
     * @param processor Address of the CrossChainHandler on the destination chain
     * @param gasLimit Gas limit for messages to this chain
     */
    function configureChain(
        uint64 chainId,
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
     * @notice Authorize or deauthorize a sender from a source chain
     * @param sender Address of the sender to authorize/deauthorize
     * @param authorized Whether to authorize or deauthorize the sender
     */
    function setAuthorizedSender(address sender, bool authorized) external onlyRole(ADMIN_ROLE) {
        if (sender == address(0)) revert ZeroAddress();
        _allowedSenders[sender] = authorized;
        emit MessageSenderAuthorized(sender, authorized);
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
     * @param destChainId Destination chain ID (CCIP chain selector)
     * @param payload Message payload (state sync or token action)
     * @return payloadHash Hash of the payload
     * @return messageId CCIP message ID
     */
    function sendMessage(
        uint16 destChainId, // Keep same parameter type for compatibility
        bytes calldata payload
    ) external payable onlyRole(OPERATOR_ROLE) checkThrottle(msg.sender) nonReentrant whenNotPaused returns (bytes32 payloadHash, uint256 messageId) {
        uint64 ccipDestChainId = uint64(destChainId); // Convert to uint64 for CCIP
        ChainConfig memory config = _chains[ccipDestChainId];
        if (!config.isSupported) revert InvalidChain();
        
        payloadHash = keccak256(payload);
        
        // Prepare CCIP message format
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(config.processor),
            data: payload,
            tokenAmounts: new Client.EVMTokenAmount[](0), // No token transfers
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({
                    gasLimit: config.gasLimit,
                    strict: false
                })
            ),
            feeToken: address(0) // Use native for fees
        });
        
        // Get fee
        uint256 fee = ccipRouter.getFee(ccipDestChainId, message);
        if (msg.value < fee) revert InsufficientFee();
        
        // Send CCIP message
        uint64 ccipMessageId = ccipRouter.ccipSend{value: fee}(ccipDestChainId, message);
        
        emit MessageSent(ccipDestChainId, payloadHash, ccipMessageId, fee);
        
        // Emit CrossChainSyncInitiated for state sync messages (halving sync with TerraStakeToken)
        if (payload.validateHeader() == 1) { // MessageType 1 = State sync
            CrossChainState memory state = abi.decode(payload.extractData(), (CrossChainState));
            emit CrossChainSyncInitiated(ccipDestChainId, state.halvingEpoch);
        }
        
        return (payloadHash, ccipMessageId);
    }

    /**
     * @notice Receives and processes a cross-chain message via Chainlink CCIP
     * @param message CCIP message containing source chain, sender and payload
     */
    function ccipReceive(
        Client.Any2EVMMessage memory message
    ) external override nonReentrant whenNotPaused {
        // Verify this came from CCIP Router
        if (msg.sender != address(ccipRouter)) revert InvalidCaller();
        
        // Extract the sender address
        address sender = abi.decode(message.sender, (address));
        if (!_allowedSenders[sender]) revert UnauthorizedSender(sender);
        
        // Create unique message ID
        bytes32 messageId = keccak256(abi.encode(message.sourceChainSelector, message.sender, message.messageId));
        if (_processedMessages[messageId]) revert StaleMessage();
        _processedMessages[messageId] = true;
        
        try this._processMessage(message.sourceChainSelector, message.data) {
            emit MessageProcessed(message.sourceChainSelector, keccak256(message.data), messageId);
        } catch (bytes memory reason) {
            delete _processedMessages[messageId]; // Allow retry on failure
            emit MessageFailed(message.sourceChainSelector, keccak256(message.data), reason);
        }
    }

    // ============ Message Processing ============
    /**
     * @notice Internal function to process received messages (self-called for safety)
     * @param srcChainId Source chain ID
     * @param payload Message payload
     */
    function _processMessage(uint64 srcChainId, bytes calldata payload) external {
        require(msg.sender == address(this), "Unauthorized");
        
        uint8 messageType = payload.validateHeader();
        bytes memory data = payload.extractData();
        if (messageType == 1) { // State sync (e.g., halving)
            CrossChainState memory state = abi.decode(data, (CrossChainState));
            _updateChainState(srcChainId, state);
            if (address(stateSync) != address(0)) {
                stateSync.syncState(uint16(srcChainId), state); // Convert back to uint16 for compatibility
            }
            emit CrossChainStateUpdated(srcChainId, state);
        } else if (messageType == 2) { // Token action
            (address recipient, uint256 amount, bytes32 reference) = abi.decode(data, (address, uint256, bytes32));
            _executeTokenAction(uint16(srcChainId), recipient, amount, reference); // Convert to uint16 for compatibility
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
    function _updateChainState(uint64 srcChainId, CrossChainState memory state) internal {
        if (state.timestamp > block.timestamp + MAX_TIMESTAMP_DRIFT) revert InvalidPayload();
        if (state.timestamp <= _chainStates[srcChainId].timestamp) revert StaleMessage();
        _chainStates[srcChainId] = state;
        // Sync with token contract (TerraStakeToken) if halving epoch is newer
        if (address(tokenContract) != address(0)) {
            try ICrossChainHandler(tokenContract).updateFromCrossChain(uint16(srcChainId), state) {
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
     * @param destChainId Destination chain ID (CCIP chain selector)
     * @param payload Message payload
     * @return nativeFee Native token fee
     */
    function estimateMessageFee(
        uint16 destChainId, // Keep same parameter type for compatibility
        bytes calldata payload
    ) external view returns (uint256 nativeFee, uint256) {
        uint64 ccipDestChainId = uint64(destChainId); // Convert to uint64 for CCIP
        ChainConfig memory config = _chains[ccipDestChainId];
        if (!config.isSupported) revert InvalidChain();
        
        // Prepare CCIP message format for fee estimation
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(config.processor),
            data: payload,
            tokenAmounts: new Client.EVMTokenAmount[](0), // No token transfers
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({
                    gasLimit: config.gasLimit,
                    strict: false
                })
            ),
            feeToken: address(0) // Use native for fees
        });
        
        // Get CCIP fee
        nativeFee = ccipRouter.getFee(ccipDestChainId, message);
        
        // Return second value as 0 for compatibility with old interface
        // (LayerZero returned zroFee as second parameter)
        return (nativeFee, 0);
    }

    /**
     * @notice Checks if a message has been processed
     * @param messageId Message ID
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
        return _chainStates[uint64(chainId)]; // Convert to uint64 for CCIP compatibility
    }

    /**
     * @notice Checks if a sender is authorized
     * @param sender Address to check
     * @return True if authorized, false otherwise
     */
    function isAuthorizedSender(address sender) external view returns (bool) {
        return _allowedSenders[sender];
    }

    /**
     * @notice Returns the chain configuration for a specific chain
     * @param chainId Chain ID (CCIP chain selector)
     * @return Config struct with processor address and gas limit
     */
    function getChainConfig(uint64 chainId) external view returns (
        bool isSupported,
        address processor,
        uint256 gasLimit,
        uint256 lastUpdate
    ) {
        ChainConfig memory config = _chains[chainId];
        return (
            config.isSupported,
            config.processor,
            config.gasLimit,
            config.lastUpdate
        );
    }

    /**
     * @notice Returns the contract version
     * @return Version string
     */
    function version() external pure returns (string memory) {
        return "3.0.0"; // Updated for CCIP integration
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

    /**
     * @notice Allows the contract to receive native tokens (required for CCIP fees)
     */
    receive() external payable {}
}           