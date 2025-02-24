// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITerraStakeToken {
    // Custom Errors
    error MintAmountExceedsMaxSupply();
    error BurnAmountExceedsBalance();
    error ZeroAddress();
    error NewMaxSupplyBelowTotalSupply();
    error NoVestingSchedule();
    error CliffNotReached();
    error NoClaimableTokens();

    // Structs
    struct VestingSchedule {
        uint256 totalAmount;
        uint256 releasedAmount;
        uint256 startTime;
        uint256 duration;
        uint256 cliff;
    }

    // Events
    event RatesUpdated(uint256 burnRate, uint256 redistributionRate, uint256 stakingRewardsRate);
    event MaxSupplyUpdated(uint256 oldMaxSupply, uint256 newMaxSupply);
    event VestingScheduleCreated(
        address indexed beneficiary,
        uint256 totalAmount,
        uint256 startTime,
        uint256 duration,
        uint256 cliff
    );
    event TokensClaimed(address indexed beneficiary, uint256 amount);
    event VestingScheduleRevoked(address indexed beneficiary, uint256 amountRemaining);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);
    event TokensRedistributed(address indexed to, uint256 amount);
    event StakingRewardsFunded(address indexed to, uint256 amount);

    // Tokenomics Parameters
    function maxSupply() external view returns (uint256);
    function burnRate() external view returns (uint256);
    function redistributionRate() external view returns (uint256);
    function stakingRewardsRate() external view returns (uint256);

    // Addresses for tokenomics
    function redistributionAddress() external view returns (address);
    function stakingRewardsAddress() external view returns (address);

    // Initialization
    function initialize(
        uint256 maxSupply_,
        address admin,
        address _redistributionAddress,
        address _stakingRewardsAddress
    ) external;

    // Core Token Functions
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;

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


    // Tokenomics Management
    function setRates(uint256 _burnRate, uint256 _redistributionRate, uint256 _stakingRewardsRate) external;
    function setMaxSupply(uint256 newMaxSupply) external;

    // Redistribution & Staking Rewards
    function redistribute(uint256 amount) external;
    function sendToStakingRewards(uint256 amount) external;

    // Emergency and Pause Functions
    function pause() external;
    function unpause() external;
    function emergencyWithdraw(address token, address to, uint256 amount) external;
}