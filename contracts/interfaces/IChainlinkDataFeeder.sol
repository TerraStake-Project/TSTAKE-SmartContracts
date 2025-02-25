// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IChainlinkDataFeeder {
    // ------------------------------------------------------------------------
    // 🔹 Events for Transparency & Monitoring
    // ------------------------------------------------------------------------
    event DataUpdated(address indexed feed, int256 value, uint256 timestamp);
    event ProjectDataUpdated(uint256 indexed projectId, int256 value, uint256 timestamp);
    event FeedActivationUpdated(address indexed feed, bool active);
    event OracleChangeRequested(address indexed feed, uint256 unlockTime);
    event OracleChangeConfirmed(address indexed feed);
    event CircuitBreakerTriggered(address indexed feed, uint256 failureCount);
    event TWAPViolationDetected(int256 reportedPrice, int256 TWAP);
    event CrossChainDataValidated(address indexed feed, bytes32 crossChainId, bool valid);
    event PerformanceMetricsUpdated(address indexed feed, uint256 reliability, uint256 latency, uint256 deviation);
    event GovernanceStatusChecked(bool status);
    event PriceImpactValidated(address feed, bool isValid);

    // ------------------------------------------------------------------------
    // 🔹 Governance Roles for Access Control
    // ------------------------------------------------------------------------
    function DEFAULT_ADMIN_ROLE() external pure returns (bytes32);
    function DEVICE_MANAGER_ROLE() external pure returns (bytes32);
    function DATA_MANAGER_ROLE() external pure returns (bytes32);
    function GOVERNANCE_ROLE() external pure returns (bytes32);

    // ------------------------------------------------------------------------
    // 🔹 Oracle Data & Feeds Management
    // ------------------------------------------------------------------------
    function lastKnownPrice(address feed) external view returns (int256);
    function activeFeeds(address feed) external view returns (bool);
    function feedFailures(address feed) external view returns (uint256);
    function pendingOracleChanges(bytes32 requestId) external view returns (uint256);

    function terraStakeProjects() external view returns (address);
    function terraStakeToken() external view returns (address);
    function liquidityGuard() external view returns (address);

    function priceOracles(uint256 index) external view returns (address);
    function priceOraclesLength() external view returns (uint256);

    // ------------------------------------------------------------------------
    // 🔹 Oracle Data Analytics & Performance Tracking
    // ------------------------------------------------------------------------
    struct FeedAnalytics {
        uint256 updateCount;
        uint256 lastValidation;
        int256[] priceHistory;
        uint256 reliabilityScore;
    }

    function feedAnalytics(address feed) external view returns (
        uint256 updateCount,
        uint256 lastValidation,
        uint256 reliabilityScore
    );

    function getFeedPerformanceMetrics(address feed) external view returns (
        uint256 reliability,
        uint256 latency,
        uint256 deviation
    );

    // ------------------------------------------------------------------------
    // 🔹 Cross-Chain Data Validation
    // ------------------------------------------------------------------------
    function crossChainData(bytes32 crossChainId) external view returns (int256);
    function validateCrossChainData(address feed, bytes32 crossChainId) external returns (bool);

    // ------------------------------------------------------------------------
    // 🔹 Project Category Support
    // ------------------------------------------------------------------------
    enum ProjectCategory {
        RENEWABLES, 
        CARBON_CREDITS, 
        ESG_SCORING, 
        ENERGY_STORAGE, 
        WATER_MANAGEMENT
    }

    function setCategoryFeed(ProjectCategory category, address feed, bool active) external;
    function categoryFeeds(ProjectCategory category, address feed) external view returns (bool);
    function categoryThresholds(ProjectCategory category) external view returns (int256);
    function validateCategoryData(ProjectCategory category, int256 value) external view returns (bool);

    // ------------------------------------------------------------------------
    // 🔹 Initialization & Configuration
    // ------------------------------------------------------------------------
    function initializeFeeds(
        address _terraStakeProjects,
        address _terraStakeToken,
        address _liquidityGuard,
        address[] calldata _oracles
    ) external;

    // ------------------------------------------------------------------------
    // 🔹 Data Feeds Management & Oracle Updates
    // ------------------------------------------------------------------------
    function updateData(address feed) external;
    function updateProjectData(uint256 projectId) external;
    function toggleFeed(address feed, bool active) external;
    function getLatestPrice(address feed) external view returns (int256);
    function validateDataFeed(address feed) external returns (bool);

    // ------------------------------------------------------------------------
    // 🔹 Multi-Oracle TWAP Validation
    // ------------------------------------------------------------------------
    function validatePriceWithTWAP(address feed, int256 reportedPrice) external returns (bool);
    function calculateExtendedTWAP(address feed, uint256 period) external view returns (int256);

    // ------------------------------------------------------------------------
    // 🔹 Governance-Controlled Oracle Management (Timelock Protected)
    // ------------------------------------------------------------------------
    function requestOracleChange(address feed) external;
    function confirmOracleChange(address feed) external;

    // ------------------------------------------------------------------------
    // 🔹 Data Validation & Governance Integration
    // ------------------------------------------------------------------------
    function validateDataWithLiquidityGuard(int256 price) external view returns (bool);
    function checkGovernanceStatus() external view returns (bool);

    // ------------------------------------------------------------------------
    // 🔹 Data Validation & Chainlink Round Data
    // ------------------------------------------------------------------------
    function getFeedLatestRoundData(address feed) external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );

    // ------------------------------------------------------------------------
    // 🔹 Versioning & State Validation
    // ------------------------------------------------------------------------
    function getContractVersion() external pure returns (bytes32);
}
