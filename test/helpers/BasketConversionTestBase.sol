// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsBasketConversion} from "../../src/interfaces/IStaticsBasketConversion.sol";
import {BasketConversionRoute, BasketConversionRequest} from "../../src/interfaces/IStaticsBasketConversionRoutes.sol";
import {BasketConversionFacet} from "../../src/facets/BasketConversionFacet.sol";
import {StaticsBasketConversionHook} from "../../src/liquidity/StaticsBasketConversionHook.sol";
import {StaticsBasketConversionZap} from "../../src/liquidity/StaticsBasketConversionZap.sol";
import {
    StaticsBasketConversionRouter,
    BasketConversionStep,
    BasketConversionBounds
} from "../../src/liquidity/StaticsBasketConversionRouter.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";
import {StaticsTestBase} from "./StaticsTestBase.sol";
import {CanonicalV4Router} from "./CanonicalPoolTestBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

abstract contract BasketConversionTestBase is StaticsTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager internal pm;
    StaticsBasketConversionHook internal conversionHook;
    StaticsBasketConversionZap internal conversionZap;
    StaticsBasketConversionRouter internal conversionRouter;
    IStaticsBasketConversion internal conversion;
    bytes32 internal conversionSalt;
    CanonicalV4Router internal liquidityRouter;
    address internal quoteToken;

    struct Fixture {
        uint256 basketId;
        address token;
        PoolId poolId;
        PoolKey key;
        BasketConversionRoute[] routes;
    }

    function setUp() public virtual override {
        super.setUp();
        (pm,) = _localLiquidity();
        quoteToken = address(new MockERC20("Quote", "Q", 18));
        _installConversion();
        _seedUnderlying(address(assetA), quoteToken);
        _seedUnderlying(address(assetB), quoteToken);
        _approveQuote(quoteToken);
    }

    function _installConversion() internal {
        bytes memory args = abi.encode(pm, baskets);
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(StaticsBasketConversionHook).creationCode, args);
        conversionSalt = salt;
        conversionHook = new StaticsBasketConversionHook{salt: salt}(pm, baskets);
        conversionZap = new StaticsBasketConversionZap(pm, baskets, address(conversionHook));
        conversionRouter = new StaticsBasketConversionRouter(pm, baskets, address(conversionHook));
        BasketConversionFacet facet =
            new BasketConversionFacet(address(conversionHook), address(conversionZap), address(conversionRouter), pm);
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] =
            IDiamondCut.FacetCut(address(facet), IDiamondCut.FacetCutAction.Add, StaticsSelectors.basketConversion());
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        conversion = IStaticsBasketConversion(address(diamond));
        basketAdmin.setBasketDistributor(address(conversionZap), true);
        IStaticsProtocolPools(address(diamond)).setPoolCreationFee(1);
        liquidityRouter = new CanonicalV4Router(pm);
    }

    function _approveQuote(address quote) internal {
        deal(quote, alice, 10_000_000 ether);
        vm.startPrank(alice);
        IERC20(quote).approve(address(conversionZap), type(uint256).max);
        IERC20(quote).approve(address(conversionRouter), type(uint256).max);
        IERC20(quote).approve(address(liquidityRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _seedUnderlying(address asset, address quote) internal {
        if (asset == quote) return;
        PoolKey memory key = _key(asset, quote, address(0), 3000, 60);
        pm.initialize(key, uint160(1 << 96));
        deal(asset, address(this), 1_000_000 ether);
        deal(quote, address(this), 1_000_000 ether);
        IERC20(asset).approve(address(liquidityRouter), type(uint256).max);
        IERC20(quote).approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-887220, 887220, int256(200_000 ether), bytes32(0)));
    }

    function _fixture(bool includeQuote) internal returns (Fixture memory f) {
        address[] memory assets = new address[](includeQuote ? 3 : 2);
        assets[0] = address(assetA);
        assets[1] = address(assetB);
        if (includeQuote) assets[2] = quoteToken;
        return _fixtureAssets(assets, quoteToken);
    }

    function _fixtureAssets(address[] memory assets, address quote) internal returns (Fixture memory f) {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0.001 ether, 0.001 ether);
        params.assets = assets;
        params.bundleAmounts = new uint256[](assets.length);
        IStaticsBasket.PoolLaunchParams[] memory pools = new IStaticsBasket.PoolLaunchParams[](assets.length);
        f.routes = new BasketConversionRoute[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            params.bundleAmounts[i] = _bundleAmount(assets[i]);
            pools[i] = IStaticsBasket.PoolLaunchParams(3000, 10, uint160(1 << 96), 0, false);
            f.routes[i] = _route(quote, assets[i]);
        }
        uint256 creationFee = basketAdmin.creationFee();
        vm.prank(alice);
        (f.basketId, f.token) =
            baskets.createBasket{value: creationFee}(params, pools, new uint256[](assets.length), block.timestamp);
        uint256 marketFee = IStaticsProtocolPools(address(diamond)).poolCreationFee();
        f.poolId =
            conversion.createBasketConversionMarket{value: marketFee}(f.basketId, quote, marketFee, block.timestamp);
        f.key = conversion.basketConversionMarket(f.poolId).key;
        vm.startPrank(alice);
        IERC20(f.token).approve(address(conversionZap), type(uint256).max);
        IERC20(f.token).approve(address(diamond), type(uint256).max);
        IERC20(f.token).approve(address(liquidityRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _key(address a, address b, address hook, uint24 fee, int24 spacing)
        internal
        pure
        returns (PoolKey memory)
    {
        return PoolKey(Currency.wrap(a < b ? a : b), Currency.wrap(a < b ? b : a), fee, spacing, IHooks(hook));
    }

    function _bundleAmount(address) internal pure virtual returns (uint256) {
        return 0.001 ether;
    }

    function _route(address quote, address asset) internal pure returns (BasketConversionRoute memory r) {
        uint256 hops = quote == asset ? 0 : 1;
        r.currencies = new address[](hops + 1);
        r.currencies[0] = quote;
        r.pools = new PoolKey[](hops);
        r.hookData = new bytes[](hops);
        if (hops != 0) {
            r.currencies[1] = asset;
            r.pools[0] = _key(quote, asset, address(0), 3000, 60);
        }
    }

    function _request(Fixture memory f, bool buying, bool usePreset)
        internal
        view
        returns (BasketConversionRequest memory r)
    {
        r.deadline = block.timestamp;
        r.limit = buying ? 1_000_000 ether : 0;
        r.routeLimits = new uint256[](f.routes.length);
        if (buying) {
            for (uint256 i; i < f.routes.length; ++i) {
                r.routeLimits[i] = r.limit;
            }
        }
        r.preset = usePreset;
        r.routes = usePreset ? new BasketConversionRoute[](0) : f.routes;
    }

    function _step(PoolKey memory k, address input, int256 amount, bytes memory data)
        internal
        pure
        returns (BasketConversionStep memory)
    {
        bool zeroForOne = Currency.unwrap(k.currency0) == input;
        return BasketConversionStep(
            k,
            SwapParams(zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            data
        );
    }

    function _trade(Fixture memory f, bool buying, uint256 shares, bool prefund, bool usePreset)
        internal
        returns (int256)
    {
        address quote = Currency.unwrap(f.key.currency0) == f.token
            ? Currency.unwrap(f.key.currency1)
            : Currency.unwrap(f.key.currency0);
        BasketConversionStep[] memory steps = new BasketConversionStep[](1);
        steps[0] = _step(
            f.key,
            buying ? quote : f.token,
            buying ? int256(shares) : -int256(shares),
            abi.encode(_request(f, buying, usePreset))
        );
        vm.prank(alice);
        return conversionRouter.execute(
            f.poolId,
            steps,
            prefund ? shares : 0,
            BasketConversionBounds(1_000_000 ether, 0, buying ? shares : 0, block.timestamp)
        );
    }

    function _assertBacking(Fixture memory f) internal view {
        uint256 supply = IERC20(f.token).totalSupply();
        address[] memory assets = baskets.basket(f.basketId).assets;
        for (uint256 i; i < assets.length; ++i) {
            uint256 bundle = baskets.basket(f.basketId).bundleAmounts[i];
            assertEq(baskets.vaultBalance(f.basketId, assets[i]), (supply * bundle + 1 ether - 1) / 1 ether);
            assertEq(pm.currencyDelta(address(conversionHook), Currency.wrap(assets[i])), 0);
            assertEq(pm.currencyDelta(address(conversionZap), Currency.wrap(assets[i])), 0);
            assertEq(pm.currencyDelta(address(conversionRouter), Currency.wrap(assets[i])), 0);
        }
        address quote = Currency.unwrap(f.key.currency0) == f.token
            ? Currency.unwrap(f.key.currency1)
            : Currency.unwrap(f.key.currency0);
        address[2] memory outer = [quote, f.token];
        address[3] memory adapters = [address(conversionHook), address(conversionZap), address(conversionRouter)];
        for (uint256 i; i < outer.length; ++i) {
            for (uint256 j; j < adapters.length; ++j) {
                assertEq(pm.currencyDelta(adapters[j], Currency.wrap(outer[i])), 0);
            }
        }
        assertEq(pm.getLiquidity(f.poolId), 0);
    }

    /// @dev Financial state only: excludes caller nonce and gas paid for a reverted transaction.
    function _conversionBooks(Fixture memory f) internal view returns (bytes32 state) {
        state = keccak256(abi.encode(IERC20(f.token).totalSupply(), _poolBooks(f.key)));
        address[] memory assets = baskets.basket(f.basketId).assets;
        for (uint256 i; i < assets.length + 2; ++i) {
            address quote = Currency.unwrap(f.key.currency0) == f.token
                ? Currency.unwrap(f.key.currency1)
                : Currency.unwrap(f.key.currency0);
            address token = i < assets.length ? assets[i] : i == assets.length ? quote : f.token;
            state = keccak256(abi.encode(state, _currencyBooks(token, f.basketId)));
        }
        for (uint256 i; i < f.routes.length; ++i) {
            for (uint256 j; j < f.routes[i].pools.length; ++j) {
                state = keccak256(abi.encode(state, _poolBooks(f.routes[i].pools[j])));
            }
        }
    }

    function _currencyBooks(address token, uint256 basketId) private view returns (bytes32 state) {
        state = keccak256(
            abi.encode(
                custody.globalReservedByToken(token),
                baskets.vaultBalance(basketId, token),
                globalRewards.rewardAsset(token),
                globalRewards.treasuryAccrued(token),
                globalRewards.unfundedSwapRewards(token)
            )
        );
        address[5] memory holders =
            [alice, address(diamond), address(conversionHook), address(conversionZap), address(conversionRouter)];
        for (uint256 i; i < holders.length; ++i) {
            state = keccak256(
                abi.encode(
                    state,
                    IERC20(token).balanceOf(holders[i]),
                    pm.currencyDelta(holders[i], Currency.wrap(token)),
                    pm.balanceOf(holders[i], uint160(token))
                )
            );
        }
        state = keccak256(
            abi.encode(
                state,
                IERC20(token).balanceOf(address(pm)),
                IERC20(token).allowance(alice, address(diamond)),
                IERC20(token).allowance(alice, address(conversionRouter)),
                IERC20(token).allowance(alice, address(conversionZap))
            )
        );
    }

    function _poolBooks(PoolKey memory key) internal view returns (bytes32) {
        PoolId id = key.toId();
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = pm.getSlot0(id);
        (uint256 fee0, uint256 fee1) = pm.getFeeGrowthGlobals(id);
        return keccak256(abi.encode(price, tick, protocolFee, lpFee, fee0, fee1, pm.getLiquidity(id)));
    }
}
