// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import {Client} from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";

/**
 * @title ICrossChainHandler
 * @notice Interface for cross-chain messaging with integrated anti-bot protection and halving sync
 * @dev Updated for Chainlink CCIP integration (v3.0.0)
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
    event MessageSent(uint64 indexed destChainId, bytes32 indexed payloadHash, uint64 messageId, uint256 fee);
    event MessageProcessed(uint64 indexed srcChainId, bytes32 indexed payloadHash, bytes32 messageId);
    event MessageFailed(uint64 indexed srcChainId, bytes32 indexed payloadHash, bytes reason);
    event ChainConfigured(uint64 indexed chainId, address indexed processor, uint256 gasLimit);
    event StateSyncUpdated(address indexed newSyncContract);
    event AntiBotUpdated(address indexed newAntiBot);
    event TransactionThrottled(address indexed user, uint256 cooldownEnds);
    event CrossChainStateUpdated(uint64 indexed srcChainId, CrossChainState state);
    event TokenActionExecuted(uint64 indexed srcChainId, address indexed recipient, uint256 amount, bytes32 referenceId);
    event CrossChainSyncInitiated(uint64 indexed targetChainId, uint256 currentEpoch);
    event MessageSenderAuthorized(address indexed sender, bool status);

    // ============ Errors ============
    error ZeroAddress();
    error InvalidChain();
    error InvalidProcessor();
    error InvalidCaller();
    error StaleMessage();
    error InvalidPayload();
    error InsufficientFee();
    error UserThrottled();
    error UnauthorizedSender(address sender);

    // ============ State Views ============
    /**
     * @notice Returns the CCIP Router contract
     * @return IRouterClient interface
     */
    function ccipRouter() external view returns (address);

    /**
     * @notice Returns the local chain ID
     * @return Chain ID as uint64
     */
    function localChainId() external view returns (uint64);

    /**
     * @notice Returns the TerraStakeToken contract address
     * @return Address of the token contract
     */
    function tokenContract() external view returns (address);

    /**
     * @notice Returns the StateSync contract
     * @return StateSync interface
     */
    function stateSync() external view returns (address);

    /**
     * @notice Returns the AntiBot contract
     * @return IAntiBot interface
     */
    function antiBot() external view returns (address);

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
     * @param messageId Hash of the message
     * @return True if processed, false otherwise
     */
    function isMessageProcessed(bytes32 messageId) external view returns (bool);

    /**
     * @notice Returns the contract version
     * @return Version string (e.g., "3.0.0")
     */
    function version() external pure returns (string memory);

    /**
     * @notice Checks if a sender is authorized
     * @param sender Address to check
     * @return True if authorized, false otherwise
     */
    function isAuthorizedSender(address sender) external view returns (bool);

     /**
 * @notice Returns chain configuration
 * @param chainId Chain ID (CCIP chain selector)
 * @return isSupported Whether the chain is supported
 * @return processor Address of the message processor on the destination chain
 * @return gasLimit Gas limit for cross-chain messages
 * @return lastUpdate Timestamp of the last configuration update
 */
    function getChainConfig(uint64 chainId) external view returns (
    bool isSupported,
    address processor,
    uint256 gasLimit,
    uint256 lastUpdate
   );


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
     * @param chainId Destination chain ID (CCIP chain selector)
     * @param processor Address of CrossChainHandler on the destination chain
     * @param gasLimit Gas limit for messages to this chain
     */
    function configureChain(
        uint64 chainId,
        address processor,
        uint256 gasLimit
    ) external;

    /**
     * @notice Authorize or deauthorize a sender from a source chain
     * @param sender Address of the sender to authorize/deauthorize
     * @param authorized Whether to authorize or deauthorize the sender
     */
    function setAuthorizedSender(address sender, bool authorized) external;

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
     * @param destChainId Destination chain ID (for backward compatibility, gets converted to uint64)
     * @param payload Message payload (state sync or token action)
     * @return payloadHash Hash of the payload
     * @return messageId CCIP message ID
     */
    function sendMessage(
        uint16 destChainId,
        bytes calldata payload
    ) external payable returns (bytes32 payloadHash, uint256 messageId);

    /**
     * @notice Estimates the fee for sending a cross-chain message
     * @param destChainId Destination chain ID (for backward compatibility, gets converted to uint64)
     * @param payload Message payload
     * @return nativeFee Native token fee
     * @return _ Second return value for compatibility (always 0)
     */
    function estimateMessageFee(
        uint16 destChainId,
        bytes calldata payload
    ) external view returns (uint256 nativeFee, uint256);

    /**
     * @notice Receives and processes a cross-chain message via Chainlink CCIP
     * @param message CCIP message containing source chain, sender and payload
     */
    function ccipReceive(
        Client.Any2EVMMessage memory message
    ) external;

    // ============ Token and State Sync Operations ============
    /**
     * @notice Executes a remote token action (e.g., minting) on the token contract
     * @param srcChainId Source chain ID
     * @param recipient Recipient address
     * @param amount Amount of tokens
     * @param referenceId Unique reference for the action
     */
    function executeRemoteTokenAction(
        uint16 srcChainId,
        address recipient,
        uint256 amount,
        bytes32 referenceId
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
interface StateSync {
    function syncState(uint16 srcChainId, ICrossChainHandler.CrossChainState memory state) external;
}
