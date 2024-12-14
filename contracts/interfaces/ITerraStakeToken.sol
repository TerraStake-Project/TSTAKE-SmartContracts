// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITerraStakeToken {
    // Custom Errors
    error Unauthorized();
    error ZeroAddress();
    error InvalidRate();
    error MintAmountExceedsMaxSupply();
    error BurnAmountExceedsBalance();
    error NoVestingSchedule();
    error CliffNotReached();
    error NoClaimableTokens();
    error NewMaxSupplyBelowTotalSupply();
    error InvalidAdminAddress();
    error AirdropExceedsMaxSupply();

    // State Variables
    function maxSupply() external view returns (uint256);
    function burnRate() external view returns (uint256);
    function redistributionRate() external view returns (uint256);

    // Role Management
    function MINTER_ROLE() external view returns (bytes32);
    function GOVERNANCE_ROLE() external view returns (bytes32);
    function VESTING_MANAGER_ROLE() external view returns (bytes32);
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function EMERGENCY_ROLE() external view returns (bytes32);

    // Vesting Schedule Struct
    struct VestingSchedule {
        uint256 totalAmount;
        uint256 releasedAmount;
        uint256 startTime;
        uint256 duration;
        uint256 cliff;
    }

    // Core Token Operations
    /// @notice Mint tokens to a specific address
    /// @dev Requires MINTER_ROLE
    /// @param to The address to mint tokens to
    /// @param amount The amount of tokens to mint
    function mint(address to, uint256 amount) external;

    /// @notice Burn tokens from a specific address
    /// @param from The address to burn tokens from
    /// @param amount The amount of tokens to burn
    function burn(address from, uint256 amount) external;

    /// @notice Transfer tokens, applying burn and redistribution if applicable
    /// @param to The recipient of the transfer
    /// @param amount The amount of tokens to transfer
    function transfer(address to, uint256 amount) external returns (bool);

    // Vesting Functions
    /// @notice Create a vesting schedule for a beneficiary
    /// @dev Requires VESTING_MANAGER_ROLE
    function createVestingSchedule(
        address beneficiary,
        uint256 totalAmount,
        uint256 startTime,
        uint256 duration,
        uint256 cliff
    ) external;

    /// @notice Claim vested tokens
    function claimVestedTokens() external;

    /// @notice Get the vesting schedule for a beneficiary
    /// @param beneficiary The address to query
    /// @return The vesting schedule for the beneficiary
    function getVestingSchedule(address beneficiary) external view returns (VestingSchedule memory);

    // Admin Functions
    /// @notice Update burn and redistribution rates
    /// @dev Requires GOVERNANCE_ROLE
    function setRates(uint256 burnRate, uint256 redistributionRate) external;

    /// @notice Set a new maximum supply for the token
    /// @dev Requires DEFAULT_ADMIN_ROLE
    /// @param newMaxSupply The new maximum supply to set
    function setMaxSupply(uint256 newMaxSupply) external;

    /// @notice Pause all token transfers
    /// @dev Requires EMERGENCY_ROLE
    function pause() external;

    /// @notice Unpause all token transfers
    /// @dev Requires EMERGENCY_ROLE
    function unpause() external;

    // Price Feed
    /// @notice Get the latest price from the oracle
    /// @return The latest price
    function getPrice() external view returns (uint256);

    // Emergency Functions
    /// @notice Withdraw tokens in case of an emergency
    /// @dev Requires EMERGENCY_ROLE
    /// @param token The token to withdraw
    /// @param to The recipient address
    /// @param amount The amount to withdraw
    function emergencyWithdraw(address token, address to, uint256 amount) external;

    // Events
    event TokensBurned(address indexed from, uint256 amount);
    event TokensRedistributed(address indexed recipient, uint256 amount);
    event RatesUpdated(uint256 burnRate, uint256 redistributionRate);
    event VestingScheduleCreated(
        address indexed beneficiary,
        uint256 totalAmount,
        uint256 startTime,
        uint256 duration,
        uint256 cliff
    );
    event TokensClaimed(address indexed beneficiary, uint256 amount);
    event MaxSupplyUpdated(uint256 newMaxSupply);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);
}
