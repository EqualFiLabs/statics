// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {MorphoPosition} from "../interfaces/IMorphoBlue.sol";
import {IStaticsMorpho} from "../interfaces/IStaticsMorpho.sol";
import {LibBasket} from "./LibBasket.sol";
import {LibBasketRewards} from "./LibBasketRewards.sol";
import {LibGlobalRewards} from "./LibGlobalRewards.sol";
import {LibMorpho} from "./LibMorpho.sol";

library LibMorphoSync {
    function syncOne(uint256 positionId, bytes32 marketId, address keeper) internal returns (uint256 trackedLoss) {
        LibMorpho.MarketConfig storage config = LibMorpho.requireMarket(marketId);
        LibMorpho.MorphoStorage storage ms = LibMorpho.morphoStorage();
        LibMorpho.PositionMarket storage tracked = ms.positions[positionId].positions[marketId];
        MorphoPosition memory actual = LibMorpho.actualPosition(positionId, marketId);
        if (
            ms.positions[positionId].indexPlusOne[marketId] != 0
                && (tracked.trackedCollateral != 0 || actual.collateral != 0 || actual.borrowShares != 0)
        ) LibMorpho.trackMarket(positionId, marketId);
        uint256 previous = tracked.trackedCollateral;
        if (uint256(actual.collateral) < previous) {
            trackedLoss = previous - uint256(actual.collateral);
            tracked.trackedCollateral = actual.collateral;
            if (config.kind == IStaticsMorpho.CollateralKind.Basket) {
                ms.basketCollateral[positionId][config.basketId] -= trackedLoss;
                LibBasketRewards.applyMorphoLoss(
                    positionId,
                    config.basketId,
                    LibBasket.basketStorage().baskets[config.basketId],
                    trackedLoss,
                    keeper,
                    ms.syncBountyBps
                );
            } else {
                ms.staticsCollateral[positionId] -= trackedLoss;
                LibGlobalRewards.applyMorphoLoss(positionId, trackedLoss, keeper, ms.syncBountyBps);
            }
        }
        LibMorpho.syncDebtObligation(positionId, marketId, actual.borrowShares);
        LibMorpho.deactivateIfEmpty(positionId, marketId, actual);
        emit IStaticsMorpho.MorphoSynchronized(positionId, marketId, keeper, previous, actual.collateral, trackedLoss);
    }

    function syncAll(uint256 positionId, address keeper) internal {
        bytes32[] storage stored = LibMorpho.morphoStorage().positions[positionId].ids;
        bytes32[] memory ids = new bytes32[](stored.length);
        for (uint256 i; i < stored.length; ++i) {
            ids[i] = stored[i];
        }
        for (uint256 i; i < ids.length; ++i) {
            syncOne(positionId, ids[i], keeper);
        }
    }
}
