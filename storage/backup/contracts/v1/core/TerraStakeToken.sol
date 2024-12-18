// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20VotesUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
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
    TerraStakeAccessControl public accessControl;

    uint256 public override maxSupply;
    uint256 public override burnRate;           // in basis points (e.g., 100 = 1%)
    uint256 public override redistributionRate; // in basis points
    address public redistributionAddress;
    AggregatorV3Interface public priceFeed;

    mapping(address => VestingSchedule) private vestingSchedules;

    // Initialization
    function initialize(
        address _accessControl,
        uint256 initialSupply,
        address _redistributionAddress
    ) external initializer {
        if (_accessControl == address(0)) revert ZeroAddress();
        if (_redistributionAddress == address(0)) revert ZeroAddress();

        string memory _name = "TerraStake";
        string memory _symbol = "TSTAKE";
        uint256 _maxSupply = 2_000_000_000 * 10**18;

        __ERC20_init(_name, _symbol);
        __ERC20Votes_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        accessControl = TerraStakeAccessControl(_accessControl);
        maxSupply = _maxSupply;

        address admin = msg.sender;
        if (!accessControl.hasRole(accessControl.DEFAULT_ADMIN_ROLE(), admin)) revert InvalidAdminAddress();

        // Mint initial supply directly
        super._mint(admin, initialSupply);

        burnRate = 0;
        redistributionRate = 0;
        redistributionAddress = _redistributionAddress;
    }

    // Core Token Operations
    function mint(address to, uint256 amount) external override whenNotPaused nonReentrant {
        if (!accessControl.hasRole(accessControl.MINTER_ROLE(), msg.sender)) revert Unauthorized();
        if (to == address(0)) revert ZeroAddress();
        if (totalSupply() + amount > maxSupply) revert MintAmountExceedsMaxSupply();

        super._mint(to, amount);
    }

    function burn(address from, uint256 amount) external override whenNotPaused nonReentrant {
        if (!accessControl.hasRole(accessControl.DEFAULT_ADMIN_ROLE(), msg.sender)) revert Unauthorized();
        if (from == address(0)) revert ZeroAddress();
        if (balanceOf(from) < amount) revert BurnAmountExceedsBalance();

        super._burn(from, amount);
        emit TokensBurned(from, amount);
    }

    function transfer(address to, uint256 amount)
        public
        override(ERC20Upgradeable, ITerraStakeToken)
        whenNotPaused
        returns (bool)
    {
        address sender = _msgSender();

        uint256 _burnAmount = (amount * burnRate) / 10000;
        uint256 _redistributeAmount = (amount * redistributionRate) / 10000;
        uint256 netAmount = amount - _burnAmount - _redistributeAmount;

        if (_burnAmount > 0) {
            super._burn(sender, _burnAmount);
            emit TokensBurned(sender, _burnAmount);
        }

        if (_redistributeAmount > 0) {
            super.transfer(redistributionAddress, _redistributeAmount);
            emit TokensRedistributed(redistributionAddress, _redistributeAmount);
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
        if (!accessControl.hasRole(accessControl.VESTING_MANAGER_ROLE(), msg.sender)) revert Unauthorized();
        if (beneficiary == address(0)) revert ZeroAddress();
        if (totalAmount == 0 || duration == 0 || startTime == 0) revert InvalidRate();
        if (totalSupply() + totalAmount > maxSupply) revert MintAmountExceedsMaxSupply();
        if (vestingSchedules[beneficiary].totalAmount > 0) revert NoVestingSchedule();

        super._mint(address(this), totalAmount);

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
        if (schedule.totalAmount == 0) revert NoVestingSchedule();
        if (block.timestamp < schedule.startTime + schedule.cliff) revert CliffNotReached();

        uint256 vested = _vestedAmount(schedule);
        if (vested <= schedule.releasedAmount) revert NoClaimableTokens();

        uint256 claimable = vested - schedule.releasedAmount;
        schedule.releasedAmount += claimable;

        super.transfer(msg.sender, claimable);
        emit TokensClaimed(msg.sender, claimable);
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
    function setRates(uint256 _burnRate, uint256 _redistributionRate) external override {
        if (!accessControl.hasRole(accessControl.GOVERNANCE_ROLE(), msg.sender)) revert Unauthorized();
        if (_burnRate + _redistributionRate > 10000) revert InvalidRate();
        burnRate = _burnRate;
        redistributionRate = _redistributionRate;
        emit RatesUpdated(_burnRate, _redistributionRate);
    }

    function setMaxSupply(uint256 newMaxSupply) external override {
        if (!accessControl.hasRole(accessControl.DEFAULT_ADMIN_ROLE(), msg.sender)) revert Unauthorized();
        if (newMaxSupply < totalSupply()) revert NewMaxSupplyBelowTotalSupply();
        maxSupply = newMaxSupply;
        emit MaxSupplyUpdated(newMaxSupply);
    }

    function pause() external override {
        if (!accessControl.hasRole(accessControl.EMERGENCY_ROLE(), msg.sender)) revert Unauthorized();
        _pause();
    }

    function unpause() external override {
        if (!accessControl.hasRole(accessControl.EMERGENCY_ROLE(), msg.sender)) revert Unauthorized();
        _unpause();
    }

    function getPrice() external view override returns (uint256) {
        if (address(priceFeed) == address(0)) revert ZeroAddress();
        (, int256 answer, , , ) = priceFeed.latestRoundData();
        if (answer <= 0) revert InvalidRate();
        return uint256(answer);
    }

    function emergencyWithdraw(address token, address to, uint256 amount) external override nonReentrant {
        if (!accessControl.hasRole(accessControl.EMERGENCY_ROLE(), msg.sender)) revert Unauthorized();
        if (to == address(0)) revert ZeroAddress();
        bool success = IERC20(token).transfer(to, amount);
        if (!success) revert Unauthorized();
        emit EmergencyWithdraw(token, to, amount);
    }

    // Overriding _update from ERC20VotesUpgradeable for customization if needed
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20VotesUpgradeable)
    {
        // Add custom logic here if needed
        super._update(from, to, value);
    }

    // Expose AccessControl Role Getters
    function MINTER_ROLE() external view override returns (bytes32) {
        return accessControl.MINTER_ROLE();
    }

    function GOVERNANCE_ROLE() external view override returns (bytes32) {
        return accessControl.GOVERNANCE_ROLE();
    }

    function VESTING_MANAGER_ROLE() external view override returns (bytes32) {
        return accessControl.VESTING_MANAGER_ROLE();
    }

    function DEFAULT_ADMIN_ROLE() external view override returns (bytes32) {
        return accessControl.DEFAULT_ADMIN_ROLE();
    }

    function EMERGENCY_ROLE() external view override returns (bytes32) {
        return accessControl.EMERGENCY_ROLE();
    }
}
