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
    uint256 public novelAssetCapacity = type(uint256).max;
    mapping(address asset => bool known) public knownAsset;
    mapping(address asset => uint256 amount) public stakerFees;
    mapping(address asset => uint256 amount) public treasuryFees;

    function configureHook(address hook_) external {
        require(hook == address(0));
        hook = hook_;
    }

    function setStakersEligible(bool eligible) external {
        stakersEligible = eligible;
    }

    function setNovelAssetCapacity(uint256 capacity) external {
        novelAssetCapacity = capacity;
    }

    function canAccrueStakerRewards(address asset) external view returns (bool) {
        return stakersEligible && (knownAsset[asset] || novelAssetCapacity != 0);
    }

    function canAccrueLiquidityRewards(PoolId) external pure returns (bool) {
        return false;
    }

    function routeSwapFees(address asset, uint256 stakerAmount, uint256 treasuryAmount) public {
        require(msg.sender == hook);
        if (stakerAmount != 0 && !knownAsset[asset]) {
            require(novelAssetCapacity != 0, "no reward slot");
            knownAsset[asset] = true;
            --novelAssetCapacity;
        }
        uint256 total = stakerAmount + treasuryAmount;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), total);
        stakerFees[asset] += stakerAmount;
        treasuryFees[asset] += treasuryAmount;
    }

    function routeCanonicalSwapFees(
        PoolId,
        address asset,
        uint256 liquidityProviderAmount,
        uint256 stakerAmount,
        uint256 treasuryAmount
    ) external {
        require(liquidityProviderAmount == 0);
        routeSwapFees(asset, stakerAmount, treasuryAmount);
    }

    function registerPool(PoolKey calldata key) external returns (PoolId) {
        return IStaticsSwapFeeHook(hook).registerPool(key);
    }

    function setFeeConfiguration(
        uint16 inputFeeBps,
        uint16 outputFeeBps,
        uint16 polShareBps,
        uint16 liquidityProviderShareBps,
        uint16 stakerShareBps,
        uint16 treasuryShareBps
    ) external {
        IStaticsSwapFeeHook(hook)
            .setFeeConfiguration(
                inputFeeBps, outputFeeBps, polShareBps, liquidityProviderShareBps, stakerShareBps, treasuryShareBps
            );
    }

    function setPoolFeeAllocation(PoolId poolId, IStaticsSwapFeeHook.FeeAllocation calldata allocation) external {
        IStaticsSwapFeeHook(hook).setPoolFeeAllocation(poolId, allocation);
    }

    function clearPoolFeeAllocation(PoolId poolId) external {
        IStaticsSwapFeeHook(hook).clearPoolFeeAllocation(poolId);
    }

    function release(PoolKey calldata key, address receiver) external returns (uint256 amount0, uint256 amount1) {
        return IStaticsSwapFeeHook(hook).releasePermanentLiquidity(key, receiver);
    }

    function decommission(PoolKey calldata key) external {
        IStaticsSwapFeeHook(hook).decommissionPool(key);
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
        assertEq(config.polShareBps, 5_000);
        assertEq(config.liquidityProviderShareBps, 1_000);
        assertEq(config.stakerShareBps, 3_000);
        assertEq(config.treasuryShareBps, 1_000);
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

    function testFinalRewardSlotIsConsumedBeforeSecondLegEligibilityCheck() public {
        receiver.setNovelAssetCapacity(1);
        _swapExactInput(true, 0.001 ether);

        address specified = Currency.unwrap(key.currency0);
        address unspecified = Currency.unwrap(key.currency1);
        assertGt(receiver.stakerFees(specified), 0);
        assertEq(receiver.stakerFees(unspecified), 0);
        assertGt(receiver.treasuryFees(specified), 0);
        assertGt(receiver.treasuryFees(unspecified), 0);
        assertTrue(receiver.knownAsset(specified));
        assertFalse(receiver.knownAsset(unspecified));
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
        hook.setFeeConfiguration(25, 25, 5_000, 1_000, 3_000, 1_000);

        vm.expectRevert(StaticsSwapFeeHook.InvalidFeeConfiguration.selector);
        receiver.setFeeConfiguration(101, 100, 5_000, 1_000, 3_000, 1_000);
        vm.expectRevert(StaticsSwapFeeHook.InvalidFeeConfiguration.selector);
        receiver.setFeeConfiguration(25, 25, 5_000, 1_000, 3_000, 999);
    }

    function testPoolAllocationIsDiamondOnlyRegisteredAndConserved() public {
        IStaticsSwapFeeHook.FeeAllocation memory allocation = IStaticsSwapFeeHook.FeeAllocation({
            polShareBps: 0, liquidityProviderShareBps: 0, stakerShareBps: 8_000, treasuryShareBps: 2_000
        });
        address outsider = makeAddr("allocation-outsider");
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(StaticsSwapFeeHook.OnlyStaticsDiamond.selector, outsider));
        hook.setPoolFeeAllocation(poolId, allocation);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(StaticsSwapFeeHook.OnlyStaticsDiamond.selector, outsider));
        hook.clearPoolFeeAllocation(poolId);

        PoolId unknown = PoolId.wrap(keccak256("unknown-pool"));
        vm.expectRevert(abi.encodeWithSelector(StaticsSwapFeeHook.PoolNotRegistered.selector, unknown));
        receiver.setPoolFeeAllocation(unknown, allocation);

        allocation.treasuryShareBps = 1_999;
        vm.expectRevert(StaticsSwapFeeHook.InvalidFeeConfiguration.selector);
        receiver.setPoolFeeAllocation(poolId, allocation);
    }

    function testPoolAllocationOverrideAndClearTrackLatestGlobalAllocation() public {
        IStaticsSwapFeeHook.PoolFeeAllocationView memory defaultAllocation = hook.poolFeeAllocation(poolId);
        assertEq(defaultAllocation.polShareBps, 5_000);
        assertEq(defaultAllocation.liquidityProviderShareBps, 1_000);
        assertEq(defaultAllocation.stakerShareBps, 3_000);
        assertEq(defaultAllocation.treasuryShareBps, 1_000);
        assertFalse(defaultAllocation.overridden);

        receiver.setPoolFeeAllocation(
            poolId,
            IStaticsSwapFeeHook.FeeAllocation({
                polShareBps: 1_000, liquidityProviderShareBps: 2_000, stakerShareBps: 3_000, treasuryShareBps: 4_000
            })
        );
        receiver.setFeeConfiguration(40, 60, 6_000, 1_000, 2_000, 1_000);
        IStaticsSwapFeeHook.PoolFeeAllocationView memory overridden = hook.poolFeeAllocation(poolId);
        assertEq(overridden.polShareBps, 1_000);
        assertEq(overridden.liquidityProviderShareBps, 2_000);
        assertEq(overridden.stakerShareBps, 3_000);
        assertEq(overridden.treasuryShareBps, 4_000);
        assertTrue(overridden.overridden);

        receiver.clearPoolFeeAllocation(poolId);
        IStaticsSwapFeeHook.PoolFeeAllocationView memory restored = hook.poolFeeAllocation(poolId);
        assertEq(restored.polShareBps, 6_000);
        assertEq(restored.liquidityProviderShareBps, 1_000);
        assertEq(restored.stakerShareBps, 2_000);
        assertEq(restored.treasuryShareBps, 1_000);
        assertFalse(restored.overridden);
    }

    function testZeroPolOverrideRoutesExactInputBothLegsInBothDirectionsWithoutNewPol() public {
        receiver.setPoolFeeAllocation(
            poolId,
            IStaticsSwapFeeHook.FeeAllocation({
                polShareBps: 0, liquidityProviderShareBps: 0, stakerShareBps: 8_000, treasuryShareBps: 2_000
            })
        );
        _assertOverriddenExactInput(true, 0.001 ether);
        _assertOverriddenExactInput(false, 0.001 ether);
        assertEq(hook.lockedLiquidity(poolId), 0);
        assertEq(hook.pendingPermanentLiquidity(poolId, key.currency0), 0);
        assertEq(hook.pendingPermanentLiquidity(poolId, key.currency1), 0);
    }

    function testZeroPolOverrideRoutesExactOutputBothLegsInBothDirectionsWithoutNewPol() public {
        receiver.setPoolFeeAllocation(
            poolId,
            IStaticsSwapFeeHook.FeeAllocation({
                polShareBps: 0, liquidityProviderShareBps: 0, stakerShareBps: 8_000, treasuryShareBps: 2_000
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

        receiver.setPoolFeeAllocation(
            poolId,
            IStaticsSwapFeeHook.FeeAllocation({
                polShareBps: 0, liquidityProviderShareBps: 0, stakerShareBps: 8_000, treasuryShareBps: 2_000
            })
        );

        assertEq(hook.lockedLiquidity(poolId), lockedBefore);
        assertEq(hook.pendingPermanentLiquidity(poolId, key.currency0), pending0Before);
        assertEq(hook.pendingPermanentLiquidity(poolId, key.currency1), pending1Before);
    }

    function testUnavailableStakerShareFromOverrideStillFallsThroughToPol() public {
        receiver.setPoolFeeAllocation(
            poolId,
            IStaticsSwapFeeHook.FeeAllocation({
                polShareBps: 0, liquidityProviderShareBps: 0, stakerShareBps: 8_000, treasuryShareBps: 2_000
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

    function testPoolOverrideCannotAffectSecondPoolOrGlobalFeeRates() public {
        HookCompatibilityERC20 secondToken = new HookCompatibilityERC20("Second Pool", "SECOND");
        PoolKey memory secondKey = _createCompatibilityPool(secondToken);
        PoolId secondPoolId = secondKey.toId();
        receiver.setPoolFeeAllocation(
            poolId,
            IStaticsSwapFeeHook.FeeAllocation({
                polShareBps: 0, liquidityProviderShareBps: 0, stakerShareBps: 8_000, treasuryShareBps: 2_000
            })
        );

        IStaticsSwapFeeHook.PoolFeeAllocationView memory firstAllocation = hook.poolFeeAllocation(poolId);
        IStaticsSwapFeeHook.PoolFeeAllocationView memory secondAllocation = hook.poolFeeAllocation(secondPoolId);
        IStaticsSwapFeeHook.FeeConfiguration memory config = hook.feeConfiguration();
        assertTrue(firstAllocation.overridden);
        assertFalse(secondAllocation.overridden);
        assertEq(secondAllocation.polShareBps, config.polShareBps);
        assertEq(secondAllocation.liquidityProviderShareBps, config.liquidityProviderShareBps);
        assertEq(config.inputFeeBps, INPUT_FEE_BPS);
        assertEq(config.outputFeeBps, OUTPUT_FEE_BPS);

        uint256 amountIn = 0.001 ether;
        BalanceDelta firstDelta = _swapExactInput(true, amountIn);
        BalanceDelta secondDelta = swap(secondKey, true, -int256(amountIn), "");
        uint256 firstNetOutput = uint256(uint128(firstDelta.amount1()));
        uint256 secondNetOutput = uint256(uint128(secondDelta.amount1()));
        uint256 firstInputFee = Math.mulDiv(amountIn, config.inputFeeBps, 10_000, Math.Rounding.Ceil);
        uint256 secondInputFee = Math.mulDiv(amountIn, config.inputFeeBps, 10_000, Math.Rounding.Ceil);
        uint256 firstOutputFee = _feeFromNet(firstNetOutput, config.outputFeeBps);
        uint256 secondOutputFee = _feeFromNet(secondNetOutput, config.outputFeeBps);
        assertEq(firstNetOutput, secondNetOutput);
        assertEq(firstInputFee, secondInputFee);
        assertEq(firstOutputFee, secondOutputFee);
        assertTrue(secondDelta.amount0() != 0 && secondDelta.amount1() != 0);
        assertEq(hook.lockedLiquidity(poolId), 0);
        assertGt(hook.lockedLiquidity(secondPoolId), 0);

        receiver.setFeeConfiguration(40, 60, 6_000, 1_000, 2_000, 1_000);
        firstAllocation = hook.poolFeeAllocation(poolId);
        secondAllocation = hook.poolFeeAllocation(secondPoolId);
        assertEq(firstAllocation.polShareBps, 0);
        assertEq(firstAllocation.stakerShareBps, 8_000);
        assertEq(firstAllocation.treasuryShareBps, 2_000);
        assertEq(secondAllocation.polShareBps, 6_000);
        assertEq(secondAllocation.liquidityProviderShareBps, 1_000);
        assertEq(secondAllocation.stakerShareBps, 2_000);
        assertEq(secondAllocation.treasuryShareBps, 1_000);
    }

    function testExistingPendingPolCompoundsAfterZeroPolOverride() public {
        _swapExactInput(true, 0.001 ether);
        uint128 lockedBeforeDonation = hook.lockedLiquidity(poolId);
        donateRouter.donate(key, 0.001 ether, 0.001 ether, "");
        _swapExactInput(false, 1_000);
        uint256 pending0 = hook.pendingPermanentLiquidity(poolId, key.currency0);
        uint256 pending1 = hook.pendingPermanentLiquidity(poolId, key.currency1);
        assertGt(pending0, 0);
        assertGt(pending1, 0);

        receiver.setPoolFeeAllocation(
            poolId,
            IStaticsSwapFeeHook.FeeAllocation({
                polShareBps: 0, liquidityProviderShareBps: 0, stakerShareBps: 8_000, treasuryShareBps: 2_000
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
        uint256 pol = Math.mulDiv(fee, 5_000, 10_000);
        uint256 liquidityProvider = Math.mulDiv(fee, 1_000, 10_000);
        uint256 staker = Math.mulDiv(fee, 3_000, 10_000);
        uint256 treasury = fee - pol - liquidityProvider - staker;
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
