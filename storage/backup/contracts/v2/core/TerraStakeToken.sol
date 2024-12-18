// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "../interfaces/ITerraStakeToken.sol";

contract TerraStakeToken is
    Initializable,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ITerraStakeToken
{
    uint256 public override maxSupply;
    uint256 public override burnRate;
    uint256 public override redistributionRate;
    uint256 public override stakingRewardsRate;

    address public override redistributionAddress;
    address public override stakingRewardsAddress;

    mapping(address => VestingSchedule) private vestingSchedules;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant VESTING_MANAGER_ROLE = keccak256("VESTING_MANAGER_ROLE");

    function initialize(
        string memory name_,
        string memory symbol_,
        uint256 maxSupply_,
        address admin
    ) external initializer {
        __ERC20_init(name_, symbol_);
        __AccessControl_init();
        __Pausable_init();

        if (admin == address(0)) revert ZeroAddress();

        maxSupply = maxSupply_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
    }

    function mint(address to, uint256 amount) external override onlyRole(MINTER_ROLE) {
        if (totalSupply() + amount > maxSupply) revert MintAmountExceedsMaxSupply();
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external override {
        if (balanceOf(from) < amount) revert BurnAmountExceedsBalance();
        _burn(from, amount);
    }

    function transfer(address to, uint256 amount) public override(ERC20Upgradeable, ITerraStakeToken) returns (bool) {
        return super.transfer(to, amount);
    }

    function createVestingSchedule(
        address beneficiary,
        uint256 totalAmount,
        uint256 startTime,
        uint256 duration,
        uint256 cliff
    ) external override onlyRole(VESTING_MANAGER_ROLE) {
        if (vestingSchedules[beneficiary].totalAmount > 0) revert NoVestingSchedule();

        vestingSchedules[beneficiary] = VestingSchedule({
            totalAmount: totalAmount,
            releasedAmount: 0,
            startTime: startTime,
            duration: duration,
            cliff: cliff
        });

        emit VestingScheduleCreated(beneficiary, totalAmount, startTime, duration, cliff);
    }

    function claimVestedTokens() external override {
        VestingSchedule storage schedule = vestingSchedules[msg.sender];
        if (block.timestamp < schedule.startTime + schedule.cliff) revert CliffNotReached();

        uint256 vestedAmount = _calculateClaimableTokens(schedule);
        if (vestedAmount == 0) revert NoClaimableTokens();

        schedule.releasedAmount += vestedAmount;
        _mint(msg.sender, vestedAmount);

        emit TokensClaimed(msg.sender, vestedAmount);
    }

    function getVestingSchedule(address beneficiary) external view override returns (VestingSchedule memory) {
        return vestingSchedules[beneficiary];
    }

    function revokeVestingSchedule(address beneficiary) external override onlyRole(VESTING_MANAGER_ROLE) {
        delete vestingSchedules[beneficiary];
        emit VestingScheduleRevoked(beneficiary, 0);
    }

    function setRates(uint256 _burnRate, uint256 _redistributionRate, uint256 _stakingRewardsRate)
        external
        override
        onlyRole(GOVERNANCE_ROLE)
    {
        burnRate = _burnRate;
        redistributionRate = _redistributionRate;
        stakingRewardsRate = _stakingRewardsRate;

        emit RatesUpdated(_burnRate, _redistributionRate, _stakingRewardsRate);
    }

    function setMaxSupply(uint256 newMaxSupply) external override onlyRole(GOVERNANCE_ROLE) {
        if (newMaxSupply < totalSupply()) revert NewMaxSupplyBelowTotalSupply();
        uint256 oldMaxSupply = maxSupply;
        maxSupply = newMaxSupply;

        emit MaxSupplyUpdated(oldMaxSupply, newMaxSupply);
    }

    function pause() external override onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function unpause() external override onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    // Changed to pure since it returns a constant and does not read state
    function getPrice() external pure override returns (uint256) {
        return 0; 
    }

    function emergencyWithdraw(address token, address to, uint256 amount) external override onlyRole(EMERGENCY_ROLE) {
        IERC20(token).transfer(to, amount);
        emit EmergencyWithdraw(token, to, amount);
    }

    function _calculateClaimableTokens(VestingSchedule storage schedule) internal view returns (uint256) {
        if (block.timestamp < schedule.startTime + schedule.cliff) return 0;

        uint256 elapsedTime = block.timestamp - schedule.startTime;
        uint256 totalVested = (schedule.totalAmount * elapsedTime) / schedule.duration;

        return totalVested > schedule.releasedAmount ? totalVested - schedule.releasedAmount : 0;
    }
}
