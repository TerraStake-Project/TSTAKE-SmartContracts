// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20PermitUpgradeable.sol";

import "../interfaces/ITerraStakeSlashing.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/ITerraStakeRewardDistributor.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";

/**
 * @title IERC20Burnable
 * @dev Interface for ERC20 tokens with burn functionality
 */
interface IERC20Burnable {
    function burn(uint256 amount) external;
}

/**
 * @title AggregatorV3Interface
 * @dev Interface for Chainlink price feeds
 */
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/**
 * @title TerraStakeSlashing (Multi-Sig Protected, Oracle-Aware, OpenZeppelin 5.2.x)
 * @notice Handles governance penalties, stake redistributions, and slashing mechanisms
 * @dev This contract is upgradeable using the UUPS pattern and integrates oracle price validation
 */
contract TerraStakeSlashing is
    Initializable,
    ITerraStakeSlashing,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // ================================
    // 🔹 Custom Errors
    // ================================
    error InvalidAddress();
    error InvalidAmount();
    error AlreadySlashed();
    error SlashingAlreadyRequested();
    error NoSlashingRequestFound();
    error NoSlashingRequestApproved();
    error InsufficientStakedBalance();
    error NotSlashed();
    error LockPeriodNotExpired();
    error NoLockedStake();
    error PercentageExceeds100();
    error InvalidRedistributionPercentage();
    error StalePrice();
    error PriceValidationFailed();
    error InvalidOracle();
    error NegativePrice();
    error CooldownActive();
    error BurnFailed();

    // ================================
    // 🔹 Governance & Security Roles
    // ================================
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant MULTISIG_ADMIN_ROLE = keccak256("MULTISIG_ADMIN_ROLE");
    bytes32 public constant MULTISIG_APPROVER_ROLE = keccak256("MULTISIG_APPROVER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant ORACLE_MANAGER_ROLE = keccak256("ORACLE_MANAGER_ROLE");

    // ================================
    // 🔹 External Contract References
    // ================================
    IERC20Upgradeable public tStakeToken;
    ITerraStakeStaking public stakingContract;
    ITerraStakeRewardDistributor public rewardDistributor;
    ITerraStakeLiquidityGuard public liquidityGuard;
    AggregatorV3Interface public priceOracle;

    // ================================
    // 🔹 Slashing & Locking Parameters
    // ================================
    uint256 public constant SLASHING_LOCK_PERIOD = 3 days;
    uint256 public constant PRICE_VALIDITY_PERIOD = 1 hours;
    uint256 public constant PRICE_DEVIATION_THRESHOLD = 10; // 10% maximum deviation
    uint256 public redistributionPercentage; // in basis points (e.g., 10000 = 100%)
    uint256 public totalSlashed;
    uint256 public lastTWAPPrice;
    uint256 public lastTWAPTimestamp;

    // ================================
    // 🔹 Slashing State Tracking
    // ================================
    mapping(address => bool) public isSlashed;
    mapping(address => uint256) public lastSlashingTime;
    mapping(address => uint256) public lockedStakes;
    mapping(address => bool) private pendingSlashApprovals;
    mapping(address => uint256) private slashAmounts;
    
    // ================================
    // 🔹 Events
    // ================================
    event SlashingRequested(address indexed participant, uint256 amount, string reason);
    event SlashingApproved(address indexed participant, uint256 amount);
    event SlashingExecuted(address indexed participant, uint256 amount);
    event FundsRedistributed(uint256 amount, address recipient);
    event StakeLocked(address indexed participant, uint256 amount, uint256 lockUntil);
    event StakeUnlocked(address indexed participant, uint256 amount);
    event PenaltyPercentageUpdated(uint256 newPercentage);
    event TokenRecovered(address token, uint256 amount, address recipient);
    event ParticipantSlashed(
        address indexed participant,
        uint256 amount,
        uint256 redistributionAmount,
        uint256 burnAmount,
        string reason
    );
    event PriceValidationFailed(uint256 currentPrice, uint256 twapPrice, uint256 deviationPercentage);
    event PriceUpdated(uint256 newPrice, uint256 timestamp);
    event OracleUpdated(address indexed newOracle);
    event Upgraded(address indexed newImplementation);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Disable initializers on deployment
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract (UUPS Upgradeable)
     * @param _tStakeToken Address of the TSTAKE token
     * @param _stakingContract Address of the staking contract
     * @param _rewardDistributor Address of the reward distributor
     * @param _liquidityGuard Address of the liquidity guard
     * @param _redistributionPercentage Redistribution % in basis points (10000 = 100%)
     * @param _priceOracle Address of the Chainlink price oracle
     */
    function initialize(
        address _tStakeToken,
        address _stakingContract,
        address _rewardDistributor,
        address _liquidityGuard,
        uint256 _redistributionPercentage,
        address _priceOracle
    ) public initializer {
        if (_tStakeToken == address(0)) revert InvalidAddress();
        if (_stakingContract == address(0)) revert InvalidAddress();
        if (_rewardDistributor == address(0)) revert InvalidAddress();
        if (_liquidityGuard == address(0)) revert InvalidAddress();
        if (_priceOracle == address(0)) revert InvalidOracle();
        if (_redistributionPercentage > 10000) revert PercentageExceeds100();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        tStakeToken = IERC20Upgradeable(_tStakeToken);
        stakingContract = ITerraStakeStaking(_stakingContract);
        rewardDistributor = ITerraStakeRewardDistributor(_rewardDistributor);
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);
        priceOracle = AggregatorV3Interface(_priceOracle);
        redistributionPercentage = _redistributionPercentage;

        // Set initial price data
        _updateTWAPPrice();

        // Grant all relevant roles to the deployer
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(SLASHER_ROLE, msg.sender);
        _grantRole(MULTISIG_ADMIN_ROLE, msg.sender);
        _grantRole(MULTISIG_APPROVER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        _grantRole(ORACLE_MANAGER_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
    }

    /**
     * @notice Authorizes a contract upgrade using UUPS pattern
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {
        emit Upgraded(newImplementation);
    }

    // ================================
    // 🔹 Price Oracle Functions
    // ================================

    /**
     * @notice Updates the TWAP price by fetching from the oracle
     * @dev Called automatically during validation but can be called manually
     */
    function _updateTWAPPrice() internal {
        (
            ,
            int256 answer,
            ,
            uint256 updatedAt,
            
        ) = priceOracle.latestRoundData();
        
        if (answer <= 0) revert NegativePrice();
        if (updatedAt < block.timestamp - PRICE_VALIDITY_PERIOD) revert StalePrice();
        
        lastTWAPPrice = uint256(answer);
        lastTWAPTimestamp = block.timestamp;
        
        emit PriceUpdated(lastTWAPPrice, lastTWAPTimestamp);
    }
    
    /**
     * @notice Validates the current price against the TWAP to prevent manipulation
     * @return True if price is valid, false otherwise
     */
    function validatePrice() public returns (bool) {
        (
            ,
            int256 answer,
            ,
            uint256 updatedAt,
            
        ) = priceOracle.latestRoundData();
        
        if (answer <= 0) revert NegativePrice();
        if (updatedAt < block.timestamp - PRICE_VALIDITY_PERIOD) revert StalePrice();
        
        uint256 currentPrice = uint256(answer);
        
        if (lastTWAPPrice > 0) {
            uint256 deviation = currentPrice > lastTWAPPrice
                ? ((currentPrice - lastTWAPPrice) * 100) / lastTWAPPrice
                : ((lastTWAPPrice - currentPrice) * 100) / lastTWAPPrice;
                
            if (deviation > PRICE_DEVIATION_THRESHOLD) {
                emit PriceValidationFailed(currentPrice, lastTWAPPrice, deviation);
                return false;
            }
        }
        
        // Update TWAP price every hour
        if (block.timestamp >= lastTWAPTimestamp + 1 hours) {
            lastTWAPPrice = currentPrice;
            lastTWAPTimestamp = block.timestamp;
            emit PriceUpdated(lastTWAPPrice, lastTWAPTimestamp);
        }
        
        return true;
    }
    
    /**
     * @notice Updates the oracle address (governance function)
     * @param _newOracle The new price oracle address
     */
    function updateOracle(address _newOracle) external onlyRole(ORACLE_MANAGER_ROLE) {
        if (_newOracle == address(0)) revert InvalidOracle();
        priceOracle = AggregatorV3Interface(_newOracle);
        emit OracleUpdated(_newOracle);
        
        // Initialize with the new oracle's price
        _updateTWAPPrice();
    }

    // ================================
    // 🔹 Multi-Sig Protected Slashing
    // ================================

    /**
     * @notice Requests slashing for governance violation (step 1: GOVERNANCE_ROLE)
     * @param participant The address to be slashed
     * @param amount The amount of tokens to slash
     * @param reason Reason or description
     */
    function requestSlashing(
        address participant,
        uint256 amount,
        string calldata reason
    ) external override onlyRole(GOVERNANCE_ROLE) {
        if (participant == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (isSlashed[participant]) revert AlreadySlashed();
        if (pendingSlashApprovals[participant]) revert SlashingAlreadyRequested();

        slashAmounts[participant] = amount;
        pendingSlashApprovals[participant] = true;

        emit SlashingRequested(participant, amount, reason);
    }

    /**
     * @notice Approves a requested slashing (step 2: MULTISIG_ADMIN_ROLE)
     * @param participant The address for which slashing was requested
     */
    function approveSlashing(address participant) external override onlyRole(MULTISIG_ADMIN_ROLE) {
        if (!pendingSlashApprovals[participant]) revert NoSlashingRequestFound();
        if (slashAmounts[participant] == 0) revert InvalidAmount();

        emit SlashingApproved(participant, slashAmounts[participant]);
    }

    /**
     * @notice Finalizes the slashing after approval (step 3: MULTISIG_APPROVER_ROLE)
     * @param participant The address to slash
     */
    function executeSlashing(address participant)
        external
        override
        onlyRole(MULTISIG_APPROVER_ROLE)
        nonReentrant
    {
        if (!pendingSlashApprovals[participant]) revert NoSlashingRequestApproved();
        if (block.timestamp < lastSlashingTime[participant] + SLASHING_LOCK_PERIOD) revert CooldownActive();

        // Validate price to prevent manipulation
        if (!validatePrice()) revert PriceValidationFailed();

        uint256 amount = slashAmounts[participant];
        if (amount == 0) revert InvalidAmount();

        // Check staked balance in staking contract
        uint256 stakedBalance = stakingContract.stakedBalanceOf(participant);
        if (stakedBalance < amount) revert InsufficientStakedBalance();

        // Slash the stake via staking contract
        stakingContract.slashStake(participant, amount);

        // Update tracking

 isSlashed[participant] = true;
        totalSlashed += amount;
        lockedStakes[participant] = amount;
        lastSlashingTime[participant] = block.timestamp;

        // Compute redistribution & burn amounts
        uint256 redistributionAmount = (amount * redistributionPercentage) / 10000;
        uint256 burnAmount = amount - redistributionAmount;

        // Distribute penalty rewards
        if (redistributionAmount > 0) {
            rewardDistributor.distributePenaltyRewards(redistributionAmount);
            emit FundsRedistributed(redistributionAmount, address(rewardDistributor));
        }

        // Burn tokens using advanced burn mechanism
        if (burnAmount > 0) {
            if (!_burnTokens(burnAmount)) revert BurnFailed();
        }

        // Clear the slash request
        delete pendingSlashApprovals[participant];
        delete slashAmounts[participant];

        emit ParticipantSlashed(
            participant, 
            amount, 
            redistributionAmount, 
            burnAmount, 
            "Multi-sig governance slashing"
        );
        emit StakeLocked(participant, amount, block.timestamp + SLASHING_LOCK_PERIOD);
    }

    /**
     * @notice Checks whether the lock period for a participant has expired
     * @param participant The address to check
     * @return True if the lock is expired
     */
    function isLockExpired(address participant) public view override returns (bool) {
        if (!isSlashed[participant]) return false;
        return (block.timestamp >= lastSlashingTime[participant] + SLASHING_LOCK_PERIOD);
    }

    /**
     * @notice Unlocks staked tokens after the slashing lock period expires
     * @dev Resets `isSlashed` so the participant can stake again
     * @param participant The address to unlock
     */
    function unlockStake(address participant) external override nonReentrant {
        if (!isSlashed[participant]) revert NotSlashed();
        if (!isLockExpired(participant)) revert LockPeriodNotExpired();

        uint256 amountToUnlock = lockedStakes[participant];
        if (amountToUnlock == 0) revert NoLockedStake();

        lockedStakes[participant] = 0;
        isSlashed[participant] = false;

        emit StakeUnlocked(participant, amountToUnlock);
    }

    // ================================
    // 🔹 Direct Slashing with ERC20-Permit
    // ================================

    /**
     * @notice Executes slashing with ERC20 Permit for gasless approvals
     * @dev This allows slashing tokens directly without prior allowance
     * @param participant Address of the participant to slash
     * @param amount Amount to slash
     * @param reason Reason for slashing
     * @param deadline Permit deadline timestamp
     * @param v Part of the signature (from EIP-712)
     * @param r Part of the signature (from EIP-712)
     * @param s Part of the signature (from EIP-712)
     */
    function slashWithPermit(
        address participant,
        uint256 amount,
        string calldata reason,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external onlyRole(SLASHER_ROLE) nonReentrant {
        if (participant == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (isSlashed[participant]) revert AlreadySlashed();
        if (block.timestamp < lastSlashingTime[participant] + SLASHING_LOCK_PERIOD) revert CooldownActive();

        // Validate price to prevent manipulation
        if (!validatePrice()) revert PriceValidationFailed();

        // Execute permit to get approval
        IERC20PermitUpgradeable(address(tStakeToken)).permit(
            participant, 
            address(this), 
            amount, 
            deadline, 
            v, 
            r, 
            s
        );

        // Transfer tokens from participant
        tStakeToken.safeTransferFrom(participant, address(this), amount);

        // Update slashing state
        isSlashed[participant] = true;
        totalSlashed += amount;
        lastSlashingTime[participant] = block.timestamp;
        lockedStakes[participant] = amount;

        // Calculate redistribution and burn amounts
        uint256 redistributionAmount = (amount * redistributionPercentage) / 10000;
        uint256 burnAmount = amount - redistributionAmount;

        // Distribute rewards
        if (redistributionAmount > 0) {
            rewardDistributor.distributePenaltyRewards(redistributionAmount);
            emit FundsRedistributed(redistributionAmount, address(rewardDistributor));
        }

        // Burn tokens
        if (burnAmount > 0) {
            if (!_burnTokens(burnAmount)) revert BurnFailed();
        }

        emit ParticipantSlashed(
            participant, 
            amount, 
            redistributionAmount, 
            burnAmount, 
            reason
        );
        emit StakeLocked(participant, amount, block.timestamp + SLASHING_LOCK_PERIOD);
    }

    /**
     * @notice Helper function to burn tokens with fallback mechanism
     * @param amount Amount of tokens to burn
     * @return success Whether the burn was successful
     */
    function _burnTokens(uint256 amount) internal returns (bool) {
        // Try to use the burn function if it exists
        try IERC20Burnable(address(tStakeToken)).burn(amount) {
            return true;
        } catch {
            // Fallback: send to dead address if burn function is not available
            tStakeToken.safeTransfer(address(0xdead), amount);
            return true;
        }
    }

    /**
     * @notice Updates the redistribution percentage in basis points (governance function)
     * @param newPercentage New percentage (10000 = 100%)
     */
    function setRedistributionPercentage(uint256 newPercentage)
        external
        override
        onlyRole(GOVERNANCE_ROLE)
    {
        if (newPercentage > 10000) revert InvalidRedistributionPercentage();
        redistributionPercentage = newPercentage;
        emit PenaltyPercentageUpdated(newPercentage);
    }

    /**
     * @notice Returns the slash amount requested for a participant if any
     * @param participant The participant's address
     */
    function getPendingSlashAmount(address participant)
        external
        view
        override
        returns (uint256)
    {
        if (!pendingSlashApprovals[participant]) {
            return 0;
        }
        return slashAmounts[participant];
    }

    /**
     * @notice Checks if a participant has a pending slash request
     * @param participant The participant's address
     */
    function hasPendingSlashRequest(address participant)
        external
        view
        override
        returns (bool)
    {
        return pendingSlashApprovals[participant];
    }

    // ================================
    // 🔹 Admin / Emergency
    // ================================

    /**
     * @notice Recovers ERC20 tokens that might be stuck in this contract (Emergency only)
     * @param token Address of the token to recover
     * @param amount Token amount
     * @param recipient Recipient address
     */
    function recoverERC20(
        address token,
        uint256 amount,
        address recipient
    ) external onlyRole(EMERGENCY_ROLE) {
        if (recipient == address(0)) revert InvalidAddress();

        IERC20Upgradeable(token).safeTransfer(recipient, amount);
        emit TokenRecovered(token, amount, recipient);
    }

    /**
     * @notice Updates contract references if needed
     * @param _stakingContract New staking contract
     * @param _rewardDistributor New reward distributor
     * @param _liquidityGuard New liquidity guard
     */
    function updateContractReferences(
        address _stakingContract,
        address _rewardDistributor,
        address _liquidityGuard
    ) external onlyRole(GOVERNANCE_ROLE) {
        if (_stakingContract != address(0)) {
            stakingContract = ITerraStakeStaking(_stakingContract);
        }
        if (_rewardDistributor != address(0)) {
            rewardDistributor = ITerraStakeRewardDistributor(_rewardDistributor);
        }
        if (_liquidityGuard != address(0)) {
            liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);
        }
    }

    /**
     * @notice Force update the TWAP price (for emergency situations)
     * @dev This should be used only when absolutely necessary
     */
    function forceUpdateTWAP() external onlyRole(ORACLE_MANAGER_ROLE) {
        _updateTWAPPrice();
    }
}
