// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsProtocolRevenue} from "../../src/interfaces/IStaticsProtocolRevenue.sol";
import {StaticsFlashArbitrageReceiver} from "../../src/periphery/StaticsFlashArbitrageReceiver.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";
import {FlashArbitrageReceiver, ICanonicalV4SwapRouter} from "../mocks/FlashArbitrageReceiver.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract FlashArbitrageTest is CanonicalPoolTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct MultiAssetFixture {
        uint256 basketId;
        address basketToken;
        uint256 stakePositionId;
        PoolKey[] pools;
    }

    function testFlashMintAndCanonicalSalesProduceFeeAwareConstituentProfit() public {
        MultiAssetFixture memory fixture = _createMultiAssetFixture();
        FlashArbitrageReceiver receiver = _newReceiver();
        (, uint256[] memory flashAmounts, uint256[] memory flashFees) =
            flashLoans.quoteFlashLoan(fixture.basketId, 1 ether);
        uint256[] memory mintMaximums = baskets.quoteMint(fixture.basketId, 1 ether);
        assetA.mint(address(receiver), mintMaximums[0] - flashAmounts[0] + flashFees[0]);
        assetB.mint(address(receiver), mintMaximums[1] - flashAmounts[1] + flashFees[1]);
        uint256 startingA = assetA.balanceOf(address(receiver));
        uint256 startingB = assetB.balanceOf(address(receiver));
        assertLt(startingA, flashAmounts[0]);
        assertLt(startingB, flashAmounts[1]);
        uint256[] memory basketAmountsIn = new uint256[](2);
        basketAmountsIn[0] = 0.5 ether;
        basketAmountsIn[1] = 0.5 ether;
        uint256[] memory minimumProfits = new uint256[](2);
        minimumProfits[0] = 0.05 ether;
        minimumProfits[1] = 0.05 ether;

        receiver.executeMintAndSell(fixture.basketId, 1 ether, fixture.pools, basketAmountsIn, minimumProfits);

        assertGe(receiver.lastProfit(address(assetA)), minimumProfits[0]);
        assertGe(receiver.lastProfit(address(assetB)), minimumProfits[1]);
        assertEq(assetA.balanceOf(address(receiver)), startingA + receiver.lastProfit(address(assetA)));
        assertEq(assetB.balanceOf(address(receiver)), startingB + receiver.lastProfit(address(assetB)));
        assertGt(swapFeeHook.lockedLiquidity(fixture.pools[0].toId()), 0);
        assertGt(swapFeeHook.lockedLiquidity(fixture.pools[1].toId()), 0);
        assertGt(globalRewards.treasuryAccrued(fixture.basketToken), 0);

        address[] memory rewardAssets = new address[](3);
        rewardAssets[0] = address(assetA);
        rewardAssets[1] = address(assetB);
        rewardAssets[2] = fixture.basketToken;
        vm.prank(alice);
        uint256[] memory pending = globalRewards.pendingRewards(fixture.stakePositionId, rewardAssets);
        assertGt(pending[0], 0);
        assertGt(pending[1], 0);
        assertGt(pending[2], 0);
    }

    function testProductionReceiverReturnsNetConstituentProfitToExecutor() public {
        MultiAssetFixture memory fixture = _createMultiAssetFixture();
        StaticsFlashArbitrageReceiver receiver = new StaticsFlashArbitrageReceiver(address(diamond));
        (, uint256[] memory flashAmounts,) = flashLoans.quoteFlashLoan(fixture.basketId, 1 ether);
        uint256[] memory mintMaximums = baskets.quoteMint(fixture.basketId, 1 ether);
        uint256 topUpA = mintMaximums[0] - flashAmounts[0];
        uint256 topUpB = mintMaximums[1] - flashAmounts[1];
        uint256 aliceABefore = assetA.balanceOf(alice);
        uint256 aliceBBefore = assetB.balanceOf(alice);
        uint256[] memory basketAmountsIn = new uint256[](2);
        basketAmountsIn[0] = 0.5 ether;
        basketAmountsIn[1] = 0.5 ether;
        uint256[] memory minimumProfits = new uint256[](2);
        minimumProfits[0] = 0.05 ether;
        minimumProfits[1] = 0.05 ether;

        vm.startPrank(alice);
        assetA.approve(address(receiver), topUpA);
        assetB.approve(address(receiver), topUpB);
        (, uint256[] memory profits) = receiver.executeMintAndSell(
            fixture.basketId, 1 ether, fixture.pools, basketAmountsIn, minimumProfits, block.timestamp
        );
        vm.stopPrank();

        assertGe(profits[0], minimumProfits[0]);
        assertGe(profits[1], minimumProfits[1]);
        assertEq(assetA.balanceOf(alice), aliceABefore + profits[0]);
        assertEq(assetB.balanceOf(alice), aliceBBefore + profits[1]);
        assertEq(assetA.balanceOf(address(receiver)), 0);
        assertEq(assetB.balanceOf(address(receiver)), 0);
        assertEq(IERC20(fixture.basketToken).balanceOf(address(receiver)), 0);
        assertEq(assetA.allowance(address(receiver), address(diamond)), 0);
        assertEq(assetB.allowance(address(receiver), address(diamond)), 0);
        assertGt(swapFeeHook.lockedLiquidity(fixture.pools[0].toId()), 0);
        assertGt(swapFeeHook.lockedLiquidity(fixture.pools[1].toId()), 0);
    }

    function testProductionReceiverRejectsExpiredQuoteBeforePullingTopUps() public {
        MultiAssetFixture memory fixture = _createMultiAssetFixture();
        StaticsFlashArbitrageReceiver receiver = new StaticsFlashArbitrageReceiver(address(diamond));
        uint256[] memory basketAmountsIn = new uint256[](2);
        basketAmountsIn[0] = 0.5 ether;
        basketAmountsIn[1] = 0.5 ether;
        uint256[] memory minimumProfits = new uint256[](2);
        uint256 aliceABefore = assetA.balanceOf(alice);

        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        vm.expectPartialRevert(StaticsFlashArbitrageReceiver.DeadlineExpired.selector);
        receiver.executeMintAndSell(
            fixture.basketId, 1 ether, fixture.pools, basketAmountsIn, minimumProfits, block.timestamp - 1
        );

        assertEq(assetA.balanceOf(alice), aliceABefore);
        assertEq(assetA.balanceOf(address(receiver)), 0);
    }

    function testProductionReceiverInvalidPoolRollsBackTopUpsAndFlashState() public {
        MultiAssetFixture memory fixture = _createMultiAssetFixture();
        StaticsFlashArbitrageReceiver receiver = new StaticsFlashArbitrageReceiver(address(diamond));
        (, uint256[] memory flashAmounts,) = flashLoans.quoteFlashLoan(fixture.basketId, 1 ether);
        uint256[] memory mintMaximums = baskets.quoteMint(fixture.basketId, 1 ether);
        uint256[] memory basketAmountsIn = new uint256[](2);
        basketAmountsIn[0] = 0.5 ether;
        basketAmountsIn[1] = 0.5 ether;
        uint256[] memory minimumProfits = new uint256[](2);
        fixture.pools[1].fee += 1;
        uint256 aliceABefore = assetA.balanceOf(alice);
        uint256 vaultBefore = baskets.vaultBalance(fixture.basketId, address(assetA));
        (uint160 priceBefore, int24 tickBefore,,) = poolManager.getSlot0(fixture.pools[0].toId());

        vm.startPrank(alice);
        assetA.approve(address(receiver), mintMaximums[0] - flashAmounts[0]);
        assetB.approve(address(receiver), mintMaximums[1] - flashAmounts[1]);
        vm.expectPartialRevert(StaticsFlashArbitrageReceiver.InvalidPool.selector);
        receiver.executeMintAndSell(
            fixture.basketId, 1 ether, fixture.pools, basketAmountsIn, minimumProfits, block.timestamp
        );
        vm.stopPrank();

        assertEq(assetA.balanceOf(alice), aliceABefore);
        assertEq(assetA.balanceOf(address(receiver)), 0);
        assertEq(baskets.vaultBalance(fixture.basketId, address(assetA)), vaultBefore);
        (uint160 priceAfter, int24 tickAfter,,) = poolManager.getSlot0(fixture.pools[0].toId());
        assertEq(priceAfter, priceBefore);
        assertEq(tickAfter, tickBefore);
    }

    function testProductionReceiverUnprofitableRouteRollsBackTopUpsAndFlashState() public {
        MultiAssetFixture memory fixture = _createMultiAssetFixture();
        StaticsFlashArbitrageReceiver receiver = new StaticsFlashArbitrageReceiver(address(diamond));
        (, uint256[] memory flashAmounts,) = flashLoans.quoteFlashLoan(fixture.basketId, 1 ether);
        uint256[] memory mintMaximums = baskets.quoteMint(fixture.basketId, 1 ether);
        uint256[] memory basketAmountsIn = new uint256[](2);
        basketAmountsIn[0] = 0.5 ether;
        basketAmountsIn[1] = 0.5 ether;
        uint256[] memory impossibleProfits = new uint256[](2);
        impossibleProfits[0] = 1 ether;
        impossibleProfits[1] = 1 ether;
        uint256 aliceABefore = assetA.balanceOf(alice);
        uint256 vaultBefore = baskets.vaultBalance(fixture.basketId, address(assetA));
        (uint160 priceBefore, int24 tickBefore,,) = poolManager.getSlot0(fixture.pools[0].toId());

        vm.startPrank(alice);
        assetA.approve(address(receiver), mintMaximums[0] - flashAmounts[0]);
        assetB.approve(address(receiver), mintMaximums[1] - flashAmounts[1]);
        vm.expectPartialRevert(StaticsFlashArbitrageReceiver.MinimumProfitNotMet.selector);
        receiver.executeMintAndSell(
            fixture.basketId, 1 ether, fixture.pools, basketAmountsIn, impossibleProfits, block.timestamp
        );
        vm.stopPrank();

        assertEq(assetA.balanceOf(alice), aliceABefore);
        assertEq(assetA.balanceOf(address(receiver)), 0);
        assertEq(baskets.vaultBalance(fixture.basketId, address(assetA)), vaultBefore);
        (uint160 priceAfter, int24 tickAfter,,) = poolManager.getSlot0(fixture.pools[0].toId());
        assertEq(priceAfter, priceBefore);
        assertEq(tickAfter, tickBefore);
    }

    function testFlashBuyAndRedeemProducesFeeAwareUnderlyingProfit() public {
        (uint256 basketId, address basketToken, PoolKey memory pool, uint256 stakePositionId) =
            _createSingleAssetFixture();
        FlashArbitrageReceiver receiver = _newReceiver();
        (, uint256[] memory amounts,) = flashLoans.quoteFlashLoan(basketId, 1 ether);

        receiver.executeBuyAndRedeem(basketId, 1 ether, pool, amounts[0], 0.2 ether);

        assertGe(receiver.lastProfit(address(assetA)), 0.2 ether);
        assertEq(assetA.balanceOf(address(receiver)), receiver.lastProfit(address(assetA)));
        assertGt(swapFeeHook.lockedLiquidity(pool.toId()), 0);
        assertGt(globalRewards.treasuryAccrued(basketToken), 0);
        address[] memory rewardAssets = new address[](2);
        rewardAssets[0] = address(assetA);
        rewardAssets[1] = basketToken;
        vm.prank(alice);
        uint256[] memory pending = globalRewards.pendingRewards(stakePositionId, rewardAssets);
        assertGt(pending[0], 0);
        assertGt(pending[1], 0);
    }

    function testCanonicalSwapRoutesOnlySelectedLegToGlobalStakers() public {
        address[] memory assets = new address[](1);
        assets[0] = address(assetA);
        uint256[] memory bundleAmounts = new uint256[](1);
        bundleAmounts[0] = 1 ether;
        (uint256 basketId, address basketToken) = _createBasket(assets, bundleAmounts);
        uint256 stakePositionId = _createStake(_asset(address(assetA)));
        _mintInitialSupply(basketId, basketToken, assets, 100 ether);
        PoolKey memory pool = _initializeAndSeed(basketId, basketToken, address(assetA));
        basketLiquidity.setSwapFeeConfiguration(
            IStaticsBasketLiquidity.SwapFeeConfiguration({
                inputFeeBps: 25,
                outputFeeBps: 25,
                polShareBps: 0,
                liquidityProviderShareBps: 0,
                basketStakerShareBps: 0,
                staticsStakerShareBps: 9_000,
                treasuryShareBps: 500
            })
        );

        uint256 basketFeeReserveBefore = custody.reservedByAccount(custody.feeCustodyAccount(), basketToken);
        uint256 basketTreasuryBefore = globalRewards.treasuryAccrued(basketToken);
        bool assetIsCurrency0 = pool.currency0 == Currency.wrap(address(assetA));
        vm.prank(alice);
        v4Router.swap(
            pool,
            SwapParams({
                zeroForOne: assetIsCurrency0,
                amountSpecified: -int256(0.1 ether),
                sqrtPriceLimitX96: assetIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        address[] memory rewardAssets = _assets(address(assetA), basketToken);
        vm.prank(alice);
        uint256[] memory pending = globalRewards.pendingRewards(stakePositionId, rewardAssets);
        assertGt(pending[0], 0);
        assertEq(pending[1], 0);
        assertGt(globalRewards.rewardAsset(address(assetA)).indexedReserve, 0);
        assertEq(globalRewards.rewardAsset(basketToken).indexedReserve, 0);

        uint256 basketTreasuryDelta = globalRewards.treasuryAccrued(basketToken) - basketTreasuryBefore;
        assertGt(basketTreasuryDelta, 0);
        // The non-POL reservation now also covers the fixed 500-bps creator credit, so the fee-account
        // reserve delta equals treasury accrual plus the creator credit for this leg.
        uint256 basketCreatorCredit = IStaticsProtocolRevenue(address(diamond)).creatorRevenue(alice, basketToken);
        assertEq(
            custody.reservedByAccount(custody.feeCustodyAccount(), basketToken) - basketFeeReserveBefore,
            basketTreasuryDelta + basketCreatorCredit
        );
        assertEq(swapFeeHook.pendingPermanentLiquidity(pool.toId(), Currency.wrap(basketToken)), 0);
        assertEq(swapFeeHook.pendingPermanentLiquidity(pool.toId(), Currency.wrap(address(assetA))), 0);
    }

    struct UnprofitableBookSnapshot {
        bytes32 account;
        address basketToken;
        uint256 vault;
        uint256 accountReserved;
        uint256 globalReserved;
        uint256 treasury;
        uint256 managerAsset;
        uint256 managerBasket;
        uint256 receiverAsset;
        uint128 lockedLiquidity;
        uint160 price;
        int24 tick;
    }

    function testUnprofitableRouteRevertsWithoutChangingAnyProtocolOrPoolBook() public {
        MultiAssetFixture memory fixture = _createMultiAssetFixture();
        FlashArbitrageReceiver receiver = _newReceiver();
        (, uint256[] memory flashAmounts, uint256[] memory flashFees) =
            flashLoans.quoteFlashLoan(fixture.basketId, 1 ether);
        uint256[] memory mintMaximums = baskets.quoteMint(fixture.basketId, 1 ether);
        assetA.mint(address(receiver), mintMaximums[0] - flashAmounts[0] + flashFees[0]);
        assetB.mint(address(receiver), mintMaximums[1] - flashAmounts[1] + flashFees[1]);

        UnprofitableBookSnapshot memory before = _snapshotUnprofitableBook(fixture, receiver);
        vm.expectPartialRevert(FlashArbitrageReceiver.MinimumProfitNotMet.selector);
        receiver.executeMintAndSell(
            fixture.basketId, 1 ether, fixture.pools, _halfAndHalf(1 ether), _impossibleProfits()
        );
        UnprofitableBookSnapshot memory after_ = _snapshotUnprofitableBook(fixture, receiver);

        assertEq(after_.vault, before.vault);
        assertEq(after_.accountReserved, before.accountReserved);
        assertEq(after_.globalReserved, before.globalReserved);
        assertEq(after_.treasury, before.treasury);
        assertEq(after_.managerAsset, before.managerAsset);
        assertEq(after_.managerBasket, before.managerBasket);
        assertEq(after_.receiverAsset, before.receiverAsset);
        assertEq(after_.lockedLiquidity, before.lockedLiquidity);
        assertEq(uint256(after_.price), uint256(before.price));
        assertEq(int256(after_.tick), int256(before.tick));
    }

    function _snapshotUnprofitableBook(MultiAssetFixture memory fixture, FlashArbitrageReceiver receiver)
        private
        view
        returns (UnprofitableBookSnapshot memory snapshot)
    {
        PoolId poolId = fixture.pools[0].toId();
        snapshot.account = custody.basketCustodyAccount(fixture.basketId);
        snapshot.basketToken = fixture.basketToken;
        snapshot.vault = baskets.vaultBalance(fixture.basketId, address(assetA));
        snapshot.accountReserved = custody.reservedByAccount(snapshot.account, address(assetA));
        snapshot.globalReserved = custody.globalReservedByToken(address(assetA));
        snapshot.treasury = globalRewards.treasuryAccrued(address(assetA));
        snapshot.managerAsset = assetA.balanceOf(address(poolManager));
        snapshot.managerBasket = IERC20(fixture.basketToken).balanceOf(address(poolManager));
        snapshot.receiverAsset = assetA.balanceOf(address(receiver));
        snapshot.lockedLiquidity = swapFeeHook.lockedLiquidity(poolId);
        (snapshot.price, snapshot.tick,,) = poolManager.getSlot0(poolId);
    }

    function _halfAndHalf(uint256 amount) private pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amount / 2;
        amounts[1] = amount - amounts[0];
    }

    function _impossibleProfits() private pure returns (uint256[] memory profits) {
        profits = new uint256[](2);
        profits[0] = 1 ether;
        profits[1] = 1 ether;
    }

    function testReceiverRejectsNoncanonicalPoolKeyForConfiguredPair() public {
        (uint256 basketId, address basketToken, PoolKey memory pool,) = _createSingleAssetFixture();
        FlashArbitrageReceiver receiver = _newReceiver();
        (, uint256[] memory amounts,) = flashLoans.quoteFlashLoan(basketId, 1 ether);
        pool.fee += 1;
        uint256 vaultBefore = baskets.vaultBalance(basketId, address(assetA));

        vm.expectPartialRevert(FlashArbitrageReceiver.InvalidPool.selector);
        receiver.executeBuyAndRedeem(basketId, 1 ether, pool, amounts[0], 0);

        assertEq(baskets.vaultBalance(basketId, address(assetA)), vaultBefore);
        assertEq(assetA.balanceOf(address(receiver)), 0);
        assertEq(IERC20(basketToken).balanceOf(address(receiver)), 0);
    }

    function testFuzzUnderpricedArbitrageAcrossQuantitiesFeesAndDivergence(
        uint256 rawShares,
        uint256 rawBundleAmount,
        uint256 rawFeeShares,
        uint256 rawFlashFeeBps,
        uint256 rawInputFeeBps,
        uint256 rawOutputFeeBps
    ) public {
        uint256 shares = bound(rawShares, 0.5 ether, 1 ether);
        uint256 bundleAmount = bound(rawBundleAmount, 1.4 ether, 2 ether);
        uint256 feeShares = bound(rawFeeShares, 0, 0.02 ether);
        uint16 flashFeeBps = uint16(bound(rawFlashFeeBps, 0, 100));
        _setHookFees(rawInputFeeBps, rawOutputFeeBps);
        address[] memory assets = new address[](1);
        assets[0] = address(assetA);
        uint256[] memory bundleAmounts = new uint256[](1);
        bundleAmounts[0] = bundleAmount;
        (uint256 basketId, address basketToken) =
            _createBasketWithFees(assets, bundleAmounts, feeShares, feeShares, flashFeeBps);
        _mintInitialSupply(basketId, basketToken, assets, 100 ether);
        PoolKey memory pool = _initializeAndSeed(basketId, basketToken, assets[0]);
        FlashArbitrageReceiver receiver = _newReceiver();
        (, uint256[] memory amounts,) = flashLoans.quoteFlashLoan(basketId, shares);

        receiver.executeBuyAndRedeem(basketId, shares, pool, amounts[0], 1);

        assertGt(receiver.lastProfit(address(assetA)), 0);
    }

    function testFuzzOverpricedArbitrageAcrossQuantitiesFeesAndDivergence(
        uint256 rawShares,
        uint256 rawBundleAmount,
        uint256 rawFeeShares,
        uint256 rawFlashFeeBps,
        uint256 rawInputFeeBps,
        uint256 rawOutputFeeBps
    ) public {
        uint256 shares = bound(rawShares, 0.5 ether, 1 ether);
        uint256 bundleAmount = bound(rawBundleAmount, 0.2 ether, 0.4 ether);
        uint256 feeShares = bound(rawFeeShares, 0, 0.02 ether);
        uint16 flashFeeBps = uint16(bound(rawFlashFeeBps, 0, 100));
        _setHookFees(rawInputFeeBps, rawOutputFeeBps);

        OverpricedArbitrage memory plan = _prepareOverpricedArbitrage(shares, bundleAmount, feeShares, flashFeeBps);
        vm.startPrank(alice);
        _approveOverpricedTopUps(plan);
        (, uint256[] memory profits) = plan.receiver
            .executeMintAndSell(
                plan.basketId, shares, plan.pools, _splitBasketAmountsIn(shares), _unitMinimumProfits(), block.timestamp
            );
        vm.stopPrank();

        assertGt(profits[0], 0);
        assertGt(profits[1], 0);
        assertEq(assetA.balanceOf(address(plan.receiver)), 0);
        assertEq(assetB.balanceOf(address(plan.receiver)), 0);
    }

    struct OverpricedArbitrage {
        uint256 basketId;
        PoolKey[] pools;
        uint256[] flashAmounts;
        uint256[] mintMaximums;
        StaticsFlashArbitrageReceiver receiver;
    }

    function _prepareOverpricedArbitrage(uint256 shares, uint256 bundleAmount, uint256 feeShares, uint16 flashFeeBps)
        private
        returns (OverpricedArbitrage memory plan)
    {
        address[] memory assets = new address[](2);
        assets[0] = address(assetA);
        assets[1] = address(assetB);
        uint256[] memory bundleAmounts = new uint256[](2);
        bundleAmounts[0] = bundleAmount;
        bundleAmounts[1] = bundleAmount;
        address basketToken;
        (plan.basketId, basketToken) = _createBasketWithFees(assets, bundleAmounts, feeShares, feeShares, flashFeeBps);
        _mintInitialSupply(plan.basketId, basketToken, assets, 100 ether);
        plan.pools = new PoolKey[](2);
        plan.pools[0] = _initializeAndSeed(plan.basketId, basketToken, assets[0]);
        plan.pools[1] = _initializeAndSeed(plan.basketId, basketToken, assets[1]);
        plan.receiver = new StaticsFlashArbitrageReceiver(address(diamond));
        (, plan.flashAmounts,) = flashLoans.quoteFlashLoan(plan.basketId, shares);
        plan.mintMaximums = baskets.quoteMint(plan.basketId, shares);
    }

    function _splitBasketAmountsIn(uint256 shares) private pure returns (uint256[] memory basketAmountsIn) {
        basketAmountsIn = new uint256[](2);
        basketAmountsIn[0] = shares / 2;
        basketAmountsIn[1] = shares - basketAmountsIn[0];
    }

    function _unitMinimumProfits() private pure returns (uint256[] memory minimumProfits) {
        minimumProfits = new uint256[](2);
        minimumProfits[0] = 1;
        minimumProfits[1] = 1;
    }

    function _approveOverpricedTopUps(OverpricedArbitrage memory plan) private {
        assetA.approve(address(plan.receiver), plan.mintMaximums[0] - plan.flashAmounts[0]);
        assetB.approve(address(plan.receiver), plan.mintMaximums[1] - plan.flashAmounts[1]);
    }

    function _createMultiAssetFixture() private returns (MultiAssetFixture memory fixture) {
        address[] memory assets = new address[](2);
        assets[0] = address(assetA);
        assets[1] = address(assetB);
        uint256[] memory bundleAmounts = new uint256[](2);
        bundleAmounts[0] = 0.4 ether;
        bundleAmounts[1] = 0.4 ether;
        (fixture.basketId, fixture.basketToken) = _createBasket(assets, bundleAmounts);
        address[] memory rewardAssets = new address[](3);
        rewardAssets[0] = assets[0];
        rewardAssets[1] = assets[1];
        rewardAssets[2] = fixture.basketToken;
        fixture.stakePositionId = _createStake(rewardAssets);
        _mintInitialSupply(fixture.basketId, fixture.basketToken, assets, 100 ether);
        fixture.pools = new PoolKey[](2);
        fixture.pools[0] = _initializeAndSeed(fixture.basketId, fixture.basketToken, assets[0]);
        fixture.pools[1] = _initializeAndSeed(fixture.basketId, fixture.basketToken, assets[1]);
    }

    function _createSingleAssetFixture()
        private
        returns (uint256 basketId, address basketToken, PoolKey memory pool, uint256 stakePositionId)
    {
        address[] memory assets = new address[](1);
        assets[0] = address(assetA);
        uint256[] memory bundleAmounts = new uint256[](1);
        bundleAmounts[0] = 1.5 ether;
        (basketId, basketToken) = _createBasket(assets, bundleAmounts);
        address[] memory rewardAssets = new address[](2);
        rewardAssets[0] = assets[0];
        rewardAssets[1] = basketToken;
        stakePositionId = _createStake(rewardAssets);
        _mintInitialSupply(basketId, basketToken, assets, 100 ether);
        pool = _initializeAndSeed(basketId, basketToken, assets[0]);
    }

    function _createBasket(address[] memory assets, uint256[] memory bundleAmounts)
        private
        returns (uint256 basketId, address basketToken)
    {
        return _createBasketWithFees(assets, bundleAmounts, 0.01 ether, 0.01 ether, 5);
    }

    function _createBasketWithFees(
        address[] memory assets,
        uint256[] memory bundleAmounts,
        uint256 mintFeeShares,
        uint256 redemptionFeeShares,
        uint16 flashFeeBps
    ) private returns (uint256 basketId, address basketToken) {
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: "Flash Arbitrage Basket",
            symbol: "sARB",
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeTiers: _singleFeeTier(mintFeeShares),
            redemptionFeeTiers: _singleFeeTier(redemptionFeeShares),
            flashFeeBps: flashFeeBps,
            originationFeeBps: 100,
            extensionFeeBps: 25,
            ltvBps: 9_500,
            recoveryPenaltyBps: 500,
            loanDuration: 30 days
        });
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) = _fundDefaultLaunch(assets, alice);
        uint256 creationFeeAmount = basketAdmin.creationFee();
        vm.prank(alice);
        return baskets.createBasket{value: creationFeeAmount}(params, pools, maximums, type(uint256).max);
    }

    function _createStake(address[] memory rewardAssets) private returns (uint256 positionId) {
        stakingAsset.mint(alice, 100 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 100 ether);
        positionId = globalRewards.createAndStake(100 ether, alice, rewardAssets);
        vm.warp(globalRewards.rewardSelection(positionId, rewardAssets[0]).eligibleAt);
        vm.stopPrank();
    }

    function _asset(address asset) private pure returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = asset;
    }

    function _assets(address first, address second) private pure returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = first;
        assets[1] = second;
    }

    function _mintInitialSupply(uint256 basketId, address basketToken, address[] memory assets, uint256 shares)
        private
    {
        uint256[] memory maximums = baskets.quoteMint(basketId, shares);
        uint256 length = assets.length;
        for (uint256 i; i < length; ++i) {
            MockERC20(assets[i]).mint(alice, maximums[i] + 100 ether);
            vm.startPrank(alice);
            IERC20(assets[i]).approve(address(diamond), type(uint256).max);
            IERC20(assets[i]).approve(address(v4Router), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(alice);
        baskets.mint(basketId, shares, alice, maximums);
        vm.prank(alice);
        IERC20(basketToken).approve(address(v4Router), type(uint256).max);
    }

    function _initializeAndSeed(uint256 basketId, address basketToken, address asset)
        private
        returns (PoolKey memory key)
    {
        IStaticsBasketLiquidity.CanonicalPoolView memory configured = basketLiquidity.canonicalPool(basketId, asset);
        key = PoolKey({
            currency0: Currency.wrap(configured.currency0),
            currency1: Currency.wrap(configured.currency1),
            fee: configured.lpFee,
            tickSpacing: configured.tickSpacing,
            hooks: IHooks(configured.hook)
        });
        assertTrue(configured.currency0 == basketToken || configured.currency1 == basketToken);
        vm.prank(alice);
        v4Router.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(configured.tickSpacing),
                tickUpper: TickMath.maxUsableTick(configured.tickSpacing),
                liquidityDelta: 40 ether,
                salt: bytes32(0)
            })
        );
    }

    function _newReceiver() private returns (FlashArbitrageReceiver receiver) {
        receiver = new FlashArbitrageReceiver(address(diamond), ICanonicalV4SwapRouter(address(v4Router)));
    }

    function _setHookFees(uint256 rawInputFeeBps, uint256 rawOutputFeeBps) private {
        basketLiquidity.setSwapFeeConfiguration(
            IStaticsBasketLiquidity.SwapFeeConfiguration({
                inputFeeBps: uint16(bound(rawInputFeeBps, 0, 100)),
                outputFeeBps: uint16(bound(rawOutputFeeBps, 0, 100)),
                polShareBps: 5_000,
                liquidityProviderShareBps: 1_000,
                basketStakerShareBps: 0,
                staticsStakerShareBps: 3_000,
                treasuryShareBps: 500
            })
        );
    }
}
