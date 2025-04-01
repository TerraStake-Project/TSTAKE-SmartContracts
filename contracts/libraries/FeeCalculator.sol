// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.21;

import "@layerzero-labs/solidity-examples/contracts/interfaces/ILayerZeroEndpoint.sol";

/**
 * @title FeeCalculator
 * @dev Calculates fees for cross-chain operations with LayerZero, optimized for Arbitrum
 */
library FeeCalculator {
    // ============ Constants ============
    uint256 public constant DEFAULT_BUFFER_BPS = 1000; // 10% buffer

    /**
     * @dev Calculates the fee for a cross-chain message
     * @param endpoint LayerZero endpoint contract
     * @param chainId Destination chain ID (LayerZero format)
     * @param sender Sender address
     * @param payload Message payload
     * @param gasLimit Gas limit for the destination chain
     * @return nativeFee Fee in native currency (ETH on Arbitrum)
     */
    function calculateMessageFee(
        ILayerZeroEndpoint endpoint,
        uint16 chainId,
        address sender,
        bytes memory payload,
        uint256 gasLimit
    ) internal view returns (uint256 nativeFee) {
        (nativeFee, ) = endpoint.estimateFees(
            chainId,
            sender,
            payload,
            false, // No premium fee
            abi.encodePacked(uint16(1), gasLimit) // Adapter params v1
        );
        return nativeFee;
    }
    
    /**
     * @dev Adds a safety buffer to a base fee
     * @param baseFee Base fee to buffer
     * @param bufferBps Buffer in basis points (e.g., 1000 = 10%)
     * @return Buffered fee
     */
    function addFeeBuffer(uint256 baseFee, uint256 bufferBps) internal pure returns (uint256) {
        return baseFee + ((baseFee * bufferBps) / 10000);
    }
    
    /**
     * @dev Gets the recommended gas limit for a chain
     * @param chainId Destination chain ID (LayerZero format)
     * @return Recommended gas limit
     */
    function getRecommendedGasLimit(uint16 chainId) internal pure returns (uint256) {
        if (chainId == 101) return 150000; // Ethereum Mainnet (LayerZero ID)
        if (chainId == 110) return 800000; // Arbitrum One
        if (chainId == 111) return 200000; // Optimism
        if (chainId == 109) return 500000; // Polygon
        if (chainId == 102) return 300000; // BSC
        
        return 300000; // Default
    }

    /**
     * @dev Estimates total fee with buffer for a cross-chain message
     * @param endpoint LayerZero endpoint contract
     * @param chainId Destination chain ID (LayerZero format)
     * @param sender Sender address
     * @param payload Message payload
     * @param gasLimit Optional gas limit (0 for recommended)
     * @param bufferBps Optional buffer in basis points (0 for default)
     * @return totalFee Total fee with buffer
     */
    function estimateTotalFee(
        ILayerZeroEndpoint endpoint,
        uint16 chainId,
        address sender,
        bytes memory payload,
        uint256 gasLimit,
        uint256 bufferBps
    ) internal view returns (uint256 totalFee) {
        uint256 effectiveGasLimit = gasLimit == 0 ? getRecommendedGasLimit(chainId) : gasLimit;
        uint256 effectiveBufferBps = bufferBps == 0 ? DEFAULT_BUFFER_BPS : bufferBps;
        
        uint256 baseFee = calculateMessageFee(endpoint, chainId, sender, payload, effectiveGasLimit);
        return addFeeBuffer(baseFee, effectiveBufferBps);
    }
}