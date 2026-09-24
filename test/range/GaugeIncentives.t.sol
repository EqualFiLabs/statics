// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IStaticsGaugeIncentives} from "../../src/interfaces/IStaticsGaugeIncentives.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {IStaticsRewardPolicy} from "../../src/interfaces/IStaticsRewardPolicy.sol";
import {GaugeIncentiveFacet} from "../../src/facets/GaugeIncentiveFacet.sol";
import {GaugeIncentiveViewFacet} from "../../src/facets/GaugeIncentiveViewFacet.sol";
import {GlobalRewardsFacet} from "../../src/facets/GlobalRewardsFacet.sol";
import {LibGaugeEpoch} from "../../src/libraries/LibGaugeEpoch.sol";
import {LibGaugeReserve} from "../../src/libraries/LibGaugeReserve.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {RangeGaugeLifecycleTestBase} from "../helpers/RangeGaugeLifecycleTestBase.sol";

contract GaugeIncentivesTest is RangeGaugeLifecycleTestBase {
    IStaticsGaugeIncentives private incentives;

    function setUp() public override {
        super.setUp();
        GaugeIncentiveFacet actions = new GaugeIncentiveFacet();
        GaugeIncentiveViewFacet views = new GaugeIncentiveViewFacet();
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](2);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(actions),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: _incentiveActionSelectors()
        });
        cut[1] = IDiamondCut.FacetCut({
            facetAddress: address(views),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: _incentiveViewSelectors()
        });
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        incentives = IStaticsGaugeIncentives(address(diamond));
    }

    function testReserveFundingMaturesAtNextEpochAndCannotDoubleCommit() public {
        _fundReserve(alice, 1_000 ether);
        IStaticsGaugeIncentives.ReserveView memory beforeBoundary = incentives.gaugeReserve();
        assertEq(beforeBoundary.available, 0);
        assertEq(beforeBoundary.deferred, 1_000 ether);
        assertEq(custody.reservedByAccount(custody.gaugeReserveCustodyAccount(), address(stakingAsset)), 1_000 ether);

        _warpNextEpoch();
        (uint64 epoch, uint256 committed, bool finalized) = incentives.checkpointGaugeEpoch();
        assertTrue(finalized);
        assertEq(committed, 0);
        IStaticsGaugeIncentives.EpochView memory state = incentives.gaugeEpoch(epoch);
        assertEq(state.nominalBudget, 40 ether);
        assertEq(state.committedBudget, 0);
        IStaticsGaugeIncentives.ReserveView memory afterBoundary = incentives.gaugeReserve();
        assertEq(afterBoundary.available, 1_000 ether);
        assertEq(afterBoundary.deferred, 0);
        assertEq(afterBoundary.committed, 0);

        (, committed, finalized) = incentives.checkpointGaugeEpoch();
        assertFalse(finalized);
        assertEq(committed, 0);
        assertEq(incentives.gaugeReserve().available, 1_000 ether);
    }

    function testAllocationValidationRejectsInvalidWeightSchedules() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        PoolId[] memory pools = new PoolId[](1);
        pools[0] = poolId;
        uint256[] memory amounts = new uint256[](0);

        vm.startPrank(alice);
        vm.expectRevert(IStaticsGaugeIncentives.GaugeAllocationLengthMismatch.selector);
        incentives.setGaugeAllocations(positionId, pools, amounts);

        PoolId[] memory excessivePools = new PoolId[](17);
        uint256[] memory excessiveAmounts = new uint256[](17);
        vm.expectRevert(abi.encodeWithSelector(IStaticsGaugeIncentives.GaugeAllocationLimitExceeded.selector, 17, 16));
        incentives.setGaugeAllocations(positionId, excessivePools, excessiveAmounts);

        amounts = new uint256[](1);
        vm.expectRevert(abi.encodeWithSelector(IStaticsGaugeIncentives.InvalidGaugeAllocation.selector, poolId, 0));
        incentives.setGaugeAllocations(positionId, pools, amounts);

        amounts[0] = 101 ether;
        vm.expectRevert(
            abi.encodeWithSelector(IStaticsGaugeIncentives.GaugeAllocationExceedsStake.selector, 101 ether, 100 ether)
        );
        incentives.setGaugeAllocations(positionId, pools, amounts);

        pools = new PoolId[](2);
        pools[0] = poolId;
        pools[1] = poolId;
        amounts = new uint256[](2);
        amounts[0] = 40 ether;
        amounts[1] = 40 ether;
        vm.expectRevert(abi.encodeWithSelector(IStaticsGaugeIncentives.DuplicateGaugeAllocation.selector, poolId));
        incentives.setGaugeAllocations(positionId, pools, amounts);
        vm.stopPrank();
    }

    function testStakeLossSyncRejectsExternalCallers() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IStaticsGaugeIncentives.GaugeSelfCallOnly.selector, alice));
        incentives.syncGaugeAllocationsAfterStakeLoss(1, 0);
    }

    function testReleaseRateChangeIsOwnerBoundedAndProspective() public {
        uint64 currentEpoch = incentives.currentGaugeEpoch();
        vm.prank(alice);
        vm.expectRevert();
        incentives.scheduleGaugeReleaseBps(500);
        vm.expectRevert(abi.encodeWithSelector(LibGaugeReserve.InvalidGaugeReleaseBps.selector, 1_001));
        incentives.scheduleGaugeReleaseBps(1_001);

        incentives.scheduleGaugeReleaseBps(500);
        IStaticsGaugeIncentives.ReserveView memory scheduled = incentives.gaugeReserve();
        assertEq(scheduled.releaseBps, 400);
        assertEq(scheduled.pendingReleaseBps, 500);
        assertEq(scheduled.pendingReleaseEpoch, currentEpoch + 1);
        assertEq(incentives.gaugeEpoch(currentEpoch).releaseBps, 400);

        _fundReserve(alice, 1_000 ether);
        _warpNextEpoch();
        (uint64 activatedEpoch,,) = incentives.checkpointGaugeEpoch();
        IStaticsGaugeIncentives.EpochView memory activated = incentives.gaugeEpoch(activatedEpoch);
        assertEq(activated.releaseBps, 500);
        assertEq(activated.nominalBudget, 50 ether);
        assertEq(incentives.gaugeReserve().releaseBps, 500);
    }

    function testLateCheckpointProratesCurrentEpochBudget() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _setAllocation(alice, positionId, poolId, 100 ether);
        _fundReserve(alice, 1_000 ether);

        uint40 boundary = LibGaugeEpoch.epochFinish(incentives.currentGaugeEpoch());
        vm.warp(uint256(boundary) + 3 days);
        (uint64 epoch, uint256 committed,) = incentives.checkpointGaugeEpoch();
        IStaticsGaugeIncentives.EpochView memory state = incentives.gaugeEpoch(epoch);
        uint256 expected = uint256(40 ether) * 4 days / 7 days;
        assertEq(state.nominalBudget, 40 ether);
        assertEq(state.activatedAt, boundary + 3 days);
        assertEq(committed, expected);
        assertEq(state.budgets[0], expected);
        assertEq(incentives.gaugeReserve().available, 1_000 ether - expected);
    }

    function testPendingAllocationsLockStakeUntilTheirRemovalBecomesActive() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);

        _setAllocation(alice, positionId, poolId, 60 ether);
        vm.prank(alice);
        (,,, IStaticsGaugeIncentives.AllocationView[] memory pending, uint256 locked) =
            incentives.gaugePositionAllocations(positionId);
        assertEq(pending.length, 1);
        assertEq(locked, 60 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GlobalRewardsFacet.InsufficientStake.selector, 41 ether, 40 ether));
        globalRewards.unstake(positionId, 41 ether, alice);
        vm.prank(alice);
        globalRewards.unstake(positionId, 40 ether, alice);

        _warpNextEpoch();
        incentives.checkpointGaugeEpoch();
        vm.prank(alice);
        incentives.setGaugeAllocations(positionId, new PoolId[](0), new uint256[](0));
        vm.prank(alice);
        (,,,, locked) = incentives.gaugePositionAllocations(positionId);
        assertEq(locked, 60 ether);

        _warpNextEpoch();
        incentives.checkpointGaugeEpoch();
        vm.prank(alice);
        (,,,, locked) = incentives.gaugePositionAllocations(positionId);
        assertEq(locked, 0);
        vm.prank(alice);
        globalRewards.unstake(positionId, 60 ether, alice);
    }

    function testTopTenUsesOnlyAllocatedStakeWithDeterministicTieBreak() public {
        PoolId[] memory pools = new PoolId[](11);
        uint256[] memory weights = new uint256[](11);
        uint256 total;
        for (uint256 i; i < pools.length; ++i) {
            MockERC20 paired = new MockERC20("Gauge Asset", "GA", 18);
            pools[i] = _createRangeGaugePool(alice, address(assetA), address(paired));
            weights[i] = (i + 1) * 10 ether;
            total += weights[i];
        }
        uint256 positionId = _createStakedPosition(alice, total);
        vm.prank(alice);
        incentives.setGaugeAllocations(positionId, pools, weights);
        _fundReserve(bob, 1_000_000 ether);

        _warpNextEpoch();
        (uint64 epoch, uint256 committed,) = incentives.checkpointGaugeEpoch();
        IStaticsGaugeIncentives.EpochView memory state = incentives.gaugeEpoch(epoch);
        assertEq(state.winnerCount, 10);
        assertEq(state.totalWeight, total - 10 ether);
        assertEq(state.committedBudget, committed);
        assertLe(committed, 40_000 ether);
        for (uint256 i; i < state.winnerCount; ++i) {
            assertEq(state.weights[i], (11 - i) * 10 ether);
        }
    }

    function testProtocolSlotEmitsToActiveLiquidityAndClaimsFromCommittedReserve() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 lpPosition = _createPosition(alice);
        _provide(lpPosition, poolId, alice);
        uint256 votingPosition = _createStakedPosition(bob, 100 ether);
        _setAllocation(bob, votingPosition, poolId, 100 ether);
        _fundReserve(bob, 1_000 ether);

        _warpNextEpoch();
        (, uint256 committed,) = incentives.checkpointGaugeEpoch();
        assertEq(committed, 40 ether);
        vm.warp(block.timestamp + 1 days);
        uint8[] memory slots = new uint8[](1);
        slots[0] = 0;
        uint256[] memory minimums = new uint256[](1);
        vm.prank(alice);
        uint256[] memory claimed = rangeGauge.claimLpRewards(lpPosition, poolId, slots, minimums, alice);
        assertApproxEqAbs(claimed[0], uint256(40 ether) / 7, 1);
        assertEq(incentives.gaugeReserve().committed, 40 ether - claimed[0]);
    }

    function testMidEpochRestrictionTerminatesAndRecyclesProtocolStream() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 lpPosition = _createPosition(alice);
        _provide(lpPosition, poolId, alice);
        uint256 votingPosition = _createStakedPosition(bob, 100 ether);
        _setAllocation(bob, votingPosition, poolId, 100 ether);
        _fundReserve(bob, 1_000 ether);

        _warpNextEpoch();
        incentives.checkpointGaugeEpoch();
        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        IStaticsRewardPolicy(address(diamond)).addRewardRestriction(address(assetA));

        uint8[] memory slots = new uint8[](1);
        slots[0] = 0;
        uint256[] memory minimums = new uint256[](1);
        vm.prank(alice);
        uint256[] memory claimed = rangeGauge.claimLpRewards(lpPosition, poolId, slots, minimums, alice);
        IStaticsRangeGauge.GaugeRewardStreamView memory stream = rangeGauge.poolRewardStream(poolId, 0);
        uint256 expectedEmission = uint256(40 ether) / 7;
        assertApproxEqAbs(stream.periodEmitted, expectedEmission, 1);
        assertEq(stream.periodEmitted + stream.periodRecycled, 40 ether);
        assertApproxEqAbs(claimed[0], expectedEmission, 1);
        assertLe(incentives.gaugeReserve().committed, 1);
        assertApproxEqAbs(incentives.gaugeReserve().deferred, 40 ether - expectedEmission, 1);
    }

    function testZeroLiquidityProtocolBudgetRecyclesAndDoesNotCarryPoolEntitlement() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _setAllocation(alice, positionId, poolId, 100 ether);
        _fundReserve(alice, 1_000 ether);

        _warpNextEpoch();
        (, uint256 committed,) = incentives.checkpointGaugeEpoch();
        assertEq(committed, 40 ether);
        vm.prank(alice);
        incentives.setGaugeAllocations(positionId, new PoolId[](0), new uint256[](0));

        _warpNextEpoch();
        incentives.checkpointGaugeEpoch();
        IStaticsRangeGauge.GaugeRewardStreamView memory stream = rangeGauge.poolRewardStream(poolId, 0);
        assertEq(stream.periodEmitted, 0);
        assertEq(stream.periodRecycled, 40 ether);
        IStaticsGaugeIncentives.ReserveView memory reserve = incentives.gaugeReserve();
        assertEq(reserve.committed, 0);
        assertEq(reserve.available, 1_000 ether);
    }

    function testRestrictionInvalidatesWeightAndRequiresExplicitRefresh() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _setAllocation(alice, positionId, poolId, 100 ether);
        _fundReserve(alice, 1_000 ether);
        vm.prank(guardian);
        IStaticsRewardPolicy(address(diamond)).addRewardRestriction(address(assetA));

        _warpNextEpoch();
        vm.expectPartialRevert(IStaticsGaugeIncentives.StaleGaugePoolWeight.selector);
        incentives.checkpointGaugeEpoch();
        assertEq(incentives.refreshGaugePoolWeight(poolId), 100 ether);
        (, uint256 committed, bool finalized) = incentives.checkpointGaugeEpoch();
        assertTrue(finalized);
        assertEq(committed, 0);
        vm.prank(alice);
        (,,,, uint256 locked) = incentives.gaugePositionAllocations(positionId);
        assertEq(locked, 0);

        IStaticsRewardPolicy(address(diamond)).removeRewardRestriction(address(assetA));
        assertEq(incentives.gaugePoolWeight(poolId).scheduledWeight, 0);

        _setAllocation(alice, positionId, poolId, 100 ether);
        assertEq(incentives.gaugePoolWeight(poolId).scheduledWeight, 100 ether);
        vm.prank(alice);
        (,,, IStaticsGaugeIncentives.AllocationView[] memory pending,) = incentives.gaugePositionAllocations(positionId);
        assertEq(pending.length, 1);
        assertEq(pending[0].eligibilityVersion, incentives.gaugePoolWeight(poolId).currentVersion);
    }

    function _createStakedPosition(address owner, uint256 amount) private returns (uint256 positionId) {
        stakingAsset.mint(owner, amount);
        vm.startPrank(owner);
        stakingAsset.approve(address(diamond), amount);
        positionId = globalRewards.createAndStake(amount, owner, new address[](0));
        vm.stopPrank();
    }

    function _setAllocation(address owner, uint256 positionId, PoolId poolId, uint256 amount) private {
        PoolId[] memory pools = new PoolId[](1);
        pools[0] = poolId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        vm.prank(owner);
        incentives.setGaugeAllocations(positionId, pools, amounts);
    }

    function _fundReserve(address funder, uint256 amount) private {
        stakingAsset.mint(funder, amount);
        vm.startPrank(funder);
        stakingAsset.approve(address(diamond), amount);
        incentives.fundGaugeReserve(amount);
        vm.stopPrank();
    }

    function _warpNextEpoch() private {
        vm.warp(LibGaugeEpoch.epochFinish(incentives.currentGaugeEpoch()));
    }

    function _incentiveActionSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = GaugeIncentiveFacet.fundGaugeReserve.selector;
        selectors[1] = GaugeIncentiveFacet.setGaugeAllocations.selector;
        selectors[2] = GaugeIncentiveFacet.checkpointGaugeEpoch.selector;
        selectors[3] = GaugeIncentiveFacet.refreshGaugePoolWeight.selector;
        selectors[4] = GaugeIncentiveFacet.scheduleGaugeReleaseBps.selector;
        selectors[5] = GaugeIncentiveFacet.syncGaugeAllocationsAfterStakeLoss.selector;
    }

    function _incentiveViewSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](9);
        selectors[0] = GaugeIncentiveViewFacet.currentGaugeEpoch.selector;
        selectors[1] = GaugeIncentiveViewFacet.gaugeEpochAt.selector;
        selectors[2] = GaugeIncentiveViewFacet.gaugeReserve.selector;
        selectors[3] = GaugeIncentiveViewFacet.gaugePoolWeight.selector;
        selectors[4] = GaugeIncentiveViewFacet.gaugePositionAllocations.selector;
        selectors[5] = GaugeIncentiveViewFacet.gaugeEpoch.selector;
        selectors[6] = GaugeIncentiveViewFacet.previewGaugeTopTen.selector;
        selectors[7] = GaugeIncentiveViewFacet.maxGaugeAllocationsPerPosition.selector;
        selectors[8] = GaugeIncentiveViewFacet.maxWeeklyGaugeReleaseBps.selector;
    }
}
