// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {StaticsSwapFeeHook} from "../../src/liquidity/StaticsSwapFeeHook.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {StaticsBasketTokenFactory} from "../../src/liquidity/StaticsBasketTokenFactory.sol";
import {PublicHookPolicyFacet} from "../../src/facets/PublicHookPolicyFacet.sol";
import {BasketConversionTestBase} from "./BasketConversionTestBase.sol";
import {StaticsTestBase} from "./StaticsTestBase.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IStaticsBasketMarkets} from "../../src/interfaces/IStaticsBasketMarkets.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";
import {RangeGaugeFacet} from "../../src/facets/RangeGaugeFacet.sol";
import {RangeGaugeLivenessFacet} from "../../src/facets/RangeGaugeLivenessFacet.sol";
import {RangeGaugePositionFacet} from "../../src/facets/RangeGaugePositionFacet.sol";
import {RangeGaugePositionManagementFacet} from "../../src/facets/RangeGaugePositionManagementFacet.sol";
import {RangeGaugeViewFacet} from "../../src/facets/RangeGaugeViewFacet.sol";
import {CanonicalV4Router} from "./CanonicalPoolTestBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BasketConversionRoute} from "../../src/interfaces/IStaticsBasketConversionRoutes.sol";

abstract contract BasketConversionForkBase is BasketConversionTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    IPoolManager internal constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant META = 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35;
    uint256 internal constant PIN = 91_275_907;
    IStaticsRangeGauge internal gauge;
    CanonicalV4Router internal marketRouter;

    function setUp() public virtual override {
        string memory endpoint = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(endpoint).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(endpoint, PIN);
        assertEq(block.chainid, 4663);
        assertEq(address(PM).codehash, 0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626);
        StaticsTestBase.setUp();
        pm = PM;
        quoteToken = USDG;
        _installForkLiquidity();
        _installConversion();
        deal(USDG, alice, 10_000_000e6);
        vm.startPrank(alice);
        IERC20(USDG).approve(address(conversionZap), type(uint256).max);
        IERC20(USDG).approve(address(conversionRouter), type(uint256).max);
        IERC20(USDG).approve(address(liquidityRouter), type(uint256).max);
        vm.stopPrank();
        _installForkGauges();
    }

    function _installLocalLiquidityIntegration() internal pure override returns (bool) {
        return false;
    }

    function _installForkLiquidity() private {
        uint160 flags = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_DONATE_FLAG;
        bytes memory args = abi.encode(PM, address(diamond), uint16(25), uint16(25), address(wrappedNative));
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(StaticsSwapFeeHook).creationCode, args);
        StaticsSwapFeeHook general =
            new StaticsSwapFeeHook{salt: salt}(PM, address(diamond), 25, 25, address(wrappedNative));
        basketLiquidity.installCanonicalPoolIntegration(address(PM), address(general));
        IAllowanceTransfer permit2 = IAllowanceTransfer(deployCode("out/Permit2.sol/Permit2.json"));
        IPositionManager pos = IPositionManager(
            deployCode(
                "out/PositionManager.sol/PositionManager.json",
                abi.encode(PM, permit2, uint256(100_000), address(0), address(0))
            )
        );
        basketLiquidity.installLiquidityManager(
            address(new StaticsLiquidityManager(address(diamond), address(pos), address(PM), address(permit2)))
        );
        _localBasketFactory = StaticsBasketTokenFactory(
            deployCode(
                "out/StaticsBasketTokenFactory.sol/StaticsBasketTokenFactory.json", abi.encode(address(diamond), PM)
            )
        );
        _localBasketHook = _deployBasketHook(PM);
        PublicHookPolicyFacet(address(diamond))
            .installBasketHook(address(_localBasketHook), address(_localBasketFactory));
    }

    function _bundleAmount(address asset) internal pure override returns (uint256) {
        return asset == USDG ? 1e6 : 0.001 ether;
    }

    function _fixture(uint256 count) internal returns (Fixture memory f) {
        string memory config = vm.readFile("test/fixtures/basket-conversion/routes-16.json");
        address[] memory assets = new address[](count);
        for (uint256 i; i < count; ++i) {
            assets[i] = count == 4 && i == 3
                ? USDG
                : vm.parseJsonAddress(config, string.concat(".routes[", vm.toString(i), "].token"));
        }
        f = _fixtureAssets(assets, USDG);
        for (uint256 i; i < count; ++i) {
            if (assets[i] != USDG) {
                string memory route = string.concat(".routes[", vm.toString(i), "]");
                f.routes[i].pools[0] = _key(
                    USDG,
                    assets[i],
                    address(0),
                    uint24(vm.parseJsonUint(config, string.concat(route, ".fee"))),
                    int24(uint24(vm.parseJsonUint(config, string.concat(route, ".tickSpacing"))))
                );
                assertEq(
                    PoolId.unwrap(f.routes[i].pools[0].toId()),
                    vm.parseJsonBytes32(config, string.concat(route, ".poolId")),
                    "underlying PoolKey differs from pinned manifest"
                );
                assertGt(PM.getLiquidity(f.routes[i].pools[0].toId()), 0, "missing real underlying liquidity");
            }
        }
    }

    /// @dev Maximum-depth gas fixture: one pinned real hop and three locally funded
    /// ordinary ERC-20 hops per asset. Distinct bridges avoid overstating warm-slot savings.
    function _fourHopRoutes(Fixture memory f) internal returns (Fixture memory) {
        address[] memory assets = baskets.basket(f.basketId).assets;
        BasketConversionRoute[] memory direct = f.routes;
        f.routes = new BasketConversionRoute[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            require(assets[i] != USDG, "deep fixture has no zero-hop constituent");
            uint256 first = assets[i] == assets[0] ? 1 : 0;
            address bridgeA = address(new MockERC20("Route bridge A", "RBA", 18));
            address bridgeB = address(new MockERC20("Route bridge B", "RBB", 18));
            _seedUnderlying(assets[first], bridgeA);
            _seedUnderlying(bridgeA, bridgeB);
            _seedUnderlying(bridgeB, assets[i]);
            BasketConversionRoute memory r;
            r.currencies = new address[](5);
            r.currencies[0] = USDG;
            r.currencies[1] = assets[first];
            r.currencies[2] = bridgeA;
            r.currencies[3] = bridgeB;
            r.currencies[4] = assets[i];
            r.pools = new PoolKey[](4);
            r.hookData = new bytes[](4);
            r.pools[0] = direct[first].pools[0];
            for (uint256 j = 1; j < 4; ++j) {
                r.pools[j] = _key(r.currencies[j], r.currencies[j + 1], address(0), 3000, 60);
            }
            f.routes[i] = r;
        }
        return f;
    }

    function _activateStakers(address[] memory assets) internal returns (uint256[] memory positions) {
        uint256 batches = (assets.length + 7) / 8;
        positions = new uint256[](batches);
        address[][] memory selections = new address[][](batches);
        stakingAsset.mint(alice, batches * 100 ether);
        vm.prank(alice);
        stakingAsset.approve(address(diamond), batches * 100 ether);
        uint256 eligibleAt;
        for (uint256 i; i < batches; ++i) {
            uint256 length = assets.length - i * 8;
            if (length > 8) length = 8;
            address[] memory selection = new address[](length);
            selections[i] = selection;
            for (uint256 j; j < length; ++j) {
                selection[j] = assets[i * 8 + j];
            }
            vm.prank(alice);
            positions[i] = globalRewards.createAndStake(100 ether, alice, selection);
            eligibleAt = globalRewards.rewardSelection(positions[i], selection[0]).eligibleAt;
        }
        vm.warp(eligibleAt + 1);
        for (uint256 i; i < batches; ++i) {
            globalRewards.checkpointRewardAssets(selections[i]);
        }
    }

    function _installForkGauges() private {
        gauge = IStaticsRangeGauge(address(diamond));
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](5);
        cut[0] = IDiamondCut.FacetCut(
            address(new RangeGaugeFacet()), IDiamondCut.FacetCutAction.Add, StaticsSelectors.rangeGaugeActions()
        );
        cut[1] = IDiamondCut.FacetCut(
            address(new RangeGaugeLivenessFacet()),
            IDiamondCut.FacetCutAction.Add,
            StaticsSelectors.rangeGaugeLiveness()
        );
        cut[2] = IDiamondCut.FacetCut(
            address(new RangeGaugePositionFacet()),
            IDiamondCut.FacetCutAction.Add,
            StaticsSelectors.rangeGaugePositionIngress()
        );
        cut[3] = IDiamondCut.FacetCut(
            address(new RangeGaugePositionManagementFacet()),
            IDiamondCut.FacetCutAction.Add,
            StaticsSelectors.rangeGaugePositionManagement()
        );
        cut[4] = IDiamondCut.FacetCut(
            address(new RangeGaugeViewFacet()), IDiamondCut.FacetCutAction.Add, StaticsSelectors.rangeGaugeViews()
        );
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        marketRouter = new CanonicalV4Router(PM);
    }

    function _fundGauge(PoolId id) internal {
        gauge.setGaugeRewardAssetAllowed(USDG, true);
        vm.startPrank(alice);
        uint8 slot = gauge.appendPoolRewardAsset(id, USDG);
        assertEq(slot, 1);
        IERC20(USDG).approve(address(diamond), 10e6);
        gauge.fundPoolReward(id, slot, 10e6, 0, 0);
        vm.stopPrank();
    }

    function _secondaryMarket(Fixture memory f, bool premium) internal returns (PoolKey memory k) {
        vm.prank(alice);
        uint256 cost = conversionZap.buy(f.poolId, 10 ether, alice, _request(f, true, false));
        uint256 price = cost / 10;
        price = premium ? price * 2 : price / 2;
        uint160 sqrtPrice = uint160(
            Math.sqrt(f.token < USDG ? Math.mulDiv(price, 1 << 192, 1 ether) : Math.mulDiv(1 ether, 1 << 192, price))
        );
        _seedSecondaryInventory(f, sqrtPrice);
        vm.prank(alice);
        IStaticsBasketMarkets(address(diamond)).createBasketMarket{value: 1}(
            IStaticsBasketMarkets.MarketParams(
                f.token,
                USDG,
                500,
                10,
                uint160(Math.sqrt(Math.mulDiv(price, 1 << 192, 1 ether))),
                type(uint256).max,
                block.timestamp,
                false
            )
        );
        (address a, address b) = f.token < USDG ? (f.token, USDG) : (USDG, f.token);
        k = PoolKey(Currency.wrap(a), Currency.wrap(b), 500, 10, IHooks(address(_localBasketHook)));
        vm.startPrank(alice);
        IERC20(f.token).approve(address(marketRouter), type(uint256).max);
        IERC20(USDG).approve(address(marketRouter), type(uint256).max);
        marketRouter.modifyLiquidity(
            k, ModifyLiquidityParams(TickMath.minUsableTick(10), TickMath.maxUsableTick(10), int256(1e15), bytes32(0))
        );
        vm.stopPrank();
    }

    function _seedSecondaryInventory(Fixture memory f, uint160 sqrtPrice) private {
        // Include the receipt fixture's 1e13 gauge leg alongside 1e15 market liquidity.
        uint256 required = f.token < USDG
            ? SqrtPriceMath.getAmount0Delta(
                sqrtPrice, TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(10)), 1_010_000_000_000_000, true
            )
            : SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(10)), sqrtPrice, 1_010_000_000_000_000, true
            );
        uint256 available = IERC20(f.token).balanceOf(alice);
        if (required > available) {
            vm.prank(alice);
            conversionZap.buy(f.poolId, required - available + 1 ether, alice, _request(f, true, false));
        }
    }
}
