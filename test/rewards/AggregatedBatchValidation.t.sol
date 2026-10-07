// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {BatchRewardsFacet} from "../../src/facets/BatchRewardsFacet.sol";
import {IStaticsBatchRewards} from "../../src/interfaces/IStaticsBatchRewards.sol";
import {IStaticsAggregatedBatchRewards} from "../../src/interfaces/IStaticsAggregatedBatchRewards.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";

// Input/route validation only; real funded claims and rollback are covered in lifecycle tests.
contract AggregatedBatchValidationTest is Test {
    BatchRewardsFacet private facet;
    address private constant ALICE = address(0xA11CE);

    function setUp() public {
        facet = new BatchRewardsFacet();
    }

    function _global(uint256 entries) private pure returns (IStaticsBatchRewards.GlobalClaim memory claim) {
        claim.positionId = 1;
        claim.assets = new address[](entries);
        claim.minimumAmounts = new uint256[](entries);
        for (uint256 i; i < entries; ++i) {
            claim.assets[i] = address(uint160(i + 1));
        }
    }

    function _sameFailure(
        IStaticsBatchRewards.GlobalClaim[] memory global,
        IStaticsBatchRewards.PoolClaim[] memory lp,
        IStaticsBatchRewards.PoolClaim[] memory allocator,
        address receiver,
        bytes memory expected
    ) private {
        vm.prank(ALICE);
        (bool ok, bytes memory result) = address(facet)
            .call(abi.encodeCall(IStaticsBatchRewards.batchClaimRewards, (global, lp, allocator, receiver)));
        assertFalse(ok);
        assertEq(result, expected);
        vm.prank(ALICE);
        (ok, result) = address(facet)
            .call(
                abi.encodeCall(
                    IStaticsAggregatedBatchRewards.batchClaimRewardsAggregated, (global, lp, allocator, receiver)
                )
            );
        assertFalse(ok);
        assertEq(result, expected);
    }

    function testEmptyGroupsArraysReceiversAndDuplicateAssetsMatchLegacy() public {
        IStaticsBatchRewards.GlobalClaim[] memory g = new IStaticsBatchRewards.GlobalClaim[](0);
        IStaticsBatchRewards.PoolClaim[] memory p = new IStaticsBatchRewards.PoolClaim[](0);
        _sameFailure(g, p, p, ALICE, abi.encodeWithSelector(IStaticsBatchRewards.EmptyRewardBatch.selector));
        _sameFailure(
            g, p, p, address(0), abi.encodeWithSelector(IStaticsBatchRewards.InvalidBatchReceiver.selector, address(0))
        );
        _sameFailure(
            g,
            p,
            p,
            address(facet),
            abi.encodeWithSelector(IStaticsBatchRewards.InvalidBatchReceiver.selector, address(facet))
        );
        g = new IStaticsBatchRewards.GlobalClaim[](1);
        g[0] = _global(0);
        _sameFailure(g, p, p, ALICE, abi.encodeWithSelector(IStaticsBatchRewards.EmptyRewardClaim.selector));
        g[0] = _global(1);
        g[0].minimumAmounts = new uint256[](0);
        _sameFailure(g, p, p, ALICE, abi.encodeWithSelector(IStaticsBatchRewards.BatchRewardLengthMismatch.selector));
        g[0] = _global(2);
        g[0].assets[1] = g[0].assets[0];
        _sameFailure(
            g, p, p, ALICE, abi.encodeWithSelector(IStaticsBatchRewards.DuplicateBatchRewardAsset.selector, address(1))
        );
        g = new IStaticsBatchRewards.GlobalClaim[](2);
        g[0] = _global(1);
        g[1] = _global(1);
        _sameFailure(
            g, p, p, ALICE, abi.encodeWithSelector(IStaticsBatchRewards.DuplicateGlobalClaim.selector, uint256(1))
        );
    }

    function testPoolDuplicatesAndSlotRulesMatchLegacy() public {
        IStaticsBatchRewards.GlobalClaim[] memory g = new IStaticsBatchRewards.GlobalClaim[](0);
        IStaticsBatchRewards.PoolClaim[] memory p = new IStaticsBatchRewards.PoolClaim[](1);
        IStaticsBatchRewards.PoolClaim[] memory empty = new IStaticsBatchRewards.PoolClaim[](0);
        uint8[] memory slots = new uint8[](1);
        slots[0] = 5;
        p[0] = IStaticsBatchRewards.PoolClaim(1, bytes32(uint256(1)), slots, new uint256[](1));
        _sameFailure(
            g, p, empty, ALICE, abi.encodeWithSelector(IStaticsBatchRewards.InvalidBatchRewardSlot.selector, uint8(5))
        );
        p[0].slots[0] = 0;
        _sameFailure(
            g, empty, p, ALICE, abi.encodeWithSelector(IStaticsBatchRewards.InvalidBatchRewardSlot.selector, uint8(0))
        );
        slots = new uint8[](2);
        slots[0] = 1;
        slots[1] = 1;
        p[0].slots = slots;
        p[0].minimumAmounts = new uint256[](2);
        _sameFailure(
            g, p, empty, ALICE, abi.encodeWithSelector(IStaticsBatchRewards.DuplicateBatchRewardSlot.selector, uint8(1))
        );
        slots = new uint8[](1);
        slots[0] = 1;
        p[0].slots = slots;
        p[0].minimumAmounts = new uint256[](1);
        IStaticsBatchRewards.PoolClaim[] memory duplicate = new IStaticsBatchRewards.PoolClaim[](2);
        duplicate[0] = p[0];
        duplicate[1] = p[0];
        _sameFailure(
            g,
            duplicate,
            empty,
            ALICE,
            abi.encodeWithSelector(IStaticsBatchRewards.DuplicatePoolClaim.selector, uint256(1), bytes32(uint256(1)))
        );
        _sameFailure(
            g,
            empty,
            duplicate,
            ALICE,
            abi.encodeWithSelector(IStaticsBatchRewards.DuplicatePoolClaim.selector, uint256(1), bytes32(uint256(1)))
        );
    }

    function testLimitsUnavailableRoutesAndCaughtRevertCleanupMatchLegacy() public {
        IStaticsBatchRewards.PoolClaim[] memory p = new IStaticsBatchRewards.PoolClaim[](0);
        IStaticsBatchRewards.GlobalClaim[] memory g = new IStaticsBatchRewards.GlobalClaim[](17);
        _sameFailure(
            g,
            p,
            p,
            ALICE,
            abi.encodeWithSelector(IStaticsBatchRewards.BatchClaimLimitExceeded.selector, uint256(17), uint256(16))
        );
        g = new IStaticsBatchRewards.GlobalClaim[](1);
        g[0] = _global(65);
        _sameFailure(
            g,
            p,
            p,
            ALICE,
            abi.encodeWithSelector(
                IStaticsBatchRewards.BatchRewardEntryLimitExceeded.selector, uint256(65), uint256(64)
            )
        );
        g = new IStaticsBatchRewards.GlobalClaim[](16);
        for (uint256 i; i < 16; ++i) {
            g[i] = _global(4);
            g[i].positionId = i + 1;
        }
        bytes memory unavailable = abi.encodeWithSelector(
            IStaticsBatchRewards.BatchClaimRouteUnavailable.selector, IStaticsGlobalRewards.claimRewards.selector
        );
        _sameFailure(g, p, p, ALICE, unavailable);
        g = new IStaticsBatchRewards.GlobalClaim[](1);
        g[0] = _global(1);
        _sameFailure(g, p, p, ALICE, unavailable);
    }
}
