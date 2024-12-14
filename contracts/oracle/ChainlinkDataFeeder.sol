// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ITerraStakeProjects {
    function updateProjectDataFromChainlink(uint256 projectId, int256 dataValue) external;
}

contract ChainlinkDataFeeder is AccessControl, ReentrancyGuard {
    // Custom Errors
    error InvalidAddress();
    error UnauthorizedAccess();
    error FeedAlreadyInactive();
    error InvalidProjectId();
    error FeedInactive();
    error DataValueInvalid();
    error DataStale();

    // Struct for managing feeds and configurations
    struct DataFeed {
        address aggregator;
        bool active;
    }

    // Reference to the TerraStakeProjects contract
    address public terraStakeProjectsContract;

    // Mapping to manage project-specific data feeds
    mapping(uint256 => DataFeed) public projectFeeds;
    mapping(uint256 => uint256) public lastUpdateTimestamp;

    // Roles
    bytes32 public constant FEED_MANAGER_ROLE = keccak256("FEED_MANAGER_ROLE");

    // Configurable stale threshold
    uint256 public staleThreshold;

    // Events for logging feed updates and data feeds to TerraStakeProjects
    event DataFeedUpdated(uint256 indexed projectId, address indexed aggregator, bool active);
    event DataFedToTerraStake(uint256 indexed projectId, int256 value, uint256 timestamp);
    event DataFeedAutoDeactivated(uint256 indexed projectId, uint256 timestamp);

    // Modifier to validate project existence
    modifier validProject(uint256 projectId) {
        if (projectFeeds[projectId].aggregator == address(0)) revert InvalidProjectId();
        if (!projectFeeds[projectId].active) revert FeedInactive();
        _;
    }

    constructor(
        address _terraStakeProjectsContract,
        address _owner,
        uint256 _staleThreshold
    ) {
        if (_terraStakeProjectsContract == address(0)) revert InvalidAddress();
        if (_owner == address(0)) revert InvalidAddress();

        terraStakeProjectsContract = _terraStakeProjectsContract;
        staleThreshold = _staleThreshold;

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(FEED_MANAGER_ROLE, _owner);
    }

    function setDataFeed(uint256 projectId, address aggregator, bool active) external onlyRole(FEED_MANAGER_ROLE) {
        if (aggregator == address(0)) revert InvalidAddress();

        projectFeeds[projectId] = DataFeed({
            aggregator: aggregator,
            active: active
        });

        emit DataFeedUpdated(projectId, aggregator, active);
    }

    function deactivateFeed(uint256 projectId) external onlyRole(FEED_MANAGER_ROLE) {
        if (!projectFeeds[projectId].active) revert FeedAlreadyInactive();
        projectFeeds[projectId].active = false;

        emit DataFeedUpdated(projectId, projectFeeds[projectId].aggregator, false);
    }

    function getLatestData(uint256 projectId) public view validProject(projectId) returns (int256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(projectFeeds[projectId].aggregator);
        (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();

        if (price <= 0) revert DataValueInvalid();
        if (block.timestamp - updatedAt >= staleThreshold) revert DataStale();

        return price;
    }

    function feedDataToTerraStake(uint256 projectId) public validProject(projectId) nonReentrant {
        int256 value = getLatestData(projectId);
        uint256 timestamp = block.timestamp;

        ITerraStakeProjects(terraStakeProjectsContract).updateProjectDataFromChainlink(projectId, value);
        lastUpdateTimestamp[projectId] = timestamp;

        emit DataFedToTerraStake(projectId, value, timestamp);
    }

    function batchFeedDataToTerraStake(uint256[] calldata projectIds) external nonReentrant {
        for (uint256 i = 0; i < projectIds.length; i++) {
            feedDataToTerraStake(projectIds[i]);
        }
    }

    function setTerraStakeContract(address _terraStakeProjectsContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_terraStakeProjectsContract == address(0)) revert InvalidAddress();
        terraStakeProjectsContract = _terraStakeProjectsContract;
    }

    function getFeedDetails(uint256 projectId) external view returns (address aggregator, bool active) {
        DataFeed memory feed = projectFeeds[projectId];
        return (feed.aggregator, feed.active);
    }

    function checkFeedHealth(uint256 projectId) public view returns (bool) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(projectFeeds[projectId].aggregator);
        (, , , uint256 updatedAt, ) = priceFeed.latestRoundData();
        return block.timestamp - updatedAt < staleThreshold;
    }

    function getLastUpdateTime(uint256 projectId) external view returns (uint256) {
        return lastUpdateTimestamp[projectId];
    }

    function batchCheckFeedHealth(uint256[] calldata projectIds) external view returns (bool[] memory) {
        bool[] memory health = new bool[](projectIds.length);
        for (uint256 i = 0; i < projectIds.length; i++) {
            AggregatorV3Interface priceFeed = AggregatorV3Interface(projectFeeds[projectIds[i]].aggregator);
            (, , , uint256 updatedAt, ) = priceFeed.latestRoundData();
            health[i] = block.timestamp - updatedAt < staleThreshold;
        }
        return health;
    }

    function autoDeactivateFeed(uint256 projectId) external {
        if (!checkFeedHealth(projectId)) {
            projectFeeds[projectId].active = false;
            emit DataFeedAutoDeactivated(projectId, block.timestamp);
        }
    }

    function updateStaleThreshold(uint256 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        staleThreshold = newThreshold;
    }
}
