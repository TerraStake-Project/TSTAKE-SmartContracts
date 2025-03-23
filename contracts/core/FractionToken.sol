// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;


import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";
import "@chainlink/contracts/src/v0.8/automation/interfaces/KeeperCompatibleInterface.sol";
import "../interfaces/ITerraStakeNFT.sol";
import "../interfaces/ITerraStakeToken.sol";
import "../interfaces/ITerraStakeProjects.sol";
import "../interfaces/IFractionToken.sol";


/**
 * @title FractionToken
 * @dev ERC20 token representing fractions of a TerraStake NFT
 */
contract FractionToken is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PermitUpgradeable,
    AccessControlEnumerableUpgradeable,
    UUPSUpgradeable
{
    string public _name;
    string public _symbol;
    uint256 public nftId;
    address public fractionManager;
    uint256 public impactValue;
    ITerraStakeProjects.ProjectCategory public projectCategory;
    bytes32 public projectDataHash;


    function initialize(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        uint256 _nftId,
        address _fractionManager,
        uint256 _impactValue,
        ITerraStakeProjects.ProjectCategory _projectCategory,
        bytes32 _projectDataHash
    ) public initializer {
        __ERC20_init(name, symbol);
        __ERC20Burnable_init();
        __ERC20Permit_init(name);
        __AccessControlEnumerable_init();
        __UUPSUpgradeable_init();
        
        _name = name;
        _symbol = symbol;
        nftId = _nftId;
        fractionManager = _fractionManager;
        impactValue = _impactValue;
        projectCategory = _projectCategory;
        projectDataHash = _projectDataHash;
        _mint(_fractionManager, initialSupply);
    }


    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}


    function burnAll(address account) public {
        uint256 balance = balanceOf(account);
        require(balance > 0, "No tokens to burn");
        _burn(account, balance);
    }


    function updateName(string memory newName) external {
        require(msg.sender == fractionManager, "Only fraction manager can update");
        _name = newName;
    }
    
    function updateSymbol(string memory newSymbol) external {
        require(msg.sender == fractionManager, "Only fraction manager can update");
        _symbol = newSymbol;
    }
}


/**
 * @title TerraStakeFractionManager
 * @dev Complete contract for fractionalizing TerraStake NFTs with project integration, governance, and keeper functionality
 */
contract TerraStakeFractionManager is
    Initializable,
    ERC1155HolderUpgradeable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ChainlinkClient,
    KeeperCompatibleInterface
{
    using ECDSA for bytes32;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;


    // Roles
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant FRACTIONALIZER_ROLE = keccak256("FRACTIONALIZER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");


    // Immutable state variables
    ITerraStakeNFT public terraStakeNFT;
    ITerraStakeToken public tStakeToken;


    // Project-related state variables
    address public projectsContract;
    mapping(uint256 => ProjectFractionData) private projectFractionData;
    mapping(uint256 => mapping(uint256 => EnumerableSet.AddressSet)) private reportFractionTokens;


    // Chainlink configuration
    address private chainlinkOracle;
    bytes32 private chainlinkJobId;
    uint256 private chainlinkFee;
    mapping(bytes32 => address) private requestToFractionToken;


    // Constants
    uint256 public constant MAX_FRACTION_SUPPLY = 1e27;
    uint256 public constant MIN_LOCK_PERIOD = 1 days;
    uint256 public constant MAX_LOCK_PERIOD = 365 days;
    uint256 public constant BASIS_POINTS = 10000;


    // Fractionalization Structs
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
    }


    struct FractionMarketData {
        uint256 totalValueLocked;
        uint256 totalActiveUsers;
        uint256 volumeTraded;
        uint256 lastTradePrice;
        uint256 lastTradeTime;
    }


    struct ProjectFractionData {
        uint256 projectId;
        uint256 totalFractions;
        uint256 totalImpactValue;
        address[] fractionTokens;
    }


    struct AggregateMetrics {
        uint256 totalMarketCap;
        uint256 totalTradingVolume;
        uint256 totalEnvironmentalImpact;
        uint256 totalActiveTokens;
        uint256 averageTokenPrice;
    }


    // Governance Structs
    struct Proposal {
        bytes32 proposalHash;
        uint256 proposedTime;
        uint256 requiredThreshold;
        bool executed;
        bool isEmergency;
        address creator;
        uint256 executionTime;
        address[] approvers;
    }


    // State variables
    mapping(address => FractionData) public fractionData;
    mapping(uint256 => address) public nftToFractionToken;
    mapping(address => FractionMarketData) public marketData;
    mapping(address => uint256) public redemptionOffers;
    mapping(address => address) public redemptionOfferors;
    EnumerableSet.AddressSet private allFractionTokens;
    uint256 public totalVolumeTraded;
    uint256 public fractionalizationFee;
    uint256 public tradingFeePercentage;
    address public treasuryWallet;


    mapping(bytes32 => Proposal) private proposals;
    EnumerableSet.Bytes32Set private allProposals;
    uint256 public governanceThreshold;
    uint256 public proposalExpiryTime;


    // Keeper state
    uint256 public lastKeeperUpdate;
    uint256 public keeperUpdateInterval;


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


    // Events
    event NFTFractionalized(uint256 indexed nftId, address fractionToken, uint256 totalSupply, address creator, ITerraStakeProjects.ProjectCategory category, uint256 impactValue);
    event ProjectLinked(address indexed fractionToken, uint256 indexed nftId, uint256 indexed projectId, uint256 reportId);
    event ImpactMetricsUpdated(address indexed fractionToken, uint256 oldImpactValue, uint256 newImpactValue);
    event ChainlinkDataRequested(address indexed fractionToken, bytes32 requestId);
    event ProjectsContractSet(address indexed projectsContract);
    event NFTRedeemed(uint256 indexed nftId, address redeemer, uint256 redemptionPrice);
    event RedemptionOffered(uint256 indexed nftId, address fractionToken, uint256 price, address offeror);
    event FractionsBought(address indexed buyer, address indexed fractionToken, uint256 amount, uint256 price);
    event FractionsSold(address indexed seller, address indexed fractionToken, uint256 amount, uint256 price);
    event ProposalCreated(bytes32 indexed proposalId, address indexed proposer, bool isEmergency, bytes data);
    event ProposalApproved(bytes32 indexed proposalId, address indexed approver);
    event ProposalExecuted(bytes32 indexed proposalId, address indexed executor, bool success);


    function initialize(
        address _terraStakeNFT,
        address _tStakeToken,
        address _treasuryWallet,
        address _chainlinkOracle,
        bytes32 _chainlinkJobId,
        uint256 _chainlinkFee
    ) public initializer {
        __ERC1155Holder_init();
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        setChainlinkToken(0xf97f4df751bB47c5295e33eD52c685D68d714C09); // LINK token on Arbitrum


        if (_terraStakeNFT == address(0) || _tStakeToken == address(0) || _treasuryWallet == address(0)) {
            revert InvalidAddress();
        }


        terraStakeNFT = ITerraStakeNFT(_terraStakeNFT);
        tStakeToken = ITerraStakeToken(_tStakeToken);
        treasuryWallet = _treasuryWallet;
        chainlinkOracle = _chainlinkOracle;
        chainlinkJobId = _chainlinkJobId;
        chainlinkFee = _chainlinkFee;


        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(VERIFIER_ROLE, msg.sender);
        _grantRole(FRACTIONALIZER_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(FEE_MANAGER_ROLE, msg.sender);


        fractionalizationFee = 100 ether;
        tradingFeePercentage = 200; // 2%
        governanceThreshold = 3;
        proposalExpiryTime = 7 days;
        keeperUpdateInterval = 1 days;
    }


    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}


    // Core Functions
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }


    function unpause() external onlyRole(GOVERNANCE_ROLE) {
        _unpause();
    }


    function offerRedemption(address fractionToken, uint256 price) external nonReentrant whenNotPaused {
        FractionData storage data = fractionData[fractionToken];
        if (!data.isActive) revert FractionalizationNotActive();
        if (!tStakeToken.transferFrom(msg.sender, address(this), price)) revert TransferFailed();


        redemptionOffers[fractionToken] = price;
        redemptionOfferors[fractionToken] = msg.sender;
        emit RedemptionOffered(data.nftId, fractionToken, price, msg.sender);
    }


    function redeemNFT(address fractionToken) external nonReentrant whenNotPaused {
        FractionData storage data = fractionData[fractionToken];
        if (!data.isActive) revert FractionalizationNotActive();
        if (block.timestamp < data.lockEndTime) revert NFTStillLocked();
        if (IFractionToken(fractionToken).balanceOf(msg.sender) < data.totalSupply) revert InsufficientBalance();


        IFractionToken(fractionToken).burnAll(msg.sender);
        terraStakeNFT.safeTransferFrom(address(this), msg.sender, data.nftId, 1, "");
        data.isActive = false;
        allFractionTokens.remove(fractionToken);


        emit NFTRedeemed(data.nftId, msg.sender, data.redemptionPrice);
    }


    function acceptRedemptionOffer(address fractionToken) external nonReentrant whenNotPaused {
        FractionData storage data = fractionData[fractionToken];
        if (!data.isActive) revert FractionalizationNotActive();
        if (redemptionOffers[fractionToken] == 0) revert NoRedemptionOffer();
        if (IFractionToken(fractionToken).balanceOf(msg.sender) < data.totalSupply) revert InsufficientBalance();


        uint256 price = redemptionOffers[fractionToken];
        address offeror = redemptionOfferors[fractionToken];
        IFractionToken(fractionToken).burnAll(msg.sender);
        if (!tStakeToken.transfer(msg.sender, price)) revert TransferFailed();


        terraStakeNFT.safeTransferFrom(address(this), offeror, data.nftId, 1, "");
        data.isActive = false;
        allFractionTokens.remove(fractionToken);
        delete redemptionOffers[fractionToken];
        delete redemptionOfferors[fractionToken];


        emit NFTRedeemed(data.nftId, offeror, price);
    }


    function buyFractions(address fractionToken, uint256 amount) external nonReentrant whenNotPaused {
        FractionData storage data = fractionData[fractionToken];
        if (!data.isActive) revert FractionalizationNotActive();
        uint256 price = getTokenPrice(fractionToken);
        uint256 totalCost = (price * amount) / 1e18;
        uint256 fee = (totalCost * tradingFeePercentage) / BASIS_POINTS;
        if (!tStakeToken.transferFrom(msg.sender, address(this), totalCost + fee)) revert TransferFailed();
        if (!tStakeToken.transfer(treasuryWallet, fee)) revert TransferFailed();


        IFractionToken(fractionToken).transfer(msg.sender, amount);
        marketData[fractionToken].volumeTraded += totalCost;
        marketData[fractionToken].lastTradePrice = price;
        marketData[fractionToken].lastTradeTime = block.timestamp;
        totalVolumeTraded += totalCost;


        emit FractionsBought(msg.sender, fractionToken, amount, totalCost);
    }


    function sellFractions(address fractionToken, uint256 amount) external nonReentrant whenNotPaused {
        FractionData storage data = fractionData[fractionToken];
        if (!data.isActive) revert FractionalizationNotActive();
        if (IFractionToken(fractionToken).balanceOf(msg.sender) < amount) revert InsufficientBalance();


        uint256 price = getTokenPrice(fractionToken);
        uint256 totalValue = (price * amount) / 1e18;
        uint256 fee = (totalValue * tradingFeePercentage) / BASIS_POINTS;
        uint256 payout = totalValue - fee;


        IFractionToken(fractionToken).transferFrom(msg.sender, address(this), amount);
        if (!tStakeToken.transfer(msg.sender, payout)) revert TransferFailed();
        if (!tStakeToken.transfer(treasuryWallet, fee)) revert TransferFailed();


        marketData[fractionToken].volumeTraded += totalValue;
        marketData[fractionToken].lastTradePrice = price;
        marketData[fractionToken].lastTradeTime = block.timestamp;
        totalVolumeTraded += totalValue;


        emit FractionsSold(msg.sender, fractionToken, amount, totalValue);
    }


    function getTokenPrice(address fractionToken) public view returns (uint256) {
        FractionData storage data = fractionData[fractionToken];
        if (!data.isActive) return 0;
        return data.redemptionPrice / data.totalSupply; // Simplified pricing
    }


    function getAggregateMetrics() external view returns (AggregateMetrics memory metrics) {
        uint256 totalMarketCap = 0;
        uint256 totalEnvironmentalImpact = 0;
        uint256 totalActiveTokens = allFractionTokens.length();
        uint256 averageTokenPrice = 0;


        for (uint256 i = 0; i < totalActiveTokens; i++) {
            address token = allFractionTokens.at(i);
            FractionData storage data = fractionData[token];
            uint256 price = getTokenPrice(token);
            totalMarketCap += price * data.totalSupply;
            totalEnvironmentalImpact += data.impactValue;
            averageTokenPrice += price;
        }


        if (totalActiveTokens > 0) {
            averageTokenPrice /= totalActiveTokens;
        }


        metrics = AggregateMetrics({
            totalMarketCap: totalMarketCap,
            totalTradingVolume: totalVolumeTraded,
            totalEnvironmentalImpact: totalEnvironmentalImpact,
            totalActiveTokens: totalActiveTokens,
            averageTokenPrice: averageTokenPrice
        });
    }


    function getTotalFractionTokens() external view returns (uint256) {
        return allFractionTokens.length();
    }


    // Project Integration Functions
    function setProjectsContract(address _projectsContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_projectsContract == address(0)) revert InvalidAddress();
        projectsContract = _projectsContract;
        emit ProjectsContractSet(_projectsContract);
    }


    function getProjectsContract() external view returns (address) {
        return projectsContract;
    }


    function linkFractionToProject(address fractionToken, uint256 projectId, uint256 reportId) external onlyRole(FRACTIONALIZER_ROLE) {
        if (projectsContract == address(0)) revert ProjectsContractNotSet();
        if (!ITerraStakeProjects(projectsContract).projectExists(projectId)) revert InvalidProjectId();


        FractionData storage data = fractionData[fractionToken];
        if (data.tokenAddress != fractionToken) revert FractionalizationNotActive();


        data.projectId = projectId;
        data.reportId = reportId;


        ProjectFractionData storage pfd = projectFractionData[projectId];
        pfd.projectId = projectId;
        pfd.totalFractions += data.totalSupply;
        pfd.totalImpactValue += data.impactValue;
        pfd.fractionTokens.push(fractionToken);


        reportFractionTokens[projectId][reportId].add(fractionToken);


        emit ProjectLinked(fractionToken, data.nftId, projectId, reportId);
    }


    function getProjectFractionTokens(uint256 projectId) external view returns (address[] memory) {
        return projectFractionData[projectId].fractionTokens;
    }


    function getReportFractionTokens(uint256 projectId, uint256 reportId) external view returns (address[] memory) {
        EnumerableSet.AddressSet storage tokens = reportFractionTokens[projectId][reportId];
        address[] memory result = new address[](tokens.length());
        for (uint256 i = 0; i < tokens.length(); i++) {
            result[i] = tokens.at(i);
        }
        return result;
    }


    function updateImpactValue(address fractionToken) external onlyRole(VERIFIER_ROLE) returns (bool) {
        if (projectsContract == address(0)) revert ProjectsContractNotSet();
        FractionData storage data = fractionData[fractionToken];
        if (!data.isActive) revert FractionalizationNotActive();


        // Placeholder: Replace with actual ITerraStakeProjects call when available
        uint256 oldImpactValue = data.impactValue;
        uint256 newImpactValue = oldImpactValue + 100; // Simulate update
        data.impactValue = newImpactValue;


        ProjectFractionData storage pfd = projectFractionData[data.projectId];
        pfd.totalImpactValue = pfd.totalImpactValue - oldImpactValue + newImpactValue;


        emit ImpactMetricsUpdated(fractionToken, oldImpactValue, newImpactValue);
        return true;
    }


    function requestImpactDataUpdate(address fractionToken) external onlyRole(VERIFIER_ROLE) returns (bytes32) {
        if (projectsContract == address(0)) revert ProjectsContractNotSet();
        FractionData storage data = fractionData[fractionToken];
        if (!data.isActive) revert FractionalizationNotActive();


        Chainlink.Request memory request = buildChainlinkRequest(chainlinkJobId, address(this), this.fulfill.selector);
        request.add("projectId", uintToString(data.projectId));
        request.add("reportId", uintToString(data.reportId));
        bytes32 requestId = sendChainlinkRequestTo(chainlinkOracle, request, chainlinkFee);
        requestToFractionToken[requestId] = fractionToken;


        emit ChainlinkDataRequested(fractionToken, requestId);
        return requestId;
    }


    function fulfill(bytes32 _requestId, uint256 _impactValue) public recordChainlinkFulfillment(_requestId) {
        address fractionToken = requestToFractionToken[_requestId];
        if (fractionToken == address(0)) return;


        FractionData storage data = fractionData[fractionToken];
        if (!data.isActive) return;


        uint256 oldImpactValue = data.impactValue;
        data.impactValue = _impactValue;


        ProjectFractionData storage pfd = projectFractionData[data.projectId];
        pfd.totalImpactValue = pfd.totalImpactValue - oldImpactValue + _impactValue;


        emit ImpactMetricsUpdated(fractionToken, oldImpactValue, _impactValue);
        delete requestToFractionToken[_requestId];
    }


    function getFractionProjectData(address fractionToken) external view returns (uint256, uint256) {
        FractionData storage data = fractionData[fractionToken];
        return (data.projectId, data.reportId);
    }


    function getProjectFractionData(uint256 projectId) external view returns (ProjectFractionData memory) {
        return projectFractionData[projectId];
    }


    function fractionalizeProjectNFT(FractionParams calldata params) external nonReentrant whenNotPaused returns (address) {
        if (projectsContract == address(0)) revert ProjectsContractNotSet();
        return _fractionalizeNFT(params, true);
    }


    function createFractionToken(
        uint256 nftId,
        string memory name,
        string memory symbol,
        uint256 fractionCount,
        uint256 lockPeriod
    ) external onlyRole(FRACTIONALIZER_ROLE) returns (address fractionToken) {
        if (nftToFractionToken[nftId] != address(0)) revert NFTAlreadyFractionalized();
        if (fractionCount == 0 || fractionCount > MAX_FRACTION_SUPPLY) revert InvalidFractionSupply();
        if (lockPeriod < MIN_LOCK_PERIOD || lockPeriod > MAX_LOCK_PERIOD) revert InvalidLockPeriod();


        FractionParams memory params = FractionParams({
            tokenId: nftId,
            fractionSupply: fractionCount,
            initialPrice: 0,
            name: name,
            symbol: symbol,
            lockPeriod: lockPeriod
        });


        return _fractionalizeNFT(params, false);
    }


    function _fractionalizeNFT(FractionParams memory params, bool isProjectNFT) internal returns (address) {
        if (nftToFractionToken[params.tokenId] != address(0)) revert NFTAlreadyFractionalized();


        terraStakeNFT.safeTransferFrom(msg.sender, address(this), params.tokenId, 1, "");
        if (fractionalizationFee > 0) {
            if (!tStakeToken.transferFrom(msg.sender, treasuryWallet, fractionalizationFee)) revert TransferFailed();
        }


        (uint256 impactValue, ITerraStakeProjects.ProjectCategory category, bytes32 verificationHash) = terraStakeNFT.getTokenData(params.tokenId);


        FractionToken fractionToken = new FractionToken();
        fractionToken.initialize(params.name, params.symbol, params.fractionSupply, params.tokenId, address(this), impactValue, category, verificationHash);


        address tokenAddress = address(fractionToken);
        fractionData[tokenAddress] = FractionData({
            tokenAddress: tokenAddress,
            nftId: params.tokenId,
            totalSupply: params.fractionSupply,
            redemptionPrice: params.initialPrice * params.fractionSupply,
            isActive: true,
            lockEndTime: block.timestamp + params.lockPeriod,
            creator: msg.sender,
            creationTime: block.timestamp,
            impactValue: impactValue,
            category: category,
            verificationHash: verificationHash,
            projectId: 0,
            reportId: 0
        });


        nftToFractionToken[params.tokenId] = tokenAddress;
        allFractionTokens.add(tokenAddress);
        marketData[tokenAddress] = FractionMarketData({
            totalValueLocked: params.initialPrice * params.fractionSupply,
            totalActiveUsers: 1,
            volumeTraded: 0,
            lastTradePrice: params.initialPrice,
            lastTradeTime: block.timestamp
        });


        IFractionToken(tokenAddress).transfer(msg.sender, params.fractionSupply);


        emit NFTFractionalized(params.tokenId, tokenAddress, params.fractionSupply, msg.sender, category, impactValue);
        return tokenAddress;
    }


    // Governance Functions
    function createProposal(bytes calldata data, bool isEmergency) external onlyRole(GOVERNANCE_ROLE) {
        bytes32 proposalHash = keccak256(data);
        if (proposals[proposalHash].proposedTime != 0) revert ProposalAlreadyExists();


        uint256 threshold = isEmergency ? 1 : governanceThreshold;
        proposals[proposalHash] = Proposal({
            proposalHash: proposalHash,
            proposedTime: block.timestamp,
            requiredThreshold: threshold,
            executed: false,
            isEmergency: isEmergency,
            creator: msg.sender,
            executionTime: 0,
            approvers: new address[](0)
        });
        allProposals.add(proposalHash);


        emit ProposalCreated(proposalHash, msg.sender, isEmergency, data);
    }


    function approveProposal(bytes32 proposalHash) external onlyRole(GOVERNANCE_ROLE) {
        Proposal storage proposal = proposals[proposalHash];
        if (proposal.proposedTime == 0) revert ProposalDoesNotExist();
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (block.timestamp > proposal.proposedTime + proposalExpiryTime) revert ProposalExpired();


        for (uint256 i = 0; i < proposal.approvers.length; i++) {
            if (proposal.approvers[i] == msg.sender) return; // Already approved
        }
        proposal.approvers.push(msg.sender);
        emit ProposalApproved(proposalHash, msg.sender);
    }


    function executeProposal(bytes32 proposalHash, bytes calldata data) external onlyRole(GOVERNANCE_ROLE) {
        Proposal storage proposal = proposals[proposalHash];
        if (proposal.proposedTime == 0) revert ProposalDoesNotExist();
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (block.timestamp > proposal.proposedTime + proposalExpiryTime) revert ProposalExpired();
        if (proposal.approvers.length < proposal.requiredThreshold) revert InsufficientBalance();


        (bool success,) = address(this).call(data);
        proposal.executed = true;
        proposal.executionTime = block.timestamp;
        allProposals.remove(proposalHash);


        emit ProposalExecuted(proposalHash, msg.sender, success);
    }


    // Keeper Functions
    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        upkeepNeeded = (block.timestamp >= lastKeeperUpdate + keeperUpdateInterval) && allFractionTokens.length() > 0;
        performData = abi.encode(upkeepNeeded);
    }


    function performUpkeep(bytes calldata performData) external override {
        bool upkeepNeeded = abi.decode(performData, (bool));
        if (!upkeepNeeded) return;


        // Example upkeep: Request impact data updates for all active tokens
        for (uint256 i = 0; i < allFractionTokens.length(); i++) {
            address token = allFractionTokens.at(i);
            if (fractionData[token].projectId > 0) {
                requestImpactDataUpdate(token);
            }
        }
        lastKeeperUpdate = block.timestamp;
    }


    // Utility function for Chainlink
    function uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }


    function supportsInterface(bytes4 interfaceId) public view override(AccessControlEnumerableUpgradeable, ERC1155HolderUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
