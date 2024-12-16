// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITerraStakeITO {
    struct AdvancedVestingSchedule {
        uint256 totalAmount;
        uint256 releasedAmount;
        uint256 startTime;
        uint256 duration;
        uint256 cliff;
        uint256 interval;
        uint256 amountPerInterval;
        bool revocable;
        bool revoked;
    }

    struct Position {
        uint128 liquidity;
        int24 lowerTick;
        int24 upperTick;
        uint256 tokenId;
    }

    enum ITOState { NotStarted, Active, Paused, Finalized }

    // Events
    event TokensPurchased(
        address indexed buyer,
        uint256 amount,
        uint256 cost,
        uint256 timestamp
    );

    event TokensPurchasedAfterITO(
        address indexed buyer,
        uint256 tokenAmount,
        uint256 usdcAmount,
        uint256 timestamp
    );

    event LiquidityAdded(
        uint256 tStakeAmount,
        uint256 usdcAmount,
        uint256 timestamp
    );

    event ITOStateChanged(ITOState newState, uint256 timestamp);

    event LiquidityProvisionChanged(uint256 newPercentage, uint256 timestamp);

    event USDCWithdrawn(
        address indexed recipient,
        uint256 amount,
        uint256 timestamp
    );

    // Getter Functions
    function getCurrentPrice() external view returns (uint256);

    function getPoolPrice() external view returns (uint256);

    // ITO State Management
    function startITO() external;

    function pauseITO() external;

    function finalizeITO() external;

    // Token Purchase Functions
    function buyTokens(uint256 amount) external;

    function buyTokensAfterITO(uint256 usdcAmount) external;

    // Liquidity Management
    function addLiquidity(
        uint256 amountTSTAKE,
        uint256 amountUSDC,
        int24 lowerTick,
        int24 upperTick
    ) external returns (uint256 tokenId);

    // Governance Functions
    function withdrawUSDC(address recipient, uint256 amount) external;
}
