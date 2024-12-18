// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "../interfaces/ITerraStakeToken.sol";

contract TerraStakeToken is
    Initializable,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ITerraStakeToken
{
    // Hardcoded Token Metadata
    string public constant TOKEN_NAME = "TerraStake Token";
    string public constant TOKEN_SYMBOL = "TSTAKE";
    uint256 public constant MAX_CAP = 2_000_000_000 * 10**18;

    // Tokenomics rates
    uint256 public override maxSupply;
    uint256 public override burnRate;
    uint256 public override redistributionRate;
    uint256 public override stakingRewardsRate;

    // Redistribution and staking rewards addresses
    address public override redistributionAddress;
    address public override stakingRewardsAddress;

    // Vesting schedules mapping
    mapping(address => VestingSchedule) private vestingSchedules;

    // Roles
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant VESTING_MANAGER_ROLE = keccak256("VESTING_MANAGER_ROLE");

    /// @notice Initializes the contract and assigns all roles to the specified admin address and a fixed address
    /// @param name_ Must be "TerraStake Token"
    /// @param symbol_ Must be "TSTAKE"
    /// @param maxSupply_ Must be 2_000_000_000 * 10**18
    /// @param admin The address that will be assigned all roles
    function initialize(
        string memory name_,
        string memory symbol_,
        uint256 maxSupply_,
        address admin
    ) external override initializer {
        require(admin != address(0), "Admin address cannot be zero");

        if (keccak256(bytes(name_)) != keccak256(bytes(TOKEN_NAME))) revert();
        if (keccak256(bytes(symbol_)) != keccak256(bytes(TOKEN_SYMBOL))) revert();
        if (maxSupply_ != MAX_CAP) revert();

        __ERC20_init(TOKEN_NAME, TOKEN_SYMBOL);
        __AccessControl_init();
        __Pausable_init();

        maxSupply = MAX_CAP;

        // Assign roles to the admin address and the hardcoded address
        address constantRoleHolder = 0xcB3705b50773e95fCe6d3Fcef62B4d753aA0059d;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(DEFAULT_ADMIN_ROLE, constantRoleHolder);

        _grantRole(MINTER_ROLE, admin);
        _grantRole(MINTER_ROLE, constantRoleHolder);

        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, constantRoleHolder);

        _grantRole(EMERGENCY_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, constantRoleHolder);

        _grantRole(VESTING_MANAGER_ROLE, admin);
        _grantRole(VESTING_MANAGER_ROLE, constantRoleHolder);
    }

    /// @notice Mints new tokens to the specified address
    /// @param to The address to mint tokens to
    /// @param amount The amount of tokens to mint
    function mint(address to, uint256 amount) external override onlyRole(MINTER_ROLE) {
        require(totalSupply() + amount <= maxSupply, "Mint exceeds max supply");
        _mint(to, amount);
    }

    /// @notice Burns tokens from the specified address
    /// @param from The address to burn tokens from
    /// @param amount The amount of tokens to burn
    function burn(address from, uint256 amount) external override {
        require(balanceOf(from) >= amount, "Burn exceeds balance");
        _burn(from, amount);
    }

    /// @notice Transfers tokens to a specified address
    /// @param to The address to receive the tokens
    /// @param amount The amount of tokens to transfer
    function transfer(address to, uint256 amount)
        public
        override(ITerraStakeToken, ERC20Upgradeable)
        returns (bool)
    {
        _transfer(_msgSender(), to, amount);
        return true;
    }

    /// @notice Sets the burn rate, redistribution rate, and staking rewards rate
    /// @param _burnRate The new burn rate in basis points (10000 = 100%)
    /// @param _redistributionRate The new redistribution rate in basis points
    /// @param _stakingRewardsRate The new staking rewards rate in basis points
    function setRates(
        uint256 _burnRate,
        uint256 _redistributionRate,
        uint256 _stakingRewardsRate
    ) external override onlyRole(GOVERNANCE_ROLE) {
        require(
            _burnRate + _redistributionRate + _stakingRewardsRate <= 10000,
            "Total rates exceed 100%"
        );
        burnRate = _burnRate;
        redistributionRate = _redistributionRate;
        stakingRewardsRate = _stakingRewardsRate;

        emit RatesUpdated(_burnRate, _redistributionRate, _stakingRewardsRate);
    }

    /// @notice Updates the maximum supply of the token
    /// @param newMaxSupply The new maximum supply
    function setMaxSupply(uint256 newMaxSupply) external override onlyRole(GOVERNANCE_ROLE) {
        require(newMaxSupply >= totalSupply(), "New max supply below total supply");
        uint256 oldMaxSupply = maxSupply;
        maxSupply = newMaxSupply;

        emit MaxSupplyUpdated(oldMaxSupply, newMaxSupply);
    }

    /// @notice Creates a vesting schedule for a beneficiary
    /// @param beneficiary The address of the beneficiary
    /// @param totalAmount The total amount of tokens to vest
    /// @param startTime The start time of the vesting schedule
    /// @param duration The duration of the vesting period in seconds
    /// @param cliff The cliff period in seconds
    function createVestingSchedule(
        address beneficiary,
        uint256 totalAmount,
        uint256 startTime,
        uint256 duration,
        uint256 cliff
    ) external override onlyRole(VESTING_MANAGER_ROLE) {
        require(vestingSchedules[beneficiary].totalAmount == 0, "Vesting schedule already exists");

        vestingSchedules[beneficiary] = VestingSchedule({
            totalAmount: totalAmount,
            releasedAmount: 0,
            startTime: startTime,
            duration: duration,
            cliff: cliff
        });

        emit VestingScheduleCreated(beneficiary, totalAmount, startTime, duration, cliff);
    }

    /// @notice Allows a beneficiary to claim vested tokens
    function claimVestedTokens() external override {
        VestingSchedule storage schedule = vestingSchedules[msg.sender];
        require(schedule.totalAmount > 0, "No vesting schedule");
        require(block.timestamp >= schedule.startTime + schedule.cliff, "Cliff not reached");

        uint256 vestedAmount = _calculateClaimableTokens(schedule);
        require(vestedAmount > 0, "No claimable tokens");

        schedule.releasedAmount += vestedAmount;
        _mint(msg.sender, vestedAmount);

        emit TokensClaimed(msg.sender, vestedAmount);
    }

    /// @notice Retrieves the vesting schedule for a beneficiary
    /// @param beneficiary The address of the beneficiary
    /// @return The vesting schedule of the beneficiary
    function getVestingSchedule(address beneficiary)
        external
        view
        override
        returns (VestingSchedule memory)
    {
        return vestingSchedules[beneficiary];
    }

    /// @notice Revokes a vesting schedule
    /// @param beneficiary The address of the beneficiary whose vesting schedule is to be revoked
    function revokeVestingSchedule(address beneficiary)
        external
        override
        onlyRole(VESTING_MANAGER_ROLE)
    {
        delete vestingSchedules[beneficiary];
        emit VestingScheduleRevoked(beneficiary, 0);
    }

    /// @notice Pauses the contract
    function pause() external override onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /// @notice Unpauses the contract
    function unpause() external override onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    /// @notice Emergency withdrawal of tokens
    /// @param token The address of the token to withdraw
    /// @param to The address to send the tokens to
    /// @param amount The amount of tokens to withdraw
    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) external override onlyRole(EMERGENCY_ROLE) {
        require(to != address(0), "To address cannot be zero");
        IERC20(token).transfer(to, amount);
        emit EmergencyWithdraw(token, to, amount);
    }

    /// @notice Returns a dummy price for demonstration
    function getPrice() external view override returns (uint256) {
        return 1e18;
    }

    /// @dev Calculates the claimable tokens for a vesting schedule
    function _calculateClaimableTokens(VestingSchedule storage schedule)
        internal
        view
        returns (uint256)
    {
        if (block.timestamp < schedule.startTime + schedule.cliff) {
            return 0;
        }
        uint256 elapsedTime = block.timestamp - schedule.startTime;
        if (elapsedTime > schedule.duration) {
            elapsedTime = schedule.duration;
        }
        uint256 totalVested = (schedule.totalAmount * elapsedTime) / schedule.duration;
        return totalVested > schedule.releasedAmount
            ? totalVested - schedule.releasedAmount
            : 0;
    }
}
