// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";

import {ChainlinkUsdOracle} from "src/dollar/ChainlinkUsdOracle.sol";
import {IUsdOracle} from "src/dollar/interfaces/IUsdOracle.sol";
import {TestnetEthUsdAggregator} from "src/dollar/testnet/TestnetEthUsdAggregator.sol";
import {TestnetSequencerUptimeAggregator} from "src/dollar/testnet/TestnetSequencerUptimeAggregator.sol";
import {TestnetUsdOracle} from "src/dollar/testnet/TestnetUsdOracle.sol";

contract TestnetOracleFixturesTest is Test {
    uint256 private constant NOW = 1_800_000_000;
    uint256 private constant GRACE_PERIOD = 1 hours;
    uint256 private constant MAX_STALENESS = 1 days;

    address private owner = makeAddr("owner");
    address private stranger = makeAddr("stranger");

    TestnetEthUsdAggregator private ethUsd;
    TestnetSequencerUptimeAggregator private sequencer;
    TestnetUsdOracle private usdg;
    ChainlinkUsdOracle private adapter;

    function setUp() public {
        vm.warp(NOW);
        ethUsd = new TestnetEthUsdAggregator(owner, 2_500e8);
        sequencer = new TestnetSequencerUptimeAggregator(owner, NOW - GRACE_PERIOD - 1);
        usdg = new TestnetUsdOracle(owner, 1e18, MAX_STALENESS);
        adapter =
            new ChainlinkUsdOracle(address(ethUsd), MAX_STALENESS, 100e18, 10_000e18, address(sequencer), GRACE_PERIOD);
    }

    function test_EthUsdAndSequencerFeedsDriveProductionAdapter() public {
        assertEq(adapter.priceWad(), 2_500e18);

        vm.prank(owner);
        ethUsd.publishPrice(3_000e8);
        assertEq(adapter.priceWad(), 3_000e18);

        vm.prank(owner);
        sequencer.publishStatus(true);
        vm.expectRevert(ChainlinkUsdOracle.SequencerDown.selector);
        adapter.priceWad();

        vm.warp(block.timestamp + 1);
        vm.prank(owner);
        sequencer.publishStatus(false);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkUsdOracle.SequencerGracePeriodActive.selector, block.timestamp, GRACE_PERIOD
            )
        );
        adapter.priceWad();

        vm.warp(block.timestamp + GRACE_PERIOD + 1);
        vm.prank(owner);
        ethUsd.publishPrice(3_000e8);
        assertEq(adapter.priceWad(), 3_000e18);
    }

    function test_SequencerHeartbeatPreservesStatusStartAndChangeRestartsIt() public {
        (,, uint256 initialStartedAt,,) = sequencer.latestRoundData();

        vm.warp(NOW + 10 minutes);
        vm.prank(owner);
        sequencer.publishStatus(false);
        (uint80 heartbeatRound, int256 heartbeatAnswer, uint256 heartbeatStartedAt, uint256 heartbeatUpdatedAt,) =
            sequencer.latestRoundData();
        assertEq(heartbeatRound, 2);
        assertEq(heartbeatAnswer, 0);
        assertEq(heartbeatStartedAt, initialStartedAt);
        assertEq(heartbeatUpdatedAt, block.timestamp);

        vm.warp(NOW + 20 minutes);
        vm.prank(owner);
        sequencer.publishStatus(true);
        (uint80 changedRound, int256 changedAnswer, uint256 changedStartedAt, uint256 changedUpdatedAt,) =
            sequencer.latestRoundData();
        assertEq(changedRound, 3);
        assertEq(changedAnswer, 1);
        assertEq(changedStartedAt, block.timestamp);
        assertEq(changedUpdatedAt, block.timestamp);
    }

    function test_UsdOraclePublishesDepegAndEnforcesStaleness() public {
        assertEq(usdg.priceWad(), 1e18);

        vm.prank(owner);
        usdg.publishPrice(0.99e18);
        assertEq(usdg.priceWad(), 0.99e18);

        vm.warp(block.timestamp + MAX_STALENESS + 1);
        vm.expectRevert(abi.encodeWithSelector(IUsdOracle.StalePrice.selector, NOW, MAX_STALENESS));
        usdg.priceWad();

        vm.prank(owner);
        usdg.publishPrice(0);
        vm.expectRevert(IUsdOracle.InvalidPrice.selector);
        usdg.priceWad();
    }

    function test_RevertWhen_NonOwnerPublishesAnyOracleState() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        ethUsd.publishPrice(2_600e8);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sequencer.publishStatus(true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        usdg.publishPrice(0.98e18);
        vm.stopPrank();
    }

    function test_RevertWhen_FixtureConstructionCannotProduceValidShape() public {
        vm.expectRevert(
            abi.encodeWithSelector(TestnetEthUsdAggregator.PriceExceedsInt256.selector, uint256(type(int256).max) + 1)
        );
        new TestnetEthUsdAggregator(owner, uint256(type(int256).max) + 1);

        vm.expectRevert(
            abi.encodeWithSelector(TestnetSequencerUptimeAggregator.InvalidInitialStartedAt.selector, 0, NOW)
        );
        new TestnetSequencerUptimeAggregator(owner, 0);

        vm.expectRevert(TestnetUsdOracle.InvalidMaxStaleness.selector);
        new TestnetUsdOracle(owner, 1e18, 0);
    }

    function testFuzz_EthUsdRoundPublishesExactPrice(uint128 price) public {
        vm.prank(owner);
        ethUsd.publishPrice(price);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            ethUsd.latestRoundData();
        assertEq(roundId, 2);
        assertEq(answer, int256(uint256(price)));
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, roundId);
    }
}
