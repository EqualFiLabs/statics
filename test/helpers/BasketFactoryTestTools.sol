// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {StaticsBasketTokenFactory} from "../../src/liquidity/StaticsBasketTokenFactory.sol";

/// @dev Local executable CreateX fixture and test-only offchain-equivalent salt provisioning.
/// Production callers supply SDK-mined salts; no production deployment mines inside a transaction.
abstract contract BasketFactoryTestTools is Test {
    uint160 private constant GENERAL_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        | Hooks.BEFORE_DONATE_FLAG;
    uint160 private constant BASKET_HOOK_FLAGS = GENERAL_HOOK_FLAGS | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;

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
        factory = StaticsBasketTokenFactory(
            vm.deployCode(
                "out/StaticsBasketTokenFactory.sol/StaticsBasketTokenFactory.json", abi.encode(diamond, manager)
            )
        );
    }

    function _deployTestBasketHook(IPoolManager manager, address diamond, address weth)
        internal
        returns (IStaticsSwapFeeHook hook)
    {
        return _deployTestPublicHook(
            "out/StaticsBasketHook.sol/StaticsBasketHook.json", BASKET_HOOK_FLAGS, manager, diamond, weth
        );
    }

    function _deployTestGeneralHook(IPoolManager manager, address diamond, address weth)
        internal
        returns (IStaticsSwapFeeHook hook)
    {
        return _deployTestPublicHook(
            "out/StaticsGeneralPoolHook.sol/StaticsGeneralPoolHook.json", GENERAL_HOOK_FLAGS, manager, diamond, weth
        );
    }

    function _ensureTestBasketSalts(StaticsBasketTokenFactory factory, uint256) internal {
        uint256 tokens = factory.queueAvailability();
        if (tokens == 0) {
            bytes32[] memory tokenSalts = new bytes32[](1);
            tokenSalts[0] = factory.saltFor(((uint88(1) << 87) - 1) - _nextTestTokenNonce[address(factory)]++);
            factory.enqueueSalts(tokenSalts);
        }
    }

    function _deployTestPublicHook(
        string memory artifact,
        uint160 flags,
        IPoolManager manager,
        address diamond,
        address weth
    ) private returns (IStaticsSwapFeeHook hook) {
        bytes memory constructorArgs = abi.encode(manager, diamond, uint16(25), uint16(25), weth);
        bytes memory creationCode = vm.getCode(artifact);
        (address expected, bytes32 salt) = HookMiner.find(address(this), flags, creationCode, constructorArgs);
        hook = IStaticsSwapFeeHook(vm.deployCode(artifact, constructorArgs, salt));
        assertEq(address(hook), expected);
    }
}
