// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.26 <0.9.0;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IStaticsLiquidityRewards {
    struct IncreaseRequest {
        uint256 liquidityDelta;
        uint256 amount0Max;
        uint256 amount1Max;
        uint256 deadline;
    }

    struct StakedLiquidityView {
        uint256 positionId;
        uint256 basketId;
        address asset;
        PoolId poolId;
        address currency0;
        address currency1;
        uint256 eligibleLiquidity;
        uint256 pendingLiquidity;
        uint256 eligibleAtBlock;
        uint256 claimable0;
        uint256 claimable1;
        bool staked;
    }

    struct PoolLiquidityRewardView {
        uint256 totalEligibleLiquidity;
        uint256 index0Ray;
        uint256 index1Ray;
        uint256 indexRemainder0;
        uint256 indexRemainder1;
        uint256 indexed0;
        uint256 indexed1;
        uint256 crystallized0;
        uint256 crystallized1;
        uint256 totalClaimable0;
        uint256 totalClaimable1;
    }

    event LiquidityPositionStaked(
        uint256 indexed positionId,
        uint256 indexed tokenId,
        PoolId indexed poolId,
        uint256 liquidity,
        uint256 eligibleAtBlock
    );
    event LiquidityPositionActivated(
        uint256 indexed positionId, uint256 indexed tokenId, PoolId indexed poolId, uint256 liquidity
    );
    event StakedLiquidityIncreased(
        uint256 indexed positionId,
        uint256 indexed tokenId,
        PoolId indexed poolId,
        uint256 liquidityDelta,
        uint256 spent0,
        uint256 spent1,
        uint256 refund0,
        uint256 refund1,
        uint256 eligibleAtBlock
    );
    event LiquidityPositionUnstaked(
        uint256 indexed positionId, uint256 indexed tokenId, PoolId indexed poolId, address receiver
    );
    event LiquidityRewardAccrued(PoolId indexed poolId, address indexed asset, uint256 amount, uint256 indexRay);
    event LiquidityRewardSettled(
        uint256 indexed positionId, uint256 indexed tokenId, address indexed asset, uint256 amount
    );
    event LiquidityRewardClaimed(
        uint256 indexed positionId, uint256 indexed tokenId, address indexed asset, address receiver, uint256 amount
    );

    function stakeLiquidityPosition(uint256 positionId, uint256 tokenId) external;
    function activateLiquidityPosition(uint256 tokenId) external;
    function increaseStakedLiquidity(
        uint256 positionId,
        uint256 tokenId,
        IncreaseRequest calldata request,
        address refundReceiver
    ) external returns (uint256 spent0, uint256 spent1, uint256 refund0, uint256 refund1);
    function unstakeLiquidityPosition(uint256 positionId, uint256 tokenId, address receiver) external;
    function claimLiquidityRewards(
        uint256 positionId,
        uint256 tokenId,
        address receiver,
        uint256 minAmount0,
        uint256 minAmount1
    ) external returns (uint256 amount0, uint256 amount1);

    function routeCanonicalSwapFees(
        PoolId poolId,
        address asset,
        uint256 liquidityProviderAmount,
        uint256 basketStakerAmount,
        uint256 staticsStakerAmount,
        uint256 treasuryAmount
    ) external;

    function stakedLiquidityPosition(uint256 tokenId) external view returns (StakedLiquidityView memory position);
    function poolLiquidityRewards(PoolId poolId) external view returns (PoolLiquidityRewardView memory pool);
    function pendingLiquidityRewards(uint256 positionId, uint256 tokenId)
        external
        view
        returns (address currency0, uint256 amount0, address currency1, uint256 amount1);
    function canAccrueLiquidityRewards(PoolId poolId) external view returns (bool);
    function canAccrueBasketRewards(PoolId poolId) external view returns (bool);
}
