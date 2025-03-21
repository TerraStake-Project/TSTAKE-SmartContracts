// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

/**
 * @title AIEngine
 * @notice AI-driven asset management contract with TStake governance, optimized for Arbitrum
 * @dev Upgradeable contract integrating Chainlink for price feeds and automation, designed to work with TerraStakeStaking
 */
contract AIEngine is
    Initializable,
    AccessControlEnumerableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    AutomationCompatibleInterface
{
    // Constants
    uint256 public constant MAX_SIGNAL_VALUE = 1e30; // Maximum raw signal value for neural weights
    uint256 public constant MAX_EMA_SMOOTHING = 100; // Maximum EMA smoothing factor (100%)
    uint256 public constant DEFAULT_REBALANCE_INTERVAL = 1 days; // Default rebalance interval
    uint256 public constant MIN_DIVERSITY_INDEX = 500; // Minimum diversity index (basis points)
    uint256 public constant MAX_DIVERSITY_INDEX = 2500; // Maximum diversity index (basis points)
    uint256 public constant MAX_PRICE_STALENESS = 24 hours; // Maximum price staleness for Chainlink feeds
    uint256 public constant MAX_PRICE_DEVIATION = 2000; // 20% max price deviation (basis points)
    uint256 public constant MAX_TIMELOCK = 7 days; // Maximum timelock for operations
    uint256 public constant VOTING_PERIOD = 3 days; // Voting period for governance proposals
    uint256 public constant MIN_PROPOSAL_THRESHOLD = 1000 * 10**18; // Minimum TStake tokens for proposal execution

    // Roles
    bytes32 public constant AI_ADMIN_ROLE = keccak256("AI_ADMIN_ROLE"); // Role for AI-related operations
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE"); // Role for emergency actions
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE"); // Role for contract upgrades
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE"); // Role for Chainlink keepers

    // Data Structures
    struct NeuralWeight {
        uint128 currentWeight; // Current EMA-adjusted weight
        uint128 rawSignal; // Raw input signal
        uint64 lastUpdateTime; // Timestamp of last update
        uint8 emaSmoothingFactor; // EMA smoothing factor (0-100)
    }

    struct Constituent {
        bool isActive; // Whether the asset is active
        uint64 activationTime; // Timestamp of activation
        uint64 evolutionScore; // Score for genetic evolution
        uint32 index; // Index in constituentList
        uint128 lastPrice; // Last recorded price
        uint64 lastPriceUpdateTime; // Timestamp of last price update
    }

    struct Feedback {
        address submitter; // Address submitting feedback
        string description; // Feedback description
        uint64 timestamp; // Submission timestamp
        bool resolved; // Whether feedback is resolved
    }

    struct Proposal {
        bytes32 id; // Unique proposal ID
        address proposer; // Proposer address
        string description; // Proposal description
        uint64 startTime; // Voting start time
        uint64 endTime; // Voting end time
        uint256 forVotes; // Votes in favor
        uint256 againstVotes; // Votes against
        bool executed; // Whether executed
        bytes callData; // Call data for execution
    }

    // State Variables
    mapping(address => NeuralWeight) public assetNeuralWeights; // Asset neural weights
    mapping(address => Constituent) public constituents; // Asset constituent data
    address[] public constituentList; // List of all constituents
    uint32 public activeConstituentCount; // Number of active constituents
    uint32 public diversityIndex; // Diversity index (HHI-style)
    uint32 public geneticVolatility; // Genetic volatility metric
    uint64 public rebalanceInterval; // Rebalance interval in seconds
    uint64 public lastRebalanceTime; // Timestamp of last rebalance
    uint32 public adaptiveVolatilityThreshold; // Volatility threshold for rebalancing
    uint8 public requiredApprovals; // Number of approvals needed for operations
    mapping(bytes32 => uint8) public operationApprovals; // Approvals per operation
    mapping(bytes32 => mapping(address => bool)) public hasApproved; // Approval status per address
    uint64 public operationTimelock; // Timelock duration for operations
    mapping(bytes32 => uint64) public operationScheduledTime; // Scheduled execution time per operation
    uint16 public maxPriceDeviation; // Maximum allowed price deviation
    mapping(address => AggregatorV3Interface) public priceFeeds; // Chainlink price feeds
    IERC20Upgradeable public tStakeToken; // TStake governance token
    mapping(bytes32 => Proposal) public proposals; // Governance proposals
    mapping(bytes32 => mapping(address => bool)) public hasVoted; // Voting status per proposal
    bytes32[] public proposalIds; // List of proposal IDs
    mapping(uint256 => Feedback) public feedbacks; // User feedback
    uint256 public feedbackCount; // Total feedback submissions
    address public stakingContract; // TerraStakeStaking contract address

    // Events
    event NeuralWeightUpdated(address indexed asset, uint256 weight, uint256 rawSignal, uint256 smoothingFactor);
    event DiversityIndexUpdated(uint256 newIndex);
    event AdaptiveRebalanceTriggered(string reason, uint256 timestamp);
    event ConstituentAdded(address indexed asset, uint256 timestamp);
    event ConstituentDeactivated(address indexed asset, uint256 timestamp);
    event OperationApproved(bytes32 indexed operationId, address indexed approver, uint256 currentApprovals);
    event OperationScheduled(bytes32 indexed operationId, uint256 executionTime);
    event ConfigUpdated(string parameter, uint256 newValue);
    event PriceUpdated(address indexed asset, uint256 price, uint256 timestamp);
    event CircuitBreaker(address indexed asset, uint256 oldPrice, uint256 newPrice, uint256 deviation);
    event FeedbackSubmitted(uint256 indexed feedbackId, address indexed submitter, string description);
    event FeedbackResolved(uint256 indexed feedbackId);
    event ProposalCreated(bytes32 indexed proposalId, address indexed proposer, string description);
    event Voted(bytes32 indexed proposalId, address indexed voter, bool support, uint256 votes);
    event ProposalExecuted(bytes32 indexed proposalId);
    event StakingContractSet(address indexed stakingContract);

    // Modifiers
    modifier validConstituent(address asset) {
        require(constituents[asset].isActive, "Asset not active");
        _;
    }

    modifier freshPrice(address asset) {
        (, , , uint256 updatedAt, ) = priceFeeds[asset].latestRoundData();
        unchecked { require(updatedAt > 0 && block.timestamp - updatedAt <= MAX_PRICE_STALENESS, "Price stale"); }
        _;
    }

    modifier withApprovals(bytes32 operationId) {
        require(operationApprovals[operationId] >= requiredApprovals, "Insufficient approvals");
        delete operationApprovals[operationId];
        _;
    }

    modifier timelockElapsed(bytes32 operationId) {
        uint64 scheduledTime = operationScheduledTime[operationId];
        require(scheduledTime > 0 && block.timestamp >= scheduledTime, "Timelock not elapsed");
        delete operationScheduledTime[operationId];
        _;
    }

    modifier onlyStakingOrAdmin() {
        require(msg.sender == stakingContract || hasRole(AI_ADMIN_ROLE, msg.sender), "Not staking contract or admin");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with the TStake token address
     * @param _tStakeToken Address of the TStake governance token
     */
    function initialize(address _tStakeToken) external initializer {
        __AccessControlEnumerable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        address sender = msg.sender;
        _grantRole(DEFAULT_ADMIN_ROLE, sender);
        _grantRole(AI_ADMIN_ROLE, sender);
        _grantRole(EMERGENCY_ROLE, sender);
        _grantRole(UPGRADER_ROLE, sender);
        _grantRole(KEEPER_ROLE, sender);

        rebalanceInterval = DEFAULT_REBALANCE_INTERVAL;
        adaptiveVolatilityThreshold = 15;
        lastRebalanceTime = uint64(block.timestamp);
        requiredApprovals = 2;
        operationTimelock = 1 days;
        maxPriceDeviation = 2000;

        tStakeToken = IERC20Upgradeable(_tStakeToken);
    }

    /**
     * @notice Sets the TerraStakeStaking contract address and grants it AI_ADMIN_ROLE
     * @param _stakingContract Address of the TerraStakeStaking contract
     */
    function setStakingContract(address _stakingContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_stakingContract != address(0), "Invalid staking contract address");
        stakingContract = _stakingContract;
        _grantRole(AI_ADMIN_ROLE, _stakingContract);
        emit StakingContractSet(_stakingContract);
    }

    // User Feedback Mechanisms
    /**
     * @notice Submits user feedback
     * @param description Feedback description
     */
    function submitFeedback(string calldata description) external whenNotPaused {
        uint256 id = feedbackCount++;
        feedbacks[id] = Feedback({
            submitter: msg.sender,
            description: description,
            timestamp: uint64(block.timestamp),
            resolved: false
        });
        emit FeedbackSubmitted(id, msg.sender, description);
    }

    /**
     * @notice Resolves a feedback entry
     * @param feedbackId ID of the feedback to resolve
     */
    function resolveFeedback(uint256 feedbackId) external onlyRole(AI_ADMIN_ROLE) {
        require(feedbackId < feedbackCount && !feedbacks[feedbackId].resolved, "Invalid or resolved feedback");
        feedbacks[feedbackId].resolved = true;
        emit FeedbackResolved(feedbackId);
    }

    /**
     * @notice Retrieves a feedback entry
     * @param feedbackId ID of the feedback
     * @return Feedback struct
     */
    function getFeedback(uint256 feedbackId) external view returns (Feedback memory) {
        require(feedbackId < feedbackCount, "Invalid feedback ID");
        return feedbacks[feedbackId];
    }

    // TStake Governance
    /**
     * @notice Creates a governance proposal
     * @param description Proposal description
     * @param callData Call data for execution
     */
    function createProposal(string calldata description, bytes calldata callData) external whenNotPaused {
        require(tStakeToken.balanceOf(msg.sender) > 0, "No TStake tokens");
        bytes32 proposalId = keccak256(abi.encode(msg.sender, description, block.timestamp));
        uint64 timestamp = uint64(block.timestamp);

        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            description: description,
            startTime: timestamp,
            endTime: timestamp + VOTING_PERIOD,
            forVotes: 0,
            againstVotes: 0,
            executed: false,
            callData: callData
        });
        proposalIds.push(proposalId);
        emit ProposalCreated(proposalId, msg.sender, description);
    }

    /**
     * @notice Votes on a governance proposal
     * @param proposalId ID of the proposal
     * @param support Whether to support the proposal
     * @param amount Number of TStake tokens to vote with
     */
    function vote(bytes32 proposalId, bool support, uint256 amount) external whenNotPaused {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.startTime > 0 && block.timestamp < proposal.endTime && !proposal.executed, "Invalid voting period");
        require(!hasVoted[proposalId][msg.sender], "Already voted");
        require(tStakeToken.transferFrom(msg.sender, address(this), amount), "Token transfer failed");

        hasVoted[proposalId][msg.sender] = true;
        if (support) {
            proposal.forVotes += amount; // Overflow checked by Solidity 0.8+
        } else {
            proposal.againstVotes += amount;
        }
        emit Voted(proposalId, msg.sender, support, amount);
    }

    /**
     * @notice Executes a passed governance proposal
     * @param proposalId ID of the proposal
     */
    function executeProposal(bytes32 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.startTime > 0 && block.timestamp >= proposal.endTime && !proposal.executed, "Cannot execute");
        require(proposal.forVotes > proposal.againstVotes && proposal.forVotes >= MIN_PROPOSAL_THRESHOLD, "Proposal failed");

        proposal.executed = true;
        (bool success, ) = address(this).call(proposal.callData);
        require(success, "Execution failed");
        emit ProposalExecuted(proposalId);
    }

    /**
     * @notice Returns the total number of proposals
     * @return Number of proposals
     */
    function getProposalCount() external view returns (uint256) {
        return proposalIds.length;
    }

    // Batch Constituent Management
    /**
     * @notice Adds multiple constituents with their price feeds
     * @param assets Array of asset addresses
     * @param priceFeeds_ Array of corresponding price feed addresses
     */
    function batchAddConstituents(address[] calldata assets, address[] calldata priceFeeds_)
        external
        onlyRole(AI_ADMIN_ROLE)
        nonReentrant
        whenNotPaused
    {
        require(assets.length == priceFeeds_.length && assets.length > 0, "Invalid arrays");
        uint32 count = activeConstituentCount;
        uint64 timestamp = uint64(block.timestamp);

        for (uint256 i; i < assets.length; ) {
            address asset = assets[i];
            address feed = priceFeeds_[i];
            require(asset != address(0) && feed != address(0), "Invalid address");
            Constituent storage c = constituents[asset];
            if (!c.isActive) {
                if (c.activationTime == 0) {
                    c.index = uint32(constituentList.length);
                    constituentList.push(asset);
                }
                c.isActive = true;
                c.activationTime = timestamp;
                c.evolutionScore = 0;
                priceFeeds[asset] = AggregatorV3Interface(feed);
                _fetchLatestPrice(asset, timestamp);
                count++;
                emit ConstituentAdded(asset, timestamp);
            }
            unchecked { i++; }
        }
        activeConstituentCount = count;
    }

    /**
     * @notice Deactivates multiple constituents
     * @param assets Array of asset addresses
     */
    function batchDeactivateConstituents(address[] calldata assets)
        external
        onlyRole(AI_ADMIN_ROLE)
        nonReentrant
        whenNotPaused
    {
        require(assets.length > 0, "Empty array");
        uint32 count = activeConstituentCount;
        uint64 timestamp = uint64(block.timestamp);

        for (uint256 i; i < assets.length; ) {
            address asset = assets[i];
            Constituent storage c = constituents[asset];
            if (c.isActive) {
                c.isActive = false;
                count--;
                emit ConstituentDeactivated(asset, timestamp);
            }
            unchecked { i++; }
        }
        activeConstituentCount = count;
        _updateDiversityIndex();
    }

    /**
     * @notice Returns the list of active constituents
     * @return Array of active constituent addresses
     */
    function getActiveConstituents() external view returns (address[] memory) {
        address[] memory activeAssets = new address[](activeConstituentCount);
        uint256 j;
        for (uint256 i; i < constituentList.length && j < activeConstituentCount; ) {
            address asset = constituentList[i];
            if (constituents[asset].isActive) {
                activeAssets[j] = asset;
                unchecked { j++; }
            }
            unchecked { i++; }
        }
        return activeAssets;
    }

    // Neural Weight Management
    /**
     * @notice Updates the neural weight for an asset
     * @param asset Asset address (can be user address for TerraStakeStaking)
     * @param newRawSignal New raw signal value
     * @param smoothingFactor EMA smoothing factor (0-100)
     */
    function updateNeuralWeight(address asset, uint256 newRawSignal, uint256 smoothingFactor)
        external
        onlyStakingOrAdmin
        whenNotPaused
    {
        require(smoothingFactor <= MAX_EMA_SMOOTHING && newRawSignal <= MAX_SIGNAL_VALUE, "Invalid input");
        _updateNeuralWeight(asset, newRawSignal, smoothingFactor, uint64(block.timestamp));
    }

    /**
     * @notice Batch updates neural weights for multiple assets
     * @param assets Array of asset addresses
     * @param newRawSignals Array of new raw signal values
     * @param smoothingFactors Array of EMA smoothing factors
     */
    function batchUpdateNeuralWeights(
        address[] calldata assets,
        uint256[] calldata newRawSignals,
        uint256[] calldata smoothingFactors
    ) external onlyRole(AI_ADMIN_ROLE) whenNotPaused {
        require(assets.length == newRawSignals.length && assets.length == smoothingFactors.length && assets.length > 0, "Invalid arrays");
        uint64 timestamp = uint64(block.timestamp);
        for (uint256 i; i < assets.length; ) {
            if (constituents[assets[i]].isActive) {
                _updateNeuralWeight(assets[i], newRawSignals[i], smoothingFactors[i], timestamp);
            }
            unchecked { i++; }
        }
    }

    function _updateNeuralWeight(address asset, uint256 newRawSignal, uint256 smoothingFactor, uint64 timestamp) internal {
        NeuralWeight storage w = assetNeuralWeights[asset];
        uint128 currentWeight = w.currentWeight;
        uint128 rawSignal = uint128(newRawSignal);
        uint8 emaSmoothing = uint8(smoothingFactor);

        if (w.lastUpdateTime == 0) {
            currentWeight = rawSignal;
        } else {
            unchecked {
                currentWeight = uint128(
                    (rawSignal * emaSmoothing + currentWeight * (MAX_EMA_SMOOTHING - emaSmoothing)) / MAX_EMA_SMOOTHING
                );
            }
        }

        w.currentWeight = currentWeight;
        w.rawSignal = rawSignal;
        w.lastUpdateTime = timestamp;
        w.emaSmoothingFactor = emaSmoothing;
        emit NeuralWeightUpdated(asset, currentWeight, newRawSignal, smoothingFactor);
        _updateDiversityIndex();
    }

    // Diversity Index Management
    function _updateDiversityIndex() internal {
        if (activeConstituentCount == 0) {
            diversityIndex = 0;
            emit DiversityIndexUpdated(0);
            return;
        }

        uint256 totalWeight;
        uint256[] memory weights = new uint256[](constituentList.length);
        for (uint256 i; i < constituentList.length; ) {
            address asset = constituentList[i];
            if (constituents[asset].isActive) {
                weights[i] = assetNeuralWeights[asset].currentWeight;
                totalWeight += weights[i];
            }
            unchecked { i++; }
        }

        if (totalWeight == 0) {
            diversityIndex = 0;
            emit DiversityIndexUpdated(0);
            return;
        }

        uint256 sumSquared;
        for (uint256 i; i < constituentList.length; ) {
            if (weights[i] > 0 && constituents[constituentList[i]].isActive) {
                uint256 share = (weights[i] * 10000) / totalWeight;
                sumSquared += share * share;
            }
            unchecked { i++; }
        }
        diversityIndex = uint32(sumSquared);
        emit DiversityIndexUpdated(sumSquared);
    }

    /**
     * @notice Recalculates the diversity index
     */
    function recalculateDiversityIndex() external onlyStakingOrAdmin whenNotPaused {
        _updateDiversityIndex();
    }

    // Chainlink Integration
    /**
     * @notice Fetches the latest price for an asset
     * @param asset Asset address
     * @return Latest price
     */
    function fetchLatestPrice(address asset) external returns (uint256) {
        return _fetchLatestPrice(asset, uint64(block.timestamp));
    }

    function _fetchLatestPrice(address asset, uint64 timestamp) internal returns (uint256) {
        AggregatorV3Interface feed = priceFeeds[asset];
        require(address(feed) != address(0), "No price feed");

        (uint80 roundId, int256 price, , uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        require(price > 0 && updatedAt > 0 && answeredInRound >= roundId, "Invalid price");

        uint256 priceUint = uint256(price);
        Constituent storage c = constituents[asset];
        uint256 oldPrice = c.lastPrice;

        if (oldPrice > 0) {
            uint256 deviation = priceUint > oldPrice
                ? ((priceUint - oldPrice) * 10000) / oldPrice
                : ((oldPrice - priceUint) * 10000) / oldPrice;
            if (deviation > maxPriceDeviation) {
                emit CircuitBreaker(asset, oldPrice, priceUint, deviation);
                if (deviation > maxPriceDeviation * 2) {
                    bytes32 opId = keccak256(abi.encode("acceptPriceDeviation", asset, priceUint, timestamp));
                    require(hasRole(EMERGENCY_ROLE, msg.sender) || operationApprovals[opId] >= requiredApprovals, "Price deviation needs approval");
                }
            }
        }

        c.lastPrice = uint128(priceUint);
        c.lastPriceUpdateTime = timestamp;
        emit PriceUpdated(asset, priceUint, timestamp);
        return priceUint;
    }

    /**
     * @notice Batch fetches latest prices for multiple assets
     * @param assets Array of asset addresses
     */
    function batchFetchLatestPrices(address[] calldata assets) external onlyRole(AI_ADMIN_ROLE) whenNotPaused {
        require(assets.length > 0, "Empty array");
        uint64 timestamp = uint64(block.timestamp);
        for (uint256 i; i < assets.length; ) {
            if (constituents[assets[i]].isActive) {
                _fetchLatestPrice(assets[i], timestamp);
            }
            unchecked { i++; }
        }
    }

    /**
     * @notice Gets the latest price and freshness status for an asset
     * @param asset Asset address
     * @return price Latest price
     * @return isFresh Whether the price is fresh
     */
    function getLatestPrice(address asset) external view returns (uint256 price, bool isFresh) {
        AggregatorV3Interface feed = priceFeeds[asset];
        if (address(feed) == address(0)) return (0, false);
        (, int256 priceInt, , uint256 updatedAt, ) = feed.latestRoundData();
        price = priceInt > 0 ? uint256(priceInt) : 0;
        isFresh = updatedAt > 0 && block.timestamp - updatedAt <= MAX_PRICE_STALENESS;
    }

    /**
     * @notice Updates the price feed address for an asset
     * @param asset Asset address
     * @param newPriceFeed New price feed address
     */
    function updatePriceFeedAddress(address asset, address newPriceFeed)
        external
        onlyStakingOrAdmin
        nonReentrant
        whenNotPaused
    {
        require(newPriceFeed != address(0), "Invalid feed");
        priceFeeds[asset] = AggregatorV3Interface(newPriceFeed);
        _fetchLatestPrice(asset, uint64(block.timestamp));
    }

    // Rebalancing Logic
    /**
     * @notice Checks if an adaptive rebalance is needed
     * @return doRebalance Whether rebalance is needed
     * @return reason Reason for rebalance
     */
    function shouldAdaptiveRebalance() public view returns (bool doRebalance, string memory reason) {
        if (block.timestamp >= lastRebalanceTime + rebalanceInterval) return (true, "Time-based rebalance");
        uint32 divIndex = diversityIndex;
        if (divIndex > MAX_DIVERSITY_INDEX) return (true, "Diversity too concentrated");
        if (divIndex < MIN_DIVERSITY_INDEX && divIndex > 0) return (true, "Diversity too dispersed");
        if (geneticVolatility > adaptiveVolatilityThreshold) return (true, "Volatility breach");
        return (false, "No rebalance needed");
    }

    /**
     * @notice Triggers an adaptive rebalance
     */
    function triggerAdaptiveRebalance() external onlyStakingOrAdmin nonReentrant whenNotPaused {
        (bool doRebalance, string memory reason) = shouldAdaptiveRebalance();
        require(doRebalance, "Rebalance not needed");
        lastRebalanceTime = uint64(block.timestamp);
        emit AdaptiveRebalanceTriggered(reason, block.timestamp);
    }

    /**
     * @notice Updates the genetic volatility metric
     * @param newVolatility New volatility value
     */
    function updateGeneticVolatility(uint256 newVolatility) external onlyRole(AI_ADMIN_ROLE) whenNotPaused {
        geneticVolatility = uint32(newVolatility);
        if (newVolatility > adaptiveVolatilityThreshold && block.timestamp >= lastRebalanceTime + (rebalanceInterval / 4)) {
            lastRebalanceTime = uint64(block.timestamp);
            emit AdaptiveRebalanceTriggered("Volatility breach", block.timestamp);
        }
    }

    // Chainlink Keeper Methods
    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        if (paused()) return (false, "");

        (bool shouldRebalance, ) = shouldAdaptiveRebalance();
        address[] memory assetsToUpdate = new address[](constituentList.length);
        uint256 updateCount;

        for (uint256 i; i < constituentList.length; ) {
            address asset = constituentList[i];
            if (constituents[asset].isActive) {
                (, , , uint256 updatedAt, ) = priceFeeds[asset].latestRoundData();
                if (updatedAt == 0 || block.timestamp - updatedAt > MAX_PRICE_STALENESS / 2) {
                    assetsToUpdate[updateCount] = asset;
                    updateCount++;
                }
            }
            unchecked { i++; }
        }

        upkeepNeeded = shouldRebalance || updateCount > 0;
        performData = abi.encode(shouldRebalance, updateCount > 0, updateCount, assetsToUpdate);
    }

    function performUpkeep(bytes calldata performData) external override nonReentrant {
        require(hasRole(KEEPER_ROLE, msg.sender) || msg.sender == tx.origin, "Not authorized");
        require(!paused(), "Contract paused");

        (bool doRebalance, bool updatePrice, uint256 updateCount, address[] memory assetsToUpdate) =
            abi.decode(performData, (bool, bool, uint256, address[]));
        uint64 timestamp = uint64(block.timestamp);

        if (updatePrice && updateCount > 0) {
            for (uint256 i; i < updateCount; ) {
                address asset = assetsToUpdate[i];
                if (constituents[asset].isActive) {
                    try this._fetchLatestPrice(asset, timestamp) {} catch {
                        emit PriceUpdated(asset, 0, timestamp);
                    }
                }
                unchecked { i++; }
            }
        }

        if (doRebalance) {
            (bool shouldRebalance, string memory reason) = shouldAdaptiveRebalance();
            if (shouldRebalance) {
                lastRebalanceTime = timestamp;
                emit AdaptiveRebalanceTriggered(reason, timestamp);
            }
        }
    }

    /**
     * @notice Manually triggers keeper-like maintenance
     */
    function manualKeeper() external nonReentrant whenNotPaused {
        uint64 timestamp = uint64(block.timestamp);
        for (uint256 i; i < constituentList.length; ) {
            address asset = constituentList[i];
            if (constituents[asset].isActive) {
                try this._fetchLatestPrice(asset, timestamp) {} catch {
                    emit PriceUpdated(asset, 0, timestamp);
                }
            }
            unchecked { i++; }
        }

        (bool doRebalance, string memory reason) = shouldAdaptiveRebalance();
        if (doRebalance) {
            lastRebalanceTime = timestamp;
            emit AdaptiveRebalanceTriggered(reason, timestamp);
        }
    }

    // Batch Configuration Management
    struct ConfigUpdate {
        string parameter;
        uint256 value;
    }

    /**
     * @notice Batch updates configuration parameters
     * @param updates Array of parameter-value pairs
     */
    function batchSetConfig(ConfigUpdate[] calldata updates) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(updates.length > 0, "Empty array");
        for (uint256 i; i < updates.length; ) {
            ConfigUpdate memory u = updates[i];
            bytes32 paramHash = keccak256(abi.encodePacked(u.parameter));
            if (paramHash == keccak256(abi.encodePacked("rebalanceInterval"))) {
                require(u.value >= 1 hours && u.value <= 30 days, "Invalid interval");
                rebalanceInterval = uint64(u.value);
            } else if (paramHash == keccak256(abi.encodePacked("volatilityThreshold"))) {
                require(u.value > 0 && u.value <= 100, "Invalid threshold");
                adaptiveVolatilityThreshold = uint32(u.value);
            } else if (paramHash == keccak256(abi.encodePacked("maxPriceDeviation"))) {
                require(u.value >= 500 && u.value <= 5000, "Invalid deviation");
                maxPriceDeviation = uint16(u.value);
            } else if (paramHash == keccak256(abi.encodePacked("requiredApprovals"))) {
                require(u.value > 0 && u.value <= getRoleMemberCount(AI_ADMIN_ROLE), "Invalid approvals");
                requiredApprovals = uint8(u.value);
            } else if (paramHash == keccak256(abi.encodePacked("operationTimelock"))) {
                require(u.value <= MAX_TIMELOCK, "Timelock too long");
                operationTimelock = uint64(u.value);
            } else {
                revert("Unknown parameter");
            }
            emit ConfigUpdated(u.parameter, u.value);
            unchecked { i++; }
        }
    }

    // Multi-signature Functionality
    /**
     * @notice Approves an operation
     * @param operationId Operation ID
     */
    function approveOperation(bytes32 operationId) external onlyRole(AI_ADMIN_ROLE) {
        require(!hasApproved[operationId][msg.sender], "Already approved");
        hasApproved[operationId][msg.sender] = true;
        operationApprovals[operationId]++;
        emit OperationApproved(operationId, msg.sender, operationApprovals[operationId]);
    }

    /**
     * @notice Revokes an operation approval
     * @param operationId Operation ID
     */
    function revokeApproval(bytes32 operationId) external {
        require(hasApproved[operationId][msg.sender], "Not approved");
        hasApproved[operationId][msg.sender] = false;
        operationApprovals[operationId]--;
        emit OperationApproved(operationId, msg.sender, operationApprovals[operationId]);
    }

    /**
     * @notice Schedules an operation for execution
     * @param operationId Operation ID
     */
    function scheduleOperation(bytes32 operationId) external onlyRole(AI_ADMIN_ROLE) {
        require(operationApprovals[operationId] >= requiredApprovals && operationScheduledTime[operationId] == 0, "Invalid operation");
        operationScheduledTime[operationId] = uint64(block.timestamp + operationTimelock);
        emit OperationScheduled(operationId, operationScheduledTime[operationId]);
    }

    /**
     * @notice Generates an operation ID
     * @param action Action description
     * @param data Additional data
     * @return Operation ID
     */
    function getOperationId(string calldata action, bytes calldata data) external view returns (bytes32) {
        return keccak256(abi.encode(action, data, block.timestamp));
    }

    // Emergency & Safety Controls
    /**
     * @notice Pauses the contract
     */
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the contract
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Resets all neural weights in an emergency
     */
    function emergencyResetWeights() external nonReentrant {
        bytes32 opId = keccak256(abi.encode("emergencyResetWeights", block.timestamp));
        require(hasRole(EMERGENCY_ROLE, msg.sender) && operationApprovals[opId] >= requiredApprovals, "Insufficient approvals");
        delete operationApprovals[opId];

        for (uint256 i; i < constituentList.length; ) {
            address asset = constituentList[i];
            if (constituents[asset].isActive) {
                delete assetNeuralWeights[asset];
            }
            unchecked { i++; }
        }
        diversityIndex = 0;
        geneticVolatility = 0;
        emit ConfigUpdated("emergencyReset", block.timestamp);
    }

    /**
     * @notice Clears a price deviation alert
     * @param asset Asset address
     */
    function clearPriceDeviationAlert(address asset) external onlyRole(EMERGENCY_ROLE) nonReentrant {
        (, int256 price, , uint256 updatedAt, ) = priceFeeds[asset].latestRoundData();
        require(price > 0 && updatedAt > 0, "Invalid price");
        uint64 timestamp = uint64(block.timestamp);
        uint256 priceUint = uint256(price);
        Constituent storage c = constituents[asset];
        c.lastPrice = uint128(priceUint);
        c.lastPriceUpdateTime = timestamp;
        emit PriceUpdated(asset, priceUint, timestamp);
    }

    // Upgradeability
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
        withApprovals(keccak256(abi.encode("upgrade", newImplementation, block.timestamp)))
        timelockElapsed(keccak256(abi.encode("upgrade", newImplementation, block.timestamp)))
    {}
}