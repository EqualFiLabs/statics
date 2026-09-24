// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IStaticsProtocolRevenue} from "../../src/interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {IStaticsPermanentLiquidityMath} from "../../src/interfaces/IStaticsPermanentLiquidityMath.sol";
import {StaticsPermanentLiquidityMath} from "../../src/liquidity/StaticsPermanentLiquidityMath.sol";
import {StaticsSwapFeeHook} from "../../src/liquidity/StaticsSwapFeeHook.sol";

contract HookCompatibilityERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }
}

/// @notice Diamond stand-in that records the routed `ProtocolFeeDistribution` per asset. General pools
/// carry no basket-staker share; the hook always carves a fixed 500-bps creator share.
contract HookDiamondMock {
    using SafeERC20 for IERC20;

    error RangeGaugeCallbackRejected(PoolId poolId);

    address public hook;
    bool public stakersEligible = true;
    bool public basketEligible;
    bool public rejectRangeGaugeCallback;
    uint256 public rangeGaugeCallbackCount;
    PoolId public lastRangeGaugeCallbackPoolId;
    mapping(address asset => bool eligible) public rewardAssetEligible;
    mapping(address asset => uint256 amount) public basketStakerFees;
    mapping(address asset => uint256 amount) public stakerFees;
    mapping(address asset => uint256 amount) public creatorFees;
    mapping(address asset => uint256 amount) public treasuryFees;
    mapping(PoolId poolId => bool quarantined) public swapQuarantined;

    function configureHook(address hook_) external {
        require(hook == address(0));
        hook = hook_;
    }

    function setStakersEligible(bool eligible) external {
        stakersEligible = eligible;
    }

    function setBasketEligible(bool eligible) external {
        basketEligible = eligible;
    }

    function setRewardAssetEligible(address asset, bool eligible) external {
        rewardAssetEligible[asset] = eligible;
    }

    function setRejectRangeGaugeCallback(bool rejected) external {
        rejectRangeGaugeCallback = rejected;
    }

    function afterProtocolPoolSwap(PoolId poolId) external {
        require(msg.sender == hook, "only hook");
        lastRangeGaugeCallbackPoolId = poolId;
        ++rangeGaugeCallbackCount;
        if (rejectRangeGaugeCallback) revert RangeGaugeCallbackRejected(poolId);
    }

    function canAccrueStakerRewards(address asset) external view returns (bool) {
        return stakersEligible && rewardAssetEligible[asset];
    }

    function canAccrueBasketRewards(PoolId) external view returns (bool) {
        return basketEligible;
    }

    function routeProtocolSwapFees(
        PoolId,
        address asset,
        IStaticsProtocolRevenue.ProtocolFeeDistribution calldata distribution
    ) external {
        require(msg.sender == hook, "only hook");
        uint256 total =
            distribution.basketStaker + distribution.staticsStaker + distribution.creator + distribution.treasury;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), total);
        _recordDistribution(asset, distribution);
    }

    function harvest(PoolKey calldata key)
        external
        returns (
            IStaticsSwapFeeHook.FeeDistribution memory distribution0,
            IStaticsSwapFeeHook.FeeDistribution memory distribution1
        )
    {
        (distribution0, distribution1) = IStaticsSwapFeeHook(hook).harvestPermanentLiquidityFees(key);
        _recordDistribution(Currency.unwrap(key.currency0), distribution0);
        _recordDistribution(Currency.unwrap(key.currency1), distribution1);
    }

    function decommissionAndRelease(PoolKey calldata key)
        external
        returns (IStaticsSwapFeeHook.PermanentLiquidityRelease memory released)
    {
        IStaticsSwapFeeHook(hook).decommissionPool(key);
        released = IStaticsSwapFeeHook(hook).releasePermanentLiquidity(key, address(this));
        _recordDistribution(Currency.unwrap(key.currency0), released.distribution0);
        _recordDistribution(Currency.unwrap(key.currency1), released.distribution1);
    }

    function _recordDistribution(address asset, IStaticsProtocolRevenue.ProtocolFeeDistribution calldata distribution)
        private
    {
        basketStakerFees[asset] += distribution.basketStaker;
        stakerFees[asset] += distribution.staticsStaker;
        creatorFees[asset] += distribution.creator;
        treasuryFees[asset] += distribution.treasury;
    }

    function _recordDistribution(address asset, IStaticsSwapFeeHook.FeeDistribution memory distribution) private {
        basketStakerFees[asset] += distribution.basketStaker;
        stakerFees[asset] += distribution.staticsStaker;
        creatorFees[asset] += distribution.creator;
        treasuryFees[asset] += distribution.treasury;
    }

    function registerPool(PoolKey calldata key, IStaticsSwapFeeHook.PoolKind kind, address creator)
        external
        returns (PoolId)
    {
        return IStaticsSwapFeeHook(hook).registerPool(key, kind, creator);
    }

    function setPoolFeeRate(PoolId poolId, uint16 inputFeeBps, uint16 outputFeeBps) external {
        IStaticsSwapFeeHook(hook).setPoolFeeRate(poolId, inputFeeBps, outputFeeBps);
    }

    function setDefaultFeeRate(uint16 inputFeeBps, uint16 outputFeeBps) external {
        IStaticsSwapFeeHook(hook).setDefaultFeeRate(inputFeeBps, outputFeeBps);
    }

    function setGeneralFeeAllocation(IStaticsSwapFeeHook.GeneralFeeAllocation calldata allocation) external {
        IStaticsSwapFeeHook(hook).setGeneralFeeAllocation(allocation);
    }

    function setBasketFeeAllocation(IStaticsSwapFeeHook.BasketFeeAllocation calldata allocation) external {
        IStaticsSwapFeeHook(hook).setBasketFeeAllocation(allocation);
    }

    function setSwapQuarantine(PoolId poolId, bool quarantined) external {
        swapQuarantined[poolId] = quarantined;
    }

    function protocolPoolSwapsBlocked(PoolId poolId) external view returns (bool blocked) {
        return swapQuarantined[PoolId.wrap(bytes32(0))] || swapQuarantined[poolId];
    }

    function seed(IStaticsSwapFeeHook.PermanentLiquiditySeed[] calldata seeds) external {
        uint256 length = seeds.length;
        for (uint256 i; i < length; ++i) {
            IStaticsSwapFeeHook.PermanentLiquiditySeed calldata seed_ = seeds[i];
            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(seed_.key.tickSpacing));
            uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(seed_.key.tickSpacing));
            uint256 amount0 = SqrtPriceMath.getAmount0Delta(1 << 96, sqrtUpper, seed_.liquidity, true);
            uint256 amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, 1 << 96, seed_.liquidity, true);
            IERC20(Currency.unwrap(seed_.key.currency0)).forceApprove(hook, amount0);
            IERC20(Currency.unwrap(seed_.key.currency1)).forceApprove(hook, amount1);
        }
        IStaticsSwapFeeHook(hook).seedPermanentLiquidity(seeds);
    }
}

contract StaticsSwapFeeHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint16 private constant INPUT_FEE_BPS = 25;
    uint16 private constant OUTPUT_FEE_BPS = 25;
    uint24 private constant LP_FEE = 3_000;
    int24 private constant TICK_SPACING = 10;
    uint256 private constant MAX_HOOK_RUNTIME_SIZE = 24_320;
    uint160 private constant REQUIRED_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        | Hooks.BEFORE_DONATE_FLAG;

    HookDiamondMock private diamond;
    StaticsSwapFeeHook private hook;
    PoolId private poolId;
    address private creator = makeAddr("creator");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        diamond = new HookDiamondMock();
        hook = _deployHook(address(diamond));
        diamond.configureHook(address(hook));
        // General allocation: pol 0, staker 9500, treasury 0 keeps fees observable in one bucket.
        diamond.setGeneralFeeAllocation(
            IStaticsSwapFeeHook.GeneralFeeAllocation({
                polShareBps: 0, staticsStakerShareBps: 9_500, treasuryShareBps: 0
            })
        );
        key = _registerInitialize(currency0, currency1, TICK_SPACING);
        poolId = key.toId();
        diamond.setRewardAssetEligible(Currency.unwrap(key.currency0), true);
        diamond.setRewardAssetEligible(Currency.unwrap(key.currency1), true);
    }

    function testMinedAddressEnablesBilateralFeePermissions() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, REQUIRED_FLAGS);
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.afterInitialize);
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.beforeDonate);
        assertEq(hook.staticsDiamond(), address(diamond));
        assertGt(address(hook.permanentLiquidityMath()).code.length, 0);
        assertLe(address(hook).code.length, MAX_HOOK_RUNTIME_SIZE);
        (uint16 inputFeeBps, uint16 outputFeeBps) = hook.defaultFeeRate();
        assertEq(inputFeeBps, INPUT_FEE_BPS);
        assertEq(outputFeeBps, OUTPUT_FEE_BPS);
    }

    function testCallbackFeesRemainFullyBackedByPoolManagerClaims() public {
        swap(key, true, -int256(0.001 ether), "");
        uint256 liability0 = hook.claimLiability(key.currency0);
        uint256 liability1 = hook.claimLiability(key.currency1);
        assertGt(liability0, 0);
        assertGt(liability1, 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(Currency.unwrap(key.currency0)))), liability0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(Currency.unwrap(key.currency1)))), liability1);
    }

    function testSwapInvokesRangeGaugeCallbackForRegisteredPool() public {
        assertEq(diamond.rangeGaugeCallbackCount(), 0);

        swap(key, true, -int256(0.001 ether), "");

        assertEq(diamond.rangeGaugeCallbackCount(), 1);
        assertEq(PoolId.unwrap(diamond.lastRangeGaugeCallbackPoolId()), PoolId.unwrap(poolId));
    }

    function testRangeGaugeCallbackFailureRevertsFeeAndPolState() public {
        uint256 claim0Before = hook.claimLiability(key.currency0);
        uint256 claim1Before = hook.claimLiability(key.currency1);
        uint256 liquidityBefore = hook.lockedLiquidity(poolId);
        diamond.setRejectRangeGaugeCallback(true);

        vm.expectRevert(
            _wrappedHookRevert(
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(HookDiamondMock.RangeGaugeCallbackRejected.selector, poolId)
            )
        );
        swap(key, true, -int256(0.001 ether), "");

        assertEq(hook.claimLiability(key.currency0), claim0Before);
        assertEq(hook.claimLiability(key.currency1), claim1Before);
        assertEq(hook.lockedLiquidity(poolId), liquidityBefore);
        assertEq(diamond.rangeGaugeCallbackCount(), 0);
        assertEq(PoolId.unwrap(diamond.lastRangeGaugeCallbackPoolId()), bytes32(0));
    }

    function testOnlyDiamondCanHarvestPermanentLiquidityFees() public {
        vm.expectRevert(abi.encodeWithSelector(StaticsSwapFeeHook.OnlyStaticsDiamond.selector, address(this)));
        hook.harvestPermanentLiquidityFees(key);
    }

    function testGlobalSwapPauseRejectsSwapsUntilDiamondRestoresThem() public {
        PoolId globalQuarantine = PoolId.wrap(bytes32(0));
        diamond.setSwapQuarantine(globalQuarantine, true);
        assertTrue(diamond.swapQuarantined(globalQuarantine));
        vm.expectRevert(
            _wrappedHookRevert(
                IHooks.beforeSwap.selector, abi.encodeWithSelector(StaticsSwapFeeHook.SwapsQuarantined.selector, poolId)
            )
        );
        swap(key, true, -int256(0.001 ether), "");

        diamond.setSwapQuarantine(globalQuarantine, false);
        assertFalse(diamond.swapQuarantined(globalQuarantine));
        swap(key, true, -int256(0.001 ether), "");
    }

    function testPoolQuarantineRejectsOnlySelectedPoolUntilReleased() public {
        PoolKey memory second = _registerInitialize(currency0, currency1, 20);
        diamond.setSwapQuarantine(poolId, true);
        assertTrue(diamond.swapQuarantined(poolId));
        vm.expectRevert(
            _wrappedHookRevert(
                IHooks.beforeSwap.selector, abi.encodeWithSelector(StaticsSwapFeeHook.SwapsQuarantined.selector, poolId)
            )
        );
        swap(key, true, -int256(0.001 ether), "");

        swap(second, true, -int256(0.001 ether), "");
        diamond.setSwapQuarantine(poolId, false);
        swap(key, true, -int256(0.001 ether), "");
    }

    function testRegistrationRejectsOneMillionPips() public {
        uint24 invalidFee = 1_000_000;
        PoolKey memory invalid = _poolKey(currency0, currency1, invalidFee, TICK_SPACING);
        vm.expectRevert(abi.encodeWithSelector(StaticsSwapFeeHook.InvalidNativeLpFee.selector, invalidFee));
        diamond.registerPool(invalid, IStaticsSwapFeeHook.PoolKind.General, address(this));
    }

    function testRegistrationAcceptsHeterogeneousStaticLpFees() public {
        PoolKey memory second = _poolKey(currency0, currency1, 500, TICK_SPACING);
        PoolId secondPoolId = diamond.registerPool(second, IStaticsSwapFeeHook.PoolKind.General, address(this));
        assertNotEq(PoolId.unwrap(secondPoolId), PoolId.unwrap(poolId));
        assertEq(hook.poolRegistration(secondPoolId).registered, true);
    }

    function testRejectsMissingPermanentLiquidityMath() public {
        IStaticsPermanentLiquidityMath missing = IStaticsPermanentLiquidityMath(address(0));
        bytes memory constructorArgs = abi.encode(manager, address(diamond), INPUT_FEE_BPS, OUTPUT_FEE_BPS, missing);
        (, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_FLAGS, type(StaticsSwapFeeHook).creationCode, constructorArgs);
        vm.expectRevert(abi.encodeWithSelector(StaticsSwapFeeHook.InvalidPermanentLiquidityMath.selector, address(0)));
        new StaticsSwapFeeHook{salt: salt}(manager, address(diamond), INPUT_FEE_BPS, OUTPUT_FEE_BPS, missing);
    }

    function testGeneralPoolCarvesFixedFiveHundredBpsCreatorShare() public {
        uint256 amountIn = 0.001 ether;
        BalanceDelta delta = swap(key, true, -int256(amountIn), "");
        uint256 netOutput = uint256(uint128(delta.amount1()));
        uint256 inputFee = Math.mulDiv(amountIn, INPUT_FEE_BPS, 10_000, Math.Rounding.Ceil);
        uint256 outputFee = _feeFromNet(netOutput, OUTPUT_FEE_BPS);
        address input = Currency.unwrap(key.currency0);
        address output = Currency.unwrap(key.currency1);
        _routePendingFees();
        assertEq(diamond.creatorFees(input), Math.mulDiv(inputFee, 500, 10_000));
        assertEq(diamond.creatorFees(output), Math.mulDiv(outputFee, 500, 10_000));
        // remaining 9500 configured -> staker bucket in this profile
        assertEq(diamond.stakerFees(input), Math.mulDiv(inputFee, 9_500, 10_000));
        assertEq(diamond.basketStakerFees(input), 0);
    }

    function testGeneralPoolNeverAccruesBasketStakerShare() public {
        diamond.setBasketEligible(true);
        swap(key, true, -int256(0.001 ether), "");
        assertEq(diamond.basketStakerFees(Currency.unwrap(key.currency0)), 0);
        assertEq(diamond.basketStakerFees(Currency.unwrap(key.currency1)), 0);
    }

    function testExactOutputPreservesRequestedOutputAndGrossesUpFees() public {
        uint256 amountOut = 0.0001 ether;
        BalanceDelta delta = swap(key, true, int256(amountOut), "");
        uint256 specifiedFee = _feeFromNet(amountOut, OUTPUT_FEE_BPS);
        assertEq(uint256(uint128(delta.amount1())), amountOut);
        address output = Currency.unwrap(key.currency1);
        _routePendingFees();
        assertEq(diamond.creatorFees(output) + diamond.stakerFees(output) + diamond.treasuryFees(output), specifiedFee);
    }

    function testNativeFeesEarnedByPermanentLiquidityRouteOnlyToTreasury() public {
        uint128 liquidity = 1 ether;
        IERC20(Currency.unwrap(key.currency0)).transfer(address(diamond), 10 ether);
        IERC20(Currency.unwrap(key.currency1)).transfer(address(diamond), 10 ether);
        IStaticsSwapFeeHook.PermanentLiquiditySeed[] memory seeds = new IStaticsSwapFeeHook.PermanentLiquiditySeed[](1);
        seeds[0] = IStaticsSwapFeeHook.PermanentLiquiditySeed({key: key, liquidity: liquidity});
        diamond.seed(seeds);

        address input = Currency.unwrap(key.currency0);
        uint256 treasuryBefore = diamond.treasuryFees(input);
        swap(key, true, -int256(0.001 ether), "");
        diamond.harvest(key);
        assertGt(diamond.treasuryFees(input), treasuryBefore);
        assertEq(hook.pendingPermanentLiquidity(poolId, key.currency0), 0);
    }

    function testUnavailableStakerShareFallsBackToTreasury() public {
        diamond.setStakersEligible(false);
        uint256 amountIn = 0.001 ether;
        swap(key, true, -int256(amountIn), "");
        uint256 inputFee = Math.mulDiv(amountIn, INPUT_FEE_BPS, 10_000, Math.Rounding.Ceil);
        address input = Currency.unwrap(key.currency0);
        _routePendingFees();
        assertEq(diamond.stakerFees(input), 0);
        // creator still 500, staker (9500) redirected to treasury
        assertEq(diamond.creatorFees(input), Math.mulDiv(inputFee, 500, 10_000));
        assertEq(diamond.treasuryFees(input), inputFee - Math.mulDiv(inputFee, 500, 10_000));
    }

    function testEligibilityDropBeforeNextSwapReallocatesPendingStakerShare() public {
        uint256 amountIn = 0.001 ether;
        swap(key, true, -int256(amountIn), "");
        diamond.setStakersEligible(false);

        swap(key, true, -int256(amountIn), "");

        uint256 inputFee = Math.mulDiv(amountIn, INPUT_FEE_BPS, 10_000, Math.Rounding.Ceil);
        uint256 creatorFee = Math.mulDiv(inputFee, 500, 10_000);
        address input = Currency.unwrap(key.currency0);
        assertEq(diamond.stakerFees(input), 0);
        assertEq(diamond.creatorFees(input), creatorFee);
        assertEq(diamond.treasuryFees(input), inputFee - creatorFee);
    }

    function testEligibilityDropBeforeHarvestReallocatesBasketShareToPol() public {
        PoolKey memory basketKey =
            _registerInitialize(currency0, currency1, 20, IStaticsSwapFeeHook.PoolKind.BasketCanonical);
        PoolId basketPoolId = basketKey.toId();
        diamond.setBasketFeeAllocation(
            IStaticsSwapFeeHook.BasketFeeAllocation({
                polShareBps: 0, basketStakerShareBps: 9_500, staticsStakerShareBps: 0, treasuryShareBps: 0
            })
        );
        diamond.setBasketEligible(true);
        uint256 amountIn = 0.001 ether;
        swap(basketKey, true, -int256(amountIn), "");
        diamond.setBasketEligible(false);

        diamond.harvest(basketKey);

        uint256 inputFee = Math.mulDiv(amountIn, INPUT_FEE_BPS, 10_000, Math.Rounding.Ceil);
        uint256 basketShare = Math.mulDiv(inputFee, 9_500, 10_000);
        address input = Currency.unwrap(basketKey.currency0);
        assertEq(diamond.basketStakerFees(input), 0);
        assertEq(hook.pendingPermanentLiquidity(basketPoolId, basketKey.currency0), basketShare);
    }

    function testEligibilityDropBeforeDecommissionRedeemsBasketFallbackAsPol() public {
        PoolKey memory basketKey =
            _registerInitialize(currency0, currency1, 20, IStaticsSwapFeeHook.PoolKind.BasketCanonical);
        diamond.setBasketFeeAllocation(
            IStaticsSwapFeeHook.BasketFeeAllocation({
                polShareBps: 0, basketStakerShareBps: 9_500, staticsStakerShareBps: 0, treasuryShareBps: 0
            })
        );
        diamond.setBasketEligible(true);
        uint256 amountIn = 0.001 ether;
        swap(basketKey, true, -int256(amountIn), "");
        diamond.setBasketEligible(false);

        IStaticsSwapFeeHook.PermanentLiquidityRelease memory released = diamond.decommissionAndRelease(basketKey);

        uint256 inputFee = Math.mulDiv(amountIn, INPUT_FEE_BPS, 10_000, Math.Rounding.Ceil);
        uint256 basketShare = Math.mulDiv(inputFee, 9_500, 10_000);
        assertEq(released.distribution0.basketStaker, 0);
        assertEq(released.pendingPol0, basketShare);
        assertTrue(hook.poolDecommissioned(basketKey.toId()));
    }

    function testPoolRateOverrideAppliesDistinctRate() public {
        diamond.setPoolFeeRate(poolId, 100, 0);
        IStaticsSwapFeeHook.PoolFeeRate memory rate = hook.poolFeeRate(poolId);
        assertTrue(rate.overridden);
        assertEq(rate.inputFeeBps, 100);
        uint256 amountIn = 0.001 ether;
        uint256 before = diamond.creatorFees(Currency.unwrap(key.currency0))
            + diamond.stakerFees(Currency.unwrap(key.currency0)) + diamond.treasuryFees(Currency.unwrap(key.currency0));
        swap(key, true, -int256(amountIn), "");
        _routePendingFees();
        uint256 collected = diamond.creatorFees(Currency.unwrap(key.currency0))
            + diamond.stakerFees(Currency.unwrap(key.currency0)) + diamond.treasuryFees(Currency.unwrap(key.currency0))
            - before;
        assertEq(collected, Math.mulDiv(amountIn, 100, 10_000, Math.Rounding.Ceil));
    }

    function testFeeRateAdministrationIsDiamondOnlyAndCapped() public {
        address outsider = makeAddr("outsider");
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(StaticsSwapFeeHook.OnlyStaticsDiamond.selector, outsider));
        hook.setDefaultFeeRate(25, 25);

        vm.expectRevert(StaticsSwapFeeHook.InvalidFeeRate.selector);
        diamond.setDefaultFeeRate(101, 100);
    }

    function testAllocationAdministrationRejectsNon9500ConfigurableShares() public {
        vm.expectRevert(StaticsSwapFeeHook.InvalidAllocation.selector);
        diamond.setGeneralFeeAllocation(
            IStaticsSwapFeeHook.GeneralFeeAllocation({
                polShareBps: 0, staticsStakerShareBps: 9_000, treasuryShareBps: 0
            })
        );
        vm.expectRevert(StaticsSwapFeeHook.InvalidAllocation.selector);
        diamond.setBasketFeeAllocation(
            IStaticsSwapFeeHook.BasketFeeAllocation({
                polShareBps: 1_000, basketStakerShareBps: 3_000, staticsStakerShareBps: 3_000, treasuryShareBps: 1_999
            })
        );
    }

    function testRegistrationAcceptsCreatorLpFeeAndRejectsNativeCurrencyAndInvalidKind() public {
        PoolKey memory creatorFee = _poolKey(currency0, currency1, 1, 20);
        PoolId creatorFeePoolId = diamond.registerPool(creatorFee, IStaticsSwapFeeHook.PoolKind.General, creator);
        assertTrue(hook.poolRegistration(creatorFeePoolId).registered);

        PoolKey memory nativePool = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: currency1,
            fee: LP_FEE,
            tickSpacing: 20,
            hooks: IHooks(hook)
        });
        vm.expectRevert(StaticsSwapFeeHook.NativeCurrencyUnsupported.selector);
        diamond.registerPool(nativePool, IStaticsSwapFeeHook.PoolKind.General, creator);

        PoolKey memory ok = _poolKey(currency0, currency1, LP_FEE, 20);
        vm.expectRevert(StaticsSwapFeeHook.InvalidPoolKind.selector);
        diamond.registerPool(ok, IStaticsSwapFeeHook.PoolKind.None, creator);

        vm.expectRevert(abi.encodeWithSelector(StaticsSwapFeeHook.InvalidCreator.selector, address(0)));
        diamond.registerPool(ok, IStaticsSwapFeeHook.PoolKind.General, address(0));
        assertFalse(hook.poolRegistration(ok.toId()).registered);
    }

    function testRegistrationRecordsKindAndCreator() public view {
        IStaticsSwapFeeHook.PoolRegistration memory registration = hook.poolRegistration(poolId);
        assertTrue(registration.registered);
        assertEq(uint8(registration.kind), uint8(IStaticsSwapFeeHook.PoolKind.General));
        assertEq(registration.creator, creator);
    }

    function testNativePoolDonationsAreForbidden() public {
        vm.expectRevert(
            _wrappedHookRevert(
                IHooks.beforeDonate.selector,
                abi.encodeWithSelector(StaticsSwapFeeHook.CanonicalPoolDonationForbidden.selector)
            )
        );
        donateRouter.donate(key, 1 ether, 0, "");
    }

    function _registerInitialize(Currency first, Currency second, int24 tickSpacing)
        private
        returns (PoolKey memory poolKey)
    {
        return _registerInitialize(first, second, tickSpacing, IStaticsSwapFeeHook.PoolKind.General);
    }

    function _registerInitialize(Currency first, Currency second, int24 tickSpacing, IStaticsSwapFeeHook.PoolKind kind)
        private
        returns (PoolKey memory poolKey)
    {
        poolKey = _poolKey(first, second, LP_FEE, tickSpacing);
        diamond.registerPool(poolKey, kind, creator);
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, "");
    }

    function _routePendingFees() private {
        swap(key, true, -int256(0.001 ether), "");
    }

    function _poolKey(Currency first, Currency second, uint24 fee, int24 tickSpacing)
        private
        view
        returns (PoolKey memory poolKey)
    {
        (Currency lower, Currency upper) = first < second ? (first, second) : (second, first);
        return PoolKey({currency0: lower, currency1: upper, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(hook)});
    }

    function _deployHook(address diamond_) private returns (StaticsSwapFeeHook deployed) {
        StaticsPermanentLiquidityMath permanentLiquidityMath = new StaticsPermanentLiquidityMath();
        bytes memory constructorArgs =
            abi.encode(manager, diamond_, INPUT_FEE_BPS, OUTPUT_FEE_BPS, permanentLiquidityMath);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_FLAGS, type(StaticsSwapFeeHook).creationCode, constructorArgs);
        deployed = new StaticsSwapFeeHook{salt: salt}(
            manager, diamond_, INPUT_FEE_BPS, OUTPUT_FEE_BPS, permanentLiquidityMath
        );
        assertEq(address(deployed), expected);
    }

    function _wrappedHookRevert(bytes4 selector, bytes memory reason) private view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            selector,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _feeFromNet(uint256 netAmount, uint256 feeBps) private pure returns (uint256) {
        return Math.mulDiv(netAmount, feeBps, 10_000 - feeBps, Math.Rounding.Ceil);
    }
}
