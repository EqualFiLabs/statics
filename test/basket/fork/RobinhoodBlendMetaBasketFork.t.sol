// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IStaticsBasket} from "../../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../../src/interfaces/IStaticsBasketLiquidity.sol";
import {
    IBlendBasket,
    IBlendBasketFactory,
    IBlendHook,
    RobinhoodBlendBasketForkBase
} from "./RobinhoodBlendBasketFork.t.sol";
import {CanonicalV4Router} from "../../helpers/CanonicalPoolTestBase.sol";

/// @notice Proves two independently deployed Blend BasketVaults compose into one Statics basket.
contract RobinhoodBlendMetaBasketForkTest is RobinhoodBlendBasketForkBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address private constant BLEND_CHIPS = 0x72c5a85cA436f8346A3429bf794ac333B5E13898;
    uint256 private constant CHIPS_REGISTRY_INDEX = 3;
    uint256 private constant USDG_FUNDING = 5_000_000;
    uint256 private constant META_BUNDLE = 0.005 ether;
    uint256 private constant OPERATION_SHARES = 1 ether;

    struct MetaBasket {
        uint256 basketId;
        address token;
        uint256 acquiredChips;
        uint256 acquisitionGas;
        uint256 launchGas;
    }

    struct MetaSnapshot {
        uint256 supply;
        uint256 userBasket;
        uint256[2] userAssets;
        uint256[2] vaults;
        uint256[2] basketReserves;
        uint256[2] feeReserves;
        uint256[2] globalReserves;
        uint256[2] treasury;
        uint256[2] diamondBalances;
    }

    struct RoundTripGas {
        uint256 mint;
        uint256 redemption;
    }

    function testTwoLiveBlendBasketsComposeIntoOneStaticsMetaBasket() public {
        _assertSecondLiveBlendBasket();
        MetaBasket memory meta;
        (meta.acquiredChips, meta.acquisitionGas) = _acquireChipsFromLiveBlendMarket();
        (meta.basketId, meta.token, meta.launchGas) = _launchMetaBasket();
        _assertCanonicalTopology(meta);

        bytes32 blendBackingBefore = _recursiveBackingHash();
        MetaSnapshot memory beforeAction = _snapshot(meta);
        RoundTripGas memory operationGas = _roundTrip(meta, beforeAction);
        assertEq(_recursiveBackingHash(), blendBackingBefore);
        _logRecursiveComposition();

        emit log("Live Blend AI + live Blend CHIPS -> one fee-bearing Statics meta basket");
        emit log_named_uint("CHIPS acquired through live BlendHook", meta.acquiredChips);
        emit log_named_uint("Live CHIPS acquisition gas", meta.acquisitionGas);
        emit log_named_uint("Two-Blend Statics launch gas", meta.launchGas);
        emit log_named_uint("Two-Blend Statics mint gas", operationGas.mint);
        emit log_named_uint("Two-Blend Statics redemption gas", operationGas.redemption);
    }

    function _assertSecondLiveBlendBasket() private view {
        IBlendBasketFactory factory = IBlendBasketFactory(BLEND_FACTORY);
        assertEq(factory.deployed(CHIPS_REGISTRY_INDEX), BLEND_CHIPS);
        assertTrue(factory.isBasket(BLEND_AI));
        assertTrue(factory.isBasket(BLEND_CHIPS));
        assertEq(keccak256(bytes(IBlendBasket(BLEND_CHIPS).symbol())), keccak256("CHIPS"));
        assertEq(IBlendBasket(BLEND_CHIPS).decimals(), 18);
        assertEq(IBlendBasket(BLEND_CHIPS).constituents().length, 4);
    }

    function _acquireChipsFromLiveBlendMarket() private returns (uint256 acquired, uint256 executionGas) {
        vm.prank(BLEND_AI_HOLDER);
        assertTrue(IERC20(USDG).transfer(alice, USDG_FUNDING));

        CanonicalV4Router router = new CanonicalV4Router(poolManager);
        PoolKey memory pool = IBlendHook(BLEND_HOOK).poolKeyFor(BLEND_CHIPS, USDG);
        assertEq(address(pool.hooks), BLEND_HOOK);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(pool.toId());
        assertGt(sqrtPriceX96, 0);
        bool zeroForOne = Currency.unwrap(pool.currency0) == USDG;
        uint256 beforeBalance = IERC20(BLEND_CHIPS).balanceOf(alice);

        vm.prank(alice);
        assertTrue(IERC20(USDG).approve(address(router), USDG_FUNDING));
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        router.swap(
            pool,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(USDG_FUNDING),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
        executionGas = gasBefore - gasleft();
        acquired = IERC20(BLEND_CHIPS).balanceOf(alice) - beforeBalance;
        assertGt(acquired, 0.02 ether);
        vm.prank(alice);
        assertTrue(IERC20(BLEND_CHIPS).approve(address(diamond), type(uint256).max));
    }

    function _launchMetaBasket() private returns (uint256 basketId, address token, uint256 executionGas) {
        address[] memory assets = _metaAssets();
        uint256[] memory bundles = new uint256[](2);
        bundles[0] = META_BUNDLE;
        bundles[1] = META_BUNDLE;
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: "Statics Blend Sectors",
            symbol: "sBLENDS",
            assets: assets,
            bundleAmounts: bundles,
            mintFeeTiers: _singleFeeTier(MINT_FEE_SHARES),
            redemptionFeeTiers: _singleFeeTier(REDEMPTION_FEE_SHARES),
            flashFeeBps: 5,
            originationFeeBps: 25,
            extensionFeeBps: 10,
            ltvBps: 9_000,
            recoveryPenaltyBps: 500,
            loanDuration: 30 days
        });
        IStaticsBasket.PoolLaunchParams[] memory pools = new IStaticsBasket.PoolLaunchParams[](2);
        uint256[] memory maximums = new uint256[](2);
        for (uint256 i; i < 2; ++i) {
            pools[i] = IStaticsBasket.PoolLaunchParams({
                lpFee: 3_000,
                tickSpacing: 10,
                sqrtPriceAssetPerBasketX96: _semanticSqrtPrice(META_BUNDLE),
                pairedAssetAmount: META_BUNDLE
            });
            maximums[i] = IERC20(assets[i]).balanceOf(alice);
        }

        uint256 creationFee = basketAdmin.creationFee();
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        (basketId, token) = baskets.createBasket{value: creationFee}(params, pools, maximums, block.timestamp + 1 hours);
        executionGas = gasBefore - gasleft();
    }

    function _assertCanonicalTopology(MetaBasket memory meta) private view {
        address[] memory assets = _metaAssets();
        IStaticsBasket.BasketView memory configured = baskets.basket(meta.basketId);
        assertEq(configured.assets, assets);
        assertEq(configured.bundleAmounts[0], META_BUNDLE);
        assertEq(configured.bundleAmounts[1], META_BUNDLE);
        for (uint256 i; i < assets.length; ++i) {
            IStaticsBasketLiquidity.CanonicalPoolView memory canonical =
                basketLiquidity.canonicalPool(meta.basketId, assets[i]);
            assertEq(canonical.basketToken, meta.token);
            assertEq(canonical.asset, assets[i]);
            assertEq(canonical.hook, address(staticsHook));
            assertNotEq(canonical.hook, BLEND_HOOK);
            assertGt(staticsHook.lockedLiquidity(canonical.poolId), 0);

            PoolKey memory blendMarket = IBlendHook(BLEND_HOOK).poolKeyFor(assets[i], USDG);
            assertEq(address(blendMarket.hooks), BLEND_HOOK);
            assertNotEq(PoolId.unwrap(canonical.poolId), PoolId.unwrap(blendMarket.toId()));
        }
    }

    function _roundTrip(MetaBasket memory meta, MetaSnapshot memory beforeAction)
        private
        returns (RoundTripGas memory executionGas)
    {
        uint256[] memory mintQuote = baskets.quoteMint(meta.basketId, OPERATION_SHARES);
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        baskets.mint(meta.basketId, OPERATION_SHARES, alice, mintQuote);
        executionGas.mint = gasBefore - gasleft();

        uint256[] memory redemptionQuote = baskets.quoteRedeem(meta.basketId, OPERATION_SHARES);
        gasBefore = gasleft();
        vm.prank(alice);
        baskets.redeem(meta.basketId, OPERATION_SHARES, alice, redemptionQuote);
        executionGas.redemption = gasBefore - gasleft();
        _assertRoundTrip(meta, beforeAction, mintQuote, redemptionQuote);
    }

    function _assertRoundTrip(
        MetaBasket memory meta,
        MetaSnapshot memory beforeAction,
        uint256[] memory mintQuote,
        uint256[] memory redemptionQuote
    ) private view {
        MetaSnapshot memory afterAction = _snapshot(meta);
        assertEq(afterAction.supply, beforeAction.supply);
        assertEq(afterAction.userBasket, beforeAction.userBasket);
        for (uint256 i; i < 2; ++i) {
            uint256 totalFee = mintQuote[i] - redemptionQuote[i];
            assertEq(afterAction.userAssets[i], beforeAction.userAssets[i] - totalFee);
            assertEq(afterAction.vaults[i], beforeAction.vaults[i]);
            assertEq(afterAction.basketReserves[i], beforeAction.basketReserves[i]);
            assertEq(afterAction.feeReserves[i], beforeAction.feeReserves[i] + totalFee);
            assertEq(afterAction.globalReserves[i], beforeAction.globalReserves[i] + totalFee);
            assertEq(afterAction.treasury[i], beforeAction.treasury[i] + totalFee);
            assertEq(afterAction.diamondBalances[i], beforeAction.diamondBalances[i] + totalFee);
        }
    }

    function _snapshot(MetaBasket memory meta) private view returns (MetaSnapshot memory snapshot) {
        snapshot.supply = IERC20(meta.token).totalSupply();
        snapshot.userBasket = IERC20(meta.token).balanceOf(alice);
        address[] memory assets = _metaAssets();
        bytes32 account = custody.basketCustodyAccount(meta.basketId);
        for (uint256 i; i < 2; ++i) {
            snapshot.userAssets[i] = IERC20(assets[i]).balanceOf(alice);
            snapshot.vaults[i] = baskets.vaultBalance(meta.basketId, assets[i]);
            snapshot.basketReserves[i] = custody.reservedByAccount(account, assets[i]);
            snapshot.feeReserves[i] = custody.reservedByAccount(custody.feeCustodyAccount(), assets[i]);
            snapshot.globalReserves[i] = custody.globalReservedByToken(assets[i]);
            snapshot.treasury[i] = globalRewards.treasuryAccrued(assets[i]);
            snapshot.diamondBalances[i] = IERC20(assets[i]).balanceOf(address(diamond));
        }
    }

    function _recursiveBackingHash() private view returns (bytes32 result) {
        address[] memory baskets_ = _metaAssets();
        for (uint256 i; i < baskets_.length; ++i) {
            IBlendBasket blend = IBlendBasket(baskets_[i]);
            address[] memory constituents = blend.constituents();
            for (uint256 j; j < constituents.length; ++j) {
                address asset = constituents[j];
                result = keccak256(abi.encode(result, baskets_[i], asset, blend.units(asset), blend.backing(asset)));
            }
        }
    }

    function _logRecursiveComposition() private {
        address[] memory baskets_ = _metaAssets();
        for (uint256 i; i < baskets_.length; ++i) {
            IBlendBasket blend = IBlendBasket(baskets_[i]);
            emit log_named_address(blend.symbol(), baskets_[i]);
            address[] memory constituents = blend.constituents();
            for (uint256 j; j < constituents.length; ++j) {
                emit log_named_decimal_uint(IERC20Metadata(constituents[j]).symbol(), blend.units(constituents[j]), 18);
            }
        }
    }

    function _metaAssets() private pure returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = BLEND_AI;
        assets[1] = BLEND_CHIPS;
    }

    function _semanticSqrtPrice(uint256 assetUnitsPerShare) private pure returns (uint160) {
        uint256 ratioRoot = Math.sqrt(assetUnitsPerShare * 1 ether);
        return uint160(Math.mulDiv(ratioRoot, 1 << 96, 1 ether));
    }
}
