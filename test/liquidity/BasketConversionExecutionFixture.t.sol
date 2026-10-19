// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import {BasketConversionForkBase} from "../helpers/BasketConversionForkBase.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {IStaticsBasketConversion} from "../../src/interfaces/IStaticsBasketConversion.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {IStaticsPosition} from "../../src/interfaces/IStaticsPosition.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BasketConversionRequest} from "../../src/interfaces/IStaticsBasketConversionRoutes.sol";
import {
    StaticsBasketConversionRouter,
    BasketConversionStep,
    BasketConversionBounds
} from "../../src/liquidity/StaticsBasketConversionRouter.sol";
import {StaticsBasketConversionZap} from "../../src/liquidity/StaticsBasketConversionZap.sol";

contract BasketConversionExecutionFixtureTest is BasketConversionForkBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    string internal output;

    function setUp() public override {
        if (bytes(vm.envOr("CONVERSION_MODE", string(""))).length == 0) {
            vm.skip(true);
            return;
        }
        super.setUp();
        output = vm.envOr("CONVERSION_EVIDENCE_OUT", string(".tooling/basket-conversion/execution/"));
        vm.dumpState(string.concat(output, _prefix(), "-base-state.json"));
    }

    function testExportExecutionFixture() public {
        Export memory e;
        e.mode = vm.envString("CONVERSION_MODE");
        bool sell = keccak256(bytes(e.mode)) == keccak256("sell");
        bool premium = keccak256(bytes(e.mode)) == keccak256("premium");
        bool buy = keccak256(bytes(e.mode)) == keccak256("buy");
        require(buy || sell || premium || keccak256(bytes(e.mode)) == keccak256("discount"));
        e.f = _fixture(vm.envUint("CONVERSION_ASSETS"));
        if (vm.envOr("CONVERSION_ROUTE_HOPS", uint256(1)) == 4) e.f = _fourHopRoutes(e.f);
        e.positions = _activateStakers(baskets.basket(e.f.basketId).assets);
        _trade(e.f, true, 100 ether, false, false);
        uint256 snap = vm.snapshotState();
        int256 q = _trade(e.f, true, 10 ether, false, false);
        assertTrue(vm.revertToState(snap));
        e.shares = 10 ether * 100e6 / uint256(-q);
        if (!sell && !buy) {
            e.market = _secondaryMarket(e.f, premium);
            e.gaugePosition = _exportGauge(e.f, e.market);
        }
        address buyer = address(uint160(0xE001));
        vm.deal(buyer, 100 ether);
        deal(USDG, buyer, 10_000e6);
        if (sell) {
            vm.prank(alice);
            conversionZap.buy(e.f.poolId, e.shares * 3, buyer, _request(e.f, true, false));
        }
        vm.startPrank(buyer);
        IERC20(e.f.token).approve(address(diamond), type(uint256).max);
        IERC20(e.f.token).approve(address(conversionZap), type(uint256).max);
        IERC20(USDG).approve(address(conversionRouter), type(uint256).max);
        IERC20(USDG).approve(address(conversionZap), type(uint256).max);
        vm.stopPrank();
        e.r = _request(e.f, buy || premium, false);
        e.r.deadline = block.timestamp + 30 days;
        e.steps = new BasketConversionStep[](sell || buy ? 1 : 2);
        BasketConversionStep memory conversion = _step(
            e.f.key,
            sell || (!premium && !buy) ? e.f.token : USDG,
            sell || (!premium && !buy) ? -int256(e.shares) : int256(e.shares),
            abi.encode(e.r)
        );
        if (sell || buy) {
            e.steps[0] = conversion;
        } else {
            BasketConversionStep memory ordinary =
                _step(e.market, premium ? e.f.token : USDG, premium ? -int256(e.shares) : int256(e.shares), "");
            e.steps[0] = premium ? conversion : ordinary;
            e.steps[1] = premium ? ordinary : conversion;
        }
        _serialize(e);
        vm.dumpState(string.concat(output, _prefix(), "-state.json"));
    }

    function _prefix() private view returns (string memory) {
        return string.concat(
            vm.toString(vm.envUint("CONVERSION_ASSETS")),
            "-",
            vm.envString("CONVERSION_MODE"),
            vm.envOr("CONVERSION_ROUTE_HOPS", uint256(1)) == 4 ? "-4hop" : ""
        );
    }

    function _exportGauge(Fixture memory f, PoolKey memory market) private returns (uint256 position) {
        vm.startPrank(alice);
        position = IStaticsPosition(address(diamond)).createPosition(alice);
        IERC20(f.token).approve(address(diamond), type(uint256).max);
        IERC20(USDG).approve(address(diamond), type(uint256).max);
        uint256 basketBudget = IERC20(f.token).balanceOf(alice);
        gauge.provideLiquidity(
            position,
            IStaticsRangeGauge.ProvideLiquidityParams(
                market.toId(),
                TickMath.minUsableTick(10),
                TickMath.maxUsableTick(10),
                1e13,
                Currency.unwrap(market.currency0) == USDG ? 100e6 : basketBudget,
                Currency.unwrap(market.currency1) == USDG ? 100e6 : basketBudget,
                block.timestamp
            )
        );
        vm.stopPrank();
        _fundGauge(market.toId());
    }

    struct Export {
        string mode;
        Fixture f;
        uint256[] positions;
        uint256 shares;
        PoolKey market;
        uint256 gaugePosition;
        BasketConversionRequest r;
        BasketConversionStep[] steps;
    }

    function _serialize(Export memory e) private {
        bool sell = keccak256(bytes(e.mode)) == keccak256("sell");
        string memory k = "evaluationFixture";
        vm.serializeString(k, "mode", e.mode);
        vm.serializeString(k, "commit", vm.envOr("STATICS_CONVERSION_CANDIDATE", string("development")));
        vm.serializeBytes(k, "hookRuntime", address(conversionHook).code);
        vm.serializeBytes(k, "zapRuntime", address(conversionZap).code);
        vm.serializeBytes(k, "routerRuntime", address(conversionRouter).code);
        address facet =
            IDiamondLoupe(address(diamond)).facetAddress(IStaticsBasketConversion.mintBasketConversion.selector);
        vm.serializeAddress(k, "facet", facet);
        vm.serializeBytes(k, "facetRuntime", facet.code);
        vm.serializeAddress(k, "poolManager", address(PM));
        vm.serializeBytes(
            k,
            "facetConstructor",
            abi.encode(address(conversionHook), address(conversionZap), address(conversionRouter), PM)
        );
        vm.serializeBytes(k, "hookConstructor", abi.encode(PM, baskets));
        vm.serializeBytes(k, "zapConstructor", abi.encode(PM, baskets, address(conversionHook)));
        vm.serializeBytes(k, "routerConstructor", abi.encode(PM, baskets, address(conversionHook)));
        vm.serializeUint(k, "count", vm.envUint("CONVERSION_ASSETS"));
        vm.serializeBytes32(k, "conversionPool", PoolId.unwrap(e.f.poolId));
        vm.serializeAddress(k, "buyer", address(uint160(0xE001)));
        vm.serializeAddress(k, "quote", USDG);
        vm.serializeAddress(k, "basket", e.f.token);
        vm.serializeAddress(k, "core", address(diamond));
        vm.serializeAddress(k, "router", address(conversionRouter));
        vm.serializeAddress(k, "zap", address(conversionZap));
        vm.serializeAddress(k, "hook", address(conversionHook));
        vm.serializeAddress(k, "deployer", address(this));
        vm.serializeBytes32(k, "hookSalt", conversionSalt);
        vm.serializeUint(k, "basketId", e.f.basketId);
        vm.serializeUint(k, "gaugePosition", e.gaugePosition);
        vm.serializeBytes32(k, "gaugePool", PoolId.unwrap(e.market.toId()));
        vm.serializeUint(k, "eligibleStakingPositions", e.positions);
        vm.serializeUint(k, "shares", e.shares);
        vm.serializeUint(k, "targetQuoteNotional", 100e6);
        vm.serializeUint(k, "blockTimestamp", block.timestamp);
        vm.serializeUint(k, "seedSupply", IERC20(e.f.token).totalSupply());
        vm.serializeAddress(k, "assets", baskets.basket(e.f.basketId).assets);
        vm.serializeUint(k, "bundleAmounts", baskets.basket(e.f.basketId).bundleAmounts);
        _serializeLiquidity(k, e);
        vm.serializeBytes(
            k,
            "zapData",
            sell
                ? abi.encodeCall(StaticsBasketConversionZap.sell, (e.f.poolId, e.shares, address(uint160(0xE001)), e.r))
                : abi.encodeCall(StaticsBasketConversionZap.buy, (e.f.poolId, e.shares, address(uint160(0xE001)), e.r))
        );
        string memory j = vm.serializeBytes(
            k,
            "hookData",
            abi.encodeCall(
                StaticsBasketConversionRouter.execute,
                (
                    e.f.poolId,
                    e.steps,
                    sell ? e.shares : 0,
                    BasketConversionBounds(
                        e.steps.length > 1 ? 0 : 1_000_000e6,
                        sell || e.steps.length > 1 ? 1 : 0,
                        sell || e.steps.length > 1 ? 0 : e.shares,
                        e.r.deadline
                    )
                )
            )
        );
        vm.writeJson(j, string.concat(output, _prefix(), "-fixture.json"));
    }

    function _serializeLiquidity(string memory k, Export memory e) private {
        uint256 total;
        uint256[] memory lengths = new uint256[](e.f.routes.length);
        for (uint256 i; i < lengths.length; ++i) {
            lengths[i] = e.f.routes[i].pools.length;
            total += lengths[i];
        }
        bytes32[] memory pools = new bytes32[](total);
        uint256[] memory liquidity = new uint256[](total);
        uint256 next;
        for (uint256 i; i < lengths.length; ++i) {
            for (uint256 j; j < lengths[i]; ++j) {
                PoolId id = e.f.routes[i].pools[j].toId();
                pools[next] = PoolId.unwrap(id);
                liquidity[next++] = PM.getLiquidity(id);
            }
        }
        vm.serializeUint(k, "routeHops", vm.envOr("CONVERSION_ROUTE_HOPS", uint256(1)));
        vm.serializeUint(k, "routeLengths", lengths);
        vm.serializeBytes32(k, "underlyingPools", pools);
        vm.serializeUint(k, "underlyingActiveLiquidity", liquidity);
        vm.serializeUint(k, "secondaryActiveLiquidity", e.steps.length > 1 ? PM.getLiquidity(e.market.toId()) : 0);
    }
}
