// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity 0.8.33;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsGaugeIncentives} from "../interfaces/IStaticsGaugeIncentives.sol";
import {LibRewardPayout} from "../libraries/LibRewardPayout.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibGaugeBribes} from "../libraries/LibGaugeBribes.sol";
import {LibGaugeRouting} from "../libraries/LibGaugeRouting.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibRangeGauge} from "../libraries/LibRangeGauge.sol";
import {LibPosition} from "../position/LibPosition.sol";

/// @notice Allocator claims split from routing to preserve EIP-170 headroom.
contract GaugeAllocatorRewardFacet is ReentrancyGuard {
    struct AllocatorClaimContext {
        uint256 positionId;
        PoolId poolId;
        uint256 allocation;
        bytes32 allocationVersion;
        uint256 poolWeight;
        uint40 currentTime;
        address receiver;
    }

    function claimGaugeAllocatorRewards(
        uint256 positionId,
        PoolId poolId,
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

        uint40 currentTime = LibRangeGauge.timestamp40(block.timestamp);
        uint256 priorWeight = LibGaugeRouting.routingStorage().poolWeights[poolId].weight;
        LibGaugeBribes.checkpointPool(poolId, currentTime, priorWeight);
        LibGaugeRouting.checkpointPool(poolId, currentTime);
        uint256 poolWeight = LibGaugeRouting.routingStorage().poolWeights[poolId].weight;
        (uint256 allocation, bytes32 allocationVersion) = LibGaugeRouting.positionAllocation(positionId, poolId);
        AllocatorClaimContext memory context = AllocatorClaimContext({
            positionId: positionId,
            poolId: poolId,
            allocation: allocation,
            allocationVersion: allocationVersion,
            poolWeight: poolWeight,
            currentTime: currentTime,
            receiver: receiver
        });

        received = _claimAllocatorSlots(context, slots, minimumAmounts);
        LibGaugeBribes.syncPositionLeg(positionId, poolId, allocation);
    }

    function _claimAllocatorSlots(
        AllocatorClaimContext memory context,
        uint8[] calldata slots,
        uint256[] calldata minimumAmounts
    ) private returns (uint256[] memory received) {
        received = new uint256[](slots.length);
        uint256 seen;
        for (uint256 i; i < slots.length;) {
            uint8 slot = slots[i];
            _validateAllocatorSlot(context.poolId, slot);
            uint256 mask = 1 << slot;
            if (seen & mask != 0) revert IStaticsGaugeIncentives.DuplicateGaugeAllocatorSlot(slot);
            seen |= mask;
            received[i] = _claim(context, slot, minimumAmounts[i]);
            unchecked {
                ++i;
            }
        }
    }

    function forfeitGaugeAllocatorReward(uint256 positionId, PoolId poolId, uint8 slot)
        external
        nonReentrant
        returns (uint256 amount)
    {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        _validateAllocatorSlot(poolId, slot);
        uint40 currentTime = LibRangeGauge.timestamp40(block.timestamp);
        uint256 priorWeight = LibGaugeRouting.routingStorage().poolWeights[poolId].weight;
        LibGaugeBribes.checkpointPool(poolId, currentTime, priorWeight);
        LibGaugeRouting.checkpointPool(poolId, currentTime);
        uint256 poolWeight = LibGaugeRouting.routingStorage().poolWeights[poolId].weight;
        (uint256 allocation, bytes32 allocationVersion) = LibGaugeRouting.positionAllocation(positionId, poolId);
        (address asset, uint256 claimable, uint256 fractionalAmount) = LibGaugeBribes.forfeitAmount(
            positionId, poolId, slot, allocation, allocationVersion, currentTime, poolWeight
        );
        amount = claimable + fractionalAmount;
        if (amount != 0) {
            LibCustody.moveReservation(LibGaugeBribes.account(poolId, slot), LibCustody.feeAccount(), asset, amount);
            LibGlobalRewards.accrueReservedTreasuryFee(asset, amount);
        }
        LibGaugeBribes.syncPositionLeg(positionId, poolId, allocation);
        emit IStaticsGaugeIncentives.GaugeAllocatorRewardForfeited(positionId, poolId, slot, asset, amount);
    }

    function _claim(AllocatorClaimContext memory context, uint8 slot, uint256 minimumAmount)
        private
        returns (uint256 received)
    {
        (address asset, uint256 amount) = LibGaugeBribes.claimAmount(
            context.positionId,
            context.poolId,
            slot,
            context.allocation,
            context.allocationVersion,
            context.currentTime,
            context.poolWeight
        );
        received = LibRewardPayout.pay(LibGaugeBribes.account(context.poolId, slot), asset, context.receiver, amount);
        if (received < minimumAmount) {
            revert IStaticsGaugeIncentives.GaugeAllocatorAmountBelowMinimum(asset, received, minimumAmount);
        }
        emit IStaticsGaugeIncentives.GaugeAllocatorRewardClaimed(
            context.positionId, context.poolId, slot, asset, context.receiver, amount, received
        );
    }

    function _validateAllocatorSlot(PoolId poolId, uint8 slot) private view {
        LibRangeGauge.PoolRewardConfig storage config = LibRangeGauge.rangeGaugeStorage().rewardConfig[poolId];
        // Slot validation needs assignment, not an asset-array read.
        if (slot == LibRangeGauge.STATICS_SLOT || !config.initialized || slot >= config.slotCount) {
            revert IStaticsGaugeIncentives.InvalidGaugeAllocatorSlot(poolId, slot);
        }
    }
}
