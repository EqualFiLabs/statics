// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsGaugeIncentives} from "../interfaces/IStaticsGaugeIncentives.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGaugeEpoch} from "../libraries/LibGaugeEpoch.sol";
import {LibGaugeBribes} from "../libraries/LibGaugeBribes.sol";
import {LibGaugeReserve} from "../libraries/LibGaugeReserve.sol";
import {LibGaugeRouting} from "../libraries/LibGaugeRouting.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibMorpho} from "../libraries/LibMorpho.sol";
import {LibPosition} from "../position/LibPosition.sol";
import {LibRangeGauge} from "../libraries/LibRangeGauge.sol";

contract GaugeIncentiveFacet is ReentrancyGuard {
    struct AllocatorClaimContext {
        uint256 positionId;
        PoolId poolId;
        uint64 epoch;
        address receiver;
        uint40 currentTime;
    }

    function fundGaugeReserve(uint256 amount) external nonReentrant returns (uint256 received) {
        if (amount == 0) revert IStaticsGaugeIncentives.InvalidGaugeFundingAmount();
        uint64 currentEpoch = LibGaugeEpoch.epochAt(block.timestamp);
        address statics = LibRangeGauge.staticsToken();
        received = LibCustody.pullAndReserve(LibCustody.gaugeReserveAccount(), statics, msg.sender, amount);
        if (received != amount) revert IStaticsGaugeIncentives.IncompatibleGaugeTokenTransfer(amount, received);
        LibGaugeReserve.defer(received, currentEpoch);
        emit IStaticsGaugeIncentives.GaugeReserveFunded(msg.sender, received, currentEpoch + 1);
    }

    function setGaugeAllocations(uint256 positionId, PoolId[] calldata poolIds, uint256[] calldata amounts)
        external
        nonReentrant
    {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibMorpho.syncIfInitialized(positionId, msg.sender);
        LibGaugeRouting.checkpointEpoch(uint40(block.timestamp));
        uint256 staked = LibGlobalRewards.rewardStorage().positions[positionId].balance;
        (uint64 effectiveEpoch, uint256 totalAllocated) =
            LibGaugeRouting.setAllocations(positionId, poolIds, amounts, staked);
        emit IStaticsGaugeIncentives.PositionGaugeAllocationsScheduled(positionId, effectiveEpoch, totalAllocated);
    }

    function checkpointGaugeEpoch()
        external
        nonReentrant
        returns (uint64 epoch, uint256 committedBudget, bool finalized)
    {
        return LibGaugeRouting.checkpointEpoch(uint40(block.timestamp));
    }

    function checkpointGaugePool(PoolId poolId) external returns (uint256 committed, uint256 recycled) {
        return LibGaugeRouting.checkpointPool(poolId, LibRangeGauge.timestamp40(block.timestamp));
    }

    function closeGaugeEpoch(uint64 epoch) external nonReentrant returns (uint256 recycled) {
        return LibGaugeRouting.closeEpoch(epoch, LibRangeGauge.timestamp40(block.timestamp));
    }

    function scheduleGaugeReleaseBps(uint16 releaseBps) external {
        LibDiamond.enforceIsContractOwner();
        uint64 currentEpoch = LibGaugeEpoch.epochAt(block.timestamp);
        uint64 effectiveEpoch = currentEpoch + 1;
        LibGaugeReserve.scheduleReleaseBps(releaseBps, effectiveEpoch, currentEpoch);
        emit IStaticsGaugeIncentives.GaugeReleaseBpsScheduled(releaseBps, effectiveEpoch);
    }

    function syncGaugeAllocationsAfterStakeLoss(uint256 positionId, uint256 remainingStake) external {
        if (msg.sender != address(this)) revert IStaticsGaugeIncentives.GaugeSelfCallOnly(msg.sender);
        LibGaugeRouting.clearForStakeLoss(positionId, remainingStake);
    }

    function finalizeGaugeAllocatorReward(PoolId poolId, uint8 slot, uint64 epoch)
        external
        nonReentrant
        returns (uint256 distributable)
    {
        _validateAllocatorSlot(poolId, slot);
        (distributable,) = _finalizeAllocatorReward(poolId, slot, epoch, LibRangeGauge.timestamp40(block.timestamp));
    }

    function claimGaugeAllocatorRewards(
        uint256 positionId,
        PoolId poolId,
        uint64 epoch,
        uint8[] calldata slots,
        uint256[] calldata minimumAmounts,
        address receiver
    ) external nonReentrant returns (uint256[] memory received) {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        if (slots.length != minimumAmounts.length) {
            revert IStaticsGaugeIncentives.GaugeAllocatorClaimLengthMismatch();
        }
        if (receiver == address(0) || receiver == address(this)) {
            revert IStaticsGaugeIncentives.InvalidGaugeAllocatorReceiver(receiver);
        }
        AllocatorClaimContext memory context = AllocatorClaimContext({
            positionId: positionId,
            poolId: poolId,
            epoch: epoch,
            receiver: receiver,
            currentTime: LibRangeGauge.timestamp40(block.timestamp)
        });
        received = new uint256[](slots.length);
        uint256 seen;
        for (uint256 i; i < slots.length; ++i) {
            uint8 slot = slots[i];
            _validateAllocatorSlot(poolId, slot);
            uint256 mask = 1 << slot;
            if (seen & mask != 0) revert IStaticsGaugeIncentives.DuplicateGaugeAllocatorSlot(slot);
            seen |= mask;
            received[i] = _claimAllocatorReward(context, slot, minimumAmounts[i]);
        }
    }

    function expireGaugeAllocatorReward(PoolId poolId, uint8 slot, uint64 epoch)
        external
        nonReentrant
        returns (uint256 amount)
    {
        _validateAllocatorSlot(poolId, slot);
        uint40 currentTime = LibRangeGauge.timestamp40(block.timestamp);
        _finalizeAllocatorReward(poolId, slot, epoch, currentTime);
        address asset;
        (asset, amount) = LibGaugeBribes.expire(poolId, slot, epoch, currentTime);
        emit IStaticsGaugeIncentives.GaugeAllocatorRewardExpired(poolId, slot, epoch, asset, amount);
    }

    function _claimAllocatorReward(AllocatorClaimContext memory context, uint8 slot, uint256 minimumAmount)
        private
        returns (uint256 received)
    {
        _finalizeAllocatorReward(context.poolId, slot, context.epoch, context.currentTime);
        (address asset, uint256 amount) =
            LibGaugeBribes.claimAmount(context.positionId, context.poolId, slot, context.epoch, context.currentTime);
        if (amount == 0) {
            if (minimumAmount != 0) {
                revert IStaticsGaugeIncentives.GaugeAllocatorAmountBelowMinimum(asset, 0, minimumAmount);
            }
            emit IStaticsGaugeIncentives.GaugeAllocatorRewardClaimed(
                context.positionId, context.poolId, context.epoch, slot, asset, context.receiver, 0, 0
            );
            return 0;
        }
        (uint256 debited, uint256 actualReceived) = LibCustody.pushReserved(
            LibGaugeBribes.account(context.poolId, slot, context.epoch), asset, context.receiver, amount, amount
        );
        if (actualReceived < minimumAmount) {
            revert IStaticsGaugeIncentives.GaugeAllocatorAmountBelowMinimum(asset, actualReceived, minimumAmount);
        }
        emit IStaticsGaugeIncentives.GaugeAllocatorRewardClaimed(
            context.positionId, context.poolId, context.epoch, slot, asset, context.receiver, debited, actualReceived
        );
        received = actualReceived;
    }

    function _finalizeAllocatorReward(PoolId poolId, uint8 slot, uint64 epoch, uint40 currentTime)
        private
        returns (uint256 distributable, bool newlyFinalized)
    {
        (newlyFinalized, distributable,) = LibGaugeBribes.finalize(poolId, slot, epoch, currentTime);
        if (!newlyFinalized) return (distributable, false);
        LibGaugeBribes.Budget storage budget = LibGaugeBribes.bribeStorage().budgets[poolId][slot][epoch];
        emit IStaticsGaugeIncentives.GaugeAllocatorRewardFinalized(
            poolId, slot, epoch, budget.asset, distributable, budget.totalWeight, budget.expiresAt
        );
    }

    function _validateAllocatorSlot(PoolId poolId, uint8 slot) private view {
        if (slot == LibRangeGauge.STATICS_SLOT) {
            revert IStaticsGaugeIncentives.InvalidGaugeAllocatorSlot(poolId, slot);
        }
        (, bool assigned) = LibRangeGauge.rewardAsset(poolId, slot);
        if (!assigned) revert IStaticsGaugeIncentives.InvalidGaugeAllocatorSlot(poolId, slot);
    }
}
