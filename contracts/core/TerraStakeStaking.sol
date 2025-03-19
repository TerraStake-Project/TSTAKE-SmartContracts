// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/ITerraStakeRewardDistributor.sol";
import "../interfaces/ITerraStakeProjects.sol";
import "../interfaces/ITerraStakeGovernance.sol";
import "../interfaces/ITerraStakeSlashing.sol";

/**
 * @title TerraStakeStaking
 * @notice Official staking contract for the TerraStake ecosystem with multi-project (batch) operations,
 * auto-compounding, dynamic APR, halving events, early-withdrawal penalties, and validator logic.
 * @dev This contract is upgradeable (UUPS) and uses multiple OpenZeppelin libraries for security.
 */
contract TerraStakeStaking is 
    ITerraStakeStaking,
    Initializable,
    ERC165Upgradeable,
    AccessControlEnumerableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    PausableUpgradeable, 
    UUPSUpgradeable
{
    using Math for uint256;

    // -------------------------------------------
    //   Custom Errors
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
    //   Constants
    // -------------------------------------------
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant UPGRADER_ROLE    = keccak256("UPGRADER_ROLE");
    bytes32 public constant EMERGENCY_ROLE   = keccak256("EMERGENCY_ROLE");
    bytes32 public constant SLASHER_ROLE     = keccak256("SLASHER_ROLE");

    uint256 public constant BASE_APR              = 10;   // 10% APR base
    uint256 public constant BOOSTED_APR           = 20;   // 20% APR if TVL < 1M TSTAKE
    uint256 public constant NFT_APR_BOOST         = 10;   // Additional +10% if user has NFT
    uint256 public constant LP_APR_BOOST          = 15;   // Additional +15% if LP staker
    uint256 public constant BASE_PENALTY_PERCENT  = 10;   // 10% base penalty for early unstake
    uint256 public constant MAX_PENALTY_PERCENT   = 30;   // 30% max penalty
    uint256 public constant LOW_STAKING_THRESHOLD = 1_000_000 * 10**18;
    uint256 public constant GOVERNANCE_VESTING_PERIOD = 7 days;
    uint256 public constant MAX_LIQUIDITY_RATE    = 10;
    uint256 public constant MIN_STAKING_DURATION  = 30 days;
    uint256 public constant GOVERNANCE_THRESHOLD  = 10_000 * 10**18; // min tokens for governance
    address private constant BURN_ADDRESS         = 0x000000000000000000000000000000000000dEaD;

    // -------------------------------------------
    //   State Variables 
    // -------------------------------------------
    IERC1155 public nftContract;
    IERC20 public stakingToken;
    ITerraStakeRewardDistributor public rewardDistributor;
    ITerraStakeProjects public projectsContract;
    ITerraStakeGovernance public governanceContract;
    ITerraStakeSlashing public slashingContract;
    address public liquidityPool;

    uint256 public liquidityInjectionRate;  // percentage of rewards reinjected
    bool    public autoLiquidityEnabled;
    uint256 public halvingPeriod;           // e.g. 730 days
    uint256 public lastHalvingTime;
    uint256 public halvingEpoch;
    uint256 public proposalNonce;
    uint256 public validatorThreshold;

    // Mappings must remain unchanged:
    /**
         * @dev Private mapping to track individual staking positions for each user
         * @notice Maps user addresses to their multiple staking positions, indexed by a unique position ID
         */
    mapping(address => mapping(uint256 => StakingPosition)) private _stakingPositions;
    mapping(address => uint256) private _governanceVotes;
    mapping(address => uint256) private _stakingBalance;
    mapping(address => bool)    private _governanceViolators;
    mapping(address => bool)    private _validators;

    uint256 private _totalStaked;
    StakingTier[] private _tiers;

    // Track active stakers
    address[] private _activeStakers;
    mapping(address => bool) private _isActiveStaker;

 // Track governance proposals
    /**
     * @dev Reserved storage space to avoid layout collisions during upgrades.
     *      Always keep this at the end of state variables.
     */
    uint256[50] private __gap;

    // -------------------------------------------
    //   Constructor & Initializer
    // -------------------------------------------
    /**
     * @notice Prevents initialization of the implementation contract
     * @dev Disables initializers to ensure the contract cannot be initialized directly, 
     *      following the UUPS upgradeable pattern
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

/**
     * @notice Initializes the contract with essential configurations and roles.
     * @dev Performs one-time initialization for the upgradeable contract, setting up contracts, roles, and initial parameters.
     * @param _nftContract Address of the NFT contract
     * @param _stakingToken Address of the staking token contract
     * @param _rewardDistributor Address of the reward distributor contract
     * @param _liquidityPool Address of the liquidity pool
     * @param _projectsContract Address of the projects contract
     * @param _governanceContract Address of the governance contract
     * @param _admin Address of the contract administrator
     * @custom:security Only callable once during proxy deployment
     */
        /**
     * @notice Initializes the contract (UUPS + OpenZeppelin upgradeable pattern).
     * @dev Must only be called once (by proxy deployment).
     */
/**
     * @notice Initializes the TerraStake staking contract with core configurations
     * @dev One-time initializer for the upgradeable contract that sets up contracts, roles, and initial staking parameters
     * @param _nftContract Address of the NFT contract used for staking boosts
     * @param _stakingToken Address of the token used for staking
     * @param _rewardDistributor Address of the contract responsible for reward distribution
     * @param _liquidityPool Address of the liquidity pool
     * @param _projectsContract Address of the projects management contract
     * @param _governanceContract Address of the governance contract
     * @param _admin Address of the contract administrator with privileged roles
     * @custom:security Only callable once during proxy deployment, with zero-address checks for all parameters
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

        nftContract      = IERC1155(_nftContract);
        stakingToken     = IERC20(_stakingToken);
        rewardDistributor= ITerraStakeRewardDistributor(_rewardDistributor);
        liquidityPool    = _liquidityPool;
        projectsContract = ITerraStakeProjects(_projectsContract);
        governanceContract = ITerraStakeGovernance(_governanceContract);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(GOVERNANCE_ROLE, _governanceContract);
        _grantRole(UPGRADER_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);

        halvingPeriod     = 730 days;
        lastHalvingTime   = block.timestamp;
        halvingEpoch      = 0;
        liquidityInjectionRate = 5;
        autoLiquidityEnabled   = true;
        validatorThreshold     = 100_000 * 10**18;

        // Initialize tiers – ensure they are ordered by duration ascending
        _tiers.push(StakingTier(30 days, 100, false));
        _tiers.push(StakingTier(90 days, 150, true));
        _tiers.push(StakingTier(180 days, 200, true));
        _tiers.push(StakingTier(365 days, 300, true));

        // Additional parameters
        governanceQuorum          = 1000;
        dynamicRewardsEnabled     = false;
        lastRewardAdjustmentTime  = block.timestamp;
        dynamicBaseAPR            = BASE_APR;
        dynamicBoostedAPR         = BOOSTED_APR;
    }

    /**
     * @dev Enforces upgrade authorization to the `UPGRADER_ROLE`.
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}

    // -------------------------------------------
    //   Staking Operations
    // -------------------------------------------

    /**
     * @notice Stake tokens for a single project.
     * @param projectId  ID of the project
     * @param amount     Amount to stake
     * @param duration   Desired staking duration
     * @param isLP       Whether staking LP tokens
     * @param autoCompound Whether to automatically compound future rewards
     */
    function stake(
        uint256 projectId,
        uint256 amount,
        uint256 duration,
        bool isLP,
        bool autoCompound
    )
        external
        nonReentrant
        whenNotPaused
    {
        if (amount == 0) revert ZeroAmount();
        if (duration < MIN_STAKING_DURATION) {
            revert InsufficientStakingDuration(MIN_STAKING_DURATION, duration);
        }
        if (!projectsContract.projectExists(projectId)) {
            revert ProjectDoesNotExist(projectId);
        }

        uint256 userStakingBalance   = _stakingBalance[msg.sender];
        uint256 currentTotalStaked   = _totalStaked;
        bool hasNFTBoost             = (nftContract.balanceOf(msg.sender, 1) > 0);

        // Get or create the staking position
        StakingPosition storage position = _stakingPositions[msg.sender][projectId];

        // If this is an existing position, claim up to now
        if (position.amount > 0) {
            _claimRewards(msg.sender, projectId);
        } else {
            position.stakingStart = block.timestamp;
            position.projectId    = projectId;
        }

        // Update position
        position.amount         += amount;
        position.lastCheckpoint  = block.timestamp;
        position.duration        = duration;
        position.isLPStaker      = isLP;
        position.hasNFTBoost     = hasNFTBoost;
        position.autoCompounding = autoCompound;

        // Update global stats
        currentTotalStaked += amount;
        _totalStaked        = currentTotalStaked;

        userStakingBalance += amount;
        _stakingBalance[msg.sender] = userStakingBalance;

        // Update governance votes if threshold is reached
        if (userStakingBalance >= GOVERNANCE_THRESHOLD && !_governanceViolators[msg.sender]) {
            _governanceVotes[msg.sender] = userStakingBalance;
        }

        // Transfer tokens
        bool success = stakingToken.transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert TransferFailed(address(stakingToken), msg.sender, address(this), amount);
        }

        // Inform projectsContract that there's a new staker
        projectsContract.incrementStakerCount(projectId);

        // Check if user is now a validator
        if (userStakingBalance >= validatorThreshold && !_validators[msg.sender]) {
            _validators[msg.sender] = true;
            emit ValidatorStatusChanged(msg.sender, true);
        }

        if (!_isActiveStaker[msg.sender]) {
            _isActiveStaker[msg.sender] = true;
            _activeStakers.push(msg.sender);
        }
        emit Staked(msg.sender, projectId, amount, duration, block.timestamp, position.amount);
    }

    /**
     * @notice Stake tokens across multiple projects in a single transaction.
     * @param projectIds    Array of project IDs to stake into
     * @param amounts       Array of amounts to stake
     * @param durations     Array of staking durations
     * @param isLP          Array of booleans if the position is LP
     * @param autoCompound  Array of booleans if auto-compounding is enabled
     */
    function batchStake(
        uint256[] calldata projectIds,
        uint256[] calldata amounts,
        uint256[] calldata durations,
        bool[]    calldata isLP,
        bool[]    calldata autoCompound
    )
        external
        nonReentrant
        whenNotPaused
    {
        uint256 length = projectIds.length;
        if (length == 0) {
            revert InvalidParameter("projectIds", 0);
        }
        // Validate array lengths
        if (
            amounts.length     != length ||
            durations.length   != length ||
            isLP.length        != length ||
            autoCompound.length!= length
        ) {
            revert InvalidParameter("arrayLengths", length);
        }

        // Hard limit to help avoid block gas blowouts or malicious usage
        // (You can adjust this to a safe upper bound for your environment)
        require(length <= 50, "batchStake: too many items");

        // Calculate total needed for all stakes
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < length; i++) {
            if (amounts[i] == 0) {
                revert ZeroAmount();
            }
            totalAmount += amounts[i];
        }

        // Transfer total in one call for gas efficiency
        if (!stakingToken.transferFrom(msg.sender, address(this), totalAmount)) {
            revert TransferFailed(address(stakingToken), msg.sender, address(this), totalAmount);
        }

        bool hasNFTBoost = (nftContract.balanceOf(msg.sender, 1) > 0);
        uint256 stakedSoFar = 0;

        for (uint256 i = 0; i < length; i++) {
            if (durations[i] < MIN_STAKING_DURATION) {
                revert InsufficientStakingDuration(MIN_STAKING_DURATION, durations[i]);
            }
            if (!projectsContract.projectExists(projectIds[i])) {
                revert ProjectDoesNotExist(projectIds[i]);
            }

            // Retrieve or create the position
            StakingPosition storage position = _stakingPositions[msg.sender][projectIds[i]];
            if (position.amount > 0) {
                _claimRewards(msg.sender, projectIds[i]);
            } else {
                position.stakingStart = block.timestamp;
                position.projectId    = projectIds[i];
            }

            position.amount         += amounts[i];
            position.lastCheckpoint  = block.timestamp;
            position.duration        = durations[i];
            position.isLPStaker      = isLP[i];
            position.hasNFTBoost     = hasNFTBoost;
            position.autoCompounding = autoCompound[i];

            stakedSoFar         += amounts[i];
            _totalStaked        += amounts[i];
            _stakingBalance[msg.sender] += amounts[i];

            // Update project stats
            projectsContract.incrementStakerCount(projectIds[i]);

            emit Staked(
                msg.sender,
                projectIds[i],
                amounts[i],
                durations[i],
                block.timestamp,
                position.amount
            );
        }

        // Update governance votes if threshold is reached
        uint256 userBal = _stakingBalance[msg.sender];
        if (userBal >= GOVERNANCE_THRESHOLD && !_governanceViolators[msg.sender]) {
            _governanceVotes[msg.sender] = userBal;
        }

        // Check validator status
        if (userBal >= validatorThreshold && !_validators[msg.sender]) {
            _validators[msg.sender] = true;
            emit ValidatorStatusChanged(msg.sender, true);
        }

        if (!_isActiveStaker[msg.sender]) {
            _isActiveStaker[msg.sender] = true;
            _activeStakers.push(msg.sender);
        }
    }

    /**
     * @notice Unstake tokens from a single project.
     * @param projectId The project to unstake from
     */
    function unstake(uint256 projectId) external nonReentrant {
        StakingPosition storage position = _stakingPositions[msg.sender][projectId];
        if (position.amount == 0) {
            revert NoActiveStakingPosition(msg.sender, projectId);
        }
        _claimRewards(msg.sender, projectId);

        uint256 amount       = position.amount;
        uint256 stakingTime  = block.timestamp - position.stakingStart;
        uint256 penalty      = 0;

        // If we haven't reached the user's stated duration, impose penalty
        if (stakingTime < position.duration) {
            uint256 remainingTime = position.duration - stakingTime;
            uint256 penaltyPercent = BASE_PENALTY_PERCENT
                + ((remainingTime * (MAX_PENALTY_PERCENT - BASE_PENALTY_PERCENT)) / position.duration);
            penalty = (amount * penaltyPercent) / 100;

            _handlePenalty(msg.sender, projectId, penalty);
        }

        _totalStaked                -= amount;
        _stakingBalance[msg.sender] -= amount;

        // Adjust governance votes if they fell below threshold
        if (_stakingBalance[msg.sender] < GOVERNANCE_THRESHOLD) {
            _governanceVotes[msg.sender] = 0;
        } else {
            _governanceVotes[msg.sender] = _stakingBalance[msg.sender];
        }

        // Update project stats
        projectsContract.decrementStakerCount(projectId);

        // Clear position
        delete _stakingPositions[msg.sender][projectId];

        // Check if we drop below validator threshold
        if (_validators[msg.sender] && _stakingBalance[msg.sender] < validatorThreshold) {
            _validators[msg.sender] = false;
            emit ValidatorStatusChanged(msg.sender, false);
        }

        uint256 transferAmount = amount - penalty;
        bool success = stakingToken.transfer(msg.sender, transferAmount);
        if (!success) {
            revert TransferFailed(address(stakingToken), address(this), msg.sender, transferAmount);
        }

        if (_stakingBalance[msg.sender] == 0) {
            _isActiveStaker[msg.sender] = false;
            _removeInactiveStaker(msg.sender);
        }
        emit Unstaked(msg.sender, projectId, transferAmount, penalty, block.timestamp);
    }

    /**
     * @notice Unstake tokens from multiple projects in one transaction.
     * @param projectIds Array of project IDs to unstake from.
     */
    function batchUnstake(uint256[] calldata projectIds) external nonReentrant whenNotPaused {
        uint256 length = projectIds.length;
        if (length == 0) {
            revert InvalidParameter("projectIds", 0);
        }
        // Hard limit to prevent huge loops
        require(length <= 50, "batchUnstake: too many items");

        uint256 totalAmount       = 0;
        uint256 totalPenalty      = 0;
        uint256 totalToRedistribute = 0;
        uint256 totalToBurn       = 0;
        uint256 totalToLiquidity  = 0;

        for (uint256 i = 0; i < length; i++) {
            uint256 projectId = projectIds[i];
            StakingPosition storage position = _stakingPositions[msg.sender][projectId];
            if (position.amount == 0) {
                revert NoActiveStakingPosition(msg.sender, projectId);
            }
            // Claim up to date
            _claimRewards(msg.sender, projectId);

            uint256 posAmount    = position.amount;
            uint256 stakingEnd   = position.stakingStart + position.duration;
            uint256 penalty      = 0;
            uint256 toRedistribute = 0;
            uint256 toBurn       = 0;
            uint256 toLiquidity  = 0;

            if (block.timestamp < stakingEnd) {
                uint256 remainingTime   = stakingEnd - block.timestamp;
                uint256 penaltyPercent  = BASE_PENALTY_PERCENT
                    + ((remainingTime * (MAX_PENALTY_PERCENT - BASE_PENALTY_PERCENT)) / position.duration);

                penalty = (posAmount * penaltyPercent) / 100;
                if (penalty > 0) {
                    toRedistribute = penalty / 2;     // 50% to stakers
                    toBurn         = penalty / 4;     // 25% burn
                    toLiquidity    = penalty - toRedistribute - toBurn; // 25% to liquidity
                    _penaltyHistory[msg.sender].push(PenaltyEvent({
                        projectId:     projectId,
                        timestamp:     block.timestamp,
                        totalPenalty:  penalty,
                        redistributed: toRedistribute,
                        burned:        toBurn,
                        toLiquidity:   toLiquidity
                    }));
                }
            }

            totalAmount += (posAmount - penalty);
            totalPenalty += penalty;
            totalToRedistribute += toRedistribute;
            totalToBurn += toBurn;
            totalToLiquidity += toLiquidity;

            _totalStaked                -= posAmount;
            _stakingBalance[msg.sender] -= posAmount;

            // Decrement staker count
            projectsContract.decrementStakerCount(projectId);

            // Clear the position
            delete _stakingPositions[msg.sender][projectId];

            emit Unstaked(msg.sender, projectId, posAmount - penalty, penalty, block.timestamp);
        }

        // Update governance votes
        if (_stakingBalance[msg.sender] < GOVERNANCE_THRESHOLD) {
            _governanceVotes[msg.sender] = 0;
        } else {
            _governanceVotes[msg.sender] = _stakingBalance[msg.sender];
        }

        // Check validator status
        if (_validators[msg.sender] && _stakingBalance[msg.sender] < validatorThreshold) {
            _validators[msg.sender] = false;
            emit ValidatorStatusChanged(msg.sender, false);
        }

        // Transfer the user's net tokens
        if (totalAmount > 0) {
            bool success = stakingToken.transfer(msg.sender, totalAmount);
            if (!success) {
                revert TransferFailed(address(stakingToken), address(this), msg.sender, totalAmount);
            }
        }

        // Process penalty distributions
        if (totalPenalty > 0) {
            // Burn portion
            if (totalToBurn > 0) {
                bool success = stakingToken.transfer(BURN_ADDRESS, totalToBurn);
                if (!success) {
                    revert TransferFailed(address(stakingToken), address(this), BURN_ADDRESS, totalToBurn);
                }
                emit SlashedTokensBurned(totalToBurn);
            }
            // Redistribute portion
            if (totalToRedistribute > 0) {
                bool success = stakingToken.transfer(address(rewardDistributor), totalToRedistribute);
                if (!success) {
                    revert TransferFailed(address(stakingToken), address(this), address(rewardDistributor), totalToRedistribute);
                }
                rewardDistributor.addPenaltyRewards(totalToRedistribute);
                emit SlashedTokensDistributed(totalToRedistribute);
            }
            // Liquidity portion
            if (totalToLiquidity > 0) {
                bool success = stakingToken.transfer(liquidityPool, totalToLiquidity);
                if (!success) {
                    revert TransferFailed(address(stakingToken), address(this), liquidityPool, totalToLiquidity);
                }
                emit LiquidityInjected(liquidityPool, totalToLiquidity, block.timestamp);
            }
        }

        if (_stakingBalance[msg.sender] == 0) {
            _isActiveStaker[msg.sender] = false;
            _removeInactiveStaker(msg.sender);
        }
    }

    /**
     * @notice Claim rewards for a single project.
     */
    function claimRewards(uint256 projectId) external nonReentrant {
        _claimRewards(msg.sender, projectId);
    }

    /**
     * @dev Internal function to claim user rewards up to now.
     */
    function _claimRewards(address user, uint256 projectId) internal {
        StakingPosition storage position = _stakingPositions[user][projectId];
        if (position.amount == 0) {
            revert NoActiveStakingPosition(user, projectId);
        }
        uint256 reward = calculateRewards(user, projectId);
        if (reward == 0) {
            position.lastCheckpoint = block.timestamp;
            return;
        }

        // Auto-compounding logic
        if (position.autoCompounding) {
            uint256 compoundAmount = (reward * 20) / 100; // 20% of reward is auto-compounded
            position.amount        += compoundAmount;
            _totalStaked           += compoundAmount;
            _stakingBalance[user]  += compoundAmount;

            // If user crosses threshold again
            if (_stakingBalance[user] >= GOVERNANCE_THRESHOLD && !_governanceViolators[user]) {
                _governanceVotes[user] = _stakingBalance[user];
            }
            reward -= compoundAmount;

            emit RewardCompounded(user, projectId, compoundAmount, block.timestamp);
        }

        // Liquidity injection if enabled
        if (autoLiquidityEnabled) {
            uint256 liquidityAmount = (reward * liquidityInjectionRate) / 100;
            if (liquidityAmount > 0) {
                reward -= liquidityAmount;
                bool liqSuccess = stakingToken.transfer(liquidityPool, liquidityAmount);
                if (!liqSuccess) {
                    revert TransferFailed(address(stakingToken), address(this), liquidityPool, liquidityAmount);
                }
                emit LiquidityInjected(liquidityPool, liquidityAmount, block.timestamp);
            }
        }

        // Additional logic to distribute validator portion
        _distributeValidatorRewards(reward);

        position.lastCheckpoint = block.timestamp;

        // Send the remainder to user
        if (reward > 0) {
            bool success = rewardDistributor.distributeReward(user, reward);
            if (!success) {
                revert DistributionFailed(reward);
            }
            emit RewardClaimed(user, projectId, reward, block.timestamp);
        }
    }

    /**
     * @dev Splits off 5% of the reward to validator pool.
     */
    function _distributeValidatorRewards(uint256 rewardAmount) internal {
        uint256 validatorShare = (rewardAmount * 5) / 100;
        if (validatorShare > 0) {
            validatorRewardPool += validatorShare;
            emit ValidatorRewardsAccumulated(validatorShare, validatorRewardPool);
        }
    }

    /**
     * @dev Apply the standard penalty distribution for early unstake events.
     */
    function _handlePenalty(address user, uint256 projectId, uint256 penaltyAmount) internal {
        uint256 burnAmount         = (penaltyAmount * 40) / 100; // 40%
        uint256 redistributeAmount = (penaltyAmount * 40) / 100; // 40%
        uint256 liquidityAmount    = penaltyAmount - burnAmount - redistributeAmount;

        bool success = stakingToken.transfer(BURN_ADDRESS, burnAmount);
        if (!success) {
            revert TransferFailed(address(stakingToken), address(this), BURN_ADDRESS, burnAmount);
        }
        success = stakingToken.transfer(address(rewardDistributor), redistributeAmount);
        if (!success) {
            revert TransferFailed(address(stakingToken), address(this), address(rewardDistributor), redistributeAmount);
        }
        success = stakingToken.transfer(liquidityPool, liquidityAmount);
        if (!success) {
            revert TransferFailed(address(stakingToken), address(this), liquidityPool, liquidityAmount);
        }

        PenaltyEvent memory penEvent = PenaltyEvent({
            projectId:     projectId,
            timestamp:     block.timestamp,
            totalPenalty:  penaltyAmount,
            redistributed: redistributeAmount,
            burned:        burnAmount,
            toLiquidity:   liquidityAmount
        });
        _penaltyHistory[user].push(penEvent);

        emit PenaltyApplied(
            user,
            projectId,
            penaltyAmount,
            burnAmount,
            redistributeAmount,
            liquidityAmount
        );
    }

    /**
     * @dev Removes an address from the `_activeStakers` array in O(1) time.
     */
    function _removeInactiveStaker(address staker) internal {
        uint256 length = _activeStakers.length;
        for (uint256 i = 0; i < length; i++) {
            if (_activeStakers[i] == staker) {
                _activeStakers[i] = _activeStakers[length - 1];
                _activeStakers.pop();
                return;
            }
        }
    }

    /**
     * @notice Get the list of active stakers
     */
    function getActiveStakers() external view returns (address[] memory) {
        return _activeStakers;
    }

    // -------------------------------------------
    //   Validator Operations
    // -------------------------------------------

    /**
     * @notice Called by a user to explicitly become a validator if their stake is sufficient.
     */
    function becomeValidator() external nonReentrant whenNotPaused {
        if (_validators[msg.sender]) {
            revert AlreadyValidator(msg.sender);
        }
        if (_stakingBalance[msg.sender] < validatorThreshold) {
            revert InvalidParameter("validatorThreshold", _stakingBalance[msg.sender]);
        }
        _validators[msg.sender] = true;
        _validatorCommission[msg.sender] = 500; // Default 5% commission in basis points
        emit ValidatorAdded(msg.sender, block.timestamp);
    }

    /**
     * @notice Claim the portion of validatorRewardPool allocated to each validator
     */
    function claimValidatorRewards() external nonReentrant {
        if (!_validators[msg.sender]) {
            revert NotValidator(msg.sender);
        }
        
        uint256 validatorCount = 0;
        for (uint256 i = 0; i < _activeStakers.length; i++) {
            if (_validators[_activeStakers[i]]) {
                validatorCount++;
            }
        }
        
        if (validatorCount == 0) {
            return; // no distribution possible
        }
        
        uint256 rewardPerValidator = validatorRewardPool / validatorCount;
        validatorRewardPool = 0;

        bool success = rewardDistributor.distributeReward(msg.sender, rewardPerValidator);
        if (!success) {
            revert DistributionFailed(rewardPerValidator);
        }
        emit ValidatorRewardsDistributed(msg.sender, rewardPerValidator);
    }

    /**
     * @notice Update your commission rate (max 20%).
     */
    function updateValidatorCommission(uint256 newCommissionRate) external {
        if (!_validators[msg.sender]) {
            revert NotValidator(msg.sender);
        }
        if (newCommissionRate > 2000) { // 2000 => 20%
            revert RateTooHigh(newCommissionRate, 2000);
        }
        _validatorCommission[msg.sender] = newCommissionRate;
        emit ValidatorCommissionUpdated(msg.sender, newCommissionRate);
    }

    // -------------------------------------------
    //   Governance Operations
    // -------------------------------------------

    function voteOnProposal(uint256 proposalId, bool support) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        if (_governanceViolators[msg.sender]) {
            revert GovernanceViolation(msg.sender);
        }
        uint256 votingPower = _governanceVotes[msg.sender];
        if (votingPower == 0) {
            revert InvalidParameter("votingPower", votingPower);
        }
        governanceContract.recordVote(proposalId, msg.sender, votingPower, support);
        emit ProposalVoted(proposalId, msg.sender, votingPower, support);
    }

    function createProposal(
        string calldata description,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[]   calldata calldatas
    )
        external
        nonReentrant
        whenNotPaused
    {
        if (_governanceViolators[msg.sender]) {
            revert GovernanceViolation(msg.sender);
        }
        uint256 votingPower = _governanceVotes[msg.sender];
        if (votingPower < GOVERNANCE_THRESHOLD) {
            revert InvalidParameter("votingPower", votingPower);
        }
        proposalNonce++;
        uint256 proposalId = governanceContract.createProposal(
            proposalNonce,
            msg.sender,
            description,
            targets,
            values,
            calldatas
        );
        emit GovernanceProposalCreated(proposalId, msg.sender, description);
    }

    function markGovernanceViolator(address violator) external onlyRole(GOVERNANCE_ROLE) {
        _governanceViolators[violator] = true;
        _governanceVotes[violator]     = 0;
        emit GovernanceViolatorMarked(violator, block.timestamp);
    }

    /**
     * @notice Slashes a user's governance voting rights as penalty for governance violations
     * @param user Address of the user whose governance voting rights will be slashed
     * @return The amount of voting power that was slashed
     */
    function slashGovernanceVote(address user) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
        returns (uint256) 
    {
        if (_governanceViolators[user]) {
            return 0; // Already a violator
        }
        
        uint256 slashedAmount = _governanceVotes[user];
        if (slashedAmount == 0) {
            return 0; // No voting power to slash
        }
        
        // Mark as violator and remove voting power
        _governanceViolators[user] = true;
        _governanceVotes[user] = 0;
        
        emit GovernanceViolatorMarked(user, block.timestamp);
        
        return slashedAmount;
    }

    /**
     * @notice Applies halving to reward rates, reducing them according to the protocol's emission schedule
     * @dev Can only be called by governance or admin roles
     * @return The new halving epoch number
     */
    function applyHalving() 
        external 
        onlyRole(GOVERNANCE_ROLE) 
        returns (uint256) 
    {
        // Store old values for event emission
        uint256 oldBaseAPR = dynamicBaseAPR;
        uint256 oldBoostedAPR = dynamicBoostedAPR;
        
        // Apply the halving (reducing both APRs by 50%)
        dynamicBaseAPR = dynamicBaseAPR / 2;
        dynamicBoostedAPR = dynamicBoostedAPR / 2;
        
        // Ensure minimum values
        if (dynamicBaseAPR < 1) dynamicBaseAPR = 1;
        if (dynamicBoostedAPR < 2) dynamicBoostedAPR = 2;
        
        // Update halving state
        halvingEpoch++;
        lastHalvingTime = block.timestamp;
        
        emit HalvingApplied(
            halvingEpoch,
            oldBaseAPR,
            dynamicBaseAPR,
            oldBoostedAPR,
            dynamicBoostedAPR
        );
        
        return halvingEpoch;
    }

    // -------------------------------------------
    //   Administrative & Emergency
    // -------------------------------------------

    /**
     * @notice Update the staking tiers in bulk. 
     * @dev This re-initializes the _tiers array. Ensure sorted ascending durations for best logic.
     */
    function updateTiers(
        uint256[] calldata minDurations,
        uint256[] calldata multipliers,
        bool[]    calldata votingRights
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (
            minDurations.length != multipliers.length ||
            minDurations.length != votingRights.length
        ) {
            revert InvalidTierConfiguration();
        }
        // Clear existing
        delete _tiers;

        // Rebuild with new
        for (uint256 i = 0; i < minDurations.length; i++) {
            if (minDurations[i] < MIN_STAKING_DURATION) {
                revert InsufficientStakingDuration(MIN_STAKING_DURATION, minDurations[i]);
            }
            _tiers.push(StakingTier(
                minDurations[i],
                multipliers[i],
                votingRights[i]
            ));
        }
        emit TiersUpdated(minDurations, multipliers, votingRights);
    }

    function setLiquidityInjectionRate(uint256 newRate) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (newRate > MAX_LIQUIDITY_RATE) {
            revert RateTooHigh(newRate, MAX_LIQUIDITY_RATE);
        }
        liquidityInjectionRate = newRate;
        emit LiquidityInjectionRateUpdated(newRate);
    }

    function toggleAutoLiquidity(bool enabled) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        autoLiquidityEnabled = enabled;
        emit AutoLiquidityToggled(enabled);
    }

    function setValidatorThreshold(uint256 newThreshold) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (newThreshold == 0) {
            revert InvalidParameter("newThreshold", newThreshold);
        }
        validatorThreshold = newThreshold;
        emit ValidatorThresholdUpdated(newThreshold);
    }

    function setRewardDistributor(address newDistributor)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (newDistributor == address(0)) {
            revert InvalidAddress("newDistributor", newDistributor);
        }
        rewardDistributor = ITerraStakeRewardDistributor(newDistributor);
        emit RewardDistributorUpdated(newDistributor);
    }

    function setLiquidityPool(address newPool)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (newPool == address(0)) {
            revert InvalidAddress("newPool", newPool);
        }
        liquidityPool = newPool;
        emit LiquidityPoolUpdated(newPool);
    }

    function setSlashingContract(address newSlashingContract)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (newSlashingContract == address(0)) {
            revert InvalidAddress("newSlashingContract", newSlashingContract);
        }
        slashingContract = ITerraStakeSlashing(newSlashingContract);
        emit SlashingContractUpdated(newSlashingContract);
    }

    function setGovernanceQuorum(uint256 newQuorum)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        governanceQuorum = newQuorum;
        emit GovernanceQuorumUpdated(newQuorum);
    }

    function toggleDynamicRewards(bool enabled)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        dynamicRewardsEnabled = enabled;
        emit DynamicRewardsToggled(enabled);
    }

    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Recover ERC20 tokens accidentally sent here, except the staked ones.
     * @dev If `token == stakingToken`, we only allow the admin to withdraw the excess above `_totalStaked`.
     */
    function recoverERC20(address token)
        external
        onlyRole(EMERGENCY_ROLE)
        returns (bool)
    {
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (token == address(stakingToken)) {
            // We can only withdraw the portion that is not staked
            amount = amount - _totalStaked; 
        }
        bool success = IERC20(token).transfer(msg.sender, amount);
        if (!success) {
            revert TransferFailed(token, address(this), msg.sender, amount);
        }
        emit TokenRecovered(token, amount, msg.sender);
        return true;
    }

    // -------------------------------------------
    //   Slashing
    // -------------------------------------------

    function slash(address validator, uint256 amount) 
        external 
        onlyRole(SLASHER_ROLE)
        returns (bool) 
    {
        if (!_validators[validator]) {
            revert NotValidator(validator);
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        uint256 userBalance = _stakingBalance[validator];
        if (userBalance < amount) {
            amount = userBalance;
        }
        if (amount == 0) {
            return false;
        }

        // Update staker's total
        _stakingBalance[validator] -= amount;
        _totalStaked               -= amount;

        // Remove validator status if they drop below threshold
        if (_stakingBalance[validator] < validatorThreshold) {
            _validators[validator] = false;
            emit ValidatorStatusChanged(validator, false);
        }

        // The actual penalty distribution
        _handlePenalty(validator, 0, amount);

        emit Slashed(validator, amount, block.timestamp);
        return true;
    }

    // -------------------------------------------
    //   View Functions
    // -------------------------------------------

    /**
     * @notice Calculates user's pending rewards for a specific position.
     */
    function calculateRewards(address user, uint256 projectId)
        public
        view
        returns (uint256)
    {
        StakingPosition storage position = _stakingPositions[user][projectId];
        if (position.amount == 0) {
            return 0;
        }

        uint256 stakingTime = block.timestamp - position.lastCheckpoint;
        if (stakingTime == 0) {
            return 0;
        }

        // Tier multiplier
        uint256 tierId       = getApplicableTier(position.duration);
        uint256 tierMult     = _tiers[tierId].multiplier;

        // Base APR logic (with halving/dynamic approach)
        uint256 baseRate = (_totalStaked < LOW_STAKING_THRESHOLD)
            ? dynamicBoostedAPR
            : dynamicBaseAPR;

        // Additional conditions
        if (position.hasNFTBoost) {
            baseRate += NFT_APR_BOOST;
        }
        if (position.isLPStaker) {
            baseRate += LP_APR_BOOST;
        }

        uint256 effectiveRate = (baseRate * tierMult) / 100;

        // annualReward = principal * effRate / 100
        // but we do pro-rata for stakingTime / year
        uint256 reward = (position.amount * effectiveRate * stakingTime)
            / (100 * 365 days);

        return reward;
    }

    /**
     * @notice Finds the staking tier index that applies for a given duration.
     */
    function getApplicableTier(uint256 duration) public view returns (uint256) {
        uint256 applicableTier = 0;
        for (uint256 i = 0; i < _tiers.length; i++) {
            if (duration >= _tiers[i].minDuration) {
                applicableTier = i;
            } else {
                break;
            }
        }
        return applicableTier;
    }

    function getUserStake(address user, uint256 projectId) external view returns (uint256) {
        return _stakingPositions[user][projectId].amount;
    }

    function getUserTotalStake(address user) external view returns (uint256) {
        return _stakingBalance[user];
    }

    function getUserPositions(address user) external view returns (StakingPosition[] memory positions) {
        // We gather from the project contract how many total projects exist
        // Then filter the user's staked positions
        uint256 projectCount = projectsContract.getProjectCount();
        uint256 count        = 0;

        for (uint256 i = 1; i <= projectCount; i++) {
            if (_stakingPositions[user][i].amount > 0) {
                count++;
            }
        }

        positions = new StakingPosition[](count);
        uint256 index = 0;

        for (uint256 i = 1; i <= projectCount; i++) {
            if (_stakingPositions[user][i].amount > 0) {
                positions[index] = _stakingPositions[user][i];
                index++;
            }
        }
        return positions;
    }

    function getPenaltyHistory(address user) external view returns (PenaltyEvent[] memory) {
        return _penaltyHistory[user];
    }

    function isValidator(address user) external view returns (bool) {
        return _validators[user];
    }

    function getValidatorCommission(address validator) external view returns (uint256) {
        return _validatorCommission[validator];
    }

    function isGovernanceViolator(address user) external view returns (bool) {
        return _governanceViolators[user];
    }

    function getGovernanceVotes(address user) external view returns (uint256) {
        return _governanceVotes[user];
    }

    function getTotalStaked() external view returns (uint256) {
        return _totalStaked;
    }

    /**
     * @notice Get the total amount of staked tokens
     * @return Total staked tokens
     */
    function totalStakedTokens() external view returns (uint256) {
        return _totalStaked;
    }

    function getValidatorRewardPool() external view returns (uint256) {
        return validatorRewardPool;
    }

    function getAllTiers() external view returns (StakingTier[] memory) {
        return _tiers;
    }

    /**
     * @notice Returns the top stakers up to `limit`.
     * @dev Uses an optimized partial selection sort algorithm that only sorts the top 'limit' elements
     *      for better performance O(n*limit) instead of O(n²).
     */
    function getTopStakers(uint256 limit)
        external
        view
        returns (address[] memory stakers, uint256[] memory amounts)
    {
        uint256 stakerCount = _activeStakers.length;
    
        // Cap the limit at the active stakers count
        if (limit > stakerCount) {
            limit = stakerCount;
        }
    
        if (limit == 0) {
            return (new address[](0), new uint256[](0));
        }

        // Initialize result arrays
        stakers = new address[](limit);
        amounts = new uint256[](limit);
    
        // Work with temporary arrays for selection process
        address[] memory tempStakers = new address[](stakerCount);
        uint256[] memory tempAmounts = new uint256[](stakerCount);

        // Populate temporary arrays
        for (uint256 i = 0; i < stakerCount; i++) {
            tempStakers[i] = _activeStakers[i];
            tempAmounts[i] = _stakingBalance[_activeStakers[i]];
        }
    
        // Find top 'limit' elements using partial selection sort
        // This is more efficient because we only sort what we need
        for (uint256 i = 0; i < limit; i++) {
            uint256 maxIndex = i;
        
            // Find the maximum value in the remaining unsorted portion
            for (uint256 j = i + 1; j < stakerCount; j++) {
                if (tempAmounts[j] > tempAmounts[maxIndex]) {
                    maxIndex = j;
                }
            }
        
            // If we found a new maximum, swap it to the current position
            if (maxIndex != i) {
                // Swap amounts
                uint256 tempAmount = tempAmounts[i];
                tempAmounts[i] = tempAmounts[maxIndex];
                tempAmounts[maxIndex] = tempAmount;
            
                // Swap addresses
                address tempAddr = tempStakers[i];
                tempStakers[i] = tempStakers[maxIndex];
                tempStakers[maxIndex] = tempAddr;
            }
        
            // Add to result arrays
            stakers[i] = tempStakers[i];
            amounts[i] = tempAmounts[i];
        }
    
        return (stakers, amounts);
    }

    /**
     * @notice Get the current count of validators
     * @return Number of validators
     */
    function getValidatorCount() external view returns (uint256) {
        uint256 count = 0;
        // Count the validators
        for (uint256 i = 0; i < _activeStakers.length; i++) {
            if (_validators[_activeStakers[i]]) {
                count++;
            }
        }
        return count;
    }

   
    /**
     * @notice Basic version info.
     */
    function version() external pure returns (string memory) {
        return "1.0.0-improved";
    }

    /**
     * @notice Apply halving to reward rates when the period has elapsed.
     * @dev Can be called by anyone, but effect happens at most once per halvingPeriod.
     */
    function applyHalvingIfNeeded() external {
        uint256 timeElapsed = block.timestamp - lastHalvingTime;
        if (timeElapsed < halvingPeriod) {
            return;
        }

        uint256 oldBaseAPR = dynamicBaseAPR;
        uint256 oldBoostedAPR = dynamicBoostedAPR;

        // Apply halving: divide rates by 2
        dynamicBaseAPR = dynamicBaseAPR / 2;
        dynamicBoostedAPR = dynamicBoostedAPR / 2;
        
        // Ensure minimum values
        if (dynamicBaseAPR < 1) {
            dynamicBaseAPR = 1;
        }
        if (dynamicBoostedAPR < 2) {
            dynamicBoostedAPR = 2;
        }

        lastHalvingTime = block.timestamp;
        halvingEpoch++;

        emit HalvingApplied(
            halvingEpoch,
            oldBaseAPR,
            dynamicBaseAPR,
            oldBoostedAPR,
            dynamicBoostedAPR
        );
    }

    /**
     * @notice Adjust reward rates based on a dynamic formula (if enabled).
     * @dev This can be called by any address to update rates.
     */
    function adjustRewardRates() external {
        if (!dynamicRewardsEnabled) {
            return;
        }

        // Can only adjust once per day
        if (block.timestamp - lastRewardAdjustmentTime < 1 days) {
            return;
        }

        uint256 oldBaseAPR = dynamicBaseAPR;
        
        // Example dynamic adjustment: base APR adjusts based on total staking
        if (_totalStaked < LOW_STAKING_THRESHOLD / 10) {
            // Extremely low staking, boost rates
            dynamicBaseAPR = 15;
            dynamicBoostedAPR = 30;
        } else if (_totalStaked < LOW_STAKING_THRESHOLD / 2) {
            // Low staking, moderate boost
            dynamicBaseAPR = 12;
            dynamicBoostedAPR = 24;
        } else if (_totalStaked < LOW_STAKING_THRESHOLD) {
            // Approaching threshold, smaller boost
            dynamicBaseAPR = BASE_APR;
            dynamicBoostedAPR = BOOSTED_APR;
        } else {
            // Above threshold, use base rates
            dynamicBaseAPR = 8;
            dynamicBoostedAPR = 16;
        }

        lastRewardAdjustmentTime = block.timestamp;
        
        emit RewardRateAdjusted(oldBaseAPR, dynamicBaseAPR);
    }

    /**
 * @dev Implements ERC165 interface detection with comprehensive support
 * @notice Explicitly declares all interfaces supported by this contract
 * @param interfaceId The interface identifier to check
 * @return bool True if the interface is supported
 */
function supportsInterface(bytes4 interfaceId)
    public
    view
    override(AccessControlEnumerableUpgradeable, ERC165Upgradeable)
    returns (bool)
{
    return
        interfaceId == type(ITerraStakeStaking).interfaceId ||
        // Add any other custom interfaces from your project
        interfaceId == type(IPausableUpgradeable).interfaceId ||
        interfaceId == type(IReentrancyGuardUpgradeable).interfaceId ||
        interfaceId == type(IERC165Upgradeable).interfaceId ||
        interfaceId == type(IAccessControlEnumerableUpgradeable).interfaceId ||
        interfaceId == type(IAccessControlUpgradeable).interfaceId ||
        super.supportsInterface(interfaceId);
}

/**
 * @dev Internal function to register a new interface
 * @notice Use this in future upgrades when adding new interfaces
 * @param interfaceId The interface identifier to register
 */
function _registerInterfaceImplementation(bytes4 interfaceId) internal {
    _registerInterface(interfaceId);
}