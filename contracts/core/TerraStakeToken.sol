// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";

contract TerraStakeToken is Initializable, ERC20Upgradeable, AccessControlUpgradeable, PausableUpgradeable {
    // Token Metadata
    string public constant TOKEN_NAME = "TerraStake Token";
    string public constant TOKEN_SYMBOL = "TSTAKE";
    uint256 public constant MAX_CAP = 2_000_000_000 * 10**18;

    // Tokenomics Parameters
    uint256 public maxSupply;
    uint256 public burnRate;
    uint256 public redistributionRate;
    uint256 public stakingRewardsRate;

    // Addresses for Redistribution and Staking Rewards
    address public redistributionAddress;
    address public stakingRewardsAddress;

    // Vesting Schedule Mapping
    struct VestingSchedule {
        uint256 totalAmount;
        uint256 releasedAmount;
        uint256 startTime;
        uint256 duration;
        uint256 cliff;
    }
    mapping(address => VestingSchedule) private vestingSchedules;

    // Roles
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant VESTING_MANAGER_ROLE = keccak256("VESTING_MANAGER_ROLE");

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

    /// @notice Initializes the contract
    function initialize(
        uint256 maxSupply_,
        address admin,
        address _redistributionAddress,
        address _stakingRewardsAddress
    ) external initializer {
        require(admin != address(0), "Admin address cannot be zero");
        require(maxSupply_ == MAX_CAP, "Invalid max supply");
        require(_redistributionAddress != address(0) && _stakingRewardsAddress != address(0), "Invalid address");

        __ERC20_init(TOKEN_NAME, TOKEN_SYMBOL);
        __AccessControl_init();
        __Pausable_init();

        maxSupply = MAX_CAP;
        redistributionAddress = _redistributionAddress;
        stakingRewardsAddress = _stakingRewardsAddress;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, admin);
        _grantRole(VESTING_MANAGER_ROLE, admin);
    }

    /// @notice Mints tokens to a specified address
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        require(totalSupply() + amount <= maxSupply, "Mint exceeds max supply");
        _mint(to, amount);
    }

    /// @notice Burns tokens from a specified address
    function burn(uint256 amount) external {
        require(balanceOf(msg.sender) >= amount, "Burn exceeds balance");
        _burn(msg.sender, amount);
    }

    /// @notice Updates burn, redistribution, and staking rates
    function setRates(
        uint256 _burnRate,
        uint256 _redistributionRate,
        uint256 _stakingRewardsRate
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(_burnRate + _redistributionRate + _stakingRewardsRate <= 10000, "Rates exceed 100%");
        burnRate = _burnRate;
        redistributionRate = _redistributionRate;
        stakingRewardsRate = _stakingRewardsRate;

        emit RatesUpdated(_burnRate, _redistributionRate, _stakingRewardsRate);
    }

    /// @notice Updates the maximum supply of tokens
    function setMaxSupply(uint256 newMaxSupply) external onlyRole(GOVERNANCE_ROLE) {
        require(newMaxSupply >= totalSupply(), "New max supply below total supply");
        uint256 oldMaxSupply = maxSupply;
        maxSupply = newMaxSupply;

        emit MaxSupplyUpdated(oldMaxSupply, newMaxSupply);
    }

    /// @notice Creates a vesting schedule for a beneficiary
    function createVestingSchedule(
        address beneficiary,
        uint256 totalAmount,
        uint256 startTime,
        uint256 duration,
        uint256 cliff
    ) external onlyRole(VESTING_MANAGER_ROLE) {
        require(vestingSchedules[beneficiary].totalAmount == 0, "Vesting schedule exists");
        require(totalAmount > 0 && duration > 0, "Invalid vesting parameters");
        require(balanceOf(address(this)) >= totalAmount, "Insufficient balance to vest");  // Ensure contract has enough tokens

        vestingSchedules[beneficiary] = VestingSchedule({
            totalAmount: totalAmount,
            releasedAmount: 0,
            startTime: startTime,
            duration: duration,
            cliff: cliff
        });

        emit VestingScheduleCreated(beneficiary, totalAmount, startTime, duration, cliff);
    }

    /// @notice Allows beneficiaries to claim vested tokens
    function claimVestedTokens() external {
        VestingSchedule storage schedule = vestingSchedules[msg.sender];
        require(schedule.totalAmount > 0, "No vesting schedule");
        require(block.timestamp >= schedule.startTime + schedule.cliff, "Cliff not reached");

        uint256 vestedAmount = _calculateClaimableTokens(schedule);
        require(vestedAmount > 0, "No claimable tokens");

        schedule.releasedAmount += vestedAmount;
        _transfer(address(this), msg.sender, vestedAmount);  // Transfer instead of minting

        emit TokensClaimed(msg.sender, vestedAmount);
    }

    /// @dev Calculates the claimable tokens for a vesting schedule
    function _calculateClaimableTokens(VestingSchedule storage schedule)
        internal
        view
        returns (uint256)
    {
        uint256 elapsedTime = block.timestamp - schedule.startTime;
        uint256 totalVested = (schedule.totalAmount * elapsedTime) / schedule.duration;
        return totalVested > schedule.releasedAmount ? totalVested - schedule.releasedAmount : 0;
    }

    /// @notice Pauses the contract
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /// @notice Unpauses the contract
    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    /// @notice Emergency withdrawal of tokens
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyRole(EMERGENCY_ROLE) {
        require(to != address(0), "Invalid address");
        require(token != address(this), "Cannot withdraw TSTAKE");

        IERC20(token).transfer(to, amount);
        emit EmergencyWithdraw(token, to, amount);
    }

    /// @notice Transfers tokens for redistribution
    function redistribute(uint256 amount) external onlyRole(GOVERNANCE_ROLE) {
        require(amount > 0, "Amount must be greater than zero");
        require(balanceOf(address(this)) >= amount, "Insufficient balance for redistribution");
        _transfer(address(this), redistributionAddress, amount);
    }

    /// @notice Transfers tokens for staking rewards
    function sendToStakingRewards(uint256 amount) external onlyRole(GOVERNANCE_ROLE) {
        require(amount > 0, "Amount must be greater than zero");
        require(balanceOf(address(this)) >= amount, "Insufficient balance for staking rewards");
        _transfer(address(this), stakingRewardsAddress, amount);
    }
}