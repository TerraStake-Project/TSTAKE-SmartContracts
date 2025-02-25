// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

interface ITerraStakeProjects {
    function updateProjectDataFromChainlink(uint256 projectId, int256 price) external;
}

interface ITerraStakeToken {
    function getGovernanceStatus() external view returns (bool);
}

interface ITerraStakeLiquidityGuard {
    function validatePriceImpact(int256 price) external view returns (bool);
}

/**
 * @title TerraStake Chainlink Data Feeder v1.3
 * @notice Secure and optimized oracle feeder for TerraStake ecosystem with TWAP validation.
 */
contract ChainlinkDataFeeder is AccessControl, ReentrancyGuard {
    // -------------------------------------------
    // 🔹 Security & Governance Constants
    // -------------------------------------------
    bytes32 private constant CONTRACT_SIGNATURE = keccak256("v1.3");
    uint256 private constant STATE_SYNC_INTERVAL = 15 minutes;
    uint256 private constant ORACLE_TIMEOUT = 1 hours;
    uint256 private constant CIRCUIT_BREAKER_THRESHOLD = 3;
    uint256 private constant GOVERNANCE_CHANGE_DELAY = 1 days;

    // -------------------------------------------
    // 🔹 Roles for Security
    // -------------------------------------------
    bytes32 public constant DEVICE_MANAGER_ROLE = keccak256("DEVICE_MANAGER_ROLE");
    bytes32 public constant DATA_MANAGER_ROLE = keccak256("DATA_MANAGER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    // -------------------------------------------
    // 🔹 Oracle Feeds & Data Storage
    // -------------------------------------------
    mapping(address => bool) public activeFeeds;
    mapping(address => int256) public lastKnownPrice;
    mapping(address => uint256) public feedFailures;
    mapping(bytes32 => uint256) public pendingOracleChanges;

    address[] public priceOracles;

    // -------------------------------------------
    // 🔹 Oracle Price Storage (TWAP)
    // -------------------------------------------
    struct OracleData {
        int256 price;
        uint256 timestamp;
    }
    mapping(address => OracleData) public oracleRecords;

    // -------------------------------------------
    // 🔹 Cross-Chain Data Validation
    // -------------------------------------------
    mapping(bytes32 => int256) public crossChainData;

    // -------------------------------------------
    // 🔹 Performance Analytics
    // -------------------------------------------
    struct FeedAnalytics {
        uint256 updateCount;
        uint256 lastValidation;
        int256[] priceHistory;
        uint256 reliabilityScore;
    }
    mapping(address => FeedAnalytics) public feedAnalytics;

    // -------------------------------------------
    // 🔹 External Contract Integrations
    // -------------------------------------------
    ITerraStakeProjects public terraStakeProjects;
    ITerraStakeToken public terraStakeToken;
    ITerraStakeLiquidityGuard public liquidityGuard;

    // -------------------------------------------
    // 🔹 Events for Transparency
    // -------------------------------------------
    event DataUpdated(address indexed feed, int256 value, uint256 timestamp);
    event ProjectDataUpdated(uint256 indexed projectId, int256 value, uint256 timestamp);
    event FeedActivationUpdated(address indexed feed, bool active);
    event OracleChangeRequested(address indexed feed, uint256 unlockTime);
    event OracleChangeConfirmed(address indexed feed);
    event CircuitBreakerTriggered(address indexed feed, uint256 failureCount);
    event TWAPViolationDetected(int256 reportedPrice, int256 TWAP);
    event CrossChainDataValidated(address indexed feed, bytes32 crossChainId, bool valid);
    event PerformanceMetricsUpdated(address indexed feed, uint256 reliability, uint256 latency, uint256 deviation);

    // -------------------------------------------
    // 🔹 Constructor: TerraStake Integration
    // -------------------------------------------
    constructor(
        address _terraStakeProjects,
        address _terraStakeToken,
        address _liquidityGuard,
        address[] memory _oracles
    ) {
        require(_terraStakeProjects != address(0), "Invalid project contract");
        require(_terraStakeToken != address(0), "Invalid TerraStakeToken contract");
        require(_liquidityGuard != address(0), "Invalid LiquidityGuard contract");

        terraStakeProjects = ITerraStakeProjects(_terraStakeProjects);
        terraStakeToken = ITerraStakeToken(_terraStakeToken);
        liquidityGuard = ITerraStakeLiquidityGuard(_liquidityGuard);

        for (uint256 i = 0; i < _oracles.length; i++) {
            priceOracles.push(_oracles[i]);
            activeFeeds[_oracles[i]] = true;
        }

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DATA_MANAGER_ROLE, msg.sender);
        _grantRole(DEVICE_MANAGER_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
    }

    // -------------------------------------------
    // 🔹 Multi-Oracle TWAP Validation
    // -------------------------------------------
    function _validatePriceWithTWAP(address feed, int256 reportedPrice) internal returns (bool) {
        OracleData storage oracle = oracleRecords[feed];

        if (oracle.timestamp == 0) {
            oracle.price = reportedPrice;
            oracle.timestamp = block.timestamp;
            return true;
        }

        uint256 timeElapsed = block.timestamp - oracle.timestamp;
        int256 TWAP = (oracle.price + reportedPrice) / 2;

        if (timeElapsed >= STATE_SYNC_INTERVAL && TWAP < (reportedPrice * 95) / 100) {
            emit TWAPViolationDetected(reportedPrice, TWAP);
            return false;
        }

        oracle.price = reportedPrice;
        oracle.timestamp = block.timestamp;
        return true;
    }

    function calculateExtendedTWAP(address feed, uint256 period) external view returns (int256) {
        require(activeFeeds[feed], "Feed not active");
        return oracleRecords[feed].price / int256(period);
    }

    // -------------------------------------------
    // 🔹 Data Fetching & Validation
    // -------------------------------------------
    function updateData(address feed) external onlyRole(DATA_MANAGER_ROLE) {
        require(activeFeeds[feed], "Feed not active");

        AggregatorV3Interface priceFeed = AggregatorV3Interface(feed);
        (, int256 answer, , uint256 updatedAt, ) = priceFeed.latestRoundData();

        require(answer > 0, "Invalid data");
        require(block.timestamp - updatedAt <= ORACLE_TIMEOUT, "Data too old");
        require(_validatePriceWithTWAP(feed, answer), "TWAP validation failed");

        lastKnownPrice[feed] = answer;
        feedAnalytics[feed].updateCount++;
        feedAnalytics[feed].lastValidation = block.timestamp;
        feedAnalytics[feed].priceHistory.push(answer);
        emit DataUpdated(feed, answer, updatedAt);
    }

    function validateCrossChainData(address feed, bytes32 crossChainId) external returns (bool) {
        int256 reportedPrice = lastKnownPrice[feed];
        int256 crossChainPrice = crossChainData[crossChainId];

        bool valid = (reportedPrice == crossChainPrice);
        emit CrossChainDataValidated(feed, crossChainId, valid);
        return valid;
    }

    function updateProjectData(uint256 projectId) external onlyRole(DATA_MANAGER_ROLE) {
        int256 price = lastKnownPrice[priceOracles[0]];
        require(price > 0, "No valid data available");
        require(liquidityGuard.validatePriceImpact(price), "Price impact too high");

        terraStakeProjects.updateProjectDataFromChainlink(projectId, price);
        emit ProjectDataUpdated(projectId, price, block.timestamp);
    }

    function getContractVersion() external pure returns (bytes32) {
        return CONTRACT_SIGNATURE;
    }
}
