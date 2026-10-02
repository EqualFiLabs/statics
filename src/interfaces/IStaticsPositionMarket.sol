// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsGlobalRewards} from "./IStaticsGlobalRewards.sol";

/// @notice Bounded discovery views for valuing a live, transferable PositionNFT account.
interface IStaticsPositionMarket {
    function pendingRewards(uint256 positionId, address[] calldata assets)
        external
        view
        returns (uint256[] memory amounts);
    function stakePosition(uint256 positionId)
        external
        view
        returns (IStaticsGlobalRewards.StakePositionView memory position);
    function positionRewardAssets(uint256 positionId) external view returns (address[] memory assets);
    function isRewardAssetOptedIn(uint256 positionId, address asset) external view returns (bool);
    function rewardSelection(uint256 positionId, address asset)
        external
        view
        returns (IStaticsGlobalRewards.RewardSelectionView memory selection);
    function globalRewardAssetsOfPosition(uint256 positionId, uint256 cursor, uint256 limit)
        external
        view
        returns (address[] memory assets, uint256 nextCursor);
    function positionGaugeAllocatorPools(uint256 positionId, uint256 cursor, uint256 limit)
        external
        view
        returns (PoolId[] memory poolIds, uint256 nextCursor);
    function previewNativeLpFees(uint256 positionId, PoolId poolId)
        external
        view
        returns (uint256 amount0, uint256 amount1);
}
