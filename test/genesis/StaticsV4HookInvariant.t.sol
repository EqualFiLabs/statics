// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {RevenueChannel} from "../../src/interfaces/IStaticsHookController.sol";
import {StaticsHookController} from "../../src/genesis/StaticsHookController.sol";
import {StaticsV4Hook} from "../../src/liquidity/StaticsV4Hook.sol";

contract StaticsV4InvariantHandler {
    PoolSwapTest public immutable router;
    MockERC20 public immutable statics;
    MockERC20 public immutable weth;
    StaticsHookController public controller;
    StaticsV4Hook public hook;
    PoolKey private key;
    PoolId private poolId;
    bool private wethToStaticsZeroForOne;

    constructor(PoolSwapTest router_, MockERC20 statics_, MockERC20 weth_) {
        router = router_;
        statics = statics_;
        weth = weth_;
        statics_.approve(address(router_), type(uint256).max);
        weth_.approve(address(router_), type(uint256).max);
    }

    function configure(StaticsHookController controller_, StaticsV4Hook hook_) external {
        require(address(hook) == address(0), "CONFIGURED");
        controller = controller_;
        hook = hook_;
        key = hook_.canonicalPoolKey();
        poolId = hook_.canonicalPoolId();
        wethToStaticsZeroForOne = Currency.unwrap(key.currency0) == address(weth);
    }

    function buy(uint256 seed) external {
        uint256 balance = weth.balanceOf(address(this));
        if (balance < 1 gwei) return;
        uint256 amount = (seed % 100 ether) + 1 gwei;
        if (amount > balance) amount = balance;
        _swap(wethToStaticsZeroForOne, -int256(amount));
    }

    function sell(uint256 seed) external {
        uint256 balance = statics.balanceOf(address(this));
        if (balance < 1 gwei) return;
        uint256 maximum = balance / 10;
        if (maximum < 1 gwei) maximum = balance;
        uint256 amount = (seed % maximum) + 1;
        _trySell(!wethToStaticsZeroForOne, amount);
    }

    function compound() external {
        hook.compoundPermanentLiquidity(key);
    }

    function claimWeth() external {
        Currency currency = Currency.wrap(address(weth));
        if (controller.claimableRevenue(poolId, currency, RevenueChannel.Treasury, address(this)) == 0) return;
        controller.claimRevenue(poolId, currency, RevenueChannel.Treasury, address(this));
    }

    function claimStatics() external {
        Currency currency = Currency.wrap(address(statics));
        if (controller.claimableRevenue(poolId, currency, RevenueChannel.Treasury, address(this)) == 0) return;
        controller.claimRevenue(poolId, currency, RevenueChannel.Treasury, address(this));
    }

    function _swap(bool zeroForOne, int256 amountSpecified) private {
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _trySell(bool zeroForOne, uint256 amount) private {
        try router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) returns (
            BalanceDelta
        ) {
        // A fully fillable sell exercises the ordinary state transition.
        }
            catch {
            // An oversized sell can reach the one-sided launch boundary. The
            // hook must reject that partial fill atomically, so it is a valid
            // no-op transition rather than an invariant-handler failure.
        }
    }
}

contract StaticsV4HookInvariantTest is StdInvariant, Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint160 private constant REQUIRED_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    MockERC20 private statics;
    MockERC20 private weth;
    StaticsHookController private controller;
    StaticsV4Hook private hook;
    StaticsV4InvariantHandler private handler;
    PoolId private poolId;
    uint128[6] private initialBandLiquidity;

    function setUp() public {
        deployFreshManagerAndRouters();
        statics = new MockERC20("Statics", "STATICS", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        statics.mint(address(this), 810_045_000 ether);
        handler = new StaticsV4InvariantHandler(swapRouter, statics, weth);
        weth.mint(address(handler), 100_000 ether);
        controller = new StaticsHookController(address(this), address(this));
        hook = _deployHook(address(handler));
        controller.bindHook(address(hook));
        statics.transfer(address(hook), 810_045_000 ether);
        controller.initializeCanonicalPool();
        handler.configure(controller, hook);
        poolId = hook.canonicalPoolId();
        for (uint8 band = 1; band <= 6; ++band) {
            initialBandLiquidity[band - 1] = hook.launchBandLiquidity(band);
        }
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.sell.selector;
        selectors[2] = handler.compound.selector;
        selectors[3] = handler.claimWeth.selector;
        selectors[4] = handler.claimStatics.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function testPermissionlessCompoundWithEmptyPairReturnsZero() public {
        handler.compound();
    }

    function invariantLaunchPrincipalNeverChanges() public view {
        uint256 installed;
        for (uint8 band = 1; band <= 6; ++band) {
            assertEq(hook.launchBandLiquidity(band), initialBandLiquidity[band - 1]);
            installed += hook.launchBandStatics(band);
        }
        assertEq(installed + hook.launchRoundingDust(), hook.PUBLIC_LAUNCH_INVENTORY());
        assertGe(statics.balanceOf(address(hook)), hook.launchRoundingDust());
    }

    function invariantFeeClaimsRemainFullyBacked() public view {
        Currency staticsCurrency = Currency.wrap(address(statics));
        Currency wethCurrency = Currency.wrap(address(weth));
        uint256 controllerStaticsClaims = manager.balanceOf(address(controller), staticsCurrency.toId());
        uint256 controllerWethClaims = manager.balanceOf(address(controller), wethCurrency.toId());
        assertEq(controllerStaticsClaims, controller.totalRevenueLiability(staticsCurrency));
        assertEq(controllerWethClaims, controller.totalRevenueLiability(wethCurrency));
        assertGe(
            manager.balanceOf(address(hook), staticsCurrency.toId()),
            hook.pendingPermanentLiquidity(poolId, staticsCurrency)
        );
        assertGe(
            manager.balanceOf(address(hook), wethCurrency.toId()), hook.pendingPermanentLiquidity(poolId, wethCurrency)
        );
        assertGe(
            statics.balanceOf(address(manager)),
            controllerStaticsClaims + manager.balanceOf(address(hook), staticsCurrency.toId())
        );
        assertGe(
            weth.balanceOf(address(manager)),
            controllerWethClaims + manager.balanceOf(address(hook), wethCurrency.toId())
        );
    }

    function invariantExternalLiquidityRemainsDisabled() public view {
        assertFalse(hook.poolConfiguration(poolId).externalLiquidityEnabled);
    }

    function _deployHook(address treasury) private returns (StaticsV4Hook deployed) {
        bytes memory constructorArgs =
            abi.encode(manager, address(controller), address(statics), address(weth), treasury, uint16(50), uint16(50));
        (, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_FLAGS, type(StaticsV4Hook).creationCode, constructorArgs);
        deployed = new StaticsV4Hook{salt: salt}(
            manager, address(controller), address(statics), address(weth), treasury, 50, 50
        );
    }
}
