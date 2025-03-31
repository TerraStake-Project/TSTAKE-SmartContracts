// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import "@uniswap/v4-periphery/contracts/interfaces/IPositionManager.sol";
import "../interfaces/IAntiBot.sol";
import "@layerzero-labs/solidity-examples/contracts/lzApp/NonblockingLzApp.sol";
import "@api3/airnode-protocol/contracts/rrp/requesters/RrpRequesterV0.sol";

interface IBurnableERC20 is IERC20Upgradeable {
    function burn(uint256 amount) external;
    function totalSupply() external view returns (uint256);
}

interface IArbitrumSequencerOracle {
    function latestAnswer() external view returns (int256);
}

interface IUniswapV4Hook {
    function onSwap(address sender, uint256 amountIn, uint256 amountOut) external;
}

contract TerraStakeITO is 
    AccessControlEnumerableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable, 
    NonblockingLzApp, 
    RrpRequesterV0 
{
    IAntiBot public antiBot;
    IArbitrumSequencerOracle public sequencerOracle;
    IUniswapV4Hook public uniswapV4Hook;
    address public api3Airnode;
    bytes32 public api3EndpointId;
    address public api3SponsorWallet;

    uint24 public constant POOL_FEE = 3000;
    uint256 public constant MAX_TOKENS_FOR_ITO = 300_000_000 * 10**18;
    uint256 public constant DEFAULT_MIN_PURCHASE_USDC = 1_000 * 10**6;
    uint256 public constant DEFAULT_MAX_PURCHASE_USDC = 150_000 * 10**6;
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant MULTISIG_ROLE = keccak256("MULTISIG_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IBurnableERC20 public tStakeToken;
    IERC20Upgradeable public usdcToken;
    IPositionManager public positionManager;
    IPoolManager public poolManager;
    bytes32 public poolId;
    address public treasuryMultiSig;
    address public stakingRewards;
    address public liquidityPool;
    uint256 public startingPrice;
    uint256 public endingPrice;
    uint256 public priceDuration;
    uint256 public tokensSold;
    uint256 public accumulatedUSDC;
    uint256 public itoStartTime;
    uint256 public itoEndTime;
    uint256 public minPurchaseUSDC;
    uint256 public maxPurchaseUSDC;
    bool public purchasesPaused;
    mapping(address => uint256) public purchasedAmounts;
    mapping(address => bool) public blacklist;
    enum ITOState { NotStarted, Active, Ended }
    ITOState public itoState;
    mapping(uint256 => uint256) public positionIds;
    uint256 public positionCounter;
    uint256 public latestApi3Price;
    uint256 public lastSequencerDownTime;
    bool public pendingApi3Request;

    // New Adjustable Parameters
    uint256 public twapTolerance = 5 * 10**16; // Fix 2: Adjustable TWAP tolerance (default 5%)
    uint256 public sequencerCooldown = 15 minutes; // Fix 3: Adjustable cooldown (default 15 minutes)
    uint256 public liquiditySyncThreshold = 50_000 * 10**6; // Fix 4: Threshold for liquidity sync (default 50,000 USDC)

    enum VestingType { Treasury, Staking, Liquidity }
    struct VestingSchedule {
        uint256 totalAmount;
        uint256 initialUnlock;
        uint256 startTime;
        uint256 duration;
        uint256 claimedAmount;
        uint256 lastClaimTime;
    }
    mapping(VestingType => VestingSchedule) public vestingSchedules;

    uint16[] public syncChains;

    mapping(bytes32 => bool) public pendingRequests;

    event TokensPurchased(address indexed buyer, uint256 usdcAmount, uint256 tokenAmount, uint256 timestamp);
    event LiquidityAdded(uint256 usdcAmount, uint256 tStakeAmount, uint256 positionId, uint256 timestamp);
    event ITOStateChanged(ITOState newState);
    event PriceUpdated(uint256 newStartPrice, uint256 newEndPrice, uint256 newDuration);
    event PurchaseLimitsUpdated(uint256 newMin, uint256 newMax);
    event BlacklistStatusUpdated(address indexed account, bool status);
    event EmergencyWithdrawal(address token, uint256 amount);
    event PurchasesPaused(bool status);
    event VestingScheduleInitialized(VestingType vestingType, uint256 totalAmount);
    event VestingClaimed(VestingType vestingType, uint256 amount, uint256 timestamp);
    event TokensBurned(uint256 amount, uint256 timestamp, uint256 newTotalSupply);
    event StateSynced(uint16 indexed chainId, bytes32 indexed payloadHash, uint256 nonce);
    event LiquiditySynced(uint256 usdcAmount, uint256 tStakeAmount);
    event Api3PriceUpdated(uint256 price, uint256 timestamp);
    event Api3RequestMade(bytes32 requestId);
    event TWAPToleranceUpdated(uint256 newTolerance);
    event SequencerCooldownUpdated(uint256 newCooldown);
    event LiquiditySyncThresholdUpdated(uint256 newThreshold);

    modifier ensureSequencerActive() {
        require(address(sequencerOracle) != address(0), "Sequencer oracle not set");
        if (sequencerOracle.latestAnswer() != 0) {
            lastSequencerDownTime = block.timestamp;
            revert("Arbitrum sequencer down");
        }
        require(block.timestamp >= lastSequencerDownTime + sequencerCooldown, "Cooldown after sequencer downtime"); // Fix 3
        _;
    }

    function initialize(
        address _tStakeToken,
        address _usdcToken,
        address _positionManager,
        address _poolManager,
        bytes32 _poolId,
        address _treasuryMultiSig,
        address _stakingRewards,
        address _liquidityPool,
        address _lzEndpoint,
        address _airnodeRrp,
        address admin
    ) external initializer {
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __NonblockingLzApp_init(_lzEndpoint);
        __RrpRequesterV0_init(_airnodeRrp);

        require(_tStakeToken != address(0) && _usdcToken != address(0), "Invalid token addresses");
        require(_positionManager != address(0) && _poolManager != address(0), "Invalid Uniswap addresses");
        require(_treasuryMultiSig != address(0) && _stakingRewards != address(0) && _liquidityPool != address(0), 
                "Invalid operational addresses");
        require(_lzEndpoint != address(0) && _airnodeRrp != address(0) && admin != address(0), "Invalid setup addresses");

        tStakeToken = IBurnableERC20(_tStakeToken);
        usdcToken = IERC20Upgradeable(_usdcToken);
        positionManager = IPositionManager(_positionManager);
        poolManager = IPoolManager(_poolManager);
        poolId = _poolId;
        treasuryMultiSig = _treasuryMultiSig;
        stakingRewards = _stakingRewards;
        liquidityPool = _liquidityPool;

        startingPrice = 0.10 * 10**18;
        endingPrice = 0.20 * 10**18;
        priceDuration = 30 days;
        itoStartTime = block.timestamp;
        itoEndTime = block.timestamp + priceDuration;
        itoState = ITOState.NotStarted;
        minPurchaseUSDC = DEFAULT_MIN_PURCHASE_USDC;
        maxPurchaseUSDC = DEFAULT_MAX_PURCHASE_USDC;

        _setupRoles(admin);
        _initializeVesting();

        syncChains.push(102); // BSC
        syncChains.push(109); // Polygon

        require(tStakeToken.balanceOf(address(this)) >= MAX_TOKENS_FOR_ITO, "Insufficient tStake balance");
    }

    function _setupRoles(address admin) private {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(MULTISIG_ROLE, treasuryMultiSig);
        _grantRole(PAUSER_ROLE, admin);
    }

    function _initializeVesting() private {
        vestingSchedules[VestingType.Treasury] = VestingSchedule(0, 10, block.timestamp, 730 days, 0, block.timestamp);
        vestingSchedules[VestingType.Staking] = VestingSchedule(0, 15, block.timestamp, 1095 days, 0, block.timestamp);
        vestingSchedules[VestingType.Liquidity] = VestingSchedule(0, 0, block.timestamp + 90 days, 180 days, 0, 0);
        emit VestingScheduleInitialized(VestingType.Treasury, 0);
        emit VestingScheduleInitialized(VestingType.Staking, 0);
        emit VestingScheduleInitialized(VestingType.Liquidity, 0);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(GOVERNANCE_ROLE) {}

    function setAntiBot(address _antiBot) external onlyRole(GOVERNANCE_ROLE) {
        require(_antiBot != address(0), "Invalid AntiBot address");
        antiBot = IAntiBot(_antiBot);
    }

    function setSequencerOracle(address _oracle) external onlyRole(GOVERNANCE_ROLE) {
        require(_oracle != address(0), "Invalid oracle address");
        sequencerOracle = IArbitrumSequencerOracle(_oracle);
    }

    function setUniswapV4Hook(address _hook) external onlyRole(GOVERNANCE_ROLE) {
        require(_hook != address(0), "Invalid hook address");
        uniswapV4Hook = IUniswapV4Hook(_hook);
    }

    function setApi3Config(address _airnode, bytes32 _endpointId, address _sponsorWallet) external onlyRole(GOVERNANCE_ROLE) {
        require(_airnode != address(0) && _sponsorWallet != address(0), "Invalid API3 config");
        api3Airnode = _airnode;
        api3EndpointId = _endpointId;
        api3SponsorWallet = _sponsorWallet;
    }

    function setITOState(ITOState newState) external onlyRole(GOVERNANCE_ROLE) {
        require(newState != itoState, "State already set");
        itoState = newState;
        if (newState == ITOState.Active && itoStartTime == block.timestamp) {
            itoStartTime = block.timestamp;
            itoEndTime = block.timestamp + priceDuration;
        }
        emit ITOStateChanged(newState);
        _syncState();
    }

    function togglePurchases(bool paused) external onlyRole(PAUSER_ROLE) {
        purchasesPaused = paused;
        emit PurchasesPaused(paused);
    }

    function updatePurchaseLimits(uint256 newMin, uint256 newMax) external onlyRole(GOVERNANCE_ROLE) {
        require(newMin > 0 && newMin < newMax, "Invalid limits");
        assembly { // Fix 5: Single storage write with assembly
            sstore(minPurchaseUSDC.slot, newMin)
            sstore(maxPurchaseUSDC.slot, newMax)
        }
        emit PurchaseLimitsUpdated(newMin, newMax);
    }

    function updatePricingParameters(uint256 newStartPrice, uint256 newEndPrice, uint256 newDuration) external onlyRole(GOVERNANCE_ROLE) {
        require(itoState == ITOState.NotStarted, "ITO already started");
        require(newStartPrice > 0 && newEndPrice >= newStartPrice, "Invalid prices");
        require(newDuration > 0, "Invalid duration");
        
        startingPrice = newStartPrice;
        endingPrice = newEndPrice;
        priceDuration = newDuration;
        itoEndTime = itoStartTime + newDuration;
        
        emit PriceUpdated(newStartPrice, newEndPrice, newDuration);
        _syncState();
    }

    // New Governance Functions
    function setTWAPTolerance(uint256 newTolerance) external onlyRole(GOVERNANCE_ROLE) { // Fix 2
        require(newTolerance <= 10 * 10**16, "Max tolerance is 10%");
        twapTolerance = newTolerance;
        emit TWAPToleranceUpdated(newTolerance);
    }

    function setSequencerCooldown(uint256 newCooldown) external onlyRole(GOVERNANCE_ROLE) { // Fix 3
        require(newCooldown >= 5 minutes && newCooldown <= 1 hours, "Cooldown must be between 5 minutes and 1 hour");
        sequencerCooldown = newCooldown;
        emit SequencerCooldownUpdated(newCooldown);
    }

    function setLiquiditySyncThreshold(uint256 newThreshold) external onlyRole(GOVERNANCE_ROLE) { // Fix 4
        require(newThreshold > 0, "Threshold must be positive");
        liquiditySyncThreshold = newThreshold;
        emit LiquiditySyncThresholdUpdated(newThreshold);
    }

    function updateBlacklist(address account, bool status) external onlyRole(GOVERNANCE_ROLE) {
        require(account != address(0), "Invalid account");
        blacklist[account] = status;
        emit BlacklistStatusUpdated(account, status);
    }

    function getVestedAmount(VestingType vestingType) public view returns (uint256) {
        VestingSchedule storage schedule = vestingSchedules[vestingType];
        if (block.timestamp < schedule.startTime) return 0;
        
        uint256 timeElapsed = block.timestamp - schedule.startTime;
        if (timeElapsed >= schedule.duration) return schedule.totalAmount - schedule.claimedAmount;
        
        uint256 initialAmount = (schedule.totalAmount * schedule.initialUnlock) / 100;
        uint256 vestingAmount = schedule.totalAmount - initialAmount;
        uint256 vestedAmount = initialAmount + ((vestingAmount * timeElapsed) / schedule.duration);
        if (vestedAmount < schedule.claimedAmount) return 0;
        return vestedAmount - schedule.claimedAmount;
    }

    function claimVestedFunds(VestingType vestingType) external onlyRole(GOVERNANCE_ROLE) nonReentrant ensureSequencerActive {
        VestingSchedule storage schedule = vestingSchedules[vestingType];
        uint256 claimableAmount = getVestedAmount(vestingType);
        
        require(claimableAmount > 0, "No funds to claim");
        require(usdcToken.balanceOf(address(this)) >= claimableAmount, "Insufficient USDC balance");

        schedule.claimedAmount += claimableAmount;
        schedule.lastClaimTime = block.timestamp;

        if (vestingType == VestingType.Treasury) {
            require(usdcToken.transfer(treasuryMultiSig, claimableAmount), "Treasury transfer failed");
        } else if (vestingType == VestingType.Staking) {
            require(usdcToken.transfer(stakingRewards, claimableAmount), "Staking transfer failed");
        } else if (vestingType == VestingType.Liquidity) {
            revert("Use releaseVestedLiquidity for Liquidity vesting");
        }
        
        emit VestingClaimed(vestingType, claimableAmount, block.timestamp);
        _syncState();
    }

    function getCurrentPrice() public view returns (uint256) {
        if (block.timestamp >= itoEndTime) return endingPrice;
        if (itoStartTime == 0 || itoStartTime >= itoEndTime) return startingPrice;
        uint256 elapsed = block.timestamp - itoStartTime;
        if (elapsed >= priceDuration) return endingPrice;
        uint256 priceIncrease = ((endingPrice - startingPrice) * elapsed) / priceDuration;
        return startingPrice + priceIncrease;
    }

    function buyTokens(uint256 usdcAmount, uint256 minTokensOut) 
        external 
        nonReentrant 
        ensureSequencerActive 
    {
        require(itoState == ITOState.Active, "ITO not active");
        require(!purchasesPaused, "Purchases paused");
        require(!blacklist[msg.sender], "Address blacklisted");
        require(usdcAmount >= minPurchaseUSDC && usdcAmount <= maxPurchaseUSDC, "Invalid purchase amount");
        require(latestApi3Price > 0, "API3 price not set");

        if (address(antiBot) != address(0)) {
            require(antiBot.validateTransfer(msg.sender, address(this), usdcAmount), "AntiBot: Transfer rejected");
            require(!antiBot.isCircuitBreakerActive(), "AntiBot: Circuit breaker active");
        }

        uint256 tokenAmount = (usdcAmount * 10**18) / getCurrentPrice();
        require(tokenAmount >= minTokensOut, "Slippage exceeded");
        require(tokensSold + tokenAmount <= MAX_TOKENS_FOR_ITO, "Exceeds allocation");
        require(tStakeToken.balanceOf(address(this)) >= tokenAmount, "Insufficient tStake balance");

        uint256 api3TokenAmount = (usdcAmount * 10**18) / latestApi3Price;
        require(tokenAmount >= api3TokenAmount * 95 / 100 && tokenAmount <= api3TokenAmount * 105 / 100, 
                "Price deviation too high");

        require(usdcToken.transferFrom(msg.sender, address(this), usdcAmount), "USDC transfer failed");
        _distributeUSDC(usdcAmount);

        if (address(uniswapV4Hook) != address(0)) {
            try uniswapV4Hook.onSwap(msg.sender, usdcAmount, tokenAmount) {} catch {}
        }
        require(tStakeToken.transfer(msg.sender, tokenAmount), "Token transfer failed");

        tokensSold += tokenAmount;
        accumulatedUSDC += usdcAmount;
        purchasedAmounts[msg.sender] += tokenAmount;

        if (address(antiBot) != address(0)) {
            antiBot.recordLiquidityInjection(msg.sender);
        }

        emit TokensPurchased(msg.sender, usdcAmount, tokenAmount, block.timestamp);
        _syncState();

        if (accumulatedUSDC >= liquiditySyncThreshold) { // Fix 4: Threshold-based sync
            _syncLiquidity();
            accumulatedUSDC = 0;
        }
    }

    function _distributeUSDC(uint256 amount) internal {
        uint256 treasuryShare = (amount * 40) / 100;
        uint256 stakingShare = (amount * 35) / 100;
        uint256 immediateLiquidityShare = (amount * 25) / 100;
        uint256 vestedLiquidityShare = (amount * 25) / 100;

        vestingSchedules[VestingType.Treasury].totalAmount += treasuryShare;
        vestingSchedules[VestingType.Staking].totalAmount += stakingShare;
        vestingSchedules[VestingType.Liquidity].totalAmount += vestedLiquidityShare;

        _addLiquidity(immediateLiquidityShare);
    }

    function _addLiquidity(uint256 liquidityUSDCAmount) internal {
        if (liquidityUSDCAmount == 0) return;

        uint256 tStakeAmount = (liquidityUSDCAmount * 10**18) / getCurrentPrice();
        require(tStakeToken.balanceOf(address(this)) >= tStakeAmount, "Insufficient tStake for liquidity");

        uint256 twapPrice = getTWAPPrice();
        require(latestApi3Price > 0 && twapPrice > 0, "Price data unavailable");
        require(
            twapPrice >= latestApi3Price * (10**18 - twapTolerance) / 10**18 && // Fix 2: Adjustable tolerance
            twapPrice <= latestApi3Price * (10**18 + twapTolerance) / 10**18,
            "TWAP deviates too much from API3"
        );

        // Fix 1: Conditional approvals
        if (usdcToken.allowance(address(this), address(positionManager)) < liquidityUSDCAmount) {
            usdcToken.approve(address(positionManager), type(uint256).max);
        }
        if (tStakeToken.allowance(address(this), address(positionManager)) < tStakeAmount) {
            tStakeToken.approve(address(positionManager), type(uint256).max);
        }

        IPositionManager.AddLiquidityParams memory params = IPositionManager.AddLiquidityParams({
            poolId: poolId,
            amount0Desired: liquidityUSDCAmount,
            amount1Desired: tStakeAmount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: liquidityPool,
            deadline: block.timestamp + 15 minutes
        });

        (uint256 amount0, uint256 amount1, uint256 positionId) = positionManager.addLiquidity(params);
        positionIds[positionCounter] = positionId;
        positionCounter++;

        if (address(uniswapV4Hook) != address(0)) {
            try uniswapV4Hook.onSwap(address(this), amount0, amount1) {} catch {}
        }

        emit LiquidityAdded(amount0, amount1, positionId, block.timestamp);
    }

    function burnUnsoldTokens() external onlyRole(GOVERNANCE_ROLE) nonReentrant ensureSequencerActive {
        require(itoState == ITOState.Ended, "ITO must be ended");
        require(!purchasesPaused, "System paused");

        uint256 unsoldAmount = MAX_TOKENS_FOR_ITO - tokensSold;
        require(unsoldAmount > 0, "No tokens to burn");
        require(tStakeToken.balanceOf(address(this)) >= unsoldAmount, "Insufficient tStake to burn");

        uint256 currentSupply = tStakeToken.totalSupply();
        tStakeToken.burn(unsoldAmount);
        uint256 newSupply = currentSupply - unsoldAmount;

        emit TokensBurned(unsoldAmount, block.timestamp, newSupply);
        _syncState();
    }

    function emergencyWithdraw(address token) external onlyRole(MULTISIG_ROLE) nonReentrant ensureSequencerActive {
        require(itoState == ITOState.Ended, "ITO not ended");
        require(token != address(tStakeToken), "Cannot withdraw tStake tokens");
        uint256 balance = IERC20Upgradeable(token).balanceOf(address(this));
        require(balance > 0, "No balance to withdraw");
        require(IERC20Upgradeable(token).transfer(treasuryMultiSig, balance), "Withdrawal failed");
        emit EmergencyWithdrawal(token, balance);
    }

    function _syncState() internal {
        bytes memory payload = abi.encode(tokensSold, tStakeToken.totalSupply(), block.timestamp, accumulatedUSDC);
        uint256 feePerChain = msg.value / syncChains.length;

        for (uint256 i = 0; i < syncChains.length; i++) {
            uint16 chainId = syncChains[i];
            _lzSend(
                chainId,
                payload,
                payable(address(this)),
                address(0x0),
                feePerChain
            );
        }
    }

    function _nonblockingLzReceive(
        uint16 _srcChainId,
        bytes memory /* _srcAddress */,
        uint64 /* _nonce */,
        bytes memory /* _payload */
    ) internal override {}

    function requestApi3Price() external onlyRole(GOVERNANCE_ROLE) {
        require(!pendingApi3Request, "API3 request pending");
        pendingApi3Request = true;
        bytes32 requestId = airnodeRrp.makeFullRequest(
            api3Airnode,
            api3EndpointId,
            address(this),
            api3SponsorWallet,
            address(this),
            this.fulfillApi3Price.selector,
            ""
        );
        pendingRequests[requestId] = true;
        emit Api3RequestMade(requestId);
    }

    function fulfillApi3Price(bytes32 requestId, bytes calldata data) external onlyAirnodeRrp {
        require(pendingRequests[requestId], "Request not pending");
        delete pendingRequests[requestId];
        pendingApi3Request = false;
        
        int256 price = abi.decode(data, (int256));
        require(price > 0, "Invalid API3 price");
        latestApi3Price = uint256(price);
        
        emit Api3PriceUpdated(latestApi3Price, block.timestamp);
    }

    function getTWAPPrice() public view returns (uint256) {
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
        uint256 price = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 10**18) / (2**192 * 10**6);
        return price;
    }

    function _syncLiquidity() internal {
        uint256 usdcBalance = usdcToken.balanceOf(address(this));
        uint256 tStakeBalance = tStakeToken.balanceOf(address(this)) - (MAX_TOKENS_FOR_ITO - tokensSold);
        if (usdcBalance > 0 && tStakeBalance > 0) {
            uint256 liquidityUSDC = usdcBalance / 2;
            _addLiquidity(liquidityUSDC);
            emit LiquiditySynced(liquidityUSDC, (liquidityUSDC * 10**18) / getCurrentPrice());
        }
    }

    function syncLiquidity() external onlyRole(GOVERNANCE_ROLE) ensureSequencerActive {
        _syncLiquidity();
    }

    function releaseVestedLiquidity() external nonReentrant onlyRole(GOVERNANCE_ROLE) {
        require(block.timestamp >= lastSequencerDownTime + sequencerCooldown, "Cooldown after sequencer downtime"); // Fix 3
        VestingSchedule storage schedule = vestingSchedules[VestingType.Liquidity];
        
        require(block.timestamp >= schedule.startTime, "Liquidity vesting cliff not reached");
        require(schedule.totalAmount > schedule.claimedAmount, "No liquidity to vest");

        uint256 elapsedTime = block.timestamp - schedule.startTime;
        uint256 totalVestingTime = schedule.duration;

        require(elapsedTime > 0, "Nothing to release yet");

        uint256 vestedAmount = elapsedTime >= totalVestingTime 
            ? schedule.totalAmount 
            : (schedule.totalAmount * elapsedTime) / totalVestingTime;
        uint256 releasable = vestedAmount - schedule.claimedAmount;

        require(releasable > 0, "No new liquidity to release");
        require(usdcToken.balanceOf(address(this)) >= releasable, "Insufficient USDC balance");

        schedule.claimedAmount += releasable;
        schedule.lastClaimTime = block.timestamp;

        _addLiquidity(releasable);

        emit VestingClaimed(VestingType.Liquidity, releasable, block.timestamp);
        _syncState();
    }

    function getITOStats() external view returns (
        uint256 totalSold,
        uint256 remaining,
        uint256 currentPrice,
        ITOState state
    ) {
        return (
            tokensSold,
            MAX_TOKENS_FOR_ITO - tokensSold,
            getCurrentPrice(),
            itoState
        );
    }

    function getPoolPrice() external view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
        return sqrtPriceX96;
    }

    function rebalanceLiquidityPosition(
        uint256 positionId,
        IPositionManager.ModifyPositionParams memory newLiquidityParams
    ) external onlyRole(GOVERNANCE_ROLE) nonReentrant ensureSequencerActive {
        require(positionId < positionCounter, "Invalid position ID");
        if (newLiquidityParams.amount0Desired > 0) {
            if (usdcToken.allowance(address(this), address(positionManager)) < newLiquidityParams.amount0Desired) {
                usdcToken.approve(address(positionManager), type(uint256).max);
            }
        }
        if (newLiquidityParams.amount1Desired > 0) {
            if (tStakeToken.allowance(address(this), address(positionManager)) < newLiquidityParams.amount1Desired) {
                tStakeToken.approve(address(positionManager), type(uint256).max);
            }
        }
        positionManager.modifyPosition(positionId, newLiquidityParams);
    }

    function collectPositionFees(
        uint256 positionId,
        address recipient
    ) external onlyRole(GOVERNANCE_ROLE) nonReentrant ensureSequencerActive {
        require(positionId < positionCounter, "Invalid position ID");
        positionManager.collectFees(positionId, recipient);
    }

    function totalSupply() public view returns (uint256) {
        return tStakeToken.totalSupply();
    }

    receive() external payable {}
}