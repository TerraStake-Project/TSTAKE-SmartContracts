// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./interfaces/ITerraStakeToken.sol";
import "./interfaces/ITerraStakeNFT.sol";

/**
 * @title TerraStakeFractions
 * @dev Contract that allows fractionalization of TerraStake NFTs into tradable ERC20 tokens
 * representing verified environmental impact projects
 */
contract TerraStakeFractions is 
    ERC1155Holder, 
    AccessControl, 
    ReentrancyGuard, 
    Pausable 
{
    using ECDSA for bytes32;

    // =====================================================
    // Roles
    // =====================================================
    bytes32 public constant FRACTIONALIZER_ROLE = keccak256("FRACTIONALIZER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");

    // =====================================================
    // Structs
    // =====================================================
    struct FractionData {
        address tokenAddress;     // Address of ERC20 token representing fractions
        uint256 nftId;            // Original NFT ID
        uint256 totalSupply;      // Total supply of fraction tokens
        uint256 redemptionPrice;  // Price in TStake to redeem the NFT
        bool isActive;            // Whether fractionalization is active
        uint256 lockEndTime;      // When the NFT can be redeemed
        address creator;          // Original NFT owner
        uint256 creationTime;     // When the fractionalization was created
        uint256 impactValue;      // The impact value of the NFT
        string projectType;       // Type of environmental project
        bytes32 verificationHash; // Hash of project verification data
    }

    struct FractionParams {
        uint256 tokenId;          // Original NFT ID
        uint256 fractionSupply;   // Total supply of fraction tokens
        uint256 initialPrice;     // Initial price per fraction
        string name;              // Name of the fraction token
        string symbol;            // Symbol of the fraction token
        uint256 lockPeriod;       // Period in seconds the NFT is locked
    }

    struct FractionMarketData {
        uint256 totalValueLocked; // Total value in TStake tokens
        uint256 totalActiveUsers; // Number of fraction holders
        uint256 volumeTraded;     // Volume of fractions traded
        uint256 lastTradePrice;   // Last trade price
        uint256 lastTradeTime;    // Last trade timestamp
    }

    // =====================================================
    // Events
    // =====================================================
    event NFTFractionalized(
        uint256 indexed nftId, 
        address fractionToken, 
        uint256 totalSupply, 
        address creator
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

    // =====================================================
    // State Variables
    // =====================================================
    // Core contracts
    ITerraStakeNFT public terraStakeNFT;
    ITerraStakeToken public tStakeToken;

    // Fee configuration
    uint256 public fractionalizationFee;   // Fee in TStake to fractionalize an NFT
    uint256 public tradingFeePercentage;   // Percentage fee on fraction trades (basis points)
    address public treasuryWallet;         // Treasury wallet for fees
    address public impactFundWallet;       // Impact fund wallet
    
    // Fraction tracking
    mapping(address => FractionData) public fractionData;  // Fraction token address => FractionData
    mapping(uint256 => address) public nftToFractionToken; // NFT ID => Fraction token address
    mapping(address => FractionMarketData) public marketData; // Fraction token address => Market data
    
    // Redemption offers
    mapping(address => uint256) public redemptionOffers; // Fraction token => Redemption price
    mapping(address => address) public redemptionOfferors; // Fraction token => Offeror address

    // Constants
    uint256 public constant MAX_FRACTION_SUPPLY = 1e27;  // 1 billion tokens with 18 decimals
    uint256 public constant MIN_LOCK_PERIOD = 1 days;
    uint256 public constant MAX_LOCK_PERIOD = 365 days;
    uint256 public constant BASIS_POINTS = 10000;        // 100% in basis points

    // =====================================================
    // Constructor
    // =====================================================
    /**
     * @notice Initializes the TerraStakeFractions contract
     * @param _terraStakeNFT Address of the TerraStakeNFT contract
     * @param _tStakeToken Address of the TStake token contract
     * @param _treasury Address of the treasury wallet
     * @param _impactFund Address of the impact fund wallet
     * @param _fee Initial fractionalization fee
     * @param _tradingFee Initial trading fee percentage (in basis points)
     */
    constructor(
        address _terraStakeNFT,
        address _tStakeToken,
        address _treasury,
        address _impactFund,
        uint256 _fee,
        uint256 _tradingFee
    ) {
        require(_terraStakeNFT != address(0), "Invalid NFT address");
        require(_tStakeToken != address(0), "Invalid token address");
        require(_treasury != address(0), "Invalid treasury address");
        require(_impactFund != address(0), "Invalid impact fund address");
        require(_tradingFee <= 1000, "Trading fee too high"); // Max 10%
        
        terraStakeNFT = ITerraStakeNFT(_terraStakeNFT);
        tStakeToken = ITerraStakeToken(_tStakeToken);
        treasuryWallet = _treasury;
        impactFundWallet = _impactFund;
        fractionalizationFee = _fee;
        tradingFeePercentage = _tradingFee;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(FRACTIONALIZER_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    // =====================================================
    // External Functions
    // =====================================================
    /**
     * @notice Fractionalize an NFT by depositing it and minting ERC20 tokens
     * @param params The fractionalization parameters
     * @return fractionTokenAddress The address of the created ERC20 token
     */
    function fractionalize(FractionParams calldata params) 
        external 
        nonReentrant 
        whenNotPaused
        returns (address fractionTokenAddress) 
    {
        require(params.fractionSupply > 0 && params.fractionSupply <= MAX_FRACTION_SUPPLY, "Invalid fraction supply");
        require(params.lockPeriod >= MIN_LOCK_PERIOD && params.lockPeriod <= MAX_LOCK_PERIOD, "Invalid lock period");
        require(nftToFractionToken[params.tokenId] == address(0), "NFT already fractionalized");
        
        // Transfer the fractionalization fee
        require(tStakeToken.transferFrom(msg.sender, address(this), fractionalizationFee), "Fee transfer failed");
        
        // Transfer the NFT from the owner to this contract
        terraStakeNFT.safeTransferFrom(msg.sender, address(this), params.tokenId, 1, "");
        
        // Get NFT metadata for verification
        (
            ,
            uint256 projectId,
            uint256 impactValue,
            ,
            string memory location,
            uint256 capacity,
            ,
            string memory projectType,
            bool isVerified,
            ,
            ,
            ,
            bytes32 projectDataHash,
            bytes32 impactReportHash,
            ,
            ,
            
        ) = terraStakeNFT.getTokenMetadata(params.tokenId);
        
        require(isVerified, "NFT must be verified");
        
        // Create verification hash
        bytes32 verificationHash = keccak256(abi.encodePacked(
            projectId,
            impactValue,
            projectDataHash,
            impactReportHash,
            block.timestamp
        ));
        
        // Deploy a new ERC20 token for this NFT
        FractionToken newFractionToken = new FractionToken(
            params.name,
            params.symbol,
            params.fractionSupply,
            params.tokenId,
            address(this)
        );
        
        fractionTokenAddress = address(newFractionToken);
        
        // Register the fraction data
        FractionData memory data = FractionData({
            tokenAddress: fractionTokenAddress,
            nftId: params.tokenId,
            totalSupply: params.fractionSupply,
            redemptionPrice: params.initialPrice * params.fractionSupply,
            isActive: true,
            lockEndTime: block.timestamp + params.lockPeriod,
            creator: msg.sender,
            creationTime: block.timestamp,
            impactValue: impactValue,
            projectType: projectType,
            verificationHash: verificationHash
        });
        
        fractionData[fractionTokenAddress] = data;
        nftToFractionToken[params.tokenId] = fractionTokenAddress;
        
        // Initialize market data
        marketData[fractionTokenAddress] = FractionMarketData({
            totalValueLocked: params.initialPrice * params.fractionSupply,
            totalActiveUsers: 1, // Creator starts as the only user
            volumeTraded: 0,
            lastTradePrice: params.initialPrice,
            lastTradeTime: block.timestamp
        });
        
        // Transfer all tokens to the creator
        newFractionToken.transfer(msg.sender, params.fractionSupply);
        
        // Distribute the fee
        distributeFee(fractionalizationFee, "fractionalization");
        
        emit NFTFractionalized(
            params.tokenId, 
            fractionTokenAddress, 
            params.fractionSupply, 
            msg.sender
        );
        
        return fractionTokenAddress;
    }

    /**
     * @notice Offer to redeem an NFT by providing the redemption price
     * @param fractionToken The address of the fraction token
     * @param redemptionPrice The price offered for redemption in TStake
     */
    function offerRedemption(address fractionToken, uint256 redemptionPrice) 
        external 
        nonReentrant 
        whenNotPaused
    {
        FractionData memory data = fractionData[fractionToken];
        require(data.isActive, "Fractionalization not active");
        require(block.timestamp >= data.lockEndTime, "NFT still locked");
        
        // Transfer the redemption price to this contract
        require(tStakeToken.transferFrom(msg.sender, address(this), redemptionPrice), "Price transfer failed");
        
        // Store the redemption offer
        redemptionOffers[fractionToken] = redemptionPrice;
        redemptionOfferors[fractionToken] = msg.sender;
        
        emit RedemptionOffered(data.nftId, fractionToken, redemptionPrice, msg.sender);
    }

    /**
     * @notice Redeem the NFT by burning all fraction tokens
     * @param fractionToken The address of the fraction token
     */
    function redeemNFT(address fractionToken) 
        external 
        nonReentrant 
        whenNotPaused
    {
        FractionData memory data = fractionData[fractionToken];
        require(data.isActive, "Fractionalization not active");
        require(block.timestamp >= data.lockEndTime, "NFT still locked");
        
        FractionToken token = FractionToken(fractionToken);
        uint256 offerPrice = redemptionOffers[fractionToken];
        address offeror = redemptionOfferors[fractionToken];
        
        // If the caller has all tokens, they can redeem directly
        if (token.balanceOf(msg.sender) == data.totalSupply) {
            // Burn all tokens
            token.burnFrom(msg.sender, data.totalSupply);
            
            // Transfer the NFT to the redeemer
            terraStakeNFT.safeTransferFrom(address(this), msg.sender, data.nftId, 1, "");
            
            // Mark fractionalization as inactive
            fractionData[fractionToken].isActive = false;
            
            emit NFTRedeemed(data.nftId, msg.sender, 0);
            return;
        }
        
        // Otherwise, check if there's a valid redemption offer
        require(offerPrice > 0, "No redemption offer");
        require(offeror != address(0), "No valid offeror");
        
        // Calculate token distribution
        uint256 totalTokens = token.totalSupply();
        require(totalTokens > 0, "No tokens in circulation");
        
        // Transfer tokens from holders to this contract and distribute the redemption price
uint256 balance = token.balanceOf(msg.sender);
        if (balance > 0) {
            // Calculate proportional share of redemption price
            uint256 userShare = (offerPrice * balance) / totalTokens;
            
            // Burn the user's tokens
            token.burnFrom(msg.sender, balance);
            
            // Transfer the user's share of the redemption price
            tStakeToken.transfer(msg.sender, userShare);
        }
        
        // Transfer the NFT to the offeror
        terraStakeNFT.safeTransferFrom(address(this), offeror, data.nftId, 1, "");
        
        // Mark fractionalization as inactive
        fractionData[fractionToken].isActive = false;
        
        // Clear the redemption offer
        redemptionOffers[fractionToken] = 0;
        redemptionOfferors[fractionToken] = address(0);
        
        emit NFTRedeemed(data.nftId, offeror, offerPrice);
    }

    /**
     * @notice Buy fractions from the contract (for initial offerings)
     * @param fractionToken The address of the fraction token
     * @param amount Amount of fractions to buy
     * @param maxPrice Maximum price willing to pay in TStake
     */
    function buyFractions(address fractionToken, uint256 amount, uint256 maxPrice) 
        external 
        nonReentrant 
        whenNotPaused
    {
        FractionData memory data = fractionData[fractionToken];
        require(data.isActive, "Fractionalization not active");
        
        FractionToken token = FractionToken(fractionToken);
        
        // Calculate the price
        uint256 unitPrice = marketData[fractionToken].lastTradePrice;
        uint256 totalPrice = unitPrice * amount;
        
        require(totalPrice <= maxPrice, "Price exceeds max price");
        require(token.balanceOf(address(this)) >= amount, "Not enough tokens available");
        
        // Calculate and transfer the fee
        uint256 fee = (totalPrice * tradingFeePercentage) / BASIS_POINTS;
        uint256 netPrice = totalPrice + fee;
        
        require(tStakeToken.transferFrom(msg.sender, address(this), netPrice), "Payment transfer failed");
        
        // Transfer fractions to buyer
        token.transfer(msg.sender, amount);
        
        // Update market data
        FractionMarketData storage market = marketData[fractionToken];
        market.volumeTraded += amount;
        market.lastTradePrice = unitPrice;
        market.lastTradeTime = block.timestamp;
        market.totalActiveUsers += 1; // This is approximate
        
        // Distribute the fee
        distributeFee(fee, "trading");
        
        emit FractionsBought(msg.sender, fractionToken, amount, totalPrice);
        emit MarketDataUpdated(
            fractionToken,
            market.totalValueLocked,
            market.volumeTraded,
            market.lastTradePrice
        );
    }

    /**
     * @notice Sell fractions back to the contract
     * @param fractionToken The address of the fraction token
     * @param amount Amount of fractions to sell
     * @param minPrice Minimum price willing to accept in TStake
     */
    function sellFractions(address fractionToken, uint256 amount, uint256 minPrice) 
        external 
        nonReentrant 
        whenNotPaused
    {
        FractionData memory data = fractionData[fractionToken];
        require(data.isActive, "Fractionalization not active");
        
        FractionToken token = FractionToken(fractionToken);
        
        // Calculate the price
        uint256 unitPrice = marketData[fractionToken].lastTradePrice;
        uint256 totalPrice = unitPrice * amount;
        
        require(totalPrice >= minPrice, "Price below min price");
        require(token.balanceOf(msg.sender) >= amount, "Not enough tokens owned");
        
        // Calculate and deduct the fee
        uint256 fee = (totalPrice * tradingFeePercentage) / BASIS_POINTS;
        uint256 netPayout = totalPrice - fee;
        
        // Transfer fractions to contract
        require(token.transferFrom(msg.sender, address(this), amount), "Token transfer failed");
        
        // Pay the seller
        require(tStakeToken.transfer(msg.sender, netPayout), "Payment failed");
        
        // Update market data
        FractionMarketData storage market = marketData[fractionToken];
        market.volumeTraded += amount;
        market.lastTradePrice = unitPrice;
        market.lastTradeTime = block.timestamp;
        
        // Distribute the fee
        distributeFee(fee, "trading");
        
        emit FractionsSold(msg.sender, fractionToken, amount, netPayout);
        emit MarketDataUpdated(
            fractionToken,
            market.totalValueLocked,
            market.volumeTraded,
            market.lastTradePrice
        );
    }

    /**
     * @notice Create a market for P2P trading of fractions by providing liquidity
     * @param fractionToken The address of the fraction token
     * @param amount Amount of fractions to provide
     * @param tStakeAmount Amount of TStake tokens to provide
     */
    function provideMarketLiquidity(address fractionToken, uint256 amount, uint256 tStakeAmount) 
        external 
        nonReentrant 
        whenNotPaused
    {
        FractionData memory data = fractionData[fractionToken];
        require(data.isActive, "Fractionalization not active");
        
        FractionToken token = FractionToken(fractionToken);
        
        // Transfer assets to this contract
        require(token.transferFrom(msg.sender, address(this), amount), "Token transfer failed");
        require(tStakeToken.transferFrom(msg.sender, address(this), tStakeAmount), "TStake transfer failed");
        
        // Update market data
        FractionMarketData storage market = marketData[fractionToken];
        market.totalValueLocked += tStakeAmount;
        
        // Calculate and update the price based on new liquidity
        if (amount > 0) {
            market.lastTradePrice = tStakeAmount / amount;
            market.lastTradeTime = block.timestamp;
        }
        
        emit MarketDataUpdated(
            fractionToken,
            market.totalValueLocked,
            market.volumeTraded,
            market.lastTradePrice
        );
    }

    // =====================================================
    // Admin Functions
    // =====================================================
    /**
     * @notice Set the fractionalization fee
     * @param newFee The new fee amount
     */
    function setFractionalizationFee(uint256 newFee) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        fractionalizationFee = newFee;
    }

    /**
     * @notice Set the trading fee percentage
     * @param newFeePercentage The new fee percentage in basis points
     */
    function setTradingFeePercentage(uint256 newFeePercentage) 
        external 
        onlyRole(GOVERNANCE_ROLE)
    {
        require(newFeePercentage <= 1000, "Fee too high"); // Max 10%
        tradingFeePercentage = newFeePercentage;
    }

    /**
     * @notice Set the treasury wallet address
     * @param newTreasury The new treasury address
     */
    function setTreasuryWallet(address newTreasury) 
        external 
        onlyRole(GOVERNANCE_ROLE)
    {
        require(newTreasury != address(0), "Invalid address");
        treasuryWallet = newTreasury;
    }

    /**
     * @notice Set the impact fund wallet address
     * @param newImpactFund The new impact fund address
     */
    function setImpactFundWallet(address newImpactFund) 
        external 
        onlyRole(GOVERNANCE_ROLE)
    {
        require(newImpactFund != address(0), "Invalid address");
        impactFundWallet = newImpactFund;
    }

    /**
     * @notice Pause contract operations
     */
    function pause() 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        _pause();
    }

    /**
     * @notice Unpause contract operations
     */
    function unpause() 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        _unpause();
    }

    /**
     * @notice Manually update market data for a fraction token
     * @param fractionToken The address of the fraction token
     * @param lastTradePrice The new last trade price
     */
    function updateMarketPrice(address fractionToken, uint256 lastTradePrice) 
        external 
        onlyRole(OPERATOR_ROLE)
    {
        require(fractionData[fractionToken].isActive, "Fractionalization not active");
        
        marketData[fractionToken].lastTradePrice = lastTradePrice;
        marketData[fractionToken].lastTradeTime = block.timestamp;
        
        emit MarketDataUpdated(
            fractionToken,
            marketData[fractionToken].totalValueLocked,
            marketData[fractionToken].volumeTraded,
            lastTradePrice
        );
    }

    // =====================================================
    // Internal Functions
    // =====================================================
    /**
     * @notice Distribute fee to treasury and impact fund
     * @param fee The fee amount to distribute
     * @param feeType The type of fee being distributed
     */
    function distributeFee(uint256 fee, string memory feeType) internal {
        // 80% to treasury, 20% to impact fund
        uint256 treasuryAmount = (fee * 80) / 100;
        uint256 impactAmount = fee - treasuryAmount;
        
        tStakeToken.transfer(treasuryWallet, treasuryAmount);
        tStakeToken.transfer(impactFundWallet, impactAmount);
        
        emit FeeDistributed(treasuryWallet, treasuryAmount, feeType);
        emit FeeDistributed(impactFundWallet, impactAmount, feeType);
    }

    // =====================================================
    // View Functions
    // =====================================================
    /**
     * @notice Get fraction data for a given token
     * @param fractionToken The fraction token address
     * @return The full fraction data struct
     */
    function getFractionData(address fractionToken) 
        external 
        view 
        returns (FractionData memory) 
    {
        return fractionData[fractionToken];
    }

    /**
     * @notice Get market data for a given fraction token
     * @param fractionToken The fraction token address
     * @return The market data struct
     */
    function getMarketData(address fractionToken) 
        external 
        view 
        returns (FractionMarketData memory) 
    {
        return marketData[fractionToken];
    }

    /**
     * @notice Get fraction token address for a given NFT ID
     * @param nftId The NFT ID
     * @return The fraction token address
     */
    function getFractionTokenForNFT(uint256 nftId) 
        external 
        view 
        returns (address) 
    {
        return nftToFractionToken[nftId];
    }

    /**
     * @notice Check if an NFT is currently fractionalized
     * @param nftId The NFT ID
     * @return True if the NFT is fractionalized
     */
    function isNFTFractionalized(uint256 nftId) 
        external 
        view 
        returns (bool) 
    {
        address tokenAddress = nftToFractionToken[nftId];
        if (tokenAddress == address(0)) return false;
        return fractionData[tokenAddress].isActive;
    }

    /**
     * @notice Calculate the current value of fraction tokens
     * @param fractionToken The fraction token address
     * @param amount The amount of tokens
     * @return The value in TStake tokens
     */
    function calculateFractionValue(address fractionToken, uint256 amount) 
        external 
        view 
        returns (uint256) 
    {
        uint256 unitPrice = marketData[fractionToken].lastTradePrice;
        return unitPrice * amount;
    }
}

/**
 * @title FractionToken
 * @dev ERC20 token representing fractions of a TerraStake NFT
 */
contract FractionToken is ERC20, ERC20Burnable, ERC20Permit {
    uint256 public nftId;
    address public fractionManager;

    /**
     * @notice Initializes the FractionToken contract
     * @param name The name of the token
     * @param symbol The symbol of the token
     * @param initialSupply The initial token supply
     * @param _nftId The ID of the fractionalized NFT
     * @param _fractionManager The address of the fraction manager contract
     */
    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        uint256 _nftId,
        address _fractionManager
    ) ERC20(name, symbol) ERC20Permit(name) {
        nftId = _nftId;
        fractionManager = _fractionManager;
        _mint(fractionManager, initialSupply);
    }
}
