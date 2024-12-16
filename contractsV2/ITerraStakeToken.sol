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
    function stakingRewardsRate() external view returns (uint256);
    function redistributionAddress() external view returns (address);
    function stakingRewardsAddress() external view returns (address);

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
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);

    // Vesting Functions
    function createVestingSchedule(
        address beneficiary,
        uint256 totalAmount,
        uint256 startTime,
        uint256 duration,
        uint256 cliff
    ) external;

    function claimVestedTokens() external;

    function getVestingSchedule(address beneficiary) external view returns (VestingSchedule memory);

    function revokeVestingSchedule(address beneficiary) external;

    // Admin Functions
    function setRates(uint256 burnRate, uint256 redistributionRate, uint256 stakingRewardsRate) external;
    function setMaxSupply(uint256 newMaxSupply) external;
    function pause() external;
    function unpause() external;

    // Price Feed
    function getPrice() external view returns (uint256);

    // Emergency Functions
    function emergencyWithdraw(address token, address to, uint256 amount) external;

    // Events
    event TokensBurned(address indexed from, uint256 amount);
    event TokensRedistributed(address indexed recipient, uint256 amount);
    event RatesUpdated(uint256 burnRate, uint256 redistributionRate, uint256 stakingRewardsRate);
    event VestingScheduleCreated(
        address indexed beneficiary,
        uint256 totalAmount,
        uint256 startTime,
        uint256 duration,
        uint256 cliff
    );
    event VestingScheduleRevoked(address indexed beneficiary, uint256 unvestedAmount);
    event TokensClaimed(address indexed beneficiary, uint256 amount);
    event MaxSupplyUpdated(uint256 oldMaxSupply, uint256 newMaxSupply);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);
}
