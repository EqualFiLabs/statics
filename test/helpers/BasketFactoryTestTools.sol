// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {StaticsBasketFactory} from "../../src/liquidity/StaticsBasketFactory.sol";

/// @dev Local executable CreateX fixture and test-only offchain-equivalent salt provisioning.
/// Production callers supply SDK-mined salts; no production deployment mines inside a transaction.
abstract contract BasketFactoryTestTools is Test {
    mapping(address => uint88) private _nextTestHookNonce;
    mapping(address => uint88) private _nextTestTokenNonce;

    function _deployTestBasketFactory(address diamond, IPoolManager manager, IStaticsSwapFeeHook policy)
        internal
        returns (StaticsBasketFactory factory)
    {
        vm.etch(
            0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed,
            vm.parseJsonBytes(vm.readFile("test/fixtures/createx-v1.json"), ".runtime")
        );
        factory = StaticsBasketFactory(
            deployCode("out/StaticsBasketFactory.sol/StaticsBasketFactory.json", abi.encode(diamond, manager, policy))
        );
    }

    function _ensureTestBasketSalts(StaticsBasketFactory factory, uint256 hookCount) internal {
        (uint256 tokens, uint256 hooks) = factory.queueAvailability();
        if (tokens == 0) {
            bytes32[] memory tokenSalts = new bytes32[](1);
            tokenSalts[0] = factory.saltFor(type(uint88).max - _nextTestTokenNonce[address(factory)]++);
            factory.enqueueSalts(tokenSalts, false);
        }
        if (hooks >= hookCount) return;
        bytes32[] memory hookSalts = new bytes32[](hookCount - hooks);
        uint88 nonce = _nextTestHookNonce[address(factory)];
        for (uint256 i; i < hookSalts.length; ++i) {
            (hookSalts[i], nonce) = _mineTestHook(factory, nonce);
        }
        _nextTestHookNonce[address(factory)] = nonce;
        factory.enqueueSalts(hookSalts, true);
    }

    function _mineTestHook(StaticsBasketFactory factory, uint88 start)
        internal
        view
        returns (bytes32 salt, uint88 next)
    {
        uint256 prefix = uint256(factory.saltFor(0));
        address createX = factory.CREATE_X();
        bytes32 proxyHash = factory.CREATE3_PROXY_HASH();
        for (uint256 nonce = start; nonce < uint256(start) + 1_000_000; ++nonce) {
            salt = bytes32(prefix | nonce);
            if (uint160(_testCreate3Address(address(factory), salt, createX, proxyHash)) & ((1 << 14) - 1) == 0x1fec) {
                return (salt, uint88(nonce + 1));
            }
        }
        revert("test salt search exhausted");
    }

    /// @dev Reuse scratch memory so test-only mining does not accumulate hundreds of thousands of ABI buffers.
    function _testCreate3Address(address factory, bytes32 salt, address createX, bytes32 proxyHash)
        private
        view
        returns (address predicted)
    {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, factory)
            mstore(add(p, 32), chainid())
            mstore(add(p, 64), salt)
            let effective := keccak256(p, 96)
            mstore8(p, 0xff)
            mstore(add(p, 1), shl(96, createX))
            mstore(add(p, 21), effective)
            mstore(add(p, 53), proxyHash)
            let proxy := and(keccak256(p, 85), 0xffffffffffffffffffffffffffffffffffffffff)
            mstore(p, shl(240, 0xd694))
            mstore(add(p, 2), shl(96, proxy))
            mstore8(add(p, 22), 1)
            predicted := and(keccak256(p, 23), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }
}
