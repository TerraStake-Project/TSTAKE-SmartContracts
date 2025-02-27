// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC1155/IERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import "./interfaces/ITerraStakeStaking.sol";
import "./interfaces/ITerraStakeRewardDistributor.sol";
import "./interfaces/ITerraStakeProjects.sol";
import "./interfaces/ITerraStakeGovernance.sol";
import "./interfaces/ITerraStakeSlashing.sol";

/**
 * @title TerraStakeStaking
 * @notice Official staking contract for the TerraStake ecosystem.
 * @dev Implements DAO governance integration and follows OZ 5.2.x patterns
 */
contract TerraStakeStaking is 
    Initializable, 
    ITerraStakeStaking, 
    AccessControlEnumerableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    PausableUpgradeable, 
    UUPSUpgradeable,
    ERC165Upgradeable 
{
    // -------------------------------------------
    // 🔹 Custom Errors
    // -------------------------------------------
    error ZeroAmount();
    error InsufficientStakingDuration(uint256 minimum, uint256 provided);
    error ProjectDoesNotExist(uint256 projectId);
    error NoActiveStakingPosition(address user, uint256 projectId);
    error TransferFailed(address token, address from, address to, uint256 amount);
    error InvalidAddress(string parameter, address provided);
    error InvalidParameter(string parameter, uint256 provided);
    error UnauthorizedCaller(address caller, string requiredRole);
    error StakingLocked(uint256 releaseTime);
    error GovernanceViolation(address user);
    error SlashingFailed(address validator, uint256 amount);
    error AlreadyValidator(address validator);
    error NotValidator(address account);
    error DistributionFailed(uint256 amount);
    error EmergencyPaused();
    error ActionNotPermittedForValidator();
    error RateTooHigh(uint256 provided, uint256 maximum);
    error InvalidTierConfiguration();

    // -------------------------------------------
    // 🔹 Constants
    // -------------------------------------------
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    
    uint256 public constant BASE_APR = 10; // 10% APR base
    uint256 public constant BOOSTED_APR = 20; // 20% APR if TVL < 1M TSTAKE
    uint256 public constant NFT_APR_BOOST = 10;
    uint256 public constant LP_APR_BOOST = 15;
    uint256 public constant BASE_PENALTY_PERCENT = 10;
    uint256 public constant MAX_PENALTY_PERCENT = 30;
    uint256 public constant LOW_STAKING_THRESHOLD = 1_000_000 * 10**18;
    uint256 public constant GOVERNANCE_VESTING_PERIOD = 7 days;
    uint256 public constant MAX_LIQUIDITY_RATE = 10;

    // -------------------------------------------
    // 🔹 State Variables
    // -------------------------------------------
    // Core contracts
    IERC1155Upgradeable public nftContract;
    IERC20Upgradeable public stakingToken;
    ITerraStakeRewardDistributor public rewardDistributor;
    ITerraStakeProjects public projectsContract;
    ITerraStakeGovernance public governanceContract;
    ITerraStakeSlashing public slashingContract;
    address public liquidityPool;
    
    // Protocol parameters
    uint256 public liquidityInjectionRate; // % of rewards reinjected
    bool public autoLiquidityEnabled;
    uint256 public halvingPeriod; // Every 2 years
    uint256 public lastHalvingTime;
    uint256 public halvingEpoch;
    uint256 public proposalNonce; // For tracking governance proposals
    uint256 public validatorThreshold; // Min amount to become validator
    
    // Staking user data
    mapping(address => mapping(uint256 => StakingPosition)) private _stakingPositions;
    mapping(address => uint256) private _governanceVotes;
    mapping(address => uint256) private _stakingBalance; // Total staked per user
    mapping(address => bool) private _governanceViolators;
    mapping(address => bool) private _validators; // Approved validators
    
    // Protocol state
    uint256 private _totalStaked;
    StakingTier[] private _tiers;
    
    // -------------------------------------------
    // 🔹 Initializer & Configuration
    // -------------------------------------------
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @notice Initialize the staking contract
     * @param _nftContract Address of the NFT contract
     * @param _stakingToken Address of the staking token
     * @param _rewardDistributor Address of the reward distributor
     * @param _liquidityPool Address of the liquidity pool
     * @param _projectsContract Address of the projects contract
     * @param _governanceContract Address of the governance contract
     * @param _admin Address of the initial admin
     */
    function initialize(
        address _nftContract,
        address _stakingToken,
        address _rewardDistributor,
        address _liquidityPool,
        address _projectsContract,
        address _governanceContract,
        address _admin
    ) external initializer {
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        __ERC165_init();
        
        if (_nftContract == address(0)) revert InvalidAddress("nftContract", _nftContract);
        if (_stakingToken == address(0)) revert InvalidAddress("stakingToken", _stakingToken);
        if (_rewardDistributor == address(0)) revert InvalidAddress("rewardDistributor", _rewardDistributor);
        if (_liquidityPool == address(0)) revert InvalidAddress("liquidityPool", _liquidityPool);
        if (_projectsContract == address(0)) revert InvalidAddress("projectsContract", _projectsContract);
        if (_governanceContract == address(0)) revert InvalidAddress("governanceContract", _governanceContract);
        if (_admin == address(0)) revert InvalidAddress("admin", _admin);
        
        nftContract = IERC1155Upgradeable(_nftContract);
        stakingToken = IERC20Upgradeable(_stakingToken);
        rewardDistributor = ITerraStakeRewardDistributor(_rewardDistributor);
        liquidityPool = _liquidityPool;
        projectsContract = ITerraStakeProjects(_projectsContract);
        governanceContract = ITerraStakeGovernance(_governanceContract);
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(GOVERNANCE_ROLE, _governanceContract);
        _grantRole(UPGRADER_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
        
        halvingPeriod = 730 days; // 2 years
        lastHalvingTime = block.timestamp;
        halvingEpoch = 0;
        liquidityInjectionRate = 5; // 5% of rewards reinjected
        autoLiquidityEnabled = true;
        validatorThreshold = 100_000 * 10**18; // 100k tokens to become validator
        
        // Initialize tiers
        _tiers.push(StakingTier(30 days, 100, false));
        _tiers.push(StakingTier(90 days, 150, true));
        _tiers.push(StakingTier(180 days, 200, true));
        _tiers.push(StakingTier(365 days, 300, true));
    }
    
    /**
     * @notice Set the slashing contract
     * @param _slashingContract Address of the slashing contract
     */
    function setSlashingContract(address _slashingContract) external onlyRole(GOVERNANCE_ROLE) {
        if (_slashingContract == address(0)) revert InvalidAddress("slashingContract", _slashingContract);
        slashingContract = ITerraStakeSlashing(_slashingContract);
        _grantRole(SLASHER_ROLE, _slashingContract);
        
        emit SlashingContractUpdated(_slashingContract);
    }
    
    /**
     * @notice Authorize contract upgrades
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyRole(UPGRADER_ROLE) 
    {}
    
    // -------------------------------------------
    // 🔹 Staking Operations
    // -------------------------------------------
    
    /**
     * @notice Stake tokens for a project
     * @param projectId ID of the project
     * @param amount Amount to stake
     * @param duration Duration to stake for
     * @param isLP Whether staking LP tokens
     * @param autoCompound Whether to automatically compound rewards
     */
    function stake(
        uint256 projectId,
        uint256 amount,
        uint256 duration,
        bool isLP,
        bool autoCompound
    ) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (duration < 30 days) revert InsufficientStakingDuration(30 days, duration);
        if (!projectsContract.projectExists(projectId)) revert ProjectDoesNotExist(projectId);
        
        // Check if user has an NFT boost
        bool hasNFTBoost = nftContract.balanceOf(msg.sender, 1) > 0;
        
        // Get staking position
        StakingPosition storage position = _stakingPositions[msg.sender][projectId];
        
        // If position exists, claim rewards first
        if (position.amount > 0) {
            _claimRewards(msg.sender, projectId);
        } else {
            // New position
            position.stakingStart = block.timestamp;
            position.projectId = projectId;
        }
        
        // Update position
        position.amount += amount;
        position.lastCheckpoint = block.timestamp;
        position.duration = duration;
        position.isLPStaker = isLP;
        position.hasNFTBoost = hasNFTBoost;
        position.autoCompounding = autoCompound;
        
        // Update totals
        _totalStaked += amount;
        _stakingBalance[msg.sender] += amount;
        
        // Update governance votes using quadratic voting power
        _governanceVotes[msg.sender] = _calculateVotingPower(msg.sender);
        
        // Transfer tokens to contract
        if (!stakingToken.transferFrom(msg.sender, address(this), amount)) 
            revert TransferFailed(address(stakingToken), msg.sender, address(this), amount);
        
        // Update project stats in projects contract
        projectsContract.updateProjectStaking(projectId, amount, true);
        
        // Mark as validator if staking enough
        if (_stakingBalance[msg.sender] >= validatorThreshold && !_validators[msg.sender]) {
            _validators[msg.sender] = true;
            emit ValidatorStatusChanged(msg.sender, true);
        }
        
        emit Staked(msg.sender, projectId, amount, duration);
    }
    
    /**
     * @notice Unstake tokens from a project
     * @param projectId ID of the project
     */
    function unstake(uint256 projectId) external nonReentrant whenNotPaused {
        StakingPosition storage position = _stakingPositions[msg.sender][projectId];
        if (position.amount == 0) revert NoActiveStakingPosition(msg.sender, projectId);
        
        // Calculate if we need to apply early unstaking penalty
        uint256 stakingEndTime = position.stakingStart + position.duration;
        uint256 amount = position.amount;
        uint256 penalty = 0;
        
        // If unstaking early, apply penalty
        if (block.timestamp < stakingEndTime) {
            uint256 timeRemaining = stakingEndTime - block.timestamp;
            uint256 totalDuration = position.duration;
            
            // Calculate penalty percentage (linear from BASE_PENALTY to MAX_PENALTY)
            uint256 penaltyPercent = BASE_PENALTY_PERCENT + 
                ((timeRemaining * (MAX_PENALTY_PERCENT - BASE_PENALTY_PERCENT)) / totalDuration);
            
            penalty = (amount * penaltyPercent) / 100;
            amount -= penalty;
            
            // If user has governance rights, they lose them for early withdrawal
            if (_hasGovernanceRights(msg.sender)) {
                _governanceViolators[msg.sender] = true;
                emit GovernanceRightsUpdated(msg.sender, false);
            }
        }
        
        // Claim any pending rewards first
        _claimRewards(msg.sender, projectId);
        
        // Update totals
        _totalStaked -= position.amount;
        _stakingBalance[msg.sender] -= position.amount;
        
        // Update governance voting power
        _governanceVotes[msg.sender] = _calculateVotingPower(msg.sender);
        
        // Update project stats
        projectsContract.updateProjectStaking(projectId, position.amount,
/**
     * @notice Get all active staking positions for a user
     * @param user Address of the user
     * @return projectIds Array of project IDs
     * @return positions Array of staking positions
     */
    function getUserStakingPositions(address user) external view returns (
        uint256[] memory projectIds,
        StakingPosition[] memory positions
    ) {
        uint256[] memory userProjects = projectsContract.getProjectsForStaker(user);
        
        uint256 activeCount = 0;
        for (uint256 i = 0; i < userProjects.length; i++) {
            if (_stakingPositions[user][userProjects[i]].amount > 0) {
                activeCount++;
            }
        }
        
        projectIds = new uint256[](activeCount);
        positions = new StakingPosition[](activeCount);
        
        uint256 index = 0;
        for (uint256 i = 0; i < userProjects.length; i++) {
            uint256 projectId = userProjects[i];
            StakingPosition memory position = _stakingPositions[user][projectId];
            
            if (position.amount > 0) {
                projectIds[index] = projectId;
                positions[index] = position;
                index++;
            }
        }
    }
    
    /**
     * @notice Check if an address is a validator
     * @param account Address to check
     * @return isValidator Whether the address is a validator
     */
    function isValidator(address account) external view returns (bool) {
        return _validators[account];
    }
    
    /**
     * @notice Get the total amount staked by a user
     * @param user Address of the user
     * @return amount Total amount staked
     */
    function getTotalStakedByUser(address user) external view returns (uint256) {
        return _stakingBalance[user];
    }
    
    /**
     * @notice Get the total amount staked in the protocol
     * @return amount Total amount staked
     */
    function getTotalStaked() external view returns (uint256) {
        return _totalStaked;
    }
    
    /**
     * @notice Get all staking tiers
     * @return tiers Array of staking tiers
     */
    function getStakingTiers() external view returns (StakingTier[] memory) {
        return _tiers;
    }
    
    /**
     * @notice Get the governance voting power of a user
     * @param user Address of the user
     * @return votes Voting power
     */
    function getGovernanceVotes(address user) external view returns (uint256) {
        return _governanceVotes[user];
    }
    
    /**
     * @notice Check if user has governance rights
     * @param user Address of the user
     * @return hasRights Whether the user has governance rights
     */
    function hasGovernanceRights(address user) external view returns (bool) {
        return _hasGovernanceRights(user);
    }
    
    /**
     * @notice Get the minimum amount required to become a validator
     * @return threshold Validator threshold
     */
    function getValidatorThreshold() public view returns (uint256) {
        return validatorThreshold;
    }
    
    /**
     * @notice Get the number of validators in the system
     * @return count Number of validators
     */
    function getValidatorCount() external view returns (uint256) {
        uint256 count = 0;
        uint256 roleCount = getRoleMemberCount(DEFAULT_ADMIN_ROLE);
        
        for (uint256 i = 0; i < roleCount; i++) {
            address account = getRoleMember(DEFAULT_ADMIN_ROLE, i);
            if (_validators[account]) {
                count++;
            }
        }
        
        return count;
    }
    
    /**
     * @notice Get protocol statistics
     * @return totalStaked Total amount staked
     * @return validators Number of validators
     * @return stakersCount Number of unique stakers
     * @return currentAPR Current base APR
     */
    function getProtocolStats() external view returns (
        uint256 totalStaked,
        uint256 validators,
        uint256 stakersCount,
        uint256 currentAPR
    ) {
        return (
            _totalStaked,
            this.getValidatorCount(),
            projectsContract.getStakerCount(),
            getCurrentBaseAPR()
        );
    }
    
    /**
     * @notice Version of the contract implementation
     * @return version Current implementation version
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
    
    // -------------------------------------------
    // 🔹 Internal Helper Functions
    // -------------------------------------------
    
    /**
     * @notice Burn tokens
     * @param amount Amount to burn
     */
    function _burnTokens(uint256 amount) internal {
        // Send tokens to dead address
        address burnAddress = 0x000000000000000000000000000000000000dEaD;
        if (!stakingToken.transfer(burnAddress, amount))
            revert TransferFailed(address(stakingToken), address(this), burnAddress, amount);
        
        emit TokensBurned(amount);
    }
    
    /**
     * @notice Add liquidity to pool
     * @param amount Amount to add
     */
    function _addLiquidity(uint256 amount) internal {
        if (!stakingToken.transfer(liquidityPool, amount))
            revert TransferFailed(address(stakingToken), address(this), liquidityPool, amount);
        
        emit LiquidityInjected(amount);
    }
    
    /**
     * @notice Calculate voting power using quadratic voting
     * @param user Address of the user
     * @return votingPower Voting power
     */
    function _calculateVotingPower(address user) internal view returns (uint256) {
        if (_governanceViolators[user]) {
            return 0;
        }
        
        uint256 stakingBalance = _stakingBalance[user];
        if (stakingBalance == 0) {
            return 0;
        }
        
        // Check if any position gives governance rights
        bool hasRights = _hasGovernanceRights(user);
        if (!hasRights) {
            return 0;
        }
        
        // Square root of stake for quadratic voting
        return _sqrt(stakingBalance);
    }
    
    /**
     * @notice Check if a user has governance rights
     * @param user Address of the user
     * @return hasRights Whether the user has governance rights
     */
    function _hasGovernanceRights(address user) internal view returns (bool) {
        if (_governanceViolators[user]) {
            return false;
        }
        
        uint256[] memory userProjects = projectsContract.getProjectsForStaker(user);
        
        for (uint256 i = 0; i < userProjects.length; i++) {
            uint256 projectId = userProjects[i];
            StakingPosition memory position = _stakingPositions[user][projectId];
            
            if (position.amount > 0) {
                // Check if the tier gives governance rights
                for (uint256 j = 0; j < _tiers.length; j++) {
                    if (position.duration >= _tiers[j].minDuration && _tiers[j].governanceRights) {
                        return true;
                    }
                }
            }
        }
        
        return false;
    }
    
    /**
     * @notice Calculate square root (using binary search)
     * @param x Input value
     * @return y Square root of input
     */
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        
        return y;
    }
    
    /**
     * @notice Support for ERC165 interface
     * @param interfaceId Interface identifier
     * @return isSupported Whether interface is supported
     */
    function supportsInterface(bytes4 interfaceId) 
        public 
        view 
        override(AccessControlEnumerableUpgradeable, ERC165Upgradeable) 
        returns (bool) 
    {
        return
            interfaceId == type(ITerraStakeStaking).interfaceId ||
            super.supportsInterface(interfaceId);
    }
    
    /**
     * @notice Recover accidentally sent ERC20 tokens
     * @param token Address of the token
     * @param amount Amount to recover
     * @param recipient Address to send tokens to
     */
    function recoverERC20(
        address token,
        uint256 amount,
        address recipient
    ) external onlyRole(GOVERNANCE_ROLE) {
        if (token == address(stakingToken)) 
            revert ActionNotPermittedForValidator();
        if (recipient == address(0))
            revert InvalidAddress("recipient", recipient);
            
        IERC20Upgradeable(token).transfer(recipient, amount);
        emit ERC20Recovered(token, amount, recipient);
    }
}
