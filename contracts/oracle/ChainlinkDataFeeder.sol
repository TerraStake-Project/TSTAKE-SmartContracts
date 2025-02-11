// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ITerraStakeProjects {
    function updateProjectDataFromChainlink(uint256 projectId, int256 dataValue) external;
}

/**
 * @title ChainlinkDataFeeder
 * @notice Feeds data from Chainlink aggregators into TerraStakeProjects with features including:
 *         - Storing last fed data and timestamp.
 *         - Batch feeding with pagination.
 *         - Configurable stale thresholds and feed manager roles.
 *         - Round completeness check to ensure aggregator data is final.
 *         - Pull-based reward accumulation: On each successful data feed, a total of 10 TSTAKE
 *           is allocated (7 TSTAKE for the reporter and 3 TSTAKE for the treasury) to be claimed later.
 */
contract ChainlinkDataFeeder is AccessControl, ReentrancyGuard {
    // ------------------------------------------------------------------------
    // Custom Errors
    // ------------------------------------------------------------------------
    error InvalidAddress();
    error InvalidProjectId();
    error FeedInactive();
    error DataValueInvalid();
    error DataStale();
    error UnauthorizedAccess();
    error InsufficientRewardBalance();
    error RewardTransferFailed();

    // ------------------------------------------------------------------------
    // Structs
    // ------------------------------------------------------------------------
    /**
     * @dev Per-project data feed configuration.
     * Fields are ordered for optimal storage packing.
     * @param active Whether the feed is active.
     * @param decimals Aggregator decimals.
     * @param aggregator The Chainlink aggregator address.
     */
    struct DataFeed {
        bool active;
        uint8 decimals;
        address aggregator;
    }

    // ------------------------------------------------------------------------
    // State Variables
    // ------------------------------------------------------------------------
    /// @notice Address of the TerraStakeProjects contract.
    address public terraStakeProjectsContract;

    /// @notice Mapping of project ID to its data feed configuration.
    mapping(uint256 => DataFeed) public projectFeeds;

    /// @notice Mapping storing the last fed data value for each project.
    mapping(uint256 => int256) public lastDataValue;
    /// @notice Mapping storing the timestamp when data was last fed for each project.
    mapping(uint256 => uint256) public lastUpdateTimestamp;

    // Global price feed addresses (if needed)
    address public tStakeAggregator;
    address public usdcAggregator;
    address public ethAggregator;

    bool public tStakeFeedActive;
    bool public usdcFeedActive;
    bool public ethFeedActive;

    uint8 public tStakeDecimals;
    uint8 public usdcDecimals;
    uint8 public ethDecimals;

    /// @notice The maximum allowable staleness (in seconds) for aggregator data.
    uint256 public staleThreshold;

    // ------------------------------------------------------------------------
    // Reward Variables (Pull Pattern)
    // ------------------------------------------------------------------------
    /// @notice The ERC20 TSTAKE token used for rewarding data feeds.
    IERC20 public rewardToken;
    /// @notice Reward allocated to a reporter per successful feed: 7 TSTAKE (18 decimals).
    uint256 public constant reporterReward = 7 * 10 ** 18;
    /// @notice Reward allocated to the treasury per successful feed: 3 TSTAKE.
    uint256 public constant treasuryReward = 3 * 10 ** 18;
    /// @notice Total reward per feed: 10 TSTAKE.
    uint256 public constant totalReportReward = reporterReward + treasuryReward;

    /// @notice The treasury address to receive its portion of rewards.
    address public treasury;

    /// @notice Mapping to accumulate unclaimed reporter rewards.
    mapping(address => uint256) public reporterRewards;
    /// @notice Mapping to accumulate unclaimed treasury rewards.
    mapping(address => uint256) public treasuryRewards;

    // ------------------------------------------------------------------------
    // Roles
    // ------------------------------------------------------------------------
    bytes32 public constant FEED_MANAGER_ROLE = keccak256("FEED_MANAGER_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    // ------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------
    /// @notice Emitted when a project's data feed is updated.
    event DataFeedUpdated(uint256 indexed projectId, address indexed aggregator, bool active, uint8 decimals);
    /// @notice Emitted when a base price feed (TSTAKE, USDC, or ETH) is updated.
    event PriceFeedUpdated(string indexed feedType, address indexed aggregator, bool active, uint8 decimals);
    /// @notice Emitted when data is fed into TerraStakeProjects.
    event DataFedToTerraStake(uint256 indexed projectId, int256 value, uint256 timestamp);
    /// @notice Emitted when the stale threshold is updated.
    event StaleThresholdUpdated(uint256 newThreshold);
    /// @notice Emitted when a reward is claimed.
    /// @param claimant The address claiming the reward.
    /// @param amount The amount claimed.
    /// @param rewardType The type of reward ("Reporter" or "Treasury").
    event RewardClaimed(address indexed claimant, uint256 amount, string rewardType);
    /// @notice Emitted when rewards are allocated after a data feed.
    event RewardAllocated(address indexed reporter, uint256 reporterReward, uint256 treasuryReward);

    // ------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------
    /**
     * @notice Initializes the ChainlinkDataFeeder contract.
     * @param _terraStakeProjectsContract The TerraStakeProjects contract address.
     * @param _tStakeAggregator Optional aggregator for TSTAKE.
     * @param _usdcAggregator Optional aggregator for USDC.
     * @param _ethAggregator Optional aggregator for ETH.
     * @param _owner The admin address (receives DEFAULT_ADMIN_ROLE and FEED_MANAGER_ROLE).
     * @param _staleThreshold Maximum allowed staleness (in seconds) for data.
     */
    constructor(
        address _terraStakeProjectsContract,
        address _tStakeAggregator,
        address _usdcAggregator,
        address _ethAggregator,
        address _owner,
        uint256 _staleThreshold
    ) {
        if (_terraStakeProjectsContract == address(0)) revert InvalidAddress();
        if (_owner == address(0)) revert InvalidAddress();

        terraStakeProjectsContract = _terraStakeProjectsContract;
        tStakeAggregator = _tStakeAggregator;
        usdcAggregator = _usdcAggregator;
        ethAggregator = _ethAggregator;

        tStakeFeedActive = (tStakeAggregator != address(0));
        usdcFeedActive = (usdcAggregator != address(0));
        ethFeedActive = (ethAggregator != address(0));

        staleThreshold = _staleThreshold;

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(FEED_MANAGER_ROLE, _owner);
    }

    // ------------------------------------------------------------------------
    // Reward Token & Treasury Setters
    // ------------------------------------------------------------------------
    /**
     * @notice Sets the reward token (TSTAKE) contract address.
     * @param _rewardToken The TSTAKE token address.
     */
    function setRewardToken(address _rewardToken) external onlyRole(FEED_MANAGER_ROLE) {
        if (_rewardToken == address(0)) revert InvalidAddress();
        rewardToken = IERC20(_rewardToken);
    }

    /**
     * @notice Sets the treasury address that will receive its share of rewards and grants TREASURY_ROLE.
     * @param _treasury The treasury address.
     */
    function setTreasury(address _treasury) external onlyRole(FEED_MANAGER_ROLE) {
        if (_treasury == address(0)) revert InvalidAddress();
        treasury = _treasury;
        _grantRole(TREASURY_ROLE, _treasury);
    }

    // ------------------------------------------------------------------------
    // Project-Specific Feed Functions
    // ------------------------------------------------------------------------
    /**
     * @notice Sets or updates the data feed configuration for a specific project.
     * @param projectId The TerraStakeProjects project ID.
     * @param aggregator The Chainlink aggregator address.
     * @param active Whether the feed is active.
     * @param decimals Aggregator decimals for on-chain scaling.
     */
    function setDataFeed(
        uint256 projectId,
        address aggregator,
        bool active,
        uint8 decimals
    ) external onlyRole(FEED_MANAGER_ROLE) {
        if (aggregator == address(0)) revert InvalidAddress();
        projectFeeds[projectId] = DataFeed({
            active: active,
            decimals: decimals,
            aggregator: aggregator
        });
        emit DataFeedUpdated(projectId, aggregator, active, decimals);
    }

    /**
     * @notice Feeds the latest aggregator data for a single project and accumulates rewards.
     * @param projectId The project ID.
     */
    function feedDataToTerraStake(uint256 projectId) public nonReentrant {
        DataFeed memory feed = projectFeeds[projectId];
        if (feed.aggregator == address(0) || !feed.active) revert InvalidProjectId();

        // Check that TerraStakeProjects contract exists.
        address projects = terraStakeProjectsContract;
        require(projects != address(0), "TerraStakeProjects address not set");
        require(projects.code.length > 0, "TerraStakeProjects contract does not exist");

        int256 value = _getLatestPrice(feed.aggregator, true);
        uint256 timestamp = block.timestamp;

        ITerraStakeProjects(projects).updateProjectDataFromChainlink(projectId, value);
        lastDataValue[projectId] = value;
        lastUpdateTimestamp[projectId] = timestamp;

        emit DataFedToTerraStake(projectId, value, timestamp);

        // Instead of pushing rewards, we accumulate them (pull pattern)
        reporterRewards[msg.sender] += reporterReward;
        treasuryRewards[treasury] += treasuryReward;
        emit RewardAllocated(msg.sender, reporterReward, treasuryReward);
    }

    /**
     * @notice Feeds data for multiple projects in a paginated manner and accumulates rewards.
     * @param projectIds An array of project IDs.
     * @param start The starting index in the array.
     * @param count The number of projects to process.
     */
    function feedAllActiveProjectsData(uint256[] calldata projectIds, uint256 start, uint256 count) external nonReentrant {
        require(start < projectIds.length, "Start index out of bounds");
        uint256 end = start + count;
        if (end > projectIds.length) {
            end = projectIds.length;
        }
        for (uint256 i = start; i < end; ) {
            DataFeed memory feed = projectFeeds[projectIds[i]];
            if (feed.aggregator != address(0) && feed.active) {
                int256 value = _getLatestPrice(feed.aggregator, true);
                ITerraStakeProjects(terraStakeProjectsContract).updateProjectDataFromChainlink(projectIds[i], value);
                lastDataValue[projectIds[i]] = value;
                lastUpdateTimestamp[projectIds[i]] = block.timestamp;
                emit DataFedToTerraStake(projectIds[i], value, block.timestamp);

                // Accumulate rewards for the caller and treasury.
                reporterRewards[msg.sender] += reporterReward;
                treasuryRewards[treasury] += treasuryReward;
                emit RewardAllocated(msg.sender, reporterReward, treasuryReward);
            }
            unchecked { ++i; }
        }
    }

    // ------------------------------------------------------------------------
    // Price Feed Update Functions
    // ------------------------------------------------------------------------
    /**
     * @notice Updates a base price feed (TSTAKE, USDC, or ETH).
     * @param feedType The feed type ("TSTAKE", "USDC", or "ETH").
     * @param aggregator The new aggregator address.
     * @param active Whether the feed is active.
     * @param decimals Aggregator decimals.
     */
    function updatePriceFeed(
        string calldata feedType,
        address aggregator,
        bool active,
        uint8 decimals
    ) external onlyRole(FEED_MANAGER_ROLE) {
        if (keccak256(bytes(feedType)) == keccak256("TSTAKE")) {
            tStakeAggregator = aggregator;
            tStakeFeedActive = active;
            tStakeDecimals = decimals;
        } else if (keccak256(bytes(feedType)) == keccak256("USDC")) {
            usdcAggregator = aggregator;
            usdcFeedActive = active;
            usdcDecimals = decimals;
        } else if (keccak256(bytes(feedType)) == keccak256("ETH")) {
            ethAggregator = aggregator;
            ethFeedActive = active;
            ethDecimals = decimals;
        } else {
            revert InvalidAddress();
        }
        emit PriceFeedUpdated(feedType, aggregator, active, decimals);
    }

    /**
     * @notice Returns the current TSTAKE price.
     * @return price The latest TSTAKE price.
     */
    function getTStakePrice() external view returns (int256) {
        return _getLatestPrice(tStakeAggregator, tStakeFeedActive);
    }

    /**
     * @notice Returns the current USDC price.
     * @return price The latest USDC price.
     */
    function getUSDCPrice() external view returns (int256) {
        return _getLatestPrice(usdcAggregator, usdcFeedActive);
    }

    /**
     * @notice Returns the current ETH price.
     * @return price The latest ETH price.
     */
    function getETHPrice() external view returns (int256) {
        return _getLatestPrice(ethAggregator, ethFeedActive);
    }

    // ------------------------------------------------------------------------
    // Stale Threshold Administration
    // ------------------------------------------------------------------------
    /**
     * @notice Updates the data staleness threshold.
     * @param newThreshold The new threshold in seconds.
     */
    function updateStaleThreshold(uint256 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        staleThreshold = newThreshold;
        emit StaleThresholdUpdated(newThreshold);
    }

    // ------------------------------------------------------------------------
    // Reward Claim Functions (Pull Pattern)
    // ------------------------------------------------------------------------
    /**
     * @notice Allows a reporter to claim their accumulated reward.
     */
    function claimReporterReward() external nonReentrant {
        uint256 reward = reporterRewards[msg.sender];
        require(reward > 0, "No reporter reward to claim");
        reporterRewards[msg.sender] = 0;
        require(rewardToken.transfer(msg.sender, reward), "Reporter reward transfer failed");
        emit RewardClaimed(msg.sender, reward, "Reporter");
    }

    /**
     * @notice Allows the treasury to claim its accumulated reward.
     * @dev Only callable by an address with TREASURY_ROLE.
     */
    function claimTreasuryReward() external nonReentrant onlyRole(TREASURY_ROLE) {
        uint256 reward = treasuryRewards[msg.sender];
        require(reward > 0, "No treasury reward to claim");
        treasuryRewards[msg.sender] = 0;
        require(rewardToken.transfer(msg.sender, reward), "Treasury reward transfer failed");
        emit RewardClaimed(msg.sender, reward, "Treasury");
    }

    // ------------------------------------------------------------------------
    // Internal Helper Functions
    // ------------------------------------------------------------------------
    /**
     * @dev Fetches the latest price from a Chainlink aggregator.
     *      Reverts if the feed is inactive, stale, or incomplete.
     * @param aggregator The Chainlink aggregator address.
     * @param active Whether the feed is active.
     * @return answer The latest price.
     */
    function _getLatestPrice(address aggregator, bool active) internal view returns (int256) {
        if (!active) revert FeedInactive();

        AggregatorV3Interface priceFeed = AggregatorV3Interface(aggregator);

        // Check that the aggregator feed appears active.
        (uint80 latestRoundId, , , , ) = priceFeed.latestRoundData();
        if (latestRoundId == 0) revert FeedInactive();

        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
        if (answer <= 0) revert DataValueInvalid();
        if (block.timestamp - updatedAt >= staleThreshold) revert DataStale();
        if (answeredInRound < roundId) revert("Chainlink incomplete round");

        return answer;
    }
}