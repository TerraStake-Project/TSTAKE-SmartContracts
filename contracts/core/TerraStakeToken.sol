// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "../interfaces/ITerraStakeGovernance.sol";
import "../interfaces/ITerraStakeStaking.sol";
import "../interfaces/ITerraStakeLiquidityGuard.sol";
import "../interfaces/ITerraStakeNeural.sol";
import "../interfaces/IAIEngine.sol";
import "../interfaces/ITerraStakeITO.sol";
import "../interfaces/ITerraStakeToken.sol";
/**
 * @title TerraStakeToken
 * @notice Upgradeable ERC20 token for the TerraStake ecosystem with advanced features, optimized for Arbitrum
 * @dev Implements ERC20Permit for gasless approvals, governance integration, staking, and TWAP oracle
 * @custom:optimized-by Emiliano Solazzi 2025 as "T-30" for Arbitrum L2 with gas efficiency considerations
 */
 contract TerraStakeToken is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    ERC20BurnableUpgradeable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ITerraStakeToken,
    ITerraStakeNeural
{
    using SafeERC20 for IERC20;

    // ================================
    //  Constants
    // ================================
    uint256 public constant MAX_SUPPLY = 10_000_000_000 * 10**18;
    uint32 public constant MIN_TWAP_PERIOD = 5 minutes;
    uint256 public constant MAX_BATCH_SIZE = 200;
    uint256 public constant PRICE_DECIMALS = 18;
    uint256 public constant LARGE_TRANSFER_THRESHOLD = 1_000_000 * 10**18;

    // ================================
    //  Uniswap V3 TWAP Oracle (Arbitrum-compatible)
    // ================================
    IUniswapV3Pool public uniswapPool;
    uint256 public lastTWAPPrice;

    // ================================
    //  TerraStake Ecosystem References
    // ================================
    ITerraStakeGovernance public governanceContract;
    ITerraStakeStaking public stakingContract;
    ITerraStakeLiquidityGuard public liquidityGuard;
    // Add AIEngine reference
    IAIEngine public aiEngine;
    bool public useAIEngine;
    // Add ITO reference 
    address public itoContractAddress;

    // ================================
    //  Blacklist Management
    // ================================
    mapping(address => bool) public isBlacklisted;

    // ================================
    //  Buyback & Token Economics
    // ================================    
    BuybackStats public buybackStatistics;
    uint256 public currentHalvingEpoch;
    uint256 public lastHalvingTime;

    // ================================
    //  Roles
    // ================================
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant LIQUIDITY_MANAGER_ROLE = keccak256("LIQUIDITY_MANAGER_ROLE");
    // Add AI Engine specific role
    bytes32 public constant AI_MANAGER_ROLE = keccak256("AI_MANAGER_ROLE");
    bytes32 public constant ITO_ROLE = keccak256("ITO_ROLE");  

    // ========== [Neural / DNA Addition] ==========
    // Additional constants for biologically-inspired systems
    uint256 public constant MIN_CONSTITUENTS = 30; 
    uint256 public constant MAX_EMA_SMOOTHING = 100; 
    uint256 public constant DEFAULT_EMA_SMOOTHING = 20; 
    uint256 public constant MIN_DIVERSITY_INDEX = 500; 
    uint256 public constant MAX_DIVERSITY_INDEX = 2500; 
    uint256 public constant VOLATILITY_THRESHOLD = 15;

    // Introduce a new role for updating neural indexing
    bytes32 public constant NEURAL_INDEXER_ROLE = keccak256("NEURAL_INDEXER_ROLE");

    mapping(address => NeuralWeight) public assetNeuralWeights;

    mapping(address => ConstituentData) public constituents;
    address[] public constituentList;

    uint256 public diversityIndex;     // e.g. HHI-based
    uint256 public geneticVolatility;  // measure of ecosystem vol

    // Adaptive rebalancing data
    uint256 public rebalanceInterval;
    uint256 public lastRebalanceTime;
    uint256 public adaptiveVolatilityThreshold;
    uint256 public rebalancingFrequencyTarget;
    uint256 public lastAdaptiveLearningUpdate;
    uint256 public selfOptimizationCounter;
    
    // Add AIEngine integration events
    event AIEngineUpdated(address indexed aiEngineAddress);
    event AIEngineUsageToggled(bool useAIEngine);
    event AIEngineOperationExecuted(string operation, bool success);

    // ================================
    //  Upgradeable Contract Initialization
    // ================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the TerraStakeToken with required contract references
     * @param _uniswapPool Address of the Uniswap V3 pool for TWAP calculations (Arbitrum Uniswap pool)
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

        // ========== [Neural / DNA Addition: Additional Role Grants] ==========
        _grantRole(NEURAL_INDEXER_ROLE, msg.sender);
        
        // Add AI Manager Role Grant
        _grantRole(AI_MANAGER_ROLE, msg.sender);

        uniswapPool = IUniswapV3Pool(_uniswapPool);
        governanceContract = ITerraStakeGovernance(_governanceContract);
        stakingContract = ITerraStakeStaking(_stakingContract);
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);
        
        // Initialize token economics
        currentHalvingEpoch = 0;
        lastHalvingTime = block.timestamp;

        // ========== [Neural / DNA Addition: Initialize Rebalance Data] ==========
        rebalanceInterval = 1 days;
        adaptiveVolatilityThreshold = VOLATILITY_THRESHOLD;
        rebalancingFrequencyTarget = 365; // daily
        lastAdaptiveLearningUpdate = block.timestamp;
        lastRebalanceTime = block.timestamp; // set to now so we wait a full interval
        // Initialize remaining neural variables
        diversityIndex = 0;
        geneticVolatility = 0;
        selfOptimizationCounter = 0;
        
        // Initialize AIEngine variables
        useAIEngine = false;
        
        lastTWAPPrice = 0; // Initialize TWAP price
    }

    // ================================
    //  AIEngine Integration Functions
    // ================================
    
    /**
     * @notice Set the AIEngine contract address
     * @param _aiEngine Address of the AIEngine contract
     */
    function setAIEngine(address _aiEngine) external onlyRole(AI_MANAGER_ROLE) {
        require(_aiEngine != address(0), "Invalid AIEngine address");
        aiEngine = IAIEngine(_aiEngine);
        emit AIEngineUpdated(_aiEngine);
    }
    
    /**
     * @notice Toggle the usage of AIEngine for neural operations
     * @param _useAIEngine Whether to use AIEngine (true) or internal logic (false)
     */
    function toggleAIEngineUsage(bool _useAIEngine) external onlyRole(AI_MANAGER_ROLE) {
        useAIEngine = _useAIEngine;
        emit AIEngineUsageToggled(_useAIEngine);
    }
    
    /**
     * @notice Syncs constituent data with the AIEngine
     * @param asset Address of the asset to sync
     */
    function syncConstituentWithAIEngine(address asset) external onlyRole(NEURAL_INDEXER_ROLE) {
        require(address(aiEngine) != address(0), "AIEngine not set");
        require(constituents[asset].isActive, "Not an active constituent");
        
        // Create price feed address to pass to AIEngine (would be set properly in production)
        address dummyPriceFeed = address(0x1);
        
        try aiEngine.addConstituent(asset, dummyPriceFeed) {
            emit AIEngineOperationExecuted("syncConstituent", true);
        } catch {
            emit AIEngineOperationExecuted("syncConstituent", false);
        }
    }
    
    /**
     * @notice Syncs a neural weight with the AIEngine
     * @param asset Address of the asset
     * @param newRawSignal The new signal value
     * @param smoothingFactor EMA smoothing factor
     */
    function syncNeuralWeightWithAIEngine(
        address asset,
        uint256 newRawSignal,
        uint256 smoothingFactor
    ) external onlyRole(NEURAL_INDEXER_ROLE) {
        require(address(aiEngine) != address(0), "AIEngine not set");
        
        try aiEngine.updateNeuralWeight(asset, newRawSignal, smoothingFactor) {
            emit AIEngineOperationExecuted("syncNeuralWeight", true);
        } catch {
            emit AIEngineOperationExecuted("syncNeuralWeight", false);
        }
    }
    
    /**
     * @notice Check token ecosystem health using AIEngine if available
     * @return healthy Whether the ecosystem is considered healthy
     */
    function checkTokenHealth() external view returns (bool healthy) {
        // Start with presumption of health
        healthy = true;
        
        // Check using AIEngine if available
        if (address(aiEngine) != address(0) && useAIEngine) {
            try aiEngine.shouldAdaptiveRebalance() returns (bool shouldRebalance, string memory reason) {
                if (shouldRebalance) {
                    healthy = false;
                }
            } catch {
                // Fallback to local metrics if AIEngine call fails
                (bool localRebalance, ) = this.shouldAdaptiveRebalance();
                healthy = !localRebalance;
            }
            
            // Additional AIEngine checks
            try aiEngine.diversityIndex() returns (uint256 divIndex) {
                if (divIndex > aiEngine.MAX_DIVERSITY_INDEX() || 
                    (divIndex < aiEngine.MIN_DIVERSITY_INDEX() && divIndex > 0)) {
                    healthy = false;
                }
            } catch {
                // Ignore if this check fails
            }
        } else {
            // Use local metrics
            (bool shouldRebalance, ) = this.shouldAdaptiveRebalance();
            uint256 localDiversity = diversityIndex;
            
            if (shouldRebalance || 
                localDiversity > MAX_DIVERSITY_INDEX || 
                (localDiversity < MIN_DIVERSITY_INDEX && localDiversity > 0)) {
                healthy = false;
            }
        }
        
        return healthy;
    }

    // ================================
    //  Permit Integration (Gas-optimized for Arbitrum)
    // ================================

    /**
     * @notice Execute permit and transfer in a single transaction
     * @dev Optimized for Arbitrum's gas model
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
        permit(owner, spender, value, deadline, v, r, s);
        require(spender == msg.sender, "Spender must be caller");
        transferFrom(owner, to, amount);
        emit PermitUsed(owner, spender, amount);
    }

// ================================
//  Blacklist Management
// ================================
function setBlacklist(address account, bool status) external onlyRole(ADMIN_ROLE) {
    require(account != address(0), "Cannot blacklist zero address");
    isBlacklisted[account] = status;
    emit BlacklistUpdated(account, status);
}

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

/**
 * @notice Sync blacklist status with ITO contract
 * @param account Address to check and sync
 */
function syncBlacklistWithITO(address account) external onlyRole(ADMIN_ROLE) {
    require(itoContractAddress != address(0), "ITO contract not set");
    bool itoBlacklisted = ITerraStakeITO(itoContractAddress).blacklist(account);
    if (isBlacklisted[account] != itoBlacklisted) {
        isBlacklisted[account] = itoBlacklisted;
        emit BlacklistUpdated(account, itoBlacklisted);
    }
}

/**
 * @notice Batch sync blacklist status with ITO contract
 * @param accounts Array of addresses to sync
 */
function batchSyncBlacklistWithITO(address[] calldata accounts) external onlyRole(ADMIN_ROLE) {
    require(itoContractAddress != address(0), "ITO contract not set");
    require(accounts.length <= MAX_BATCH_SIZE, "Batch too large");
    
    for (uint256 i = 0; i < accounts.length; i++) {
        bool itoBlacklisted = ITerraStakeITO(itoContractAddress).blacklist(accounts[i]);
        if (isBlacklisted[accounts[i]] != itoBlacklisted) {
            isBlacklisted[accounts[i]] = itoBlacklisted;
            emit BlacklistUpdated(accounts[i], itoBlacklisted);
        }
    }
}
    // ================================
    //  Airdrop Function (Gas-optimized for Arbitrum)
    // ================================
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
    //  Minting & Burning
    // ================================
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

    function burnFrom(address from, uint256 amount) 
        public
        override
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
    //  TWAP Oracle Implementation (Arbitrum-optimized)
    // ================================
    function getTWAPPrice(uint32 twapInterval) public returns (uint256 price) {
        // If AIEngine is active, try to get price from there first
        if (address(aiEngine) != address(0) && useAIEngine) {
            try aiEngine.fetchLatestPrice(address(this)) returns (uint256 aiPrice) {
                if (aiPrice > 0) {
                    lastTWAPPrice = aiPrice;
                    emit TWAPPriceQueried(twapInterval, aiPrice);
                    return aiPrice;
                }
            } catch {
                // If AIEngine price fetch fails, fallback to Uniswap TWAP
            }
        }
        
        // Original Uniswap TWAP logic as fallback
        require(twapInterval >= MIN_TWAP_PERIOD, "TWAP interval too short");
        
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapInterval;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives, ) = uniswapPool.observe(secondsAgos);
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 tick = int24(tickCumulativesDelta / int56(uint56(twapInterval)));
        
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
        price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * (10**PRICE_DECIMALS) >> 192;
        
        // Update the last TWAP price
        lastTWAPPrice = price;
        
        emit TWAPPriceQueried(twapInterval, price);
        return price;
    }

    // ================================
    //  Emergency & Recovery Functions
    // ================================
    function emergencyWithdraw(address token, address to, uint256 amount) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        require(token != address(this), "Cannot withdraw native token");
        require(to != address(0), "Cannot withdraw to zero address");
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyWithdrawal(token, to, amount);
    }

    function emergencyWithdrawMultiple(address[] calldata tokens, address to, uint256[] calldata amounts)
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        require(tokens.length == amounts.length, "Arrays length mismatch");
        require(to != address(0), "Cannot withdraw to zero address");
        
        for (uint256 i = 0; i < tokens.length; ) {
            require(tokens[i] != address(this), "Cannot withdraw native token");
            IERC20(tokens[i]).safeTransfer(to, amounts[i]);
            emit EmergencyWithdrawal(tokens[i], to, amounts[i]);
            unchecked { ++i; }
        }
    }

    // ================================
    //  Governance & Ecosystem Updates
    // ================================
    function updateGovernanceContract(address _governanceContract) external onlyRole(ADMIN_ROLE) {
        require(_governanceContract != address(0), "Invalid address");
        governanceContract = ITerraStakeGovernance(_governanceContract);
        emit GovernanceUpdated(_governanceContract);
    }

    function updateStakingContract(address _stakingContract) external onlyRole(ADMIN_ROLE) {
        require(_stakingContract != address(0), "Invalid address");
        stakingContract = ITerraStakeStaking(_stakingContract);
        emit StakingUpdated(_stakingContract);
    }

    function updateLiquidityGuard(address _liquidityGuard) external onlyRole(ADMIN_ROLE) {
        require(_liquidityGuard != address(0), "Invalid address");
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);
        emit LiquidityGuardUpdated(_liquidityGuard);
    }
    /**
    * @notice Updates the ITO contract address
    * @param _itoContract Address of the ITO contract
   */
    function updateITOContract(address _itoContract) external onlyRole(ADMIN_ROLE) {
         require(_itoContract != address(0), "Invalid address");
         itoContractAddress = _itoContract;
         emit ITOContractUpdated(_itoContract);
   }

    // ================================
    //  Token Transfer Override (Gas-optimized for Arbitrum)
    // ================================
    function _update(address from, address to, uint256 amount) internal override whenNotPaused {
        if (from != address(0)) {
            require(!isBlacklisted[from], "Sender blacklisted");
        }
        if (to != address(0)) {
            require(!isBlacklisted[to], "Recipient blacklisted");
        }
        // Large transfer -> ask liquidity guard
        if (from != address(0) && to != address(0) && amount >= LARGE_TRANSFER_THRESHOLD) {
            try liquidityGuard.verifyTWAPForWithdrawal() returns (bool success) {
                require(success, "TWAP verification failed");
            } catch {
                emit TransferBlocked(from, to, amount, "Liquidity protection triggered");
                revert("Liquidity protection triggered");
            }
        }
        // Proceed with parent logic
        super._update(from, to, amount);
    }

    // ================================
    //  Staking Integration (Arbitrum-optimized)
    // ================================
    function stakeTokens(address from, uint256 amount) external nonReentrant returns (bool) {
        require(msg.sender == address(stakingContract), "Only staking contract");
        require(!isBlacklisted[from], "Blacklisted address");
        require(balanceOf(from) >= amount, "Insufficient balance");
        
        _transfer(from, address(stakingContract), amount);
        emit StakingOperationExecuted(from, amount, true);
        return true;
    }

    function unstakeTokens(address to, uint256 amount) external nonReentrant returns (bool) {
        require(msg.sender == address(stakingContract), "Only staking contract");
        require(!isBlacklisted[to], "Blacklisted address");
        
        _transfer(address(stakingContract), to, amount);
        emit StakingOperationExecuted(to, amount, false);
        return true;
    }

    function getGovernanceVotes(address account) external view returns (uint256) {
        return stakingContract.getGovernanceVotes(account);
    }

    function isGovernorPenalized(address account) external view returns (bool) {
        return stakingContract.isGovernanceViolator(account);
    }

    // ================================
    //  Liquidity & Buyback Functions (Arbitrum-optimized)
    // ================================
    function executeBuyback(uint256 usdcAmount) 
        external 
        onlyRole(LIQUIDITY_MANAGER_ROLE) 
        nonReentrant 
        returns (uint256 tokensReceived) 
    {
        require(usdcAmount > 0, "Amount must be > 0");
        tokensReceived = (usdcAmount * 10**decimals()) / getTWAPPrice(MIN_TWAP_PERIOD);
        liquidityGuard.injectLiquidity(usdcAmount);
        buybackStatistics.totalUSDCSpent += usdcAmount;
        buybackStatistics.totalTokensBought += tokensReceived;
        buybackStatistics.lastBuybackTime = block.timestamp;
        buybackStatistics.buybackCount++;
        
        emit BuybackExecuted(usdcAmount, tokensReceived);
        return tokensReceived;
    }

    function injectLiquidity(uint256 amount) 
        external 
        onlyRole(LIQUIDITY_MANAGER_ROLE) 
        nonReentrant 
        returns (bool) 
    {
        require(amount > 0, "Amount must be > 0");
        require(balanceOf(address(this)) >= amount, "Insufficient balance");
        address liquidityPool = liquidityGuard.getLiquidityPool();
        require(liquidityPool != address(0), "Invalid liquidity pool");
        
        _transfer(address(this), liquidityPool, amount);
        emit LiquidityInjected(amount, amount);
        return true;
    }

    // ================================
    //  Halving Mechanism Integration
    // ================================
    function triggerHalving() external onlyRole(ADMIN_ROLE) returns (uint256) {
        stakingContract.applyHalving();
        governanceContract.applyHalving();
        currentHalvingEpoch++;
        lastHalvingTime = block.timestamp;
        emit HalvingTriggered(currentHalvingEpoch, lastHalvingTime);
        return currentHalvingEpoch;
    }

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

    function checkGovernanceApproval(address account, uint256 amount) 
        public 
        view 
        returns (bool) 
    {
        if (amount > LARGE_TRANSFER_THRESHOLD) {
            return stakingContract.getGovernanceVotes(account) > 0;
        }
        return true;
    }

    function penalizeGovernanceViolator(address account) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        stakingContract.slashGovernanceVote(account);
    }

    // ================================
    //  Security Functions
    // ================================
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function activateCircuitBreaker() external onlyRole(ADMIN_ROLE) {
        liquidityGuard.triggerCircuitBreaker();
    }

    function resetCircuitBreaker() external onlyRole(ADMIN_ROLE) {
        liquidityGuard.resetCircuitBreaker();
    }

    // ================================
    //  View Functions (Arbitrum gas-optimized)
    // ================================
    function getBuybackStatistics() external view returns (BuybackStats memory) {
        return buybackStatistics;
    }

    function getLiquiditySettings() external view returns (bool) {
        return liquidityGuard.getLiquiditySettings();
    }

    function isCircuitBreakerTriggered() external view returns (bool) {
        return liquidityGuard.isCircuitBreakerTriggered();
    }

    // ================================
    //  Upgradeability (Arbitrum considerations)
    // ================================
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // ========== [Neural / DNA Addition: Implementation (Arbitrum optimized)] ==========

    /**
     * @notice Updates an asset's neural weight using exponential moving average
     * @param asset Asset being updated
     * @param newRawSignal The new raw signal (scaled 1e18)
     * @param smoothingFactor Smoothing factor (1-100)
     * @dev Optimized for Arbitrum's gas characteristics
     */
    function updateNeuralWeight(
        address asset,
        uint256 newRawSignal,
        uint256 smoothingFactor
    )
        public
        onlyRole(NEURAL_INDEXER_ROLE)
    {
        // Try to use AIEngine if enabled
        if (address(aiEngine) != address(0) && useAIEngine) {
            try aiEngine.updateNeuralWeight(asset, newRawSignal, smoothingFactor) {
                // If AIEngine update succeeded, still update local state to keep in sync
                emit AIEngineOperationExecuted("updateNeuralWeight", true);
            } catch {
                // If AIEngine fails, proceed with local update only
                emit AIEngineOperationExecuted("updateNeuralWeight", false);
            }
        }
        
        // Always update local state regardless of AIEngine
        require(smoothingFactor > 0 && smoothingFactor <= MAX_EMA_SMOOTHING, "Invalid smoothing factor");

        // If first time
        if (assetNeuralWeights[asset].lastUpdateTime == 0) {
            assetNeuralWeights[asset] = NeuralWeight({
                currentWeight: newRawSignal,
                rawSignal: newRawSignal,
                lastUpdateTime: block.timestamp,
                emaSmoothingFactor: smoothingFactor
            });
        } else {
            NeuralWeight storage w = assetNeuralWeights[asset];
            w.rawSignal = newRawSignal;
            // newEMA = (signal * factor + oldEMA * (100 - factor)) / 100
            w.currentWeight = (newRawSignal * smoothingFactor + w.currentWeight * (100 - smoothingFactor)) / 100;
            w.lastUpdateTime = block.timestamp;
            w.emaSmoothingFactor = smoothingFactor;
        }

        emit NeuralWeightUpdated(asset, assetNeuralWeights[asset].currentWeight, smoothingFactor);

        // Recompute diversity if constituent is active
        if (constituents[asset].isActive) {
            _updateDiversityIndex();
        }
    }

    /**
     * @notice Batch update multiple assets (gas-optimized for Arbitrum)
     */
    function batchUpdateNeuralWeights(
        address[] calldata assets,
        uint256[] calldata signals,
        uint256[] calldata smoothingFactors
    )
        external
        onlyRole(NEURAL_INDEXER_ROLE)
    {
        require(assets.length == signals.length, "Arrays mismatch");
        require(assets.length == smoothingFactors.length, "Arrays mismatch");
        require(assets.length <= MAX_BATCH_SIZE, "Batch too large");

        // Try to batch update via AIEngine if enabled
        if (address(aiEngine) != address(0) && useAIEngine) {
            try aiEngine.batchUpdateNeuralWeights(assets, signals, smoothingFactors) {
                emit AIEngineOperationExecuted("batchUpdateNeuralWeights", true);
            } catch {
                emit AIEngineOperationExecuted("batchUpdateNeuralWeights", false);
            }
        }

        // Always update local state
        for (uint256 i = 0; i < assets.length; i++) {
            updateNeuralWeight(assets[i], signals[i], smoothingFactors[i]);
        }
    }

    /**
     * @notice Add a new constituent
     * @dev Optimized for Arbitrum's gas cost model
     */
    function addConstituent(address asset, uint256 initialWeight)
        external
        onlyRole(ADMIN_ROLE)
    {
        // Try to add constituent to AIEngine if enabled
        if (address(aiEngine) != address(0) && useAIEngine) {
            // Create price feed address to pass to AIEngine (would be set properly in production)
            address dummyPriceFeed = address(0x1);
            
            try aiEngine.addConstituent(asset, dummyPriceFeed) {
                emit AIEngineOperationExecuted("addConstituent", true);
            } catch {
                emit AIEngineOperationExecuted("addConstituent", false);
            }
        }
        
        // Always update local state
        require(asset != address(0), "Zero address");
        require(!constituents[asset].isActive, "Already active");
        constituents[asset] = ConstituentData({
            isActive: true,
            activationTime: block.timestamp,
            evolutionScore: 0
        });
        constituentList.push(asset);

        // If no neural weight yet, init
        if (assetNeuralWeights[asset].lastUpdateTime == 0) {
            assetNeuralWeights[asset].currentWeight = initialWeight;
            assetNeuralWeights[asset].rawSignal = initialWeight;
            assetNeuralWeights[asset].lastUpdateTime = block.timestamp;
            assetNeuralWeights[asset].emaSmoothingFactor = DEFAULT_EMA_SMOOTHING;
        }

        emit ConstituentAdded(asset, block.timestamp);
        _updateDiversityIndex();
    }

    /**
     * @notice Remove a constituent
     */
    function removeConstituent(address asset)
        external
        onlyRole(ADMIN_ROLE)
    {
        // Try to remove constituent from AIEngine if enabled
        if (address(aiEngine) != address(0) && useAIEngine) {
            try aiEngine.deactivateConstituent(asset) {
                emit AIEngineOperationExecuted("removeConstituent", true);
            } catch {
                emit AIEngineOperationExecuted("removeConstituent", false);
            }
        }
        
        // Always update local state
        require(constituents[asset].isActive, "Not active");
        constituents[asset].isActive = false;
        emit ConstituentRemoved(asset, block.timestamp);
        _updateDiversityIndex();
    }

    /**
     * @notice Update evolution score
     */
    function updateEvolutionScore(address asset, uint256 newScore)
        external
        onlyRole(NEURAL_INDEXER_ROLE)
    {
        // Always update local state first
        require(constituents[asset].isActive, "Not active");
        constituents[asset].evolutionScore = newScore;
        
        // Update geneticVolatility locally
        uint256 oldVolatility = geneticVolatility;
        geneticVolatility = (geneticVolatility * 90 + newScore * 10) / 100;
        
        // Try to update genetic volatility in AIEngine if enabled
        if (address(aiEngine) != address(0) && useAIEngine) {
            try aiEngine.updateGeneticVolatility(geneticVolatility) {
                emit AIEngineOperationExecuted("updateGeneticVolatility", true);
            } catch {
                emit AIEngineOperationExecuted("updateGeneticVolatility", false);
            }
        }
    }

    /**
     * @notice Get count of active constituents
     * @return count The number of active constituents
     */
    function getActiveConstituentsCount() external view returns (uint256 count) {
        // If AIEngine is enabled, try to get count from there first
        if (address(aiEngine) != address(0) && useAIEngine) {
            try aiEngine.activeConstituentCount() returns (uint256 aiCount) {
                return aiCount;
            } catch {
                // Fallback to local calculation on AIEngine failure
            }
        }
        
        // Local calculation as fallback
        uint256 activeCount = 0;
        for (uint256 i = 0; i < constituentList.length; i++) {
            if (constituents[constituentList[i]].isActive) {
                activeCount++;
            }
        }
        return activeCount;
    }

    /**
     * @notice Get evolution score for a constituent
     * @param asset Address of the asset
     * @return score The evolution score
     */
    function getEvolutionScore(address asset) external view returns (uint256 score) {
        return constituents[asset].evolutionScore;
    }

    /**
     * @notice Check if rebalance should be triggered
     * @return shouldRebalance Whether rebalance is needed
     * @return reason Human-readable reason
     */
    function shouldAdaptiveRebalance() public view returns (bool, string memory) {
        // Try to use AIEngine if enabled
        if (address(aiEngine) != address(0) && useAIEngine) {
            try aiEngine.shouldAdaptiveRebalance() returns (bool shouldRebalance, string memory reason) {
                return (shouldRebalance, reason);
            } catch {
                // Fallback to local logic if AIEngine call fails
            }
        }
        
        // Local rebalance logic as fallback
        
        // Time-based rebalance
        if (block.timestamp >= lastRebalanceTime + rebalanceInterval) {
            return (true, "Time-based rebalance");
        }

        // Concentration-based rebalance
        if (diversityIndex > MAX_DIVERSITY_INDEX) {
            return (true, "Diversity too concentrated");
        }

        // Dispersion-based rebalance
        if (diversityIndex < MIN_DIVERSITY_INDEX && diversityIndex > 0) {
            return (true, "Diversity too dispersed");
        }

        // Volatility-based rebalance
        if (geneticVolatility > adaptiveVolatilityThreshold) {
            return (true, "Volatility threshold breach");
        }

        // TWAP-based calculation
        uint256 currentPrice = lastTWAPPrice;
        uint256 priceChange;
        if (currentPrice > 0 && lastTWAPPrice > 0) {
            if (currentPrice > lastTWAPPrice) {
                priceChange = ((currentPrice - lastTWAPPrice) * 100) / lastTWAPPrice;
            } else {
                priceChange = ((lastTWAPPrice - currentPrice) * 100) / lastTWAPPrice;
            }
            
            if (priceChange > adaptiveVolatilityThreshold) {
                return (true, "Market volatility trigger");
            }
        }

        return (false, "No rebalance needed");
    }

    /**
     * @notice Trigger adaptive rebalance
     * @return reason The reason for rebalance
     */
    function triggerAdaptiveRebalance() external onlyRole(NEURAL_INDEXER_ROLE) returns (string memory reason) {
        // Try to trigger rebalance in AIEngine if enabled
        if (address(aiEngine) != address(0) && useAIEngine) {
            try aiEngine.triggerAdaptiveRebalance() returns (string memory aiReason) {
                emit AIEngineOperationExecuted("triggerAdaptiveRebalance", true);
                // Still update local state for consistency
                lastRebalanceTime = block.timestamp;
                return aiReason;
            } catch {
                emit AIEngineOperationExecuted("triggerAdaptiveRebalance", false);
                // Fallback to local rebalance if AIEngine fails
            }
        }

        // Local rebalance logic as fallback
        (bool doRebalance, string memory rebalanceReason) = shouldAdaptiveRebalance();
        require(doRebalance, "Rebalance not needed");

        lastRebalanceTime = block.timestamp;
        try this.getTWAPPrice(MIN_TWAP_PERIOD) returns (uint256 price) {
            lastTWAPPrice = price;
        } catch {
            // If TWAP fails, continue anyway
        }

        emit AdaptiveRebalanceTriggered(rebalanceReason, block.timestamp);
        
        return rebalanceReason;
    }

    /**
     * @notice Execute self-optimization routine
     */
    function executeSelfOptimization() external onlyRole(ADMIN_ROLE) {
        // Try to use AIEngine for self-optimization if enabled
        if (address(aiEngine) != address(0) && useAIEngine) {
            try aiEngine.manualKeeper() {
                emit AIEngineOperationExecuted("executeSelfOptimization", true);
                // Still update local counters
                selfOptimizationCounter++;
                lastAdaptiveLearningUpdate = block.timestamp;
                emit SelfOptimizationExecuted(selfOptimizationCounter, block.timestamp);
                return;
            } catch {
                emit AIEngineOperationExecuted("executeSelfOptimization", false);
                // Fallback to local optimization if AIEngine fails
            }
        }
        
        // Local optimization logic as fallback
        require(block.timestamp >= lastAdaptiveLearningUpdate + 30 days, "Too soon to optimize");

        uint256 timeSinceLast = block.timestamp - lastAdaptiveLearningUpdate;
        uint256 daysSinceLast = timeSinceLast / 1 days;
        uint256 rebalancesExecuted = (lastRebalanceTime - lastAdaptiveLearningUpdate) / rebalanceInterval;
        uint256 annualizedRebalances = (rebalancesExecuted * 365) / (daysSinceLast == 0 ? 1 : daysSinceLast);

        // If more frequent than 120% of target
        if (annualizedRebalances > (rebalancingFrequencyTarget * 12 / 10)) {
            rebalanceInterval = (rebalanceInterval * 110) / 100; // slow it down
        } else if (annualizedRebalances < (rebalancingFrequencyTarget * 8 / 10)) {
            rebalanceInterval = (rebalanceInterval * 90) / 100; // speed up
        }

        // Adjust volatility threshold
        uint256 p = lastTWAPPrice;
        try this.getTWAPPrice(30 days) returns (uint256 newPrice) {
            if (newPrice > p) {
                adaptiveVolatilityThreshold = (adaptiveVolatilityThreshold * 105) / 100;
            } else {
                adaptiveVolatilityThreshold = (adaptiveVolatilityThreshold * 95) / 100;
            }
        } catch {
            // If TWAP fails, keep current threshold
        }
        
        if (adaptiveVolatilityThreshold < 5) {
            adaptiveVolatilityThreshold = 5;
        }
        if (adaptiveVolatilityThreshold > 50) {
            adaptiveVolatilityThreshold = 50;
        }

        lastAdaptiveLearningUpdate = block.timestamp;
        selfOptimizationCounter++;

        emit SelfOptimizationExecuted(selfOptimizationCounter, block.timestamp);
    }

    /**
     * @notice Returns all ecosystem health metrics in a single call
     * @dev Gas-optimized to minimize data accessing costs on Arbitrum
     */
    function getEcosystemHealthMetrics() external view returns (
        uint256 diversityIdx,
        uint256 geneticVol,
        uint256 activeConstituents,
        uint256 adaptiveThreshold,
        uint256 currentPrice,
        uint256 selfOptCounter
    ) {
        // Try to get metrics from AIEngine if enabled
        if (address(aiEngine) != address(0) && useAIEngine) {
            try aiEngine.getActiveConstituents() returns (address[] memory activeAssets) {
                uint256 activeCount = activeAssets.length;
                
                // Try to get other metrics individually
                uint256 aiDiversityIndex;
                uint256 aiGeneticVolatility;
                
                // Use try/catch for each metric to handle potential failures
                try aiEngine.diversityIndex() returns (uint256 div) {
                    aiDiversityIndex = div;
                } catch {
                    aiDiversityIndex = diversityIndex; // Fallback to local value
                }
                
                try aiEngine.geneticVolatility() returns (uint256 vol) {
                    aiGeneticVolatility = vol;
                } catch {
                    aiGeneticVolatility = geneticVolatility; // Fallback to local value
                }
                
                return (
                    aiDiversityIndex,
                    aiGeneticVolatility,
                    activeCount,
                    adaptiveVolatilityThreshold,
                    lastTWAPPrice,
                    selfOptimizationCounter
                );
            } catch {
                // If the getActiveConstituents call fails, fall back to local calculation
            }
        }
        
        // Local calculation as fallback
        uint256 active = 0;
        for (uint256 i = 0; i < constituentList.length; i++) {
            if (constituents[constituentList[i]].isActive) {
                active++;
            }
        }
        
        return (
            diversityIndex,
            geneticVolatility,
            active,
            adaptiveVolatilityThreshold,
            lastTWAPPrice,
            selfOptimizationCounter
        );
    }

    /**
     * @notice Batch retrieval of neural weights for multiple assets
     * @param assets Array of asset addresses to query
     * @return weights Array of current weights
     * @return signals Array of raw signals
     * @return updateTimes Array of last update timestamps
     */
    function batchGetNeuralWeights(address[] calldata assets) 
        external 
        view 
        returns (
            uint256[] memory weights,
            uint256[] memory signals,
            uint256[] memory updateTimes
        ) 
    {
        weights = new uint256[](assets.length);
        signals = new uint256[](assets.length);
        updateTimes = new uint256[](assets.length);
        
        for (uint256 i = 0; i < assets.length; i++) {
            weights[i] = assetNeuralWeights[assets[i]].currentWeight;
            signals[i] = assetNeuralWeights[assets[i]].rawSignal;
            updateTimes[i] = assetNeuralWeights[assets[i]].lastUpdateTime;
        }
        
        return (weights, signals, updateTimes);
    }

    /**
     * @notice Recompute the diversity index (Herfindahl-Hirschman Index)
     * @dev Internal function to update the diversity metric
     */
    function _updateDiversityIndex() internal {
        uint256 activeCount = 0;
        uint256 totalWeight = 0;
        uint256 sumSquared = 0;
        
        // First pass - get active count and total weight
        for (uint256 i = 0; i < constituentList.length; i++) {
            address a = constituentList[i];
            if (constituents[a].isActive) {
                activeCount++;
                totalWeight += assetNeuralWeights[a].currentWeight;
            }
        }

        // Check minimum constituents requirement
        // Allow if we haven't reached minimum yet
        if (activeCount < MIN_CONSTITUENTS && constituentList.length >= MIN_CONSTITUENTS) {
            revert("Insufficient genetic diversity");
        }

        // Second pass - calculate HHI
        if (totalWeight > 0) {
            for (uint256 i = 0; i < constituentList.length; i++) {
                address a = constituentList[i];
                if (constituents[a].isActive) {
                    uint256 w = assetNeuralWeights[a].currentWeight;
                    uint256 share = (w * 10000) / totalWeight;
                    sumSquared += (share * share);
                }
            }
            diversityIndex = sumSquared;
        } else {
            // Fallback - equal distribution
            diversityIndex = activeCount > 0 ? 10000 / activeCount : 0;
        }

        // Sync with AIEngine if enabled
        if (address(aiEngine) != address(0) && useAIEngine) {
            try aiEngine.recalculateDiversityIndex() {
                emit AIEngineOperationExecuted("recalculateDiversityIndex", true);
            } catch {
                emit AIEngineOperationExecuted("recalculateDiversityIndex", false);
            }
        }

        emit DiversityIndexUpdated(diversityIndex);
    }

    /**
     * @notice Batch sync multiple constituents with the AIEngine
     * @param assets Array of constituent addresses to sync
     */
    function batchSyncConstituentsWithAIEngine(address[] calldata assets) 
        external 
        onlyRole(NEURAL_INDEXER_ROLE) 
    {
        require(address(aiEngine) != address(0), "AIEngine not set");
        require(assets.length <= MAX_BATCH_SIZE, "Batch too large");
        
        address dummyPriceFeed = address(0x1); // Would be properly set in production
        
        for (uint256 i = 0; i < assets.length; i++) {
            if (constituents[assets[i]].isActive) {
                try aiEngine.addConstituent(assets[i], dummyPriceFeed) {
                    // Success
                } catch {
                    // Continue with next asset if one fails
                }
            }
        }
        
        emit AIEngineOperationExecuted("batchSyncConstituents", true);
    }
    
    /**
     * @notice Force update local diversity index from AIEngine
     */
    function updateDiversityFromAIEngine() 
        external 
        onlyRole(NEURAL_INDEXER_ROLE) 
    {
        require(address(aiEngine) != address(0), "AIEngine not set");
        require(useAIEngine, "AIEngine not enabled");
        
        try aiEngine.diversityIndex() returns (uint256 aiDiversityIndex) {
            diversityIndex = aiDiversityIndex;
            emit DiversityIndexUpdated(diversityIndex);
            emit AIEngineOperationExecuted("updateDiversityFromAIEngine", true);
        } catch {
            emit AIEngineOperationExecuted("updateDiversityFromAIEngine", false);
            revert("Failed to get diversity from AIEngine");
        }
    }
    
    /**
     * @notice Force update local genetic volatility from AIEngine
     */
    function updateVolatilityFromAIEngine() 
        external 
        onlyRole(NEURAL_INDEXER_ROLE) 
    {
        require(address(aiEngine) != address(0), "AIEngine not set");
        require(useAIEngine, "AIEngine not enabled");
        
        try aiEngine.geneticVolatility() returns (uint256 aiGeneticVolatility) {
            geneticVolatility = aiGeneticVolatility;
            emit AIEngineOperationExecuted("updateVolatilityFromAIEngine", true);
        } catch {
            emit AIEngineOperationExecuted("updateVolatilityFromAIEngine", false);
            revert("Failed to get volatility from AIEngine");
        }
    }
    
    /**
     * @notice Execute AIEngine keeper functions manually
     * @dev Useful for maintenance and ensuring data consistency
     */
    function executeAIEngineKeeper() 
        external 
        onlyRole(AI_MANAGER_ROLE) 
    {
        require(address(aiEngine) != address(0), "AIEngine not set");
        
        try aiEngine.manualKeeper() {
            emit AIEngineOperationExecuted("executeAIEngineKeeper", true);
        } catch {
            emit AIEngineOperationExecuted("executeAIEngineKeeper", false);
            revert("AIEngine keeper operation failed");
        }
    }
    
    /**
     * @notice Get the maximum price deviation allowed by AIEngine
     * @return The maximum price deviation in basis points (100 = 1%)
     */
    function getAIEngineMaxPriceDeviation() 
        external 
        view 
        returns (uint256) 
    {
        if (address(aiEngine) != address(0)) {
            try aiEngine.MAX_PRICE_DEVIATION() returns (uint256 deviation) {
                return deviation;
            } catch {
                return 0;
            }
        }
        return 0;
    }
    
    /**
     * @notice Get AIEngine integration status
     * @return isSet Whether AIEngine is set
     * @return isEnabled Whether AIEngine is enabled for use
     * @return engineAddress The address of the AIEngine (zero if not set)
     */
    function getAIEngineStatus() 
        external 
        view 
        returns (
            bool isSet,
            bool isEnabled,
            address engineAddress
        ) 
    {
        isSet = address(aiEngine) != address(0);
        isEnabled = useAIEngine;
        engineAddress = address(aiEngine);
        
        return (isSet, isEnabled, engineAddress);
    }
}
