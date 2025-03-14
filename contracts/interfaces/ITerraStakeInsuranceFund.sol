// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

/**
 * @title ITerraStakeInsuranceFund
 * @notice Interface for the TerraStake insurance fund that handles premiums and claims in TSTAKE tokens
 */
interface ITerraStakeInsuranceFund {
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
    // Structs
    // ============================
    struct Claim {
        address claimant;
        uint256 amount;
        uint256 timestamp;
        bool processed;
        bool approved;
    }

    // ============================
    // Events
    // ============================
    event PremiumPaid(address indexed user, uint256 premium, uint256 coverageGranted, uint256 timestamp);
    event ClaimFiled(address indexed user, uint256 claimId, uint256 claimAmount, uint256 timestamp);
    event ClaimProcessed(uint256 claimId, address indexed claimant, bool approved, uint256 amountPaid, uint256 timestamp);

    // ============================
    // Core Functions
    // ============================
    function initialize(
        address _tstakeToken,
        uint256 _minCapitalRequirement,
        uint256 _basePremiumRate,
        uint256 _coverageMultiplier
    ) external;

    function payPremium(uint256 premiumAmount) external;
    function fileClaim(uint256 claimAmount) external returns (uint256 claimId);
    function processClaim(uint256 claimId, bool approve) external;

    // ============================
    // View Functions
    // ============================
    function tstakeToken() external view returns (ERC20Upgradeable);
    function premiumsPaid(address user) external view returns (uint256);
    function coverageAmount(address user) external view returns (uint256);
    function totalFundValue() external view returns (uint256);
    function minCapitalRequirement() external view returns (uint256);
    function basePremiumRate() external view returns (uint256);
    function coverageMultiplier() external view returns (uint256);
    function claims(uint256 index) external view returns (
        address claimant,
        uint256 amount,
        uint256 timestamp,
        bool processed,
        bool approved
    );
    function userClaimIds(address user, uint256 index) external view returns (uint256);
    function getUserClaimCount(address user) external view returns (uint256);
    function getClaim(uint256 claimId) external view returns (Claim memory);
    function getFundBalance() external view returns (uint256);

    // ============================
    // Constants
    // ============================
    function GOVERNANCE_ROLE() external view returns (bytes32);
    function FUND_MANAGER_ROLE() external view returns (bytes32);
}