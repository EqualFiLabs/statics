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
import {LibGaugeRouting} from "../../src/libraries/LibGaugeRouting.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {GaugeIncentiveFacet} from "../../src/facets/GaugeIncentiveFacet.sol";
import {GlobalRewardsFacet} from "../../src/facets/GlobalRewardsFacet.sol";
import {RangeGaugeLivenessFacet} from "../../src/facets/RangeGaugeLivenessFacet.sol";
import {BatchRewardsFacet} from "../../src/facets/BatchRewardsFacet.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsCustody} from "../../src/interfaces/IStaticsCustody.sol";
import {LibRangeGauge} from "../../src/libraries/LibRangeGauge.sol";
import {LibCustody} from "../../src/libraries/LibCustody.sol";
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

contract IncorrectAcknowledgedRewardRoute {
    function claimLpRewards(uint256, PoolId, uint8[] calldata slots, uint256[] calldata, address receiver)
        external
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](slots.length);
        for (uint256 i; i < slots.length; ++i) {
            LibRewardPayout.pay(bytes32(0), address(1), receiver, 0);
            amounts[i] = 1;
        }
    }
}

contract ExcessAcknowledgedRewardRoute {
    function claimLpRewards(uint256, PoolId, uint8[] calldata, uint256[] calldata, address receiver)
        external
        returns (uint256[] memory)
    {
        LibRewardPayout.pay(bytes32(0), address(1), receiver, 0);
        LibRewardPayout.pay(bytes32(0), address(1), receiver, 0);
        return new uint256[](2);
    }
}

contract WrongReceiverRewardRoute {
    function claimLpRewards(uint256, PoolId, uint8[] calldata slots, uint256[] calldata, address)
        external
        returns (uint256[] memory amounts)
    {
        LibRewardPayout.pay(bytes32(0), address(1), address(0xBAD), 0);
        return new uint256[](slots.length);
    }
}

// Narrow storage observation, used to inspect transient reservations during and after real claims.
contract AggregationStateProbe {
    function batchReserved(address asset) external view returns (uint256) {
        return LibCustody.aggregatedRewardReservation(asset);
    }
}

contract AggregationBackingObserver {
    bool public observed;

    function observe(address diamond, bytes32 source, address asset, uint256 priorGlobal) external {
        uint256 pending = AggregationStateProbe(diamond).batchReserved(asset);
        require(pending > 0, "missing pending reservation");
        require(IStaticsCustody(diamond).globalReservedByToken(asset) == priorGlobal, "global backing changed early");
        require(
            IStaticsCustody(diamond).reservedByAccount(source, asset) + pending == priorGlobal,
            "reservation sum changed"
        );
        require(MockERC20(asset).balanceOf(diamond) >= priorGlobal, "unbacked pending payout");
        observed = true;
    }
}

contract AggregatedBatchRewardsTest is BatchRewardsLifecycleTest {
    IStaticsAggregatedBatchRewards internal aggregated;
    bytes32 private constant TRANSFER = keccak256("Transfer(address,address,uint256)");

    function setUp() public override {
        super.setUp();
        aggregated = IStaticsAggregatedBatchRewards(address(diamond));
        if (IDiamondLoupe(address(diamond)).facetAddress(aggregated.batchClaimRewardsAggregated.selector) == address(0))
        {
            bytes4[] memory aggregateSelector = new bytes4[](1);
            aggregateSelector[0] = aggregated.batchClaimRewardsAggregated.selector;
            IDiamondCut.FacetCut[] memory install = new IDiamondCut.FacetCut[](1);
            install[0] = IDiamondCut.FacetCut(
                address(new BatchRewardsFacet()), IDiamondCut.FacetCutAction.Add, aggregateSelector
            );
            IDiamondCut(address(diamond)).diamondCut(install, address(0), "");
        }
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = AggregationStateProbe.batchReserved.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut(address(new AggregationStateProbe()), IDiamondCut.FacetCutAction.Add, selectors);
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
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
        assertEq(AggregationStateProbe(address(diamond)).batchReserved(address(reward)), 0);
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
        assertEq(AggregationStateProbe(address(diamond)).batchReserved(address(reward)), 0);
        assertGt(_aggregatedMixed().length, 0);
    }

    function testAggregatedGlobalNoRewardsStillRevertsAndContextRecovers() public {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _stake(alice, _assets());
        _provide(id, pool, alice);
        IStaticsBatchRewards.GlobalClaim[] memory claims = new IStaticsBatchRewards.GlobalClaim[](1);
        claims[0] = IStaticsBatchRewards.GlobalClaim(id, _assets(), new uint256[](2));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GlobalRewardsFacet.NoRewards.selector, id));
        aggregated.batchClaimRewardsAggregated(
            claims, new IStaticsBatchRewards.PoolClaim[](0), new IStaticsBatchRewards.PoolClaim[](0), alice
        );
        assertEq(_aggregatedLp(_poolClaims(id, pool, _slots(0, false)))[0][0], 0);
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
        assertEq(AggregationStateProbe(address(diamond)).batchReserved(address(taxed)), 0);
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
            assertEq(AggregationStateProbe(address(diamond)).batchReserved(address(tokens[i])), 0);
            assertGe(tokens[i].balanceOf(address(diamond)), custody.globalReservedByToken(address(tokens[i])));
        }
        emit log_named_uint("64 entries / 13 tokens legacy gas", legacyGas);
        emit log_named_uint("64 entries / 13 tokens aggregate gas", aggregateGas);
        assertLt(aggregateGas, legacyGas);
    }

    function test_AggregatedRewardFacetsRetainEip170Headroom() public {
        assertLe(type(GaugeIncentiveFacet).runtimeCode.length, 24_576);
        assertLe(type(GlobalRewardsFacet).runtimeCode.length, 24_576);
        assertLe(type(RangeGaugeLivenessFacet).runtimeCode.length, 24_576);
        assertLe(type(BatchRewardsFacet).runtimeCode.length, 24_576);
        emit log_named_uint("GaugeIncentiveFacet runtime bytes", type(GaugeIncentiveFacet).runtimeCode.length);
        emit log_named_uint("GlobalRewardsFacet runtime bytes", type(GlobalRewardsFacet).runtimeCode.length);
        emit log_named_uint("RangeGaugeLivenessFacet runtime bytes", type(RangeGaugeLivenessFacet).runtimeCode.length);
        emit log_named_uint("BatchRewardsFacet runtime bytes", type(BatchRewardsFacet).runtimeCode.length);
    }

    function _benchmarkPayouts(uint256 groups, uint256 entries, bool distinct) private {
        MockERC20[] memory tokens = new MockERC20[](distinct ? groups * entries : entries);
        for (uint256 i; i < tokens.length; ++i) {
            tokens[i] = new MockERC20("Reward", "RWD", 18);
        }
        IStaticsBatchRewards.PoolClaim[] memory claims = new IStaticsBatchRewards.PoolClaim[](groups);
        for (uint256 i; i < groups; ++i) {
            MockERC20 pair = new MockERC20("Pair", "PAIR", 18);
            PoolId pool = _createRangeGaugePool(alice, address(assetA), address(pair));
            uint256 id = _createPosition(alice);
            _provide(id, pool, alice);
            uint8[] memory slots = new uint8[](entries);
            for (uint256 j; j < entries; ++j) {
                slots[j] = _bribe(pool, tokens[distinct ? i * entries + j : j], 0);
            }
            claims[i] = IStaticsBatchRewards.PoolClaim(id, PoolId.unwrap(pool), slots, new uint256[](entries));
        }
        vm.warp(block.timestamp + 7 days);
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        uint256 start = gasleft();
        uint256[][] memory expected = _lpBatch(claims);
        uint256 legacyGas = start - gasleft();
        assertEq(_payoutTransfers(vm.getRecordedLogs()), groups * entries);
        uint256[] memory balances = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            balances[i] = tokens[i].balanceOf(alice);
        }
        vm.revertToState(snapshot);
        vm.recordLogs();
        start = gasleft();
        uint256[][] memory actual = _aggregatedLp(claims);
        uint256 aggregateGas = start - gasleft();
        assertEq(abi.encode(actual), abi.encode(expected));
        assertEq(_payoutTransfers(vm.getRecordedLogs()), tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(tokens[i].balanceOf(alice), balances[i]);
        }
        emit log_named_uint("legacy execution gas", legacyGas);
        emit log_named_uint("aggregated execution gas", aggregateGas);
        if (groups > 1 && !distinct) assertLt(aggregateGas, legacyGas);
    }

    function testBenchmarkOneEntry() public {
        _benchmarkPayouts(1, 1, false);
    }

    function testBenchmarkTypicalRepeatedTokens() public {
        _benchmarkPayouts(4, 4, false);
    }

    function testBenchmarkMaximumRepeatedTokens() public {
        _benchmarkPayouts(16, 4, false);
    }

    function testBenchmarkMaximumDistinctTokens() public {
        _benchmarkPayouts(16, 4, true);
    }

    function testBenchmarkMixedSettlement() public {
        _mixedState();
        uint256 snapshot = vm.snapshotState();
        vm.prank(alice);
        uint256 start = gasleft();
        (uint256[][] memory g, uint256[][] memory l, uint256[][] memory a) =
            batch.batchClaimRewards(_globals(), _pools(false), _pools(true), bob);
        uint256 legacyGas = start - gasleft();
        bytes memory expected = abi.encode(g, l, a);
        vm.revertToState(snapshot);
        start = gasleft();
        assertEq(_aggregatedMixed(), expected);
        emit log_named_uint("mixed legacy execution gas", legacyGas);
        emit log_named_uint("mixed aggregated execution gas", start - gasleft());
    }

    function testPendingBatchReservationRemainsGloballyBackedDuringFlush() public {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _createPosition(alice);
        _provide(id, pool, alice);
        MockReentrantERC20 first = new MockReentrantERC20();
        MockERC20 second = new MockERC20("Second", "SECOND", 18);
        uint8[] memory slots = new uint8[](2);
        slots[0] = _bribe(pool, first, 0);
        slots[1] = _bribe(pool, second, 0);
        vm.warp(block.timestamp + 1 days);
        AggregationBackingObserver observer = new AggregationBackingObserver();
        first.setCallback(
            address(diamond),
            address(observer),
            abi.encodeCall(
                observer.observe,
                (
                    address(diamond),
                    LibRangeGauge.rewardAccount(pool, slots[1]),
                    address(second),
                    custody.globalReservedByToken(address(second))
                )
            )
        );
        _aggregatedLp(_poolClaims(id, pool, slots));
        assertTrue(first.reentrySucceeded());
        assertTrue(observer.observed());
        assertEq(AggregationStateProbe(address(diamond)).batchReserved(address(second)), 0);
    }

    function testIndividualClaimCallbackCannotEnterAggregatedBatch() public {
        _reentry(
            abi.encodeCall(
                IStaticsAggregatedBatchRewards.batchClaimRewardsAggregated,
                (
                    new IStaticsBatchRewards.GlobalClaim[](0),
                    new IStaticsBatchRewards.PoolClaim[](0),
                    new IStaticsBatchRewards.PoolClaim[](0),
                    alice
                )
            ),
            IStaticsBatchRewards.BatchClaimReentrantCall.selector,
            true
        );
    }

    function testAggregatedWrongAcknowledgementAndReceiverRevert() public {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _createPosition(alice);
        _provide(id, pool, alice);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IStaticsRangeGauge.claimLpRewards.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut(
            address(new IncorrectAcknowledgedRewardRoute()), IDiamondCut.FacetCutAction.Replace, selectors
        );
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        vm.expectPartialRevert(IStaticsAggregatedBatchRewards.AggregatedClaimRouteIncompatible.selector);
        _aggregatedLp(_poolClaims(id, pool, _slots(0, false)));
        cut[0].facetAddress = address(new ExcessAcknowledgedRewardRoute());
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        vm.expectPartialRevert(IStaticsAggregatedBatchRewards.AggregatedClaimRouteIncompatible.selector);
        _aggregatedLp(_poolClaims(id, pool, _slots(0, false)));
        cut[0].facetAddress = address(new WrongReceiverRewardRoute());
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        vm.expectRevert(IStaticsAggregatedBatchRewards.InvalidAggregatedClaimContext.selector);
        _aggregatedLp(_poolClaims(id, pool, _slots(0, false)));
    }

    function testAggregatedCatchupRevertsAndRecoversAfterBoundedCheckpoint() public {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _stake(alice, new address[](0));
        _provide(id, pool, alice);
        _allocate(id, pool);
        _activateReserve();
        vm.warp(block.timestamp + 60 weeks);
        IStaticsBatchRewards.PoolClaim[] memory claims = _poolClaims(id, pool, _slots(0, false));
        uint256 reserved = custody.globalReservedByToken(address(stakingAsset));
        vm.expectPartialRevert(LibGaugeRouting.GaugeScheduleCatchupRequired.selector);
        _aggregatedLp(claims);
        assertEq(custody.globalReservedByToken(address(stakingAsset)), reserved);
        assertEq(AggregationStateProbe(address(diamond)).batchReserved(address(stakingAsset)), 0);
        incentives.checkpointGaugeSchedule(52);
        incentives.checkpointGaugeSchedule(52);
        assertGt(_aggregatedLp(claims)[0][0], 0);
    }

    function testBenchmarkMaximumLazySettlement() public {
        PoolId pool = _createRangeGaugePool(alice);
        IStaticsBatchRewards.PoolClaim[] memory claims = new IStaticsBatchRewards.PoolClaim[](16);
        for (uint256 i; i < 16; ++i) {
            uint256 id = _stake(alice, new address[](0));
            _provide(id, pool, alice);
            _allocate(id, pool);
            uint8[] memory slots = new uint8[](4);
            for (uint256 j; j < 4; ++j) {
                slots[j] = uint8(j);
            }
            claims[i] = IStaticsBatchRewards.PoolClaim(id, PoolId.unwrap(pool), slots, new uint256[](4));
        }
        for (uint256 i; i < 3; ++i) {
            _bribe(pool, new MockERC20("Reward", "RWD", 18), 0);
        }
        _activateReserve();
        vm.warp(block.timestamp + 50 weeks);
        uint256 snapshot = vm.snapshotState();
        uint256 start = gasleft();
        uint256[][] memory expected = _lpBatch(claims);
        uint256 legacyGas = start - gasleft();
        vm.revertToState(snapshot);
        start = gasleft();
        uint256[][] memory actual = _aggregatedLp(claims);
        uint256 aggregatedGas = start - gasleft();
        assertEq(abi.encode(actual), abi.encode(expected));
        assertGe(stakingAsset.balanceOf(address(diamond)), custody.globalReservedByToken(address(stakingAsset)));
        emit log_named_uint("maximum lazy legacy execution gas", legacyGas);
        emit log_named_uint("maximum lazy aggregated execution gas", aggregatedGas);
        assertLt(aggregatedGas, legacyGas);
    }

    function testAggregatedRejectsUnacknowledgedZeroRoute() public {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _createPosition(alice);
        _provide(id, pool, alice);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IStaticsRangeGauge.claimLpRewards.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut(
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
        assertEq(AggregationStateProbe(address(diamond)).batchReserved(address(first)), 0);
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
