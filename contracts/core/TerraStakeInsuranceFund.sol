// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/ITerraStakeInsuranceFund.sol";



/**
 * @title TerraStakeInsuranceFund
 * @notice This contract implements a simple insurance fund for the TerraStake ecosystem.
 * Users pay a premium in TSTAKE tokens to build up coverage; the fund holds these tokens.
 * In the event of an adverse occurrence, users can file a claim. A fund manager (or governance)
 * then reviews the claim and, if approved, pays the claim from the fund.
 *
 * The design uses OpenZeppelin's upgradeable contracts and access control so that only
 * authorized roles can process claims or upgrade the contract.
 */
contract TerraStakeInsuranceFund is 
    Initializable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable 
{
    using SafeERC20 for IERC20;

    // ============================
    // Roles
    // ============================
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant FUND_MANAGER_ROLE = keccak256("FUND_MANAGER_ROLE");

    // ============================
    // Custom Errors
    // ============================
    error ZeroPremium();
    error InvalidClaimAmount();
    error InsufficientCoverage();
    error ClaimAlreadyProcessed();
    error ClaimNotFound();
    error UnauthorizedCaller();
    error InsufficientFund();
    error TransferFailed(address from, address token, address to, uint256 amount);

    // ============================
    // State Variables
    // ============================
    // TSTAKE token contract reference
    IERC20 public tstakeToken;
    
    // Premiums paid (in TSTAKE tokens) by each participant
    mapping(address => uint256) public premiumsPaid;
    
    // Coverage available for each user (e.g. calculated as premium * multiplier)
    mapping(address => uint256) public coverageAmount;
    
    // Total fund value held (in TSTAKE tokens)
    uint256 public totalFundValue;
    
    // Minimum capital requirement for fund stability
    uint256 public minCapitalRequirement;
    
    // Base premium rate (expressed in basis points, e.g. 100 = 1%)
    uint256 public basePremiumRate;
    
    // Coverage multiplier determines how many times the premium is converted into coverage
    uint256 public coverageMultiplier;

    // ============================
    // Claims
    // ============================
    struct Claim {
        address claimant;
        uint256 amount;
        uint256 timestamp;
        bool processed;
        bool approved;
    }
    Claim[] public claims;
    // Mapping from user to array of claim IDs
    mapping(address => uint256[]) public userClaimIds;

    // ============================
    // Events
    // ============================
    event PremiumPaid(address indexed user, uint256 premium, uint256 coverageGranted, uint256 timestamp);
    event ClaimFiled(address indexed user, uint256 claimId, uint256 claimAmount, uint256 timestamp);
    event ClaimProcessed(uint256 claimId, address indexed claimant, bool approved, uint256 amountPaid, uint256 timestamp);

    // ============================
    // Initializer & Upgrade Functions
    // ============================
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _tstakeToken,
        uint256 _minCapitalRequirement,
        uint256 _basePremiumRate,
        uint256 _coverageMultiplier
    ) external initializer {
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        if (_tstakeToken == address(0)) revert TransferFailed(address(0), _tstakeToken, address(0), 0);

        tstakeToken = IERC20(_tstakeToken);
        minCapitalRequirement = _minCapitalRequirement;
        basePremiumRate = _basePremiumRate;
        coverageMultiplier = _coverageMultiplier;
        totalFundValue = 0; // Initially, no funds are collected.

        // Grant roles: deployer becomes default admin, governance, and fund manager.
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(FUND_MANAGER_ROLE, msg.sender);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ============================
    // Premium & Coverage Functions
    // ============================
    /**
     * @notice Pay a premium into the insurance fund using TSTAKE tokens.
     * @param premiumAmount The amount of TSTAKE tokens the user pays as premium.
     */
    function payPremium(uint256 premiumAmount) external nonReentrant whenNotPaused {
        if (premiumAmount == 0) revert ZeroPremium();

        // Transfer the TSTAKE tokens from the user to the contract.
        tstakeToken.safeTransferFrom(msg.sender, address(this), premiumAmount);

        // Update user and global fund records.
        premiumsPaid[msg.sender] += premiumAmount;
        totalFundValue += premiumAmount;

        // Calculate coverage granted (e.g. premium * coverageMultiplier).
        uint256 grantedCoverage = premiumAmount * coverageMultiplier;
        coverageAmount[msg.sender] += grantedCoverage;

        emit PremiumPaid(msg.sender, premiumAmount, grantedCoverage, block.timestamp);
    }

    // ============================
    // Claims Functions
    // ============================
    /**
     * @notice File a claim for a specified amount.
     * @param claimAmount The amount of TSTAKE tokens the user is claiming.
     * @return claimId The newly created claim's index.
     */
    function fileClaim(uint256 claimAmount) external nonReentrant whenNotPaused returns (uint256 claimId) {
        if (claimAmount == 0) revert InvalidClaimAmount();
        if (claimAmount > coverageAmount[msg.sender]) revert InsufficientCoverage();

        claimId = claims.length;
        claims.push(Claim({
            claimant: msg.sender,
            amount: claimAmount,
            timestamp: block.timestamp,
            processed: false,
            approved: false
        }));
        userClaimIds[msg.sender].push(claimId);

        emit ClaimFiled(msg.sender, claimId, claimAmount, block.timestamp);
    }

    /**
     * @notice Process a filed claim.
     * @param claimId The ID of the claim to process.
     * @param approve Whether to approve the claim.
     */
    function processClaim(uint256 claimId, bool approve) external nonReentrant whenNotPaused onlyRole(FUND_MANAGER_ROLE) {
        if (claimId >= claims.length) revert ClaimNotFound();
        Claim storage userClaim = claims[claimId];
        if (userClaim.processed) revert ClaimAlreadyProcessed();

        userClaim.processed = true;
        userClaim.approved = approve;

        uint256 payout = 0;
        if (approve) {
            // Ensure the fund has sufficient tokens.
            if (userClaim.amount > totalFundValue) revert InsufficientFund();
            payout = userClaim.amount;
            totalFundValue -= payout;
            tstakeToken.safeTransfer(userClaim.claimant, payout);
        }

        emit ClaimProcessed(claimId, userClaim.claimant, approve, payout, block.timestamp);
    }

    // ============================
    // View Functions
    // ============================
    /**
     * @notice Returns the number of claims filed by a given user.
     */
    function getUserClaimCount(address user) external view returns (uint256) {
        return userClaimIds[user].length;
    }

    /**
     * @notice Returns details of a specific claim.
     */
    function getClaim(uint256 claimId) external view returns (Claim memory) {
        if (claimId >= claims.length) revert ClaimNotFound();
        return claims[claimId];
    }

    /**
     * @notice Returns the current TSTAKE balance held by the fund.
     */
    function getFundBalance() external view returns (uint256) {
        return tstakeToken.balanceOf(address(this));
    }
}
