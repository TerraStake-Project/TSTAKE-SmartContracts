// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

interface ITerraStakeProjects {
    function updateProjectDataFromChainlink(uint256 projectId, int256 dataValue) external;
}

/**
 * @title ChainlinkDataFeeder
 * @notice Feeds data from Chainlink aggregators into the TerraStakeProjects contract,
 *         with extra features:
 *         - Storing last fed data and timestamp
 *         - Optional aggregator decimals tracking
 *         - Batch feeding
 *         - Configurable stale thresholds and feed manager roles
 *         - Round completeness check to ensure aggregator data is final
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

    // ------------------------------------------------------------------------
    // Structs
    // ------------------------------------------------------------------------
    /**
     * @dev Per-project data feed configuration
     * @param aggregator The Chainlink aggregator address
     * @param active Whether this feed is active for the project
     * @param decimals If you want to store aggregator decimals for on-chain scaling
     */
    struct DataFeed {
        address aggregator;
        bool active;
        uint8 decimals;
    }

    // ------------------------------------------------------------------------
    // State Variables
    // ------------------------------------------------------------------------
    // TerraStakeProjects contract to which we feed data
    address public terraStakeProjectsContract;

    // Per-project feed config: projectId -> DataFeed
    mapping(uint256 => DataFeed) public projectFeeds;

    // Last fed data for each project
    // lastDataValue[projectId] = the last int256 data fed
    // lastUpdateTimestamp[projectId] = block.timestamp when data was fed
    mapping(uint256 => int256) public lastDataValue;
    mapping(uint256 => uint256) public lastUpdateTimestamp;

    // If you also have aggregator-based price feeds for TSTAKE / USDC / ETH
    address public tStakeAggregator;
    address public usdcAggregator;
    address public ethAggregator;

    bool public tStakeFeedActive;
    bool public usdcFeedActive;
    bool public ethFeedActive;

    // If you want to store decimals for these global feeds
    uint8 public tStakeDecimals;
    uint8 public usdcDecimals;
    uint8 public ethDecimals;

    // Configurable threshold to treat data as stale (in seconds)
    uint256 public staleThreshold;

    // Roles
    bytes32 public constant FEED_MANAGER_ROLE = keccak256("FEED_MANAGER_ROLE");

    // ------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------
    /**
     * @dev Emitted when a project's data feed is updated
     */
    event DataFeedUpdated(uint256 indexed projectId, address indexed aggregator, bool active, uint8 decimals);

    /**
     * @dev Emitted when a base price feed (TSTAKE, USDC, ETH) is updated
     */
    event PriceFeedUpdated(string indexed feedType, address indexed aggregator, bool active, uint8 decimals);

    /**
     * @dev Emitted whenever data is fed into TerraStakeProjects
     */
    event DataFedToTerraStake(uint256 indexed projectId, int256 value, uint256 timestamp);

    /**
     * @dev Emitted when the stale threshold is updated
     */
    event StaleThresholdUpdated(uint256 newThreshold);

    // ------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------
    /**
     * @dev Sets up contract references and roles.
     * @param _terraStakeProjectsContract The TerraStakeProjects contract address
     * @param _tStakeAggregator Optional aggregator for TSTAKE
     * @param _usdcAggregator Optional aggregator for USDC
     * @param _ethAggregator Optional aggregator for ETH
     * @param _owner Admin who receives DEFAULT_ADMIN_ROLE and FEED_MANAGER_ROLE
     * @param _staleThreshold Max allowable time in seconds since aggregator's last update
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
        usdcAggregator   = _usdcAggregator;
        ethAggregator    = _ethAggregator;

        // Feeds are active if aggregator addresses are nonzero
        tStakeFeedActive = (tStakeAggregator != address(0));
        usdcFeedActive   = (usdcAggregator   != address(0));
        ethFeedActive    = (ethAggregator    != address(0));

        staleThreshold = _staleThreshold;

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(FEED_MANAGER_ROLE, _owner);
    }

    // ------------------------------------------------------------------------
    // Project-Specific Feeds
    // ------------------------------------------------------------------------
    /**
     * @notice Sets or updates a data feed for a given project
     * @param projectId The project ID in TerraStakeProjects
     * @param aggregator The Chainlink aggregator address
     * @param active Whether the feed is active
     * @param decimals If you want to store aggregator decimals for on-chain use
     */
    function setDataFeed(
        uint256 projectId, 
        address aggregator, 
        bool active, 
        uint8 decimals
    ) external onlyRole(FEED_MANAGER_ROLE) {
        if (aggregator == address(0)) revert InvalidAddress();
        projectFeeds[projectId] = DataFeed({
            aggregator: aggregator,
            active: active,
            decimals: decimals
        });

        emit DataFeedUpdated(projectId, aggregator, active, decimals);
    }

    /**
     * @notice Feeds the latest aggregator data to TerraStakeProjects for a single project
     * @param projectId The project ID for which we feed data
     */
    function feedDataToTerraStake(uint256 projectId) public nonReentrant {
        DataFeed memory feed = projectFeeds[projectId];
        if (feed.aggregator == address(0) || !feed.active) revert InvalidProjectId();

        // Retrieve fresh aggregator price
        int256 value = _getLatestPrice(feed.aggregator, true);
        uint256 timestamp = block.timestamp;

        // Feed data to TerraStakeProjects
        ITerraStakeProjects(terraStakeProjectsContract).updateProjectDataFromChainlink(projectId, value);

        // Store the last fed data
        lastDataValue[projectId] = value;
        lastUpdateTimestamp[projectId] = timestamp;

        emit DataFedToTerraStake(projectId, value, timestamp);
    }

    /**
     * @notice (Optional) Feed data in batch for multiple projects
     * @param projectIds An array of project IDs
     */
    function feedAllActiveProjectsData(uint256[] calldata projectIds) external nonReentrant {
        // Potentially large gas usage if many projects. Use with caution.
        for (uint256 i = 0; i < projectIds.length; ) {
            DataFeed memory feed = projectFeeds[projectIds[i]];
            if (feed.aggregator != address(0) && feed.active) {
                int256 value = _getLatestPrice(feed.aggregator, true);
                ITerraStakeProjects(terraStakeProjectsContract).updateProjectDataFromChainlink(projectIds[i], value);

                lastDataValue[projectIds[i]] = value;
                lastUpdateTimestamp[projectIds[i]] = block.timestamp;

                emit DataFedToTerraStake(projectIds[i], value, block.timestamp);
            }
            unchecked { ++i; }
        }
    }

    // ------------------------------------------------------------------------
    // TSTAKE, USDC, ETH Price Feeds
    // ------------------------------------------------------------------------
    /**
     * @notice Update one of the base price feeds (TSTAKE, USDC, ETH)
     * @param feedType The string "TSTAKE", "USDC", or "ETH"
     * @param aggregator The new aggregator address
     * @param active Whether this feed is active
     * @param decimals Optionally store aggregator decimals
     */
    function updatePriceFeed(
        string calldata feedType, 
        address aggregator, 
        bool active,
        uint8 decimals
    ) external onlyRole(FEED_MANAGER_ROLE) {
        if (keccak256(bytes(feedType)) == keccak256("TSTAKE")) {
            tStakeAggregator  = aggregator;
            tStakeFeedActive  = active;
            tStakeDecimals    = decimals;
        } else if (keccak256(bytes(feedType)) == keccak256("USDC")) {
            usdcAggregator    = aggregator;
            usdcFeedActive    = active;
            usdcDecimals      = decimals;
        } else if (keccak256(bytes(feedType)) == keccak256("ETH")) {
            ethAggregator     = aggregator;
            ethFeedActive     = active;
            ethDecimals       = decimals;
        } else {
            revert InvalidAddress();
        }
        emit PriceFeedUpdated(feedType, aggregator, active, decimals);
    }

    /**
     * @notice Convenience getter for TSTAKE aggregator price
     */
    function getTStakePrice() external view returns (int256) {
        return _getLatestPrice(tStakeAggregator, tStakeFeedActive);
    }

    /**
     * @notice Convenience getter for USDC aggregator price
     */
    function getUSDCPrice() external view returns (int256) {
        return _getLatestPrice(usdcAggregator, usdcFeedActive);
    }

    /**
     * @notice Convenience getter for ETH aggregator price
     */
    function getETHPrice() external view returns (int256) {
        return _getLatestPrice(ethAggregator, ethFeedActive);
    }

    // ------------------------------------------------------------------------
    // Stale Threshold & Admin
    // ------------------------------------------------------------------------
    /**
     * @notice Update the allowable data staleness threshold (in seconds)
     */
    function updateStaleThreshold(uint256 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        staleThreshold = newThreshold;
        emit StaleThresholdUpdated(newThreshold);
    }

    // ------------------------------------------------------------------------
    // Internal Helpers
    // ------------------------------------------------------------------------
    /**
     * @dev Fetches the latest aggregator price, reverts if inactive or stale
     *      Also checks aggregator round completeness using answeredInRound < roundId
     * @param aggregator The Chainlink aggregator address
     * @param active Whether feed is active
     */
    function _getLatestPrice(address aggregator, bool active) internal view returns (int256) {
        if (!active) revert FeedInactive();

        AggregatorV3Interface priceFeed = AggregatorV3Interface(aggregator);
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        if (answer <= 0) revert DataValueInvalid();
        if (block.timestamp - updatedAt >= staleThreshold) revert DataStale();

        // Round completeness check
        if (answeredInRound < roundId) {
            revert("Chainlink incomplete round");
        }

        return answer;
    }
}
