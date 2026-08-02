// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {StaticsSwapFeeHook} from "../../src/liquidity/StaticsSwapFeeHook.sol";

contract HookTaxToken is ERC20 {
    uint16 public receiverTaxBps;
    uint16 public senderExtraBps;

    constructor() ERC20("Hook Tax Token", "HTT", 18) {}

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }

    function setTaxes(uint16 receiverTaxBps_, uint16 senderExtraBps_) external {
        receiverTaxBps = receiverTaxBps_;
        senderExtraBps = senderExtraBps_;
    }

    function slash(address holder, uint256 amount) external {
        _burn(holder, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 receiverTax = amount * receiverTaxBps / 10_000;
        uint256 senderExtra = amount * senderExtraBps / 10_000;
        balanceOf[msg.sender] -= amount + senderExtra;
        balanceOf[to] += amount - receiverTax;
        totalSupply -= receiverTax + senderExtra;
        emit Transfer(msg.sender, to, amount - receiverTax);
        if (receiverTax + senderExtra != 0) emit Transfer(msg.sender, address(0), receiverTax + senderExtra);
        return true;
    }
}

contract HookMultiHopRouter is IUnlockCallback {
    using CurrencySettler for Currency;
    using TransientStateLibrary for IPoolManager;

    struct Route {
        address payer;
        address receiver;
        PoolKey first;
        PoolKey second;
        bool firstZeroForOne;
        bool secondZeroForOne;
        uint256 amountIn;
    }

    IPoolManager private immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swapExactInput(
        PoolKey calldata first,
        PoolKey calldata second,
        bool firstZeroForOne,
        bool secondZeroForOne,
        uint256 amountIn,
        address receiver
    ) external returns (uint256 intermediateAmount, uint256 finalAmount) {
        bytes memory result = manager.unlock(
            abi.encode(
                Route({
                    payer: msg.sender,
                    receiver: receiver,
                    first: first,
                    second: second,
                    firstZeroForOne: firstZeroForOne,
                    secondZeroForOne: secondZeroForOne,
                    amountIn: amountIn
                })
            )
        );
        return abi.decode(result, (uint256, uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        Route memory route = abi.decode(data, (Route));
        BalanceDelta firstDelta = manager.swap(
            route.first,
            SwapParams({
                zeroForOne: route.firstZeroForOne,
                amountSpecified: -int256(route.amountIn),
                sqrtPriceLimitX96: route.firstZeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            ""
        );
        uint256 intermediateAmount =
            uint256(uint128(route.firstZeroForOne ? firstDelta.amount1() : firstDelta.amount0()));
        BalanceDelta secondDelta = manager.swap(
            route.second,
            SwapParams({
                zeroForOne: route.secondZeroForOne,
                amountSpecified: -int256(intermediateAmount),
                sqrtPriceLimitX96: route.secondZeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            ""
        );
        uint256 finalAmount = uint256(uint128(route.secondZeroForOne ? secondDelta.amount1() : secondDelta.amount0()));

        Currency inputCurrency = route.firstZeroForOne ? route.first.currency0 : route.first.currency1;
        Currency intermediateCurrency = route.firstZeroForOne ? route.first.currency1 : route.first.currency0;
        Currency outputCurrency = route.secondZeroForOne ? route.second.currency1 : route.second.currency0;
        int256 inputDelta = manager.currencyDelta(address(this), inputCurrency);
        int256 intermediateDelta = manager.currencyDelta(address(this), intermediateCurrency);
        int256 outputDelta = manager.currencyDelta(address(this), outputCurrency);
        require(inputDelta < 0 && intermediateDelta == 0 && outputDelta > 0);
        inputCurrency.settle(manager, route.payer, uint256(-inputDelta), false);
        outputCurrency.take(manager, route.receiver, uint256(outputDelta), false);
        return abi.encode(intermediateAmount, finalAmount);
    }

    uint160 private constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 private constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
}

contract StaticsSwapFeeHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint16 private constant HOOK_FEE_BPS = 1;
    uint24 private constant LP_FEE = 500;
    int24 private constant TICK_SPACING = 10;
    uint160 private constant REQUIRED_FLAGS =
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    StaticsSwapFeeHook private hook;
    PoolId private poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        hook = _deployHook(address(this));
        key = _registerInitializeAndSeed(currency0, currency1, LP_FEE, TICK_SPACING);
        poolId = key.toId();
    }

    function testMinedAddressEnablesOnlyRequiredHookPermissions() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, REQUIRED_FLAGS);
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.afterInitialize);
        assertTrue(permissions.afterSwap);
        assertTrue(permissions.afterSwapReturnDelta);
        assertEq(hook.staticsDiamond(), address(this));
        assertEq(hook.hookFeeBps(), HOOK_FEE_BPS);
    }

    function testExactInputAndOutputChargeRealizedAmountsInBothDirections() public {
        _assertExactInput(true, 0.001 ether);
        _assertExactInput(false, 0.001 ether);
        _assertExactOutput(true, 0.0001 ether);
        _assertExactOutput(false, 0.0001 ether);
    }

    function testPartialExecutionAndDustUseRealizedAmountWithUpwardRounding() public {
        Currency outputCurrency = key.currency1;
        uint256 accruedBefore = hook.accruedFees(poolId, outputCurrency);
        BalanceDelta partialDelta = swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(100 ether), sqrtPriceLimitX96: SQRT_PRICE_1_2}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 partialFee = hook.accruedFees(poolId, outputCurrency) - accruedBefore;
        uint256 partialNetOutput = uint256(uint128(partialDelta.amount1()));
        assertLt(uint256(-int256(partialDelta.amount0())), 100 ether);
        assertEq(partialFee, _fee(partialNetOutput + partialFee));

        key = _registerInitializeAndSeed(currency0, currency1, 600, TICK_SPACING);
        poolId = key.toId();
        accruedBefore = hook.accruedFees(poolId, key.currency1);
        BalanceDelta dust = swap(key, true, -int256(1_000), "");
        uint256 dustFee = hook.accruedFees(poolId, key.currency1) - accruedBefore;
        assertEq(dustFee, 1);
        assertEq(dustFee, _fee(uint256(uint128(dust.amount1())) + dustFee));
    }

    function testRegistrationAndWithdrawalsAreDiamondOnlyAndPoolIsolated() public {
        PoolKey memory sibling = _poolKey(currency0, currency1, 3_000, 60);
        hook.registerPool(sibling);
        manager.initialize(sibling, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(sibling, LIQUIDITY_PARAMS, "");
        PoolId siblingId = sibling.toId();

        address outsider = makeAddr("outsider");
        PoolKey memory rejected = _poolKey(currency0, currency1, 10_000, 200);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(StaticsSwapFeeHook.OnlyStaticsDiamond.selector, outsider));
        hook.registerPool(rejected);

        _assertExactInput(true, 0.001 ether);
        assertEq(hook.accruedFees(siblingId, key.currency1), 0);
        _swapExactInput(sibling, true, 0.001 ether);
        uint256 siblingLiability = hook.accruedFees(siblingId, sibling.currency1);
        assertGt(siblingLiability, 0);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(StaticsSwapFeeHook.OnlyStaticsDiamond.selector, outsider));
        hook.withdrawPoolFees(poolId);

        hook.withdrawPoolFees(poolId);
        assertEq(hook.accruedFees(poolId, key.currency1), 0);
        assertEq(hook.accruedFees(siblingId, sibling.currency1), siblingLiability);
        assertEq(hook.totalLiability(sibling.currency1), siblingLiability);
        assertEq(sibling.currency1.balanceOf(address(hook)), siblingLiability);
    }

    function testUnregisteredPoolCannotInitialize() public {
        PoolKey memory unregistered = _poolKey(currency0, currency1, 3_000, 60);
        vm.expectPartialRevert(CustomRevert.WrappedError.selector);
        manager.initialize(unregistered, SQRT_PRICE_1_1);
    }

    function testWithdrawalMeasuresFeeOnTransferReceipt() public {
        (PoolKey memory taxedPool, HookTaxToken taxed, PoolId taxedPoolId) = _createTaxedOutputPool();
        uint256 liability = hook.accruedFees(taxedPoolId, Currency.wrap(address(taxed)));
        taxed.setTaxes(100, 0);

        (uint256 spent0, uint256 received0, uint256 spent1, uint256 received1) = hook.withdrawPoolFees(taxedPoolId);
        (uint256 spent, uint256 received) =
            taxedPool.currency0 == Currency.wrap(address(taxed)) ? (spent0, received0) : (spent1, received1);
        assertEq(spent, liability);
        assertEq(received, liability - (liability / 100));
        assertEq(hook.accruedFees(taxedPoolId, Currency.wrap(address(taxed))), 0);
    }

    function testWithdrawalRejectsSenderExtraDebitAcrossPoolLiabilities() public {
        (PoolKey memory taxedPool, HookTaxToken taxed, PoolId taxedPoolId) = _createTaxedOutputPool();
        Currency taxedCurrency = Currency.wrap(address(taxed));
        uint256 liability = hook.accruedFees(taxedPoolId, taxedCurrency);
        taxed.mint(address(hook), liability);
        uint256 hookBalanceBefore = taxed.balanceOf(address(hook));
        taxed.setTaxes(0, 1_000);

        vm.expectPartialRevert(StaticsSwapFeeHook.WithdrawalExceedsPoolLiability.selector);
        hook.withdrawPoolFees(taxedPoolId);
        assertEq(hook.accruedFees(taxedPoolId, taxedCurrency), liability);
        assertEq(taxed.balanceOf(address(hook)), hookBalanceBefore);
        assertTrue(taxedPool.currency0 == taxedCurrency || taxedPool.currency1 == taxedCurrency);
    }

    function testSharedCurrencyInsolvencyFreezesEveryPoolWithdrawal() public {
        HookTaxToken shared = new HookTaxToken();
        MockERC20 pairedA = new MockERC20("Paired Token A", "PAIR-A", 18);
        MockERC20 pairedB = new MockERC20("Paired Token B", "PAIR-B", 18);
        shared.mint(address(this), 20 ether);
        pairedA.mint(address(this), 10 ether);
        pairedB.mint(address(this), 10 ether);
        shared.approve(address(modifyLiquidityRouter), type(uint256).max);
        shared.approve(address(swapRouter), type(uint256).max);
        pairedA.approve(address(modifyLiquidityRouter), type(uint256).max);
        pairedA.approve(address(swapRouter), type(uint256).max);
        pairedB.approve(address(modifyLiquidityRouter), type(uint256).max);
        pairedB.approve(address(swapRouter), type(uint256).max);

        Currency sharedCurrency = Currency.wrap(address(shared));
        Currency pairedCurrencyA = Currency.wrap(address(pairedA));
        Currency pairedCurrencyB = Currency.wrap(address(pairedB));
        PoolKey memory poolA = _registerInitializeAndSeed(sharedCurrency, pairedCurrencyA, 700, TICK_SPACING);
        PoolKey memory poolB = _registerInitializeAndSeed(sharedCurrency, pairedCurrencyB, 800, TICK_SPACING);
        PoolId poolIdA = poolA.toId();
        PoolId poolIdB = poolB.toId();
        _swapExactInput(poolA, poolA.currency0 == pairedCurrencyA, 0.001 ether);
        _swapExactInput(poolB, poolB.currency0 == pairedCurrencyB, 0.001 ether);

        uint256 liabilityA = hook.accruedFees(poolIdA, sharedCurrency);
        uint256 liabilityB = hook.accruedFees(poolIdB, sharedCurrency);
        uint256 totalLiability = liabilityA + liabilityB;
        assertGt(liabilityA, 0);
        assertGt(liabilityB, 0);
        assertEq(hook.totalLiability(sharedCurrency), totalLiability);
        assertEq(shared.balanceOf(address(hook)), totalLiability);

        shared.slash(address(hook), liabilityB);
        vm.expectRevert(
            abi.encodeWithSelector(
                StaticsSwapFeeHook.HookLiabilityInsolvent.selector, sharedCurrency, totalLiability, liabilityA
            )
        );
        hook.withdrawPoolFees(poolIdA);

        assertEq(hook.accruedFees(poolIdA, sharedCurrency), liabilityA);
        assertEq(hook.accruedFees(poolIdB, sharedCurrency), liabilityB);
        assertEq(hook.totalLiability(sharedCurrency), totalLiability);
        assertEq(shared.balanceOf(address(hook)), liabilityA);

        shared.mint(address(hook), liabilityB);
        hook.withdrawPoolFees(poolIdA);
        assertEq(hook.accruedFees(poolIdA, sharedCurrency), 0);
        assertEq(hook.accruedFees(poolIdB, sharedCurrency), liabilityB);
        assertEq(hook.totalLiability(sharedCurrency), liabilityB);
        assertEq(shared.balanceOf(address(hook)), liabilityB);
    }

    function testThirdPartyLiquidityAndMultiHopRoutingPayTheSameFee() public {
        address thirdParty = makeAddr("thirdParty");
        _fundRouterUser(thirdParty, currency0, 1 ether, address(modifyLiquidityRouter));
        _fundRouterUser(thirdParty, currency1, 1 ether, address(modifyLiquidityRouter));
        ModifyLiquidityParams memory thirdPartyPosition = ModifyLiquidityParams({
            tickLower: -120, tickUpper: 120, liquidityDelta: 0.1 ether, salt: bytes32(uint256(1))
        });
        vm.prank(thirdParty);
        modifyLiquidityRouter.modifyLiquidity(key, thirdPartyPosition, "");

        Currency thirdCurrency = deployMintAndApproveCurrency();
        PoolKey memory second = _registerInitializeAndSeed(currency1, thirdCurrency, LP_FEE, TICK_SPACING);
        PoolId secondId = second.toId();
        HookMultiHopRouter router = new HookMultiHopRouter(manager);
        MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        bool secondZeroForOne = second.currency0 == currency1;
        uint256 firstBefore = hook.accruedFees(poolId, currency1);
        Currency finalCurrency = secondZeroForOne ? second.currency1 : second.currency0;
        uint256 secondBefore = hook.accruedFees(secondId, finalCurrency);

        (uint256 intermediateAmount, uint256 finalAmount) =
            router.swapExactInput(key, second, true, secondZeroForOne, 0.001 ether, address(this));
        uint256 firstFee = hook.accruedFees(poolId, currency1) - firstBefore;
        uint256 secondFee = hook.accruedFees(secondId, finalCurrency) - secondBefore;
        assertEq(firstFee, _fee(intermediateAmount + firstFee));
        assertEq(secondFee, _fee(finalAmount + secondFee));
    }

    function _assertExactInput(bool zeroForOne, uint256 amountIn) private {
        Currency feeCurrency = zeroForOne ? key.currency1 : key.currency0;
        uint256 accruedBefore = hook.accruedFees(poolId, feeCurrency);
        BalanceDelta delta = _swapExactInput(key, zeroForOne, amountIn);
        uint256 fee = hook.accruedFees(poolId, feeCurrency) - accruedBefore;
        uint256 netOutput = uint256(uint128(zeroForOne ? delta.amount1() : delta.amount0()));
        assertEq(fee, _fee(netOutput + fee));
    }

    function _assertExactOutput(bool zeroForOne, uint256 amountOut) private {
        Currency feeCurrency = zeroForOne ? key.currency0 : key.currency1;
        uint256 accruedBefore = hook.accruedFees(poolId, feeCurrency);
        BalanceDelta delta = swap(key, zeroForOne, int256(amountOut), "");
        uint256 fee = hook.accruedFees(poolId, feeCurrency) - accruedBefore;
        uint256 totalInput = uint256(-int256(zeroForOne ? delta.amount0() : delta.amount1()));
        assertEq(fee, _fee(totalInput - fee));
        assertEq(uint256(uint128(zeroForOne ? delta.amount1() : delta.amount0())), amountOut);
    }

    function _swapExactInput(PoolKey memory poolKey, bool zeroForOne, uint256 amountIn)
        private
        returns (BalanceDelta delta)
    {
        return swap(poolKey, zeroForOne, -int256(amountIn), "");
    }

    function _registerInitializeAndSeed(Currency first, Currency second, uint24 fee, int24 tickSpacing)
        private
        returns (PoolKey memory poolKey)
    {
        poolKey = _poolKey(first, second, fee, tickSpacing);
        hook.registerPool(poolKey);
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, "");
    }

    function _poolKey(Currency first, Currency second, uint24 fee, int24 tickSpacing)
        private
        view
        returns (PoolKey memory poolKey)
    {
        (Currency lower, Currency upper) = first < second ? (first, second) : (second, first);
        return PoolKey({currency0: lower, currency1: upper, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(hook)});
    }

    function _deployHook(address diamond) private returns (StaticsSwapFeeHook deployed) {
        (address expected, bytes32 salt) = HookMiner.find(
            address(this),
            REQUIRED_FLAGS,
            type(StaticsSwapFeeHook).creationCode,
            abi.encode(manager, diamond, HOOK_FEE_BPS)
        );
        deployed = new StaticsSwapFeeHook{salt: salt}(manager, diamond, HOOK_FEE_BPS);
        assertEq(address(deployed), expected);
    }

    function _createTaxedOutputPool()
        private
        returns (PoolKey memory taxedPool, HookTaxToken taxed, PoolId taxedPoolId)
    {
        taxed = new HookTaxToken();
        MockERC20 paired = new MockERC20("Paired Token", "PAIR", 18);
        taxed.mint(address(this), 10 ether);
        paired.mint(address(this), 10 ether);
        taxed.approve(address(modifyLiquidityRouter), type(uint256).max);
        taxed.approve(address(swapRouter), type(uint256).max);
        paired.approve(address(modifyLiquidityRouter), type(uint256).max);
        paired.approve(address(swapRouter), type(uint256).max);
        Currency taxedCurrency = Currency.wrap(address(taxed));
        Currency pairedCurrency = Currency.wrap(address(paired));
        taxedPool = _registerInitializeAndSeed(taxedCurrency, pairedCurrency, 700, TICK_SPACING);
        taxedPoolId = taxedPool.toId();
        bool pairedForTaxed = taxedPool.currency0 == pairedCurrency;
        _swapExactInput(taxedPool, pairedForTaxed, 0.001 ether);
        assertGt(hook.accruedFees(taxedPoolId, taxedCurrency), 0);
    }

    function _fundRouterUser(address user, Currency currency, uint256 amount, address router) private {
        MockERC20 token = MockERC20(Currency.unwrap(currency));
        token.mint(user, amount);
        vm.prank(user);
        token.approve(router, type(uint256).max);
    }

    function _fee(uint256 realizedAmount) private pure returns (uint256) {
        return (realizedAmount * HOOK_FEE_BPS + 9_999) / 10_000;
    }
}
