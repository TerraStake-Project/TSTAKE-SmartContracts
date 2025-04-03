// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

/**
 * @title EthereumAdapter
 * @dev Ethereum-specific helpers for Chainlink CCIP integration
 * @notice This version is Chainlink-native (no LayerZero logic)
 */
library EthereumAdapter {
    // ============ Constants ============
    // Chainlink CCIP selector for Ethereum Mainnet
    uint64 internal constant CHAIN_SELECTOR = 5009297550715157269;

    // ============ Errors ============
    error InvalidAddress();
    error InvalidPayload();

    /**
     * @notice Formats a destination address for CCIP (EVM-compatible)
     * @param destination Address on the target chain
     * @return encoded Encoded destination for CCIP receiver
     */
    function formatReceiver(address destination) internal pure returns (bytes memory encoded) {
        if (destination == address(0)) revert InvalidAddress();
        return abi.encode(destination);
    }

    /**
     * @notice Parses a destination address from CCIP message
     * @param encodedReceiver Encoded bytes from CCIP `message.sender`
     * @return decoded Address parsed from encoded value
     */
    function parseReceiver(bytes memory encodedReceiver) internal pure returns (address decoded) {
        if (encodedReceiver.length != 32) revert InvalidPayload(); // ABI encoding of address is 32 bytes
        decoded = abi.decode(encodedReceiver, (address));
    }

    /**
     * @notice Estimates gas needed for CCIP operations (approximate)
     * @param payloadSize Payload size in bytes
     * @return gasEstimate Estimated gas cost (rough)
     */
    function estimateGas(uint256 payloadSize) internal pure returns (uint256 gasEstimate) {
        unchecked {
            return 100_000 + ((payloadSize + 31) / 32) * 16_000;
        }
    }
}
