// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsLaunchLiquidityHook} from "../../src/interfaces/IStaticsLaunchLiquidityHook.sol";
import {
    FormalLaunchPoolManager,
    FormalLaunchPositionManager,
    FormalLaunchToken,
    FormalStaticsLaunchLiquidityHook
} from "./mocks/FormalLaunchLiquidityMocks.sol";

contract StaticsLaunchLiquidityHookHalmosTest is SymTest, Test {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using PoolIdLibrary for PoolKey;

    uint160 private constant SQRT_PRICE_1_1 = 1 << 96;

    FormalLaunchToken private tokenA;
    FormalLaunchToken private tokenB;
    FormalLaunchPoolManager private manager;
    FormalLaunchPositionManager private positionManager;
    FormalStaticsLaunchLiquidityHook private hook;
    PoolKey private keyA;
    PoolKey private keyB;
    PoolId private poolA;
    PoolId private poolB;
    address private receiver;

    struct SwapCase {
        bool zeroForOne;
        bool exactInput;
        uint120 amount;
        uint16 feeBps;
    }

    function setUp() public {
        receiver = address(0xBEEF);
        tokenA = new FormalLaunchToken();
        tokenB = new FormalLaunchToken();
        manager = new FormalLaunchPoolManager();
        positionManager = new FormalLaunchPositionManager(IPoolManager(address(manager)));
        hook = new FormalStaticsLaunchLiquidityHook(
            IPoolManager(address(manager)), IPositionManager(address(positionManager)), address(this), receiver
        );

        (Currency currency0, Currency currency1) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));
        keyA = PoolKey({currency0: currency0, currency1: currency1, fee: 3_000, tickSpacing: 60, hooks: IHooks(hook)});
        keyB = PoolKey({currency0: currency0, currency1: currency1, fee: 5_000, tickSpacing: 100, hooks: IHooks(hook)});
        poolA = hook.registerPool(keyA, SQRT_PRICE_1_1, 25, 75);
        poolB = hook.registerPool(keyB, SQRT_PRICE_1_1, 100, 200);
    }

    function check_beforeSwapRoutesExactSpecifiedFee(bool zeroForOne, bool exactInput, uint120 amount, uint16 feeBps)
        public
    {
        vm.assume(amount > 0);
        vm.assume(feeBps <= hook.MAX_HOOK_FEE_BPS());
        _assertBeforeSwap(SwapCase(zeroForOne, exactInput, amount, feeBps));
    }

    function _assertBeforeSwap(SwapCase memory case_) private {
        hook.setHookFees(poolA, case_.feeBps, case_.feeBps);

        Currency specified = case_.zeroForOne == case_.exactInput ? keyA.currency0 : keyA.currency1;
        uint256 expected = Math.mulDiv(case_.amount, case_.feeBps, 10_000, Math.Rounding.Ceil);
        _token(specified).mint(address(manager), expected);

        (, BeforeSwapDelta returned, uint24 overrideFee) =
            manager.callBeforeSwap(IHooks(hook), keyA, _params(case_.zeroForOne, _specifiedAmount(case_)));

        assertEq(returned.getSpecifiedDelta(), int128(uint128(expected)));
        assertEq(returned.getUnspecifiedDelta(), 0);
        assertEq(overrideFee, 0);
        assertEq(specified.balanceOf(address(manager)), 0);
        assertEq(specified.balanceOf(receiver), expected);
        assertEq(keyA.currency0.balanceOf(address(hook)), 0);
        assertEq(keyA.currency1.balanceOf(address(hook)), 0);
    }

    function check_afterSwapRoutesExactUnspecifiedFee(uint64 amount, uint16 feeBps) public {
        _checkAfterSwap(amount, feeBps, true, true);
    }

    function _checkAfterSwap(uint64 amount, uint16 feeBps, bool zeroForOne, bool exactInput) private {
        vm.assume(amount > 0);
        vm.assume(feeBps <= hook.MAX_HOOK_FEE_BPS());
        _assertAfterSwap(SwapCase(zeroForOne, exactInput, amount, feeBps));
    }

    function _assertAfterSwap(SwapCase memory case_) private {
        hook.setHookFees(poolA, case_.feeBps, case_.feeBps);

        bool specifiedIsCurrency0 = case_.exactInput == case_.zeroForOne;
        Currency unspecified = specifiedIsCurrency0 ? keyA.currency1 : keyA.currency0;
        uint256 expected = Math.mulDiv(case_.amount, case_.feeBps, 10_000, Math.Rounding.Ceil);
        _token(unspecified).mint(address(manager), expected);

        (, int128 returned) = manager.callAfterSwap(
            IHooks(hook),
            keyA,
            _params(case_.zeroForOne, _specifiedAmount(case_)),
            _unspecifiedDelta(specifiedIsCurrency0, case_.amount)
        );

        assertEq(returned, int128(uint128(expected)));
        assertEq(unspecified.balanceOf(address(manager)), 0);
        assertEq(unspecified.balanceOf(receiver), expected);
        assertEq(keyA.currency0.balanceOf(address(hook)), 0);
        assertEq(keyA.currency1.balanceOf(address(hook)), 0);
    }

    function check_feeUpdatesRemainPoolLocal(uint16 inputFeeBps, uint16 outputFeeBps) public {
        vm.assume(inputFeeBps <= hook.MAX_HOOK_FEE_BPS());
        vm.assume(outputFeeBps <= hook.MAX_HOOK_FEE_BPS());
        IStaticsLaunchLiquidityHook.PoolRegistration memory otherBefore = hook.poolRegistration(poolB);

        hook.setHookFees(poolA, inputFeeBps, outputFeeBps);

        IStaticsLaunchLiquidityHook.PoolRegistration memory updated = hook.poolRegistration(poolA);
        IStaticsLaunchLiquidityHook.PoolRegistration memory otherAfter = hook.poolRegistration(poolB);
        assertEq(updated.inputFeeBps, inputFeeBps);
        assertEq(updated.outputFeeBps, outputFeeBps);
        assertEq(keccak256(abi.encode(otherAfter)), keccak256(abi.encode(otherBefore)));
    }

    function check_receiverUpdatePreservesEveryPool(address nextReceiver) public {
        vm.assume(nextReceiver != address(0));
        vm.assume(nextReceiver != address(hook));
        vm.assume(nextReceiver != address(manager));
        IStaticsLaunchLiquidityHook.PoolRegistration memory beforeA = hook.poolRegistration(poolA);
        IStaticsLaunchLiquidityHook.PoolRegistration memory beforeB = hook.poolRegistration(poolB);

        hook.setFeeReceiver(nextReceiver);

        assertEq(hook.feeReceiver(), nextReceiver);
        assertEq(keccak256(abi.encode(hook.poolRegistration(poolA))), keccak256(abi.encode(beforeA)));
        assertEq(keccak256(abi.encode(hook.poolRegistration(poolB))), keccak256(abi.encode(beforeB)));
    }

    function check_initializationAcceptsOnlyBoundManagerAndPrice(address sender, uint160 sqrtPriceX96) public {
        (bool success,) = address(manager)
            .call(abi.encodeCall(manager.callAfterInitialize, (IHooks(hook), sender, keyA, sqrtPriceX96)));
        bool shouldSucceed = sender == address(positionManager) && sqrtPriceX96 == SQRT_PRICE_1_1;
        assertEq(success, shouldSucceed);
    }

    function check_unauthorizedCallerCannotChangeConfiguration(address caller, uint16 inputFeeBps, uint16 outputFeeBps)
        public
    {
        vm.assume(caller != address(this));
        IStaticsLaunchLiquidityHook.PoolRegistration memory beforeA = hook.poolRegistration(poolA);
        address receiverBefore = hook.feeReceiver();

        vm.startPrank(caller);
        (bool feeSuccess,) = address(hook).call(abi.encodeCall(hook.setHookFees, (poolA, inputFeeBps, outputFeeBps)));
        (bool receiverSuccess,) = address(hook).call(abi.encodeCall(hook.setFeeReceiver, (caller)));
        vm.stopPrank();

        assertFalse(feeSuccess);
        assertFalse(receiverSuccess);
        assertEq(keccak256(abi.encode(hook.poolRegistration(poolA))), keccak256(abi.encode(beforeA)));
        assertEq(hook.feeReceiver(), receiverBefore);
    }

    function _params(bool zeroForOne, int256 amountSpecified) private pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: 0});
    }

    function _specifiedAmount(SwapCase memory case_) private pure returns (int256) {
        int256 amount = int256(uint256(case_.amount));
        return case_.exactInput ? -amount : amount;
    }

    function _unspecifiedDelta(bool specifiedIsCurrency0, uint120 amount) private pure returns (BalanceDelta) {
        int128 signedAmount = int128(uint128(amount));
        return specifiedIsCurrency0 ? toBalanceDelta(0, signedAmount) : toBalanceDelta(signedAmount, 0);
    }

    function _token(Currency currency) private pure returns (FormalLaunchToken) {
        return FormalLaunchToken(Currency.unwrap(currency));
    }
}
