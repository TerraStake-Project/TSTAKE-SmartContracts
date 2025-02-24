// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @dev This interface matches the final "ChainlinkDataFeeder" contract,
 *      including extra fields (like decimals) in DataFeed, the updated function names, 
 *      and the public variables/getters.
 */
interface IChainlinkDataFeeder {
    // -------------------------------------------------------
    // Struct
    // -------------------------------------------------------
    /**
     * @dev Per-project data feed configuration
     */
    struct DataFeed {
        address aggregator;
        bool active;
        uint8 decimals;
    }

    // -------------------------------------------------------
    // Events
    // -------------------------------------------------------
    event DataFeedUpdated(uint256 indexed projectId, address indexed aggregator, bool active, uint8 decimals);
    event DataFedToTerraStake(uint256 indexed projectId, int256 value, uint256 timestamp);
    event StaleThresholdUpdated(uint256 newThreshold);
    event PriceFeedUpdated(string indexed feedType, address indexed aggregator, bool active, uint8 decimals);

    // -------------------------------------------------------
    // Core Functions
    // -------------------------------------------------------
    /**
     * @notice Sets or updates a data feed for a given project.
     */
    function setDataFeed(
        uint256 projectId, 
        address aggregator, 
        bool active, 
        uint8 decimals
    ) external;

    /**
     * @notice Updates one of the base price feeds (TSTAKE, USDC, ETH).
     */
    function updatePriceFeed(
        string calldata feedType, 
        address aggregator, 
        bool active,
        uint8 decimals
    ) external;

    /**
     * @notice Feeds the latest aggregator data to TerraStakeProjects for a single project.
     */
    function feedDataToTerraStake(uint256 projectId) external;

    /**
     * @notice (Optional) Feeds data in batch for multiple projects.
     */
    function feedAllActiveProjectsData(uint256[] calldata projectIds) external;

    /**
     * @notice Update the allowable data staleness threshold (in seconds).
     */
    function updateStaleThreshold(uint256 newThreshold) external;

    // -------------------------------------------------------
    // View Functions
    // -------------------------------------------------------
    /**
     * @notice Returns the latest TSTAKE aggregator price.
     */
    function getTStakePrice() external view returns (int256);

    /**
     * @notice Returns the latest USDC aggregator price.
     */
    function getUSDCPrice() external view returns (int256);

    /**
     * @notice Returns the latest ETH aggregator price.
     */
    function getETHPrice() external view returns (int256);

    /**
     * @notice Public getters for last fed data (value) and timestamp.
     *         Since they are public mappings in the contract, 
     *         we expose the same function signatures here.
     */
    function lastDataValue(uint256 projectId) external view returns (int256);
    function lastUpdateTimestamp(uint256 projectId) external view returns (uint256);

    /**
     * @notice Returns the project feed details. 
     *         Matches the public `projectFeeds` mapping in the contract.
     */
    function projectFeeds(uint256 projectId) external view returns (
        address aggregator,
        bool active,
        uint8 decimals
    );
}
