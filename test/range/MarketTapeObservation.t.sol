// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MarketTapeObservationFacet} from "../../src/facets/MarketTapeObservationFacet.sol";
import {IStaticsMarketTape} from "../../src/interfaces/IStaticsMarketTape.sol";
import {IStaticsMarketObservations} from "../../src/interfaces/IStaticsMarketObservations.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibMarketTape} from "../../src/libraries/LibMarketTape.sol";
import {
    RangeGaugeCallbackHarness,
    RangeGaugeHookCaller,
    RangeGaugePoolManagerMock
} from "../helpers/RangeGaugeCallbackHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract MarketTapeObservationHarness is RangeGaugeCallbackHarness, MarketTapeObservationFacet {
    bool private recorderBroken;

    function setHarnessOwner(address owner) external {
        LibDiamond.initializeOwnership(owner);
    }

    function setRecorderBroken(bool broken) external {
        recorderBroken = broken;
    }

    function recordMarketObservation(PoolId targetPoolId, uint256 expectedSequence) public override {
        if (recorderBroken) revert("BROKEN_OBSERVATION_RECORDER");
        super.recordMarketObservation(targetPoolId, expectedSequence);
    }
}

contract MarketTapeObservationTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 private constant START = 14 days;

    MarketTapeObservationHarness private callback;
    RangeGaugeHookCaller private hook;
    RangeGaugePoolManagerMock private poolManager;
    PoolId private poolId;

    function setUp() public {
        callback = new MarketTapeObservationHarness();
        hook = new RangeGaugeHookCaller();
        poolManager = new RangeGaugePoolManagerMock();
        callback.initialize(address(new MockERC20("Statics", "STATICS", 18)));
        callback.setHarnessOwner(address(this));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 3_000,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        poolId = callback.registerGeneralPool(key, makeAddr("creator"));
        callback.installPublicIntegration(address(poolManager), address(hook));
        callback.initializeGauge(poolId, 0);
        poolManager.setTick(poolId, 0);
        vm.warp(START);
    }

    function testFirstSwapInstallsDefaultsAndCommitsObservation() public {
        _notify(-100, 90);

        IStaticsMarketObservations.ObservationConfig memory config = callback.marketObservationConfig(poolId);
        assertTrue(config.initialized);
        assertTrue(config.enabled);
        assertEq(config.cadence, 15 minutes);
        assertEq(config.cardinality, 1);
        assertEq(config.cardinalityNext, 96);
        assertEq(config.stored, 1);
        assertEq(config.latestId, 1);
        assertEq(config.lastObservationTimestamp, START);
        assertEq(config.failedWriteCount, 0);

        IStaticsMarketObservations.MarketObservation memory observation = callback.marketObservation(poolId, 1);
        assertEq(observation.timestamp, START);
        assertEq(observation.sequence, 1);
        assertEq(observation.externalVolume0, 100);
        assertEq(observation.externalVolume1, 90);
    }

    function testSameBlockAndPreCadenceSwapsDoNotAppendHistory() public {
        _notify(-100, 90);
        _notify(-50, 45);
        vm.warp(START + 15 minutes - 1);
        _notify(-25, 20);

        IStaticsMarketObservations.ObservationConfig memory config = callback.marketObservationConfig(poolId);
        assertEq(config.stored, 1);
        assertEq(config.latestId, 1);
        assertEq(callback.canonicalMarketState(poolId).sequence, 3);

        vm.warp(START + 15 minutes);
        _notify(-10, 8);
        config = callback.marketObservationConfig(poolId);
        assertEq(config.stored, 2);
        assertEq(config.cardinality, 2);
        assertEq(config.latestId, 2);
        assertEq(callback.marketObservation(poolId, 2).sequence, 4);
    }

    function testRingGrowsLazilyWrapsAndReturnsAtOrBeforeSnapshots() public {
        callback.setMarketObservationConfig(poolId, true, 1 minutes, 3);
        _notify(-100, 90);
        for (uint256 i = 1; i <= 3; ++i) {
            vm.warp(START + i * 1 minutes);
            poolManager.setTick(poolId, int256(i));
            _notify(-100, 90);
        }

        IStaticsMarketObservations.ObservationConfig memory config = callback.marketObservationConfig(poolId);
        assertEq(config.cardinality, 3);
        assertEq(config.stored, 3);
        assertEq(config.latestId, 4);
        vm.expectRevert(
            abi.encodeWithSelector(MarketTapeObservationFacet.MarketObservationNotFound.selector, poolId, uint64(1))
        );
        callback.marketObservation(poolId, 1);

        uint32[] memory lookbacks = new uint32[](3);
        lookbacks[0] = 0;
        lookbacks[1] = 1 minutes;
        lookbacks[2] = 2 minutes;
        IStaticsMarketObservations.MarketObservation[] memory values = callback.observeMarket(poolId, lookbacks);
        assertEq(values[0].sequence, 4);
        assertEq(values[1].sequence, 3);
        assertEq(values[2].sequence, 2);
    }

    function testConfigurationIsOwnerControlledBoundedAndCanDisableRecording() public {
        vm.prank(makeAddr("outsider"));
        vm.expectRevert();
        callback.setMarketObservationConfig(poolId, true, 1 minutes, 672);

        callback.setMarketObservationConfig(poolId, true, 1 minutes, 672);
        assertEq(callback.marketObservationConfig(poolId).cardinalityNext, 672);
        vm.expectRevert(abi.encodeWithSelector(LibMarketTape.InvalidObservationCardinality.selector, 673));
        callback.setMarketObservationConfig(poolId, true, 1 minutes, 673);
        vm.expectRevert(abi.encodeWithSelector(LibMarketTape.InvalidObservationCadence.selector, 59));
        callback.setMarketObservationConfig(poolId, true, 59, 96);
        vm.expectRevert(abi.encodeWithSelector(LibMarketTape.InvalidObservationCadence.selector, 1 days + 1));
        callback.setMarketObservationConfig(poolId, true, 1 days + 1, 96);

        callback.setMarketObservationConfig(poolId, false, 0, 0);
        _notify(-100, 90);
        IStaticsMarketObservations.ObservationConfig memory config = callback.marketObservationConfig(poolId);
        assertFalse(config.enabled);
        assertEq(config.stored, 0);
        assertEq(callback.canonicalMarketState(poolId).sequence, 1);
    }

    function testRecorderRejectsExternalAndMismatchedSelfCalls() public {
        vm.expectRevert(abi.encodeWithSelector(MarketTapeObservationFacet.OnlyDiamondSelf.selector, address(this)));
        callback.recordMarketObservation(poolId, 1);

        _notify(-100, 90);
        vm.prank(address(callback));
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketTapeObservationFacet.CanonicalSequenceMismatch.selector, poolId, uint256(2), uint256(1)
            )
        );
        callback.recordMarketObservation(poolId, 2);
    }

    function testRevertingRecorderCreatesDetectableGapAndRecovers() public {
        _notify(-100, 90);
        callback.setRecorderBroken(true);
        vm.warp(START + 15 minutes);
        vm.expectEmit(true, true, false, true, address(callback));
        emit IStaticsMarketTape.MarketSwapRecorded(poolId, 2, toBalanceDelta(-50, 45), 0, 0, 0, 1);
        _notify(-50, 45);

        IStaticsMarketObservations.ObservationConfig memory config = callback.marketObservationConfig(poolId);
        assertEq(callback.canonicalMarketState(poolId).sequence, 2);
        assertEq(config.latestId, 1);
        assertEq(config.failedWriteCount, 1);
        assertEq(config.lastFailedSequence, 2);

        callback.setRecorderBroken(false);
        vm.warp(START + 30 minutes);
        _notify(-25, 20);
        config = callback.marketObservationConfig(poolId);
        assertEq(config.latestId, 2);
        assertEq(callback.marketObservation(poolId, 2).sequence, 3);
        assertEq(config.failedWriteCount, 1);
    }

    function testObservationQueriesRejectMissingTooOldAndOversizedRequests() public {
        uint32[] memory oneQuery = new uint32[](1);
        vm.expectRevert(abi.encodeWithSelector(MarketTapeObservationFacet.NoMarketObservations.selector, poolId));
        callback.observeMarket(poolId, oneQuery);

        _notify(-100, 90);
        vm.warp(START + 1 hours);
        oneQuery[0] = uint32(block.timestamp + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketTapeObservationFacet.ObservationQueryInFuture.selector,
                uint256(uint32(block.timestamp + 1)),
                block.timestamp
            )
        );
        callback.observeMarket(poolId, oneQuery);

        oneQuery[0] = 1 hours + 1;
        vm.expectRevert(
            abi.encodeWithSelector(MarketTapeObservationFacet.ObservationTooOld.selector, poolId, START - 1, START)
        );
        callback.observeMarket(poolId, oneQuery);

        oneQuery[0] = 1 hours;
        assertEq(callback.observeMarket(poolId, oneQuery)[0].sequence, 1);
        oneQuery[0] = 1 hours - 1;
        assertEq(callback.observeMarket(poolId, oneQuery)[0].sequence, 1);

        uint32[] memory oversized = new uint32[](65);
        vm.expectRevert(abi.encodeWithSelector(MarketTapeObservationFacet.TooManyObservationQueries.selector, 65, 64));
        callback.observeMarket(poolId, oversized);
    }

    function testMaximumObservationQueryUsesBoundedSearch() public {
        callback.setMarketObservationConfig(poolId, true, 1 minutes, 672);
        _notify(-100, 90);
        for (uint256 i = 1; i < 672; ++i) {
            vm.warp(START + i * 1 minutes);
            _notify(-100, 90);
        }

        uint32[] memory lookbacks = new uint32[](64);
        for (uint256 i; i < lookbacks.length; ++i) {
            lookbacks[i] = uint32((i * 10 + 1) * 1 minutes);
        }

        uint256 gasBefore = gasleft();
        IStaticsMarketObservations.MarketObservation[] memory values = callback.observeMarket(poolId, lookbacks);
        uint256 queryGas = gasBefore - gasleft();

        assertEq(values.length, 64);
        assertEq(values[0].sequence, 671);
        assertEq(values[63].sequence, 41);
        emit log_named_uint("maximum observation query gas", queryGas);
        assertLt(queryGas, 8_000_000);
    }

    function testObservationGasIsBoundedOnOrdinaryAndCommitSwaps() public {
        _notify(-100, 90);
        uint256 gasBefore = gasleft();
        _notify(-50, 45);
        uint256 ordinaryGas = gasBefore - gasleft();

        vm.warp(START + 15 minutes);
        gasBefore = gasleft();
        _notify(-50, 45);
        uint256 commitGas = gasBefore - gasleft();

        emit log_named_uint("market observation ordinary swap gas", ordinaryGas);
        emit log_named_uint("market observation commit swap gas", commitGas);
        assertLt(ordinaryGas, 350_000);
        assertLt(commitGas, 650_000);
        assertGt(commitGas, ordinaryGas);
    }

    function _notify(int128 amount0, int128 amount1) private {
        hook.notify(address(callback), poolId, toBalanceDelta(amount0, amount1), 0, 1);
    }
}
