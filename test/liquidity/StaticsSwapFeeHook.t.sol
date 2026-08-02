// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {StaticsSwapFeeHook} from "../../src/liquidity/StaticsSwapFeeHook.sol";

contract HookCompatibilityERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }
}

contract HookSenderExtraFeeERC20 is HookCompatibilityERC20 {
    address public taxedSender;

    constructor() HookCompatibilityERC20("Sender Extra Tax", "SETAX") {}

    function setTaxedSender(address sender) external {
        taxedSender = sender;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == taxedSender && to != address(0)) super._update(from, address(0), value / 100);
        super._update(from, to, value);
    }
}

contract HookZeroApprovalRevertingERC20 is HookCompatibilityERC20 {
    error ZeroApprovalUnsupported();

    constructor() HookCompatibilityERC20("Zero Approval Reverts", "ZAR") {}

    function approve(address spender, uint256 value) public override returns (bool) {
        if (value == 0) revert ZeroApprovalUnsupported();
        return super.approve(spender, value);
    }
}

contract HookFeeReceiver {
    using SafeERC20 for IERC20;

    address public hook;
    bool public stakersEligible = true;
    mapping(address asset => bool eligible) public rewardAssetEligible;
    mapping(address asset => uint256 amount) public basketStakerFees;
    mapping(address asset => uint256 amount) public stakerFees;
    mapping(address asset => uint256 amount) public treasuryFees;

    function configureHook(address hook_) external {
        require(hook == address(0));
        hook = hook_;
    }

    function setStakersEligible(bool eligible) external {
        stakersEligible = eligible;
    }

    function setRewardAssetEligible(address asset, bool eligible) external {
        rewardAssetEligible[asset] = eligible;
    }

    function canAccrueStakerRewards(address asset) external view returns (bool) {
        return stakersEligible && rewardAssetEligible[asset];
    }

    function canAccrueLiquidityRewards(PoolId) external pure returns (bool) {
        return false;
    }

    function canAccrueBasketRewards(PoolId) external pure returns (bool) {
        return false;
    }

    function routeSwapFees(address asset, uint256 stakerAmount, uint256 treasuryAmount) public {
        require(msg.sender == hook);
        uint256 total = stakerAmount + treasuryAmount;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), total);
        stakerFees[asset] += stakerAmount;
        treasuryFees[asset] += treasuryAmount;
    }

    function routeCanonicalSwapFees(
        PoolId,
        address asset,
        uint256 liquidityProviderAmount,
        uint256 basketStakerAmount,
        uint256 staticsStakerAmount,
        uint256 treasuryAmount
    ) external {
        require(liquidityProviderAmount == 0);
        require(basketStakerAmount == 0);
        routeSwapFees(asset, staticsStakerAmount, treasuryAmount);
    }

    function registerPool(PoolKey calldata key) external returns (PoolId) {
        return IStaticsSwapFeeHook(hook).registerPool(key);
    }

    function setFeeConfiguration(
        uint16 inputFeeBps,
        uint16 outputFeeBps,
        uint16 polShareBps,
        uint16 liquidityProviderShareBps,
        uint16 staticsStakerShareBps,
        uint16 treasuryShareBps
    ) external {
        IStaticsSwapFeeHook(hook)
            .setFeeConfiguration(
                inputFeeBps,
                outputFeeBps,
                polShareBps,
                liquidityProviderShareBps,
                0,
                staticsStakerShareBps,
                treasuryShareBps
            );
    }

    function setPoolFeeConfiguration(PoolId poolId, IStaticsSwapFeeHook.FeeConfiguration calldata allocation) external {
        IStaticsSwapFeeHook(hook).setPoolFeeConfiguration(poolId, allocation);
    }

    function clearPoolFeeConfiguration(PoolId poolId) external {
        IStaticsSwapFeeHook(hook).clearPoolFeeConfiguration(poolId);
    }

    function release(PoolKey calldata key, address receiver) external returns (uint256 amount0, uint256 amount1) {
        return IStaticsSwapFeeHook(hook).releasePermanentLiquidity(key, receiver);
    }

    function decommission(PoolKey calldata key) external {
        IStaticsSwapFeeHook(hook).decommissionPool(key);
    }

    function seed(IStaticsSwapFeeHook.PermanentLiquiditySeed[] calldata seeds) external {
        uint256 length = seeds.length;
        address[] memory currencies = new address[](length * 2);
        uint256[] memory amounts = new uint256[](length * 2);
        uint256 currencyCount;
        for (uint256 i; i < length; ++i) {
            IStaticsSwapFeeHook.PermanentLiquiditySeed calldata seed_ = seeds[i];
            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(seed_.key.tickSpacing));
            uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(seed_.key.tickSpacing));
            uint256 amount0 = SqrtPriceMath.getAmount0Delta(1 << 96, sqrtUpper, seed_.liquidity, true);
            uint256 amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, 1 << 96, seed_.liquidity, true);
            currencyCount =
                _addFunding(currencies, amounts, currencyCount, Currency.unwrap(seed_.key.currency0), amount0);
            currencyCount =
                _addFunding(currencies, amounts, currencyCount, Currency.unwrap(seed_.key.currency1), amount1);
        }
        for (uint256 i; i < currencyCount; ++i) {
            IERC20(currencies[i]).forceApprove(hook, amounts[i]);
        }
        IStaticsSwapFeeHook(hook).seedPermanentLiquidity(seeds);
    }

    function _addFunding(
        address[] memory currencies,
        uint256[] memory amounts,
        uint256 length,
        address currency,
        uint256 amount
    ) private pure returns (uint256) {
        for (uint256 i; i < length; ++i) {
            if (currencies[i] == currency) {
                amounts[i] += amount;
                return length;
            }
        }
        currencies[length] = currency;
        amounts[length] = amount;
        return length + 1;
    }
}

contract StaticsSwapFeeHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint16 private constant INPUT_FEE_BPS = 25;
    uint16 private constant OUTPUT_FEE_BPS = 25;
    uint24 private constant LP_FEE = 0;
    int24 private constant TICK_SPACING = 10;
    uint160 private constant REQUIRED_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    HookFeeReceiver private receiver;
    StaticsSwapFeeHook private hook;
    PoolId private poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        receiver = new HookFeeReceiver();
        hook = _deployHook(address(receiver));
        receiver.configureHook(address(hook));
        key = _registerInitializeAndSeed(currency0, currency1, TICK_SPACING);
        poolId = key.toId();
        receiver.setRewardAssetEligible(Currency.unwrap(key.currency0), true);
        receiver.setRewardAssetEligible(Currency.unwrap(key.currency1), true);
    }

    function testMinedAddressEnablesOnlyBilateralFeePermissions() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, REQUIRED_FLAGS);
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.afterInitialize);
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.beforeSwapReturnDelta);
        assertTrue(permissions.afterSwap);
        assertTrue(permissions.afterSwapReturnDelta);
        assertEq(hook.staticsDiamond(), address(receiver));
        IStaticsSwapFeeHook.FeeConfiguration memory config = hook.feeConfiguration();
        assertEq(config.inputFeeBps, INPUT_FEE_BPS);
        assertEq(config.outputFeeBps, OUTPUT_FEE_BPS);
        assertEq(config.polShareBps, 1_000);
        assertEq(config.liquidityProviderShareBps, 2_500);
        assertEq(config.basketStakerShareBps, 2_500);
        assertEq(config.staticsStakerShareBps, 1_500);
        assertEq(config.treasuryShareBps, 2_500);
    }

    function testExactInputChargesBothAssetsAndLocksPolInBothDirections() public {
        _assertExactInput(true, 0.001 ether);
        _assertExactInput(false, 0.001 ether);
        assertGt(hook.lockedLiquidity(poolId), 0);
    }

    function testExactOutputChargesBothAssetsInBothDirections() public {
        _assertExactOutput(true, 0.0001 ether);
        _assertExactOutput(false, 0.0001 ether);
        assertGt(hook.lockedLiquidity(poolId), 0);
    }

    function testNoStakersRedirectsStakerShareIntoPermanentLiquidity() public {
        receiver.setStakersEligible(false);
        _swapExactInput(true, 0.001 ether);
        assertEq(receiver.stakerFees(Currency.unwrap(key.currency0)), 0);
        assertEq(receiver.stakerFees(Currency.unwrap(key.currency1)), 0);
        assertGt(receiver.treasuryFees(Currency.unwrap(key.currency0)), 0);
        assertGt(receiver.treasuryFees(Currency.unwrap(key.currency1)), 0);
        assertGt(hook.lockedLiquidity(poolId), 0);
    }

    function testEachSwapLegChecksItsAssetEligibleStake() public {
        address specified = Currency.unwrap(key.currency0);
        address unspecified = Currency.unwrap(key.currency1);
        receiver.setRewardAssetEligible(unspecified, false);
        _swapExactInput(true, 0.001 ether);

        assertGt(receiver.stakerFees(specified), 0);
        assertEq(receiver.stakerFees(unspecified), 0);
        assertGt(receiver.treasuryFees(specified), 0);
        assertGt(receiver.treasuryFees(unspecified), 0);
    }

    function testDonatedPositionFeesRemainPolAndDoNotBlockSwaps() public {
        _swapExactInput(true, 0.001 ether);
        uint128 lockedBefore = hook.lockedLiquidity(poolId);
        donateRouter.donate(key, 1 ether, 1 ether, "");

        _swapExactInput(false, 1_000);

        assertGe(hook.lockedLiquidity(poolId), lockedBefore);
        assertGt(
            hook.pendingPermanentLiquidity(poolId, key.currency0)
                + hook.pendingPermanentLiquidity(poolId, key.currency1),
            0
        );
    }

    function testSenderExtraDebitFromHookRevertsSwapBeforeCrossPoolInventoryCanBeSpent() public {
        HookSenderExtraFeeERC20 taxed = new HookSenderExtraFeeERC20();
        PoolKey memory taxedKey = _createCompatibilityPool(taxed);
        taxed.setTaxedSender(address(hook));

        vm.expectPartialRevert(CustomRevert.WrappedError.selector);
        swap(taxedKey, true, -int256(0.001 ether), "");
    }

    function testSenderExtraDebitFromPoolManagerRevertsSwap() public {
        HookSenderExtraFeeERC20 taxed = new HookSenderExtraFeeERC20();
        PoolKey memory taxedKey = _createCompatibilityPool(taxed);
        taxed.setTaxedSender(address(manager));

        vm.expectPartialRevert(CustomRevert.WrappedError.selector);
        swap(taxedKey, true, -int256(0.001 ether), "");
    }

    function testTokenThatRejectsZeroApprovalCanRouteSwapFees() public {
        HookZeroApprovalRevertingERC20 token = new HookZeroApprovalRevertingERC20();
        PoolKey memory compatibleKey = _createCompatibilityPool(token);

        swap(compatibleKey, true, -int256(0.001 ether), "");

        assertGt(receiver.stakerFees(address(token)) + receiver.treasuryFees(address(token)), 0);
    }

    function testFeeConfigurationIsDiamondOnlyAndCombinedFeeIsCapped() public {
        address outsider = makeAddr("outsider");
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(StaticsSwapFeeHook.OnlyStaticsDiamond.selector, outsider));
        hook.setFeeConfiguration(25, 25, 5_000, 1_000, 0, 3_000, 1_000);

        vm.expectRevert(StaticsSwapFeeHook.InvalidFeeConfiguration.selector);
        receiver.setFeeConfiguration(101, 100, 5_000, 1_000, 3_000, 1_000);
        vm.expectRevert(StaticsSwapFeeHook.InvalidFeeConfiguration.selector);
        receiver.setFeeConfiguration(25, 25, 5_000, 1_000, 3_000, 999);
    }

    function testPoolConfigurationIsDiamondOnlyRegisteredAndValidated() public {
        IStaticsSwapFeeHook.FeeConfiguration memory configuration = IStaticsSwapFeeHook.FeeConfiguration({
            inputFeeBps: 25,
            outputFeeBps: 25,
            polShareBps: 0,
            liquidityProviderShareBps: 0,
            basketStakerShareBps: 0,
            staticsStakerShareBps: 8_000,
            treasuryShareBps: 2_000
        });
        address outsider = makeAddr("configuration-outsider");
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(StaticsSwapFeeHook.OnlyStaticsDiamond.selector, outsider));
        hook.setPoolFeeConfiguration(poolId, configuration);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(StaticsSwapFeeHook.OnlyStaticsDiamond.selector, outsider));
        hook.clearPoolFeeConfiguration(poolId);

        PoolId unknown = PoolId.wrap(keccak256("unknown-pool"));
        vm.expectRevert(abi.encodeWithSelector(StaticsSwapFeeHook.PoolNotRegistered.selector, unknown));
        receiver.setPoolFeeConfiguration(unknown, configuration);

        configuration.treasuryShareBps = 1_999;
        vm.expectRevert(StaticsSwapFeeHook.InvalidFeeConfiguration.selector);
        receiver.setPoolFeeConfiguration(poolId, configuration);
        configuration.treasuryShareBps = 2_000;
        configuration.inputFeeBps = 101;
        configuration.outputFeeBps = 100;
        vm.expectRevert(StaticsSwapFeeHook.InvalidFeeConfiguration.selector);
        receiver.setPoolFeeConfiguration(poolId, configuration);
    }

    function testPoolConfigurationOverrideAndClearTrackLatestGlobalDefault() public {
        IStaticsSwapFeeHook.PoolFeeConfigurationView memory defaultConfiguration = hook.poolFeeConfiguration(poolId);
        assertEq(defaultConfiguration.inputFeeBps, 25);
        assertEq(defaultConfiguration.outputFeeBps, 25);
        assertEq(defaultConfiguration.polShareBps, 1_000);
        assertEq(defaultConfiguration.liquidityProviderShareBps, 2_500);
        assertEq(defaultConfiguration.basketStakerShareBps, 2_500);
        assertEq(defaultConfiguration.staticsStakerShareBps, 1_500);
        assertEq(defaultConfiguration.treasuryShareBps, 2_500);
        assertFalse(defaultConfiguration.overridden);

        receiver.setPoolFeeConfiguration(
            poolId,
            IStaticsSwapFeeHook.FeeConfiguration({
                inputFeeBps: 40,
                outputFeeBps: 60,
                polShareBps: 1_000,
                liquidityProviderShareBps: 2_000,
                basketStakerShareBps: 0,
                staticsStakerShareBps: 3_000,
                treasuryShareBps: 4_000
            })
        );
        receiver.setFeeConfiguration(70, 80, 6_000, 1_000, 2_000, 1_000);
        IStaticsSwapFeeHook.PoolFeeConfigurationView memory overridden = hook.poolFeeConfiguration(poolId);
        assertEq(overridden.inputFeeBps, 40);
        assertEq(overridden.outputFeeBps, 60);
        assertEq(overridden.polShareBps, 1_000);
        assertEq(overridden.liquidityProviderShareBps, 2_000);
        assertEq(overridden.staticsStakerShareBps, 3_000);
        assertEq(overridden.treasuryShareBps, 4_000);
        assertTrue(overridden.overridden);

        receiver.clearPoolFeeConfiguration(poolId);
        IStaticsSwapFeeHook.PoolFeeConfigurationView memory restored = hook.poolFeeConfiguration(poolId);
        assertEq(restored.inputFeeBps, 70);
        assertEq(restored.outputFeeBps, 80);
        assertEq(restored.polShareBps, 6_000);
        assertEq(restored.liquidityProviderShareBps, 1_000);
        assertEq(restored.staticsStakerShareBps, 2_000);
        assertEq(restored.treasuryShareBps, 1_000);
        assertFalse(restored.overridden);
    }

    function testPoolOverrideAppliesDistinctInputAndOutputRates() public {
        uint256 amountIn = 0.001 ether;
        receiver.setPoolFeeConfiguration(
            poolId,
            IStaticsSwapFeeHook.FeeConfiguration({
                inputFeeBps: 100,
                outputFeeBps: 0,
                polShareBps: 0,
                liquidityProviderShareBps: 0,
                basketStakerShareBps: 0,
                staticsStakerShareBps: 0,
                treasuryShareBps: 10_000
            })
        );
        uint256 currency0Before = receiver.treasuryFees(Currency.unwrap(key.currency0));
        uint256 currency1Before = receiver.treasuryFees(Currency.unwrap(key.currency1));
        _swapExactInput(true, amountIn);
        assertEq(
            receiver.treasuryFees(Currency.unwrap(key.currency0)) - currency0Before,
            Math.mulDiv(amountIn, 100, 10_000, Math.Rounding.Ceil)
        );
        assertEq(receiver.treasuryFees(Currency.unwrap(key.currency1)), currency1Before);

        receiver.setPoolFeeConfiguration(
            poolId,
            IStaticsSwapFeeHook.FeeConfiguration({
                inputFeeBps: 0,
                outputFeeBps: 100,
                polShareBps: 0,
                liquidityProviderShareBps: 0,
                basketStakerShareBps: 0,
                staticsStakerShareBps: 0,
                treasuryShareBps: 10_000
            })
        );
        currency0Before = receiver.treasuryFees(Currency.unwrap(key.currency0));
        currency1Before = receiver.treasuryFees(Currency.unwrap(key.currency1));
        _swapExactInput(true, amountIn);
        assertEq(receiver.treasuryFees(Currency.unwrap(key.currency0)), currency0Before);
        assertGt(receiver.treasuryFees(Currency.unwrap(key.currency1)), currency1Before);
    }

    function testPoolOverrideAppliesDistinctRatesToExactOutputInBothDirections() public {
        uint256 amountOut = 0.0001 ether;
        receiver.setPoolFeeConfiguration(
            poolId,
            IStaticsSwapFeeHook.FeeConfiguration({
                inputFeeBps: 0,
                outputFeeBps: 100,
                polShareBps: 0,
                liquidityProviderShareBps: 0,
                basketStakerShareBps: 0,
                staticsStakerShareBps: 0,
                treasuryShareBps: 10_000
            })
        );

        for (uint256 i; i < 2; ++i) {
            bool zeroForOne = i == 0;
            Currency input = zeroForOne ? key.currency0 : key.currency1;
            Currency output = zeroForOne ? key.currency1 : key.currency0;
            uint256 inputBefore = receiver.treasuryFees(Currency.unwrap(input));
            uint256 outputBefore = receiver.treasuryFees(Currency.unwrap(output));
            BalanceDelta delta = swap(key, zeroForOne, int256(amountOut), "");
            assertEq(receiver.treasuryFees(Currency.unwrap(input)), inputBefore);
            assertEq(
                receiver.treasuryFees(Currency.unwrap(output)) - outputBefore,
                Math.mulDiv(amountOut, 100, 10_000, Math.Rounding.Ceil)
            );
            assertEq(uint256(uint128(zeroForOne ? delta.amount1() : delta.amount0())), amountOut);
        }

        receiver.setPoolFeeConfiguration(
            poolId,
            IStaticsSwapFeeHook.FeeConfiguration({
                inputFeeBps: 100,
                outputFeeBps: 0,
                polShareBps: 0,
                liquidityProviderShareBps: 0,
                basketStakerShareBps: 0,
                staticsStakerShareBps: 0,
                treasuryShareBps: 10_000
            })
        );

        for (uint256 i; i < 2; ++i) {
            bool zeroForOne = i == 0;
            Currency input = zeroForOne ? key.currency0 : key.currency1;
            Currency output = zeroForOne ? key.currency1 : key.currency0;
            uint256 inputBefore = receiver.treasuryFees(Currency.unwrap(input));
            uint256 outputBefore = receiver.treasuryFees(Currency.unwrap(output));
            BalanceDelta delta = swap(key, zeroForOne, int256(amountOut), "");
            uint256 totalInput = uint256(-int256(zeroForOne ? delta.amount0() : delta.amount1()));
            assertEq(receiver.treasuryFees(Currency.unwrap(input)) - inputBefore, _feeFromGross(totalInput, 100));
            assertEq(receiver.treasuryFees(Currency.unwrap(output)), outputBefore);
            assertEq(uint256(uint128(zeroForOne ? delta.amount1() : delta.amount0())), amountOut);
        }
    }

    function testZeroPolOverrideRoutesExactInputBothLegsInBothDirectionsWithoutNewPol() public {
        receiver.setPoolFeeConfiguration(
            poolId,
            IStaticsSwapFeeHook.FeeConfiguration({
                inputFeeBps: 25,
                outputFeeBps: 25,
                polShareBps: 0,
                liquidityProviderShareBps: 0,
                basketStakerShareBps: 0,
                staticsStakerShareBps: 8_000,
                treasuryShareBps: 2_000
            })
        );
        _assertOverriddenExactInput(true, 0.001 ether);
        _assertOverriddenExactInput(false, 0.001 ether);
        assertEq(hook.lockedLiquidity(poolId), 0);
        assertEq(hook.pendingPermanentLiquidity(poolId, key.currency0), 0);
        assertEq(hook.pendingPermanentLiquidity(poolId, key.currency1), 0);
    }

    function testZeroPolOverrideRoutesExactOutputBothLegsInBothDirectionsWithoutNewPol() public {
        receiver.setPoolFeeConfiguration(
            poolId,
            IStaticsSwapFeeHook.FeeConfiguration({
                inputFeeBps: 25,
                outputFeeBps: 25,
                polShareBps: 0,
                liquidityProviderShareBps: 0,
                basketStakerShareBps: 0,
                staticsStakerShareBps: 8_000,
                treasuryShareBps: 2_000
            })
        );
        _assertOverriddenExactOutput(true, 0.0001 ether);
        _assertOverriddenExactOutput(false, 0.0001 ether);
        assertEq(hook.lockedLiquidity(poolId), 0);
        assertEq(hook.pendingPermanentLiquidity(poolId, key.currency0), 0);
        assertEq(hook.pendingPermanentLiquidity(poolId, key.currency1), 0);
    }

    function testZeroPolOverridePreservesExistingPendingAndPermanentLiquidity() public {
        _swapExactInput(true, 0.001 ether);
        uint128 lockedBefore = hook.lockedLiquidity(poolId);
        uint256 pending0Before = hook.pendingPermanentLiquidity(poolId, key.currency0);
        uint256 pending1Before = hook.pendingPermanentLiquidity(poolId, key.currency1);
        assertGt(lockedBefore, 0);

        receiver.setPoolFeeConfiguration(
            poolId,
            IStaticsSwapFeeHook.FeeConfiguration({
                inputFeeBps: 25,
                outputFeeBps: 25,
                polShareBps: 0,
                liquidityProviderShareBps: 0,
                basketStakerShareBps: 0,
                staticsStakerShareBps: 8_000,
                treasuryShareBps: 2_000
            })
        );

        assertEq(hook.lockedLiquidity(poolId), lockedBefore);
        assertEq(hook.pendingPermanentLiquidity(poolId, key.currency0), pending0Before);
        assertEq(hook.pendingPermanentLiquidity(poolId, key.currency1), pending1Before);
    }

    function testUnavailableStakerShareFromOverrideStillFallsThroughToPol() public {
        receiver.setPoolFeeConfiguration(
            poolId,
            IStaticsSwapFeeHook.FeeConfiguration({
                inputFeeBps: 25,
                outputFeeBps: 25,
                polShareBps: 0,
                liquidityProviderShareBps: 0,
                basketStakerShareBps: 0,
                staticsStakerShareBps: 8_000,
                treasuryShareBps: 2_000
            })
        );
        receiver.setStakersEligible(false);
        _swapExactInput(true, 0.001 ether);
        assertEq(receiver.stakerFees(Currency.unwrap(key.currency0)), 0);
        assertEq(receiver.stakerFees(Currency.unwrap(key.currency1)), 0);
        assertGt(
            hook.lockedLiquidity(poolId) + hook.pendingPermanentLiquidity(poolId, key.currency0)
                + hook.pendingPermanentLiquidity(poolId, key.currency1),
            0
        );
    }

    function testPoolOverrideControlsOnlyItsPoolRatesAndAllocation() public {
        HookCompatibilityERC20 secondToken = new HookCompatibilityERC20("Second Pool", "SECOND");
        PoolKey memory secondKey = _createCompatibilityPool(secondToken);
        PoolId secondPoolId = secondKey.toId();
        receiver.setPoolFeeConfiguration(
            poolId,
            IStaticsSwapFeeHook.FeeConfiguration({
                inputFeeBps: 40,
                outputFeeBps: 60,
                polShareBps: 0,
                liquidityProviderShareBps: 0,
                basketStakerShareBps: 0,
                staticsStakerShareBps: 8_000,
                treasuryShareBps: 2_000
            })
        );

        IStaticsSwapFeeHook.PoolFeeConfigurationView memory firstConfiguration = hook.poolFeeConfiguration(poolId);
        IStaticsSwapFeeHook.PoolFeeConfigurationView memory secondConfiguration =
            hook.poolFeeConfiguration(secondPoolId);
        IStaticsSwapFeeHook.FeeConfiguration memory globalConfiguration = hook.feeConfiguration();
        assertTrue(firstConfiguration.overridden);
        assertEq(firstConfiguration.inputFeeBps, 40);
        assertEq(firstConfiguration.outputFeeBps, 60);
        assertFalse(secondConfiguration.overridden);
        assertEq(secondConfiguration.inputFeeBps, globalConfiguration.inputFeeBps);
        assertEq(secondConfiguration.outputFeeBps, globalConfiguration.outputFeeBps);
        assertEq(secondConfiguration.polShareBps, globalConfiguration.polShareBps);
        assertEq(secondConfiguration.liquidityProviderShareBps, globalConfiguration.liquidityProviderShareBps);
        assertEq(globalConfiguration.inputFeeBps, INPUT_FEE_BPS);
        assertEq(globalConfiguration.outputFeeBps, OUTPUT_FEE_BPS);

        uint256 amountIn = 0.001 ether;
        BalanceDelta firstDelta = _swapExactInput(true, amountIn);
        BalanceDelta secondDelta = swap(secondKey, true, -int256(amountIn), "");
        uint256 firstNetOutput = uint256(uint128(firstDelta.amount1()));
        uint256 secondNetOutput = uint256(uint128(secondDelta.amount1()));
        uint256 firstInputFee = Math.mulDiv(amountIn, firstConfiguration.inputFeeBps, 10_000, Math.Rounding.Ceil);
        uint256 secondInputFee = Math.mulDiv(amountIn, secondConfiguration.inputFeeBps, 10_000, Math.Rounding.Ceil);
        uint256 firstOutputFee = _feeFromNet(firstNetOutput, firstConfiguration.outputFeeBps);
        uint256 secondOutputFee = _feeFromNet(secondNetOutput, secondConfiguration.outputFeeBps);
        assertGt(firstInputFee, secondInputFee);
        assertGt(firstOutputFee, secondOutputFee);
        assertLt(firstNetOutput, secondNetOutput);
        assertTrue(secondDelta.amount0() != 0 && secondDelta.amount1() != 0);
        assertEq(hook.lockedLiquidity(poolId), 0);
        assertGt(hook.lockedLiquidity(secondPoolId), 0);

        receiver.setFeeConfiguration(70, 80, 6_000, 1_000, 2_000, 1_000);
        firstConfiguration = hook.poolFeeConfiguration(poolId);
        secondConfiguration = hook.poolFeeConfiguration(secondPoolId);
        assertEq(firstConfiguration.inputFeeBps, 40);
        assertEq(firstConfiguration.outputFeeBps, 60);
        assertEq(firstConfiguration.polShareBps, 0);
        assertEq(firstConfiguration.staticsStakerShareBps, 8_000);
        assertEq(firstConfiguration.treasuryShareBps, 2_000);
        assertEq(secondConfiguration.inputFeeBps, 70);
        assertEq(secondConfiguration.outputFeeBps, 80);
        assertEq(secondConfiguration.polShareBps, 6_000);
        assertEq(secondConfiguration.liquidityProviderShareBps, 1_000);
        assertEq(secondConfiguration.staticsStakerShareBps, 2_000);
        assertEq(secondConfiguration.treasuryShareBps, 1_000);
    }

    function testExistingPendingPolCompoundsAfterZeroPolOverride() public {
        // Recreate the prior effective POL route so both currencies retain pending inventory.
        receiver.setFeeConfiguration(25, 25, 7_000, 0, 2_000, 1_000);
        _swapExactInput(true, 0.001 ether);
        uint128 lockedBeforeDonation = hook.lockedLiquidity(poolId);
        donateRouter.donate(key, 0.001 ether, 0.001 ether, "");
        _swapExactInput(false, 1_000);
        uint256 pending0 = hook.pendingPermanentLiquidity(poolId, key.currency0);
        uint256 pending1 = hook.pendingPermanentLiquidity(poolId, key.currency1);
        assertGt(pending0, 0);
        assertGt(pending1, 0);

        receiver.setPoolFeeConfiguration(
            poolId,
            IStaticsSwapFeeHook.FeeConfiguration({
                inputFeeBps: 25,
                outputFeeBps: 25,
                polShareBps: 0,
                liquidityProviderShareBps: 0,
                basketStakerShareBps: 0,
                staticsStakerShareBps: 8_000,
                treasuryShareBps: 2_000
            })
        );
        _swapExactInput(true, 1_000);
        assertGt(hook.lockedLiquidity(poolId), lockedBeforeDonation);
        assertLt(hook.pendingPermanentLiquidity(poolId, key.currency0), pending0);
        assertLt(hook.pendingPermanentLiquidity(poolId, key.currency1), pending1);
    }

    function testLiquidityProviderShareHasNoIndependentCap() public {
        receiver.setFeeConfiguration(25, 25, 0, 9_000, 0, 1_000);
        IStaticsSwapFeeHook.FeeConfiguration memory config = hook.feeConfiguration();
        assertEq(config.liquidityProviderShareBps, 9_000);
        _swapExactInput(true, 0.001 ether);
        assertGt(hook.lockedLiquidity(poolId), 0);
    }

    function testRegistrationRejectsNativeCurrencyAndNativeLpFees() public {
        PoolKey memory nonzeroFee = _poolKey(currency0, currency1, 1, 20);
        vm.expectRevert(abi.encodeWithSelector(StaticsSwapFeeHook.NonzeroNativeLpFee.selector, uint24(1)));
        receiver.registerPool(nonzeroFee);

        PoolKey memory nativePool = PoolKey({
            currency0: Currency.wrap(address(0)), currency1: currency1, fee: 0, tickSpacing: 20, hooks: IHooks(hook)
        });
        vm.expectRevert(StaticsSwapFeeHook.NativeCurrencyUnsupported.selector);
        receiver.registerPool(nativePool);
    }

    function testUnregisteredPoolCannotInitialize() public {
        PoolKey memory unregistered = _poolKey(currency0, currency1, LP_FEE, 20);
        vm.expectPartialRevert(CustomRevert.WrappedError.selector);
        manager.initialize(unregistered, SQRT_PRICE_1_1);
    }

    function testPermanentLiquidityCanOnlyReleaseThroughDiamond() public {
        _swapExactInput(true, 0.001 ether);
        uint128 lockedBefore = hook.lockedLiquidity(poolId);
        assertGt(lockedBefore, 0);

        address outsider = makeAddr("outsider");
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(StaticsSwapFeeHook.OnlyStaticsDiamond.selector, outsider));
        hook.releasePermanentLiquidity(key, outsider);

        receiver.decommission(key);
        (uint256 amount0, uint256 amount1) = receiver.release(key, address(receiver));
        assertGt(amount0, 0);
        assertGt(amount1, 0);
        assertEq(hook.lockedLiquidity(poolId), 0);
    }

    function testDiamondSeedsMultiplePoolsThroughOnePermanentLiquidityPath() public {
        HookCompatibilityERC20 shared = new HookCompatibilityERC20("Shared", "SHARED");
        HookCompatibilityERC20 first = new HookCompatibilityERC20("First", "FIRST");
        HookCompatibilityERC20 second = new HookCompatibilityERC20("Second", "SECOND");
        PoolKey memory firstKey = _registerAndInitialize(shared, first);
        PoolKey memory secondKey = _registerAndInitialize(shared, second);
        uint128 firstLiquidity = 2 ether;
        uint128 secondLiquidity = 3 ether;
        IStaticsSwapFeeHook.PermanentLiquiditySeed[] memory seeds = new IStaticsSwapFeeHook.PermanentLiquiditySeed[](2);
        seeds[0] = IStaticsSwapFeeHook.PermanentLiquiditySeed({key: firstKey, liquidity: firstLiquidity});
        seeds[1] = IStaticsSwapFeeHook.PermanentLiquiditySeed({key: secondKey, liquidity: secondLiquidity});
        shared.mint(address(receiver), 10 ether);
        first.mint(address(receiver), 10 ether);
        second.mint(address(receiver), 10 ether);

        receiver.seed(seeds);

        assertEq(hook.lockedLiquidity(firstKey.toId()), firstLiquidity);
        assertEq(hook.lockedLiquidity(secondKey.toId()), secondLiquidity);
        assertEq(shared.allowance(address(receiver), address(hook)), 0);
        assertEq(first.allowance(address(receiver), address(hook)), 0);
        assertEq(second.allowance(address(receiver), address(hook)), 0);
    }

    function testPermanentLaunchSeedRejectsDuplicateAndAlreadySeededPools() public {
        HookCompatibilityERC20 first = new HookCompatibilityERC20("First", "FIRST");
        HookCompatibilityERC20 second = new HookCompatibilityERC20("Second", "SECOND");
        PoolKey memory seededKey = _registerAndInitialize(first, second);
        IStaticsSwapFeeHook.PermanentLiquiditySeed[] memory seeds = new IStaticsSwapFeeHook.PermanentLiquiditySeed[](2);
        seeds[0] = IStaticsSwapFeeHook.PermanentLiquiditySeed({key: seededKey, liquidity: 1 ether});
        seeds[1] = IStaticsSwapFeeHook.PermanentLiquiditySeed({key: seededKey, liquidity: 1 ether});
        vm.expectRevert(
            abi.encodeWithSelector(StaticsSwapFeeHook.DuplicatePermanentLiquiditySeed.selector, seededKey.toId())
        );
        receiver.seed(seeds);

        first.mint(address(receiver), 10 ether);
        second.mint(address(receiver), 10 ether);
        seeds = new IStaticsSwapFeeHook.PermanentLiquiditySeed[](1);
        seeds[0] = IStaticsSwapFeeHook.PermanentLiquiditySeed({key: seededKey, liquidity: 1 ether});
        receiver.seed(seeds);
        vm.expectRevert(
            abi.encodeWithSelector(StaticsSwapFeeHook.PermanentLiquidityAlreadySeeded.selector, seededKey.toId())
        );
        receiver.seed(seeds);
    }

    function testPermanentLaunchSeedIsDiamondOnlyAndRollsBackOnFundingFailure() public {
        HookCompatibilityERC20 first = new HookCompatibilityERC20("First", "FIRST");
        HookCompatibilityERC20 second = new HookCompatibilityERC20("Second", "SECOND");
        PoolKey memory unseededKey = _registerAndInitialize(first, second);
        IStaticsSwapFeeHook.PermanentLiquiditySeed[] memory seeds = new IStaticsSwapFeeHook.PermanentLiquiditySeed[](1);
        seeds[0] = IStaticsSwapFeeHook.PermanentLiquiditySeed({key: unseededKey, liquidity: 1 ether});

        vm.expectRevert(abi.encodeWithSelector(StaticsSwapFeeHook.OnlyStaticsDiamond.selector, address(this)));
        hook.seedPermanentLiquidity(seeds);

        vm.expectRevert();
        receiver.seed(seeds);
        assertEq(hook.lockedLiquidity(unseededKey.toId()), 0);
    }

    function _registerAndInitialize(HookCompatibilityERC20 first, HookCompatibilityERC20 second)
        private
        returns (PoolKey memory poolKey)
    {
        poolKey = _poolKey(Currency.wrap(address(first)), Currency.wrap(address(second)), LP_FEE, TICK_SPACING);
        receiver.registerPool(poolKey);
        manager.initialize(poolKey, SQRT_PRICE_1_1);
    }

    function _assertExactInput(bool zeroForOne, uint256 amountIn) private {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        uint256 inputStakerBefore = receiver.stakerFees(Currency.unwrap(input));
        uint256 inputTreasuryBefore = receiver.treasuryFees(Currency.unwrap(input));
        uint256 outputStakerBefore = receiver.stakerFees(Currency.unwrap(output));
        uint256 outputTreasuryBefore = receiver.treasuryFees(Currency.unwrap(output));

        BalanceDelta delta = _swapExactInput(zeroForOne, amountIn);
        uint256 netOutput = uint256(uint128(zeroForOne ? delta.amount1() : delta.amount0()));
        uint256 inputFee = Math.mulDiv(amountIn, INPUT_FEE_BPS, 10_000, Math.Rounding.Ceil);
        uint256 outputFee = _feeFromNet(netOutput, OUTPUT_FEE_BPS);
        _assertDistribution(input, inputFee, inputStakerBefore, inputTreasuryBefore);
        _assertDistribution(output, outputFee, outputStakerBefore, outputTreasuryBefore);
    }

    function _assertExactOutput(bool zeroForOne, uint256 amountOut) private {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        uint256 inputStakerBefore = receiver.stakerFees(Currency.unwrap(input));
        uint256 inputTreasuryBefore = receiver.treasuryFees(Currency.unwrap(input));
        uint256 outputStakerBefore = receiver.stakerFees(Currency.unwrap(output));
        uint256 outputTreasuryBefore = receiver.treasuryFees(Currency.unwrap(output));

        BalanceDelta delta = swap(key, zeroForOne, int256(amountOut), "");
        uint256 totalInput = uint256(-int256(zeroForOne ? delta.amount0() : delta.amount1()));
        uint256 netOutput = uint256(uint128(zeroForOne ? delta.amount1() : delta.amount0()));
        assertEq(netOutput, amountOut);
        uint256 outputFee = Math.mulDiv(amountOut, OUTPUT_FEE_BPS, 10_000, Math.Rounding.Ceil);
        uint256 inputFee = _feeFromGross(totalInput, INPUT_FEE_BPS);
        _assertDistribution(input, inputFee, inputStakerBefore, inputTreasuryBefore);
        _assertDistribution(output, outputFee, outputStakerBefore, outputTreasuryBefore);
    }

    function _assertDistribution(Currency currency, uint256 fee, uint256 stakerBefore, uint256 treasuryBefore)
        private
        view
    {
        uint256 pol = Math.mulDiv(fee, 1_000, 10_000);
        uint256 liquidityProvider = Math.mulDiv(fee, 2_500, 10_000);
        uint256 basketStaker = Math.mulDiv(fee, 2_500, 10_000);
        uint256 staker = Math.mulDiv(fee, 1_500, 10_000);
        uint256 treasury = fee - pol - liquidityProvider - basketStaker - staker;
        address asset = Currency.unwrap(currency);
        assertEq(receiver.stakerFees(asset) - stakerBefore, staker);
        assertEq(receiver.treasuryFees(asset) - treasuryBefore, treasury);
    }

    function _assertOverriddenExactInput(bool zeroForOne, uint256 amountIn) private {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        uint256 inputStakerBefore = receiver.stakerFees(Currency.unwrap(input));
        uint256 inputTreasuryBefore = receiver.treasuryFees(Currency.unwrap(input));
        uint256 outputStakerBefore = receiver.stakerFees(Currency.unwrap(output));
        uint256 outputTreasuryBefore = receiver.treasuryFees(Currency.unwrap(output));
        BalanceDelta delta = _swapExactInput(zeroForOne, amountIn);
        uint256 netOutput = uint256(uint128(zeroForOne ? delta.amount1() : delta.amount0()));
        _assertOverrideDistribution(
            input,
            Math.mulDiv(amountIn, INPUT_FEE_BPS, 10_000, Math.Rounding.Ceil),
            inputStakerBefore,
            inputTreasuryBefore
        );
        _assertOverrideDistribution(
            output, _feeFromNet(netOutput, OUTPUT_FEE_BPS), outputStakerBefore, outputTreasuryBefore
        );
    }

    function _assertOverriddenExactOutput(bool zeroForOne, uint256 amountOut) private {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        uint256 inputStakerBefore = receiver.stakerFees(Currency.unwrap(input));
        uint256 inputTreasuryBefore = receiver.treasuryFees(Currency.unwrap(input));
        uint256 outputStakerBefore = receiver.stakerFees(Currency.unwrap(output));
        uint256 outputTreasuryBefore = receiver.treasuryFees(Currency.unwrap(output));
        BalanceDelta delta = swap(key, zeroForOne, int256(amountOut), "");
        uint256 totalInput = uint256(-int256(zeroForOne ? delta.amount0() : delta.amount1()));
        _assertOverrideDistribution(
            input, _feeFromGross(totalInput, INPUT_FEE_BPS), inputStakerBefore, inputTreasuryBefore
        );
        _assertOverrideDistribution(
            output,
            Math.mulDiv(amountOut, OUTPUT_FEE_BPS, 10_000, Math.Rounding.Ceil),
            outputStakerBefore,
            outputTreasuryBefore
        );
    }

    function _assertOverrideDistribution(Currency currency, uint256 fee, uint256 stakerBefore, uint256 treasuryBefore)
        private
        view
    {
        uint256 staker = Math.mulDiv(fee, 8_000, 10_000);
        uint256 treasury = fee - staker;
        address asset = Currency.unwrap(currency);
        assertEq(receiver.stakerFees(asset) - stakerBefore, staker);
        assertEq(receiver.treasuryFees(asset) - treasuryBefore, treasury);
        assertEq(staker + treasury, fee);
    }

    function _swapExactInput(bool zeroForOne, uint256 amountIn) private returns (BalanceDelta delta) {
        return swap(key, zeroForOne, -int256(amountIn), "");
    }

    function _registerInitializeAndSeed(Currency first, Currency second, int24 tickSpacing)
        private
        returns (PoolKey memory poolKey)
    {
        poolKey = _poolKey(first, second, LP_FEE, tickSpacing);
        receiver.registerPool(poolKey);
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

    function _createCompatibilityPool(HookCompatibilityERC20 specialToken) private returns (PoolKey memory poolKey) {
        HookCompatibilityERC20 pairedToken = new HookCompatibilityERC20("Paired", "PAIR");
        specialToken.mint(address(this), 1_000 ether);
        pairedToken.mint(address(this), 1_000 ether);
        _approveCompatibilityToken(specialToken);
        _approveCompatibilityToken(pairedToken);
        poolKey = _registerInitializeAndSeed(
            Currency.wrap(address(specialToken)), Currency.wrap(address(pairedToken)), TICK_SPACING
        );
        receiver.setRewardAssetEligible(address(specialToken), true);
        receiver.setRewardAssetEligible(address(pairedToken), true);
    }

    function _approveCompatibilityToken(HookCompatibilityERC20 token) private {
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        token.approve(address(donateRouter), type(uint256).max);
    }

    function _deployHook(address diamond) private returns (StaticsSwapFeeHook deployed) {
        bytes memory constructorArgs = abi.encode(manager, diamond, INPUT_FEE_BPS, OUTPUT_FEE_BPS);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_FLAGS, type(StaticsSwapFeeHook).creationCode, constructorArgs);
        deployed = new StaticsSwapFeeHook{salt: salt}(manager, diamond, INPUT_FEE_BPS, OUTPUT_FEE_BPS);
        assertEq(address(deployed), expected);
    }

    function _feeFromNet(uint256 netAmount, uint256 feeBps) private pure returns (uint256) {
        return Math.mulDiv(netAmount, feeBps, 10_000 - feeBps, Math.Rounding.Ceil);
    }

    function _feeFromGross(uint256 grossAmount, uint256 feeBps) private pure returns (uint256) {
        return Math.mulDiv(grossAmount, feeBps, 10_000 + feeBps, Math.Rounding.Ceil);
    }
}
