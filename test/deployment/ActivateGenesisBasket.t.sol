// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {ActivateGenesisBasket, GenesisBasketActivationConfig} from "../../script/ActivateGenesisBasket.s.sol";
import {IERC173} from "../../src/interfaces/IERC173.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {StaticsTimelock} from "../../src/governance/StaticsTimelock.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

contract ActivateGenesisBasketBatchTest is Test {
    function testBuildsOneTypedActivationPerAsset() public {
        ActivateGenesisBasket activation = new ActivateGenesisBasket();
        address diamond = makeAddr("diamond");
        address[] memory assets = new address[](3);
        assets[0] = makeAddr("TSLA");
        assets[1] = makeAddr("PLTR");
        assets[2] = makeAddr("AMD");
        GenesisBasketActivationConfig memory config = GenesisBasketActivationConfig({basketId: 7, assets: assets});

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            activation.buildBatch(diamond, config);

        assertEq(targets.length, 3);
        assertEq(values.length, 3);
        assertEq(payloads.length, 3);
        for (uint256 i; i < 3; ++i) {
            assertEq(targets[i], diamond);
            assertEq(values[i], 0);
            assertEq(_selector(payloads[i]), IStaticsBasketLiquidity.activateCanonicalPool.selector);
            (uint256 basketId, address asset) = abi.decode(_arguments(payloads[i]), (uint256, address));
            assertEq(basketId, 7);
            assertEq(asset, assets[i]);
        }
    }

    function testLoadsRobinhoodTpa1ActivationDefinition() public {
        GenesisBasketActivationConfig memory config =
            new ActivateGenesisBasket().loadConfig("script/config/robinhood-testnet-tpa1.json");

        assertEq(config.basketId, 0);
        assertEq(config.assets.length, 3);
        assertEq(config.assets[0], 0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E);
        assertEq(config.assets[1], 0x1FBE1a0e43594b3455993B5dE5Fd0A7A266298d0);
        assertEq(config.assets[2], 0x71178BAc73cBeb415514eB542a8995b82669778d);
    }

    function _selector(bytes memory payload) private pure returns (bytes4 selector) {
        assembly ("memory-safe") {
            selector := mload(add(payload, 0x20))
        }
    }

    function _arguments(bytes memory payload) private pure returns (bytes memory arguments) {
        arguments = new bytes(payload.length - 4);
        for (uint256 i; i < arguments.length; ++i) {
            arguments[i] = payload[i + 4];
        }
    }
}

contract ActivateGenesisBasketIntegrationTest is CanonicalPoolTestBase {
    ActivateGenesisBasket private activation;
    StaticsTimelock private timelock;
    GenesisBasketActivationConfig private config;

    function setUp() public override {
        super.setUp();
        activation = new ActivateGenesisBasket();
        (uint256 basketId,) = _createDefaultBasket(0, 0);

        address[] memory proposers = new address[](1);
        proposers[0] = address(activation);
        address[] memory executors = new address[](1);
        executors[0] = address(activation);
        timelock = new StaticsTimelock(proposers, executors, address(this));
        IERC173(address(diamond)).transferOwnership(address(timelock));

        address[] memory assets = new address[](2);
        assets[0] = address(assetA);
        assets[1] = address(assetB);
        config = GenesisBasketActivationConfig({basketId: basketId, assets: assets});
    }

    function testCheckpointsSchedulesAndActivatesEveryCanonicalPool() public {
        vm.warp(block.timestamp + 1 hours);
        activation.checkpoint(address(diamond), config);

        for (uint256 i; i < config.assets.length; ++i) {
            IStaticsBasketLiquidity.CanonicalPoolView memory pool =
                basketLiquidity.canonicalPool(config.basketId, config.assets[i]);
            assertEq(pool.observationCardinality, 2);
            assertTrue(pool.referenceAvailable);
        }

        bytes32 salt = keccak256("activate genesis pools");
        bytes32 operationId = activation.schedule(address(diamond), config, salt);
        assertTrue(timelock.isOperationPending(operationId));

        vm.warp(block.timestamp + timelock.getMinDelay());
        activation.execute(address(diamond), config, salt);
        assertTrue(timelock.isOperationDone(operationId));

        for (uint256 i; i < config.assets.length; ++i) {
            IStaticsBasketLiquidity.CanonicalPoolView memory pool =
                basketLiquidity.canonicalPool(config.basketId, config.assets[i]);
            assertEq(uint8(pool.status), uint8(IStaticsBasketLiquidity.CanonicalPoolStatus.Active));
            assertEq(pool.activatedAt, block.timestamp);
        }
    }

    function testScheduleRequiresCheckpointedOracleHistory() public {
        vm.warp(block.timestamp + 1 hours);

        vm.expectPartialRevert(ActivateGenesisBasket.OracleHistoryUnavailable.selector);
        activation.schedule(address(diamond), config, keccak256("missing checkpoints"));
    }

    function testRejectsAssetListThatDoesNotMatchBasketDefinition() public {
        config.assets[1] = makeAddr("wrong asset");
        vm.warp(block.timestamp + 1 hours);

        vm.expectRevert(
            abi.encodeWithSelector(ActivateGenesisBasket.BasketDefinitionMismatch.selector, config.basketId)
        );
        activation.checkpoint(address(diamond), config);
    }
}
