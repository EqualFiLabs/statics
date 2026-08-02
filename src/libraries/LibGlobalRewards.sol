// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStaticsGlobalRewards} from "../interfaces/IStaticsGlobalRewards.sol";
import {LibBasket} from "./LibBasket.sol";
import {LibCustody} from "./LibCustody.sol";
import {LibPosition} from "../position/LibPosition.sol";

library LibGlobalRewards {
    bytes32 internal constant REWARD_STORAGE_POSITION = keccak256("statics.storage.global.rewards.v1");
    uint256 internal constant RAY = 1e27;
    uint256 internal constant MAX_REWARD_ASSETS = 64;
    uint256 internal constant UNSTAKE_COOLDOWN = 24 hours;
    uint256 internal constant STAKER_SHARE_BPS = 9_000;

    struct RewardSlot {
        address asset;
        IStaticsGlobalRewards.RewardAssetStatus status;
        uint64 generation;
        uint256 indexRay;
        uint256 indexRemainder;
        uint256 indexedAmount;
        uint256 crystallizedAmount;
        uint256 retirementCursor;
        uint256 retirementHighWater;
    }

    struct PositionCheckpoint {
        uint64 generation;
        uint256 indexRay;
    }

    struct StakePosition {
        uint256 balance;
        uint256 lastIncreaseTimestamp;
        uint256 claimAssetCount;
        mapping(uint8 slot => PositionCheckpoint checkpoint) checkpoints;
        mapping(address asset => uint256 amount) claimable;
    }

    struct RewardStorage {
        address stakingToken;
        uint256 totalStaked;
        uint256 occupiedSlots;
        RewardSlot[64] slots;
        mapping(address asset => uint256 slotPlusOne) slotPlusOne;
        address[] queue;
        mapping(address asset => bool queued) queued;
        mapping(uint256 positionId => StakePosition position) positions;
        mapping(address asset => uint256 amount) totalClaimable;
        mapping(address asset => uint256 amount) treasuryAccrued;
    }

    error InvalidStakingToken();
    error RewardAssetAlreadyKnown(address asset);
    error InvalidRewardAsset(address asset);
    error InvalidRewardSlot(uint256 slot);
    error RewardAssetNotActive(uint256 slot);
    error RewardAssetNotRetiring(uint256 slot);
    error RetirementSettlementIncomplete(uint256 cursor, uint256 highWater);
    error ReplacementNotQueued(address asset);
    error InvalidSettlementBatch();

    function rewardStorage() internal pure returns (RewardStorage storage rs) {
        bytes32 position = REWARD_STORAGE_POSITION;
        assembly ("memory-safe") {
            rs.slot := position
        }
    }

    function initialize(address stakingToken_) internal {
        if (stakingToken_ == address(0) || stakingToken_.code.length == 0) revert InvalidStakingToken();
        RewardStorage storage rs = rewardStorage();
        if (rs.stakingToken != address(0)) revert InvalidStakingToken();
        rs.stakingToken = stakingToken_;
    }

    function accrueNonSwapFee(bytes32 sourceAccount, address asset, uint256 grossFee) internal {
        if (grossFee == 0) return;
        RewardStorage storage rs = rewardStorage();
        LibCustody.moveReservation(sourceAccount, LibCustody.feeAccount(), asset, grossFee);
        (uint8 slot, bool active) = _registerOrQueue(rs, asset);
        uint256 intendedStakerAmount = Math.mulDiv(grossFee, STAKER_SHARE_BPS, LibBasket.BPS);
        uint256 stakerAmount;
        if (active && rs.totalStaked != 0) {
            stakerAmount = intendedStakerAmount;
            _increaseIndex(rs.slots[slot], stakerAmount, rs.totalStaked);
        }
        uint256 treasuryAmount = grossFee - stakerAmount;
        rs.treasuryAccrued[asset] += treasuryAmount;
        emit IStaticsGlobalRewards.GlobalFeeAccrued(
            asset,
            grossFee,
            stakerAmount,
            treasuryAmount,
            active ? rs.slots[slot].indexRay : 0
        );
    }

    function accrueReservedSwapStakerFee(address asset, uint256 amount) internal {
        if (amount == 0) return;
        RewardStorage storage rs = rewardStorage();
        (uint8 slot, bool active) = _registerOrQueue(rs, asset);
        if (!active || rs.totalStaked == 0) revert InvalidRewardAsset(asset);
        _increaseIndex(rs.slots[slot], amount, rs.totalStaked);
        emit IStaticsGlobalRewards.GlobalFeeAccrued(asset, amount, amount, 0, rs.slots[slot].indexRay);
    }

    function accrueReservedTreasuryFee(address asset, uint256 amount) internal {
        if (amount == 0) return;
        rewardStorage().treasuryAccrued[asset] += amount;
        emit IStaticsGlobalRewards.GlobalFeeAccrued(asset, amount, 0, amount, 0);
    }

    function settleAll(uint256 positionId) internal {
        RewardStorage storage rs = rewardStorage();
        for (uint8 slot; slot < MAX_REWARD_ASSETS; ++slot) {
            if (rs.slots[slot].status != IStaticsGlobalRewards.RewardAssetStatus.None) {
                settleSlot(rs, positionId, slot);
            }
        }
    }

    function resetIndexRemainders() internal {
        RewardStorage storage rs = rewardStorage();
        for (uint8 slot; slot < MAX_REWARD_ASSETS; ++slot) {
            if (rs.slots[slot].status != IStaticsGlobalRewards.RewardAssetStatus.None) {
                rs.slots[slot].indexRemainder = 0;
            }
        }
    }

    function settleAsset(uint256 positionId, address asset) internal {
        RewardStorage storage rs = rewardStorage();
        uint256 slotPlusOne = rs.slotPlusOne[asset];
        if (slotPlusOne != 0) settleSlot(rs, positionId, uint8(slotPlusOne - 1));
    }

    function settleSlot(RewardStorage storage rs, uint256 positionId, uint8 slot) internal {
        RewardSlot storage reward = rs.slots[slot];
        if (reward.status == IStaticsGlobalRewards.RewardAssetStatus.None) return;
        StakePosition storage position = rs.positions[positionId];
        PositionCheckpoint storage checkpoint = position.checkpoints[slot];
        uint256 priorIndex = checkpoint.generation == reward.generation ? checkpoint.indexRay : 0;
        uint256 added;
        if (position.balance != 0 && reward.indexRay > priorIndex) {
            added = Math.mulDiv(position.balance, reward.indexRay - priorIndex, RAY);
            if (added != 0) {
                if (position.claimable[reward.asset] == 0) ++position.claimAssetCount;
                position.claimable[reward.asset] += added;
                rs.totalClaimable[reward.asset] += added;
                reward.crystallizedAmount += added;
            }
        }
        checkpoint.generation = reward.generation;
        checkpoint.indexRay = reward.indexRay;
        emit IStaticsGlobalRewards.PositionRewardSettled(positionId, reward.asset, reward.generation, added);
    }

    function pending(uint256 positionId, address asset) internal view returns (uint256 amount) {
        RewardStorage storage rs = rewardStorage();
        StakePosition storage position = rs.positions[positionId];
        amount = position.claimable[asset];
        uint256 slotPlusOne = rs.slotPlusOne[asset];
        if (slotPlusOne == 0) return amount;
        uint8 slot = uint8(slotPlusOne - 1);
        RewardSlot storage reward = rs.slots[slot];
        PositionCheckpoint storage checkpoint = position.checkpoints[slot];
        uint256 priorIndex = checkpoint.generation == reward.generation ? checkpoint.indexRay : 0;
        if (position.balance != 0 && reward.indexRay > priorIndex) {
            amount += Math.mulDiv(position.balance, reward.indexRay - priorIndex, RAY);
        }
    }

    function activateStakingLeg(uint256 positionId) internal {
        bytes32 key = LibPosition.stakingLegKey();
        LibPosition.PositionStorage storage ps = LibPosition.positionStorage();
        if (!ps.activeLeg[positionId][key]) LibPosition.activateLeg(positionId, key);
    }

    function deactivateStakingLegIfEmpty(uint256 positionId) internal {
        StakePosition storage position = rewardStorage().positions[positionId];
        if (position.balance != 0 || position.claimAssetCount != 0) return;
        bytes32 key = LibPosition.stakingLegKey();
        LibPosition.PositionStorage storage ps = LibPosition.positionStorage();
        if (ps.activeLeg[positionId][key]) LibPosition.deactivateLeg(positionId, key);
    }

    function beginRetirement(uint8 slot, uint256 highWater) internal {
        RewardStorage storage rs = rewardStorage();
        RewardSlot storage reward = rs.slots[slot];
        if (reward.status != IStaticsGlobalRewards.RewardAssetStatus.Active) revert RewardAssetNotActive(slot);
        reward.status = IStaticsGlobalRewards.RewardAssetStatus.Retiring;
        reward.retirementCursor = 1;
        reward.retirementHighWater = highWater;
        emit IStaticsGlobalRewards.RewardAssetRetirementStarted(slot, reward.asset, reward.generation, highWater);
    }

    function settleRetirement(uint8 slot, uint256 maxPositions) internal returns (uint256 next, bool complete) {
        if (maxPositions == 0) revert InvalidSettlementBatch();
        RewardStorage storage rs = rewardStorage();
        RewardSlot storage reward = rs.slots[slot];
        if (reward.status != IStaticsGlobalRewards.RewardAssetStatus.Retiring) revert RewardAssetNotRetiring(slot);
        uint256 from = reward.retirementCursor;
        uint256 highWater = reward.retirementHighWater;
        uint256 end = from + maxPositions - 1;
        if (end > highWater) end = highWater;
        for (uint256 positionId = from; positionId <= end; ++positionId) {
            settleSlot(rs, positionId, slot);
        }
        next = end < highWater ? end + 1 : highWater + 1;
        reward.retirementCursor = next;
        complete = next > highWater;
        emit IStaticsGlobalRewards.RewardAssetRetirementProgress(slot, from, end);
    }

    function finalizeRetirement(uint8 slot, address replacement) internal {
        RewardStorage storage rs = rewardStorage();
        RewardSlot storage reward = rs.slots[slot];
        if (reward.status != IStaticsGlobalRewards.RewardAssetStatus.Retiring) revert RewardAssetNotRetiring(slot);
        if (reward.retirementCursor <= reward.retirementHighWater) {
            revert RetirementSettlementIncomplete(reward.retirementCursor, reward.retirementHighWater);
        }
        address retired = reward.asset;
        uint64 retiredGeneration = reward.generation;
        uint256 dust = reward.indexedAmount - reward.crystallizedAmount;
        if (dust != 0) rs.treasuryAccrued[retired] += dust;
        delete rs.slotPlusOne[retired];
        emit IStaticsGlobalRewards.RewardAssetRetired(slot, retired, retiredGeneration);

        if (replacement == address(0)) {
            rs.slots[slot] = RewardSlot({
                asset: address(0),
                status: IStaticsGlobalRewards.RewardAssetStatus.None,
                generation: retiredGeneration,
                indexRay: 0,
                indexRemainder: 0,
                indexedAmount: 0,
                crystallizedAmount: 0,
                retirementCursor: 0,
                retirementHighWater: 0
            });
            --rs.occupiedSlots;
            return;
        }
        if (!rs.queued[replacement]) revert ReplacementNotQueued(replacement);
        rs.queued[replacement] = false;
        uint64 nextGeneration = retiredGeneration + 1;
        rs.slots[slot] = RewardSlot({
            asset: replacement,
            status: IStaticsGlobalRewards.RewardAssetStatus.Active,
            generation: nextGeneration,
            indexRay: 0,
            indexRemainder: 0,
            indexedAmount: 0,
            crystallizedAmount: 0,
            retirementCursor: 0,
            retirementHighWater: 0
        });
        rs.slotPlusOne[replacement] = uint256(slot) + 1;
        emit IStaticsGlobalRewards.RewardAssetActivated(slot, replacement, nextGeneration);
    }

    function _registerOrQueue(RewardStorage storage rs, address asset) private returns (uint8 slot, bool active) {
        if (asset == address(0) || asset.code.length == 0) revert InvalidRewardAsset(asset);
        uint256 existing = rs.slotPlusOne[asset];
        if (existing != 0) {
            slot = uint8(existing - 1);
            return (slot, rs.slots[slot].status == IStaticsGlobalRewards.RewardAssetStatus.Active);
        }
        if (rs.queued[asset]) return (0, false);
        if (rs.occupiedSlots == MAX_REWARD_ASSETS) {
            rs.queued[asset] = true;
            rs.queue.push(asset);
            emit IStaticsGlobalRewards.RewardAssetQueued(asset);
            return (0, false);
        }
        for (uint8 i; i < MAX_REWARD_ASSETS; ++i) {
            if (rs.slots[i].status == IStaticsGlobalRewards.RewardAssetStatus.None) {
                slot = i;
                break;
            }
        }
        uint64 generation = rs.slots[slot].generation + 1;
        rs.slots[slot] = RewardSlot({
            asset: asset,
            status: IStaticsGlobalRewards.RewardAssetStatus.Active,
            generation: generation,
            indexRay: 0,
            indexRemainder: 0,
            indexedAmount: 0,
            crystallizedAmount: 0,
            retirementCursor: 0,
            retirementHighWater: 0
        });
        rs.slotPlusOne[asset] = uint256(slot) + 1;
        ++rs.occupiedSlots;
        emit IStaticsGlobalRewards.RewardAssetActivated(slot, asset, generation);
        return (slot, true);
    }

    function _increaseIndex(RewardSlot storage reward, uint256 amount, uint256 denominator) private {
        uint256 delta = Math.mulDiv(amount, RAY, denominator);
        uint256 remainder = mulmod(amount, RAY, denominator);
        delta += reward.indexRemainder / denominator;
        uint256 normalizedPrior = reward.indexRemainder % denominator;
        uint256 room = denominator - normalizedPrior;
        if (remainder >= room) {
            ++delta;
            remainder -= room;
        } else {
            remainder += normalizedPrior;
        }
        reward.indexRay += delta;
        reward.indexRemainder = remainder;
        reward.indexedAmount += amount;
    }
}
