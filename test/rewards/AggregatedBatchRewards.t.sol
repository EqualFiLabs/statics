// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {BatchRewardsLifecycleTest} from "./BatchRewardsLifecycle.t.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibPosition} from "../../src/position/LibPosition.sol";
import {IStaticsGaugeIncentives} from "../../src/interfaces/IStaticsGaugeIncentives.sol";
import {Vm} from "forge-std/Vm.sol";
import {IStaticsBatchRewards} from "../../src/interfaces/IStaticsBatchRewards.sol";
import {IStaticsAggregatedBatchRewards} from "../../src/interfaces/IStaticsAggregatedBatchRewards.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {BatchRewardsFacet} from "../../src/facets/BatchRewardsFacet.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LibRewardPayout} from "../../src/libraries/LibRewardPayout.sol";
import {
    MockERC20,
    MockFeeOnTransferERC20,
    MockReentrantERC20,
    MockRevertingERC20,
    MockSenderExtraFeeERC20
} from "../mocks/MockERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

// Deliberately obsolete route: no aggregation acknowledgement, even for a zero result.
contract UnacknowledgedRewardRoute {
    function claimLpRewards(uint256, PoolId, uint8[] calldata slots, uint256[] calldata, address)
        external
        pure
        returns (uint256[] memory)
    {
        return new uint256[](slots.length);
    }
}

contract AggregatedBatchRewardsTest is BatchRewardsLifecycleTest {
    IStaticsAggregatedBatchRewards internal aggregated;
    bytes32 private constant TRANSFER = keccak256("Transfer(address,address,uint256)");

    function setUp() public override {
        super.setUp();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IStaticsAggregatedBatchRewards.batchClaimRewardsAggregated.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut(address(new BatchRewardsFacet()), IDiamondCut.FacetCutAction.Add, selectors);
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        aggregated = IStaticsAggregatedBatchRewards(address(diamond));
    }

    function _aggregatedLp(IStaticsBatchRewards.PoolClaim[] memory claims) internal returns (uint256[][] memory out) {
        vm.prank(alice);
        (, out,) = aggregated.batchClaimRewardsAggregated(
            new IStaticsBatchRewards.GlobalClaim[](0), claims, new IStaticsBatchRewards.PoolClaim[](0), alice
        );
    }

    function _aggregatedMixed() internal returns (bytes memory) {
        vm.prank(alice);
        (uint256[][] memory g, uint256[][] memory l, uint256[][] memory a) =
            aggregated.batchClaimRewardsAggregated(_globals(), _pools(false), _pools(true), bob);
        return abi.encode(g, l, a);
    }

    function _payoutTransfers(Vm.Log[] memory logs) internal view returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].topics.length == 3 && logs[i].topics[0] == TRANSFER
                    && logs[i].topics[1] == bytes32(uint256(uint160(address(diamond))))
            ) ++count;
        }
    }

    function testAggregatedMixedMatchesIndividualStateAndResults() public {
        _mixedState();
        uint256 snapshot = vm.snapshotState();
        bytes memory expected = _individual();
        bytes32 state = _accountingHash();
        vm.revertToState(snapshot);
        vm.recordLogs();
        assertEq(_aggregatedMixed(), expected);
        assertEq(_accountingHash(), state);
        assertEq(_payoutTransfers(vm.getRecordedLogs()), 4);
        assertEq(custody.reservedByAccount(LibRewardPayout.ACCOUNT, address(reward)), 0);
    }

    function testAggregatedLateMinimumRollsBackStagingAndRecovers() public {
        _mixedState();
        bytes32 beforeState = _accountingHash();
        IStaticsBatchRewards.PoolClaim[] memory a = _pools(true);
        a[1].minimumAmounts[0] = type(uint256).max;
        vm.prank(alice);
        vm.expectPartialRevert(bytes4(keccak256("GaugeAllocatorAmountBelowMinimum(address,uint256,uint256)")));
        aggregated.batchClaimRewardsAggregated(_globals(), _pools(false), a, bob);
        assertEq(_accountingHash(), beforeState);
        assertEq(custody.reservedByAccount(LibRewardPayout.ACCOUNT, address(reward)), 0);
        assertGt(_aggregatedMixed().length, 0);
    }

    function testAggregatedTaxedReceiptRevertsAndLegacyClaimStillWorks() public {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _createPosition(alice);
        _provide(id, pool, alice);
        MockFeeOnTransferERC20 taxed = new MockFeeOnTransferERC20();
        uint8 slot = _bribe(pool, taxed, 0);
        vm.warp(block.timestamp + 1 days);
        IStaticsBatchRewards.PoolClaim[] memory claims = _poolClaims(id, pool, _slots(slot, false));
        uint256 reserved = custody.globalReservedByToken(address(taxed));
        vm.expectPartialRevert(IStaticsAggregatedBatchRewards.IncompatibleAggregatedRewardTransfer.selector);
        _aggregatedLp(claims);
        assertEq(taxed.balanceOf(alice), 0);
        assertEq(custody.globalReservedByToken(address(taxed)), reserved);
        assertEq(custody.reservedByAccount(LibRewardPayout.ACCOUNT, address(taxed)), 0);
        assertGt(_lpBatch(claims)[0][0], 0);
    }

    function testAggregatedZeroEntryAndConsecutiveCalls() public {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _createPosition(alice);
        _provide(id, pool, alice);
        MockERC20 token = new MockERC20("Reward", "RWD", 18);
        uint8 slot = _bribe(pool, token, 0);
        vm.warp(block.timestamp + 1 days);
        IStaticsBatchRewards.PoolClaim[] memory claims = _poolClaims(id, pool, _slots(slot, true));
        uint256[][] memory out = _aggregatedLp(claims);
        assertEq(out[0][0], 0);
        assertGt(out[0][1], 0);
        vm.recordLogs();
        out = _aggregatedLp(claims);
        assertEq(out[0][0], 0);
        assertEq(out[0][1], 0);
        assertEq(_payoutTransfers(vm.getRecordedLogs()), 0);
    }

    function _callback(bytes memory data, bytes4 expected) internal {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _createPosition(alice);
        _provide(id, pool, alice);
        MockReentrantERC20 token = new MockReentrantERC20();
        uint8 slot = _bribe(pool, token, 0);
        vm.warp(block.timestamp + 1 days);
        token.setCallback(address(diamond), address(diamond), data);
        assertGt(_aggregatedLp(_poolClaims(id, pool, _slots(slot, false)))[0][0], 0);
        assertFalse(token.reentrySucceeded());
        assertEq(bytes4(token.reentryResult()), expected);
        token.setCallback(address(0), address(0), "");
        vm.warp(block.timestamp + 1 days);
        assertGt(_aggregatedLp(_poolClaims(id, pool, _slots(slot, false)))[0][0], 0);
    }

    function testAggregatedCallbackCannotEnterEitherBatch() public {
        uint256 snapshot = vm.snapshotState();
        _callback(
            abi.encodeCall(
                IStaticsAggregatedBatchRewards.batchClaimRewardsAggregated,
                (
                    new IStaticsBatchRewards.GlobalClaim[](0),
                    new IStaticsBatchRewards.PoolClaim[](0),
                    new IStaticsBatchRewards.PoolClaim[](0),
                    alice
                )
            ),
            IStaticsBatchRewards.BatchClaimReentrantCall.selector
        );
        vm.revertToState(snapshot);
        _callback(_nestedBatch(), IStaticsBatchRewards.BatchClaimReentrantCall.selector);
    }

    function testAggregatedCallbackCannotEnterClaimsOrCustody() public {
        uint256 snapshot = vm.snapshotState();
        _callback(
            abi.encodeCall(IStaticsGlobalRewards.claimRewards, (uint256(1), new address[](0), alice, new uint256[](0))),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector
        );
        vm.revertToState(snapshot);
        _callback(
            abi.encodeCall(IStaticsGlobalRewards.unstake, (uint256(1), uint256(1), alice)),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector
        );
    }

    function testObservedSixtyFourPayoutsBecomeThirteen() public {
        MockERC20[] memory tokens = new MockERC20[](13);
        for (uint256 i; i < 13; ++i) {
            tokens[i] = new MockERC20("Reward", "RWD", 18);
        }
        IStaticsBatchRewards.PoolClaim[] memory claims = new IStaticsBatchRewards.PoolClaim[](16);
        for (uint256 i; i < 16; ++i) {
            MockERC20 pair = new MockERC20("Pair", "PAIR", 18);
            PoolId pool = _createRangeGaugePool(alice, address(assetA), address(pair));
            uint256 id = _createPosition(alice);
            _provide(id, pool, alice);
            uint8[] memory slots = new uint8[](4);
            for (uint256 j; j < 4; ++j) {
                slots[j] = _bribe(pool, tokens[j < 3 ? j : 3 + i % 10], 0);
            }
            claims[i] = IStaticsBatchRewards.PoolClaim(id, PoolId.unwrap(pool), slots, new uint256[](4));
        }
        vm.warp(block.timestamp + 7 days);
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        uint256 start = gasleft();
        uint256[][] memory expected = _lpBatch(claims);
        uint256 legacyGas = start - gasleft();
        assertEq(_payoutTransfers(vm.getRecordedLogs()), 64);
        uint256[] memory balances = new uint256[](13);
        for (uint256 i; i < 13; ++i) {
            balances[i] = tokens[i].balanceOf(alice);
        }
        vm.revertToState(snapshot);
        vm.recordLogs();
        start = gasleft();
        uint256[][] memory out = _aggregatedLp(claims);
        uint256 aggregateGas = start - gasleft();
        assertEq(abi.encode(out), abi.encode(expected));
        assertEq(_payoutTransfers(vm.getRecordedLogs()), 13);
        for (uint256 i; i < 13; ++i) {
            assertEq(tokens[i].balanceOf(alice), balances[i]);
            assertEq(custody.reservedByAccount(LibRewardPayout.ACCOUNT, address(tokens[i])), 0);
            assertGe(tokens[i].balanceOf(address(diamond)), custody.globalReservedByToken(address(tokens[i])));
        }
        emit log_named_uint("64 entries / 13 tokens legacy gas", legacyGas);
        emit log_named_uint("64 entries / 13 tokens aggregate gas", aggregateGas);
        assertLt(aggregateGas, legacyGas);
    }

    function testAggregatedRejectsUnacknowledgedZeroRoute() public {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _createPosition(alice);
        _provide(id, pool, alice);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IStaticsRangeGauge.claimLpRewards.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] =
            IDiamondCut.FacetCut(
            address(new UnacknowledgedRewardRoute()), IDiamondCut.FacetCutAction.Replace, selectors
        );
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticsAggregatedBatchRewards.AggregatedClaimRouteIncompatible.selector, selectors[0]
            )
        );
        _aggregatedLp(_poolClaims(id, pool, _slots(0, false)));
    }

    function testAggregatedAuthorizationAndTransferredNftRollback() public {
        _mixedState();
        vm.prank(bob);
        vm.expectPartialRevert(LibPosition.NotPositionOwnerOrApproved.selector);
        aggregated.batchClaimRewardsAggregated(_globals(), _pools(false), _pools(true), bob);
        vm.prank(alice);
        IERC721(address(diamond)).setApprovalForAll(bob, true);
        uint256 snapshot = vm.snapshotState();
        vm.prank(bob);
        (uint256[][] memory g, uint256[][] memory l, uint256[][] memory a) =
            aggregated.batchClaimRewardsAggregated(_globals(), _pools(false), _pools(true), bob);
        assertGt(g[0][0] + l[0][0] + a[0][0], 0);
        vm.revertToState(snapshot);
        vm.prank(alice);
        IERC721(address(diamond)).transferFrom(alice, bob, secondId);
        bytes32 state = _accountingHash();
        vm.expectPartialRevert(LibPosition.NotPositionOwnerOrApproved.selector);
        _aggregatedMixed();
        assertEq(_accountingHash(), state);
    }

    function testAggregatedRetainedClaimsResolveAfterExitAndAllocationClear() public {
        firstPool = _createRangeGaugePool(alice);
        firstId = _stake(alice, new address[](0));
        _provide(firstId, firstPool, alice);
        _allocate(firstId, firstPool);
        reward = new MockERC20("Reward", "RWD", 18);
        _bribe(firstPool, reward, 5000);
        vm.warp(block.timestamp + 3.5 days);
        _exit(firstId, firstPool, alice);
        vm.prank(alice);
        incentives.setGaugeAllocations(firstId, new PoolId[](0), new uint256[](0));
        IStaticsBatchRewards.PoolClaim[] memory claims = _poolClaims(firstId, firstPool, _slots(1, false));
        vm.recordLogs();
        vm.prank(alice);
        (, uint256[][] memory l, uint256[][] memory a) =
            aggregated.batchClaimRewardsAggregated(new IStaticsBatchRewards.GlobalClaim[](0), claims, claims, alice);
        assertApproxEqAbs(l[0][0], 25 ether, 2);
        assertApproxEqAbs(a[0][0], 25 ether, 2);
        assertEq(_payoutTransfers(vm.getRecordedLogs()), 1);
        (PoolId[] memory pools,) = rangeGauge.positionGaugePools(firstId, 0, 100);
        assertEq(pools.length, 0);
        (pools,) = incentives.positionGaugeAllocatorPools(firstId, 0, 100);
        assertEq(pools.length, 0);
    }

    function testAggregatedFinalTokenRevertRollsBackEarlierTransfer() public {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _createPosition(alice);
        _provide(id, pool, alice);
        MockERC20 first = new MockERC20("Reward", "RWD", 18);
        MockRevertingERC20 last = new MockRevertingERC20();
        uint8 s1 = _bribe(pool, first, 0);
        uint8 s2 = _bribe(pool, last, 0);
        vm.warp(block.timestamp + 1 days);
        uint8[] memory slots = new uint8[](2);
        slots[0] = s1;
        slots[1] = s2;
        IStaticsBatchRewards.PoolClaim[] memory claims = _poolClaims(id, pool, slots);
        uint256 reserved = custody.globalReservedByToken(address(first));
        last.setTransfersRevert(true);
        vm.expectPartialRevert(MockRevertingERC20.TransferBlocked.selector);
        _aggregatedLp(claims);
        assertEq(first.balanceOf(alice), 0);
        assertEq(custody.globalReservedByToken(address(first)), reserved);
        assertEq(custody.reservedByAccount(LibRewardPayout.ACCOUNT, address(first)), 0);
        last.setTransfersRevert(false);
        assertGt(_aggregatedLp(claims)[0][1], 0);
    }

    function testAggregatedExcessSenderDebitRollsBack() public {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _createPosition(alice);
        _provide(id, pool, alice);
        MockSenderExtraFeeERC20 taxed = new MockSenderExtraFeeERC20();
        uint8 slot = _bribe(pool, taxed, 0);
        vm.warp(block.timestamp + 1 days);
        taxed.setTaxedSender(address(diamond));
        uint256 reserved = custody.globalReservedByToken(address(taxed));
        vm.expectPartialRevert(IStaticsAggregatedBatchRewards.IncompatibleAggregatedRewardTransfer.selector);
        _aggregatedLp(_poolClaims(id, pool, _slots(slot, false)));
        assertEq(taxed.balanceOf(alice), 0);
        assertEq(custody.globalReservedByToken(address(taxed)), reserved);
    }
}
