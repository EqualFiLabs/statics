// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {LiquidityOperations} from "@uniswap/v4-periphery/test/shared/LiquidityOperations.sol";
import {Plan, Planner} from "@uniswap/v4-periphery/test/shared/Planner.sol";
import {PositionConfig} from "@uniswap/v4-periphery/test/shared/PositionConfig.sol";
import {StaticsLaunchLiquidityHook} from "../../../src/liquidity/StaticsLaunchLiquidityHook.sol";

/// @notice Reproduces a realistically priced, externally managed STATICS/NVDA launch using the
/// deployed Robinhood v4 contracts and tokens through a local Anvil mainnet fork.
contract RobinhoodRealisticLaunchLiquidityForkTest is Test, LiquidityOperations {
    using Planner for Plan;
    using PoolIdLibrary for PoolKey;

    string private constant MANIFEST_PATH = "deployments/robinhood-chain-4663.json";
    address private constant STATICS = 0x2d8d6F4A93AcD7a916A5a654ec8b690bA3B3EAdd;
    address private constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    uint256 private constant STATICS_USD_NUMERATOR = 1_744;
    uint256 private constant STATICS_USD_DENOMINATOR = 100_000;
    uint256 private constant NVDA_USD_PRICE = 230;
    uint256 private constant LAUNCH_USD_NOTIONAL = 10_000 ether;
    uint256 private constant SWAP_USD_NOTIONAL = 100_000 ether;
    uint256 private constant SWAPS_PER_DIRECTION = 10;

    uint160 private constant INITIAL_SQRT_PRICE_X96 = 689_904_386_145_184_590_450_493_103;
    int24 private constant LAUNCH_TICK_LOWER = -94_860;
    int24 private constant LAUNCH_TICK_UPPER = -90_780;
    int24 private constant NARROW_TICK_LOWER = -95_460;
    int24 private constant NARROW_TICK_UPPER = -94_260;
    int24 private constant BROAD_TICK_LOWER = -96_660;
    int24 private constant BROAD_TICK_UPPER = -93_060;

    uint160 private constant REQUIRED_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    IPoolManager private poolManager;
    IPositionManager private positionManager;
    IAllowanceTransfer private permit2;
    PoolSwapTest private swapRouter;
    StaticsLaunchLiquidityHook private hook;
    PoolKey private key;

    address private positionOwner = makeAddr("positionOwner");
    address private initialFeeReceiver = makeAddr("initialFeeReceiver");
    address private replacementFeeReceiver = makeAddr("replacementFeeReceiver");

    PositionConfig private launchPosition;
    PositionConfig private narrowPosition;
    PositionConfig private broadPosition;
    uint128 private launchLiquidity;
    uint128 private narrowLiquidity;
    uint128 private broadLiquidity;
    uint256 private launchTokenId;
    uint256 private narrowTokenId;
    uint256 private broadTokenId;

    function setUp() public {
        _selectLatestFork();
        assertGt(STATICS.code.length, 0);
        assertGt(NVDA.code.length, 0);
        assertLt(uint160(STATICS), uint160(NVDA));
        assertLt(INITIAL_SQRT_PRICE_X96, TickMath.getSqrtPriceAtTick(LAUNCH_TICK_LOWER));

        string memory manifest = vm.readFile(MANIFEST_PATH);
        poolManager = IPoolManager(vm.parseJsonAddress(manifest, ".contracts.poolManager.address"));
        positionManager = IPositionManager(vm.parseJsonAddress(manifest, ".contracts.positionManager.address"));
        permit2 = IAllowanceTransfer(vm.parseJsonAddress(manifest, ".contracts.permit2.address"));
        assertEq(address(poolManager).codehash, vm.parseJsonBytes32(manifest, ".contracts.poolManager.runtimeCodeHash"));
        assertEq(
            address(positionManager).codehash,
            vm.parseJsonBytes32(manifest, ".contracts.positionManager.runtimeCodeHash")
        );
        assertEq(address(permit2).codehash, vm.parseJsonBytes32(manifest, ".contracts.permit2.runtimeCodeHash"));

        lpm = positionManager;
        _deadline = block.timestamp + 1 hours;
        swapRouter = new PoolSwapTest(poolManager);
        // Synthetic funding isolates the integration lifecycle from changing holder balances.
        // Approvals, transfers, PositionManager settlement, swaps, and fee routing still execute
        // through the forked production token and v4 contracts.
        deal(STATICS, address(this), 100_000_000 ether, true);
        deal(NVDA, address(this), 100_000_000 ether, true);

        hook = _deployHook();
        key = PoolKey({
            currency0: Currency.wrap(STATICS),
            currency1: Currency.wrap(NVDA),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        hook.registerPool(key, INITIAL_SQRT_PRICE_X96, 50, 50, positionOwner);

        _approvePositionManager(STATICS);
        _approvePositionManager(NVDA);
        IERC20(STATICS).approve(address(swapRouter), type(uint256).max);
        IERC20(NVDA).approve(address(swapRouter), type(uint256).max);

        _createPositions();
    }

    function testRealisticSingleSidedLaunchAndHundredThousandUsdLifecycle() public {
        assertEq(IERC721(address(positionManager)).ownerOf(launchTokenId), positionOwner);
        assertEq(IERC721(address(positionManager)).ownerOf(narrowTokenId), positionOwner);
        assertEq(IERC721(address(positionManager)).ownerOf(broadTokenId), positionOwner);
        assertEq(lpm.getPositionLiquidity(launchTokenId), launchLiquidity);
        assertEq(lpm.getPositionLiquidity(narrowTokenId), narrowLiquidity);
        assertEq(lpm.getPositionLiquidity(broadTokenId), broadLiquidity);
        assertEq(IERC20(STATICS).balanceOf(address(hook)), 0);
        assertEq(IERC20(NVDA).balanceOf(address(hook)), 0);

        hook.setHookFees(key.toId(), 75, 125);
        hook.setFeeReceiver(replacementFeeReceiver);

        uint256 staticsInputPerSwap =
            (SWAP_USD_NOTIONAL / 2) * STATICS_USD_DENOMINATOR / STATICS_USD_NUMERATOR / SWAPS_PER_DIRECTION;
        uint256 nvdaInputPerSwap = (SWAP_USD_NOTIONAL / 2) / NVDA_USD_PRICE / SWAPS_PER_DIRECTION;
        uint256 totalStaticsInput;
        uint256 totalNvdaInput;
        for (uint256 i; i < SWAPS_PER_DIRECTION; ++i) {
            _swap(true, staticsInputPerSwap);
            _swap(false, nvdaInputPerSwap);
            totalStaticsInput += staticsInputPerSwap;
            totalNvdaInput += nvdaInputPerSwap;
        }

        uint256 totalUsdNotional =
            totalStaticsInput * STATICS_USD_NUMERATOR / STATICS_USD_DENOMINATOR + totalNvdaInput * NVDA_USD_PRICE;
        assertApproxEqAbs(totalUsdNotional, SWAP_USD_NOTIONAL, 2_000);
        assertEq(poolManager.balanceOf(initialFeeReceiver, Currency.wrap(STATICS).toId()), 0);
        assertEq(poolManager.balanceOf(initialFeeReceiver, Currency.wrap(NVDA).toId()), 0);
        assertGt(poolManager.balanceOf(replacementFeeReceiver, Currency.wrap(STATICS).toId()), 0);
        assertGt(poolManager.balanceOf(replacementFeeReceiver, Currency.wrap(NVDA).toId()), 0);
        assertEq(IERC20(STATICS).balanceOf(address(hook)), 0);
        assertEq(IERC20(NVDA).balanceOf(address(hook)), 0);

        uint128 liquidityToRemove = launchLiquidity / 10;
        vm.prank(positionOwner);
        positionManager.modifyLiquidities(
            getDecreaseEncoded(launchTokenId, launchPosition, liquidityToRemove, ""), block.timestamp + 1
        );
        assertEq(lpm.getPositionLiquidity(launchTokenId), launchLiquidity - liquidityToRemove);
        assertEq(lpm.getPositionLiquidity(narrowTokenId), narrowLiquidity);
        assertEq(lpm.getPositionLiquidity(broadTokenId), broadLiquidity);

        uint256 receiverStaticsBefore = poolManager.balanceOf(replacementFeeReceiver, Currency.wrap(STATICS).toId());
        _swap(true, 1_000 ether);
        assertGt(poolManager.balanceOf(replacementFeeReceiver, Currency.wrap(STATICS).toId()), receiverStaticsBefore);
    }

    function _createPositions() private {
        launchPosition = PositionConfig({poolKey: key, tickLower: LAUNCH_TICK_LOWER, tickUpper: LAUNCH_TICK_UPPER});
        uint256 launchStaticsAmount = LAUNCH_USD_NOTIONAL * STATICS_USD_DENOMINATOR / STATICS_USD_NUMERATOR;
        launchLiquidity = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(LAUNCH_TICK_LOWER),
            TickMath.getSqrtPriceAtTick(LAUNCH_TICK_UPPER),
            launchStaticsAmount
        );
        launchTokenId = lpm.nextTokenId();
        uint256 staticsBefore = IERC20(STATICS).balanceOf(address(this));
        uint256 nvdaBefore = IERC20(NVDA).balanceOf(address(this));
        _initializeAndMintSingleSided(launchStaticsAmount);
        assertApproxEqAbs(staticsBefore - IERC20(STATICS).balanceOf(address(this)), launchStaticsAmount, 32);
        assertEq(nvdaBefore - IERC20(NVDA).balanceOf(address(this)), 0);

        narrowPosition = PositionConfig({poolKey: key, tickLower: NARROW_TICK_LOWER, tickUpper: NARROW_TICK_UPPER});
        narrowLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            INITIAL_SQRT_PRICE_X96,
            TickMath.getSqrtPriceAtTick(NARROW_TICK_LOWER),
            TickMath.getSqrtPriceAtTick(NARROW_TICK_UPPER),
            35_000_000 ether,
            3_000 ether
        );
        narrowTokenId = lpm.nextTokenId();
        mint(narrowPosition, narrowLiquidity, positionOwner, "");

        broadPosition = PositionConfig({poolKey: key, tickLower: BROAD_TICK_LOWER, tickUpper: BROAD_TICK_UPPER});
        broadLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            INITIAL_SQRT_PRICE_X96,
            TickMath.getSqrtPriceAtTick(BROAD_TICK_LOWER),
            TickMath.getSqrtPriceAtTick(BROAD_TICK_UPPER),
            20_000_000 ether,
            1_500 ether
        );
        broadTokenId = lpm.nextTokenId();
        mint(broadPosition, broadLiquidity, positionOwner, "");
        vm.prank(positionOwner);
        hook.activatePool(key.toId());
    }

    function _initializeAndMintSingleSided(uint256 launchStaticsAmount) private {
        Plan memory plan = Planner.init();
        plan.add(
            Actions.MINT_POSITION,
            abi.encode(
                key,
                LAUNCH_TICK_LOWER,
                LAUNCH_TICK_UPPER,
                launchLiquidity,
                uint128(launchStaticsAmount + 1),
                uint128(0),
                positionOwner,
                bytes("")
            )
        );
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(positionManager.initializePool, (key, INITIAL_SQRT_PRICE_X96));
        calls[1] = abi.encodeCall(
            positionManager.modifyLiquidities, (plan.finalizeModifyLiquidityWithSettlePair(key), block.timestamp + 1)
        );
        positionManager.multicall(calls);
    }

    function _swap(bool zeroForOne, uint256 amountIn) private {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _approvePositionManager(address token) private {
        IERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, address(positionManager), type(uint160).max, type(uint48).max);
    }

    function _deployHook() private returns (StaticsLaunchLiquidityHook deployed) {
        bytes memory args = abi.encode(poolManager, positionManager, address(this), initialFeeReceiver);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_HOOK_FLAGS, type(StaticsLaunchLiquidityHook).creationCode, args);
        deployed =
            new StaticsLaunchLiquidityHook{salt: salt}(poolManager, positionManager, address(this), initialFeeReceiver);
        assertEq(address(deployed), expected);
    }

    function _selectLatestFork() private {
        if (block.chainid == 4_663 && STATICS.code.length != 0 && NVDA.code.length != 0) return;
        string memory rpcUrl = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_ROBINHOOD_FORK", false)) fail("Robinhood fork required");
            vm.skip(true, "ROBINHOOD_MAINNET is not configured");
            return;
        }
        vm.createSelectFork(rpcUrl);
        assertEq(block.chainid, 4_663);
    }
}
