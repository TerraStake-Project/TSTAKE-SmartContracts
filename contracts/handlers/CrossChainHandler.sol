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

    // Arbitrum Mainnet
    address constant ARB_CCIP_ROUTER = 0xE1053aE1857476f36A3C62580FF9b016E8EE8F6f;

    // Arbitrum Sepolia Testnet
    address constant ARB_SEPOLIA_ROUTER = 0xE1053aE1857476f36A3C62580FF9b016E8EE8F6f;

    // ============ Immutables ============
    address public immutable ccipRouter; 
    uint64 public immutable localChainId; // Uses CCIP's chain selector format

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

    /**
     * @notice Sets the authorization status of a sender
     * @param sender Address of the sender
     * @param authorized True to authorize, false to revoke
     */
    function setAuthorizedSender(address sender, bool authorized) external onlyRole(ADMIN_ROLE) {
        _allowedSenders[sender] = authorized;
        emit MessageSenderAuthorized(sender, authorized);
    }

    /**
     * @notice Allows the admin to withdraw all ETH from the contract in case of emergency
     * @param to Address to send the withdrawn ETH
     */
    function emergencyWithdrawETH(address to) external onlyRole(ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        payable(to).transfer(address(this).balance);
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
        require(gasLimit >= MIN_GAS_LIMIT && gasLimit <= MAX_GAS_LIMIT, "Invalid gas");
        if (chainId == 0 || chainId == localChainId) revert InvalidChain();
        if (processor == address(0)) revert ZeroAddress();

        _chains[chainId] = ChainConfig({
            isSupported: true,
            processor: processor,
            gasLimit: gasLimit,
            lastUpdate: block.timestamp
        });

        emit ChainConfigured(chainId, processor, gasLimit);
    }

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
            (bool isThrottled, ) = antiBot.checkThrottle(user);
            require(!isThrottled, "Throttled");
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

    /**
     * @notice Sends a cross-chain message to a destination chain
     * @param destChainId Destination chain ID (CCIP chain selector)
     * @param payload Message payload (state sync or token action)
     * @return payloadHash Hash of the payload
     * @return messageId CCIP message ID
     */
    function sendMessage(
        uint64 destChainId, 
        bytes calldata payload
    ) external payable onlyRole(OPERATOR_ROLE) checkThrottle(msg.sender) nonReentrant whenNotPaused returns (bytes32 payloadHash, uint256 messageId) {
        uint64 ccipDestChainId = uint64(destChainId); // Convert to CCIP format
        
        payloadHash = keccak256(payload);
        
        // CCIP message struct
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_chains[ccipDestChainId].processor),
            data: payload,
            tokenAmounts: new Client.EVMTokenAmount[](0), // No token transfers
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({
                gasLimit: _chains[ccipDestChainId].gasLimit,
                strict: false
            })),
            feeToken: address(0) // Pay fees in native ETH
        });
        
        uint256 fee = ccipRouter.getFee(ccipDestChainId, message);
        if (msg.value < fee) revert InsufficientFee();
        
        messageId = ccipRouter.ccipSend{value: fee}(ccipDestChainId, message);
        emit MessageSent(ccipDestChainId, payloadHash, messageId, fee);
        
        // Emit CrossChainSyncInitiated for state sync messages (halving sync with TerraStakeToken)
        if (payload.validateHeader() == 1) { // MessageType 1 = State sync
            CrossChainState memory state = abi.decode(payload.extractData(), (CrossChainState));
            emit CrossChainSyncInitiated(ccipDestChainId, state.halvingEpoch);
        }
        
        return (payloadHash, messageId);
    }

    /**
     * @notice Executes a token action (e.g., minting) on the token contract
     * @param srcChainId Source chain ID
     * @param recipient Recipient address
     * @param amount Amount of tokens
     * @param ref Unique reference for the action
     */
    function _executeTokenAction(uint16 srcChainId, address recipient, uint256 amount, bytes32 ref) 
        internal 
    {
        (bool success, ) = tokenContract.call(
            abi.encodeWithSelector(
                ICrossChainHandler.executeRemoteTokenAction.selector,
                srcChainId,
                recipient,
                amount,
                ref
            )
        );
        require(success, "Token action failed");
    }

    /**
     * @notice Updates the chain state with received halving or other state data
     * @param srcChainId Source chain ID
     * @param state CrossChainState containing halving epoch, timestamp, etc.
     */
    function _updateChainState(uint64 srcChainId, CrossChainState memory state) internal {
        if (state.timestamp > block.timestamp + MAX_TIMESTAMP_DRIFT) revert("Future timestamp");
        
        // Update local state
        _chainStates[srcChainId] = state;
        
        // Sync with TerraStakeToken (if newer halving epoch)
        if (address(tokenContract) != address(0)) {
            ICrossChainHandler(tokenContract).updateFromCrossChain(
                uint16(srcChainId), // Convert back to uint16 for token contract
                state
            );
        }
    }

    // ============ Utility Functions ============
    /**
     * @notice Processes incoming messages
     * @param sourceChainSelector Source chain ID
     * @param data Message payload
     */
    function _processMessage(uint64 sourceChainSelector, bytes memory data) internal {
        // Validate payload structure
        if (data.length == 0) revert InvalidPayload();
        
        // Decode and process message
        CrossChainState memory state = abi.decode(data, (CrossChainState));
        _updateChainState(sourceChainSelector, state);
        
        emit CrossChainStateUpdated(sourceChainSelector, state);
    }

    /**
     * @notice Estimates the fee for sending a message to a destination chain
     * @param destChainId Destination chain ID (CCIP chain selector)
     * @param payload Message payload
     * @return nativeFee Native token fee
     */
    function estimateMessageFee(
        uint64 destChainId, // Standardized to uint64 for CCIP compatibility
        bytes calldata payload
    ) external view returns (uint256 nativeFee, uint256) {
        uint64 ccipDestChainId = uint64(destChainId); // Convert to uint64 for CCIP
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_chains[ccipDestChainId].processor),
            data: payload,
            tokenAmounts: new Client.EVMTokenAmount[](0), // No token transfers
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({
                    gasLimit: _chains[ccipDestChainId].gasLimit,
                    strict: false
                })
            ),
            feeToken: address(0) // Use native for fees
        });
        return (ccipRouter.getFee(ccipDestChainId, message), 0);
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

    /**
     * @notice Handles incoming CCIP messages
     * @param message The CCIP message
     */
    function ccipReceive(Client.Any2EVMMessage memory message) external override {
        require(msg.sender == address(ccipRouter), "Invalid caller");
        
        address sender = abi.decode(message.sender, (address));
        if (!_allowedSenders[sender]) revert UnauthorizedSender(sender);
        
        bytes32 messageId = keccak256(abi.encode(
            message.sourceChainSelector, 
            message.sender, 
            message.messageId
        ));
        if (_processedMessages[messageId]) revert StaleMessage();
        
        _processedMessages[messageId] = true;
        _processMessage(message.sourceChainSelector, message.data);
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