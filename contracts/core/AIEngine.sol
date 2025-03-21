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
import "./IAIEngine.sol"; // Importing the IAIEngine interface

/**
 * @title AIEngine
 * @notice AI-driven asset management contract with TStake governance, optimized for Arbitrum
 * @dev Upgradeable contract integrating Chainlink for price feeds and automation, implementing IAIEngine
 */
contract AIEngine is
    Initializable,
    AccessControlEnumerableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IAIEngine // Implementing IAIEngine
{
    // Constants
    uint256 public constant MAX_SIGNAL_VALUE = 1e30;
    uint256 public constant MAX_EMA_SMOOTHING = 100;
    uint256 public constant DEFAULT_REBALANCE_INTERVAL = 1 days;
    uint256 public constant MIN_DIVERSITY_INDEX = 500;
    uint256 public constant MAX_DIVERSITY_INDEX = 2500;
    uint256 public constant MAX_PRICE_STALENESS = 24 hours;
    uint256 public constant MAX_PRICE_DEVIATION = 2000;
    uint256 public constant MAX_TIMELOCK = 7 days;
    uint256 public constant VOTING_PERIOD = 3 days;
    uint256 public constant MIN_PROPOSAL_THRESHOLD = 1000 * 10**18;

    // Roles
    bytes32 public constant AI_ADMIN_ROLE = keccak256("AI_ADMIN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    // Data Structures
    struct NeuralWeight {
        uint256 currentWeight; // Changed to uint256 to match IAIEngine
        uint256 rawSignal;     // Changed to uint256 to match IAIEngine
        uint256 lastUpdateTime;// Changed to uint256 to match IAIEngine
        uint256 emaSmoothingFactor; // Changed to uint256 to match IAIEngine
    }

    struct Constituent {
        bool isActive;
        uint256 activationTime; // Changed to uint256 to match IAIEngine
        uint256 evolutionScore; // Changed to uint256 to match IAIEngine
        uint256 index;          // Changed to uint256 to match IAIEngine
        uint256 lastPrice;      // Changed to uint256 to match IAIEngine
        uint256 lastPriceUpdateTime; // Changed to uint256 to match IAIEngine
    }

    struct Feedback {
        address submitter;
        string description;
        uint64 timestamp;
        bool resolved;
    }

    struct Proposal {
        bytes32 id;
        address proposer;
        string description;
        uint64 startTime;
        uint64 endTime;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
        bytes callData;
    }

    // State Variables
    mapping(address => NeuralWeight) public override assetNeuralWeights;
    mapping(address => Constituent) public override constituents;
    address[] public override constituentList;
    uint256 public override activeConstituentCount; // Changed to uint256
    uint256 public override diversityIndex;         // Changed to uint256
    uint256 public override geneticVolatility;      // Changed to uint256
    uint256 public override rebalanceInterval;      // Changed to uint256
    uint256 public override lastRebalanceTime;      // Changed to uint256
    uint256 public override adaptiveVolatilityThreshold; // Changed to uint256
    uint256 public override requiredApprovals;      // Changed to uint256
    mapping(bytes32 => uint256) public override operationApprovals; // Changed to uint256
    mapping(bytes32 => mapping(address => bool)) public override hasApproved;
    uint256 public override operationTimelock;      // Changed to uint256
    mapping(bytes32 => uint256) public override operationScheduledTime; // Changed to uint256
    uint256 public override maxPriceDeviation;      // Changed to uint256
    mapping(address => AggregatorV3Interface) public override priceFeeds;
    IERC20Upgradeable public tStakeToken;
    mapping(bytes32 => Proposal) public proposals;
    mapping(bytes32 => mapping(address => bool)) public hasVoted;
    bytes32[] public proposalIds;
    mapping(uint256 => Feedback) public feedbacks;
    uint256 public feedbackCount;
    address public stakingContract;

    // Events (all IAIEngine events included, plus extras)
    event NeuralWeightUpdated(address indexed asset, uint256 weight, uint256 rawSignal, uint256 smoothingFactor) override;
    event DiversityIndexUpdated(uint256 newIndex) override;
    event AdaptiveRebalanceTriggered(string reason, uint256 timestamp) override;
    event ConstituentAdded(address indexed asset, uint256 timestamp) override;
    event ConstituentDeactivated(address indexed asset, uint256 timestamp) override;
    event OperationApproved(bytes32 indexed operationId, address indexed approver, uint256 currentApprovals) override;
    event OperationScheduled(bytes32 indexed operationId, uint256 executionTime) override;
    event ConfigUpdated(string parameter, uint256 newValue) override;
    event PriceUpdated(address indexed asset, uint256 price, uint256 timestamp) override;
    event CircuitBreaker(address indexed asset, uint256 oldPrice, uint256 newPrice, uint256 deviation) override;
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
        require(updatedAt > 0 && block.timestamp - updatedAt <= MAX_PRICE_STALENESS, "Price stale");
        _;
    }

    modifier withApprovals(bytes32 operationId) {
        require(operationApprovals[operationId] >= requiredApprovals, "Insufficient approvals");
        delete operationApprovals[operationId];
        _;
    }

    modifier timelockElapsed(bytes32 operationId) {
        uint256 scheduledTime = operationScheduledTime[operationId];
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
        lastRebalanceTime = block.timestamp;
        requiredApprovals = 2;
        operationTimelock = 1 days;
        maxPriceDeviation = 2000;

        tStakeToken = IERC20Upgradeable(_tStakeToken);
    }

    function setStakingContract(address _stakingContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_stakingContract != address(0), "Invalid staking contract address");
        stakingContract = _stakingContract;
        _grantRole(AI_ADMIN_ROLE, _stakingContract);
        emit StakingContractSet(_stakingContract);
    }

    // User Feedback Mechanisms
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

    function resolveFeedback(uint256 feedbackId) external onlyRole(AI_ADMIN_ROLE) {
        require(feedbackId < feedbackCount && !feedbacks[feedbackId].resolved, "Invalid or resolved feedback");
        feedbacks[feedbackId].resolved = true;
        emit FeedbackResolved(feedbackId);
    }

    function getFeedback(uint256 feedbackId) external view returns (Feedback memory) {
        require(feedbackId < feedbackCount, "Invalid feedback ID");
        return feedbacks[feedbackId];
    }

    // TStake Governance
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

    function vote(bytes32 proposalId, bool support, uint256 amount) external whenNotPaused {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.startTime > 0 && block.timestamp < proposal.endTime && !proposal.executed, "Invalid voting period");
        require(!hasVoted[proposalId][msg.sender], "Already voted");
        require(tStakeToken.transferFrom(msg.sender, address(this), amount), "Token transfer failed");

        hasVoted[proposalId][msg.sender] = true;
        if (support) {
            proposal.forVotes += amount;
        } else {
            proposal.againstVotes += amount;
        }
        emit Voted(proposalId, msg.sender, support, amount);
    }

    function executeProposal(bytes32 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.startTime > 0 && block.timestamp >= proposal.endTime && !proposal.executed, "Cannot execute");
        require(proposal.forVotes > proposal.againstVotes && proposal.forVotes >= MIN_PROPOSAL_THRESHOLD, "Proposal failed");

        proposal.executed = true;
        (bool success, ) = address(this).call(proposal.callData);
        require(success, "Execution failed");
        emit ProposalExecuted(proposalId);
    }

    function getProposalCount() external view returns (uint256) {
        return proposalIds.length;
    }

    // Constituent Management (IAIEngine implementations)
    function addConstituent(address asset, address priceFeed) external override onlyRole(AI_ADMIN_ROLE) nonReentrant whenNotPaused {
        address[] memory assets = new address[](1);
        address[] memory feeds = new address[](1);
        assets[0] = asset;
        feeds[0] = priceFeed;
        batchAddConstituents(assets, feeds);
    }

    function deactivateConstituent(address asset) external override onlyRole(AI_ADMIN_ROLE) nonReentrant whenNotPaused {
        address[] memory assets = new address[](1);
        assets[0] = asset;
        batchDeactivateConstituents(assets);
    }

    function batchAddConstituents(address[] calldata assets, address[] calldata priceFeeds_)
        public
        onlyRole(AI_ADMIN_ROLE)
        nonReentrant
        whenNotPaused
    {
        require(assets.length == priceFeeds_.length && assets.length > 0, "Invalid arrays");
        uint256 count = activeConstituentCount;
        uint256 timestamp = block.timestamp;

        for (uint256 i; i < assets.length; ) {
            address asset = assets[i];
            address feed = priceFeeds_[i];
            require(asset != address(0) && feed != address(0), "Invalid address");
            Constituent storage c = constituents[asset];
            if (!c.isActive) {
                if (c.activationTime == 0) {
                    c.index = constituentList.length;
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

    function batchDeactivateConstituents(address[] calldata assets)
        public
        onlyRole(AI_ADMIN_ROLE)
        nonReentrant
        whenNotPaused
    {
        require(assets.length > 0, "Empty array");
        uint256 count = activeConstituentCount;
        uint256 timestamp = block.timestamp;

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

    function getActiveConstituents() external view override returns (address[] memory activeAssets) {
        activeAssets = new address[](activeConstituentCount);
        uint256 j;
        for (uint256 i; i < constituentList.length && j < activeConstituentCount; ) {
            address asset = constituentList[i];
            if (constituents[asset].isActive) {
                activeAssets[j] = asset;
                unchecked { j++; }
            }
            unchecked { i++; }
        }
    }

    // Neural Weight Management
    function updateNeuralWeight(address asset, uint256 newRawSignal, uint256 smoothingFactor)
        external
        override
        onlyStakingOrAdmin
        whenNotPaused
    {
        require(smoothingFactor <= MAX_EMA_SMOOTHING && newRawSignal <= MAX_SIGNAL_VALUE, "Invalid input");
        _updateNeuralWeight(asset, newRawSignal, smoothingFactor, block.timestamp);
    }

    function batchUpdateNeuralWeights(
        address[] calldata assets,
        uint256[] calldata newRawSignals,
        uint256[] calldata smoothingFactors
    ) external override onlyRole(AI_ADMIN_ROLE) whenNotPaused {
        require(assets.length == newRawSignals.length && assets.length == smoothingFactors.length && assets.length > 0, "Invalid arrays");
        uint256 timestamp = block.timestamp;
        for (uint256 i; i < assets.length; ) {
            if (constituents[assets[i]].isActive) {
                _updateNeuralWeight(assets[i], newRawSignals[i], smoothingFactors[i], timestamp);
            }
            unchecked { i++; }
        }
    }

    function _updateNeuralWeight(address asset, uint256 newRawSignal, uint256 smoothingFactor, uint256 timestamp) internal {
        NeuralWeight storage w = assetNeuralWeights[asset];
        uint256 currentWeight = w.currentWeight;

        if (w.lastUpdateTime == 0) {
            currentWeight = newRawSignal;
        } else {
            currentWeight = (newRawSignal * smoothingFactor + currentWeight * (MAX_EMA_SMOOTHING - smoothingFactor)) / MAX_EMA_SMOOTHING;
        }

        w.currentWeight = currentWeight;
        w.rawSignal = newRawSignal;
        w.lastUpdateTime = timestamp;
        w.emaSmoothingFactor = smoothingFactor;
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
        diversityIndex = sumSquared;
        emit DiversityIndexUpdated(sumSquared);
    }

    function recalculateDiversityIndex() external override onlyStakingOrAdmin whenNotPaused {
        _updateDiversityIndex();
    }

    // Chainlink Integration
    function fetchLatestPrice(address asset) external override returns (uint256) {
        return _fetchLatestPrice(asset, block.timestamp);
    }

    function _fetchLatestPrice(address asset, uint256 timestamp) internal returns (uint256) {
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

        c.lastPrice = priceUint;
        c.lastPriceUpdateTime = timestamp;
        emit PriceUpdated(asset, priceUint, timestamp);
        return priceUint;
    }

    function batchFetchLatestPrices(address[] calldata assets) external onlyRole(AI_ADMIN_ROLE) whenNotPaused {
        require(assets.length > 0, "Empty array");
        uint256 timestamp = block.timestamp;
        for (uint256 i; i < assets.length; ) {
            if (constituents[assets[i]].isActive) {
                _fetchLatestPrice(assets[i], timestamp);
            }
            unchecked { i++; }
        }
    }

    function getLatestPrice(address asset) external view override returns (uint256 price, bool isFresh) {
        AggregatorV3Interface feed = priceFeeds[asset];
        if (address(feed) == address(0)) return (0, false);
        (, int256 priceInt, , uint256 updatedAt, ) = feed.latestRoundData();
        price = priceInt > 0 ? uint256(priceInt) : 0;
        isFresh = updatedAt > 0 && block.timestamp - updatedAt <= MAX_PRICE_STALENESS;
    }

    function updatePriceFeedAddress(address asset, address newPriceFeed)
        external
        override
        onlyStakingOrAdmin
        nonReentrant
        whenNotPaused
    {
        require(newPriceFeed != address(0), "Invalid feed");
        priceFeeds[asset] = AggregatorV3Interface(newPriceFeed);
        _fetchLatestPrice(asset, block.timestamp);
    }

    // Rebalancing Logic
    function shouldAdaptiveRebalance() public view override returns (bool shouldRebalance, string memory reason) {
        if (block.timestamp >= lastRebalanceTime + rebalanceInterval) return (true, "Time-based rebalance");
        uint256 divIndex = diversityIndex;
        if (divIndex > MAX_DIVERSITY_INDEX) return (true, "Diversity too concentrated");
        if (divIndex < MIN_DIVERSITY_INDEX && divIndex > 0) return (true, "Diversity too dispersed");
        if (geneticVolatility > adaptiveVolatilityThreshold) return (true, "Volatility breach");
        return (false, "No rebalance needed");
    }

    function triggerAdaptiveRebalance() external override onlyStakingOrAdmin nonReentrant whenNotPaused {
        (bool doRebalance, string memory reason) = shouldAdaptiveRebalance();
        require(doRebalance, "Rebalance not needed");
        lastRebalanceTime = block.timestamp;
        emit AdaptiveRebalanceTriggered(reason, block.timestamp);
    }

    function updateGeneticVolatility(uint256 newVolatility) external override onlyRole(AI_ADMIN_ROLE) whenNotPaused {
        geneticVolatility = newVolatility;
        if (newVolatility > adaptiveVolatilityThreshold && block.timestamp >= lastRebalanceTime + (rebalanceInterval / 4)) {
            lastRebalanceTime = block.timestamp;
            emit AdaptiveRebalanceTriggered("Volatility breach", block.timestamp);
        }
    }

    // Chainlink Keeper Methods
    function checkUpkeep(bytes calldata checkData) external view override returns (bool upkeepNeeded, bytes memory performData) {
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
        uint256 timestamp = block.timestamp;

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

    function manualKeeper() external override nonReentrant whenNotPaused {
        uint256 timestamp = block.timestamp;
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

    // Configuration Management (IAIEngine implementations)
    function setRebalanceInterval(uint256 newInterval) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newInterval >= 1 hours && newInterval <= 30 days, "Invalid interval");
        rebalanceInterval = newInterval;
        emit ConfigUpdated("rebalanceInterval", newInterval);
    }

    function setVolatilityThreshold(uint256 newThreshold) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newThreshold > 0 && newThreshold <= 100, "Invalid threshold");
        adaptiveVolatilityThreshold = newThreshold;
        emit ConfigUpdated("volatilityThreshold", newThreshold);
    }

    function setMaxPriceDeviation(uint256 newDeviation) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newDeviation >= 500 && newDeviation <= 5000, "Invalid deviation");
        maxPriceDeviation = newDeviation;
        emit ConfigUpdated("maxPriceDeviation", newDeviation);
    }

    function setRequiredApprovals(uint256 newRequiredApprovals) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRequiredApprovals > 0 && newRequiredApprovals <= getRoleMemberCount(AI_ADMIN_ROLE), "Invalid approvals");
        requiredApprovals = newRequiredApprovals;
        emit ConfigUpdated("requiredApprovals", newRequiredApprovals);
    }

    function setOperationTimelock(uint256 newTimelock) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newTimelock <= MAX_TIMELOCK, "Timelock too long");
        operationTimelock = newTimelock;
        emit ConfigUpdated("operationTimelock", newTimelock);
    }

    function batchSetConfig(ConfigUpdate[] calldata updates) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(updates.length > 0, "Empty array");
        for (uint256 i; i < updates.length; ) {
            ConfigUpdate memory u = updates[i];
            bytes32 paramHash = keccak256(abi.encodePacked(u.parameter));
            if (paramHash == keccak256(abi.encodePacked("rebalanceInterval"))) {
                require(u.value >= 1 hours && u.value <= 30 days, "Invalid interval");
                rebalanceInterval = u.value;
            } else if (paramHash == keccak256(abi.encodePacked("volatilityThreshold"))) {
                require(u.value > 0 && u.value <= 100, "Invalid threshold");
                adaptiveVolatilityThreshold = u.value;
            } else if (paramHash == keccak256(abi.encodePacked("maxPriceDeviation"))) {
                require(u.value >= 500 && u.value <= 5000, "Invalid deviation");
                maxPriceDeviation = u.value;
            } else if (paramHash == keccak256(abi.encodePacked("requiredApprovals"))) {
                require(u.value > 0 && u.value <= getRoleMemberCount(AI_ADMIN_ROLE), "Invalid approvals");
                requiredApprovals = u.value;
            } else if (paramHash == keccak256(abi.encodePacked("operationTimelock"))) {
                require(u.value <= MAX_TIMELOCK, "Timelock too long");
                operationTimelock = u.value;
            } else {
                revert("Unknown parameter");
            }
            emit ConfigUpdated(u.parameter, u.value);
            unchecked { i++; }
        }
    }

    // Multi-signature Functionality
    function approveOperation(bytes32 operationId) external override onlyRole(AI_ADMIN_ROLE) {
        require(!hasApproved[operationId][msg.sender], "Already approved");
        hasApproved[operationId][msg.sender] = true;
        operationApprovals[operationId]++;
        emit OperationApproved(operationId, msg.sender, operationApprovals[operationId]);
    }

    function revokeApproval(bytes32 operationId) external override {
        require(hasApproved[operationId][msg.sender], "Not approved");
        hasApproved[operationId][msg.sender] = false;
        operationApprovals[operationId]--;
        emit OperationApproved(operationId, msg.sender, operationApprovals[operationId]);
    }

    function scheduleOperation(bytes32 operationId) external override onlyRole(AI_ADMIN_ROLE) {
        require(operationApprovals[operationId] >= requiredApprovals && operationScheduledTime[operationId] == 0, "Invalid operation");
        operationScheduledTime[operationId] = block.timestamp + operationTimelock;
        emit OperationScheduled(operationId, operationScheduledTime[operationId]);
    }

    function getOperationId(string calldata action, bytes calldata data) external view override returns (bytes32) {
        return keccak256(abi.encode(action, data, block.timestamp));
    }

    // Emergency & Safety Controls
    function pause() external override onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function unpause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function emergencyResetWeights() external override nonReentrant {
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

    function clearPriceDeviationAlert(address asset) external override onlyRole(EMERGENCY_ROLE) nonReentrant {
        (, int256 price, , uint256 updatedAt, ) = priceFeeds[asset].latestRoundData();
        require(price > 0 && updatedAt > 0, "Invalid price");
        uint256 timestamp = block.timestamp;
        uint256 priceUint = uint256(price);
        Constituent storage c = constituents[asset];
        c.lastPrice = priceUint;
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