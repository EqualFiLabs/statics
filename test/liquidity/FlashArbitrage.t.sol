// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
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
                treasuryShareBps: 1_000
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
        assertEq(
            custody.reservedByAccount(custody.feeCustodyAccount(), basketToken) - basketFeeReserveBefore,
            basketTreasuryDelta
        );
        assertGt(swapFeeHook.pendingPermanentLiquidity(pool.toId(), Currency.wrap(basketToken)), 0);
        assertEq(swapFeeHook.pendingPermanentLiquidity(pool.toId(), Currency.wrap(address(assetA))), 0);
    }

    function testUnprofitableRouteRevertsWithoutChangingAnyProtocolOrPoolBook() public {
        MultiAssetFixture memory fixture = _createMultiAssetFixture();
        FlashArbitrageReceiver receiver = _newReceiver();
        (, uint256[] memory flashAmounts, uint256[] memory flashFees) =
            flashLoans.quoteFlashLoan(fixture.basketId, 1 ether);
        uint256[] memory mintMaximums = baskets.quoteMint(fixture.basketId, 1 ether);
        assetA.mint(address(receiver), mintMaximums[0] - flashAmounts[0] + flashFees[0]);
        assetB.mint(address(receiver), mintMaximums[1] - flashAmounts[1] + flashFees[1]);
        uint256[] memory basketAmountsIn = new uint256[](2);
        basketAmountsIn[0] = 0.5 ether;
        basketAmountsIn[1] = 0.5 ether;
        uint256[] memory impossibleProfits = new uint256[](2);
        impossibleProfits[0] = 1 ether;
        impossibleProfits[1] = 1 ether;

        bytes32 account = custody.basketCustodyAccount(fixture.basketId);
        uint256 vaultBefore = baskets.vaultBalance(fixture.basketId, address(assetA));
        uint256 accountBefore = custody.reservedByAccount(account, address(assetA));
        uint256 globalBefore = custody.globalReservedByToken(address(assetA));
        uint256 treasuryBefore = globalRewards.treasuryAccrued(address(assetA));
        uint256 managerAssetBefore = assetA.balanceOf(address(poolManager));
        uint256 managerBasketBefore = IERC20(fixture.basketToken).balanceOf(address(poolManager));
        uint256 receiverAssetBefore = assetA.balanceOf(address(receiver));
        uint128 lockedBefore = swapFeeHook.lockedLiquidity(fixture.pools[0].toId());
        (uint160 priceBefore, int24 tickBefore,,) = poolManager.getSlot0(fixture.pools[0].toId());

        vm.expectPartialRevert(FlashArbitrageReceiver.MinimumProfitNotMet.selector);
        receiver.executeMintAndSell(fixture.basketId, 1 ether, fixture.pools, basketAmountsIn, impossibleProfits);

        assertEq(baskets.vaultBalance(fixture.basketId, address(assetA)), vaultBefore);
        assertEq(custody.reservedByAccount(account, address(assetA)), accountBefore);
        assertEq(custody.globalReservedByToken(address(assetA)), globalBefore);
        assertEq(globalRewards.treasuryAccrued(address(assetA)), treasuryBefore);
        assertEq(assetA.balanceOf(address(poolManager)), managerAssetBefore);
        assertEq(IERC20(fixture.basketToken).balanceOf(address(poolManager)), managerBasketBefore);
        assertEq(assetA.balanceOf(address(receiver)), receiverAssetBefore);
        assertEq(swapFeeHook.lockedLiquidity(fixture.pools[0].toId()), lockedBefore);
        (uint160 priceAfter, int24 tickAfter,,) = poolManager.getSlot0(fixture.pools[0].toId());
        assertEq(priceAfter, priceBefore);
        assertEq(tickAfter, tickBefore);
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
        address[] memory assets = new address[](2);
        assets[0] = address(assetA);
        assets[1] = address(assetB);
        uint256[] memory bundleAmounts = new uint256[](2);
        bundleAmounts[0] = bundleAmount;
        bundleAmounts[1] = bundleAmount;
        (uint256 basketId, address basketToken) =
            _createBasketWithFees(assets, bundleAmounts, feeShares, feeShares, flashFeeBps);
        _mintInitialSupply(basketId, basketToken, assets, 100 ether);
        PoolKey[] memory pools = new PoolKey[](2);
        pools[0] = _initializeAndSeed(basketId, basketToken, assets[0]);
        pools[1] = _initializeAndSeed(basketId, basketToken, assets[1]);
        FlashArbitrageReceiver receiver = _newReceiver();
        (, uint256[] memory flashAmounts, uint256[] memory flashFees) = flashLoans.quoteFlashLoan(basketId, shares);
        uint256[] memory mintMaximums = baskets.quoteMint(basketId, shares);
        assetA.mint(address(receiver), mintMaximums[0] - flashAmounts[0] + flashFees[0]);
        assetB.mint(address(receiver), mintMaximums[1] - flashAmounts[1] + flashFees[1]);
        uint256[] memory basketAmountsIn = new uint256[](2);
        basketAmountsIn[0] = shares / 2;
        basketAmountsIn[1] = shares - basketAmountsIn[0];
        uint256[] memory minimumProfits = new uint256[](2);
        minimumProfits[0] = 1;
        minimumProfits[1] = 1;

        receiver.executeMintAndSell(basketId, shares, pools, basketAmountsIn, minimumProfits);

        assertGt(receiver.lastProfit(address(assetA)), 0);
        assertGt(receiver.lastProfit(address(assetB)), 0);
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
        vm.prank(alice);
        return baskets.createBasket{value: basketAdmin.creationFee()}(params);
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
        basketLiquidity.initializeCanonicalPool(basketId, asset, SQRT_PRICE_1_1);
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
                treasuryShareBps: 1_000
            })
        );
    }
}
