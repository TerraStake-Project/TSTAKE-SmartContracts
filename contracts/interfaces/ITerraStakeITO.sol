// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITerraStakeITO {
    enum ITOState { NotStarted, Active, Ended }

    // ================================
    // 🔹 Constants
    // ================================
    function POOL_FEE() external pure returns (uint24);
    function MAX_TOKENS_FOR_ITO() external pure returns (uint256);
    function DEFAULT_MIN_PURCHASE_USDC() external pure returns (uint256);
    function DEFAULT_MAX_PURCHASE_USDC() external pure returns (uint256);

    // ================================
    // 🔹 Governance & Roles
    // ================================
    function GOVERNANCE_ROLE() external view returns (bytes32);
    function MULTISIG_ROLE() external view returns (bytes32);
    function PAUSER_ROLE() external view returns (bytes32);

    // ================================
    // 🔹 ITO State Variables
    // ================================
    function itoState() external view returns (ITOState);
    function startingPrice() external view returns (uint256);
    function endingPrice() external view returns (uint256);
    function priceDuration() external view returns (uint256);
    function tokensSold() external view returns (uint256);
    function accumulatedUSDC() external view returns (uint256);
    function itoStartTime() external view returns (uint256);
    function itoEndTime() external view returns (uint256);
    function minPurchaseUSDC() external view returns (uint256);
    function maxPurchaseUSDC() external view returns (uint256);
    function purchasesPaused() external view returns (bool);

    // ================================
    // 🔹 ITO Functions
    // ================================
    function getCurrentPrice() external view returns (uint256);

    function buyTokens(
        uint256 usdcAmount,
        uint256 minTokensOut,
        bool usePermit,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function withdrawUSDC(address recipient, uint256 amount) external;

    function pausePurchases() external;

    function resumePurchases() external;

    // ================================
    // 🔹 Uniswap Liquidity Functions
    // ================================
    function addLiquidityToUniswap(uint256 usdcAmount, uint256 tStakeAmount) external;

    // ================================
    // 🔹 View Functions & Mappings
    // ================================
    function purchasedAmounts(address user) external view returns (uint256);
    function blacklist(address user) external view returns (bool);

    // ================================
    // 🔹 Verification Functions
    // ================================
    function officialInfo() external pure returns (string memory);
    function verifyOwner() external pure returns (string memory);

    // ================================
    // 🔹 Events
    // ================================
    event TokensPurchased(
        address indexed buyer,
        uint256 usdcSpent,
        uint256 tokensReceived,
        uint256 timestamp
    );

    event USDCWithdrawn(
        address indexed recipient,
        uint256 amount,
        uint256 timestamp
    );

    event ITOStateUpdated(
        ITOState newState,
        uint256 timestamp
    );

    event PurchasesPaused(
        bool status,
        uint256 timestamp
    );

    event BlacklistUpdated(
        address indexed user,
        bool isBlacklisted
    );

    event LiquidityAdded(
        uint256 usdcAmount,
        uint256 tStakeAmount
    );
}
