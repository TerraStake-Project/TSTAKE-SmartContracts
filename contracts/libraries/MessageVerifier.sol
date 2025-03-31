// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.21;

/**
 * @title MessageVerifier
 * @dev Handles verification of cross-chain messages for CrossChainHandler
 */
library MessageVerifier {
    // Errors
    error InvalidSourceAddressLength();
    error EmptyPayload();
    error InsufficientPayloadLength();

    /**
     * @dev Verifies the source of a message
     * @param srcChainId Source chain ID (unused but included for interface consistency)
     * @param srcAddress Source address bytes (expected to be 40 bytes for LayerZero: 20 bytes local + 20 bytes remote)
     * @param expectedProcessor Expected processor address to verify against
     * @return bool Whether the remote address in the path matches the expected processor
     */
    function verifyMessageSource(
        uint16 /* srcChainId */,
        bytes memory srcAddress,
        address expectedProcessor
    ) internal pure returns (bool) {
        if (srcAddress.length != 40) revert InvalidSourceAddressLength();
        
        // Extract the last 20 bytes (remote address) without assembly for readability
        bytes20 remoteAddrBytes = bytes20(srcAddress[20:]);
        address remoteAddr = address(remoteAddrBytes);
        
        return remoteAddr == expectedProcessor;
    }
    
    /**
     * @dev Generates a unique message ID
     * @param srcChainId Source chain ID
     * @param srcAddress Source address bytes
     * @param nonce Message nonce
     * @param payload Message payload
     * @return bytes32 Unique message identifier
     */
    function generateMessageId(
        uint16 srcChainId,
        bytes memory srcAddress,
        uint64 nonce,
        bytes memory payload
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(srcChainId, srcAddress, nonce, payload));
    }
    
    /**
     * @dev Extracts the message type from a payload
     * @param payload Message payload
     * @return uint8 Message type (first byte of payload)
     */
    function extractMessageType(bytes memory payload) internal pure returns (uint8) {
        if (payload.length == 0) revert EmptyPayload();
        return uint8(payload[0]);
    }
    
    /**
     * @dev Extracts the message data from a payload
     * @param payload Message payload
     * @return bytes Message data (everything after the first byte)
     */
    function extractMessageData(bytes memory payload) internal pure returns (bytes memory) {
        if (payload.length <= 1) revert InsufficientPayloadLength();
        return payload[1:];
    }
}