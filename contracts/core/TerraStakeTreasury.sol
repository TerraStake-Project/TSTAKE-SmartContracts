// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "../interfaces/IAntiBot.sol";
import "../interfaces/ITerraStakeITO.sol";
import "../interfaces/ITerraStakeToken.sol";

/// @dev Minimal interface extending IERC20 to include burning functionality.
interface IBurnableERC20 is IERC20 {
    function burn(uint256 amount) external;
}

/**
 * @title TerraStakeTreasury
 * @notice Treasury contract for the TerraStake ecosystem with upgradability and robust security features
 * @dev Includes multi-role access control, AntiBot protection, gas optimizations, and upgradability
 */
contract TerraStakeTreasury is 
    Initializable, 
    AccessControlEnumerableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    PausableUpgradeable,
    UUPSUpgradeable 
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ================================
    //  Constants & Roles
    // ================================
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    
    // Arbitrum-specific gas optimization
    uint256 private constant MAX_BATCH_SIZE = 10; // Limit batch operations for gas efficiency

    // ================================
    //  State Variables
    // ================================
    IAntiBot public antiBot;
    IBurnableERC20 public tStakeToken;
    ITerraStakeITO public itoContract;
    
    EnumerableSet.AddressSet private whitelistedTokens;
    EnumerableSet.AddressSet private whitelistedReceivers;
    
    // Withdrawal limits
    mapping(address => uint256) public dailyLimits;
    mapping(address => uint256) public dailyWithdrawn;
    mapping(address => uint256) public lastWithdrawalDay;
    
    // Allocation tracking
    struct Allocation {
        address token;
        uint256 amount;
        uint256 releaseTime;
        bool released;
        string purpose;
    }
    
    mapping(address => Allocation[]) public allocations;
    
    // Ecosystem fund distribution
    struct FundDistribution {
        uint256 developmentShare; // percentage (e.g. 30 for 30%)
        uint256 marketingShare;
        uint256 communityShare;
        uint256 reserveShare;
    }
    
    FundDistribution public fundDistribution;
    
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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract (replaces constructor in upgradable contracts)
     * @param admin Address of the admin
     * @param _tStakeToken Address of the TerraStake token
     */
    function initialize(
        address admin,
        address _tStakeToken
    ) external initializer {
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        
        _setupRoles(admin);
        
        require(_tStakeToken != address(0), "Invalid token address");
        tStakeToken = IBurnableERC20(_tStakeToken);
        
        // Default fund distribution
        fundDistribution = FundDistribution({
            developmentShare: 30,
            marketingShare: 25,
            communityShare: 25,
            reserveShare: 20
        });
    }
    
    function _setupRoles(address admin) private {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }
    
    /**
     * @notice Function that authorizes an upgrade
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
    
    // ================================
    //  Administrative Functions
    // ================================
    
    /**
     * @notice Set the AntiBot contract address
     * @param _antiBot Address of the AntiBot contract
     */
    function setAntiBot(address _antiBot) external onlyRole(GOVERNOR_ROLE) {
        require(_antiBot != address(0), "Invalid AntiBot address");
        antiBot = IAntiBot(_antiBot);
        emit AntiBotUpdated(_antiBot);
    }
    
    /**
     * @notice Set the TerraStake token address
     * @param _tStakeToken Address of the TerraStake token
     */
    function setTStakeToken(address _tStakeToken) external onlyRole(GOVERNOR_ROLE) {
        require(_tStakeToken != address(0), "Invalid token address");
        tStakeToken = IBurnableERC20(_tStakeToken);
        emit TStakeTokenUpdated(_tStakeToken);
    }
    
    /**
     * @notice Set the ITO contract address
     * @param _itoContract Address of the ITO contract
     */
    function setITOContract(address _itoContract) external onlyRole(GOVERNOR_ROLE) {
        require(_itoContract != address(0), "Invalid ITO contract address");
        itoContract = ITerraStakeITO(_itoContract);
        emit ITOContractUpdated(_itoContract);
    }
    
    /**
     * @notice Update token whitelist status
     * @param token Token address
     * @param status Whitelist status
     */
    function setTokenWhitelist(address token, bool status) external onlyRole(GOVERNOR_ROLE) {
        require(token != address(0), "Invalid token address");
        
        if (status) {
            whitelistedTokens.add(token);
        } else {
            whitelistedTokens.remove(token);
        }
        
        emit TokenWhitelisted(token, status);
    }
    
    /**
     * @notice Update receiver whitelist status
     * @param receiver Receiver address
     * @param status Whitelist status
     */
    function setReceiverWhitelist(address receiver, bool status) external onlyRole(GOVERNOR_ROLE) {
        require(receiver != address(0), "Invalid receiver address");
        
        if (status) {
            whitelistedReceivers.add(receiver);
        } else {
            whitelistedReceivers.remove(receiver);
        }
        
        emit ReceiverWhitelisted(receiver, status);
    }
    
    /**
     * @notice Set daily withdrawal limit for a token
     * @param token Token address
     * @param limit Daily limit amount
     */
    function setDailyLimit(address token, uint256 limit) external onlyRole(GOVERNOR_ROLE) {
        require(whitelistedTokens.contains(token), "Token not whitelisted");
        dailyLimits[token] = limit;
        emit DailyLimitUpdated(token, limit);
    }
    
    /**
     * @notice Update fund distribution percentages
     * @param _developmentShare Development fund percentage
     * @param _marketingShare Marketing fund percentage
     * @param _communityShare Community fund percentage
     * @param _reserveShare Reserve fund percentage
     */
    function updateFundDistribution(
        uint256 _developmentShare,
        uint256 _marketingShare,
        uint256 _communityShare,
        uint256 _reserveShare
    ) external onlyRole(GOVERNOR_ROLE) {
        require(_developmentShare + _marketingShare + _communityShare + _reserveShare == 100, "Shares must total 100%");
        
        fundDistribution = FundDistribution({
            developmentShare: _developmentShare,
            marketingShare: _marketingShare,
            communityShare: _communityShare,
            reserveShare: _reserveShare
        });
        
        emit FundDistributionUpdated(_developmentShare, _marketingShare, _communityShare, _reserveShare);
    }
    
    /**
     * @notice Pause all treasury operations
     */
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause treasury operations
     */
    function unpause() external onlyRole(GOVERNOR_ROLE) {
        _unpause();
    }
    
    // ================================
    //  Allocation Functions
    // ================================
    
    /**
     * @notice Allocate funds to a receiver with time lock
     * @param token Token address
     * @param receiver Receiver address
     * @param amount Amount to allocate
     * @param releaseTime Time when funds can be released
     * @param purpose Description of allocation purpose
     */
    function allocateFunds(
        address token,
        address receiver,
        uint256 amount,
        uint256 releaseTime,
        string calldata purpose
    ) external onlyRole(ALLOCATOR_ROLE) nonReentrant whenNotPaused {
        require(whitelistedTokens.contains(token), "Token not whitelisted");
        require(whitelistedReceivers.contains(receiver), "Receiver not whitelisted");
        require(amount > 0, "Amount must be greater than 0");
        require(releaseTime > block.timestamp, "Release time must be in future");
        require(IERC20(token).balanceOf(address(this)) >= amount, "Insufficient balance");
        
        // Apply AntiBot protection if configured
        if (address(antiBot) != address(0)) {
            require(antiBot.validateTransfer(address(this), receiver, amount), "AntiBot: Transfer rejected");
        }
        
        // Create new allocation
        allocations[receiver].push(Allocation({
            token: token,
            amount: amount,
            releaseTime: releaseTime,
            released: false,
            purpose: purpose
        }));
        
        emit FundsAllocated(token, receiver, amount, releaseTime, purpose);
    }
    
    /**
     * @notice Release allocated funds to receiver
     * @param allocationIndex Index of the allocation
     */
    function releaseFunds(uint256 allocationIndex) external nonReentrant whenNotPaused {
        Allocation[] storage receiverAllocations = allocations[msg.sender];
        require(allocationIndex < receiverAllocations.length, "Invalid allocation index");
        
        Allocation storage allocation = receiverAllocations[allocationIndex];
        require(!allocation.released, "Funds already released");
        require(block.timestamp >= allocation.releaseTime, "Funds still locked");
        require(whitelistedTokens.contains(allocation.token), "Token not whitelisted");
        
        // Check daily limits
        address token = allocation.token;
        uint256 today = block.timestamp / 1 days;
        if (lastWithdrawalDay[token] < today) {
            lastWithdrawalDay[token] = today;
            dailyWithdrawn[token] = 0;
        }
        
        require(dailyWithdrawn[token] + allocation.amount <= dailyLimits[token], "Daily limit exceeded");
        
        // Apply AntiBot protection if configured
        if (address(antiBot) != address(0)) {
            require(antiBot.validateTransfer(address(this), msg.sender, allocation.amount), "AntiBot: Transfer rejected");
        }
        
        // Update state before transfer to prevent reentrancy
        allocation.released = true;
        dailyWithdrawn[token] += allocation.amount;
        
        // Transfer funds
        IERC20(token).safeTransfer(msg.sender, allocation.amount);
        
        emit FundsReleased(token, msg.sender, allocation.amount, allocation.purpose);
    }
    
    /**
     * @notice Batch release of multiple allocations (gas-optimized)
     * @param allocationIndices Array of allocation indices to release
     */
    function batchReleaseFunds(uint256[] calldata allocationIndices) external nonReentrant whenNotPaused {
        require(allocationIndices.length <= MAX_BATCH_SIZE, "Batch too large");
        
        Allocation[] storage receiverAllocations = allocations[msg.sender];
        
        // Maps to track total amounts per token
        mapping(address => uint256) memory tokenAmounts;
        
        // First pass: validate and calculate totals
        for (uint256 i = 0; i < allocationIndices.length; i++) {
            uint256 index = allocationIndices[i];
            require(index < receiverAllocations.length, "Invalid allocation index");
            
            Allocation storage allocation = receiverAllocations[index];
            require(!allocation.released, "Funds already released");
            require(block.timestamp >= allocation.releaseTime, "Funds still locked");
            require(whitelistedTokens.contains(allocation.token), "Token not whitelisted");
            
            tokenAmounts[allocation.token] += allocation.amount;
        }
        // Second pass: check limits and mark as released
        address[] memory tokensToTransfer = new address[](allocationIndices.length);
        uint256[] memory amountsToTransfer = new uint256[](allocationIndices.length);
        uint256 uniqueTokenCount = 0;
        
        for (uint256 i = 0; i < allocationIndices.length; i++) {
            Allocation storage allocation = receiverAllocations[allocationIndices[i]];
            address token = allocation.token;
            
            // Check daily limits
            uint256 today = block.timestamp / 1 days;
            if (lastWithdrawalDay[token] < today) {
                lastWithdrawalDay[token] = today;
                dailyWithdrawn[token] = 0;
            }
            
            require(dailyWithdrawn[token] + tokenAmounts[token] <= dailyLimits[token], "Daily limit exceeded");
            
            // Apply AntiBot protection if configured
            if (address(antiBot) != address(0)) {
                require(antiBot.validateTransfer(address(this), msg.sender, tokenAmounts[token]), "AntiBot: Transfer rejected");
            }
            
            // Find if token is already in the transfer list
            bool found = false;
            for (uint256 j = 0; j < uniqueTokenCount; j++) {
                if (tokensToTransfer[j] == token) {
                    found = true;
                    break;
                }
            }
            
            // Add to transfer list if not found
            if (!found) {
                tokensToTransfer[uniqueTokenCount] = token;
                amountsToTransfer[uniqueTokenCount] = tokenAmounts[token];
                uniqueTokenCount++;
            }
            
            // Mark as released and update daily withdrawn
            allocation.released = true;
            dailyWithdrawn[token] += allocation.amount;
            
            emit FundsReleased(token, msg.sender, allocation.amount, allocation.purpose);
        }
        
        // Third pass: transfer funds (one transfer per token type for gas efficiency)
        for (uint256 i = 0; i < uniqueTokenCount; i++) {
            IERC20(tokensToTransfer[i]).safeTransfer(msg.sender, amountsToTransfer[i]);
        }
    }
    
    // ================================
    //  Revenue Management Functions
    // ================================
    
    /**
     * @notice Receive revenue and distribute according to fund allocation
     * @param token Token address
     * @param amount Amount received
     * @param source Source of revenue
     */
    function receiveRevenue(address token, uint256 amount, string calldata source) external nonReentrant whenNotPaused {
        require(whitelistedTokens.contains(token), "Token not whitelisted");
        
        // Transfer tokens from sender to treasury
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        
        emit RevenueReceived(token, amount, source);
    }
    
    /**
     * @notice Burn TerraStake tokens for deflationary mechanism
     * @param amount Amount to burn
     */
    function burnTokens(uint256 amount) external onlyRole(GOVERNOR_ROLE) nonReentrant whenNotPaused {
        require(address(tStakeToken) != address(0), "TStake token not set");
        require(tStakeToken.balanceOf(address(this)) >= amount, "Insufficient balance");
        
        tStakeToken.burn(amount);
        
        emit TokensBurned(amount, block.timestamp);
    }
    
    /**
     * @notice Distribute funds according to ecosystem allocation
     * @param token Token to distribute
     * @param amount Total amount to distribute
     * @param developmentAddress Address for development funds
     * @param marketingAddress Address for marketing funds
     * @param communityAddress Address for community funds
     * @param reserveAddress Address for reserve funds
     */
    function distributeFunds(
        address token,
        uint256 amount,
        address developmentAddress,
        address marketingAddress,
        address communityAddress,
        address reserveAddress
    ) external onlyRole(GOVERNOR_ROLE) nonReentrant whenNotPaused {
        require(whitelistedTokens.contains(token), "Token not whitelisted");
        require(
            whitelistedReceivers.contains(developmentAddress) &&
            whitelistedReceivers.contains(marketingAddress) &&
            whitelistedReceivers.contains(communityAddress) &&
            whitelistedReceivers.contains(reserveAddress),
            "Receivers not whitelisted"
        );
        require(IERC20(token).balanceOf(address(this)) >= amount, "Insufficient balance");
        
        // Calculate amounts based on distribution percentages
        uint256 developmentAmount = (amount * fundDistribution.developmentShare) / 100;
        uint256 marketingAmount = (amount * fundDistribution.marketingShare) / 100;
        uint256 communityAmount = (amount * fundDistribution.communityShare) / 100;
        uint256 reserveAmount = amount - developmentAmount - marketingAmount - communityAmount;
        
        // Transfer funds
        IERC20(token).safeTransfer(developmentAddress, developmentAmount);
        IERC20(token).safeTransfer(marketingAddress, marketingAmount);
        IERC20(token).safeTransfer(communityAddress, communityAmount);
        IERC20(token).safeTransfer(reserveAddress, reserveAmount);
    }
    
    // ================================
    //  Emergency Functions
    // ================================
    
    /**
     * @notice Emergency withdrawal of funds
     * @param token Token address
     * @param receiver Receiver address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, address receiver, uint256 amount) external onlyRole(EMERGENCY_ROLE) nonReentrant {
        require(token != address(0) && receiver != address(0), "Invalid addresses");
        require(amount > 0, "Amount must be greater than 0");
        require(IERC20(token).balanceOf(address(this)) >= amount, "Insufficient balance");
        
        IERC20(token).safeTransfer(receiver, amount);
        emit EmergencyWithdrawal(token, receiver, amount);
    }
    
    // ================================
    //  View Functions
    // ================================
    
    /**
     * @notice Get all whitelisted tokens
     * @return Array of token addresses
     */
    function getWhitelistedTokens() external view returns (address[] memory) {
        uint256 length = whitelistedTokens.length();
        address[] memory tokens = new address[](length);
        
        for (uint256 i = 0; i < length; i++) {
            tokens[i] = whitelistedTokens.at(i);
        }
        
        return tokens;
    }
    
    /**
     * @notice Get all whitelisted receivers
     * @return Array of receiver addresses
     */
    function getWhitelistedReceivers() external view returns (address[] memory) {
        uint256 length = whitelistedReceivers.length();
        address[] memory receivers = new address[](length);
        
        for (uint256 i = 0; i < length; i++) {
            receivers[i] = whitelistedReceivers.at(i);
        }
        
        return receivers;
    }
    
    /**
     * @notice Get all allocations for a receiver
     * @param receiver Receiver address
     * @return Array of allocations
     */
    function getAllocations(address receiver) external view returns (Allocation[] memory) {
        return allocations[receiver];
    }
    
    /**
     * @notice Get remaining daily withdrawal limit for a token
     * @param token Token address
     * @return Remaining limit
     */
    function getRemainingDailyLimit(address token) external view returns (uint256) {
        uint256 today = block.timestamp / 1 days;
        if (lastWithdrawalDay[token] < today) {
            return dailyLimits[token];
        }
        return dailyLimits[token] > dailyWithdrawn[token] ? dailyLimits[token] - dailyWithdrawn[token] : 0;
    }
    
    /**
     * @notice Check if a token is whitelisted
     * @param token Token address
     * @return True if whitelisted
     */
    function isTokenWhitelisted(address token) external view returns (bool) {
        return whitelistedTokens.contains(token);
    }
    
    /**
     * @notice Check if a receiver is whitelisted
     * @param receiver Receiver address
     * @return True if whitelisted
     */
    function isReceiverWhitelisted(address receiver) external view returns (bool) {
        return whitelistedReceivers.contains(receiver);
    }
}