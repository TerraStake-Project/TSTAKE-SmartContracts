// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

/**
 * @title MessageVerifier
 * @dev Library for verifying and decoding Chainlink CCIP cross-chain message payloads
 */
library MessageVerifier {
    // ============ Errors ============
    error EmptyPayload();
    error InsufficientPayloadLength();

    // ============ Payload Format ============
    // [1 byte: messageType][n bytes: messageData]

    /**
     * @notice Validates and extracts the message type from the payload
     * @param payload The full cross-chain message payload
     * @return messageType The first byte of the payload
     */
    function extractMessageType(bytes memory payload) internal pure returns (uint8 messageType) {
        if (payload.length == 0) revert EmptyPayload();
        return uint8(payload[0]);
    }

    /**
     * @notice Extracts the message data after the message type
     * @param payload The full cross-chain message payload
     * @return messageData The bytes after the first byte (actual encoded data)
     */
    function extractMessageData(bytes memory payload) internal pure returns (bytes memory messageData) {
        if (payload.length <= 1) revert InsufficientPayloadLength();
        return payload[1:];
    }

    /**
     * @notice Generates a unique message ID for internal deduplication or off-chain indexing
     * @param srcChainId Source chain ID (Chainlink chain selector format)
     * @param sender The address on the source chain
     * @param ccipMessageId The message ID returned by Chainlink CCIP
     * @return messageId A keccak256 hash of the message metadata
     */
    function generateMessageId(
        uint64 srcChainId,
        address sender,
        bytes32 ccipMessageId
    ) internal pure returns (bytes32 messageId) {
        return keccak256(abi.encode(srcChainId, sender, ccipMessageId));
    }

    // ============ Optional Aliases for Extension Syntax ============
    /**
     * @notice Alias for extractMessageType (for use with `using MessageVerifier for bytes`)
     */
    function validateHeader(bytes memory payload) internal pure returns (uint8) {
        return extractMessageType(payload);
    }

    /**
     * @notice Alias for extractMessageData (for use with `using MessageVerifier for bytes`)
     */
    function extractData(bytes memory payload) internal pure returns (bytes memory) {
        return extractMessageData(payload);
    }
}
