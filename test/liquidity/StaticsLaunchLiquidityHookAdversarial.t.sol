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
        poolId = hook.registerPool(key, SQRT_PRICE_1_1, 25, 75, address(this));
        manager.callAfterInitialize(IHooks(hook), address(positionManager), key, SQRT_PRICE_1_1, 0);
        hook.activatePool(poolId);
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
            amount: bound(rawAmount, 1, uint256(uint128(type(int128).max)) / 2),
            feeBps: uint16(bound(rawFeeBps, 0, hook.MAX_HOOK_FEE_BPS()))
        });
        _assertBeforeSwap(case_);
    }

    function _assertBeforeSwap(FeeCase memory case_) private {
        hook.setHookFees(poolId, case_.feeBps, case_.feeBps);
        Currency specified = case_.zeroForOne == case_.exactInput ? key.currency0 : key.currency1;
        uint256 expected =
            case_.exactInput ? _feeFromGross(case_.amount, case_.feeBps) : _feeFromNet(case_.amount, case_.feeBps);
        uint256 managerBefore = specified.balanceOf(address(manager));
        uint256 receiverBefore = specified.balanceOf(receiver);
        uint256 claimsBefore = manager.balanceOf(receiver, specified.toId());

        (, BeforeSwapDelta returned, uint24 lpFeeOverride) = manager.callBeforeSwap(
            IHooks(hook),
            key,
            _params(case_.zeroForOne, case_.exactInput ? -int256(case_.amount) : int256(case_.amount))
        );

        assertEq(returned.getSpecifiedDelta(), int128(uint128(expected)));
        assertEq(returned.getUnspecifiedDelta(), 0);
        assertEq(lpFeeOverride, 0);
        assertEq(specified.balanceOf(address(manager)), managerBefore);
        assertEq(specified.balanceOf(receiver), receiverBefore);
        assertEq(manager.balanceOf(receiver, specified.toId()) - claimsBefore, expected);
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
            amount: bound(rawAmount, 1, uint256(uint128(type(int128).max)) / 2),
            feeBps: uint16(bound(rawFeeBps, 0, hook.MAX_HOOK_FEE_BPS()))
        });
        _assertAfterSwap(case_, negativeDelta);
    }

    function _assertAfterSwap(FeeCase memory case_, bool negativeDelta) private {
        hook.setHookFees(poolId, case_.feeBps, case_.feeBps);
        bool specifiedCurrencyIs0 = case_.exactInput == case_.zeroForOne;
        Currency unspecified = specifiedCurrencyIs0 ? key.currency1 : key.currency0;
        uint256 expected =
            case_.exactInput ? _feeFromGross(case_.amount, case_.feeBps) : _feeFromNet(case_.amount, case_.feeBps);

        (, int128 returned) = manager.callAfterSwap(
            IHooks(hook),
            key,
            _params(case_.zeroForOne, case_.exactInput ? -int256(case_.amount) : int256(case_.amount)),
            _fullFillDelta(
                case_,
                specifiedCurrencyIs0,
                negativeDelta ? -int128(uint128(case_.amount)) : int128(uint128(case_.amount))
            )
        );

        assertEq(returned, int128(uint128(expected)));
        assertEq(unspecified.balanceOf(address(manager)), 0);
        assertEq(unspecified.balanceOf(receiver), 0);
        assertEq(manager.balanceOf(receiver, unspecified.toId()), expected);
    }

    function testZeroFeeSkipsTokenTransferEvenWhenZeroTransfersRevert() public {
        hook.setHookFees(poolId, 0, 0);
        _token(key.currency0).setBehavior(AdversarialLaunchToken.Behavior.RevertZeroTransfer);

        (, BeforeSwapDelta returned,) = manager.callBeforeSwap(IHooks(hook), key, _params(true, -int256(1 ether)));

        assertEq(BeforeSwapDelta.unwrap(returned), 0);
    }

    function testFeeClaimsDoNotInvokeAdversarialCurrencyTransfers() public {
        AdversarialLaunchToken chargedToken = _token(key.currency0);
        uint256 charged = Math.mulDiv(1 ether, 25, 10_000, Math.Rounding.Ceil);
        AdversarialLaunchToken.Behavior[4] memory behaviors = [
            AdversarialLaunchToken.Behavior.ShortReceipt,
            AdversarialLaunchToken.Behavior.ExtraDebit,
            AdversarialLaunchToken.Behavior.RevertTransfer,
            AdversarialLaunchToken.Behavior.Reenter
        ];
        chargedToken.setReentry(address(hook), abi.encodeCall(hook.setHookFees, (poolId, 999, 999)));

        for (uint256 i; i < behaviors.length; ++i) {
            chargedToken.setBehavior(behaviors[i]);
            manager.callBeforeSwap(IHooks(hook), key, _params(true, -int256(1 ether)));
        }

        assertFalse(chargedToken.reentrySucceeded());
        assertEq(manager.balanceOf(receiver, key.currency0.toId()), charged * behaviors.length);
        assertEq(chargedToken.balanceOf(address(manager)), 0);
        assertEq(chargedToken.balanceOf(receiver), 0);
        IStaticsLaunchLiquidityHook.PoolRegistration memory registration = hook.poolRegistration(poolId);
        assertEq(registration.inputFeeBps, 25);
        assertEq(registration.outputFeeBps, 75);
    }

    function testIncompleteSpecifiedFillRevertsAndRollsBackBothClaims() public {
        SwapParams memory params = _params(true, -int256(1 ether));
        uint256 specifiedFee = _feeFromGross(1 ether, 25);
        int128 partialSpecifiedDelta = -int128(int256(1 ether - specifiedFee - 1));
        BalanceDelta partialDelta = toBalanceDelta(partialSpecifiedDelta, int128(0.5 ether));
        int256 expectedSpecifiedDelta = -int256(1 ether) + int256(specifiedFee);

        vm.expectRevert(
            abi.encodeWithSelector(
                StaticsLaunchLiquidityHook.IncompleteSpecifiedFill.selector,
                expectedSpecifiedDelta,
                int256(partialSpecifiedDelta)
            )
        );
        manager.callSwapHooks(IHooks(hook), key, params, partialDelta);

        assertEq(manager.balanceOf(receiver, key.currency0.toId()), 0);
        assertEq(manager.balanceOf(receiver, key.currency1.toId()), 0);
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
        PoolKey memory second = key;
        second.fee = 5_000;
        PoolId secondId = hook.registerPool(second, SQRT_PRICE_1_1, 0, 0, address(this));
        vm.expectRevert(abi.encodeWithSelector(StaticsLaunchLiquidityHook.UnauthorizedInitializer.selector, outsider));
        manager.callAfterInitialize(IHooks(hook), outsider, second, SQRT_PRICE_1_1, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                StaticsLaunchLiquidityHook.InitialPriceMismatch.selector, SQRT_PRICE_1_1, SQRT_PRICE_1_1 + 1
            )
        );
        manager.callAfterInitialize(IHooks(hook), address(positionManager), second, SQRT_PRICE_1_1 + 1, 0);

        assertEq(
            manager.callAfterInitialize(IHooks(hook), address(positionManager), second, SQRT_PRICE_1_1, 0),
            IHooks.afterInitialize.selector
        );
        assertTrue(hook.poolRegistration(secondId).initialized);
        assertFalse(hook.poolRegistration(secondId).active);
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
        assertEq(after_.launchOperator, before_.launchOperator);
        assertEq(after_.initialized, before_.initialized);
        assertEq(after_.active, before_.active);
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

    function _fullFillDelta(FeeCase memory case_, bool specifiedCurrencyIs0, int128 unspecifiedDelta)
        private
        pure
        returns (BalanceDelta)
    {
        uint256 specifiedFee =
            case_.exactInput ? _feeFromGross(case_.amount, case_.feeBps) : _feeFromNet(case_.amount, case_.feeBps);
        int256 rawSpecified = case_.exactInput
            ? -int256(case_.amount) + int256(specifiedFee)
            : int256(case_.amount) + int256(specifiedFee);
        int128 specifiedDelta = int128(rawSpecified);
        return specifiedCurrencyIs0
            ? toBalanceDelta(specifiedDelta, unspecifiedDelta)
            : toBalanceDelta(unspecifiedDelta, specifiedDelta);
    }

    function _feeFromGross(uint256 amount, uint256 feeBps) private pure returns (uint256) {
        return Math.mulDiv(amount, feeBps, 10_000, Math.Rounding.Ceil);
    }

    function _feeFromNet(uint256 amount, uint256 feeBps) private pure returns (uint256) {
        if (feeBps == 0) return 0;
        return Math.mulDiv(amount, feeBps, 10_000 - feeBps, Math.Rounding.Ceil);
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
