// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsLiquidityManager} from "../interfaces/IStaticsLiquidityManager.sol";
import {IStaticsGaugeIncentives} from "../interfaces/IStaticsGaugeIncentives.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IStaticsRangeGauge} from "../interfaces/IStaticsRangeGauge.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibGaugeEpoch} from "../libraries/LibGaugeEpoch.sol";
import {LibGaugeReserve} from "../libraries/LibGaugeReserve.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {LibRangeGauge} from "../libraries/LibRangeGauge.sol";
import {LibPosition} from "../position/LibPosition.sol";

/// @notice Exit, claim, forfeiture, recovery, and final reconciliation for public range gauges.
contract RangeGaugeLivenessFacet is ReentrancyGuard {
    using StateLibrary for IPoolManager;

    struct ClaimContext {
        uint256 positionId;
        PoolId poolId;
        address receiver;
    }

    function exitLiquidity(
        uint256 positionId,
        PoolId poolId,
        uint256 amount0Minimum,
        uint256 amount1Minimum,
        uint256 deadline
    ) external nonReentrant returns (IStaticsRangeGauge.LiquidityMovement memory movement) {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        PoolKey memory key = _enforceHistoricalPublicGauge(poolId);
        LibRangeGauge.LpLeg storage leg = _indexedLeg(positionId, poolId);
        if (leg.manager == address(0) || leg.liquidity == 0) {
            revert IStaticsRangeGauge.InvalidPositionState(positionId, poolId);
        }

        _synchronizeAndSettle(poolId, key, leg);
        uint256 posmTokenId = leg.posmTokenId;
        address receiver = IERC721(address(this)).ownerOf(positionId);
        IStaticsLiquidityManager.ManagedPositionMovement memory managed = IStaticsLiquidityManager(leg.manager)
            .exitManagedPosition(
                IStaticsLiquidityManager.ManagedLiquidityRequest({
                    tokenId: posmTokenId,
                    liquidity: 0,
                    amount0Limit: amount0Minimum,
                    amount1Limit: amount1Minimum,
                    deadline: deadline,
                    receiver: receiver
                })
            );

        LibRangeGauge.unregisterPositionRange(poolId, leg.tickLower, leg.tickUpper, key.tickSpacing, leg.liquidity);
        LibRangeGauge.unbindPosm(posmTokenId, positionId, poolId);
        LibRangeGauge.GaugePool storage gauge = LibRangeGauge.rangeGaugeStorage().gauges[poolId];
        --gauge.managedLegCount;
        leg.manager = address(0);
        leg.posmTokenId = 0;
        leg.tickLower = 0;
        leg.tickUpper = 0;
        leg.liquidity = 0;
        delete leg.checkpointInsideRay;
        delete leg.rewardRemainderRay;
        _finalizeIfResolved(positionId, poolId, leg);

        movement = IStaticsRangeGauge.LiquidityMovement({
            posmTokenId: posmTokenId,
            liquidity: 0,
            spent0: 0,
            received0: managed.received0,
            spent1: 0,
            received1: managed.received1
        });
        emit IStaticsRangeGauge.ManagedLiquidityExited(positionId, poolId, posmTokenId);
    }

    function claimLpRewards(
        uint256 positionId,
        PoolId poolId,
        uint8[] calldata slots,
        uint256[] calldata minimumAmounts,
        address receiver
    ) external nonReentrant returns (uint256[] memory received) {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        if (slots.length != minimumAmounts.length) revert IStaticsRangeGauge.ArrayLengthMismatch();
        if (receiver == address(0) || receiver == address(this)) revert IStaticsRangeGauge.InvalidReceiver(receiver);
        PoolKey memory key = _enforceHistoricalPublicGauge(poolId);
        LibRangeGauge.LpLeg storage leg = _indexedLeg(positionId, poolId);
        _settleIfActive(poolId, key, leg);

        ClaimContext memory context = ClaimContext({positionId: positionId, poolId: poolId, receiver: receiver});
        received = _claimSlots(context, leg, slots, minimumAmounts);
        _finalizeIfResolved(positionId, poolId, leg);
    }

    function forfeitLpReward(uint256 positionId, PoolId poolId, uint8 slot)
        external
        nonReentrant
        returns (uint256 amount)
    {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        PoolKey memory key = _enforceHistoricalPublicGauge(poolId);
        LibRangeGauge.LpLeg storage leg = _indexedLeg(positionId, poolId);
        _settleIfActive(poolId, key, leg);
        (address asset, bool assigned) = LibRangeGauge.rewardAsset(poolId, slot);
        if (!assigned) revert IStaticsRangeGauge.GaugeRewardSlotNotAssigned(poolId, slot);

        amount = leg.claimable[slot];
        leg.claimable[slot] = 0;
        _decreaseClaimLiability(poolId, slot, amount);
        if (leg.liquidity == 0) leg.rewardRemainderRay[slot] = 0;
        LibRangeGauge.GaugeRewardStream storage stream = LibRangeGauge.rangeGaugeStorage().gauges[poolId].streams[slot];
        if (amount != 0 && slot == LibRangeGauge.STATICS_SLOT && stream.protocolEpoch != 0) {
            LibCustody.moveReservation(
                LibRangeGauge.rewardAccount(poolId, slot), LibCustody.gaugeReserveAccount(), asset, amount
            );
            LibGaugeReserve.consumeCommitted(amount);
            LibGaugeReserve.recycle(amount, stream.protocolEpoch, LibGaugeEpoch.epochAt(block.timestamp));
        } else if (amount != 0) {
            LibCustody.moveReservation(
                LibRangeGauge.rewardAccount(poolId, slot), LibCustody.feeAccount(), asset, amount
            );
            LibGlobalRewards.accrueReservedTreasuryFee(asset, amount);
        }
        emit IStaticsRangeGauge.LpRewardForfeited(positionId, poolId, asset, slot, amount);
        _finalizeIfResolved(positionId, poolId, leg);
    }

    function recoverUnboundPosm(address manager, uint256 posmTokenId, address receiver) external nonReentrant {
        LibDiamond.enforceIsContractOwner();
        if (manager.code.length == 0) revert IStaticsRangeGauge.LiquidityManagerNotInstalled();
        IStaticsLiquidityManager bound = IStaticsLiquidityManager(manager);
        address actualDiamond = bound.staticsDiamond();
        if (actualDiamond != address(this)) {
            revert IStaticsRangeGauge.LiquidityManagerBindingMismatch(manager, address(this), actualDiamond);
        }
        bound.recoverUnboundPosition(posmTokenId, receiver);
        emit IStaticsRangeGauge.UnboundPosmRecovered(manager, posmTokenId, receiver);
    }

    function reconcilePoolRewardSurplus(PoolId poolId, uint8 slot) external nonReentrant returns (uint256 amount) {
        _enforceHistoricalPublicGauge(poolId);
        LibRangeGauge.RangeGaugeStorage storage rgs = LibRangeGauge.rangeGaugeStorage();
        (address asset, bool assigned) = LibRangeGauge.rewardAsset(poolId, slot);
        if (!assigned) revert IStaticsRangeGauge.GaugeRewardSlotNotAssigned(poolId, slot);
        LibRangeGauge.GaugePool storage gauge = rgs.gauges[poolId];
        LibRangeGauge.GaugeRewardStream storage stream = gauge.streams[slot];
        bytes32 account = LibRangeGauge.rewardAccount(poolId, slot);
        uint256 reserved = LibCustody.accountReserved(account, asset);
        if (!LibRangeGauge.reconciliationAvailable(
                gauge.stopped,
                gauge.unresolvedLegCount,
                stream.periodBudget,
                stream.periodEmitted,
                stream.periodRecycled,
                stream.claimLiability,
                reserved,
                stream.indexedLiability
            )) revert IStaticsRangeGauge.PoolRewardReconciliationUnavailable(poolId, slot);

        stream.indexedLiability = 0;
        stream.indexRemainder = 0;
        amount = reserved;
        if (amount != 0 && slot == LibRangeGauge.STATICS_SLOT && stream.protocolEpoch != 0) {
            LibCustody.moveReservation(
                LibRangeGauge.rewardAccount(poolId, slot), LibCustody.gaugeReserveAccount(), asset, amount
            );
            LibGaugeReserve.consumeCommitted(amount);
            LibGaugeReserve.recycle(amount, stream.protocolEpoch, LibGaugeEpoch.epochAt(block.timestamp));
        } else if (amount != 0) {
            LibCustody.moveReservation(account, LibCustody.feeAccount(), asset, amount);
            LibGlobalRewards.accrueReservedTreasuryFee(asset, amount);
        }
        emit IStaticsRangeGauge.PoolRewardSurplusReconciled(poolId, asset, slot, amount);
    }

    function _claimSlots(
        ClaimContext memory context,
        LibRangeGauge.LpLeg storage leg,
        uint8[] calldata slots,
        uint256[] calldata minimumAmounts
    ) private returns (uint256[] memory received) {
        received = new uint256[](slots.length);
        uint256 seen;
        for (uint256 i; i < slots.length; ++i) {
            uint8 slot = slots[i];
            if (slot >= LibRangeGauge.MAX_REWARD_SLOTS) {
                revert IStaticsRangeGauge.GaugeRewardSlotNotAssigned(context.poolId, slot);
            }
            uint256 mask = 1 << slot;
            if (seen & mask != 0) revert IStaticsRangeGauge.DuplicateRewardSlot(slot);
            seen |= mask;
            received[i] = _claimSlot(context, leg, slot, minimumAmounts[i]);
        }
    }

    function _claimSlot(ClaimContext memory context, LibRangeGauge.LpLeg storage leg, uint8 slot, uint256 minimumAmount)
        private
        returns (uint256 received)
    {
        (address asset, bool assigned) = LibRangeGauge.rewardAsset(context.poolId, slot);
        if (!assigned) revert IStaticsRangeGauge.GaugeRewardSlotNotAssigned(context.poolId, slot);
        uint256 amount = leg.claimable[slot];
        if (amount == 0) {
            if (minimumAmount != 0) revert IStaticsRangeGauge.RewardAmountBelowMinimum(asset, 0, minimumAmount);
            return 0;
        }

        leg.claimable[slot] = 0;
        _decreaseClaimLiability(context.poolId, slot, amount);
        (uint256 debited, uint256 actualReceived) = LibCustody.pushReserved(
            LibRangeGauge.rewardAccount(context.poolId, slot), asset, context.receiver, amount, amount
        );
        LibRangeGauge.GaugeRewardStream storage stream =
            LibRangeGauge.rangeGaugeStorage().gauges[context.poolId].streams[slot];
        if (slot == LibRangeGauge.STATICS_SLOT && stream.protocolEpoch != 0) {
            LibGaugeReserve.consumeCommitted(debited);
        }
        if (actualReceived < minimumAmount) {
            revert IStaticsRangeGauge.RewardAmountBelowMinimum(asset, actualReceived, minimumAmount);
        }
        emit IStaticsRangeGauge.LpRewardsClaimed(
            context.positionId, context.poolId, asset, slot, context.receiver, debited, actualReceived
        );
        received = actualReceived;
    }

    function _decreaseClaimLiability(PoolId poolId, uint8 slot, uint256 amount) private {
        if (amount == 0) return;
        LibRangeGauge.GaugeRewardStream storage stream = LibRangeGauge.rangeGaugeStorage().gauges[poolId].streams[slot];
        uint256 liability = stream.claimLiability;
        if (amount > liability) {
            revert IStaticsRangeGauge.ClaimLiabilityUnderflow(poolId, slot, liability, amount);
        }
        stream.claimLiability = liability - amount;
    }

    function _settleIfActive(PoolId poolId, PoolKey memory key, LibRangeGauge.LpLeg storage leg) private {
        if (leg.liquidity == 0) return;
        _synchronizeAndSettle(poolId, key, leg);
    }

    function _synchronizeAndSettle(PoolId poolId, PoolKey memory key, LibRangeGauge.LpLeg storage leg) private {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        (, int24 liveTick,,) = IPoolManager(ls.poolManager).getSlot0(poolId);
        uint40 currentTime = LibRangeGauge.timestamp40(block.timestamp);
        IStaticsGaugeIncentives(address(this)).checkpointGaugePool(poolId);
        LibRangeGauge.synchronizeTopology(poolId, key.tickSpacing, liveTick, currentTime);
        LibRangeGauge.settleLeg(poolId, leg);
    }

    function _indexedLeg(uint256 positionId, PoolId poolId) private view returns (LibRangeGauge.LpLeg storage leg) {
        if (!LibRangeGauge.hasPositionPool(positionId, poolId)) {
            revert IStaticsRangeGauge.ManagedLegNotFound(positionId, poolId);
        }
        leg = LibRangeGauge.rangeGaugeStorage().lpLegs[positionId][poolId];
    }

    function _finalizeIfResolved(uint256 positionId, PoolId poolId, LibRangeGauge.LpLeg storage leg) private {
        if (leg.liquidity != 0) return;
        for (uint8 slot; slot < LibRangeGauge.MAX_REWARD_SLOTS; ++slot) {
            if (leg.claimable[slot] != 0 || leg.rewardRemainderRay[slot] != 0) return;
        }

        LibRangeGauge.RangeGaugeStorage storage rgs = LibRangeGauge.rangeGaugeStorage();
        --rgs.gauges[poolId].unresolvedLegCount;
        LibRangeGauge.removePositionPool(positionId, poolId);
        delete rgs.lpLegs[positionId][poolId];
        LibPosition.deactivateLeg(positionId, LibPosition.lpLegKey(poolId));
    }

    function _enforceHistoricalPublicGauge(PoolId poolId) private view returns (PoolKey memory key) {
        (IStaticsProtocolPools.ProtocolPoolKind kind, PoolKey memory registeredKey,,) =
            LibProtocolPools.enforceRegistered(poolId);
        if (
            kind != IStaticsProtocolPools.ProtocolPoolKind.General
                && kind != IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical
        ) revert IStaticsRangeGauge.InvalidPublicPool(poolId);
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (address(registeredKey.hooks) != ls.hook) revert IStaticsRangeGauge.InvalidPublicPool(poolId);
        if (!LibRangeGauge.rangeGaugeStorage().gauges[poolId].initialized) {
            revert IStaticsRangeGauge.InvalidPublicPool(poolId);
        }
        key = registeredKey;
    }
}
