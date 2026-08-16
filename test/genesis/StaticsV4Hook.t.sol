// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {RevenueChannel} from "../../src/interfaces/IStaticsHookController.sol";
import {IStaticsV4Hook} from "../../src/interfaces/IStaticsV4Hook.sol";
import {StaticsHookController} from "../../src/genesis/StaticsHookController.sol";
import {StaticsV4Hook} from "../../src/liquidity/StaticsV4Hook.sol";

contract StaticsV4HookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint16 private constant INPUT_FEE_BPS = 50;
    uint16 private constant OUTPUT_FEE_BPS = 50;
    uint160 private constant REQUIRED_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    address private treasury;
    MockERC20 private staticsToken;
    MockERC20 private wethToken;
    StaticsHookController private controllerContract;
    StaticsV4Hook private hook;
    PoolKey private poolKey;
    PoolId private poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        treasury = makeAddr("treasury");
        staticsToken = new MockERC20("Statics", "STATICS", 18);
        staticsToken.mint(address(this), 999_955_550 ether);
        wethToken = new MockERC20("Wrapped Ether", "WETH", 18);
        wethToken.mint(address(this), 100_000 ether);
        controllerContract = new StaticsHookController(address(this), address(this));
        hook = _deployHook();
        controllerContract.bindHook(address(hook));
        staticsToken.transfer(address(hook), hook.PUBLIC_LAUNCH_INVENTORY());
        poolKey = hook.canonicalPoolKey();
        poolId = poolKey.toId();

        wethToken.approve(address(swapRouter), type(uint256).max);
        staticsToken.approve(address(swapRouter), type(uint256).max);
        wethToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        staticsToken.approve(address(modifyLiquidityRouter), type(uint256).max);
    }

    function testAtomicLaunchInstallsExactSixBandInventory() public {
        controllerContract.initializeCanonicalPool();

        IStaticsV4Hook.PoolConfigurationView memory configuration = hook.poolConfiguration(poolId);
        assertTrue(configuration.registered);
        assertTrue(configuration.initialized);
        assertFalse(configuration.externalLiquidityEnabled);
        assertTrue(hook.launchInventoryInstalled());

        uint256[6] memory targets = [
            uint256(24_301_350 ether),
            uint256(56_703_150 ether),
            uint256(162_009_000 ether),
            uint256(202_511_250 ether),
            uint256(243_013_500 ether),
            uint256(121_506_750 ether)
        ];
        uint256 settled;
        for (uint8 band = 1; band <= 6; ++band) {
            uint256 amount = hook.launchBandStatics(band);
            assertGt(hook.launchBandLiquidity(band), 0);
            assertLe(amount, targets[band - 1]);
            settled += amount;
        }
        assertEq(settled + hook.launchRoundingDust(), hook.PUBLIC_LAUNCH_INVENTORY());
        assertLt(hook.launchRoundingDust(), 10_000);
        assertEq(staticsToken.balanceOf(address(hook)), hook.launchRoundingDust());
        assertEq(wethToken.balanceOf(address(hook)), 0);
    }

    function testColdAtomicLaunchStaysBelowSixteenMillionGas() public {
        uint256 gasBefore = gasleft();
        controllerContract.initializeCanonicalPool();
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("cold six-band launch gas", gasUsed);
        assertLt(gasUsed, 16_000_000);
    }

    function testSwapAccruesPullTreasuryRevenueAndPermanentLiquidity() public {
        controllerContract.initializeCanonicalPool();
        bool wethToStaticsZeroForOne = Currency.unwrap(poolKey.currency0) == address(wethToken);
        BalanceDelta delta = _swapInput(wethToStaticsZeroForOne, 100 ether);
        assertTrue(delta.amount0() != 0);
        assertTrue(delta.amount1() != 0);

        Currency wethCurrency = Currency.wrap(address(wethToken));
        Currency staticsCurrency = Currency.wrap(address(staticsToken));
        uint256 wethClaim = controllerContract.claimableRevenue(poolId, wethCurrency, RevenueChannel.Treasury, treasury);
        uint256 staticsClaim =
            controllerContract.claimableRevenue(poolId, staticsCurrency, RevenueChannel.Treasury, treasury);
        assertGt(wethClaim, 0);
        assertGt(staticsClaim, 0);
        assertGt(hook.lockedPermanentLiquidity(poolId), 0);

        address receiver = makeAddr("treasuryReceiver");
        vm.startPrank(treasury);
        controllerContract.claimRevenue(poolId, wethCurrency, RevenueChannel.Treasury, receiver);
        controllerContract.claimRevenue(poolId, staticsCurrency, RevenueChannel.Treasury, receiver);
        vm.stopPrank();
        assertEq(wethToken.balanceOf(receiver), wethClaim);
        assertEq(staticsToken.balanceOf(receiver), staticsClaim);
    }

    function testRecipientChangePreservesHistoricalClaims() public {
        controllerContract.initializeCanonicalPool();
        bool wethToStaticsZeroForOne = Currency.unwrap(poolKey.currency0) == address(wethToken);
        _swapInput(wethToStaticsZeroForOne, 100 ether);

        Currency wethCurrency = Currency.wrap(address(wethToken));
        uint256 historicalClaim =
            controllerContract.claimableRevenue(poolId, wethCurrency, RevenueChannel.Treasury, treasury);
        assertGt(historicalClaim, 0);

        address nextTreasury = makeAddr("nextTreasury");
        IStaticsV4Hook.RevenueRecipients memory recipients;
        recipients.treasury = nextTreasury;
        controllerContract.configurePool(poolId, _initialFees(), recipients);
        _swapInput(wethToStaticsZeroForOne, 100 ether);

        assertEq(
            controllerContract.claimableRevenue(poolId, wethCurrency, RevenueChannel.Treasury, treasury),
            historicalClaim
        );
        assertGt(controllerContract.claimableRevenue(poolId, wethCurrency, RevenueChannel.Treasury, nextTreasury), 0);
    }

    function testExactInputAndExactOutputWorkInBothDirections() public {
        controllerContract.initializeCanonicalPool();
        bool wethToStaticsZeroForOne = Currency.unwrap(poolKey.currency0) == address(wethToken);

        _swapInput(wethToStaticsZeroForOne, 100 ether);
        uint256 purchased = staticsToken.balanceOf(address(this)) - 189_910_550 ether;
        assertGt(purchased, 0);
        _swapSpecified(wethToStaticsZeroForOne, int256(1_000 ether));

        uint256 staticsToSell = purchased / 100;
        _swapInput(!wethToStaticsZeroForOne, staticsToSell);
        _swapSpecified(!wethToStaticsZeroForOne, int256(0.01 ether));
    }

    function testExternalLiquidityActivationIsAtomicWithLpRewardRoute() public {
        controllerContract.initializeCanonicalPool();
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -166_040, tickUpper: -143_020, liquidityDelta: 1 ether, salt: keccak256("external")
        });
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(poolKey, params, "");

        address lpRewards = makeAddr("lpRewards");
        IStaticsV4Hook.FeeConfiguration memory fees = _initialFees();
        fees.polShareBps = 2_000;
        fees.liquidityProviderShareBps = 1_000;
        fees.treasuryShareBps = 7_000;
        IStaticsV4Hook.RevenueRecipients memory recipients;
        recipients.liquidityProvider = lpRewards;
        recipients.treasury = treasury;
        controllerContract.activateExternalLiquidity(poolId, fees, recipients);

        IStaticsV4Hook.PoolConfigurationView memory configuration = hook.poolConfiguration(poolId);
        assertTrue(configuration.externalLiquidityEnabled);
        assertEq(configuration.fees.liquidityProviderShareBps, 1_000);
        assertEq(configuration.recipients.liquidityProvider, lpRewards);
    }

    function testCannotLaunchWithInsufficientInventory() public {
        StaticsHookController insufficientController = new StaticsHookController(address(this), address(this));
        StaticsV4Hook insufficientHook =
            _deployHookFor(insufficientController, address(staticsToken), address(wethToken), treasury);
        insufficientController.bindHook(address(insufficientHook));
        staticsToken.mint(address(this), hook.PUBLIC_LAUNCH_INVENTORY());
        staticsToken.transfer(address(insufficientHook), hook.PUBLIC_LAUNCH_INVENTORY() - 1);

        vm.expectRevert();
        insufficientController.initializeCanonicalPool();
    }

    function testDonationsCannotBlockOrExpandLaunchPrincipal() public {
        staticsToken.transfer(address(hook), 1 ether);
        wethToken.transfer(address(hook), 1 ether);
        controllerContract.initializeCanonicalPool();

        uint256 settled;
        for (uint8 band = 1; band <= 6; ++band) {
            settled += hook.launchBandStatics(band);
        }
        assertEq(settled + hook.launchRoundingDust(), hook.PUBLIC_LAUNCH_INVENTORY());
        assertEq(staticsToken.balanceOf(address(hook)), hook.launchRoundingDust() + 1 ether);
        assertEq(wethToken.balanceOf(address(hook)), 1 ether);
    }

    function testCanonicalPoolRejectsUnauthorizedInitializer() public {
        IStaticsV4Hook.PoolConfigurationView memory configuration = hook.poolConfiguration(poolId);
        vm.expectRevert();
        manager.initialize(poolKey, configuration.expectedSqrtPriceX96);

        controllerContract.initializeCanonicalPool();
        assertTrue(hook.poolConfiguration(poolId).initialized);
    }

    function testOnlyAuthorizedBinderCanBindHook() public {
        StaticsHookController unboundController = new StaticsHookController(address(this), address(this));
        StaticsV4Hook unboundHook =
            _deployHookFor(unboundController, address(staticsToken), address(wethToken), treasury);

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(StaticsHookController.InvalidHookBinder.selector);
        unboundController.bindHook(address(unboundHook));
        unboundController.bindHook(address(unboundHook));

        vm.expectRevert(StaticsHookController.InvalidHookBinder.selector);
        unboundController.bindHook(address(unboundHook));
    }

    function testControllerRegistersAndAuthenticatesAdditionalPools() public {
        MockERC20 tokenA = new MockERC20("Pool A", "pA", 18);
        MockERC20 tokenB = new MockERC20("Pool B", "pB", 18);
        (Currency currency0, Currency currency1) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));
        PoolKey memory additionalKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))
        });
        address initializer = makeAddr("poolInitializer");
        IStaticsV4Hook.RevenueRecipients memory recipients;
        recipients.treasury = treasury;
        uint160 expectedPrice = TickMath.getSqrtPriceAtTick(0);

        PoolId additionalId =
            controllerContract.registerPool(additionalKey, expectedPrice, initializer, _initialFees(), recipients);
        assertEq(PoolId.unwrap(additionalId), PoolId.unwrap(additionalKey.toId()));

        vm.prank(makeAddr("wrongInitializer"));
        vm.expectRevert();
        manager.initialize(additionalKey, expectedPrice);

        vm.prank(initializer);
        manager.initialize(additionalKey, expectedPrice);
        assertTrue(hook.poolConfiguration(additionalId).initialized);
    }

    function testInitialConfigurationIsTwentyFiveSeventyFive() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, REQUIRED_FLAGS);
        IStaticsV4Hook.PoolConfigurationView memory configuration = hook.poolConfiguration(poolId);
        assertEq(configuration.fees.inputFeeBps, INPUT_FEE_BPS);
        assertEq(configuration.fees.outputFeeBps, OUTPUT_FEE_BPS);
        assertEq(configuration.fees.polShareBps, 2_500);
        assertEq(configuration.fees.treasuryShareBps, 7_500);
        assertEq(configuration.recipients.treasury, treasury);
    }

    function testLaunchMirrorsRangesWhenStaticsIsCurrencyOne() public {
        MockERC20 tokenA = new MockERC20("Mirror A", "mA", 18);
        MockERC20 tokenB = new MockERC20("Mirror B", "mB", 18);
        (MockERC20 mirrorWeth, MockERC20 mirrorStatics) =
            address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        mirrorStatics.mint(address(this), 999_955_550 ether);

        StaticsHookController mirrorController = new StaticsHookController(address(this), address(this));
        StaticsV4Hook mirrorHook =
            _deployHookFor(mirrorController, address(mirrorStatics), address(mirrorWeth), treasury);
        mirrorController.bindHook(address(mirrorHook));
        mirrorStatics.transfer(address(mirrorHook), mirrorHook.PUBLIC_LAUNCH_INVENTORY());

        PoolKey memory mirrorKey = mirrorHook.canonicalPoolKey();
        assertEq(Currency.unwrap(mirrorKey.currency1), address(mirrorStatics));
        (int24 lower1, int24 upper1) = mirrorHook.launchBandTicks(1);
        (int24 lower6, int24 upper6) = mirrorHook.launchBandTicks(6);
        assertEq(lower1, 143_020);
        assertEq(upper1, 166_040);
        assertEq(lower6, 27_880);
        assertEq(upper6, 50_910);

        mirrorController.initializeCanonicalPool();
        assertTrue(mirrorHook.launchInventoryInstalled());
        assertEq(mirrorStatics.balanceOf(address(mirrorHook)), mirrorHook.launchRoundingDust());
    }

    function _swapInput(bool zeroForOne, uint256 amountIn) private returns (BalanceDelta delta) {
        return _swapSpecified(zeroForOne, -int256(amountIn));
    }

    function _swapSpecified(bool zeroForOne, int256 amountSpecified) private returns (BalanceDelta delta) {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
        delta = swapRouter.swap(
            poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );
    }

    function _initialFees() private pure returns (IStaticsV4Hook.FeeConfiguration memory fees) {
        fees = IStaticsV4Hook.FeeConfiguration({
            inputFeeBps: INPUT_FEE_BPS,
            outputFeeBps: OUTPUT_FEE_BPS,
            polShareBps: 2_500,
            liquidityProviderShareBps: 0,
            basketStakerShareBps: 0,
            staticsStakerShareBps: 0,
            partnerShareBps: 0,
            creatorShareBps: 0,
            treasuryShareBps: 7_500
        });
    }

    function _deployHook() private returns (StaticsV4Hook deployed) {
        return _deployHookFor(controllerContract, address(staticsToken), address(wethToken), treasury);
    }

    function _deployHookFor(StaticsHookController controller_, address statics_, address weth_, address treasury_)
        private
        returns (StaticsV4Hook deployed)
    {
        bytes memory constructorArgs =
            abi.encode(manager, address(controller_), statics_, weth_, treasury_, INPUT_FEE_BPS, OUTPUT_FEE_BPS);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_FLAGS, type(StaticsV4Hook).creationCode, constructorArgs);
        deployed = new StaticsV4Hook{salt: salt}(
            manager, address(controller_), statics_, weth_, treasury_, INPUT_FEE_BPS, OUTPUT_FEE_BPS
        );
        assertEq(address(deployed), expected);
    }
}
