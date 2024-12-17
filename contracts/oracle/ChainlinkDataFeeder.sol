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
    bytes32 public constant REWARD_MANAGER_ROLE = keccak256("REWARD_MANAGER_ROLE");

    // Configurable stale threshold
    uint256 public staleThreshold;

    // Events
    event DataFeedUpdated(uint256 indexed projectId, address indexed aggregator, bool active);
    event DataFedToTerraStake(uint256 indexed projectId, int256 value, uint256 timestamp);
    event DataFeedAutoDeactivated(uint256 indexed projectId, uint256 timestamp);
    event FeedBatchDeactivated(uint256[] projectIds, uint256 timestamp);
    event FeedBatchReactivate(uint256[] projectIds, uint256 timestamp);
    event StaleThresholdUpdated(uint256 newThreshold);

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
        _grantRole(REWARD_MANAGER_ROLE, _owner);
    }

    // Set or update a data feed
    function setDataFeed(uint256 projectId, address aggregator, bool active) external onlyRole(FEED_MANAGER_ROLE) {
        if (aggregator == address(0)) revert InvalidAddress();

        projectFeeds[projectId] = DataFeed({
            aggregator: aggregator,
            active: active
        });

        emit DataFeedUpdated(projectId, aggregator, active);
    }

    // Deactivate an individual feed
    function deactivateFeed(uint256 projectId) external onlyRole(FEED_MANAGER_ROLE) {
        if (!projectFeeds[projectId].active) revert FeedAlreadyInactive();
        projectFeeds[projectId].active = false;

        emit DataFeedUpdated(projectId, projectFeeds[projectId].aggregator, false);
    }

    // Feed latest data to TerraStakeProjects contract
    function feedDataToTerraStake(uint256 projectId) public validProject(projectId) nonReentrant {
        int256 value = getLatestData(projectId);
        uint256 timestamp = block.timestamp;

        ITerraStakeProjects(terraStakeProjectsContract).updateProjectDataFromChainlink(projectId, value);
        lastUpdateTimestamp[projectId] = timestamp;

        emit DataFedToTerraStake(projectId, value, timestamp);
    }

    // Batch feed data to multiple projects
    function batchFeedDataToTerraStake(uint256[] calldata projectIds) external nonReentrant {
        for (uint256 i = 0; i < projectIds.length; i++) {
            feedDataToTerraStake(projectIds[i]);
        }
    }

    // Validate data fetched from Chainlink
    function validateData(uint256 projectId, int256 expectedValue) external view validProject(projectId) returns (bool) {
        int256 value = getLatestData(projectId);
        return value == expectedValue;
    }

    // Automatically deactivate unhealthy feeds
    function autoBatchDeactivateFeeds(uint256[] calldata projectIds) external onlyRole(FEED_MANAGER_ROLE) {
        for (uint256 i = 0; i < projectIds.length; i++) {
            if (!checkFeedHealth(projectIds[i])) {
                projectFeeds[projectIds[i]].active = false;
                emit DataFeedAutoDeactivated(projectIds[i], block.timestamp);
            }
        }
        emit FeedBatchDeactivated(projectIds, block.timestamp);
    }

    // Manually reactivate inactive feeds
    function manualRecoverInactiveFeeds(uint256[] calldata projectIds) external onlyRole(FEED_MANAGER_ROLE) {
        for (uint256 i = 0; i < projectIds.length; i++) {
            if (!projectFeeds[projectIds[i]].active) {
                projectFeeds[projectIds[i]].active = true;
            }
        }
        emit FeedBatchReactivate(projectIds, block.timestamp);
    }

    // Update stale threshold
    function updateStaleThreshold(uint256 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        staleThreshold = newThreshold;
        emit StaleThresholdUpdated(newThreshold);
    }

    // Fetch the latest data for a project
    function getLatestData(uint256 projectId) public view validProject(projectId) returns (int256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(projectFeeds[projectId].aggregator);
        (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();

        if (price <= 0) revert DataValueInvalid();
        if (block.timestamp - updatedAt >= staleThreshold) revert DataStale();

        return price;
    }

    // Check the health of a specific feed
    function checkFeedHealth(uint256 projectId) public view returns (bool) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(projectFeeds[projectId].aggregator);
        (, , , uint256 updatedAt, ) = priceFeed.latestRoundData();
        return block.timestamp - updatedAt < staleThreshold;
    }
}