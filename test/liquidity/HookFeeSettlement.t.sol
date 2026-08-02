// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketAdmin} from "../../src/interfaces/IStaticsBasketAdmin.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {LibBasket} from "../../src/libraries/LibBasket.sol";
import {MockERC20, MockOutboundFeeERC20, MockReentrantERC20, MockSenderExtraFeeERC20} from "../mocks/MockERC20.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

contract HookFeeSettlementTest is CanonicalPoolTestBase {
    function testUnderlyingFeesBecomeIsolatedTerminalRevenueAndTreasuryCanClaim() public {
        (uint256 basketId, address basketToken, PoolKey memory key) = _prepareDefaultPool();
        _swapFrom(key, basketToken, 2 ether);
        (, uint256 pendingUnderlying) = basketLiquidity.pendingCanonicalHookFees(basketId, address(assetA));
        assertGt(pendingUnderlying, 0);

        uint256 vaultBefore = baskets.vaultBalance(basketId, address(assetA));
        uint256 reserveBefore = basketLiquidity.liquidityReserve(basketId, address(assetA));
        IStaticsBasketLiquidity.PrimaryFeeTotals memory primaryBefore =
            basketLiquidity.cumulativePrimaryFees(basketId, address(assetA));
        bytes32 account = custody.basketCustodyAccount(basketId);
        uint256 custodyBefore = custody.reservedByAccount(account, address(assetA));

        IStaticsBasketLiquidity.HookSettlementTotals memory settled =
            basketLiquidity.settleCanonicalHookFees(basketId, address(assetA));
        assertEq(settled.constituentHookDebit, pendingUnderlying);
        assertEq(settled.constituentRevenue, pendingUnderlying);
        assertEq(settled.basketTokenHookDebit, 0);
        assertEq(basketAdmin.protocolRevenue(basketId, address(assetA)), pendingUnderlying);
        assertEq(basketLiquidity.cumulativeHookRevenue(basketId, address(assetA)), pendingUnderlying);
        assertEq(custody.reservedByAccount(account, address(assetA)) - custodyBefore, pendingUnderlying);
        assertEq(baskets.vaultBalance(basketId, address(assetA)), vaultBefore);
        assertEq(basketLiquidity.liquidityReserve(basketId, address(assetA)), reserveBefore);
        _assertPrimaryTotalsEqual(primaryBefore, basketLiquidity.cumulativePrimaryFees(basketId, address(assetA)));

        vm.prank(alice);
        vm.expectPartialRevert(bytes4(keccak256("OnlyTreasury(address)")));
        basketAdmin.claimProtocolRevenue(basketId, address(assetA), pendingUnderlying, bob);
        uint256 bobBefore = assetA.balanceOf(bob);
        vm.prank(treasury);
        basketAdmin.claimProtocolRevenue(basketId, address(assetA), pendingUnderlying, bob);
        assertEq(assetA.balanceOf(bob) - bobBefore, pendingUnderlying);
    }

    function testBasketTokenFeesBurnIntoProportionalUnderlyingRevenue() public {
        (uint256 basketId, address basketToken, PoolKey memory key) = _prepareDefaultPool();
        _swapFrom(key, address(assetA), 2 ether);
        (uint256 pendingBasketTokens,) = basketLiquidity.pendingCanonicalHookFees(basketId, address(assetA));
        assertGt(pendingBasketTokens, 0);

        uint256 supplyBefore = IERC20(basketToken).totalSupply();
        uint256 vaultABefore = baskets.vaultBalance(basketId, address(assetA));
        uint256 vaultBBefore = baskets.vaultBalance(basketId, address(assetB));
        uint256 expectedA = LibBasket.backingReduction(2 ether, supplyBefore, pendingBasketTokens);
        uint256 expectedB = LibBasket.backingReduction(5 ether, supplyBefore, pendingBasketTokens);
        bytes32 account = custody.basketCustodyAccount(basketId);
        uint256 reservedABefore = custody.reservedByAccount(account, address(assetA));
        uint256 reservedBBefore = custody.reservedByAccount(account, address(assetB));

        IStaticsBasketLiquidity.HookSettlementTotals memory settled =
            basketLiquidity.settleCanonicalHookFees(basketId, address(assetA));
        assertEq(settled.basketTokenHookDebit, pendingBasketTokens);
        assertEq(settled.basketTokensBurned, pendingBasketTokens);
        assertEq(IERC20(basketToken).totalSupply(), supplyBefore - pendingBasketTokens);
        assertEq(vaultABefore - baskets.vaultBalance(basketId, address(assetA)), expectedA);
        assertEq(vaultBBefore - baskets.vaultBalance(basketId, address(assetB)), expectedB);
        assertEq(basketAdmin.protocolRevenue(basketId, address(assetA)), expectedA);
        assertEq(basketAdmin.protocolRevenue(basketId, address(assetB)), expectedB);
        assertEq(basketLiquidity.cumulativeHookRevenue(basketId, address(assetA)), expectedA);
        assertEq(basketLiquidity.cumulativeHookRevenue(basketId, address(assetB)), expectedB);
        assertEq(custody.reservedByAccount(account, address(assetA)), reservedABefore);
        assertEq(custody.reservedByAccount(account, address(assetB)), reservedBBefore);
    }

    function testFeeOnTransferSettlementCreditsOnlyDiamondReceipt() public {
        MockOutboundFeeERC20 taxed = new MockOutboundFeeERC20();
        (uint256 basketId, address basketToken, PoolKey memory key) =
            _prepareSingleAssetPool(taxed, "Tax Basket", "sTAX");
        _swapFrom(key, basketToken, 2 ether);
        (, uint256 pendingUnderlying) = basketLiquidity.pendingCanonicalHookFees(basketId, address(taxed));
        taxed.setTaxedSender(address(swapFeeHook));

        IStaticsBasketLiquidity.HookSettlementTotals memory settled =
            basketLiquidity.settleCanonicalHookFees(basketId, address(taxed));
        assertEq(settled.constituentHookDebit, pendingUnderlying);
        assertEq(settled.constituentRevenue, pendingUnderlying - pendingUnderlying / 100);
        assertEq(basketAdmin.protocolRevenue(basketId, address(taxed)), settled.constituentRevenue);
    }

    function testSenderExtraDebitCannotConsumeSiblingPoolLiability() public {
        MockSenderExtraFeeERC20 taxed = new MockSenderExtraFeeERC20();
        (uint256 firstBasket, address firstToken, PoolKey memory firstKey) =
            _prepareSingleAssetPool(taxed, "First", "sONE");
        (uint256 secondBasket, address secondToken, PoolKey memory secondKey) =
            _prepareSingleAssetPool(taxed, "Second", "sTWO");
        _swapFrom(firstKey, firstToken, 2 ether);
        _swapFrom(secondKey, secondToken, 2 ether);
        (, uint256 firstLiability) = basketLiquidity.pendingCanonicalHookFees(firstBasket, address(taxed));
        (, uint256 secondLiability) = basketLiquidity.pendingCanonicalHookFees(secondBasket, address(taxed));
        uint256 hookBalanceBefore = taxed.balanceOf(address(swapFeeHook));
        taxed.setTaxedSender(address(swapFeeHook));

        vm.expectPartialRevert(bytes4(keccak256("WithdrawalExceedsPoolLiability(bytes32,address,uint256,uint256)")));
        basketLiquidity.settleCanonicalHookFees(firstBasket, address(taxed));
        (, uint256 firstAfter) = basketLiquidity.pendingCanonicalHookFees(firstBasket, address(taxed));
        (, uint256 secondAfter) = basketLiquidity.pendingCanonicalHookFees(secondBasket, address(taxed));
        assertEq(firstAfter, firstLiability);
        assertEq(secondAfter, secondLiability);
        assertEq(taxed.balanceOf(address(swapFeeHook)), hookBalanceBefore);
        assertEq(basketAdmin.protocolRevenue(firstBasket, address(taxed)), 0);
        assertEq(basketAdmin.protocolRevenue(secondBasket, address(taxed)), 0);
    }

    function testHookWithdrawalTokenCallbackCannotReenterDiamondSettlement() public {
        MockReentrantERC20 reentrant = new MockReentrantERC20();
        (uint256 basketId, address basketToken, PoolKey memory key) =
            _prepareSingleAssetPool(reentrant, "Reentrant Basket", "sREENTER");
        _swapFrom(key, basketToken, 2 ether);
        (, uint256 pendingUnderlying) = basketLiquidity.pendingCanonicalHookFees(basketId, address(reentrant));
        assertGt(pendingUnderlying, 0);
        reentrant.setCallback(
            address(swapFeeHook),
            address(diamond),
            abi.encodeCall(IStaticsBasketLiquidity.settleCanonicalHookFees, (basketId, address(reentrant)))
        );

        IStaticsBasketLiquidity.HookSettlementTotals memory settled =
            basketLiquidity.settleCanonicalHookFees(basketId, address(reentrant));

        assertFalse(reentrant.reentrySucceeded());
        assertEq(bytes4(reentrant.reentryResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(settled.constituentRevenue, pendingUnderlying);
        assertEq(basketAdmin.protocolRevenue(basketId, address(reentrant)), pendingUnderlying);
    }

    function testEmptySettlementDoesNotChangeAccounting() public {
        (uint256 basketId,,) = _prepareDefaultPool();
        IStaticsBasketLiquidity.HookSettlementTotals memory settled =
            basketLiquidity.settleCanonicalHookFees(basketId, address(assetA));
        assertEq(settled.constituentRevenue, 0);
        assertEq(settled.basketTokensBurned, 0);
        IStaticsBasketLiquidity.HookSettlementTotals memory cumulative =
            basketLiquidity.cumulativeCanonicalHookSettlement(basketId, address(assetA));
        assertEq(cumulative.constituentRevenue, 0);
        assertEq(cumulative.basketTokensBurned, 0);
    }

    function _prepareDefaultPool() private returns (uint256 basketId, address basketToken, PoolKey memory key) {
        (basketId, basketToken) = _createDefaultBasket(0, 0);
        basketLiquidity.initializeCanonicalPool(basketId, address(assetA), SQRT_PRICE_1_1);
        uint256[] memory quote = baskets.quoteMint(basketId, 100 ether);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.prank(alice);
        baskets.mint(basketId, 100 ether, alice, quote);
        assetA.mint(alice, 100 ether);
        _approveV4Router(alice, basketToken);
        _approveV4Router(alice, address(assetA));
        key = _canonicalKey(basketId, address(assetA));
        _addFullRangeLiquidity(key);
    }

    function _prepareSingleAssetPool(MockERC20 asset, string memory name, string memory symbol)
        private
        returns (uint256 basketId, address basketToken, PoolKey memory key)
    {
        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: name,
            symbol: symbol,
            assets: assets,
            bundleAmounts: amounts,
            mintFeeTiers: new IStaticsBasket.FeeTier[](0),
            redemptionFeeTiers: new IStaticsBasket.FeeTier[](0),
            flashFeeBps: 0,
            originationFeeBps: 0,
            extensionFeeBps: 0,
            ltvBps: 9_500,
            loanDuration: 30 days
        });
        vm.prank(alice);
        (basketId, basketToken) = baskets.createBasket{value: basketAdmin.creationFee()}(params);
        basketLiquidity.initializeCanonicalPool(basketId, address(asset), SQRT_PRICE_1_1);

        uint256[] memory quote = baskets.quoteMint(basketId, 100 ether);
        asset.mint(alice, quote[0] + 100 ether);
        vm.startPrank(alice);
        asset.approve(address(diamond), type(uint256).max);
        baskets.mint(basketId, 100 ether, alice, quote);
        vm.stopPrank();
        _approveV4Router(alice, basketToken);
        _approveV4Router(alice, address(asset));
        key = _canonicalKey(basketId, address(asset));
        _addFullRangeLiquidity(key);
    }

    function _canonicalKey(uint256 basketId, address asset) private view returns (PoolKey memory key) {
        IStaticsBasketLiquidity.CanonicalPoolView memory pool = basketLiquidity.canonicalPool(basketId, asset);
        key = PoolKey({
            currency0: Currency.wrap(pool.currency0),
            currency1: Currency.wrap(pool.currency1),
            fee: pool.lpFee,
            tickSpacing: pool.tickSpacing,
            hooks: IHooks(pool.hook)
        });
    }

    function _addFullRangeLiquidity(PoolKey memory key) private {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(10),
            tickUpper: TickMath.maxUsableTick(10),
            liquidityDelta: 10 ether,
            salt: bytes32(0)
        });
        vm.prank(alice);
        v4Router.modifyLiquidity(key, params);
    }

    function _swapFrom(PoolKey memory key, address inputToken, uint256 amount) private {
        bool zeroForOne = Currency.unwrap(key.currency0) == inputToken;
        vm.prank(alice);
        v4Router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    function _assertPrimaryTotalsEqual(
        IStaticsBasketLiquidity.PrimaryFeeTotals memory left,
        IStaticsBasketLiquidity.PrimaryFeeTotals memory right
    ) private pure {
        assertEq(left.holderAmount, right.holderAmount);
        assertEq(left.liquidityAmount, right.liquidityAmount);
        assertEq(left.protocolAmount, right.protocolAmount);
    }
}
