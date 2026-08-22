// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {BasketLiquidityFacet} from "../../src/facets/BasketLiquidityFacet.sol";
import {LibBasket} from "../../src/libraries/LibBasket.sol";
import {LibBasketLiquidityMath} from "../../src/libraries/LibBasketLiquidityMath.sol";
import {MockERC20, MockSenderExtraFeeERC20} from "../mocks/MockERC20.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

contract AtomicBasketLaunchTest is CanonicalPoolTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function testSixteenConstituentLaunchSeedsEveryPoolAndCustodyBook() public {
        (IStaticsBasket.CreateBasketParams memory params, MockERC20[] memory assets) = _basketParameters(16);
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, alice);
        uint256 creationFeeAmount = basketAdmin.creationFee();

        vm.prank(alice);
        (uint256 basketId, address basketToken) =
            baskets.createBasket{value: creationFeeAmount}(params, pools, maximums, type(uint256).max);

        assertGt(IERC20(basketToken).totalSupply(), 0);
        assertEq(IERC20(basketToken).balanceOf(address(diamond)), 0);
        assertEq(IERC20(basketToken).balanceOf(address(poolManager)), IERC20(basketToken).totalSupply());
        for (uint256 i; i < assets.length; ++i) {
            IStaticsBasketLiquidity.CanonicalPoolView memory canonical =
                basketLiquidity.canonicalPool(basketId, address(assets[i]));
            assertGt(swapFeeHook.lockedLiquidity(canonical.poolId), 0);
            assertGt(poolManager.getLiquidity(canonical.poolId), 0);
            assertGt(assets[i].balanceOf(address(poolManager)), 0);
            assertEq(
                custody.reservedByAccount(custody.basketCustodyAccount(basketId), address(assets[i])),
                baskets.vaultBalance(basketId, address(assets[i]))
            );
            assertEq(custody.globalReservedByToken(address(assets[i])), assets[i].balanceOf(address(diamond)));
        }
    }

    function testCanonicalPoolExecutesSwapInLaunchTransactionState() public {
        (uint256 basketId, address basketToken) = _createDefaultBasket(0, 0);
        IStaticsBasketLiquidity.CanonicalPoolView memory canonical =
            basketLiquidity.canonicalPool(basketId, address(assetA));

        uint256[] memory quote = baskets.quoteMint(basketId, 1 ether);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.prank(alice);
        baskets.mint(basketId, 1 ether, alice, quote);
        _approveV4Router(alice, basketToken);
        _approveV4Router(alice, address(assetA));

        PoolKey memory key = _poolKey(canonical);
        bool basketIsCurrency0 = canonical.currency0 == basketToken;
        uint256 assetBefore = assetA.balanceOf(alice);
        vm.prank(alice);
        BalanceDelta delta = v4Router.swap(
            key,
            SwapParams({
                zeroForOne: basketIsCurrency0,
                amountSpecified: -int256(0.01 ether),
                sqrtPriceLimitX96: basketIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        assertGt(assetA.balanceOf(alice), assetBefore);
        assertTrue(delta.amount0() != 0);
        assertTrue(delta.amount1() != 0);
        assertGt(swapFeeHook.lockedLiquidity(canonical.poolId), 0);
    }

    function testFuzzLaunchUsesSemanticAssetPerBasketPrice(uint256 rawTick, uint256 rawPairedAmount) public {
        int24 semanticTick = int24(int256(bound(rawTick, 1, 10_001)) - 5_001);
        uint160 semanticPrice = TickMath.getSqrtPriceAtTick(semanticTick);
        uint256 pairedAmount = bound(rawPairedAmount, 1e12, 100 ether);
        (IStaticsBasket.CreateBasketParams memory params, MockERC20[] memory assets) = _basketParameters(1);
        IStaticsBasket.PoolLaunchParams[] memory pools = new IStaticsBasket.PoolLaunchParams[](1);
        pools[0] = IStaticsBasket.PoolLaunchParams({
            sqrtPriceAssetPerBasketX96: semanticPrice, pairedAssetAmount: pairedAmount
        });
        uint256[] memory maximums = new uint256[](1);
        maximums[0] = 1_000_000 ether;
        assets[0].mint(alice, maximums[0]);
        vm.prank(alice);
        assets[0].approve(address(diamond), maximums[0]);

        uint256 balanceBefore = assets[0].balanceOf(alice);
        uint256 creationFeeAmount = basketAdmin.creationFee();
        vm.prank(alice);
        (uint256 basketId, address basketToken) =
            baskets.createBasket{value: creationFeeAmount}(params, pools, maximums, type(uint256).max);

        IStaticsBasketLiquidity.CanonicalPoolView memory canonical =
            basketLiquidity.canonicalPool(basketId, address(assets[0]));
        uint160 expectedPrice =
            basketToken < address(assets[0]) ? semanticPrice : uint160(Math.mulDiv(1 << 96, 1 << 96, semanticPrice));
        (uint160 actualPrice,,,) = poolManager.getSlot0(canonical.poolId);
        assertEq(actualPrice, expectedPrice);
        assertGt(balanceBefore - assets[0].balanceOf(alice), pairedAmount);
        assertLe(balanceBefore - assets[0].balanceOf(alice), maximums[0]);
        assertEq(custody.globalReservedByToken(address(assets[0])), assets[0].balanceOf(address(diamond)));
        assertEq(IERC20(basketToken).balanceOf(address(diamond)), 0);
    }

    function testFundingFailureRollsBackTokenPoolsFeeAndCustody() public {
        (IStaticsBasket.CreateBasketParams memory params, MockERC20[] memory assets) = _basketParameters(3);
        IStaticsBasket.PoolLaunchParams[] memory pools = _defaultPoolLaunchParams(3);
        uint256[] memory maximums = _defaultLaunchMaximums(3);
        for (uint256 i; i < assets.length; ++i) {
            assets[i].mint(alice, maximums[i]);
        }
        vm.startPrank(alice);
        assets[0].approve(address(diamond), maximums[0]);
        assets[1].approve(address(diamond), maximums[1]);
        vm.stopPrank();

        uint256 diamondNonce = vm.getNonce(address(diamond));
        address predictedBasketToken = vm.computeCreateAddress(address(diamond), diamondNonce);
        uint256 treasuryBefore = treasury.balance;
        uint256 creationFeeAmount = basketAdmin.creationFee();
        vm.prank(alice);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        baskets.createBasket{value: creationFeeAmount}(params, pools, maximums, type(uint256).max);

        assertEq(baskets.basketCount(), 0);
        assertEq(treasury.balance, treasuryBefore);
        assertEq(predictedBasketToken.code.length, 0);
        assertEq(vm.getNonce(address(diamond)), diamondNonce);
        for (uint256 i; i < assets.length; ++i) {
            PoolKey memory key = _derivedKey(predictedBasketToken, address(assets[i]));
            PoolId poolId = key.toId();
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
            IStaticsSwapFeeHook.PoolRegistration memory registration = swapFeeHook.poolRegistration(poolId);
            assertEq(sqrtPriceX96, 0);
            assertFalse(registration.registered);
            assertEq(assets[i].balanceOf(alice), maximums[i]);
            assertEq(assets[i].balanceOf(address(diamond)), 0);
            assertEq(custody.globalReservedByToken(address(assets[i])), 0);
        }
    }

    struct LaunchExpectation {
        uint256 basketAmount;
        uint256 pairedAssetAmount;
        uint256 maximum;
        uint256 debit;
    }

    function testSenderExtraChargeCannotExceedCompleteLaunchMaximum() public {
        MockSenderExtraFeeERC20 taxed = new MockSenderExtraFeeERC20();
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: "Sender Extra Launch",
            symbol: "sEXTRA",
            assets: _singleAddressArray(address(taxed)),
            bundleAmounts: _singleUintArray(0.01 ether),
            mintFeeTiers: new IStaticsBasket.FeeTier[](0),
            redemptionFeeTiers: new IStaticsBasket.FeeTier[](0),
            flashFeeBps: 5,
            originationFeeBps: 100,
            extensionFeeBps: 25,
            ltvBps: 9_500,
            recoveryPenaltyBps: 500,
            loanDuration: 30 days
        });
        IStaticsBasket.PoolLaunchParams[] memory pools = _singlePoolLaunch(1 ether);
        LaunchExpectation memory expected = _expectedLaunchDebit(address(taxed), params.bundleAmounts[0]);

        taxed.mint(alice, expected.debit);
        taxed.setTaxedSender(alice);
        uint256 creationFeeAmount = basketAdmin.creationFee();
        vm.startPrank(alice);
        taxed.approve(address(diamond), expected.maximum);
        vm.expectRevert(
            abi.encodeWithSelector(
                BasketLiquidityFacet.LaunchDebitExceedsMaximum.selector,
                address(taxed),
                expected.debit,
                expected.maximum
            )
        );
        baskets.createBasket{value: creationFeeAmount}(
            params, pools, _singleUintArray(expected.maximum), type(uint256).max
        );
        vm.stopPrank();

        assertEq(baskets.basketCount(), 0);
        assertEq(taxed.balanceOf(alice), expected.debit);
        assertEq(taxed.balanceOf(address(diamond)), 0);
    }

    function _singleAddressArray(address item) private pure returns (address[] memory items) {
        items = new address[](1);
        items[0] = item;
    }

    function _singleUintArray(uint256 item) private pure returns (uint256[] memory items) {
        items = new uint256[](1);
        items[0] = item;
    }

    function _singlePoolLaunch(uint256 pairedAssetAmount)
        private
        pure
        returns (IStaticsBasket.PoolLaunchParams[] memory pools)
    {
        pools = new IStaticsBasket.PoolLaunchParams[](1);
        pools[0] = IStaticsBasket.PoolLaunchParams({
            sqrtPriceAssetPerBasketX96: DEFAULT_LAUNCH_SQRT_PRICE, pairedAssetAmount: pairedAssetAmount
        });
    }

    function _expectedLaunchDebit(address taxed, uint256 bundleAmount)
        private
        view
        returns (LaunchExpectation memory expected)
    {
        address predictedBasketToken = vm.computeCreateAddress(address(diamond), vm.getNonce(address(diamond)));
        bool assetIsCurrency0 = taxed < predictedBasketToken;
        (, expected.basketAmount, expected.pairedAssetAmount) =
            LibBasketLiquidityMath.fullRangeAmounts(DEFAULT_LAUNCH_SQRT_PRICE, assetIsCurrency0, 1 ether);
        uint256 backingAmount = LibBasket.backingIncrease(bundleAmount, 0, expected.basketAmount);
        expected.maximum = expected.pairedAssetAmount + backingAmount;
        expected.debit = expected.maximum + expected.pairedAssetAmount / 100 + backingAmount / 100;
    }

    function testLaunchRejectsPricesOutsideFullRangeTickBounds() public {
        (IStaticsBasket.CreateBasketParams memory params, MockERC20[] memory assets) = _basketParameters(1);
        IStaticsBasket.PoolLaunchParams[] memory pools = new IStaticsBasket.PoolLaunchParams[](1);
        pools[0].pairedAssetAmount = 1 ether;
        uint256[] memory maximums = new uint256[](1);
        maximums[0] = 1_000_000 ether;
        assets[0].mint(alice, maximums[0]);
        vm.prank(alice);
        assets[0].approve(address(diamond), maximums[0]);

        address predictedBasketToken = vm.computeCreateAddress(address(diamond), vm.getNonce(address(diamond)));
        uint160 lower = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(10));
        uint160 upper = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(10));
        uint160[2] memory invalidCanonicalPrices = [lower - 1, upper + 1];
        uint256 creationFeeAmount = basketAdmin.creationFee();
        for (uint256 i; i < invalidCanonicalPrices.length; ++i) {
            uint160 semanticPrice = predictedBasketToken < address(assets[0])
                ? invalidCanonicalPrices[i]
                : uint160(Math.mulDiv(1 << 96, 1 << 96, invalidCanonicalPrices[i]));
            pools[0].sqrtPriceAssetPerBasketX96 = semanticPrice;
            vm.prank(alice);
            vm.expectRevert(
                abi.encodeWithSelector(
                    BasketLiquidityFacet.InvalidPoolLaunchPrice.selector, address(assets[0]), semanticPrice
                )
            );
            baskets.createBasket{value: creationFeeAmount}(params, pools, maximums, type(uint256).max);
        }

        assertEq(baskets.basketCount(), 0);
    }

    function _basketParameters(uint256 count)
        private
        returns (IStaticsBasket.CreateBasketParams memory params, MockERC20[] memory deployedAssets)
    {
        address[] memory assets = new address[](count);
        uint256[] memory bundleAmounts = new uint256[](count);
        deployedAssets = new MockERC20[](count);
        for (uint256 i; i < count; ++i) {
            deployedAssets[i] = new MockERC20("Launch Constituent", "LC", 18);
            assets[i] = address(deployedAssets[i]);
            bundleAmounts[i] = (i + 1) * 0.01 ether;
        }
        params = IStaticsBasket.CreateBasketParams({
            name: "Atomic Launch Basket",
            symbol: "sLAUNCH",
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeTiers: new IStaticsBasket.FeeTier[](0),
            redemptionFeeTiers: new IStaticsBasket.FeeTier[](0),
            flashFeeBps: 5,
            originationFeeBps: 100,
            extensionFeeBps: 25,
            ltvBps: 9_500,
            recoveryPenaltyBps: 500,
            loanDuration: 30 days
        });
    }

    function _poolKey(IStaticsBasketLiquidity.CanonicalPoolView memory canonical)
        private
        pure
        returns (PoolKey memory key)
    {
        key = PoolKey({
            currency0: Currency.wrap(canonical.currency0),
            currency1: Currency.wrap(canonical.currency1),
            fee: canonical.lpFee,
            tickSpacing: canonical.tickSpacing,
            hooks: IHooks(canonical.hook)
        });
    }

    function _derivedKey(address basketToken, address asset) private view returns (PoolKey memory key) {
        (Currency currency0, Currency currency1) = basketToken < asset
            ? (Currency.wrap(basketToken), Currency.wrap(asset))
            : (Currency.wrap(asset), Currency.wrap(basketToken));
        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 10, hooks: IHooks(address(swapFeeHook))
        });
    }
}
