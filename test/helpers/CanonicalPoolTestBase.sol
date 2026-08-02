// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {StaticsSwapFeeHook} from "../../src/liquidity/StaticsSwapFeeHook.sol";
import {StaticsTestBase} from "./StaticsTestBase.sol";

contract CanonicalV4Router is IUnlockCallback {
    using CurrencySettler for Currency;

    uint8 private constant MODIFY_LIQUIDITY = 1;
    uint8 private constant SWAP = 2;

    IPoolManager private immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function modifyLiquidity(PoolKey calldata key, ModifyLiquidityParams calldata params)
        external
        returns (BalanceDelta delta)
    {
        return abi.decode(
            manager.unlock(abi.encode(MODIFY_LIQUIDITY, msg.sender, key, abi.encode(params))), (BalanceDelta)
        );
    }

    function swap(PoolKey calldata key, SwapParams calldata params) external returns (BalanceDelta delta) {
        return abi.decode(manager.unlock(abi.encode(SWAP, msg.sender, key, abi.encode(params))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (uint8 action, address payer, PoolKey memory key, bytes memory params) =
            abi.decode(data, (uint8, address, PoolKey, bytes));
        BalanceDelta delta;
        if (action == MODIFY_LIQUIDITY) {
            (delta,) = manager.modifyLiquidity(key, abi.decode(params, (ModifyLiquidityParams)), "");
        } else if (action == SWAP) {
            delta = manager.swap(key, abi.decode(params, (SwapParams)), "");
        } else {
            revert();
        }
        _settle(key.currency0, delta.amount0(), payer);
        _settle(key.currency1, delta.amount1(), payer);
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta, address payer) private {
        if (delta < 0) currency.settle(manager, payer, uint256(-int256(delta)), false);
        if (delta > 0) currency.take(manager, payer, uint256(uint128(delta)), false);
    }
}

abstract contract CanonicalPoolTestBase is StaticsTestBase {
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;
    uint160 internal constant REQUIRED_HOOK_FLAGS =
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    IPoolManager internal poolManager;
    StaticsSwapFeeHook internal swapFeeHook;
    CanonicalV4Router internal v4Router;

    function setUp() public virtual override {
        super.setUp();
        poolManager = IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        swapFeeHook = _deployHook();
        basketLiquidity.installCanonicalPoolIntegration(address(poolManager), address(swapFeeHook));
        v4Router = new CanonicalV4Router(poolManager);
    }

    function _deployHook() private returns (StaticsSwapFeeHook deployed) {
        (address expected, bytes32 salt) = HookMiner.find(
            address(this),
            REQUIRED_HOOK_FLAGS,
            type(StaticsSwapFeeHook).creationCode,
            abi.encode(poolManager, address(diamond), uint16(1))
        );
        deployed = new StaticsSwapFeeHook{salt: salt}(poolManager, address(diamond), 1);
        assertEq(address(deployed), expected);
    }

    function _approveV4Router(address user, address token) internal {
        vm.prank(user);
        MockERC20(token).approve(address(v4Router), type(uint256).max);
    }
}
