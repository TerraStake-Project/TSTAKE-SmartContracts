// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";

/**
 * @title FeeCalculator
 * @dev Calculates message fees for Chainlink CCIP cross-chain operations
 */
library FeeCalculator {
    // ============ Constants ============
    uint256 public constant DEFAULT_BUFFER_BPS = 1000; // 10%

    /**
     * @notice Builds the CCIP message object
     * @param receiver The address of the destination CrossChainHandler (encoded)
     * @param data Encoded payload to send
     * @param gasLimit Gas limit to allocate on the destination chain
     * @return message Struct representing a CCIP message
     */
    function buildCCIPMessage(
        address receiver,
        bytes memory data,
        uint256 gasLimit
    ) internal pure returns (Client.EVM2AnyMessage memory message) {
        message = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: data,
            tokenAmounts: new Client.EVMTokenAmount , // No token transfer
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({
                    gasLimit: gasLimit,
                    strict: false
                })
            ),
            feeToken: address(0) // Pay in native token (ETH, etc.)
        });
    }

    /**
     * @notice Calculates base message fee for a CCIP transmission
     * @param router Chainlink CCIP router client
     * @param destChainSelector Destination chain selector (CCIP format)
     * @param message Prepared CCIP message
     * @return nativeFee Fee in native token (ETH, MATIC, etc.)
     */
    function calculateMessageFee(
        IRouterClient router,
        uint64 destChainSelector,
        Client.EVM2AnyMessage memory message
    ) internal view returns (uint256 nativeFee) {
        nativeFee = router.getFee(destChainSelector, message);
    }

    /**
     * @notice Adds buffer to fee in basis points (BPS)
     * @param baseFee The calculated fee
     * @param bufferBps The buffer (e.g. 1000 = 10%)
     * @return totalFee Buffered fee
     */
    function addFeeBuffer(uint256 baseFee, uint256 bufferBps) internal pure returns (uint256 totalFee) {
        return baseFee + ((baseFee * bufferBps) / 10000);
    }

    /**
     * @notice Gets recommended gas limit for a destination chain
     * @param chainSelector Destination chain selector
     * @return gasLimit Recommended gas limit
     */
    function getRecommendedGasLimit(uint64 chainSelector) internal pure returns (uint256 gasLimit) {
        if (chainSelector == 5009297550715157269) return 800_000; // Ethereum Mainnet
        if (chainSelector == 4949039107694359620) return 800_000; // Arbitrum One
        if (chainSelector == 3734403246176062136) return 200_000; // Optimism
        if (chainSelector == 12532609583862916517) return 400_000; // Polygon
        if (chainSelector == 13264668187771770619) return 300_000; // BNB Chain

        return 300_000; // Default fallback
    }

    /**
     * @notice Calculates total estimated fee with buffer
     * @param router Chainlink CCIP router client
     * @param destChainSelector Destination chain selector (CCIP format)
     * @param receiver Destination contract
     * @param payload Encoded data payload
     * @param gasLimit Custom gas limit (0 for default)
     * @param bufferBps Optional buffer in BPS (0 for default)
     * @return totalFee Estimated fee with buffer applied
     */
    function estimateTotalFee(
        IRouterClient router,
        uint64 destChainSelector,
        address receiver,
        bytes memory payload,
        uint256 gasLimit,
        uint256 bufferBps
    ) internal view returns (uint256 totalFee) {
        uint256 finalGasLimit = gasLimit == 0
            ? getRecommendedGasLimit(destChainSelector)
            : gasLimit;
        uint256 finalBufferBps = bufferBps == 0 ? DEFAULT_BUFFER_BPS : bufferBps;

        Client.EVM2AnyMessage memory message = buildCCIPMessage(receiver, payload, finalGasLimit);
        uint256 baseFee = calculateMessageFee(router, destChainSelector, message);
        return addFeeBuffer(baseFee, finalBufferBps);
    }
}
