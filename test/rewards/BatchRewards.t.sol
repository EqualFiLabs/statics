// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StaticsDiamond} from "../../src/diamond/StaticsDiamond.sol";
import {BatchRewardsFacet} from "../../src/facets/BatchRewardsFacet.sol";
import {DiamondCutFacet} from "../../src/facets/DiamondCutFacet.sol";
import {IStaticsBatchRewards} from "../../src/interfaces/IStaticsBatchRewards.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {IStaticsGaugeIncentives} from "../../src/interfaces/IStaticsGaugeIncentives.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";

// Narrow synthetic dispatch harness. Real reward transfers are covered separately.
contract BatchDispatchProbe is ReentrancyGuard {
    error ProbeFailure(uint256 positionId);
    error WrongCaller(address caller);
    bytes32 private constant SLOT = keccak256("statics.test.batch.dispatch");

    function _claim(uint256 id, uint256[] calldata minimums, uint256 kind) private returns (uint256[] memory out) {
        if (msg.sender != address(0xA11CE)) revert WrongCaller(msg.sender);
        if (id == 99) revert ProbeFailure(id);
        uint256 prior;
        bytes32 slot = SLOT;
        assembly {
            prior := sload(slot)
            sstore(slot, add(mul(prior, 10), kind))
        }
        out = new uint256[](minimums.length);
        for (uint256 i; i < out.length; ++i) {
            out[i] = minimums[i] + id;
        }
    }

    function claimRewards(uint256 id, address[] calldata, address, uint256[] calldata minimums)
        external
        nonReentrant
        returns (uint256[] memory)
    {
        return _claim(id, minimums, 1);
    }

    function claimLpRewards(uint256 id, PoolId, uint8[] calldata, uint256[] calldata minimums, address)
        external
        nonReentrant
        returns (uint256[] memory)
    {
        return _claim(id, minimums, 2);
    }

    function claimGaugeAllocatorRewards(uint256 id, PoolId, uint8[] calldata, uint256[] calldata minimums, address)
        external
        nonReentrant
        returns (uint256[] memory)
    {
        return _claim(id, minimums, 3);
    }
}

contract BatchProbeInit {
    function init(address batch, address probe, address cut) external {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = IStaticsBatchRewards.batchClaimRewards.selector;
        selectors[1] = IStaticsBatchRewards.batchClaimLimits.selector;
        LibDiamond.addFunctions(batch, selectors);
        selectors = new bytes4[](3);
        selectors[0] = IStaticsGlobalRewards.claimRewards.selector;
        selectors[1] = IStaticsRangeGauge.claimLpRewards.selector;
        selectors[2] = IStaticsGaugeIncentives.claimGaugeAllocatorRewards.selector;
        LibDiamond.addFunctions(probe, selectors);
        selectors = new bytes4[](1);
        selectors[0] = IDiamondCut.diamondCut.selector;
        LibDiamond.addFunctions(cut, selectors);
    }
}

contract BatchRewardsTest is Test {
    IStaticsBatchRewards private batch;
    address private constant ALICE = address(0xA11CE);
    bytes32 private constant PROBE_SLOT = keccak256("statics.test.batch.dispatch");

    function setUp() public {
        BatchProbeInit init = new BatchProbeInit();
        batch = IStaticsBatchRewards(
            address(
                new StaticsDiamond(
                    address(this),
                    address(0),
                    address(init),
                    abi.encodeCall(
                        init.init,
                        (
                            address(new BatchRewardsFacet()),
                            address(new BatchDispatchProbe()),
                            address(new DiamondCutFacet())
                        )
                    )
                )
            )
        );
    }

    function _global(uint256 id, uint256 count) private pure returns (IStaticsBatchRewards.GlobalClaim memory c) {
        c.positionId = id;
        c.assets = new address[](count);
        c.minimumAmounts = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            c.assets[i] = address(uint160(i + 1));
            c.minimumAmounts[i] = i + 10;
        }
    }

    function _pool(uint256 id, uint256 slot) private pure returns (IStaticsBatchRewards.PoolClaim memory c) {
        c.positionId = id;
        c.poolId = bytes32(id);
        c.slots = new uint8[](1);
        c.slots[0] = uint8(slot);
        c.minimumAmounts = new uint256[](1);
        c.minimumAmounts[0] = 20;
    }

    function _call(
        IStaticsBatchRewards.GlobalClaim[] memory g,
        IStaticsBatchRewards.PoolClaim[] memory l,
        IStaticsBatchRewards.PoolClaim[] memory a
    ) private {
        vm.prank(ALICE);
        batch.batchClaimRewards(g, l, a, ALICE);
    }

    function testDispatchPreservesCallerCategoryAndResultOrder() public {
        IStaticsBatchRewards.GlobalClaim[] memory g = new IStaticsBatchRewards.GlobalClaim[](2);
        g[0] = _global(1, 2);
        g[1] = _global(2, 1);
        IStaticsBatchRewards.PoolClaim[] memory l = new IStaticsBatchRewards.PoolClaim[](1);
        l[0] = _pool(3, 0);
        IStaticsBatchRewards.PoolClaim[] memory a = new IStaticsBatchRewards.PoolClaim[](1);
        a[0] = _pool(3, 1);
        vm.prank(ALICE);
        (uint256[][] memory gr, uint256[][] memory lr, uint256[][] memory ar) = batch.batchClaimRewards(g, l, a, ALICE);
        assertEq(gr[0][0], 11);
        assertEq(gr[0][1], 12);
        assertEq(gr[1][0], 12);
        assertEq(lr[0][0], 23);
        assertEq(ar[0][0], 23);
        assertEq(uint256(vm.load(address(batch), PROBE_SLOT)), 1123);
    }

    function testLateFailureRollsBackAndLockRecovers() public {
        IStaticsBatchRewards.GlobalClaim[] memory g = new IStaticsBatchRewards.GlobalClaim[](2);
        g[0] = _global(1, 1);
        g[1] = _global(99, 1);
        vm.expectRevert(abi.encodeWithSelector(BatchDispatchProbe.ProbeFailure.selector, 99));
        _call(g, new IStaticsBatchRewards.PoolClaim[](0), new IStaticsBatchRewards.PoolClaim[](0));
        assertEq(vm.load(address(batch), PROBE_SLOT), bytes32(0));
        g[1].positionId = 2;
        _call(g, new IStaticsBatchRewards.PoolClaim[](0), new IStaticsBatchRewards.PoolClaim[](0));
        assertEq(uint256(vm.load(address(batch), PROBE_SLOT)), 11);
    }

    function testRejectsEmptyAndInvalidReceiver() public {
        IStaticsBatchRewards.GlobalClaim[] memory g = new IStaticsBatchRewards.GlobalClaim[](0);
        IStaticsBatchRewards.PoolClaim[] memory p = new IStaticsBatchRewards.PoolClaim[](0);
        vm.expectRevert(IStaticsBatchRewards.EmptyRewardBatch.selector);
        _call(g, p, p);
        vm.expectRevert(abi.encodeWithSelector(IStaticsBatchRewards.InvalidBatchReceiver.selector, address(batch)));
        batch.batchClaimRewards(g, p, p, address(batch));
        vm.expectRevert(abi.encodeWithSelector(IStaticsBatchRewards.InvalidBatchReceiver.selector, address(0)));
        batch.batchClaimRewards(g, p, p, address(0));
    }

    function testRejectsMalformedAndDuplicateGlobals() public {
        IStaticsBatchRewards.GlobalClaim[] memory g = new IStaticsBatchRewards.GlobalClaim[](2);
        g[0] = _global(1, 1);
        g[1] = _global(1, 1);
        IStaticsBatchRewards.PoolClaim[] memory p = new IStaticsBatchRewards.PoolClaim[](0);
        vm.expectRevert(abi.encodeWithSelector(IStaticsBatchRewards.DuplicateGlobalClaim.selector, 1));
        _call(g, p, p);
        g = new IStaticsBatchRewards.GlobalClaim[](1);
        g[0] = _global(1, 0);
        vm.expectRevert(IStaticsBatchRewards.EmptyRewardClaim.selector);
        _call(g, p, p);
        g[0] = _global(1, 2);
        g[0].minimumAmounts = new uint256[](1);
        vm.expectRevert(IStaticsBatchRewards.BatchRewardLengthMismatch.selector);
        _call(g, p, p);
        g[0] = _global(1, 2);
        g[0].assets[1] = g[0].assets[0];
        vm.expectRevert(abi.encodeWithSelector(IStaticsBatchRewards.DuplicateBatchRewardAsset.selector, address(1)));
        _call(g, p, p);
    }

    function testRejectsDuplicatePoolsAndSlotsInBothCategories() public {
        IStaticsBatchRewards.GlobalClaim[] memory g = new IStaticsBatchRewards.GlobalClaim[](0);
        IStaticsBatchRewards.PoolClaim[] memory p = new IStaticsBatchRewards.PoolClaim[](2);
        IStaticsBatchRewards.PoolClaim[] memory empty = new IStaticsBatchRewards.PoolClaim[](0);
        p[0] = _pool(1, 1);
        p[1] = _pool(1, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IStaticsBatchRewards.DuplicatePoolClaim.selector, 1, bytes32(uint256(1)))
        );
        _call(g, p, empty);
        vm.expectRevert(
            abi.encodeWithSelector(IStaticsBatchRewards.DuplicatePoolClaim.selector, 1, bytes32(uint256(1)))
        );
        _call(g, empty, p);
        p = new IStaticsBatchRewards.PoolClaim[](1);
        p[0] = _pool(1, 1);
        p[0].slots = new uint8[](2);
        p[0].slots[0] = 1;
        p[0].slots[1] = 1;
        p[0].minimumAmounts = new uint256[](2);
        vm.expectRevert(abi.encodeWithSelector(IStaticsBatchRewards.DuplicateBatchRewardSlot.selector, uint8(1)));
        _call(g, p, empty);
        vm.expectRevert(abi.encodeWithSelector(IStaticsBatchRewards.DuplicateBatchRewardSlot.selector, uint8(1)));
        _call(g, empty, p);
    }

    function testLimitsAndInvalidSlots() public {
        (uint256 groups, uint256 entries) = batch.batchClaimLimits();
        assertEq(groups, 16);
        assertEq(entries, 64);
        IStaticsBatchRewards.GlobalClaim[] memory g = new IStaticsBatchRewards.GlobalClaim[](17);
        IStaticsBatchRewards.PoolClaim[] memory p = new IStaticsBatchRewards.PoolClaim[](0);
        vm.expectRevert(abi.encodeWithSelector(IStaticsBatchRewards.BatchClaimLimitExceeded.selector, 17, 16));
        _call(g, p, p);
        g = new IStaticsBatchRewards.GlobalClaim[](1);
        g[0] = _global(1, 65);
        vm.expectRevert(abi.encodeWithSelector(IStaticsBatchRewards.BatchRewardEntryLimitExceeded.selector, 65, 64));
        _call(g, p, p);
        g[0] = _global(1, 64);
        _call(g, p, p);
        g = new IStaticsBatchRewards.GlobalClaim[](0);
        p = new IStaticsBatchRewards.PoolClaim[](1);
        p[0] = _pool(1, 5);
        vm.expectRevert(abi.encodeWithSelector(IStaticsBatchRewards.InvalidBatchRewardSlot.selector, uint8(5)));
        _call(g, p, new IStaticsBatchRewards.PoolClaim[](0));
        p[0] = _pool(1, 0);
        vm.expectRevert(abi.encodeWithSelector(IStaticsBatchRewards.InvalidBatchRewardSlot.selector, uint8(0)));
        _call(g, new IStaticsBatchRewards.PoolClaim[](0), p);
    }

    function testUnavailableRoute() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IStaticsGlobalRewards.claimRewards.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, selectors);
        IDiamondCut(address(batch)).diamondCut(cut, address(0), "");
        IStaticsBatchRewards.GlobalClaim[] memory g = new IStaticsBatchRewards.GlobalClaim[](1);
        g[0] = _global(1, 1);
        vm.expectRevert(abi.encodeWithSelector(IStaticsBatchRewards.BatchClaimRouteUnavailable.selector, selectors[0]));
        _call(g, new IStaticsBatchRewards.PoolClaim[](0), new IStaticsBatchRewards.PoolClaim[](0));
    }

    function testSharedGuardRejectsEntry() public {
        bytes32 guardSlot = 0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;
        vm.store(address(batch), guardSlot, bytes32(uint256(2)));
        vm.expectRevert(IStaticsBatchRewards.BatchClaimReentrantCall.selector);
        _call(
            new IStaticsBatchRewards.GlobalClaim[](0),
            new IStaticsBatchRewards.PoolClaim[](0),
            new IStaticsBatchRewards.PoolClaim[](0)
        );
        assertEq(vm.load(address(batch), guardSlot), bytes32(uint256(2)));
    }
}
