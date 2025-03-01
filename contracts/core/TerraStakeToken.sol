// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "../interfaces/ITerraStakeGovernance.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";

/**
 * @title TerraStakeToken
 * @notice Upgradeable ERC20 token for the TerraStake ecosystem with advanced features
 * @dev Implements ERC20Permit for gasless approvals, governance integration, staking, and TWAP oracle
 */
contract TerraStakeToken is
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    ERC20BurnableUpgradeable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // ================================
    // 🔹 Constants
    // ================================
    uint256 public constant MAX_SUPPLY = 10_000_000_000 * 10**18;
    uint32 public constant MIN_TWAP_PERIOD = 5 minutes;
    uint256 public constant MAX_BATCH_SIZE = 200;
    uint256 public constant PRICE_DECIMALS = 18;
    uint256 public constant LARGE_TRANSFER_THRESHOLD = 1_000_000 * 10**18;

    // ================================
    // 🔹 Uniswap V3 TWAP Oracle
    // ================================
    IUniswapV3Pool public uniswapPool;

    // ================================
    // 🔹 TerraStake Ecosystem References
    // ================================
    ITerraStakeGovernance public governanceContract;
    ITerraStakeStaking public stakingContract;
    ITerraStakeLiquidityGuard public liquidityGuard;

    // ================================
    // 🔹 Blacklist Management
    // ================================
    mapping(address => bool) public isBlacklisted;

    // ================================
    // 🔹 Buyback & Token Economics
    // ================================
    struct BuybackStats {
        uint256 totalTokensBought;
        uint256 totalUSDCSpent;
        uint256 lastBuybackTime;
        uint256 buybackCount;
    }
    
    BuybackStats public buybackStatistics;
    uint256 public currentHalvingEpoch;
    uint256 public lastHalvingTime;

    // ================================
    // 🔹 Roles
    // ================================
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant LIQUIDITY_MANAGER_ROLE = keccak256("LIQUIDITY_MANAGER_ROLE");

    // ================================
    // 🔹 Events
    // ================================
    event BlacklistUpdated(address indexed account, bool status);
    event AirdropExecuted(address[] recipients, uint256 amount, uint256 totalAmount);
    event TWAPPriceQueried(uint32 twapInterval, uint256 price);
    event EmergencyWithdrawal(address token, address to, uint256 amount);
    event TokenBurned(address indexed burner, uint256 amount);
    event GovernanceUpdated(address indexed governanceContract);
    event StakingUpdated(address indexed stakingContract);
    event LiquidityGuardUpdated(address indexed liquidityGuard);
    event BuybackExecuted(uint256 amount, uint256 tokensReceived);
    event LiquidityInjected(uint256 amount, uint256 tokensUsed);
    event HalvingTriggered(uint256 epochNumber, uint256 timestamp);
    event TransferBlocked(address indexed from, address indexed to, uint256 amount, string reason);
    event StakingOperationExecuted(address indexed user, uint256 amount, bool isStake);
    event PermitUsed(address indexed owner, address indexed spender, uint256 amount);

    // ================================
    // 🔹 Upgradeable Contract Initialization
    // ================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the TerraStakeToken with required contract references
     * @param _uniswapPool Address of the Uniswap V3 pool for TWAP calculations
     * @param _governanceContract Address of the governance contract
     * @param _stakingContract Address of the staking contract
     * @param _liquidityGuard Address of the liquidity guard contract
     */
    function initialize(
        address _uniswapPool,
        address _governanceContract,
        address _stakingContract,
        address _liquidityGuard
    ) public initializer {
        require(_uniswapPool != address(0), "Invalid Uniswap pool address");
        require(_governanceContract != address(0), "Invalid governance contract");
        require(_stakingContract != address(0), "Invalid staking contract");
        require(_liquidityGuard != address(0), "Invalid liquidity guard contract");

        __ERC20_init("TerraStake", "TSTAKE");
        __ERC20Permit_init("TerraStake");
        __ERC20Burnable_init();
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        _grantRole(LIQUIDITY_MANAGER_ROLE, msg.sender);

        uniswapPool = IUniswapV3Pool(_uniswapPool);
        governanceContract = ITerraStakeGovernance(_governanceContract);
        stakingContract = ITerraStakeStaking(_stakingContract);
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);
        
        // Initialize token economics
        currentHalvingEpoch = 0;
        lastHalvingTime = block.timestamp;
    }

    // ================================
    // 🔹 Permit Integration
    // ================================

    /**
     * @notice Execute permit and transfer in a single transaction
     * @param owner The owner of the tokens
     * @param spender The spender being approved
     * @param value The amount being approved
     * @param deadline The timestamp after which the signature is no longer valid
     * @param v The recovery byte of the signature
     * @param r The first 32 bytes of the signature
     * @param s The second 32 bytes of the signature
     * @param to The recipient of the transfer
     * @param amount The amount to transfer
     */
    function permitAndTransfer(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        address to,
        uint256 amount
    ) external {
        // Execute the permit
        permit(owner, spender, value, deadline, v, r, s);
        
        // Execute the transfer
        require(spender == msg.sender, "Spender must be caller");
        transferFrom(owner, to, amount);
        
        emit PermitUsed(owner, spender, amount);
    }

    // ================================
    // 🔹 Blacklist Management
    // ================================

    /**
     * @notice Sets or removes an address from the blacklist
     * @param account The address to blacklist or unblacklist
     * @param status True to blacklist, false to remove from blacklist
     */
    function setBlacklist(address account, bool status) external onlyRole(ADMIN_ROLE) {
        require(account != address(0), "Cannot blacklist zero address");
        isBlacklisted[account] = status;
        emit BlacklistUpdated(account, status);
    }

    /**
     * @notice Batch blacklists or unblacklists multiple addresses
     * @param accounts Array of addresses to update
     * @param status True to blacklist, false to remove from blacklist
     */
    function batchBlacklist(address[] calldata accounts, bool status) external onlyRole(ADMIN_ROLE) {
        uint256 length = accounts.length;
        require(length <= MAX_BATCH_SIZE, "Batch size too large");
        
        for (uint256 i = 0; i < length; ) {
            require(accounts[i] != address(0), "Cannot blacklist zero address");
            isBlacklisted[accounts[i]] = status;
            emit BlacklistUpdated(accounts[i], status);
            unchecked { ++i; }
        }
    }

    // ================================
    // 🔹 Airdrop Function
    // ================================

    /**
     * @notice Airdrops tokens to multiple recipients
     * @param recipients Array of recipient addresses
     * @param amount Amount per recipient
     */
    function airdrop(address[] calldata recipients, uint256 amount)
        external
        onlyRole(ADMIN_ROLE)
        whenNotPaused
        nonReentrant
    {
        require(amount > 0, "Amount must be > 0");
        require(recipients.length <= MAX_BATCH_SIZE, "Batch too large");
        
        uint256 totalAmount = amount * recipients.length;
        require(totalSupply() + totalAmount <= MAX_SUPPLY, "Exceeds max supply");
        
        for (uint256 i = 0; i < recipients.length; ) {
            address recipient = recipients[i];
            require(recipient != address(0), "Cannot airdrop to zero address");
            require(!isBlacklisted[recipient], "Recipient blacklisted");
            
            _mint(recipient, amount);
            
            unchecked { ++i; }
        }
        
        emit AirdropExecuted(recipients, amount, totalAmount);
    }

    // ================================
    // 🔹 Minting & Burning
    // ================================

    /**
     * @notice Mints new tokens to a specified address
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) 
        external 
        onlyRole(MINTER_ROLE) 
        whenNotPaused 
        nonReentrant 
    {
        require(to != address(0), "Cannot mint to zero address");
        require(!isBlacklisted[to], "Recipient blacklisted");
        require(totalSupply() + amount <= MAX_SUPPLY, "Exceeds max supply");
        
        _mint(to, amount);
    }

    /**
     * @notice Burns tokens from a specified address (admin override)
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burnFrom(address from, uint256 amount) 
        external 
        onlyRole(ADMIN_ROLE) 
        whenNotPaused 
        nonReentrant 
    {
        require(!isBlacklisted[from], "Address blacklisted");
        require(balanceOf(from) >= amount, "Insufficient balance");
        
        _burn(from, amount);
        emit TokenBurned(from, amount);
    }

    // ================================
    // 🔹 TWAP Oracle Implementation
    // ================================

    /**
     * @notice Queries the TWAP price from Uniswap V3 pool
     * @param twapInterval Time period for TWAP calculation
     * @return price The TWAP price with PRICE_DECIMALS precision
     */
    function getTWAPPrice(uint32 twapInterval) public returns (uint256 price) {
        require(twapInterval >= MIN_TWAP_PERIOD, "TWAP interval too short");
        
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapInterval;
        secondsAgos[1] = 0;
        
        (int56[] memory tickCumulatives, ) = uniswapPool.observe(secondsAgos);
        
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 tick = int24(tickCumulativesDelta / int56(uint56(twapInterval)));
        
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
        price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * (10**PRICE_DECIMALS) >> 192;
        
        emit TWAPPriceQueried(twapInterval, price);
        return price;
    }

    // ================================
    // 🔹 Emergency & Recovery Functions
    // ================================

    /**
     * @notice Emergency withdrawal of tokens accidentally sent to this contract
     * @param token Address of the token to withdraw
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(
        address token, 
        address to, 
        uint256 amount
    ) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        require(token != address(this), "Cannot withdraw native token");
        require(to != address(0), "Cannot withdraw to zero address");
        IERC20Upgradeable(token).safeTransfer(to, amount);
        emit EmergencyWithdrawal(token, to, amount);
    }

    /**
     * @notice Batch emergency withdrawal of multiple tokens
     * @param tokens Array of token addresses
     * @param to Recipient address
     * @param amounts Array of amounts to withdraw
     */
    function emergencyWithdrawMultiple(
        address[] calldata tokens,
        address to,
        uint256[] calldata amounts
    ) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        require(tokens.length == amounts.length, "Arrays length mismatch");
        require(to != address(0), "Cannot withdraw to zero address");
        
        for (uint256 i = 0; i < tokens.length; ) {
            require(tokens[i] != address(this), "Cannot withdraw native token");
            
            IERC20Upgradeable(tokens[i]).safeTransfer(to, amounts[i]);
            emit EmergencyWithdrawal(tokens[i], to, amounts[i]);
            
            unchecked { ++i; }
        }
    }

    // ================================
    // 🔹 Governance & Ecosystem Updates
    // ================================

    /**
     * @notice Updates the governance contract reference
     * @param _governanceContract New governance contract address
     */
    function updateGovernanceContract(address _governanceContract) external onlyRole(ADMIN_ROLE) {
        require(_governanceContract != address(0), "Invalid address");
        governanceContract = ITerraStakeGovernance(_governanceContract);
        emit GovernanceUpdated(_governanceContract);
    }

    /**
     * @notice Updates the staking contract reference
     * @param _stakingContract New staking contract address
     */
    function updateStakingContract(address _stakingContract) external onlyRole(ADMIN_ROLE) {
        require(_stakingContract != address(0), "Invalid address");
        stakingContract = ITerraStakeStaking(_stakingContract);
        emit StakingUpdated(_stakingContract);
    }

    /**
     * @notice Updates the liquidity guard contract reference
     * @param _liquidityGuard New liquidity guard contract address
     */
    function updateLiquidityGuard(address _liquidityGuard) external onlyRole(ADMIN_ROLE) {
        require(_liquidityGuard != address(0), "Invalid address");
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);
        emit LiquidityGuardUpdated(_liquidityGuard);
    }

    // ================================
    // 🔹 Token Transfer Override
    // ================================

    /**
     * @notice Override for token transfers to enforce blacklist and liquidity protection
     * @dev Checks blacklist status and verifies large transfers with liquidity guard
     * @param from Sender address
     * @param to Recipient address
     * @param amount Transfer amount
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override whenNotPaused {
        // Skip blacklist check for minting
        if (from != address(0)) {
            require(!isBlacklisted[from], "Sender blacklisted");
        }
        
        // Skip blacklist check for burning
        if (to != address(0)) {
            require(!isBlacklisted[to], "Recipient blacklisted");
        }
        
        // Only check liquidity protection for transfers (not mints or burns)
        // and only for large transfers
        if (from != address(0) && to != address(0) && amount >= LARGE_TRANSFER_THRESHOLD) {
            try liquidityGuard.verifyTWAPForWithdrawal() returns (bool success) {
                require(success, "TWAP verification failed");
            } catch {
                emit TransferBlocked(from, to, amount, "Liquidity protection triggered");
                revert("Liquidity protection triggered");
            }
        }
        
        // Call parent implementation - critical for ERC20 functionality
        super._update(from, to, amount);
    }

    // ================================
    // 🔹 Staking Integration
    // ================================

    /**
     * @notice Handles token staking operations (special handler for staking contract)
     * @param from Address to stake from
     * @param amount Amount to stake
     * @return success True if successful
     */
    function stakeTokens(address from, uint256 amount) external nonReentrant returns (bool) {
        require(msg.sender == address(stakingContract), "Only staking contract");
        require(!isBlacklisted[from], "Blacklisted address");
        require(balanceOf(from) >= amount, "Insufficient balance");
        
        _transfer(from, address(stakingContract), amount);
        emit StakingOperationExecuted(from, amount, true);
        return true;
    }

    /**
     * @notice Handles token unstaking operations (special handler for staking contract)
     * @param to Address to unstake to
     * @param amount Amount to unstake
     * @return success True if successful
     */
    function unstakeTokens(address to, uint256 amount) external nonReentrant returns (bool) {
        require(msg.sender == address(stakingContract), "Only staking contract");
        require(!isBlacklisted[to], "Blacklisted address");
        
        _transfer(address(stakingContract), to, amount);
        emit StakingOperationExecuted(to, amount, false);
        return true;
    }

    /**
     * @notice Gets governance voting power for a user
     * @param account User address
     * @return votingPower The governance voting power
     */
    function getGovernanceVotes(address account) external view returns (uint256) {
        return stakingContract.governanceVotes(account);
    }

    /**
     * @notice Checks if a user has been penalized in governance
     * @param account User address
     * @return isPenalized True if penalized
     */
    function isGovernorPenalized(address account) external view returns (bool) {
        return stakingContract.governanceViolators(account);
    }

    // ================================
    // 🔹 Liquidity & Buyback Functions
    // ================================

    /**
     * @notice Executes a token buyback via the liquidity guard
     * @param usdcAmount Amount of USDC to use for buyback
     * @return tokensReceived The amount of tokens received
     */
    function executeBuyback(uint256 usdcAmount) 
        external 
        onlyRole(LIQUIDITY_MANAGER_ROLE) 
        nonReentrant 
        returns (uint256 tokensReceived) 
    {
        require(usdcAmount > 0, "Amount must be > 0");
        
        // Estimate tokens based on TWAP
        tokensReceived = (usdcAmount * 10**decimals()) / getTWAPPrice(MIN_TWAP_PERIOD);
        
        // Call liquidity guard to execute the buyback
        liquidityGuard.injectLiquidity(usdcAmount);
        
        // Update buyback statistics
        buybackStatistics.totalUSDCSpent += usdcAmount;
        buybackStatistics.totalTokensBought += tokensReceived;
        buybackStatistics.lastBuybackTime = block.timestamp;
        buybackStatistics.buybackCount++;
        
        emit BuybackExecuted(usdcAmount, tokensReceived);
        return tokensReceived;
    }

    /**
     * @notice Injects liquidity into the ecosystem
     * @param amount Amount of tokens to use for liquidity
     * @return success True if successful
     */
    function injectLiquidity(uint256 amount) 
        external 
        onlyRole(LIQUIDITY_MANAGER_ROLE) 
        nonReentrant 
        returns (bool) 
    {
        require(amount > 0, "Amount must be > 0");
        require(balanceOf(address(this)) >= amount, "Insufficient balance");
        
        // Transfer tokens to liquidity pool
        address liquidityPool = liquidityGuard.getLiquidityPool();
        require(liquidityPool != address(0), "Invalid liquidity pool");
        
        _transfer(address(this), liquidityPool, amount);
        emit LiquidityInjected(amount, amount);
        return true;
    }

    // ================================
    // 🔹 Halving Mechanism Integration
    // ================================

    /**
     * @notice Triggers halving event in the ecosystem
     * @return epoch The new halving epoch
     */
    function triggerHalving() external onlyRole(ADMIN_ROLE) returns (uint256) {
        // Call halving on both staking and governance contracts
        stakingContract.applyHalving();
        governanceContract.applyHalving();
        
        currentHalvingEpoch++;
        lastHalvingTime = block.timestamp;
        
        emit HalvingTriggered(currentHalvingEpoch, lastHalvingTime);
        return currentHalvingEpoch;
    }

    /**
     * @notice Gets halving details from the staking contract
     * @return period The halving period
     * @return lastTime The last halving time
     * @return epoch The current halving epoch
     */
    function getHalvingDetails() external view returns (
        uint256 period,
        uint256 lastTime,
        uint256 epoch
    ) {
        return (
            stakingContract.halvingPeriod(),
            stakingContract.lastHalvingTime(),
            stakingContract.halvingEpoch()
        );
    }

    // ================================
    // 🔹 Governance Verification
    // ================================

    /**
     * @notice Checks if a large transaction should be approved by governance
     * @param account Address to check
     * @param amount Amount to verify
     * @return approved True if the transaction is approved
     */
    function checkGovernanceApproval(address account, uint256 amount) 
        public 
        view 
        returns (bool) 
    {
        if (amount > LARGE_TRANSFER_THRESHOLD) {
            return stakingContract.governanceVotes(account) > 0;
        }
        return true;
    }

    /**
     * @notice Helper for governance to penalize a user for violations
     * @param account Address to penalize
     */
    function penalizeGovernanceViolator(address account) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        stakingContract.slashGovernanceVote(account);
    }

    // ================================
    // 🔹 Security Functions
    // ================================

    /**
     * @notice Pauses all token transfers
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses token transfers
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Activates circuit breaker in the liquidity guard
     */
    function activateCircuitBreaker() external onlyRole(ADMIN_ROLE) {
        liquidityGuard.triggerCircuitBreaker();
    }

    /**
     * @notice Resets circuit breaker in the liquidity guard
     */
    function resetCircuitBreaker() external onlyRole(ADMIN_ROLE) {
        liquidityGuard.resetCircuitBreaker();
    }

    // ================================
    // 🔹 View Functions
    // ================================

    /**
     * @notice Gets the current buyback statistics
     * @return stats The buyback statistics struct
     */
    function getBuybackStatistics() external view returns (BuybackStats memory) {
        return buybackStatistics;
    }

    /**
     * @notice Gets liquidity settings from liquidity guard
     * @return isPairingEnabled Whether liquidity pairing is enabled
     */
    function getLiquiditySettings() external view returns (bool) {
        return liquidityGuard.getLiquiditySettings();
    }

    /**
     * @notice Checks if circuit breaker is triggered
     * @return isTriggered True if triggered
     */
    function isCircuitBreakerTriggered() external view returns (bool) {
        return liquidityGuard.isCircuitBreakerTriggered();
    }

    // ================================
    // 🔹 Upgradeability
    // ================================

    /**
     * @notice Authorizes an upgrade to a new implementation
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyRole(UPGRADER_ROLE) 
    {
        // Additional validation can be added here
    }

    /**
     * @notice Gets the current implementation address
     * @return implementation The implementation address
     */
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }
}
