// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITerraStakeITO {
    enum ITOState { NotStarted, Active, Paused, Finalized }

    // ------------------------------------------------------
    // Events
    // ------------------------------------------------------
    event TokensPurchased(
        address indexed buyer,
        uint256 usdcAmount,
        uint256 tokenAmount,
        uint256 timestamp
    );

    event TokensPurchasedAfterITO(
        address indexed buyer,
        uint256 usdcAmount,
        uint256 tokenAmount,
        uint256 timestamp
    );

    event LiquidityAdded(
        uint256 tStakeAmount,
        uint256 usdcAmount,
        uint256 timestamp
    );

    event ITOStateChanged(
        ITOState newState,
        uint256 timestamp
    );

    event DynamicITOParametersUpdated(
        uint256 newStartingPrice,
        uint256 newEndingPrice,
        uint256 newPriceDuration
    );

    event UnsoldTokensBurned(
        uint256 unsoldTokens,
        uint256 timestamp
    );

    event UnsoldTokensAllocated(
        uint256 treasuryAmount,
        uint256 stakingAmount,
        uint256 liquidityAmount,
        uint256 timestamp
    );

    event USDCWithdrawn(
        address indexed recipient,
        uint256 amount,
        uint256 timestamp
    );

    event TreasuryVestedTokensClaimed(
        uint256 amountClaimed,
        uint256 remainingVestedTokens,
        uint256 timestamp
    );

    // ------------------------------------------------------
    // Getter Functions
    // ------------------------------------------------------
    function getCurrentPrice() external view returns (uint256);
    function getPoolPrice() external view returns (uint256);
    function getRemainingVestedTreasuryTokens() external view returns (uint256);

    // ------------------------------------------------------
    // ITO State Management
    // ------------------------------------------------------
    function startITO() external;
    function pauseITO() external;
    function finalizeITO() external;
    function claimVestedTokens() external;

    function updateITOPrices(
        uint256 newStartingPrice,
        uint256 newEndingPrice,
        uint256 newPriceDuration
    ) external;

    // ------------------------------------------------------
    // Token Purchase Functions
    // ------------------------------------------------------
    function buyTokens(uint256 usdcAmount, uint256 minTokensOut) external;
    function buyTokensAfterITO(uint256 usdcAmount) external;

    // ------------------------------------------------------
    // Liquidity Management
    // ------------------------------------------------------
    function addLiquidity(
        uint256 amountTSTAKE,
        uint256 amountUSDC,
        int24 lowerTick,
        int24 upperTick,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external returns (uint256 tokenId);

    // ------------------------------------------------------
    // Governance Functions
    // ------------------------------------------------------
    function withdrawUSDC(address recipient, uint256 amount) external;
    function pausePurchases() external;
    function resumePurchases() external;
}