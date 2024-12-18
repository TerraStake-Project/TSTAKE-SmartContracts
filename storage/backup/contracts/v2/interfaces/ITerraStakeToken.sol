// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITerraStakeToken {
    error MintAmountExceedsMaxSupply();
    error BurnAmountExceedsBalance();
    error ZeroAddress();
    error NewMaxSupplyBelowTotalSupply();
    error NoVestingSchedule();
    error CliffNotReached();
    error NoClaimableTokens();

    struct VestingSchedule {
        uint256 totalAmount;
        uint256 releasedAmount;
        uint256 startTime;
        uint256 duration;
        uint256 cliff;
    }

    event RatesUpdated(uint256 burnRate, uint256 redistributionRate, uint256 stakingRewardsRate);
    event MaxSupplyUpdated(uint256 oldMaxSupply, uint256 newMaxSupply);
    event VestingScheduleCreated(address indexed beneficiary, uint256 totalAmount, uint256 startTime, uint256 duration, uint256 cliff);
    event TokensClaimed(address indexed beneficiary, uint256 amount);
    event VestingScheduleRevoked(address indexed beneficiary, uint256 amountRemaining);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);

    function maxSupply() external view returns (uint256);
    function burnRate() external view returns (uint256);
    function redistributionRate() external view returns (uint256);
    function stakingRewardsRate() external view returns (uint256);

    function redistributionAddress() external view returns (address);
    function stakingRewardsAddress() external view returns (address);

    function initialize(
        string memory name_,
        string memory symbol_,
        uint256 maxSupply_,
        address admin
    ) external;

    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);

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

    function setRates(uint256 _burnRate, uint256 _redistributionRate, uint256 _stakingRewardsRate) external;
    function setMaxSupply(uint256 newMaxSupply) external;
    function pause() external;
    function unpause() external;
    function getPrice() external view returns (uint256);
    function emergencyWithdraw(address token, address to, uint256 amount) external;
}
