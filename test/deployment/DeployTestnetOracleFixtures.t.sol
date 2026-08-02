// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {
    DeployTestnetOracleFixtures,
    TestnetOracleFixtureDeployment
} from "../../script/DeployTestnetOracleFixtures.s.sol";
import {ChainlinkUsdOracle} from "../../src/dollar/ChainlinkUsdOracle.sol";
import {TestnetEthUsdAggregator} from "../../src/dollar/testnet/TestnetEthUsdAggregator.sol";
import {TestnetSequencerUptimeAggregator} from "../../src/dollar/testnet/TestnetSequencerUptimeAggregator.sol";
import {TestnetUsdOracle} from "../../src/dollar/testnet/TestnetUsdOracle.sol";

contract DeployTestnetOracleFixturesTest is Test {
    uint256 private constant NOW = 1_800_000_000;
    uint256 private constant GRACE_PERIOD = 1 hours;

    function test_DeploysOwnedFixturesReadyForProductionPath() public {
        vm.warp(NOW);
        address owner = makeAddr("owner");

        TestnetOracleFixtureDeployment memory deployment =
            new DeployTestnetOracleFixtures().deploy(owner, 2_500e8, GRACE_PERIOD + 1, 1e18, 30 days, GRACE_PERIOD);

        TestnetEthUsdAggregator ethUsd = TestnetEthUsdAggregator(deployment.ethUsdFeed);
        TestnetSequencerUptimeAggregator sequencer = TestnetSequencerUptimeAggregator(deployment.sequencerUptimeFeed);
        TestnetUsdOracle usdg = TestnetUsdOracle(deployment.usdgOracle);

        assertEq(ethUsd.owner(), owner);
        assertEq(sequencer.owner(), owner);
        assertEq(usdg.owner(), owner);
        assertEq(usdg.priceWad(), 1e18);
        assertEq(usdg.sequencerUptimeFeed(), deployment.sequencerUptimeFeed);
        assertEq(usdg.sequencerGracePeriod(), GRACE_PERIOD);

        ChainlinkUsdOracle adapter =
            new ChainlinkUsdOracle(address(ethUsd), 1 days, 100e18, 10_000e18, address(sequencer), GRACE_PERIOD);
        assertEq(adapter.priceWad(), 2_500e18);
    }

    function test_RevertWhen_InitialUptimeCannotProduceRoundTimestamp() public {
        vm.warp(NOW);
        DeployTestnetOracleFixtures deployer = new DeployTestnetOracleFixtures();
        vm.expectRevert(abi.encodeWithSelector(DeployTestnetOracleFixtures.InvalidInitialUptime.selector, NOW, NOW));
        deployer.deploy(makeAddr("owner"), 2_500e8, NOW, 1e18, 30 days, GRACE_PERIOD);
    }
}
