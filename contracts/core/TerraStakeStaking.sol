// SPDX-License-Identifier: GPL-3.0
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
    error BatchTransferFailed();

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
    uint256 public constant MIN_STAKING_DURATION = 30 days;
    address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

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
        if (duration < MIN_STAKING_DURATION) revert InsufficientStakingDuration(MIN_STAKING_DURATION, duration);
        if (!projectsContract.projectExists(projectId)) revert ProjectDoesNotExist(projectId);
        
        // Cache storage variables
        uint256 userStakingBalance = _stakingBalance[msg.sender];
        uint256 currentTotalStaked = _totalStaked;
        
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
        
        // Update totals (cache and update once)
        currentTotalStaked += amount;
        _totalStaked = currentTotalStaked;
        
        userStakingBalance += amount;
        _stakingBalance[msg.sender] = userStakingBalance;
        
        // Update governance votes using quadratic voting power
        _governanceVotes[msg.sender] = _calculateVotingPower(msg.sender);
        
        // Transfer tokens to contract
        if (!stakingToken.transferFrom(msg.sender, address(this), amount)) 
            revert TransferFailed(address(stakingToken), msg.sender, address(this), amount);
        
        // Update project stats in projects contract
        projectsContract.updateProjectStaking(projectId, amount, true);

// Mark as validator if staking enough
        if (userStakingBalance >= validatorThreshold && !_validators[msg.sender]) {
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
        
        // Cache position data to reduce storage reads
        uint256 positionAmount = position.amount;
        uint256 positionStart = position.stakingStart;
        uint256 positionDuration = position.duration;
        
        // Cache user balance
        uint256 userStakingBalance = _stakingBalance[msg.sender];
        
        // Calculate if we need to apply early unstaking penalty
        uint256 stakingEndTime = positionStart + positionDuration;
        uint256 amount = positionAmount;
        uint256 penalty = 0;
        uint256 toRedistribute = 0;
        uint256 toBurn = 0;
        uint256 toLiquidity = 0;
        
        // If unstaking early, apply penalty
        if (block.timestamp < stakingEndTime) {
            uint256 timeRemaining = stakingEndTime - block.timestamp;
            
            // Calculate penalty percentage (linear from BASE_PENALTY to MAX_PENALTY)
            uint256 penaltyPercent = BASE_PENALTY_PERCENT + 
                ((timeRemaining * (MAX_PENALTY_PERCENT - BASE_PENALTY_PERCENT)) / positionDuration);
            
            penalty = (amount * penaltyPercent) / 100;
            amount -= penalty;
            
            // If user has governance rights, they lose them for early withdrawal
            if (_hasGovernanceRights(msg.sender)) {
                _governanceViolators[msg.sender] = true;
                emit GovernanceRightsUpdated(msg.sender, false);
            }
            
            // Calculate penalty distributions
            if (penalty > 0) {
                toRedistribute = penalty / 2;
                toBurn = penalty / 4;
                toLiquidity = penalty - toRedistribute - toBurn;
            }
        }
        
        // Claim any pending rewards first
        _claimRewards(msg.sender, projectId);
        
        // Update totals (using cached values)
        _totalStaked -= positionAmount;
        _stakingBalance[msg.sender] = userStakingBalance - positionAmount;
        
        // Update governance voting power
        _governanceVotes[msg.sender] = _calculateVotingPower(msg.sender);
        
        // Update project stats
        projectsContract.updateProjectStaking(projectId, positionAmount, false);
        
        // Clear position
        delete _stakingPositions[msg.sender][projectId];
        
        // Update validator status if applicable
        bool wasValidator = _validators[msg.sender];
        if (wasValidator && userStakingBalance - positionAmount < validatorThreshold) {
            _validators[msg.sender] = false;
            emit ValidatorStatusChanged(msg.sender, false);
        }
        
        // Handle all token transfers in one batch
        bool success = true;
        
        // 1. Transfer user's tokens back
        if (amount > 0) {
            success = stakingToken.transfer(msg.sender, amount);
        }
        
        // 2. Handle penalty distributions as a batch
        if (penalty > 0 && success) {
            // Distribute rewards to stakers
            if (toRedistribute > 0) {
                success = success && rewardDistributor.distributeBonus(toRedistribute);
            }
            
            // Send to burn address
            if (toBurn > 0 && success) {
                success = success && stakingToken.transfer(BURN_ADDRESS, toBurn);
            }
            
            // Add to liquidity
            if (autoLiquidityEnabled && toLiquidity > 0 && success) {
                success = success && stakingToken.transfer(liquidityPool, toLiquidity);
            }
        }
        
        if (!success) revert BatchTransferFailed();
        
        emit Unstaked(msg.sender, projectId, amount, penalty);
    }
    
    /**
     * @notice Claim rewards for a staking position
     * @param projectId ID of the project
     */
    function claimRewards(uint256 projectId) external nonReentrant whenNotPaused {
        if (_stakingPositions[msg.sender][projectId].amount == 0) 
            revert NoActiveStakingPosition(msg.sender, projectId);
        _claimRewards(msg.sender, projectId);
    }
    
    /**
     * @notice Internal function to claim rewards
     * @param user Address of the user
     * @param projectId ID of the project
     */
    function _claimRewards(address user, uint256 projectId) internal {
        StakingPosition storage position = _stakingPositions[user][projectId];
        
        // Calculate rewards
        uint256 rewards = calculateRewards(user, projectId);
        
        if (rewards == 0) return;
        
        // Update checkpoint
        position.lastCheckpoint = block.timestamp;
        
        // Handle liquidity injection if enabled
        uint256 toInject = 0;
        if (autoLiquidityEnabled && liquidityInjectionRate > 0) {
            toInject = (rewards * liquidityInjectionRate) / 100;
        }
        
        // Auto-compound if enabled
        if (position.autoCompounding) {
            // Cache values
            uint256 compoundAmount = rewards;
            uint256 newAmount = position.amount + compoundAmount;
            uint256 newTotalStaked = _totalStaked + compoundAmount;
            uint256 newUserBalance = _stakingBalance[user] + compoundAmount;
            
            // Update position and global state (single write)
            position.amount = newAmount;
            _totalStaked = newTotalStaked;
            _stakingBalance[user] = newUserBalance;
            
            // Update governance votes
            _governanceVotes[user] = _calculateVotingPower(user);
            
            // Update project stats
            projectsContract.updateProjectStaking(projectId, compoundAmount, true);
            
            emit RewardsCompounded(user, projectId, compoundAmount);
        } else {
            // Distribute rewards with single transfer
            uint256 toUser = rewards - toInject;
            
            // First handle liquidity injection if needed
            if (toInject > 0) {
                if (!stakingToken.transfer(liquidityPool, toInject))
                    revert TransferFailed(address(stakingToken), address(this), liquidityPool, toInject);
                    
                emit LiquidityInjected(toInject);
            }
            
            // Then transfer rewards to user
            if (!rewardDistributor.distributeReward(user, toUser))
                revert DistributionFailed(toUser);
                
            emit RewardsDistributed(user, projectId, toUser);
        }
    }
    
    /**
     * @notice Add validator if they meet the threshold
     * @param validator Address to add as validator
     */
    function addValidator(address validator) external onlyRole(GOVERNANCE_ROLE) {
        if (_validators[validator]) revert AlreadyValidator(validator);
        
        uint256 validatorBalance = _stakingBalance[validator];
        if (validatorBalance < validatorThreshold) 
            revert InvalidParameter("stakingBalance", validatorBalance);
        
        _validators[validator] = true;
        emit ValidatorStatusChanged(validator, true);
    }
    
    /**
     * @notice Remove validator
     * @param validator Address to remove as validator
     */
    function removeValidator(address validator) external onlyRole(GOVERNANCE_ROLE) {
        if (!_validators[validator]) revert NotValidator(validator);
        
        _validators[validator] = false;
        emit ValidatorStatusChanged(validator, false);
    }
    
    /**
     * @notice Slash a validator's stake (called by slashing contract)
     * @param validator Address of validator to slash
     * @param amount Amount to slash
     * @return success Whether slashing was successful
     */
    function slashValidator(address validator, uint256 amount) external onlyRole(SLASHER_ROLE) returns (bool) {
        if (!_validators[validator]) revert NotValidator(validator);
        if (amount == 0) revert ZeroAmount();
        
        // Get total staked by validator
        uint256 validatorStake = _stakingBalance[validator];
        uint256 slashAmount = amount;
        
        if (validatorStake < slashAmount) {
            slashAmount = validatorStake;
        }
        
        // Loop through all projects to find validator's positions
        uint256 slashedSoFar = 0;
        uint256[] memory projectIds = projectsContract.getProjectsForStaker(validator);
        
        for (uint256 i = 0; i < projectIds.length && slashedSoFar < slashAmount; i++) {
            uint256 projectId = projectIds[i];
            StakingPosition storage position = _stakingPositions[validator][projectId];
            
            if (position.amount > 0) {
                uint256 toSlash = slashAmount - slashedSoFar;
                if (toSlash > position.amount) {
                    toSlash = position.amount;
                }
                
                // Update position
                position.amount -= toSlash;
                
                // Update project stats
                projectsContract.updateProjectStaking(projectId, toSlash, false);
                
                slashedSoFar += toSlash;
                
                // If position is now empty, clean it up
                if (position.amount == 0) {
                    delete _stakingPositions[validator][projectId];
                }
            }
        }
        
        if (slashedSoFar == 0) revert SlashingFailed(validator, amount);
        
        // Cache values and update at once
        uint256 newTotalStaked = _totalStaked - slashedSoFar;
        uint256 newValidatorBalance = validatorStake - slashedSoFar;
        
        // Update totals
        _totalStaked = newTotalStaked;
        _stakingBalance[validator] = newValidatorBalance;
        
        // Update governance voting power
        _governanceVotes[validator] = _calculateVotingPower(validator);
        
        // If validator no longer meets threshold, remove validator status
        if (newValidatorBalance < validatorThreshold) {
            _validators[validator] = false;
            emit ValidatorStatusChanged(validator, false);
        }
        
        // Batch all token transfers - send slashed amount to burn address
        if (slashedSoFar > 0) {
            if (!stakingToken.transfer(BURN_ADDRESS, slashedSoFar))
                revert TransferFailed(address(stakingToken), address(this), BURN_ADDRESS, slashedSoFar);
        }
        
        emit ValidatorSlashed(validator, slashedSoFar);
        return true;
    }
    
    // -------------------------------------------
    // 🔹 Protocol Parameters
    // -------------------------------------------
    
    /**
     * @notice Apply halving to reduce APR
     */
    function applyHalving() external onlyRole(GOVERNANCE_ROLE) {
        uint256 nextHalvingTime = lastHalvingTime + halvingPeriod;
        if (block.timestamp < nextHalvingTime) 
            revert InvalidParameter("halvingDueTime", nextHalvingTime);
        
        lastHalvingTime = block.timestamp;
        halvingEpoch++;
        
        emit HalvingApplied(halvingEpoch, getCurrentBaseAPR());
    }
    
    /**
     * @notice Update liquidity injection rate
     * @param newRate New rate for liquidity injection
     */
    function updateLiquidityInjectionRate(uint256 newRate) external onlyRole(GOVERNANCE_ROLE) {
        if (newRate > MAX_LIQUIDITY_RATE) revert RateTooHigh(newRate, MAX_LIQUIDITY_RATE);
        
        liquidityInjectionRate = newRate;
        emit LiquidityInjectionRateUpdated(newRate);
    }
    
    /**
     * @notice Toggle auto-liquidity feature
     */
    function toggleAutoLiquidity() external onlyRole(GOVERNANCE_ROLE) {
        bool newStatus = !autoLiquidityEnabled;
        autoLiquidityEnabled = newStatus;
        emit AutoLiquidityToggled(newStatus);
    }
    
    /**
     * @notice Update validator threshold
     * @param newThreshold New threshold amount
     */
    function updateValidatorThreshold(uint256 newThreshold) external onlyRole(GOVERNANCE_ROLE) {
        if (newThreshold == 0) revert ZeroAmount();
        
        validatorThreshold = newThreshold;
        emit ValidatorThresholdUpdated(newThreshold);
    }
    
    /**
     * @notice Update halving period
     * @param newPeriod New halving period in seconds
     */
    function updateHalvingPeriod(uint256 newPeriod) external onlyRole(GOVERNANCE_ROLE) {
        if (newPeriod < 30 days) revert InvalidParameter("halvingPeriod", newPeriod);
        
        halvingPeriod = newPeriod;
        emit HalvingPeriodUpdated(newPeriod);
    }
    
    /**
     * @notice Toggle emergency pause status
     * @param paused Whether to pause or unpause
     */
    function toggleEmergencyPause(bool paused) external onlyRole(EMERGENCY_ROLE) {
        if (paused) {
            _pause();
        } else {
            _unpause();
        }
        
        emit EmergencyPauseToggled(paused);
    }
    
    /**
     * @notice Add a new staking tier
     * @param minDuration Minimum staking duration for tier
     * @param rewardMultiplier Reward multiplier (in basis points)
     * @param governanceRights Whether tier grants governance rights
     */
    function addStakingTier(
        uint256 minDuration,
        uint256 rewardMultiplier,
        bool governanceRights
    ) external onlyRole(GOVERNANCE_ROLE) {
        if (minDuration < 7 days) revert InvalidParameter("minDuration", minDuration);
        if (rewardMultiplier == 0) revert ZeroAmount();
        
        _tiers.push(StakingTier(minDuration, rewardMultiplier, governanceRights));
        
        emit StakingTierAdded(_tiers.length - 1, minDuration, rewardMultiplier, governanceRights);
    }
    
    /**
     * @notice Update an existing staking tier
     * @param tierId ID of tier to update
     * @param minDuration Minimum staking duration for tier
     * @param rewardMultiplier Reward multiplier (in basis points)
     * @param governanceRights Whether tier grants governance rights
     */
    function updateStakingTier(
        uint256 tierId,
        uint256 minDuration,
        uint256 rewardMultiplier,
        bool governanceRights
    ) external onlyRole(GOVERNANCE_ROLE) {
        uint256 tiersLength = _tiers.length;
        if (tierId >= tiersLength) revert InvalidParameter("tierId", tierId);
        if (minDuration < 7 days) revert InvalidParameter("minDuration", minDuration);
        if (rewardMultiplier == 0) revert ZeroAmount();
        
        StakingTier storage tier = _tiers[tierId];
        
        tier.minDuration = minDuration;
        tier.rewardMultiplier = rewardMultiplier;
        tier.governanceRights = governanceRights;
        
        emit StakingTierUpdated(tierId, minDuration, rewardMultiplier, governanceRights);
    }
    
    // -------------------------------------------
    // 🔹 View Functions
    // -------------------------------------------
    
    /**
     * @notice Calculate rewards for a staking position
     * @param user Address of the user
     * @param projectId ID of the project
     * @return amount Amount of rewards
     */
    function calculateRewards(address user, uint256 projectId) public view returns (uint256) {
        StakingPosition memory position = _stakingPositions[user][projectId];
        if (position.amount == 0) return 0;
        
        // Calculate time staked using last checkpoint for fair rewards
        uint256 timeStaked = block.timestamp - position.lastCheckpoint;
        if (timeStaked == 0) return 0;
        
        // Get total time in contract for long-term bonus calculation
        uint256 totalTimeStaked = block.timestamp - position.stakingStart;
        
        // Get APR based on staking conditions
        uint256 apr = getDynamicAPR(position.isLPStaker, position.hasNFTBoost);
        
        // Apply tier multiplier
        uint256 tierMultiplier = getTierMultiplier(position.duration);
        
        // Calculate base rewards
        // formula: amount * apr * timeStaked * tierMultiplier / (100 * 365 days * 10000)
        uint256 rewards = (position.amount * apr * timeStaked * tierMultiplier) / (100 * 365 days * 10000);
        
        // ✅ Gradual Bonus Structure
        // Adding time-based bonuses to reward long-term stakers
        if (totalTimeStaked >= 18 * 30 days) {
            // +8% bonus for staking 18+ months
            rewards += (rewards * 8) / 100;
        } else if (totalTimeStaked >= 15 * 30 days) {
            // +5% bonus for staking 15-18 months
            rewards += (rewards * 5) / 100;
        } else if (totalTimeStaked >= 12 * 30 days) {
            // +3% bonus for staking 12-15 months
            rewards += (rewards * 3) / 100;
        }
        
        return rewards;
    }
    
    /**
     * @notice Get dynamic APR based on staking conditions
     * @param isLP Whether staker is providing LP tokens
     * @param hasNFT Whether staker has NFT boost
     * @return apr Annual percentage rate
     */
    function getDynamicAPR(bool isLP, bool hasNFT) public view returns (uint256) {
        uint256 baseApr = getCurrentBaseAPR();
        
        if (isLP) {
            return baseApr + LP_APR_BOOST;
        } else if (hasNFT) {
            return baseApr + NFT_APR_BOOST;
        } else {
            return baseApr;
        }
    }
    
    /**
     * @notice Get current base APR after halvings
     * @return apr Annual percentage rate
     */
    function getCurrentBaseAPR() public view returns (uint256) {
        uint256 totalStakedAmount = _totalStaked;
        uint256 baseRate = totalStakedAmount < LOW_STAKING_THRESHOLD ? BOOSTED_APR : BASE_APR;
        uint256 currentHalvingEpoch = halvingEpoch;
        
        // Apply halvings (divide by 2^halvingEpoch)
        if (currentHalvingEpoch > 0) {
            // Apply halving using bitshift for gas efficiency
            return baseRate >> currentHalvingEpoch;
        }
        
        return baseRate;
    }
    
    /**
     * @notice Get tier multiplier for a staking duration
     * @param duration Staking duration
     * @return multiplier Reward multiplier in basis points
     */
    function getTierMultiplier(uint256 duration) public view returns (uint256) {
        uint256 multiplier = 100; // Default 1x multiplier (100 basis points)
        uint256 tiersLength = _tiers.length;
        
        for (uint256 i = 0; i < tiersLength; i++) {
            StakingTier memory tier = _tiers[i];
            if (duration >= tier.minDuration && tier.rewardMultiplier > multiplier) {
                multiplier = tier.rewardMultiplier;
            }
        }
        
        return multiplier;
    }
    
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
        uint256 projectsCount = userProjects.length;
        
        // Count active positions first to size arrays correctly
        uint256 activeCount = 0;
        for (uint256 i = 0; i < projectsCount; i++) {
            if (_stakingPositions[user][userProjects[i]].amount > 0) {
                activeCount++;
            }
        }
        
        // Initialize return arrays with correct size
        projectIds = new uint256[](activeCount);
        positions = new StakingPosition[](activeCount);
        
        // Fill arrays in a single pass
        uint256 index = 0;
        for (uint256 i = 0; i < projectsCount; i++) {
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
        uint256 roleCount = getRoleMemberCount(DEFAULT_ADMIN_ROLE);
        
        // Load all addresses first to minimize storage reads
        address[] memory adminMembers = new address[](roleCount);
        for (uint256 i = 0; i < roleCount; i++) {
            adminMembers[i] = getRoleMember(DEFAULT_ADMIN_ROLE, i);
        }
        
        // Count validators
        uint256 count = 0;
        for (uint256 i = 0; i < roleCount; i++) {
            if (_validators[adminMembers[i]]) {
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
     * @notice Calculate voting power using quadratic voting
     * @param user Address of the user
     * @return votingPower Voting power
     */
    function _calculateVotingPower(address user) internal view returns (uint256) {
        // Early returns for efficiency
        if (_governanceViolators[user]) {
            return 0;
        }
        
        uint256 stakingBalance = _stakingBalance[user];
        if (stakingBalance == 0) {
            return 0;
        }
        
        // Check if any position gives governance rights
        if (!_hasGovernanceRights(user)) {
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
        uint256 tiersLength = _tiers.length;
        
        for (uint256 i = 0; i < userProjects.length; i++) {
            uint256 projectId = userProjects[i];
            StakingPosition memory position = _stakingPositions[user][projectId];
            
            if (position.amount > 0) {
                // Check if the tier gives governance rights
                for (uint256 j = 0; j < tiersLength; j++) {
                    StakingTier memory tier = _tiers[j];
                    if (position.duration >= tier.minDuration && tier.governanceRights) {
                        return true; // Early return when found
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
        
        // Optimized square root using binary search
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

