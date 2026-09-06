// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IStaticsLaunchLiquidityHook} from "../../src/interfaces/IStaticsLaunchLiquidityHook.sol";
import {StaticsLaunchLiquidityHook} from "../../src/liquidity/StaticsLaunchLiquidityHook.sol";

contract StaticsLaunchLiquidityHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint24 private constant LP_FEE = 3_000;
    int24 private constant TICK_SPACING = 60;
    uint128 private constant EXTERNAL_LIQUIDITY = 1e18;
    uint128 private constant SEED_LIQUIDITY = 5e17;
    uint160 private constant REQUIRED_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    address private feeReceiver = makeAddr("feeReceiver");
    address private liquidityReceiver = makeAddr("liquidityReceiver");
    address private outsider = makeAddr("outsider");
    StaticsLaunchLiquidityHook private hook;
    PoolId private poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        hook = _deployHook();
        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: LP_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(hook)
        });
        poolId = hook.registerAndInitialize(key, SQRT_PRICE_1_1);

        LIQUIDITY_PARAMS.liquidityDelta = int256(uint256(EXTERNAL_LIQUIDITY));
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function testExactPermissionMaskAndStaticPoolRegistration() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, REQUIRED_FLAGS);
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
        assertFalse(permissions.beforeDonate);
        assertLt(address(hook).code.length, 24_576);

        IStaticsLaunchLiquidityHook.PoolRegistration memory registration = hook.poolRegistration(poolId);
        assertTrue(registration.registered);
        assertFalse(registration.retired);
        assertEq(key.fee, LP_FEE);
    }

    function testRejectsWrongNativeFeeAndUntrustedRegistration() public {
        PoolKey memory wrongFee = key;
        wrongFee.fee = 500;

        vm.expectRevert(abi.encodeWithSelector(StaticsLaunchLiquidityHook.OnlyLiquidityAdmin.selector, outsider));
        vm.prank(outsider);
        hook.registerAndInitialize(wrongFee, SQRT_PRICE_1_1);

        vm.expectRevert(abi.encodeWithSelector(StaticsLaunchLiquidityHook.InvalidNativeLpFee.selector, uint24(500)));
        hook.registerAndInitialize(wrongFee, SQRT_PRICE_1_1);
    }

    function testExactInputZeroForOneChargesBilateralFiftyBpsAndSplitsSixtyForty() public {
        _assertFirstSwapAccounting(true, -int256(0.001 ether));
    }

    function testExactInputOneForZeroChargesBilateralFiftyBpsAndSplitsSixtyForty() public {
        _assertFirstSwapAccounting(false, -int256(0.001 ether));
    }

    function testExactOutputZeroForOneChargesBilateralFiftyBpsAndSplitsSixtyForty() public {
        _assertFirstSwapAccounting(true, int256(0.0005 ether));
    }

    function testExactOutputOneForZeroChargesBilateralFiftyBpsAndSplitsSixtyForty() public {
        _assertFirstSwapAccounting(false, int256(0.0005 ether));
    }

    function testFuzzExactInputAccounting(bool zeroForOne, uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 1_000, 0.0005 ether);
        _assertFirstSwapAccounting(zeroForOne, -int256(amount));
    }

    function testFuzzExactOutputAccounting(bool zeroForOne, uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 1_000, 0.00025 ether);
        _assertFirstSwapAccounting(zeroForOne, int256(amount));
    }

    function testSeedPOLAndNativeFeesAreRevenueRatherThanPendingPOL() public {
        _seedPOL();
        uint128 liquidityBefore = hook.polLiquidity(poolId);
        uint256 receiver0Before = currency0.balanceOf(feeReceiver);
        uint256 receiver1Before = currency1.balanceOf(feeReceiver);

        uint256 amountIn = 0.01 ether;
        BalanceDelta delta = swap(key, true, -int256(amountIn), ZERO_BYTES);
        uint256 netOutput = uint256(uint128(delta.amount1()));
        uint256 inputFee = Math.mulDiv(amountIn, 50, 10_000, Math.Rounding.Ceil);
        uint256 outputFee = _feeFromNet(netOutput, 50);
        uint256 bilateralRevenue0 = inputFee - Math.mulDiv(inputFee, 4_000, 10_000);
        uint256 bilateralRevenue1 = outputFee - Math.mulDiv(outputFee, 4_000, 10_000);

        uint256 receiver0Delta = currency0.balanceOf(feeReceiver) - receiver0Before;
        uint256 receiver1Delta = currency1.balanceOf(feeReceiver) - receiver1Before;
        assertGe(receiver0Delta, bilateralRevenue0);
        assertGe(receiver1Delta, bilateralRevenue1);
        assertTrue(
            receiver0Delta > bilateralRevenue0 || receiver1Delta > bilateralRevenue1,
            "protocol position native fees not routed"
        );
        assertGt(hook.polLiquidity(poolId), liquidityBefore);
        assertEq(currency0.balanceOf(address(hook)), hook.pendingPOL(poolId, currency0));
        assertEq(currency1.balanceOf(address(hook)), hook.pendingPOL(poolId, currency1));
    }

    function testPermissionlessCompoundAndHarvestCannotRedirectRevenue() public {
        _seedPOL();
        swap(key, true, -int256(0.003 ether), ZERO_BYTES);

        vm.startPrank(outsider);
        hook.compoundPOL(key);
        hook.harvestPOLFees(key);
        vm.stopPrank();

        assertEq(currency0.balanceOf(outsider), 0);
        assertEq(currency1.balanceOf(outsider), 0);
        assertEq(currency0.balanceOf(address(hook)), hook.pendingPOL(poolId, currency0));
        assertEq(currency1.balanceOf(address(hook)), hook.pendingPOL(poolId, currency1));
    }

    function testHarvestBeforePOLExistsIsPermissionlessNoOp() public {
        vm.prank(outsider);
        (uint256 amount0, uint256 amount1) = hook.harvestPOLFees(key);
        assertEq(amount0, 0);
        assertEq(amount1, 0);
    }

    function testRetirementReleasesPOLWithoutBlockingExternalLiquidity() public {
        _seedPOL();
        swap(key, true, -int256(0.003 ether), ZERO_BYTES);
        uint256 receiver0Before = currency0.balanceOf(liquidityReceiver);
        uint256 receiver1Before = currency1.balanceOf(liquidityReceiver);

        hook.retireAndReleasePOL(key);

        assertEq(hook.polLiquidity(poolId), 0);
        assertEq(hook.pendingPOL(poolId, currency0), 0);
        assertEq(hook.pendingPOL(poolId, currency1), 0);
        assertTrue(currency0.balanceOf(liquidityReceiver) > receiver0Before);
        assertTrue(currency1.balanceOf(liquidityReceiver) > receiver1Before);
        assertTrue(hook.poolRegistration(poolId).retired);

        uint256 retiredSwapAmount = 0.001 ether;
        uint256 retiredInputReceiverBefore = currency1.balanceOf(feeReceiver);
        swap(key, false, -int256(retiredSwapAmount), ZERO_BYTES);
        assertEq(
            currency1.balanceOf(feeReceiver) - retiredInputReceiverBefore,
            Math.mulDiv(retiredSwapAmount, 50, 10_000, Math.Rounding.Ceil)
        );
        assertEq(hook.pendingPOL(poolId, currency0), 0);
        assertEq(hook.pendingPOL(poolId, currency1), 0);

        REMOVE_LIQUIDITY_PARAMS.liquidityDelta = -int256(uint256(EXTERNAL_LIQUIDITY));
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function testOnlyOwnerCanChangeFixedDestinationsAndOnlyAdminCanRelease() public {
        vm.startPrank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        hook.setFeeReceiver(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        hook.setLiquidityReceiver(outsider);
        vm.expectRevert(abi.encodeWithSelector(StaticsLaunchLiquidityHook.OnlyLiquidityAdmin.selector, outsider));
        hook.retireAndReleasePOL(key);
        vm.stopPrank();
    }

    function _assertFirstSwapAccounting(bool zeroForOne, int256 amountSpecified) private {
        bool exactInput = amountSpecified < 0;
        Currency specified = (zeroForOne == exactInput) ? currency0 : currency1;
        Currency unspecified = specified == currency0 ? currency1 : currency0;
        uint256 specifiedRealized = _absolute(amountSpecified);
        uint256 specifiedFee = Math.mulDiv(specifiedRealized, 50, 10_000, Math.Rounding.Ceil);
        uint256 specifiedReceiverBefore = specified.balanceOf(feeReceiver);
        uint256 unspecifiedReceiverBefore = unspecified.balanceOf(feeReceiver);

        BalanceDelta delta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        bool specifiedCurrencyIs0 = exactInput == zeroForOne;
        int128 unspecifiedDelta = specifiedCurrencyIs0 ? delta.amount1() : delta.amount0();
        uint256 unspecifiedFee = exactInput
            ? _feeFromNet(_absolute(int256(unspecifiedDelta)), 50)
            : _feeFromGross(_absolute(int256(unspecifiedDelta)), 50);

        _assertReceiverSplit(specified, specifiedReceiverBefore, specifiedFee);
        _assertReceiverSplitFromObservedNet(unspecified, unspecifiedReceiverBefore, unspecifiedFee);
        assertGt(hook.polLiquidity(poolId), 0);
        _assertTracked(specified);
        _assertTracked(unspecified);
    }

    function _assertReceiverSplit(Currency currency, uint256 receiverBefore, uint256 fee) private view {
        uint256 pol = Math.mulDiv(fee, 4_000, 10_000);
        assertEq(currency.balanceOf(feeReceiver) - receiverBefore, fee - pol);
    }

    /// @dev A post-hook net delta can map to either of two adjacent pre-hook realized values exactly
    /// at a ceil-rounding boundary. Both candidates preserve exact onchain 60/40 accounting.
    function _assertReceiverSplitFromObservedNet(Currency currency, uint256 receiverBefore, uint256 fee) private view {
        uint256 pol = Math.mulDiv(fee, 4_000, 10_000);
        assertApproxEqAbs(currency.balanceOf(feeReceiver) - receiverBefore, fee - pol, 1);
    }

    function _assertTracked(Currency currency) private view {
        assertEq(currency.balanceOf(address(hook)), hook.pendingPOL(poolId, currency));
    }

    function _seedPOL() private {
        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.seedPOL(key, SEED_LIQUIDITY, type(uint256).max, type(uint256).max);
        assertEq(hook.polLiquidity(poolId), SEED_LIQUIDITY);
    }

    function _deployHook() private returns (StaticsLaunchLiquidityHook deployed) {
        bytes memory constructorArgs = abi.encode(manager, address(this), feeReceiver, liquidityReceiver, address(this));
        (address expected, bytes32 salt) = HookMiner.find(
            address(this), REQUIRED_FLAGS, type(StaticsLaunchLiquidityHook).creationCode, constructorArgs
        );
        deployed = new StaticsLaunchLiquidityHook{salt: salt}(
            manager, address(this), feeReceiver, liquidityReceiver, address(this)
        );
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
