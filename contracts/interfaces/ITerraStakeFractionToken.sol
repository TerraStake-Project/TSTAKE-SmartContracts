// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "./interfaces/ITerraStakeFractionToken.sol";

/**
 * @title TerraStakeFractionToken
 * @dev ERC20 token representing fractions of a TerraStake NFT
 */
contract TerraStakeFractionToken is ERC20, ERC20Burnable, ERC20Permit, ITerraStakeFractionToken {
    uint256 private _nftId;
    address private _fractionManager;
    
    // Additional metadata for environmental impact
    uint256 public impactValue;
    string public projectType;
    bytes32 public verificationHash;

    /**
     * @notice Initializes the TerraStakeFractionToken contract
     * @param name The name of the token
     * @param symbol The symbol of the token
     * @param initialSupply The initial token supply
     * @param tokenNftId The ID of the fractionalized NFT
     * @param manager The address of the fraction manager contract
     * @param _impactValue The environmental impact value of the underlying NFT
     * @param _projectType The type of environmental project
     * @param _verificationHash Hash of verification data for the project
     */
    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        uint256 tokenNftId,
        address manager,
        uint256 _impactValue,
        string memory _projectType,
        bytes32 _verificationHash
    ) ERC20(name, symbol) ERC20Permit(name) {
        require(manager != address(0), "Manager cannot be zero address");
        require(initialSupply > 0, "Supply must be positive");
        
        _nftId = tokenNftId;
        _fractionManager = manager;
        impactValue = _impactValue;
        projectType = _projectType;
        verificationHash = _verificationHash;
        
        _mint(manager, initialSupply);
    }
    
    /**
     * @notice Returns the ID of the NFT that this token represents
     * @return The NFT ID
     */
    function nftId() public view override returns (uint256) {
        return _nftId;
    }
    
    /**
     * @notice Returns the address of the fraction manager contract
     * @return The fraction manager address
     */
    function fractionManager() public view override returns (address) {
        return _fractionManager;
    }
    
    /**
     * @notice Burns a specified amount of tokens - only fraction manager can call
     * @param amount The amount of tokens to burn
     */
    function burn(uint256 amount) public override(ERC20Burnable, ITerraStakeFractionToken) {
        super.burn(amount);
    }
    
    /**
     * @notice Burns tokens from an account if approved
     * @param account The account to burn tokens from
     * @param amount The amount of tokens to burn
     */
    function burnFrom(address account, uint256 amount) public override(ERC20Burnable, ITerraStakeFractionToken) {
        super.burnFrom(account, amount);
    }
    
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
    ) public override(ERC20Permit, ITerraStakeFractionToken) {
        super.permit(owner, spender, value, deadline, v, r, s);
    }
    
    /**
     * @notice Get complete metadata about this fraction token
     * @return tokenNftId The NFT ID
     * @return manager The fraction manager address
     * @return impact The environmental impact value
     * @return project The project type
     * @return verification The verification hash
     */
    function getMetadata() external view returns (
        uint256 tokenNftId,
        address manager,
        uint256 impact,
        string memory project,
        bytes32 verification
    ) {
        return (_nftId, _fractionManager, impactValue, projectType, verificationHash);
    }
    
    /**
     * @notice Update the impact value - only callable by fraction manager
     * @param newImpactValue The new impact value
     */
    function updateImpactValue(uint256 newImpactValue) external {
        require(msg.sender == _fractionManager, "Only fraction manager can update");
        impactValue = newImpactValue;
    }
}
