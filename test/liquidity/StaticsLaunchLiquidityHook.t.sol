// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IStaticsLaunchLiquidityHook} from "../../src/interfaces/IStaticsLaunchLiquidityHook.sol";
import {StaticsLaunchLiquidityHook} from "../../src/liquidity/StaticsLaunchLiquidityHook.sol";

contract StaticsLaunchLiquidityHookTest is Test, Deployers, DeployPermit2 {
    using PoolIdLibrary for PoolKey;

    uint24 private constant LP_FEE = 3_000;
    int24 private constant TICK_SPACING = 60;
    uint16 private constant INPUT_FEE_BPS = 35;
    uint16 private constant OUTPUT_FEE_BPS = 80;
    uint160 private constant REQUIRED_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    address private feeReceiver = makeAddr("feeReceiver");
    address private outsider = makeAddr("outsider");
    PositionManager private positionManagerContract;
    StaticsLaunchLiquidityHook private hook;
    PoolId private poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        IAllowanceTransfer permit2 = IAllowanceTransfer(deployPermit2());
        positionManagerContract =
            new PositionManager(manager, permit2, 100_000, IPositionDescriptor(address(0)), IWETH9(address(0)));
        hook = _deployHook(IPositionManager(address(positionManagerContract)));
        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: LP_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(hook)
        });
        poolId = hook.registerPool(key, SQRT_PRICE_1_1, INPUT_FEE_BPS, OUTPUT_FEE_BPS);
        positionManagerContract.initializePool(key, SQRT_PRICE_1_1);

        LIQUIDITY_PARAMS.liquidityDelta = 1e18;
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function testStoresExplicitPoolConfigurationAndExactPermissionMask() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, REQUIRED_FLAGS);
        assertEq(hook.positionManager(), address(positionManagerContract));
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.afterInitialize);
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertTrue(permissions.beforeSwapReturnDelta);
        assertTrue(permissions.afterSwapReturnDelta);
        assertFalse(permissions.beforeAddLiquidity);
        assertFalse(permissions.afterAddLiquidity);
        assertFalse(permissions.beforeRemoveLiquidity);
        assertFalse(permissions.afterRemoveLiquidity);
        assertLt(address(hook).code.length, 24_576);

        IStaticsLaunchLiquidityHook.PoolRegistration memory registration = hook.poolRegistration(poolId);
        assertTrue(registration.registered);
        assertEq(Currency.unwrap(registration.currency0), Currency.unwrap(currency0));
        assertEq(Currency.unwrap(registration.currency1), Currency.unwrap(currency1));
        assertEq(registration.nativeLpFee, LP_FEE);
        assertEq(registration.tickSpacing, TICK_SPACING);
        assertEq(registration.expectedSqrtPriceX96, SQRT_PRICE_1_1);
        assertEq(registration.inputFeeBps, INPUT_FEE_BPS);
        assertEq(registration.outputFeeBps, OUTPUT_FEE_BPS);
    }

    function testRegistersDifferentStaticNativeFeesAcrossPools() public {
        PoolKey memory second = key;
        second.fee = 5_000;
        PoolId secondId = hook.registerPool(second, SQRT_PRICE_1_1, 10, 20);

        assertTrue(PoolId.unwrap(secondId) != PoolId.unwrap(poolId));
        assertEq(hook.poolRegistration(secondId).nativeLpFee, 5_000);
        assertEq(hook.poolRegistration(poolId).nativeLpFee, LP_FEE);
    }

    function testMultiplePoolsRouteIndependentConfiguredFees() public {
        PoolKey memory second = key;
        second.fee = 5_000;
        PoolId secondId = hook.registerPool(second, SQRT_PRICE_1_1, 100, 200);
        positionManagerContract.initializePool(second, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(second, LIQUIDITY_PARAMS, ZERO_BYTES);

        uint256 amountIn = 0.001 ether;
        uint256 receiverBefore = currency0.balanceOf(feeReceiver);
        swap(second, true, -int256(amountIn), ZERO_BYTES);
        assertEq(
            currency0.balanceOf(feeReceiver) - receiverBefore, Math.mulDiv(amountIn, 100, 10_000, Math.Rounding.Ceil)
        );
        assertEq(hook.poolRegistration(secondId).inputFeeBps, 100);
        assertEq(hook.poolRegistration(poolId).inputFeeBps, INPUT_FEE_BPS);
    }

    function testRejectsDynamicNativeFeeAndHookFeesAboveCap() public {
        PoolKey memory invalid = key;
        invalid.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        vm.expectRevert(StaticsLaunchLiquidityHook.DynamicNativeLpFeeUnsupported.selector);
        hook.registerPool(invalid, SQRT_PRICE_1_1, 0, 0);

        PoolKey memory second = key;
        second.fee = 5_000;
        vm.expectRevert(abi.encodeWithSelector(StaticsLaunchLiquidityHook.HookFeeTooLarge.selector, uint16(1_001)));
        hook.registerPool(second, SQRT_PRICE_1_1, 1_001, 0);
    }

    function testRejectsDirectInitializationAndWrongPositionManagerPrice() public {
        PoolKey memory second = key;
        second.fee = 5_000;
        hook.registerPool(second, SQRT_PRICE_1_1, 0, 0);

        vm.expectRevert();
        manager.initialize(second, SQRT_PRICE_1_1);
        assertEq(positionManagerContract.initializePool(second, SQRT_PRICE_1_1 + 1), type(int24).max);
        assertEq(positionManagerContract.initializePool(second, SQRT_PRICE_1_1), 0);
    }

    function testExactInputRoutesConfiguredBilateralFees() public {
        _assertSwapAccounting(true, -int256(0.001 ether), INPUT_FEE_BPS, OUTPUT_FEE_BPS);
    }

    function testExactOutputRoutesConfiguredBilateralFees() public {
        _assertSwapAccounting(false, int256(0.0005 ether), OUTPUT_FEE_BPS, INPUT_FEE_BPS);
    }

    function testFuzzConfiguredFeeAccounting(bool zeroForOne, bool exactInput, uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 1_000, exactInput ? 0.0005 ether : 0.00025 ether);
        int256 amountSpecified = exactInput ? -int256(amount) : int256(amount);
        _assertSwapAccounting(
            zeroForOne,
            amountSpecified,
            exactInput ? INPUT_FEE_BPS : OUTPUT_FEE_BPS,
            exactInput ? OUTPUT_FEE_BPS : INPUT_FEE_BPS
        );
    }

    function testOwnerCanChangePoolFeesWithoutChangingOtherConfiguration() public {
        hook.setHookFees(poolId, 100, 200);
        IStaticsLaunchLiquidityHook.PoolRegistration memory registration = hook.poolRegistration(poolId);
        assertEq(registration.inputFeeBps, 100);
        assertEq(registration.outputFeeBps, 200);
        assertEq(registration.nativeLpFee, LP_FEE);
        assertEq(registration.expectedSqrtPriceX96, SQRT_PRICE_1_1);

        _assertSwapAccounting(true, -int256(0.001 ether), 100, 200);
    }

    function testOwnerCanChangeReceiverForFutureFees() public {
        address replacement = makeAddr("replacement");
        hook.setFeeReceiver(replacement);
        feeReceiver = replacement;
        _assertSwapAccounting(false, -int256(0.001 ether), INPUT_FEE_BPS, OUTPUT_FEE_BPS);
    }

    function testUnauthorizedConfigurationChangesRevert() public {
        vm.startPrank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        hook.setHookFees(poolId, 1, 2);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        hook.setFeeReceiver(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        hook.registerPool(key, SQRT_PRICE_1_1, 1, 2);
        vm.stopPrank();
    }

    function testRejectsInvalidReceiverAndFeeUpdatesAboveCap() public {
        vm.expectRevert(StaticsLaunchLiquidityHook.InvalidReceiver.selector);
        hook.setFeeReceiver(address(0));
        vm.expectRevert(StaticsLaunchLiquidityHook.InvalidReceiver.selector);
        hook.setFeeReceiver(address(hook));
        vm.expectRevert(StaticsLaunchLiquidityHook.InvalidReceiver.selector);
        hook.setFeeReceiver(address(manager));
        vm.expectRevert(abi.encodeWithSelector(StaticsLaunchLiquidityHook.HookFeeTooLarge.selector, uint16(1_001)));
        hook.setHookFees(poolId, 0, 1_001);
    }

    function _assertSwapAccounting(
        bool zeroForOne,
        int256 amountSpecified,
        uint16 specifiedFeeBps,
        uint16 unspecifiedFeeBps
    ) private {
        bool exactInput = amountSpecified < 0;
        Currency specified = (zeroForOne == exactInput) ? currency0 : currency1;
        Currency unspecified = specified == currency0 ? currency1 : currency0;
        uint256 specifiedRealized = _absolute(amountSpecified);
        uint256 specifiedFee = Math.mulDiv(specifiedRealized, specifiedFeeBps, 10_000, Math.Rounding.Ceil);
        uint256 specifiedReceiverBefore = specified.balanceOf(feeReceiver);
        uint256 unspecifiedReceiverBefore = unspecified.balanceOf(feeReceiver);

        BalanceDelta delta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        bool specifiedCurrencyIs0 = exactInput == zeroForOne;
        int128 unspecifiedDelta = specifiedCurrencyIs0 ? delta.amount1() : delta.amount0();
        uint256 unspecifiedFee = exactInput
            ? _feeFromNet(_absolute(int256(unspecifiedDelta)), unspecifiedFeeBps)
            : _feeFromGross(_absolute(int256(unspecifiedDelta)), unspecifiedFeeBps);

        assertEq(specified.balanceOf(feeReceiver) - specifiedReceiverBefore, specifiedFee);
        assertApproxEqAbs(unspecified.balanceOf(feeReceiver) - unspecifiedReceiverBefore, unspecifiedFee, 1);
        assertEq(currency0.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);
    }

    function _deployHook(IPositionManager positionManager_) private returns (StaticsLaunchLiquidityHook deployed) {
        bytes memory constructorArgs = abi.encode(manager, positionManager_, address(this), feeReceiver);
        (address expected, bytes32 salt) = HookMiner.find(
            address(this), REQUIRED_FLAGS, type(StaticsLaunchLiquidityHook).creationCode, constructorArgs
        );
        deployed = new StaticsLaunchLiquidityHook{salt: salt}(manager, positionManager_, address(this), feeReceiver);
        assertEq(address(deployed), expected);
    }

    function _feeFromNet(uint256 netAmount, uint256 feeBps) private pure returns (uint256) {
        return Math.mulDiv(netAmount, feeBps, 10_000 - feeBps, Math.Rounding.Ceil);
    }

    function _feeFromGross(uint256 grossAmount, uint256 feeBps) private pure returns (uint256) {
        return Math.mulDiv(grossAmount, feeBps, 10_000 + feeBps, Math.Rounding.Ceil);
    }

    function _absolute(int256 value) private pure returns (uint256) {
        return value < 0 ? uint256(-(value + 1)) + 1 : uint256(value);
    }
}
