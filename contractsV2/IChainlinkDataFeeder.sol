// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IChainlinkDataFeeder {
    // Struct
    struct DataFeed {
        address aggregator;
        bool active;
    }

    // Events
    event DataFeedUpdated(uint256 indexed projectId, address indexed aggregator, bool active);
    event DataFedToTerraStake(uint256 indexed projectId, int256 value, uint256 timestamp);
    event DataFeedAutoDeactivated(uint256 indexed projectId, uint256 timestamp);
    event FeedBatchDeactivated(uint256[] projectIds, uint256 timestamp);
    event FeedBatchReactivate(uint256[] projectIds, uint256 timestamp);
    event StaleThresholdUpdated(uint256 newThreshold);

    // Core Functions
    function setDataFeed(uint256 projectId, address aggregator, bool active) external;

    function deactivateFeed(uint256 projectId) external;

    function feedDataToTerraStake(uint256 projectId) external;

    function batchFeedDataToTerraStake(uint256[] calldata projectIds) external;

    function validateData(uint256 projectId, int256 expectedValue) external view returns (bool);

    function autoBatchDeactivateFeeds(uint256[] calldata projectIds) external;

    function manualRecoverInactiveFeeds(uint256[] calldata projectIds) external;

    function updateStaleThreshold(uint256 newThreshold) external;

    // View Functions
    function getLatestData(uint256 projectId) external view returns (int256);

    function checkFeedHealth(uint256 projectId) external view returns (bool);

    function getFeedDetails(uint256 projectId) external view returns (address aggregator, bool active);

    function getLastUpdateTime(uint256 projectId) external view returns (uint256);
}
