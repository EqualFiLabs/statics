// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script, console2} from "forge-std/Script.sol";

import {TestnetEthUsdAggregator} from "../src/dollar/testnet/TestnetEthUsdAggregator.sol";
import {TestnetSequencerUptimeAggregator} from "../src/dollar/testnet/TestnetSequencerUptimeAggregator.sol";
import {TestnetUsdOracle} from "../src/dollar/testnet/TestnetUsdOracle.sol";

struct TestnetOracleFixtureDeployment {
    address ethUsdFeed;
    address sequencerUptimeFeed;
    address usdgOracle;
}

/// @notice Deploys the three owner-operated oracle fixtures used on public testnet.
contract DeployTestnetOracleFixtures is Script {
    error InvalidInitialUptime(uint256 uptime, uint256 currentTimestamp);

    function run() external returns (TestnetOracleFixtureDeployment memory deployment) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("TESTNET_ORACLE_OWNER");
        uint256 ethUsdPrice = vm.envUint("TESTNET_ETH_USD_INITIAL_PRICE");
        uint256 sequencerInitialUptime = vm.envUint("TESTNET_SEQUENCER_INITIAL_UPTIME");
        uint256 usdgPriceWad = vm.envUint("TESTNET_USDG_INITIAL_PRICE_WAD");
        uint256 usdgMaxStaleness = vm.envUint("TESTNET_USDG_ORACLE_MAX_STALENESS");
        uint256 usdgSequencerGracePeriod = vm.envUint("TESTNET_USDG_SEQUENCER_GRACE_PERIOD");

        vm.startBroadcast(privateKey);
        deployment = deploy(
            owner, ethUsdPrice, sequencerInitialUptime, usdgPriceWad, usdgMaxStaleness, usdgSequencerGracePeriod
        );
        vm.stopBroadcast();

        console2.log("ETH_USD_FEED", deployment.ethUsdFeed);
        console2.log("SEQUENCER_UPTIME_FEED", deployment.sequencerUptimeFeed);
        console2.log("STATICS_DOLLAR_USDC_ORACLE", deployment.usdgOracle);
    }

    function deploy(
        address owner,
        uint256 ethUsdPrice,
        uint256 sequencerInitialUptime,
        uint256 usdgPriceWad,
        uint256 usdgMaxStaleness,
        uint256 usdgSequencerGracePeriod
    ) public returns (TestnetOracleFixtureDeployment memory deployment) {
        uint256 currentTimestamp = block.timestamp;
        if (sequencerInitialUptime >= currentTimestamp) {
            revert InvalidInitialUptime(sequencerInitialUptime, currentTimestamp);
        }
        uint256 sequencerStartedAt = currentTimestamp - sequencerInitialUptime;

        deployment.ethUsdFeed = address(new TestnetEthUsdAggregator(owner, ethUsdPrice));
        deployment.sequencerUptimeFeed = address(new TestnetSequencerUptimeAggregator(owner, sequencerStartedAt));
        deployment.usdgOracle = address(
            new TestnetUsdOracle(
                owner, usdgPriceWad, usdgMaxStaleness, deployment.sequencerUptimeFeed, usdgSequencerGracePeriod
            )
        );
    }
}
