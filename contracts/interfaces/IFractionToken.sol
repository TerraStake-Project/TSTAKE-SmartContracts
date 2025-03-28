// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/automation/interfaces/KeeperCompatibleInterface.sol";
import "./ITerraStakeToken.sol";
import "./ITerraStakeProjects.sol";

interface IFractionToken is IERC20 {
    function burnAll(address account) external;
}

/**
 * @title ITerraStakeFractionManager
 * @dev Interface for the TerraStakeFractionManager contract
 */
interface ITerraStakeFractionManager is KeeperCompatibleInterface {
    // =====================================================
    // Structs
    // =====================================================
    struct FractionData {
        address tokenAddress;
        uint256 nftId;
        uint256 totalSupply;
        uint256 redemptionPrice;
        bool isActive;
        uint256 lockEndTime;
        address creator;
        uint256 creationTime;
        uint256 impactValue;
        ITerraStakeProjects.ProjectCategory category;
        bytes32 verificationHash;
        // New fields for project integration
        uint256 projectId;
        uint256 reportId;
    }

    struct FractionParams {
        uint256 tokenId;
        uint256 fractionSupply;
        uint256 initialPrice;
        string name;
        string symbol;
        uint256 lockPeriod;
        // New fields for project integration
        uint256 projectId;
        uint256 reportId;
    }

    struct FractionMarketData {
        uint256 totalValueLocked;
        uint256 totalActiveUsers;
        uint256 volumeTraded;
        uint256 lastTradePrice;
        uint256 lastTradeTime;
    }

    struct AggregateMetrics {
        uint256 totalMarketCap;
        uint256 totalTradingVolume;
        uint256 totalEnvironmentalImpact;
        uint256 totalActiveTokens;
        uint256 averageTokenPrice;
    }

    struct OracleConfig {
        address oracle;
        uint256 heartbeatPeriod;
        int256 minPrice;
        int256 maxPrice;
        bool active;
        uint256 lastUpdateTime;
        uint256 updateInterval;
    }

    struct TimelockConfig {
        uint256 duration;
        bool enabled;
    }

    // New struct for project-related fraction data
    struct ProjectFractionData {
        uint256 projectId;
        uint256 reportId;
        uint256 impactValue;
        address[] fractionTokens;
        uint256 totalFractionalized;
    }

    // =====================================================
    // Events
    // =====================================================
    event NFTFractionalized(
        uint256 indexed nftId, 
        address fractionToken, 
        uint256 totalSupply, 
        address creator,
        ITerraStakeProjects.ProjectCategory category,
        uint256 impactValue
    );

    event NFTRedeemed(
        uint256 indexed nftId, 
        address redeemer, 
        uint256 redemptionPrice
    );

    event FractionsBought(
        address indexed buyer, 
        address indexed fractionToken, 
        uint256 amount, 
        uint256 price
    );

    event FractionsSold(
        address indexed seller, 
        address indexed fractionToken, 
        uint256 amount, 
        uint256 price
    );

    event RedemptionOffered(
        uint256 indexed nftId, 
        address fractionToken, 
        uint256 price, 
        address offeror
    );

    event MarketDataUpdated(
        address indexed fractionToken,
        uint256 totalValueLocked,
        uint256 volumeTraded,
        uint256 lastTradePrice
    );

    event FeeDistributed(
        address indexed recipient,
        uint256 amount,
        string feeType
    );

    event GlobalStatsUpdated(
        uint256 totalMarketCap,
        uint256 totalTradingVolume,
        uint256 totalEnvironmentalImpact
    );
            
    event OracleConfigured(
        address indexed token,
        address indexed oracle,
        uint256 heartbeatPeriod,
        int256 minPrice,
        int256 maxPrice,
        uint256 updateInterval
    );
    
    event PriceUpdated(
        address indexed token,
        uint256 oldPrice,
        uint256 newPrice,
        address indexed oracle
    );
    
    event EmergencyActionExecuted(
        address indexed executor,
        bytes32 indexed actionId,
        string description
    );
    
    event TimelockConfigUpdated(
        uint256 newDuration,
        bool enabled
    );
    
    event KeeperConfigUpdated(
        uint256 updateInterval,
        bool enabled
    );

    // New events for project integration
    event ProjectLinked(
        address indexed fractionToken,
        uint256 indexed nftId,
        uint256 indexed projectId,
        uint256 reportId
    );
    
    event ImpactMetricsUpdated(
        address indexed fractionToken,
        uint256 oldImpactValue,
        uint256 newImpactValue
    );

    event ChainlinkDataRequested(
        address indexed fractionToken,
        bytes32 requestId
    );

    event ProjectsContractSet(
        address indexed projectsContract
    );


    // Errors
    error InvalidAddress();
    error NFTAlreadyFractionalized();
    error FractionalizationNotActive();
    error ProjectsContractNotSet();
    error InvalidProjectId();
    error InvalidFractionSupply();
    error InvalidLockPeriod();
    error InsufficientBalance();
    error NFTStillLocked();
    error NoRedemptionOffer();
    error TransferFailed();
    error ProposalAlreadyExists();
    error ProposalDoesNotExist();
    error ProposalAlreadyExecuted();
    error ProposalExpired();

    // =====================================================
    // Fractionalization Functions
    // =====================================================
    function fractionalizeNFT(FractionParams calldata params) external;
    function offerRedemption(address fractionToken, uint256 price) external;
    function redeemNFT(address fractionToken) external;
    function acceptRedemptionOffer(address fractionToken) external;
    function buyFractions(address fractionToken, uint256 amount) external;
    function sellFractions(address fractionToken, uint256 amount) external;
    function getTokenPrice(address fractionToken) external view returns (uint256);
    function getAggregateMetrics() external view returns (AggregateMetrics memory metrics);
    function getTotalFractionTokens() external view returns (uint256);
    function createFractionToken(
        uint256 nftId,
        string memory name,
        string memory symbol,
        uint256 fractionCount,
        uint256 lockPeriod
    ) external returns (address fractionToken);

    // =====================================================
    // New Project Integration Functions
    // =====================================================
    
    /**
     * @notice Sets the TerraStakeProjects contract address
     * @param projectsContract The projects contract address
     */
    function setProjectsContract(address projectsContract) external;
    
    /**
     * @notice Gets the TerraStakeProjects contract address
     * @return The projects contract address
     */
    function getProjectsContract() external view returns (address);
    
    /**
     * @notice Links an existing fractionalized NFT to a project
     * @param fractionToken The fraction token address
     * @param projectId The project ID
     * @param reportId The report ID
     */
    function linkFractionToProject(
        address fractionToken,
        uint256 projectId,
        uint256 reportId
    ) external;
    
    /**
     * @notice Gets all fractionalized tokens for a project
     * @param projectId The project ID
     * @return fractionTokens Array of fraction token addresses
     */
    function getProjectFractionTokens(uint256 projectId) 
        external 
        view 
        returns (address[] memory fractionTokens);
    
    /**
     * @notice Gets all fractionalized tokens for a specific impact report
     * @param projectId The project ID
     * @param reportId The report ID
     * @return fractionTokens Array of fraction token addresses
     */
    function getReportFractionTokens(uint256 projectId, uint256 reportId) 
        external 
        view 
        returns (address[] memory fractionTokens);
    
    /**
     * @notice Updates impact value for a fraction token using Chainlink data
     * @param fractionToken The fraction token address
     * @return success Whether the update was successful
     */
    function updateImpactValue(address fractionToken) external returns (bool success);
    
    /**
     * @notice Requests impact data update from Chainlink for a fraction token
     * @param fractionToken The fraction token address
     * @return requestId The Chainlink request ID
     */
    function requestImpactDataUpdate(address fractionToken) external returns (bytes32 requestId);
    
    /**
     * @notice Gets the project and report IDs for a fraction token
     * @param fractionToken The fraction token address
     * @return projectId The project ID
     * @return reportId The report ID
     */
    function getFractionProjectData(address fractionToken) 
        external 
        view 
        returns (uint256 projectId, uint256 reportId);
    
    /**
     * @notice Gets fraction data for a specific project
     * @param projectId The project ID
     * @return data The project fraction data
     */
    function getProjectFractionData(uint256 projectId) 
        external 
        view 
        returns (ProjectFractionData memory data);
    
    /**
     * @notice Fractionalizes an NFT with project data
     * @param params The fractionalization parameters including project data
     * @return fractionToken The created fraction token address
     */
    function fractionalizeProjectNFT(FractionParams calldata params) 
        external 
        returns (address fractionToken);

    // =====================================================
    // Oracle Functions
    // =====================================================
    function configureOracle(
        address token,
        address oracle,
        uint256 heartbeatPeriod,
        int256 minPrice,
        int256 maxPrice,
        uint256 updateInterval
    ) external;
    
    function updateTokenPrice(address token) external;

    // =====================================================
    // Governance Functions
    // =====================================================                   
    function setTimelockConfig(uint256 _duration, bool _enabled) external;
    
    function executeEmergencyAction(
        address target,
        bytes calldata data,
        string calldata description
    ) external returns (bool);
    
    // =====================================================
    // Fee Management
    // =====================================================
    function setFees(uint256 _fractionalizationFee, uint256 _tradingFeePercentage) external;
    function setFeeWallets(address _treasuryWallet, address _impactFundWallet) external;

    // =====================================================
    // Keeper Functions
    // =====================================================
    function setKeeperConfig(uint256 _updateInterval, bool _enabled) external;
    function checkUpkeep(bytes calldata checkData) 
        external 
        view 
        override 
        returns (bool upkeepNeeded, bytes memory performData);
    function performUpkeep(bytes calldata performData) external override;

    // =====================================================
    // Admin Functions
    // =====================================================
    function pause() external;
    function unpause() external;
}
