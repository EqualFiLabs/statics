// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsGaugeIncentives} from "../interfaces/IStaticsGaugeIncentives.sol";
import {LibRewardPayout} from "../libraries/LibRewardPayout.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGaugeBribes} from "../libraries/LibGaugeBribes.sol";
import {LibGaugeReserve} from "../libraries/LibGaugeReserve.sol";
import {LibGaugeRouting} from "../libraries/LibGaugeRouting.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibMorpho} from "../libraries/LibMorpho.sol";
import {LibRangeGauge} from "../libraries/LibRangeGauge.sol";
import {LibPosition} from "../position/LibPosition.sol";

contract GaugeIncentiveFacet is ReentrancyGuard {
    struct AllocatorClaimContext {
        uint256 positionId;
        PoolId poolId;
        uint256 allocation;
        bytes32 allocationVersion;
        uint256 poolWeight;
        uint40 currentTime;
        address receiver;
    }

    function fundGaugeReserve(uint256 amount) external nonReentrant returns (uint256 received) {
        if (amount == 0) revert IStaticsGaugeIncentives.InvalidGaugeFundingAmount();
        address statics = LibRangeGauge.staticsToken();
        received = LibCustody.pullAndReserve(LibCustody.gaugeReserveAccount(), statics, msg.sender, amount);
        if (received != amount) revert IStaticsGaugeIncentives.IncompatibleGaugeTokenTransfer(amount, received);

        LibGaugeRouting.RoutingStorage storage routing = LibGaugeRouting.routingStorage();
        uint40 maturityAt;
        if (routing.activated) {
            uint40 currentTime = LibRangeGauge.timestamp40(block.timestamp);
            LibGaugeRouting.checkpointSchedule(currentTime, LibGaugeRouting.MAX_CATCHUP_PERIODS);
            LibGaugeRouting.enforceScheduleCurrent(currentTime);
            maturityAt = routing.periodFinish;
            LibGaugeReserve.defer(received, maturityAt);
        } else {
            LibGaugeReserve.makeAvailable(received);
        }
        emit IStaticsGaugeIncentives.GaugeReserveFunded(msg.sender, received, maturityAt);
    }

    function activateGaugeSchedule() external nonReentrant returns (uint256 budget) {
        LibDiamond.enforceIsContractOwner();
        uint40 currentTime = LibRangeGauge.timestamp40(block.timestamp);
        budget = LibGaugeRouting.activate(currentTime);
        emit IStaticsGaugeIncentives.GaugeScheduleActivated(
            currentTime, LibGaugeRouting.routingStorage().periodFinish, budget
        );
    }

    function setGaugeAllocations(uint256 positionId, PoolId[] calldata poolIds, uint256[] calldata amounts)
        external
        nonReentrant
    {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibMorpho.syncIfInitialized(positionId, msg.sender);
        uint256 staked = LibGlobalRewards.rewardStorage().positions[positionId].balance;
        (uint40 nextAllocationAt, uint256 totalAllocated) = LibGaugeRouting.setAllocations(
            positionId, poolIds, amounts, staked, LibRangeGauge.timestamp40(block.timestamp)
        );
        _emitAllocations(positionId, nextAllocationAt, totalAllocated, poolIds, amounts);
    }

    /// @dev Standard ABI encoding of (totalAllocated, poolIds, amounts). The routing
    /// library already checks equal lengths and the 16-pool bound. Encoding directly
    /// avoids duplicating dynamic calldata encoders in this near-limit facet.
    function _emitAllocations(
        uint256 positionId,
        uint40 nextAllocationAt,
        uint256 totalAllocated,
        PoolId[] calldata poolIds,
        uint256[] calldata amounts
    ) private {
        bytes32 topic = IStaticsGaugeIncentives.PositionGaugeAllocationsSet.selector;
        assembly ("memory-safe") {
            let data := mload(0x40)
            let arraySize := shl(5, poolIds.length)
            let secondOffset := add(128, arraySize)
            let size := add(160, shl(1, arraySize))
            mstore(data, totalAllocated)
            mstore(add(data, 32), 96)
            mstore(add(data, 64), secondOffset)
            mstore(add(data, 96), poolIds.length)
            calldatacopy(add(data, 128), poolIds.offset, arraySize)
            mstore(add(data, secondOffset), amounts.length)
            calldatacopy(add(add(data, secondOffset), 32), amounts.offset, arraySize)
            mstore(0x40, add(data, size))
            log3(data, size, topic, positionId, and(nextAllocationAt, 0xffffffffff))
        }
    }

    function checkpointGaugeSchedule(uint16 maxPeriods)
        external
        nonReentrant
        returns (uint64 period, uint16 periodsProcessed, uint256 newlyAccounted)
    {
        (periodsProcessed, newlyAccounted) =
            LibGaugeRouting.checkpointSchedule(LibRangeGauge.timestamp40(block.timestamp), maxPeriods);
        period = LibGaugeRouting.routingStorage().currentPeriod;
    }

    function checkpointGaugePool(PoolId poolId) external returns (uint256 credited, uint256 recycled) {
        uint40 currentTime = LibRangeGauge.timestamp40(block.timestamp);
        if (LibRangeGauge.rangeGaugeStorage().gauges[poolId].stopped) {
            (credited, recycled) = LibGaugeRouting.invalidatePool(poolId, currentTime);
        } else {
            uint256 priorWeight = LibGaugeRouting.routingStorage().poolWeights[poolId].weight;
            LibGaugeBribes.checkpointPool(poolId, currentTime, priorWeight);
            (credited, recycled) = LibGaugeRouting.checkpointPool(poolId, currentTime);
        }
        if (credited != 0) emit IStaticsGaugeIncentives.ProtocolGaugeRewardCredited(poolId, credited);
        if (recycled != 0) emit IStaticsGaugeIncentives.ProtocolGaugeRewardRecycled(poolId, recycled);
    }

    function scheduleGaugeReleaseBps(uint16 releaseBps) external {
        LibDiamond.enforceIsContractOwner();
        LibGaugeRouting.RoutingStorage storage routing = LibGaugeRouting.routingStorage();
        uint40 effectiveAt;
        if (routing.activated) {
            uint40 currentTime = LibRangeGauge.timestamp40(block.timestamp);
            LibGaugeRouting.checkpointSchedule(currentTime, LibGaugeRouting.MAX_CATCHUP_PERIODS);
            LibGaugeRouting.enforceScheduleCurrent(currentTime);
            effectiveAt = routing.periodFinish;
            LibGaugeReserve.scheduleReleaseBps(releaseBps, effectiveAt);
        } else {
            LibGaugeReserve.setPreActivationReleaseBps(releaseBps);
        }
        emit IStaticsGaugeIncentives.GaugeReleaseBpsScheduled(releaseBps, effectiveAt);
    }

    function setGaugeAllocationCooldown(uint40 cooldown) external {
        LibDiamond.enforceIsContractOwner();
        LibGaugeRouting.setAllocationCooldown(cooldown);
        emit IStaticsGaugeIncentives.GaugeAllocationCooldownSet(cooldown);
    }

    function syncGaugeAllocationsAfterStakeLoss(uint256 positionId, uint256 remainingStake) external {
        if (msg.sender != address(this)) revert IStaticsGaugeIncentives.GaugeSelfCallOnly(msg.sender);
        LibGaugeRouting.clearForStakeLoss(positionId, remainingStake);
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
