// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";

contract TerraStakeToken is
    Initializable,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable
{
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
        uint256 totalAmount;        // Total tokens to vest
        uint256 releasedAmount;     // Tokens already claimed
        uint256 startTime;          // Vesting start time
        uint256 duration;           // Vesting duration in seconds
        uint256 cliff;              // Cliff period in seconds
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
        string memory name_,
        string memory symbol_,
        uint256 maxSupply_,
        address admin
    ) external initializer {
        require(admin != address(0), "Admin address cannot be zero");
        require(keccak256(bytes(name_)) == keccak256(bytes(TOKEN_NAME)), "Invalid token name");
        require(keccak256(bytes(symbol_)) == keccak256(bytes(TOKEN_SYMBOL)), "Invalid token symbol");
        require(maxSupply_ == MAX_CAP, "Invalid max supply");

        __ERC20_init(TOKEN_NAME, TOKEN_SYMBOL);
        __AccessControl_init();
        __Pausable_init();

        maxSupply = MAX_CAP;

        address constantRoleHolder = 0xcB3705b50773e95fCe6d3Fcef62B4d753aA0059d;

        bytes32[4] memory roles = [
            MINTER_ROLE,
            GOVERNANCE_ROLE,
            EMERGENCY_ROLE,
            VESTING_MANAGER_ROLE
        ];

        for (uint256 i = 0; i < roles.length; i++) {
            _grantRole(roles[i], admin);
            _grantRole(roles[i], constantRoleHolder);
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(DEFAULT_ADMIN_ROLE, constantRoleHolder);
    }

    /// @notice Mints tokens to a specified address
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        require(totalSupply() + amount <= maxSupply, "Mint exceeds max supply");
        _mint(to, amount);
    }

    /// @notice Burns tokens from a specified address
    function burn(address from, uint256 amount) external {
        require(balanceOf(from) >= amount, "Burn exceeds balance");
        _burn(from, amount);
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
        _mint(msg.sender, vestedAmount);

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
        IERC20(token).transfer(to, amount);

        emit EmergencyWithdraw(token, to, amount);
    }
}
