// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title TerraStakeFractionToken
 * @dev ERC20 token representing fractions of a TerraStake NFT
 */
contract TerraStakeFractionToken is ERC20, ERC20Burnable, ERC20Permit {
    uint256 public nftId;
    address public fractionManager;

    /**
     * @notice Initializes the TerraStakeFractionToken contract
     * @param name The name of the token
     * @param symbol The symbol of the token
     * @param initialSupply The initial token supply
     * @param _nftId The ID of the fractionalized NFT
     * @param _fractionManager The address of the fraction manager contract
     */
    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        uint256 _nftId,
        address _fractionManager
    ) ERC20(name, symbol) ERC20Permit(name) {
        nftId = _nftId;
        fractionManager = _fractionManager;
        _mint(_fractionManager, initialSupply);
    }
}
