// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsLaunchLiquidityHook} from "../../src/interfaces/IStaticsLaunchLiquidityHook.sol";
import {StaticsLaunchLiquidityHook} from "../../src/liquidity/StaticsLaunchLiquidityHook.sol";
import {
    AdversarialLaunchToken,
    AdversarialPoolManager,
    AdversarialPositionManager
} from "../mocks/LaunchLiquidityAdversarialMocks.sol";

contract StaticsLaunchLiquidityHookAdversarialTest is Test {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using PoolIdLibrary for PoolKey;

    uint160 private constant SQRT_PRICE_1_1 = 1 << 96;
    uint160 private constant REQUIRED_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    address private receiver = makeAddr("receiver");
    address private outsider = makeAddr("outsider");
    AdversarialLaunchToken private tokenA;
    AdversarialLaunchToken private tokenB;
    AdversarialPoolManager private manager;
    AdversarialPositionManager private positionManager;
    StaticsLaunchLiquidityHook private hook;
    PoolKey private key;
    PoolId private poolId;

    struct FeeCase {
        bool zeroForOne;
        bool exactInput;
        uint256 amount;
        uint16 feeBps;
    }

    function setUp() public {
        tokenA = new AdversarialLaunchToken();
        tokenB = new AdversarialLaunchToken();
        manager = new AdversarialPoolManager();
        positionManager = new AdversarialPositionManager(IPoolManager(address(manager)));
        hook = _deployHook();

        (Currency currency0, Currency currency1) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));
        key = PoolKey({currency0: currency0, currency1: currency1, fee: 3_000, tickSpacing: 60, hooks: IHooks(hook)});
        poolId = hook.registerPool(key, SQRT_PRICE_1_1, 25, 75);
    }

    function testFuzzBeforeSwapChargesExactSpecifiedLeg(
        bool zeroForOne,
        bool exactInput,
        uint256 rawAmount,
        uint256 rawFeeBps
    ) public {
        FeeCase memory case_ = FeeCase({
            zeroForOne: zeroForOne,
            exactInput: exactInput,
            amount: bound(rawAmount, 1, uint256(uint128(type(int128).max))),
            feeBps: uint16(bound(rawFeeBps, 0, hook.MAX_HOOK_FEE_BPS()))
        });
        _assertBeforeSwap(case_);
    }

    function _assertBeforeSwap(FeeCase memory case_) private {
        hook.setHookFees(poolId, case_.feeBps, case_.feeBps);
        Currency specified = case_.zeroForOne == case_.exactInput ? key.currency0 : key.currency1;
        uint256 expected = Math.mulDiv(case_.amount, case_.feeBps, 10_000, Math.Rounding.Ceil);
        _token(specified).mint(address(manager), expected);
        uint256 managerBefore = specified.balanceOf(address(manager));
        uint256 receiverBefore = specified.balanceOf(receiver);

        (, BeforeSwapDelta returned, uint24 lpFeeOverride) = manager.callBeforeSwap(
            IHooks(hook),
            key,
            _params(case_.zeroForOne, case_.exactInput ? -int256(case_.amount) : int256(case_.amount))
        );

        assertEq(returned.getSpecifiedDelta(), int128(uint128(expected)));
        assertEq(returned.getUnspecifiedDelta(), 0);
        assertEq(lpFeeOverride, 0);
        assertEq(managerBefore - specified.balanceOf(address(manager)), expected);
        assertEq(specified.balanceOf(receiver) - receiverBefore, expected);
        assertEq(key.currency0.balanceOf(address(hook)), 0);
        assertEq(key.currency1.balanceOf(address(hook)), 0);
    }

    function testFuzzAfterSwapChargesExactUnspecifiedLeg(
        bool zeroForOne,
        bool exactInput,
        bool negativeDelta,
        uint256 rawAmount,
        uint256 rawFeeBps
    ) public {
        FeeCase memory case_ = FeeCase({
            zeroForOne: zeroForOne,
            exactInput: exactInput,
            amount: bound(rawAmount, 1, uint256(uint128(type(int128).max))),
            feeBps: uint16(bound(rawFeeBps, 0, hook.MAX_HOOK_FEE_BPS()))
        });
        _assertAfterSwap(case_, negativeDelta);
    }

    function _assertAfterSwap(FeeCase memory case_, bool negativeDelta) private {
        hook.setHookFees(poolId, case_.feeBps, case_.feeBps);
        bool specifiedCurrencyIs0 = case_.exactInput == case_.zeroForOne;
        Currency unspecified = specifiedCurrencyIs0 ? key.currency1 : key.currency0;
        int128 signedAmount = negativeDelta ? -int128(uint128(case_.amount)) : int128(uint128(case_.amount));
        BalanceDelta delta = specifiedCurrencyIs0 ? toBalanceDelta(0, signedAmount) : toBalanceDelta(signedAmount, 0);
        uint256 expected = Math.mulDiv(case_.amount, case_.feeBps, 10_000, Math.Rounding.Ceil);
        _token(unspecified).mint(address(manager), expected);
        uint256 managerBefore = unspecified.balanceOf(address(manager));
        uint256 receiverBefore = unspecified.balanceOf(receiver);

        (, int128 returned) = manager.callAfterSwap(
            IHooks(hook),
            key,
            _params(case_.zeroForOne, case_.exactInput ? -int256(case_.amount) : int256(case_.amount)),
            delta
        );

        assertEq(returned, int128(uint128(expected)));
        assertEq(managerBefore - unspecified.balanceOf(address(manager)), expected);
        assertEq(unspecified.balanceOf(receiver) - receiverBefore, expected);
    }

    function testZeroFeeSkipsTokenTransferEvenWhenZeroTransfersRevert() public {
        hook.setHookFees(poolId, 0, 0);
        _token(key.currency0).setBehavior(AdversarialLaunchToken.Behavior.RevertZeroTransfer);

        (, BeforeSwapDelta returned,) = manager.callBeforeSwap(IHooks(hook), key, _params(true, -int256(1 ether)));

        assertEq(BeforeSwapDelta.unwrap(returned), 0);
    }

    function testShortReceiptRevertsAndRollsBackCompleteRoute() public {
        AdversarialLaunchToken chargedToken = _token(key.currency0);
        chargedToken.mint(address(manager), 1 ether);
        chargedToken.setBehavior(AdversarialLaunchToken.Behavior.ShortReceipt);
        uint256 managerBefore = chargedToken.balanceOf(address(manager));
        uint256 charged = Math.mulDiv(1 ether, 25, 10_000, Math.Rounding.Ceil);

        vm.expectRevert(
            abi.encodeWithSelector(
                StaticsLaunchLiquidityHook.IncompatiblePoolCurrency.selector, key.currency0, charged, charged - 1
            )
        );
        manager.callBeforeSwap(IHooks(hook), key, _params(true, -int256(1 ether)));

        assertEq(chargedToken.balanceOf(address(manager)), managerBefore);
        assertEq(chargedToken.balanceOf(receiver), 0);
    }

    function testExtraDebitRevertsAndRollsBackCompleteRoute() public {
        AdversarialLaunchToken chargedToken = _token(key.currency0);
        chargedToken.mint(address(manager), 1 ether);
        chargedToken.setBehavior(AdversarialLaunchToken.Behavior.ExtraDebit);
        uint256 managerBefore = chargedToken.balanceOf(address(manager));
        uint256 charged = Math.mulDiv(1 ether, 25, 10_000, Math.Rounding.Ceil);

        vm.expectRevert(
            abi.encodeWithSelector(
                StaticsLaunchLiquidityHook.UnexpectedTokenDebit.selector, key.currency0, charged, charged + 1
            )
        );
        manager.callBeforeSwap(IHooks(hook), key, _params(true, -int256(1 ether)));

        assertEq(chargedToken.balanceOf(address(manager)), managerBefore);
        assertEq(chargedToken.balanceOf(receiver), 0);
    }

    function testReentrantTokenCannotChangeConfiguration() public {
        AdversarialLaunchToken chargedToken = _token(key.currency0);
        chargedToken.mint(address(manager), 1 ether);
        chargedToken.setReentry(address(hook), abi.encodeCall(hook.setHookFees, (poolId, 999, 999)));
        chargedToken.setBehavior(AdversarialLaunchToken.Behavior.Reenter);

        manager.callBeforeSwap(IHooks(hook), key, _params(true, -int256(1 ether)));

        assertFalse(chargedToken.reentrySucceeded());
        IStaticsLaunchLiquidityHook.PoolRegistration memory registration = hook.poolRegistration(poolId);
        assertEq(registration.inputFeeBps, 25);
        assertEq(registration.outputFeeBps, 75);
    }

    function testCallbacksRejectEveryNonManagerCaller() public {
        SwapParams memory params = _params(true, -int256(1 ether));
        vm.startPrank(outsider);
        vm.expectRevert();
        hook.afterInitialize(address(positionManager), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert();
        hook.beforeSwap(outsider, key, params, "");
        vm.expectRevert();
        hook.afterSwap(outsider, key, params, toBalanceDelta(0, 0), "");
        vm.stopPrank();
    }

    function testInitializationRequiresBoundPositionManagerAndExactPrice() public {
        vm.expectRevert(abi.encodeWithSelector(StaticsLaunchLiquidityHook.UnauthorizedInitializer.selector, outsider));
        manager.callAfterInitialize(IHooks(hook), outsider, key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                StaticsLaunchLiquidityHook.InitialPriceMismatch.selector, SQRT_PRICE_1_1, SQRT_PRICE_1_1 + 1
            )
        );
        manager.callAfterInitialize(IHooks(hook), address(positionManager), key, SQRT_PRICE_1_1 + 1, 0);

        assertEq(
            manager.callAfterInitialize(IHooks(hook), address(positionManager), key, SQRT_PRICE_1_1, 0),
            IHooks.afterInitialize.selector
        );
    }

    function testOwnershipTransitionMovesAllConfigurationAuthority() public {
        address nextOwner = makeAddr("nextOwner");
        hook.transferOwnership(nextOwner);
        vm.prank(nextOwner);
        hook.acceptOwnership();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.setHookFees(poolId, 1, 2);
        vm.prank(nextOwner);
        hook.setHookFees(poolId, 1, 2);

        assertEq(hook.owner(), nextOwner);
        assertEq(hook.poolRegistration(poolId).inputFeeBps, 1);
        assertEq(hook.poolRegistration(poolId).outputFeeBps, 2);
    }

    function testFeeAndReceiverUpdatesPreserveImmutableRegistrationFields() public {
        IStaticsLaunchLiquidityHook.PoolRegistration memory before_ = hook.poolRegistration(poolId);
        address nextReceiver = makeAddr("nextReceiver");
        hook.setHookFees(poolId, 0, hook.MAX_HOOK_FEE_BPS());
        hook.setFeeReceiver(nextReceiver);
        IStaticsLaunchLiquidityHook.PoolRegistration memory after_ = hook.poolRegistration(poolId);

        assertEq(Currency.unwrap(after_.currency0), Currency.unwrap(before_.currency0));
        assertEq(Currency.unwrap(after_.currency1), Currency.unwrap(before_.currency1));
        assertEq(after_.nativeLpFee, before_.nativeLpFee);
        assertEq(after_.tickSpacing, before_.tickSpacing);
        assertEq(after_.expectedSqrtPriceX96, before_.expectedSqrtPriceX96);
        assertTrue(after_.registered);
        assertEq(after_.inputFeeBps, 0);
        assertEq(after_.outputFeeBps, hook.MAX_HOOK_FEE_BPS());
        assertEq(hook.feeReceiver(), nextReceiver);
    }

    function _params(bool zeroForOne, int256 amountSpecified) private pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: 0});
    }

    function _token(Currency currency) private pure returns (AdversarialLaunchToken) {
        return AdversarialLaunchToken(Currency.unwrap(currency));
    }

    function _deployHook() private returns (StaticsLaunchLiquidityHook deployed) {
        IPositionManager positionManager_ = IPositionManager(address(positionManager));
        bytes memory args = abi.encode(IPoolManager(address(manager)), positionManager_, address(this), receiver);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_FLAGS, type(StaticsLaunchLiquidityHook).creationCode, args);
        deployed = new StaticsLaunchLiquidityHook{salt: salt}(
            IPoolManager(address(manager)), positionManager_, address(this), receiver
        );
        assertEq(address(deployed), expected);
    }
}
