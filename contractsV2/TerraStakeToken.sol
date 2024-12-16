// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20VotesUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../governance/TerraStakeAccessControl.sol";
import "../interfaces/ITerraStakeToken.sol";

contract TerraStakeToken is
    Initializable,
    ERC20VotesUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    ITerraStakeToken
{
    // State Variables
    TerraStakeAccessControl public accessControl;

    uint256 public override maxSupply;
    uint256 public override burnRate; // Basis points (e.g., 100 = 1%)
    uint256 public override redistributionRate; // Basis points
    uint256 public override stakingRewardsRate; // Basis points

    address public redistributionAddress;
    address public stakingRewardsAddress;

    AggregatorV3Interface public priceFeed;

    mapping(address => VestingSchedule) private vestingSchedules;

    // Events
    event VestingScheduleRevoked(address indexed beneficiary, uint256 unvestedAmount);
    event RatesSet(uint256 burnRate, uint256 redistributionRate, uint256 stakingRewardsRate);
    event MaxSupplyUpdated(uint256 oldMaxSupply, uint256 newMaxSupply);

    // Initialization
    function initialize(
        address _accessControl,
        uint256 initialSupply,
        address _redistributionAddress,
        address _stakingRewardsAddress,
        address _priceFeed
    ) external initializer {
        require(_accessControl != address(0), "Zero address: access control");
        require(_redistributionAddress != address(0), "Zero address: redistribution");
        require(_stakingRewardsAddress != address(0), "Zero address: staking rewards");
        require(_priceFeed != address(0), "Zero address: price feed");

        __ERC20_init("TerraStake", "TSTAKE");
        __ERC20Votes_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        accessControl = TerraStakeAccessControl(_accessControl);
        redistributionAddress = _redistributionAddress;
        stakingRewardsAddress = _stakingRewardsAddress;
        priceFeed = AggregatorV3Interface(_priceFeed);

        maxSupply = 2_000_000_000 * 10**18;
        burnRate = 0;
        redistributionRate = 0;
        stakingRewardsRate = 0;

        // Mint initial supply to deployer
        _mint(msg.sender, initialSupply);
    }

    // Core Token Operations
    function mint(address to, uint256 amount) external override whenNotPaused nonReentrant {
        require(accessControl.hasRole(accessControl.MINTER_ROLE(), msg.sender), "Unauthorized");
        require(to != address(0), "Zero address: mint");
        require(totalSupply() + amount <= maxSupply, "Exceeds max supply");

        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external override whenNotPaused nonReentrant {
        require(accessControl.hasRole(accessControl.DEFAULT_ADMIN_ROLE(), msg.sender), "Unauthorized");
        require(from != address(0), "Zero address: burn");
        require(balanceOf(from) >= amount, "Insufficient balance");

        _burn(from, amount);
        emit TokensBurned(from, amount);
    }

    function transfer(address to, uint256 amount)
        public
        override(ERC20Upgradeable, ITerraStakeToken)
        whenNotPaused
        returns (bool)
    {
        require(redistributionAddress != address(0), "Invalid redistribution address");
        require(stakingRewardsAddress != address(0), "Invalid staking rewards address");

        uint256 burnAmount = (amount * burnRate) / 10000;
        uint256 redistributeAmount = (amount * redistributionRate) / 10000;
        uint256 rewardAmount = (amount * stakingRewardsRate) / 10000;
        uint256 netAmount = amount - burnAmount - redistributeAmount - rewardAmount;

        if (burnAmount > 0) {
            _burn(msg.sender, burnAmount);
            emit TokensBurned(msg.sender, burnAmount);
        }

        if (redistributeAmount > 0) {
            _transfer(msg.sender, redistributionAddress, redistributeAmount);
            emit TokensRedistributed(redistributionAddress, redistributeAmount);
        }

        if (rewardAmount > 0) {
            _transfer(msg.sender, stakingRewardsAddress, rewardAmount);
            emit TokensRedistributed(stakingRewardsAddress, rewardAmount);
        }

        return super.transfer(to, netAmount);
    }

    // Vesting Functions
    function createVestingSchedule(
        address beneficiary,
        uint256 totalAmount,
        uint256 startTime,
        uint256 duration,
        uint256 cliff
    ) external override {
        require(accessControl.hasRole(accessControl.VESTING_MANAGER_ROLE(), msg.sender), "Unauthorized");
        require(beneficiary != address(0), "Zero address: beneficiary");
        require(totalAmount > 0 && duration > 0 && startTime > 0, "Invalid schedule");
        require(totalSupply() + totalAmount <= maxSupply, "Exceeds max supply");
        require(vestingSchedules[beneficiary].totalAmount == 0, "Vesting schedule exists");

        _mint(address(this), totalAmount);

        vestingSchedules[beneficiary] = VestingSchedule({
            totalAmount: totalAmount,
            releasedAmount: 0,
            startTime: startTime,
            duration: duration,
            cliff: cliff
        });

        emit VestingScheduleCreated(beneficiary, totalAmount, startTime, duration, cliff);
    }

    function claimVestedTokens() external override whenNotPaused nonReentrant {
        VestingSchedule storage schedule = vestingSchedules[msg.sender];
        require(schedule.totalAmount > 0, "No vesting schedule");
        require(block.timestamp >= schedule.startTime + schedule.cliff, "Cliff not reached");

        uint256 vested = _vestedAmount(schedule);
        require(vested > schedule.releasedAmount, "No claimable tokens");

        uint256 claimable = vested - schedule.releasedAmount;
        schedule.releasedAmount += claimable;

        _transfer(address(this), msg.sender, claimable);
        emit TokensClaimed(msg.sender, claimable);
    }

    function revokeVestingSchedule(address beneficiary) external {
        require(accessControl.hasRole(accessControl.VESTING_MANAGER_ROLE(), msg.sender), "Unauthorized");
        VestingSchedule storage schedule = vestingSchedules[beneficiary];
        require(schedule.totalAmount > 0, "No vesting schedule");

        uint256 unvested = schedule.totalAmount - schedule.releasedAmount;
        delete vestingSchedules[beneficiary];

        _burn(address(this), unvested);
        emit VestingScheduleRevoked(beneficiary, unvested);
    }

    function getVestingSchedule(address beneficiary) external view override returns (VestingSchedule memory) {
        return vestingSchedules[beneficiary];
    }

    function _vestedAmount(VestingSchedule memory schedule) internal view returns (uint256) {
        if (block.timestamp < schedule.startTime + schedule.cliff) return 0;
        if (block.timestamp >= schedule.startTime + schedule.duration) return schedule.totalAmount;

        uint256 elapsed = block.timestamp - schedule.startTime;
        return (schedule.totalAmount * elapsed) / schedule.duration;
    }

    // Admin Functions
    function setRates(uint256 _burnRate, uint256 _redistributionRate, uint256 _stakingRewardsRate) external override {
        require(accessControl.hasRole(accessControl.GOVERNANCE_ROLE(), msg.sender), "Unauthorized");
        require(_burnRate + _redistributionRate + _stakingRewardsRate <= 10000, "Invalid rates");

        burnRate = _burnRate;
        redistributionRate = _redistributionRate;
        stakingRewardsRate = _stakingRewardsRate;

        emit RatesSet(_burnRate, _redistributionRate, _stakingRewardsRate);
    }

    function setMaxSupply(uint256 newMaxSupply) external override {
        require(accessControl.hasRole(accessControl.DEFAULT_ADMIN_ROLE(), msg.sender), "Unauthorized");
        require(newMaxSupply >= totalSupply(), "Invalid max supply");

        uint256 oldMaxSupply = maxSupply;
        maxSupply = newMaxSupply;

        emit MaxSupplyUpdated(oldMaxSupply, newMaxSupply);
    }

    function pause() external override {
        require(accessControl.hasRole(accessControl.EMERGENCY_ROLE(), msg.sender), "Unauthorized");
        _pause();
    }

    function unpause() external override {
        require(accessControl.hasRole(accessControl.EMERGENCY_ROLE(), msg.sender), "Unauthorized");
        _unpause();
    }

    function getPrice() external view override returns (uint256) {
        (, int256 answer, , uint256 updatedAt, ) = priceFeed.latestRoundData();
        require(answer > 0, "Invalid oracle price");
        require(block.timestamp - updatedAt < 1 hours, "Price is stale");
        return uint256(answer);
    }

    function emergencyWithdraw(address token, address to, uint256 amount) external override nonReentrant {
        require(accessControl.hasRole(accessControl.EMERGENCY_ROLE(), msg.sender), "Unauthorized");
        require(to != address(0), "Zero address: recipient");

        uint256 balance = IERC20(token).balanceOf(address(this));
        require(amount <= balance, "Insufficient balance");

        bool success = IERC20(token).transfer(to, amount);
        require(success, "Transfer failed");

        emit EmergencyWithdraw(token, to, amount);
    }
}
