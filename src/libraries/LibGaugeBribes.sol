// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsGaugeIncentives} from "../interfaces/IStaticsGaugeIncentives.sol";
import {LibCustody} from "./LibCustody.sol";
import {LibGaugeEligibility} from "./LibGaugeEligibility.sol";
import {LibGaugeEpoch} from "./LibGaugeEpoch.sol";
import {LibGaugeRouting} from "./LibGaugeRouting.sol";
import {LibGlobalRewards} from "./LibGlobalRewards.sol";
import {LibRangeGauge} from "./LibRangeGauge.sol";

/// @notice Custody and claim accounting for creator-funded gauge allocator rewards.
library LibGaugeBribes {
    bytes32 internal constant STORAGE_POSITION = keccak256("statics.storage.gauge.bribes.v1");
    bytes32 internal constant ACCOUNT_DOMAIN = keccak256("statics.custody.account.gauge.bribes.v1");
    uint64 internal constant CLAIM_WINDOW_EPOCHS = 26;

    struct Budget {
        address asset;
        bytes32 eligibilityVersion;
        bool finalized;
        bool expired;
        uint40 fundedAt;
        uint40 expiresAt;
        uint256 funded;
        uint256 totalWeight;
        uint256 distributable;
        uint256 remainingLiability;
    }

    struct BribeStorage {
        mapping(PoolId poolId => mapping(uint8 slot => mapping(uint64 epoch => Budget budget))) budgets;
        mapping(
            uint256 positionId => mapping(PoolId poolId => mapping(uint8 slot => mapping(uint64 epoch => bool)))
        ) claimed;
    }

    error GaugeBribeAssetMismatch(address expected, address actual);

    function bribeStorage() internal pure returns (BribeStorage storage bs) {
        bytes32 position = STORAGE_POSITION;
        assembly ("memory-safe") {
            bs.slot := position
        }
    }

    function account(PoolId poolId, uint8 slot, uint64 epoch) internal pure returns (bytes32) {
        return keccak256(abi.encode(ACCOUNT_DOMAIN, PoolId.unwrap(poolId), slot, epoch));
    }

    /// @dev A restriction-version change invalidates prior funding for the same future epoch.
    ///      The invalidated reservation becomes treasury revenue before the new tranche is recorded.
    function recordFunding(
        PoolId poolId,
        uint8 slot,
        uint64 epoch,
        address asset,
        bytes32 eligibilityVersion,
        uint40 fundedAt,
        uint256 amount
    ) internal returns (uint256 invalidated) {
        Budget storage budget = bribeStorage().budgets[poolId][slot][epoch];
        address recordedAsset = budget.asset;
        if (recordedAsset != address(0) && recordedAsset != asset) {
            revert GaugeBribeAssetMismatch(recordedAsset, asset);
        }
        if (budget.eligibilityVersion != bytes32(0) && budget.eligibilityVersion != eligibilityVersion) {
            invalidated = budget.funded;
            if (invalidated != 0) {
                LibCustody.moveReservation(account(poolId, slot, epoch), LibCustody.feeAccount(), asset, invalidated);
                LibGlobalRewards.accrueReservedTreasuryFee(asset, invalidated);
            }
            delete bribeStorage().budgets[poolId][slot][epoch];
        }
        budget.asset = asset;
        budget.eligibilityVersion = eligibilityVersion;
        if (budget.fundedAt == 0) budget.fundedAt = fundedAt;
        budget.funded += amount;
    }

    function finalize(PoolId poolId, uint8 slot, uint64 epoch, uint40 currentTime)
        internal
        returns (bool newlyFinalized, uint256 distributable, uint256 treasuryAmount)
    {
        Budget storage budget = bribeStorage().budgets[poolId][slot][epoch];
        if (budget.asset == address(0) || budget.funded == 0) {
            revert IStaticsGaugeIncentives.GaugeAllocatorRewardNotFound(poolId, slot, epoch);
        }
        if (budget.finalized) return (false, budget.distributable, 0);
        uint40 finish = LibGaugeEpoch.epochFinish(epoch);
        if (currentTime < finish) {
            revert IStaticsGaugeIncentives.GaugeAllocatorEpochActive(epoch, finish, currentTime);
        }

        (uint256 totalWeight, bytes32 weightVersion) = LibGaugeRouting.poolWeightAt(poolId, epoch);
        uint40 cutoff = _eligibilityCutoff(poolId, epoch, budget.fundedAt, finish);
        if (weightVersion == budget.eligibilityVersion && totalWeight != 0 && cutoff > LibGaugeEpoch.epochStart(epoch))
        {
            distributable =
                Math.mulDiv(budget.funded, uint256(cutoff) - LibGaugeEpoch.epochStart(epoch), LibGaugeEpoch.WEEK);
            budget.totalWeight = totalWeight;
        }
        budget.finalized = true;
        budget.distributable = distributable;
        budget.remainingLiability = distributable;
        budget.expiresAt = LibGaugeEpoch.epochFinish(epoch + CLAIM_WINDOW_EPOCHS);
        treasuryAmount = budget.funded - distributable;
        _toTreasury(poolId, slot, epoch, budget.asset, treasuryAmount);
        newlyFinalized = true;
    }

    function claimAmount(uint256 positionId, PoolId poolId, uint8 slot, uint64 epoch, uint40 currentTime)
        internal
        returns (address asset, uint256 amount)
    {
        Budget storage budget = bribeStorage().budgets[poolId][slot][epoch];
        if (!budget.finalized) revert IStaticsGaugeIncentives.GaugeAllocatorRewardNotFinalized(poolId, slot, epoch);
        if (currentTime >= budget.expiresAt) {
            revert IStaticsGaugeIncentives.GaugeAllocatorClaimExpired(poolId, slot, epoch, budget.expiresAt);
        }
        BribeStorage storage bs = bribeStorage();
        if (bs.claimed[positionId][poolId][slot][epoch]) {
            revert IStaticsGaugeIncentives.GaugeAllocatorRewardAlreadyClaimed(positionId, poolId, slot, epoch);
        }
        bs.claimed[positionId][poolId][slot][epoch] = true;
        asset = budget.asset;
        (uint256 allocation, bytes32 allocationVersion) =
            LibGaugeRouting.positionAllocationAt(positionId, poolId, epoch);
        if (
            allocation == 0 || allocationVersion != budget.eligibilityVersion || budget.totalWeight == 0
                || budget.distributable == 0
        ) return (asset, 0);
        amount = Math.mulDiv(budget.distributable, allocation, budget.totalWeight);
        uint256 remaining = budget.remainingLiability;
        if (amount > remaining) {
            revert IStaticsGaugeIncentives.GaugeAllocatorLiabilityUnderflow(poolId, slot, epoch, remaining, amount);
        }
        budget.remainingLiability = remaining - amount;
    }

    function expire(PoolId poolId, uint8 slot, uint64 epoch, uint40 currentTime)
        internal
        returns (address asset, uint256 amount)
    {
        Budget storage budget = bribeStorage().budgets[poolId][slot][epoch];
        if (!budget.finalized) revert IStaticsGaugeIncentives.GaugeAllocatorRewardNotFinalized(poolId, slot, epoch);
        if (currentTime < budget.expiresAt) {
            revert IStaticsGaugeIncentives.GaugeAllocatorClaimWindowActive(
                poolId, slot, epoch, budget.expiresAt, currentTime
            );
        }
        asset = budget.asset;
        if (budget.expired) return (asset, 0);
        budget.expired = true;
        amount = budget.remainingLiability;
        budget.remainingLiability = 0;
        _toTreasury(poolId, slot, epoch, asset, amount);
    }

    function preview(uint256 positionId, PoolId poolId, uint8 slot, uint64 epoch)
        internal
        view
        returns (uint256 allocation, uint256 amount, bool claimed)
    {
        BribeStorage storage bs = bribeStorage();
        Budget storage budget = bs.budgets[poolId][slot][epoch];
        bytes32 allocationVersion;
        (allocation, allocationVersion) = LibGaugeRouting.positionAllocationAt(positionId, poolId, epoch);
        claimed = bs.claimed[positionId][poolId][slot][epoch];
        if (
            !budget.finalized || budget.expired || claimed || block.timestamp >= budget.expiresAt || allocation == 0
                || allocationVersion != budget.eligibilityVersion || budget.totalWeight == 0
        ) return (allocation, 0, claimed);
        amount = Math.mulDiv(budget.distributable, allocation, budget.totalWeight);
    }

    function _eligibilityCutoff(PoolId poolId, uint64 epoch, uint40 fundedAt, uint40 finish)
        private
        view
        returns (uint40 cutoff)
    {
        uint40 start = LibGaugeEpoch.epochStart(epoch);
        if (epoch != 0) {
            uint40 preEpochRestriction = LibGaugeEligibility.restrictionTimestamp(poolId, epoch - 1);
            if (preEpochRestriction > fundedAt) return start;
        }
        cutoff = finish;
        uint40 restrictedAt = LibGaugeEligibility.restrictionTimestamp(poolId, epoch);
        if (restrictedAt != 0 && restrictedAt < cutoff) cutoff = restrictedAt;
        uint40 stoppedAt = LibRangeGauge.rangeGaugeStorage().gauges[poolId].stoppedAt;
        if (stoppedAt != 0 && stoppedAt < cutoff) cutoff = stoppedAt;
        if (cutoff < start) cutoff = start;
    }

    function _toTreasury(PoolId poolId, uint8 slot, uint64 epoch, address asset, uint256 amount) private {
        if (amount == 0) return;
        LibCustody.moveReservation(account(poolId, slot, epoch), LibCustody.feeAccount(), asset, amount);
        LibGlobalRewards.accrueReservedTreasuryFee(asset, amount);
    }
}
