// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";

/**
 * @title ITerraStakeFractionToken
 * @dev Interface for the FractionToken representing fractions of a TerraStake NFT
 */
interface ITerraStakeFractionToken is IERC20, IERC20Metadata {
    /**
     * @notice Returns the ID of the NFT that this token represents
     * @return The NFT ID
     */
    function nftId() external view returns (uint256);
    
    /**
     * @notice Returns the address of the fraction manager contract
     * @return The fraction manager address
     */
    function fractionManager() external view returns (address);
    
    /**
     * @notice Burns a specified amount of tokens
     * @param amount The amount of tokens to burn
     */
    function burn(uint256 amount) external;
    
    /**
     * @notice Burns tokens from an account if approved
     * @param account The account to burn tokens from
     * @param amount The amount of tokens to burn
     */
    function burnFrom(address account, uint256 amount) external;
    
    /**
     * @notice ERC20Permit function - updates allowances with a signed permit
     * @param owner The token owner
     * @param spender The spender address
     * @param value The amount of tokens to approve
     * @param deadline The deadline timestamp for the signature
     * @param v The recovery byte of the signature
     * @param r The first 32 bytes of the signature
     * @param s The second 32 bytes of the signature
     */
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}
