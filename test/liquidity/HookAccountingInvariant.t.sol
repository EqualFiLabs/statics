// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {StaticsSwapFeeHook} from "../../src/liquidity/StaticsSwapFeeHook.sol";

contract HookInvariantDiamond {
    function register(StaticsSwapFeeHook hook, PoolKey calldata key) external {
        hook.registerPool(key);
    }

    function withdraw(StaticsSwapFeeHook hook, PoolId poolId) external {
        hook.withdrawPoolFees(poolId);
    }
}

contract HookAccountingHandler is Test {
    IPoolManager private immutable manager;
    PoolSwapTest private immutable router;
    StaticsSwapFeeHook private immutable hook;
    HookInvariantDiamond private immutable diamond;
    PoolKey private first;
    PoolKey private second;

    constructor(
        IPoolManager manager_,
        PoolSwapTest router_,
        StaticsSwapFeeHook hook_,
        HookInvariantDiamond diamond_,
        PoolKey memory first_,
        PoolKey memory second_
    ) {
        manager = manager_;
        router = router_;
        hook = hook_;
        diamond = diamond_;
        first = first_;
        second = second_;
        MockERC20(Currency.unwrap(first.currency0)).approve(address(router_), type(uint256).max);
        MockERC20(Currency.unwrap(first.currency1)).approve(address(router_), type(uint256).max);
    }

    function swapFirst(uint256 rawAmount, bool zeroForOne) external {
        _swap(first, rawAmount, zeroForOne);
    }

    function swapSecond(uint256 rawAmount, bool zeroForOne) external {
        _swap(second, rawAmount, zeroForOne);
    }

    function withdrawFirst() external {
        diamond.withdraw(hook, first.toId());
    }

    function withdrawSecond() external {
        diamond.withdraw(hook, second.toId());
    }

    function _swap(PoolKey storage stored, uint256 rawAmount, bool zeroForOne) private {
        uint256 amount = bound(rawAmount, 1_000, 0.001 ether);
        PoolKey memory poolKey = stored;
        try router.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {}
            catch {}
    }

    uint160 private constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 private constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
}

contract HookAccountingInvariantTest is StdInvariant, Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint160 private constant REQUIRED_FLAGS =
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    StaticsSwapFeeHook private hook;
    HookInvariantDiamond private diamond;
    PoolKey private first;
    PoolKey private second;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        diamond = new HookInvariantDiamond();
        hook = _deployHook();
        first = _initializePool(500, 10);
        second = _initializePool(3_000, 60);

        HookAccountingHandler handler = new HookAccountingHandler(manager, swapRouter, hook, diamond, first, second);
        MockERC20(Currency.unwrap(currency0)).mint(address(handler), 1_000_000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(handler), 1_000_000 ether);
        targetContract(address(handler));
    }

    function invariantPoolLiabilitiesSumToCurrencyLiability() public view {
        PoolId firstId = first.toId();
        PoolId secondId = second.toId();
        assertEq(
            hook.totalLiability(currency0), hook.accruedFees(firstId, currency0) + hook.accruedFees(secondId, currency0)
        );
        assertEq(
            hook.totalLiability(currency1), hook.accruedFees(firstId, currency1) + hook.accruedFees(secondId, currency1)
        );
    }

    function invariantPhysicalBalancesCoverAllHookLiabilities() public view {
        assertGe(currency0.balanceOf(address(hook)), hook.totalLiability(currency0));
        assertGe(currency1.balanceOf(address(hook)), hook.totalLiability(currency1));
    }

    function _initializePool(uint24 fee, int24 tickSpacing) private returns (PoolKey memory poolKey) {
        poolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(hook)
        });
        diamond.register(hook, poolKey);
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, "");
    }

    function _deployHook() private returns (StaticsSwapFeeHook deployed) {
        (address expected, bytes32 salt) = HookMiner.find(
            address(this),
            REQUIRED_FLAGS,
            type(StaticsSwapFeeHook).creationCode,
            abi.encode(manager, diamond, uint16(1))
        );
        deployed = new StaticsSwapFeeHook{salt: salt}(manager, address(diamond), 1);
        assertEq(address(deployed), expected);
    }
}
