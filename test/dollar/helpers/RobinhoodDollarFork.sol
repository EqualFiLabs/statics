// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployStaticsDollarBase, StaticsDollarProductionConfig} from "script/dollar/DeployStaticsDollar.s.sol";

abstract contract RobinhoodDollarFork is Test, DeployStaticsDollarBase {
    // Post-deployment snapshot of the Statics sequencer signal, with its recovery grace elapsed.
    uint256 internal constant FORK_BLOCK = 90_883_652;
    bytes32 internal constant FORK_HASH = 0xa82be08633dc8be82b1b168eeaa5d56584be332f5cc5f1f3a63441da29582c37;
    address internal constant RH_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant RH_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant RH_ETH_USD = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address internal constant RH_USDG_USD = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address internal constant RH_SEQUENCER = 0xeCe3F60De85705472292a44787123a8Fc46CDa54;
    // The Robinhood ETH/USD and USDG/USD directory heartbeats are both 86,400 seconds.
    uint256 internal constant FEED_MAX_AGE = 1 days;
    uint256 internal constant SEQUENCER_GRACE = 1 hours;

    function setUp() public virtual {
        string memory rpc = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            if (vm.envOr("REQUIRE_ROBINHOOD_FORK", false)) fail("Robinhood fork required");
            vm.skip(true, "ROBINHOOD_MAINNET is not configured");
            return;
        }

        string memory header =
            vm.rpcJson(rpc, "eth_getBlockByHash", string.concat("[\"", vm.toString(FORK_HASH), "\",false]"));
        assertEq(vm.parseJsonBytes32(header, ".hash"), FORK_HASH, "fork block hash drift");
        assertEq(vm.parseJsonUint(header, ".number"), FORK_BLOCK);
        vm.createSelectFork(rpc, FORK_BLOCK);
        assertEq(vm.getChainId(), 4663);
        assertEq(vm.getBlockNumber(), vm.parseJsonUint(header, ".l1BlockNumber"));
        assertEq(vm.getBlockTimestamp(), vm.parseJsonUint(header, ".timestamp"));
    }

    function _productionConfig() internal returns (StaticsDollarProductionConfig memory config) {
        config.owner = makeAddr("robinhoodProductionOwner");
        config.profileGuardian = makeAddr("robinhoodProfileGuardian");
        config.treasury = makeAddr("robinhoodProductionTreasury");
        config.stakingToken = RH_USDG;
        config.weth = RH_WETH;
        config.ethUsdFeed = RH_ETH_USD;
        config.sequencerUptimeFeed = RH_SEQUENCER;
        config.oracleMaxStaleness = FEED_MAX_AGE;
        config.oracleMinPriceWad = 100e18;
        config.oracleMaxPriceWad = 100_000e18;
        config.sequencerGracePeriod = SEQUENCER_GRACE;
        config.collateralRatioBps = 15_000;
        config.priceBandBps = 15_000;
        config.debtCeiling = 1_000_000e18;
        config.riskUri = "ipfs://risk/{id}.json";
    }
}
