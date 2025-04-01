// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.21;

/**
 * @title EthereumAdapter
 * @dev Handles Ethereum-specific cross-chain logic for LayerZero integration
 */
library EthereumAdapter {
    // Ethereum Mainnet chain ID constant (LayerZero uses uint16 for chain IDs)
    uint16 internal constant CHAIN_ID = 1;

    // Errors
    error InvalidAddressLength();

    /**
     * @dev Formats an Ethereum address for LayerZero cross-chain compatibility
     * @param localAddr Local Ethereum address
     * @param remoteAddr Remote address (on destination chain)
     * @return bytes 40-byte path compatible with LayerZero (local + remote address)
     */
    function formatAddress(address localAddr, address remoteAddr) internal pure returns (bytes memory) {
        return abi.encodePacked(localAddr, remoteAddr);
    }
    
    /**
     * @dev Parses an Ethereum address from a LayerZero path
     * @param path 40-byte path containing local and remote addresses
     * @return localAddr Local Ethereum address
     * @return remoteAddr Remote address
     */
    function parseAddress(bytes memory path) internal pure returns (address localAddr, address remoteAddr) {
        if (path.length != 40) revert InvalidAddressLength();
        
        assembly {
            localAddr := shr(96, mload(add(path, 32)))
            remoteAddr := shr(96, mload(add(path, 40)))
        }
    }
    
    /**
     * @dev Estimates gas needed for Ethereum cross-chain operations
     * @param payloadSize Size of the message payload in bytes
     * @return uint256 Estimated gas cost
     */
    function estimateGas(uint256 payloadSize) internal pure returns (uint256) {
        // Base gas (100k) + additional gas per 32-byte chunk of payload
        unchecked {
            return 100_000 + ((payloadSize + 31) / 32) * 16_000;
        }
    }
}