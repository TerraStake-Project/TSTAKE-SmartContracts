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

    event TokensVested(
        address indexed beneficiary,
        uint256 amount,
        uint256 timestamp
    );

    event VestingScheduleCreated(
        address indexed beneficiary,
        uint256 totalAmount,
        uint256 startTime,
        uint256 duration,
        uint256 cliff,
        uint256 interval,
        uint256 amountPerInterval,
        bool revocable
    );

    event VestingScheduleRevoked(address indexed beneficiary, uint256 timestamp);

    event LiquidityPositionCreated(uint256 tokenId, uint256 liquidity, uint256 timestamp);

    // Getters
    function getCurrentPrice() external view returns (uint256);

    function getVestedAmount(address beneficiary) external view returns (uint256);

    function getVestingSchedule(address beneficiary) external view returns (AdvancedVestingSchedule memory);

    function getPoolPrice() external view returns (uint256);

    function getLiquidityPosition(uint256 tokenId) external view returns (Position memory);

    // Vesting Functions
    function createVestingSchedule(
        address beneficiary,
        uint256 totalAmount,
        uint256 startTime,
        uint256 duration,
        uint256 cliff,
        uint256 interval,
        bool revocable
    ) external;

    function claimVestedTokens() external;

    function revokeVestingSchedule(address beneficiary) external;

    // ITO Management
    function startITO() external;

    function pauseITO() external;

    function finalizeITO() external;

    function buyTokens(uint256 amount) external;

    function buyTokensAfterITO(uint256 usdcAmount) external;

    // Liquidity and USDC Management
    function setLiquidityPercentage(uint256 _percentage) external;

    function addLiquidity(
        uint256 amountTSTAKE,
        uint256 amountUSDC,
        int24 lowerTick,
        int24 upperTick
    ) external returns (uint256 tokenId);

    function increaseLiquidity(
        uint256 tokenId,
        uint256 amountTSTAKE,
        uint256 amountUSDC
    ) external;

    function removeLiquidity(uint256 tokenId, uint128 liquidity) external;

    function withdrawUSDC(address recipient, uint256 amount) external;
}
