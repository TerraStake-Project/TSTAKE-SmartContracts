// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "../interfaces/IAntiBot.sol";
import "../interfaces/ITerraStakeITO.sol";


/// @dev Minimal interface extending IERC20 to include burning functionality.
interface IBurnableERC20 is IERC20 {
    function burn(uint256 amount) external;
}


/**
 * @title ITerraStakeTreasury
 * @notice Interface for the TerraStake Treasury contract
 */
interface ITerraStakeTreasury {
    // ================================
    //  Structs
    // ================================
    struct Allocation {
        address token;
        uint256 amount;
        uint256 releaseTime;
        bool released;
        string purpose;
    }
    
    struct FundDistribution {
        uint256 developmentShare;
        uint256 marketingShare;
        uint256 communityShare;
        uint256 reserveShare;
    }

    // ================================
    //  Events
    // ================================
    event TokenWhitelisted(address indexed token, bool status);
    event ReceiverWhitelisted(address indexed receiver, bool status);
    event DailyLimitUpdated(address indexed token, uint256 newLimit);
    event FundsAllocated(address indexed token, address indexed receiver, uint256 amount, uint256 releaseTime, string purpose);
    event FundsReleased(address indexed token, address indexed receiver, uint256 amount, string purpose);
    event EmergencyWithdrawal(address indexed token, address indexed receiver, uint256 amount);
    event AntiBotUpdated(address indexed newAntiBot);
    event TStakeTokenUpdated(address indexed newToken);
    event ITOContractUpdated(address indexed newITOContract);
    event FundDistributionUpdated(uint256 developmentShare, uint256 marketingShare, uint256 communityShare, uint256 reserveShare);
    event TokensBurned(uint256 amount, uint256 timestamp);
    event RevenueReceived(address indexed token, uint256 amount, string source);

    // ================================
    //  Constants & Roles
    // ================================
    function GOVERNOR_ROLE() external view returns (bytes32);
    function ALLOCATOR_ROLE() external view returns (bytes32);
    function EMERGENCY_ROLE() external view returns (bytes32);
    function UPGRADER_ROLE() external view returns (bytes32);

    // ================================
    //  State Variables
    // ================================
    function antiBot() external view returns (IAntiBot);
    function tStakeToken() external view returns (IBurnableERC20);
    function itoContract() external view returns (ITerraStakeITO);
    function fundDistribution() external view returns (FundDistribution memory);
    function dailyLimits(address token) external view returns (uint256);
    function dailyWithdrawn(address token) external view returns (uint256);
    function lastWithdrawalDay(address token) external view returns (uint256);
    function allocations(address receiver, uint256 index) external view returns (
        address token,
        uint256 amount,
        uint256 releaseTime,
        bool released,
        string memory purpose
    );

    // ================================
    //  Initialization
    // ================================
    function initialize(
        address admin,
        address _tStakeToken
    ) external;

    // ================================
    //  Administrative Functions
    // ================================
    function setAntiBot(address _antiBot) external;
    function setTStakeToken(address _tStakeToken) external;
    function setITOContract(address _itoContract) external;
    function setTokenWhitelist(address token, bool status) external;
    function setReceiverWhitelist(address receiver, bool status) external;
    function setDailyLimit(address token, uint256 limit) external;
    function updateFundDistribution(
        uint256 _developmentShare,
        uint256 _marketingShare,
        uint256 _communityShare,
        uint256 _reserveShare
    ) external;
    function pause() external;
    function unpause() external;

    // ================================
    //  Allocation Functions
    // ================================
    function allocateFunds(
        address token,
        address receiver,
        uint256 amount,
        uint256 releaseTime,
        string calldata purpose
    ) external;
    function releaseFunds(uint256 allocationIndex) external;
    function batchReleaseFunds(uint256[] calldata allocationIndices) external;

    // ================================
    //  Revenue Management Functions
    // ================================
    function receiveRevenue(address token, uint256 amount, string calldata source) external;
    function burnTokens(uint256 amount) external;
    function distributeFunds(
        address token,
        uint256 amount,
        address developmentAddress,
        address marketingAddress,
        address communityAddress,
        address reserveAddress
    ) external;

    // ================================
    //  Emergency Functions
    // ================================
    function emergencyWithdraw(address token, address receiver, uint256 amount) external;

    // ================================
    //  View Functions
    // ================================
    function getWhitelistedTokens() external view returns (address[] memory);
    function getWhitelistedReceivers() external view returns (address[] memory);
    function getAllocations(address receiver) external view returns (Allocation[] memory);
    function getRemainingDailyLimit(address token) external view returns (uint256);
    function isTokenWhitelisted(address token) external view returns (bool);
    function isReceiverWhitelisted(address receiver) external view returns (bool);
}