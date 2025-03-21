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
 * @notice AI-driven asset management with TStake governance on Arbitrum, updated for TerraStakeStaking compatibility
 * @dev Upgradeable contract optimized for Arbitrum with Chainlink integration
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
    uint256 public constant MAX_SIGNAL_VALUE = 1e30;
    uint256 public constant MAX_EMA_SMOOTHING = 100;
    uint256 public constant DEFAULT_REBALANCE_INTERVAL = 1 days;
    uint256 public constant MIN_DIVERSITY_INDEX = 500;
    uint256 public constant MAX_DIVERSITY_INDEX = 2500;
    uint256 public constant MAX_PRICE_STALENESS = 24 hours;
    uint256 public constant MAX_PRICE_DEVIATION = 2000; // 20% in basis points
    uint256 public constant MAX_TIMELOCK = 7 days;
    uint256 public constant VOTING_PERIOD = 3 days;
    uint256 public constant MIN_PROPOSAL_THRESHOLD = 1000 * 10**18; // 1000 TSTK tokens

    // Roles
    bytes32 public constant AI_ADMIN_ROLE = 0x6e3f2c4c4e6e4c2e4f1b2e4e6e4c2e4e6e4c2e4e6e4c2e4e6e4c2e4e6e4c2e4e;
    bytes32 public constant EMERGENCY_ROLE = 0x7e4f3c5d5e7f5d3e5g2c3e5e7f5d3e5g2c3e5e7f5d3e5g2c3e5e7f5d3e5g2c3e5e;
    bytes32 public constant UPGRADER_ROLE = 0x8f5g4d6e6f8g6e4f6h3d4f6e8g6e4f6h3d4f6e8g6e4f6h3d4f6e8g6e4f6h3d4f6e;
    bytes32 public constant KEEPER_ROLE = 0x9g6h5e7f7g9h7f5g7i4e5g7f9h7f5g7i4e5g7f9h7f5g7i4e5g7f9h7f5g7i4e5g7f;

    // Data Structures
    struct NeuralWeight {
        uint128 currentWeight;
        uint128 rawSignal;
        uint64 lastUpdateTime;
        uint8 emaSmoothingFactor;
    }

    struct Constituent {
        bool isActive;
        uint64 activationTime;
        uint64 evolutionScore;
        uint32 index;
        uint128 lastPrice;
        uint64 lastPriceUpdateTime;
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
    mapping(address => NeuralWeight) public assetNeuralWeights;
    mapping(address => Constituent) public constituents;
    address[] public constituentList;
    uint32 public activeConstituentCount;
   
    uint32 public diversityIndex;
    uint32 public geneticVolatility;
   
    uint64 public rebalanceInterval;
    uint64 public lastRebalanceTime;
    uint32 public adaptiveVolatilityThreshold;
   
    uint8 public requiredApprovals;
    mapping(bytes32 => uint8) public operationApprovals;
    mapping(bytes32 => mapping(address => bool)) public hasApproved;
    uint64 public operationTimelock;
    mapping(bytes32 => uint64) public operationScheduledTime;
   
    uint16 public maxPriceDeviation;
    mapping(address => AggregatorV3Interface) public priceFeeds;

    // TStake Governance
    IERC20Upgradeable public tStakeToken;
    mapping(bytes32 => Proposal) public proposals;
    mapping(bytes32 => mapping(address => bool)) public hasVoted;
    bytes32[] public proposalIds;

    // Feedback
    mapping(uint256 => Feedback) public feedbacks;
    uint256 public feedbackCount;

    // Staking Contract Integration
    address public stakingContract; // TerraStakeStaking address

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

    // Initialization
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _tStakeToken) public initializer {
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

    // Staking Contract Integration
    function setStakingContract(address _stakingContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_stakingContract != address(0), "Invalid staking contract address");
        stakingContract = _stakingContract;
        _grantRole(AI_ADMIN_ROLE, _stakingContract); // Allow TerraStakeStaking to call AI_ADMIN_ROLE functions
        emit StakingContractSet(_stakingContract);
    }

    // User Feedback Mechanisms
    function submitFeedback(string calldata description) external whenNotPaused {
        uint256 id = feedbackCount;
        feedbacks[id] = Feedback({
            submitter: msg.sender,
            description: description,
            timestamp: uint64(block.timestamp),
            resolved: false
        });
        unchecked { feedbackCount++; }
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
        uint256 balance = tStakeToken.balanceOf(msg.sender);
        require(balance > 0, "No TStake tokens");
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
            unchecked { proposal.forVotes += amount; }
        } else {
            unchecked { proposal.againstVotes += amount; }
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

    // Batch Constituent Management
    function batchAddConstituents(address[] calldata assets, address[] calldata priceFeeds_)
        external
        onlyRole(AI_ADMIN_ROLE)
        nonReentrant
        whenNotPaused
    {
        uint256 len = assets.length;
        require(len == priceFeeds_.length && len > 0, "Invalid arrays");
        uint32 count = activeConstituentCount;
        uint64 timestamp = uint64(block.timestamp);

        for (uint256 i; i < len; ) {
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
                unchecked { count++; }
                emit ConstituentAdded(asset, timestamp);
            }
            unchecked { i++; }
        }
        activeConstituentCount = count;
    }

    function batchDeactivateConstituents(address[] calldata assets)
        external
        onlyRole(AI_ADMIN_ROLE)
        nonReentrant
        whenNotPaused
    {
        uint256 len = assets.length;
        require(len > 0, "Empty array");
        uint32 count = activeConstituentCount;
        uint64 timestamp = uint64(block.timestamp);

        for (uint256 i; i < len; ) {
            address asset = assets[i];
            Constituent storage c = constituents[asset];
            if (c.isActive) {
                c.isActive = false;
                unchecked { count--; }
                emit ConstituentDeactivated(asset, timestamp);
            }
            unchecked { i++; }
        }
        activeConstituentCount = count;
        _updateDiversityIndex();
    }

    function getActiveConstituents() external view returns (address[] memory) {
        uint32 count = activeConstituentCount;
        address[] memory activeAssets = new address[](count);
        uint256 len = constituentList.length;
        uint256 j;
        for (uint256 i; i < len && j < count; ) {
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
    function updateNeuralWeight(address asset, uint256 newRawSignal, uint256 smoothingFactor)
        public
        onlyStakingOrAdmin
        whenNotPaused
    {
        require(smoothingFactor <= MAX_EMA_SMOOTHING && newRawSignal <= MAX_SIGNAL_VALUE, "Invalid input");
        _updateNeuralWeight(asset, newRawSignal, smoothingFactor, uint64(block.timestamp));
    }

    function batchUpdateNeuralWeights(
        address[] calldata assets,
        uint256[] calldata newRawSignals,
        uint256[] calldata smoothingFactors
    ) external onlyRole(AI_ADMIN_ROLE) whenNotPaused {
        uint256 len = assets.length;
        require(len == newRawSignals.length && len == smoothingFactors.length && len > 0, "Invalid arrays");
        uint64 timestamp = uint64(block.timestamp);
        for (uint256 i; i < len; ) {
            if (constituents[assets[i]].isActive) {
                _updateNeuralWeight(assets[i], newRawSignals[i], smoothingFactors[i], timestamp);
            }
            unchecked { i++; }
        }
    }

    function _updateNeuralWeight(address asset, uint256 newRawSignal, uint256 smoothingFactor, uint64 timestamp) internal {
        NeuralWeight storage w = assetNeuralWeights[asset];
        w.rawSignal = uint128(newRawSignal);
        if (w.lastUpdateTime == 0) {
            w.currentWeight = uint128(newRawSignal);
        } else {
            unchecked {
                w.currentWeight = uint128(
                    (newRawSignal * smoothingFactor + w.currentWeight * (MAX_EMA_SMOOTHING - smoothingFactor)) / MAX_EMA_SMOOTHING
                );
            }
        }
        w.lastUpdateTime = timestamp;
        w.emaSmoothingFactor = uint8(smoothingFactor);
        emit NeuralWeightUpdated(asset, w.currentWeight, newRawSignal, smoothingFactor);
        _updateDiversityIndex();
    }

    // Diversity Index Management
    function _updateDiversityIndex() internal {
        uint32 count = activeConstituentCount;
        if (count == 0) {
            diversityIndex = 0;
            emit DiversityIndexUpdated(0);
            return;
        }

        uint256 totalWeight;
        uint256 len = constituentList.length;
        uint256[] memory weights = new uint256[](len);
        for (uint256 i; i < len; ) {
            address asset = constituentList[i];
            if (constituents[asset].isActive) {
                weights[i] = assetNeuralWeights[asset].currentWeight;
                unchecked { totalWeight += weights[i]; }
            }
            unchecked { i++; }
        }

        if (totalWeight == 0) {
            diversityIndex = 0;
            emit DiversityIndexUpdated(0);
            return;
        }

        uint256 sumSquared;
        for (uint256 i; i < len; ) {
            if (weights[i] > 0 && constituents[constituentList[i]].isActive) {
                uint256 share = (WETH (weights[i] * 10000) / totalWeight;
                unchecked { sumSquared += share * share; }
            }
            unchecked { i++; }
        }
        diversityIndex = uint32(sumSquared);
        emit DiversityIndexUpdated(sumSquared);
    }

    function recalculateDiversityIndex() external onlyStakingOrAdmin whenNotPaused {
        _updateDiversityIndex();
    }

    // Chainlink Integration (Arbitrum-specific)
    function fetchLatestPrice(address asset) public returns (uint256) {
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

    function batchFetchLatestPrices(address[] calldata assets) external onlyRole(AI_ADMIN_ROLE) whenNotPaused {
        uint256 len = assets.length;
        require(len > 0, "Empty array");
        uint64 timestamp = uint64(block.timestamp);
        for (uint256 i; i < len; ) {
            if (constituents[assets[i]].isActive) {
                _fetchLatestPrice(assets[i], timestamp);
            }
            unchecked { i++; }
        }
    }

    function getLatestPrice(address asset) external view returns (uint256 price, bool isFresh) {
        AggregatorV3Interface feed = priceFeeds[asset];
        if (address(feed) == address(0)) return (0, false);
        (, int256 priceInt, , uint256 updatedAt, ) = feed.latestRoundData();
        price = priceInt > 0 ? uint256(priceInt) : 0;
        unchecked { isFresh = updatedAt > 0 && block.timestamp - updatedAt <= MAX_PRICE_STALENESS; }
    }

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
    function shouldAdaptiveRebalance() public view returns (bool, string memory) {
        unchecked {
            if (block.timestamp >= lastRebalanceTime + rebalanceInterval) return (true, "Time-based rebalance");
        }
        uint32 divIndex = diversityIndex;
        if (divIndex > MAX_DIVERSITY_INDEX) return (true, "Diversity too concentrated");
        if (divIndex < MIN_DIVERSITY_INDEX && divIndex > 0) return (true, "Diversity too dispersed");
        if (geneticVolatility > adaptiveVolatilityThreshold) return (true, "Volatility breach");
        return (false, "No rebalance needed");
    }

    function triggerAdaptiveRebalance() external onlyStakingOrAdmin nonReentrant whenNotPaused {
        (bool doRebalance, string memory reason) = shouldAdaptiveRebalance();
        require(doRebalance, "Rebalance not needed");
        lastRebalanceTime = uint64(block.timestamp);
        emit AdaptiveRebalanceTriggered(reason, block.timestamp);
    }

    function updateGeneticVolatility(uint256 newVolatility) external onlyRole(AI_ADMIN_ROLE) whenNotPaused {
        geneticVolatility = uint32(newVolatility);
        if (newVolatility > adaptiveVolatilityThreshold) {
            unchecked {
                if (block.timestamp >= lastRebalanceTime + (rebalanceInterval / 4)) {
                    lastRebalanceTime = uint64(block.timestamp);
                    emit AdaptiveRebalanceTriggered("Volatility breach", block.timestamp);
                }
            }
        }
    }

    // Chainlink Keeper Methods (Arbitrum-specific)
    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        if (paused()) return (false, "");

        (bool shouldRebalance, ) = shouldAdaptiveRebalance();
        uint256 len = constituentList.length;
        address[] memory assetsToUpdate = new address[](len);
        uint256 updateCount;

        for (uint256 i; i < len; ) {
            address asset = constituentList[i];
            if (constituents[asset].isActive) {
                (, , , uint256 updatedAt, ) = priceFeeds[asset].latestRoundData();
                unchecked {
                    if (updatedAt == 0 || block.timestamp - updatedAt > MAX_PRICE_STALENESS / 2) {
                        assetsToUpdate[updateCount] = asset;
                        updateCount++;
                    }
                }
            }
            unchecked { i++; }
        }

        upkeepNeeded = shouldRebalance || updateCount > 0;
        performData = abi.encode(shouldRebalance, updateCount > 0, updateCount, assetsToUpdate);
        return (upkeepNeeded, performData);
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

    function manualKeeper() external nonReentrant whenNotPaused {
        uint256 len = constituentList.length;
        uint64 timestamp = uint64(block.timestamp);
        for (uint256 i; i < len; ) {
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

    function batchSetConfig(ConfigUpdate[] calldata updates) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 len = updates.length;
        require(len > 0, "Empty array");
        for (uint256 i; i < len; ) {
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
    function approveOperation(bytes32 operationId) external onlyRole(AI_ADMIN_ROLE) {
        require(!hasApproved[operationId][msg.sender], "Already approved");
        hasApproved[operationId][msg.sender] = true;
        unchecked { operationApprovals[operationId]++; }
        emit OperationApproved(operationId, msg.sender, operationApprovals[operationId]);
    }

    function revokeApproval(bytes32 operationId) external {
        require(hasApproved[operationId][msg.sender], "Not approved");
        hasApproved[operationId][msg.sender] = false;
        unchecked { operationApprovals[operationId]--; }
        emit OperationApproved(operationId, msg.sender, operationApprovals[operationId]);
    }

    function scheduleOperation(bytes32 operationId) external onlyRole(AI_ADMIN_ROLE) {
        require(operationApprovals[operationId] >= requiredApprovals && operationScheduledTime[operationId] == 0, "Invalid operation");
        operationScheduledTime[operationId] = uint64(block.timestamp + operationTimelock);
        emit OperationScheduled(operationId, operationScheduledTime[operationId]);
    }

    function getOperationId(string calldata action, bytes calldata data) external view returns (bytes32) {
        return keccak256(abi.encode(action, data, block.timestamp));
    }

    // Emergency & Safety Controls
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function emergencyResetWeights() external nonReentrant {
        bytes32 opId = keccak256(abi.encode("emergencyResetWeights", block.timestamp));
        require(hasRole(EMERGENCY_ROLE, msg.sender) && operationApprovals[opId] >= requiredApprovals, "Insufficient approvals");
        delete operationApprovals[opId];

        uint256 len = constituentList.length;
        for (uint256 i; i < len; ) {
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