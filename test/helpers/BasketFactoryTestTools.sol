// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {StaticsBasketTokenFactory} from "../../src/liquidity/StaticsBasketTokenFactory.sol";

/// @dev Local executable CreateX fixture and test-only offchain-equivalent salt provisioning.
/// Production callers supply SDK-mined salts; no production deployment mines inside a transaction.
abstract contract BasketFactoryTestTools is Test {
    mapping(address => uint88) private _nextTestTokenNonce;

    function _deployTestBasketFactory(address diamond, IPoolManager manager, IStaticsSwapFeeHook policy)
        internal
        returns (StaticsBasketTokenFactory factory)
    {
        vm.etch(
            0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed,
            vm.parseJsonBytes(vm.readFile("test/fixtures/createx-v1.json"), ".runtime")
        );
        policy;
        factory = new StaticsBasketTokenFactory(diamond, manager);
    }

    function _ensureTestBasketSalts(StaticsBasketTokenFactory factory, uint256) internal {
        uint256 tokens = factory.queueAvailability();
        if (tokens == 0) {
            bytes32[] memory tokenSalts = new bytes32[](1);
            tokenSalts[0] = factory.saltFor(((uint88(1) << 87) - 1) - _nextTestTokenNonce[address(factory)]++);
            factory.enqueueSalts(tokenSalts);
        }
    }
}
