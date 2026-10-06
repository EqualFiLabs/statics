// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsBatchRewards} from "../interfaces/IStaticsBatchRewards.sol";
import {IStaticsGlobalRewards} from "../interfaces/IStaticsGlobalRewards.sol";
import {IStaticsRangeGauge} from "../interfaces/IStaticsRangeGauge.sol";
import {IStaticsGaugeIncentives} from "../interfaces/IStaticsGaugeIncentives.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/// @notice Dispatches only typed reward claims; accounting remains in the installed claim facets.
contract BatchRewardsFacet is IStaticsBatchRewards, ReentrancyGuard {
    uint256 private constant MAX_CLAIMS = 16;
    uint256 private constant MAX_ENTRIES = 64;
    bytes32 private constant BATCH_STORAGE = keccak256("statics.storage.batch.rewards.v1");

    struct BatchStorage {
        bool entered;
    }

    function _batchStorage() private pure returns (BatchStorage storage state) {
        bytes32 slot = BATCH_STORAGE;
        assembly ("memory-safe") { state.slot := slot }
    }

    // The outer dispatcher must NOT acquire the shared guard: every delegated claim acquires it.
    // Reject callbacks from an ordinary guarded action as well as callbacks from this batch.
    modifier batchGuard() {
        BatchStorage storage state = _batchStorage();
        if (state.entered || _reentrancyGuardEntered()) revert BatchClaimReentrantCall();
        state.entered = true;
        _;
        state.entered = false;
    }

    function batchClaimLimits() external pure returns (uint256 maxClaims, uint256 maxRewardEntries) {
        return (MAX_CLAIMS, MAX_ENTRIES);
    }

    function batchClaimRewards(
        GlobalClaim[] calldata globalClaims,
        PoolClaim[] calldata lpClaims,
        PoolClaim[] calldata allocatorClaims,
        address receiver
    )
        external
        batchGuard
        returns (uint256[][] memory globalReceived, uint256[][] memory lpReceived, uint256[][] memory allocatorReceived)
    {
        if (receiver == address(0) || receiver == address(this)) revert InvalidBatchReceiver(receiver);
        uint256 count = globalClaims.length + lpClaims.length + allocatorClaims.length;
        if (count == 0) revert EmptyRewardBatch();
        if (count > MAX_CLAIMS) revert BatchClaimLimitExceeded(count, MAX_CLAIMS);
        uint256 entries = _validateGlobals(globalClaims);
        entries += _validatePools(lpClaims, false);
        entries += _validatePools(allocatorClaims, true);
        if (entries > MAX_ENTRIES) revert BatchRewardEntryLimitExceeded(entries, MAX_ENTRIES);

        globalReceived = new uint256[][](globalClaims.length);
        for (uint256 i; i < globalClaims.length; ++i) {
            GlobalClaim calldata item = globalClaims[i];
            globalReceived[i] = _dispatch(
                IStaticsGlobalRewards.claimRewards.selector,
                abi.encodeCall(
                    IStaticsGlobalRewards.claimRewards, (item.positionId, item.assets, receiver, item.minimumAmounts)
                )
            );
        }
        lpReceived = _claimPools(lpClaims, receiver, false);
        allocatorReceived = _claimPools(allocatorClaims, receiver, true);
    }

    function _validateGlobals(GlobalClaim[] calldata claims) private pure returns (uint256 entries) {
        for (uint256 i; i < claims.length; ++i) {
            GlobalClaim calldata item = claims[i];
            for (uint256 prior; prior < i; ++prior) {
                if (claims[prior].positionId == item.positionId) revert DuplicateGlobalClaim(item.positionId);
            }
            uint256 length = item.assets.length;
            if (length == 0) revert EmptyRewardClaim();
            if (length != item.minimumAmounts.length) revert BatchRewardLengthMismatch();
            entries += length;
            if (entries > MAX_ENTRIES) revert BatchRewardEntryLimitExceeded(entries, MAX_ENTRIES);
            for (uint256 j; j < length; ++j) {
                for (uint256 prior; prior < j; ++prior) {
                    if (item.assets[prior] == item.assets[j]) revert DuplicateBatchRewardAsset(item.assets[j]);
                }
            }
        }
    }

    function _validatePools(PoolClaim[] calldata claims, bool allocator) private pure returns (uint256 entries) {
        for (uint256 i; i < claims.length; ++i) {
            PoolClaim calldata item = claims[i];
            for (uint256 prior; prior < i; ++prior) {
                if (claims[prior].positionId == item.positionId && claims[prior].poolId == item.poolId) {
                    revert DuplicatePoolClaim(item.positionId, item.poolId);
                }
            }
            uint256 length = item.slots.length;
            if (length == 0) revert EmptyRewardClaim();
            if (length != item.minimumAmounts.length) revert BatchRewardLengthMismatch();
            entries += length;
            if (entries > MAX_ENTRIES) revert BatchRewardEntryLimitExceeded(entries, MAX_ENTRIES);
            uint256 seen;
            for (uint256 j; j < length; ++j) {
                uint8 slot = item.slots[j];
                if (slot > 4 || (allocator && slot == 0)) revert InvalidBatchRewardSlot(slot);
                uint256 mask = 1 << slot;
                if (seen & mask != 0) revert DuplicateBatchRewardSlot(slot);
                seen |= mask;
            }
        }
    }

    function _claimPools(PoolClaim[] calldata claims, address receiver, bool allocator)
        private
        returns (uint256[][] memory received)
    {
        received = new uint256[][](claims.length);
        for (uint256 i; i < claims.length; ++i) {
            PoolClaim calldata item = claims[i];
            bytes4 selector = allocator
                ? IStaticsGaugeIncentives.claimGaugeAllocatorRewards.selector
                : IStaticsRangeGauge.claimLpRewards.selector;
            received[i] = _dispatch(
                selector,
                abi.encodeWithSelector(
                    selector, item.positionId, PoolId.wrap(item.poolId), item.slots, item.minimumAmounts, receiver
                )
            );
        }
    }

    function _dispatch(bytes4 selector, bytes memory data) private returns (uint256[] memory received) {
        address facet = LibDiamond.diamondStorage().selectorToFacetAndPosition[selector].facetAddress;
        if (facet.code.length == 0) revert BatchClaimRouteUnavailable(selector);
        (bool success, bytes memory result) = facet.delegatecall(data);
        if (!success) {
            assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
        received = abi.decode(result, (uint256[]));
    }
}
