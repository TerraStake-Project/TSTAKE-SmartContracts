// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

/**
 * @title ISecondaryMarketCallback
 * @dev Interface for secondary markets to receive notifications about fraction token transfers
 */
interface ISecondaryMarketCallback {
    /**
     * @dev Called when a fraction token transfer occurs
     * @param from The address sending the tokens
     * @param to The address receiving the tokens
     * @param fractionToken The address of the fraction token
     * @param amount The amount of tokens transferred
     */
    function onFractionTransfer(
        address from,
        address to,
        address fractionToken,
        uint256 amount
    ) external;
}