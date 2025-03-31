// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

/**
 * @title ICrossChainHandler
 * @notice Interface for cross-chain messaging with integrated anti-bot protection and halving sync
 * @dev Fully synced with CrossChainHandler v2.2.1 and TerraStakeToken halving logic
 */
interface ICrossChainHandler {
    // ============ Structs ============
    /**
     * @notice Struct to hold cross-chain state data, including halving information
     * @param halvingEpoch Current halving epoch (synced with TerraStakeToken's currentHalvingEpoch)
     * @param timestamp Timestamp of the last state update (synced with lastHalvingTime)
     * @param totalSupply Total token supply or staked amount
     * @param lastTWAPPrice Last TWAP price (token-specific, 0 for staking)
     * @param emissionRate Emission rate (token) or dynamic APR (staking)
     */
    struct CrossChainState {
        uint256 halvingEpoch;
        uint256 timestamp;
        uint256 totalSupply;
        uint256 lastTWAPPrice;
        uint256 emissionRate;
    }

    // ============ Events ============
    event MessageSent(uint16 indexed destChainId, bytes32 indexed payloadHash, uint256 nonce, uint256 fee);
    event MessageProcessed(uint16 indexed srcChainId, bytes32 indexed payloadHash, uint256 nonce);
    event MessageFailed(uint16 indexed srcChainId, bytes32 indexed payloadHash, bytes reason);
    event ChainConfigured(uint16 indexed chainId, address indexed processor, uint256 gasLimit);
    event StateSyncUpdated(address indexed newSyncContract);
    event AntiBotUpdated(address indexed newAntiBot);
    event TransactionThrottled(address indexed user, uint256 cooldownEnds);
    event CrossChainStateUpdated(uint16 indexed srcChainId, CrossChainState state);
    event TokenActionExecuted(uint16 indexed srcChainId, address indexed recipient, uint256 amount, bytes32 reference);
    event CrossChainSyncInitiated(uint16 indexed targetChainId, uint256 currentEpoch);

    // ============ Errors ============
    error ZeroAddress();
    error InvalidChain();
    error InvalidProcessor();
    error InvalidCaller();
    error StaleMessage();
    error InvalidPayload();
    error InsufficientFee();
    error TransactionThrottled();

    // ============ State Views ============
    /**
     * @notice Returns the LayerZero endpoint contract
     * @return ILayerZeroEndpoint interface
     */
    function lzEndpoint() external view returns (ILayerZeroEndpoint);

    /**
     * @notice Returns the local chain ID
     * @return Chain ID as uint16
     */
    function localChainId() external view returns (uint16);

    /**
     * @notice Returns the TerraStakeToken contract address
     * @return Address of the token contract
     */
    function tokenContract() external view returns (address);

    /**
     * @notice Returns the StateSync contract
     * @return StateSync interface
     */
    function stateSync() external view returns (StateSync);

    /**
     * @notice Returns the AntiBot contract
     * @return IAntiBot interface
     */
    function antiBot() external view returns (IAntiBot);

    /**
     * @notice Returns the default gas limit for cross-chain messages
     * @return Gas limit in wei
     */
    function defaultGasLimit() external view returns (uint256);

    /**
     * @notice Retrieves the state for a given chain
     * @param chainId Chain ID to query
     * @return CrossChainState struct with halving and state data
     */
    function getChainState(uint16 chainId) external view returns (CrossChainState memory);

    /**
     * @notice Checks if a message has been processed
     * @param messageId Hash of the message (srcChainId, srcAddress, nonce, payload)
     * @return True if processed, false otherwise
     */
    function isMessageProcessed(bytes32 messageId) external view returns (bool);

    /**
     * @notice Returns the contract version
     * @return Version string (e.g., "2.2.1")
     */
    function version() external pure returns (string memory);

    // ============ Configuration ============
    /**
     * @notice Initializes the contract with core dependencies
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
    ) external;

    /**
     * @notice Configures a destination chain for messaging
     * @param chainId Destination chain ID
     * @param processor Address of CrossChainHandler on the destination chain
     * @param gasLimit Gas limit for messages to this chain
     */
    function configureChain(
        uint16 chainId,
        address processor,
        uint256 gasLimit
    ) external;

    /**
     * @notice Updates the StateSync contract address
     * @param _stateSync New StateSync contract address
     */
    function setStateSync(address _stateSync) external;

    /**
     * @notice Updates the AntiBot contract address
     * @param _antiBot New AntiBot contract address
     */
    function setAntiBot(address _antiBot) external;

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
    ) external payable returns (bytes32 payloadHash, uint256 nonce);

    /**
     * @notice Estimates the fee for sending a cross-chain message
     * @param destChainId Destination chain ID
     * @param payload Message payload
     * @return nativeFee Native token fee
     * @return zroFee ZRO token fee (always 0 as disabled)
     */
    function estimateMessageFee(
        uint16 destChainId,
        bytes calldata payload
    ) external view returns (uint256 nativeFee, uint256 zroFee);

    /**
     * @notice Receives and processes a cross-chain message from LayerZero
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
    ) external;

    // ============ Token and State Sync Operations ============
    /**
     * @notice Executes a remote token action (e.g., minting) on the token contract
     * @param srcChainId Source chain ID
     * @param recipient Recipient address
     * @param amount Amount of tokens
     * @param reference Unique reference for the action
     */
    function executeRemoteTokenAction(
        uint16 srcChainId,
        address recipient,
        uint256 amount,
        bytes32 reference
    ) external;

    /**
     * @notice Updates the contract state from a cross-chain message
     * @param srcChainId Source chain ID
     * @param state CrossChainState containing halving and state data
     */
    function updateFromCrossChain(
        uint16 srcChainId,
        CrossChainState memory state
    ) external;

    // ============ Emergency Operations ============
    /**
     * @notice Pauses the contract in an emergency
     */
    function pause() external;

    /**
     * @notice Unpauses the contract
     */
    function unpause() external;
}

// Required interfaces for completeness
interface ILayerZeroEndpoint {
    function send(
        uint16 _dstChainId,
        bytes calldata _destination,
        bytes calldata _payload,
        address payable _refundAddress,
        address _zroPaymentAddress,
        bytes calldata _adapterParams
    ) external payable;

    function getOutboundNonce(uint16 _dstChainId, address _srcAddress) external view returns (uint64);
}

interface StateSync {
    function syncState(uint16 srcChainId, CrossChainState memory state) external;
}

interface IAntiBot {
    function checkThrottle(address user) external view returns (bool isThrottled, uint256 cooldownEnds);
}