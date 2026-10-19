// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;
import {PublicHookUpgradeForkBase, PublicHookCandidateDeployer} from "../helpers/PublicHookUpgradeForkBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStaticsPositionFees} from "../../src/interfaces/IStaticsPosition.sol";
import {IERC173} from "../../src/interfaces/IERC173.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
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
import {StaticsInterfaceInit} from "../../src/diamond/StaticsInterfaceInit.sol";
import {PrepareStaticsBasketConversionUpgrade} from "../../script/PrepareStaticsBasketConversionUpgrade.s.sol";
import {StaticsProtocolPlan, StaticsProtocolParts} from "../../script/libraries/StaticsProtocolPlan.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {ForkSafe} from "../helpers/ForkSafe.sol";
import {PhaseTwoRehearsalBatch} from "../../scripts/phase-one-rehearsal/helpers/PhaseTwoRehearsalActors.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsBasketMarkets} from "../../src/interfaces/IStaticsBasketMarkets.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {LibBasketConversion} from "../../src/libraries/LibBasketConversion.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Actual fork Safe batch and conversion lifecycles on the original upgraded Diamond.
contract BasketConversionUpgradeForkTest is PublicHookUpgradeForkBase, ForkSafe {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    address private constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address private constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address private constant META = 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35;
    StaticsBasketConversionZap private zap;
    StaticsBasketConversionRouter private router;
    StaticsBasketConversionHook private hook;
    address private facet;
    uint256 private basketId;
    address private token;
    PoolKey private conversionKey;
    PoolKey private ordinaryKey;
    PoolKey private generalKey;
    uint256 private stake;
    string private output;
    bool private recording;
    string[] private actions;

    function setUp() public override {
        if (!vm.envOr("STATICS_CONVERSION_UPGRADE_FORK", false)) {
            vm.skip(true);
            return;
        }
        vm.setEnv("STATICS_PUBLIC_HOOK_FORK", "true");
        super.setUp();
        vm.rollFork(91_275_907);
        vm.deal(alice, 100 ether);
        output = vm.envOr("CONVERSION_UPGRADE_OUT", string(""));
    }

    function testPinnedOriginalDiamondConversionUpgrade() public {
        _upgrade();
        StaticsProtocolParts memory parts = new PublicHookCandidateDeployer().deployParts();
        _assertRouting(parts, false);
        _deployConversion();
        _prepareBasketAndMarkets();
        recording = true;
        _applyConversion(parts);
        _assertRouting(parts, true);
        _convert();
        IDiamondLoupe.Facet[] memory installed = IDiamondLoupe(address(diamond)).facets();
        assertEq(installed.length, 52);
        uint256 count;
        for (uint256 i; i < installed.length; ++i) {
            count += installed[i].functionSelectors.length;
        }
        assertEq(count, 362);
        _export();
    }

    function _assertRouting(StaticsProtocolParts memory parts, bool installed) private view {
        IDiamondCut.FacetCut[] memory expected = StaticsProtocolPlan.cumulative(parts, 2);
        for (uint256 i; i < expected.length; ++i) {
            for (uint256 j; j < expected[i].functionSelectors.length; ++j) {
                address actual = IDiamondLoupe(address(diamond)).facetAddress(expected[i].functionSelectors[j]);
                if (installed) assertEq(actual, expected[i].facetAddress);
                else assertTrue(actual != expected[i].facetAddress, "replacement branch not exercised");
            }
        }
    }

    function _deployConversion() private {
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        (, bytes32 salt) = HookMiner.find(
            address(this), flags, type(StaticsBasketConversionHook).creationCode, abi.encode(poolManager, baskets)
        );
        hook = new StaticsBasketConversionHook{salt: salt}(poolManager, baskets);
        zap = new StaticsBasketConversionZap(poolManager, baskets, address(hook));
        router = new StaticsBasketConversionRouter(poolManager, baskets, address(hook));
        facet = address(new BasketConversionFacet(address(hook), address(zap), address(router), poolManager));
        safeBatch = new PhaseTwoRehearsalBatch();
    }

    function _applyConversion(StaticsProtocolParts memory parts) private {
        PrepareStaticsBasketConversionUpgrade builder = new PrepareStaticsBasketConversionUpgrade();
        address init = address(new StaticsInterfaceInit());
        // The initializer must also be present in the pre-cut Anvil export.
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            builder.buildBatch(DIAMOND, facet, init, address(zap), parts);
        string memory safe = builder.buildSafeJson(DIAMOND, facet, init, address(zap), parts);
        for (uint256 i; i < targets.length; ++i) {
            string memory path = string.concat(".transactions[", vm.toString(i), "]");
            assertEq(vm.parseJsonAddress(safe, string.concat(path, ".to")), targets[i]);
            assertEq(vm.parseJsonBytes(safe, string.concat(path, ".data")), payloads[i]);
        }
        if (bytes(output).length != 0) vm.dumpState(string.concat(output, "/upgrade-state.json"));
        _executeSafe(owner, targets, values, payloads, "conversion-cut");
        assertTrue(basketAdmin.isBasketDistributor(address(zap)));
        assertEq(IERC173(DIAMOND).owner(), owner);
    }

    function _prepareBasketAndMarkets() private {
        IStaticsBasket.CreateBasketParams memory p = _defaultParams(0.001 ether, 0.001 ether);
        p.assets[0] = AAPL;
        p.assets[1] = META;
        p.bundleAmounts[0] = 0.001 ether;
        p.bundleAmounts[1] = 0.001 ether;
        IStaticsBasket.PoolLaunchParams[] memory launches = new IStaticsBasket.PoolLaunchParams[](2);
        for (uint256 i; i < 2; ++i) {
            launches[i] = IStaticsBasket.PoolLaunchParams(3000, 10, uint160(1 << 96), 0, false);
        }
        vm.prank(owner);
        (basketId, token) = baskets.createBasket(p, launches, new uint256[](2), block.timestamp);
        deal(AAPL, alice, 100 ether);
        deal(META, alice, 100 ether);
        deal(USDG, alice, 1_000_000e6);
        vm.startPrank(alice);
        IERC20(AAPL).approve(DIAMOND, type(uint256).max);
        IERC20(META).approve(DIAMOND, type(uint256).max);
        baskets.mint(basketId, 1000 ether, alice, baskets.quoteMint(basketId, 1000 ether));
        IERC20(token).approve(address(zap), type(uint256).max);
        IERC20(token).approve(DIAMOND, type(uint256).max);
        IERC20(token).approve(address(v4Router), type(uint256).max);
        IERC20(USDG).approve(address(zap), type(uint256).max);
        IERC20(USDG).approve(address(router), type(uint256).max);
        IERC20(USDG).approve(address(v4Router), type(uint256).max);
        IERC20(AAPL).approve(address(v4Router), type(uint256).max);
        vm.stopPrank();
        _activateStaker();
        _seedMarkets();
        conversionKey = _key(token, USDG, address(hook), 0, 1);
    }

    function _activateStaker() private {
        address staking = globalRewards.stakingToken();
        deal(staking, alice, 100 ether);
        address[] memory assets = new address[](3);
        assets[0] = AAPL;
        assets[1] = META;
        assets[2] = USDG;
        vm.startPrank(alice);
        IERC20(staking).approve(DIAMOND, type(uint256).max);
        stake = globalRewards.createAndStake{value: IStaticsPositionFees(DIAMOND).positionCreationFee()}(
            100 ether, alice, assets
        );
        vm.stopPrank();
        vm.warp(globalRewards.rewardSelection(stake, AAPL).eligibleAt + 1);
    }

    function _seedMarkets() private {
        uint160 price = uint160(Math.sqrt(Math.mulDiv(100e6, 1 << 192, 1 ether)));
        vm.prank(owner);
        PoolId market = IStaticsBasketMarkets(DIAMOND)
            .createBasketMarket(
                IStaticsBasketMarkets.MarketParams(token, USDG, 500, 10, price, 0, block.timestamp, false)
            );
        ordinaryKey = _key(token, USDG, address(_localBasketHook), 500, 10);
        assertEq(PoolId.unwrap(market), PoolId.unwrap(ordinaryKey.toId()));
        vm.prank(alice);
        v4Router.modifyLiquidity(ordinaryKey, ModifyLiquidityParams(-887270, 887270, 1e14, bytes32(0)));
        PoolKey memory real = _key(AAPL, USDG, address(0), 3000, 60);
        (uint160 livePrice,,,) = poolManager.getSlot0(real.toId());
        (uint16 input, uint16 outputRate) = swapFeeHook.defaultFeeRate();
        vm.prank(owner);
        PoolId general = pools.createPool(
            IStaticsProtocolPools.CreatePoolParams(
                USDG,
                AAPL,
                3000,
                60,
                livePrice,
                IStaticsProtocolPools.PoolSwapFeeRate(input, outputRate),
                owner,
                false,
                0,
                block.timestamp
            ),
            ""
        );
        generalKey = pools.protocolPool(general).key;
        assertEq(address(generalKey.hooks), address(swapFeeHook));
        vm.prank(alice);
        v4Router.modifyLiquidity(generalKey, ModifyLiquidityParams(-887220, 887220, 1e15, bytes32(0)));
    }

    function _key(address a, address b, address h, uint24 fee, int24 spacing) private pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(a < b ? a : b), Currency.wrap(a < b ? b : a), fee, spacing, IHooks(h));
    }

    function _request(bool buying) private view returns (BasketConversionRequest memory r) {
        r.deadline = block.timestamp + 30 days;
        r.limit = buying ? 10_000e6 : 0;
        r.routeLimits = new uint256[](2);
        r.routes = new BasketConversionRoute[](2);
        for (uint256 i; i < 2; ++i) {
            r.routeLimits[i] = r.limit;
            r.routes[i].currencies = new address[](2);
            r.routes[i].currencies[0] = USDG;
            r.routes[i].currencies[1] = i == 0 ? AAPL : META;
            r.routes[i].pools = new PoolKey[](1);
            r.routes[i].hookData = new bytes[](1);
            r.routes[i].pools[0] = i == 0 ? generalKey : _key(META, USDG, address(0), 3000, 60);
        }
    }

    function _step(PoolKey memory key, address input, int256 amount, bytes memory data)
        private
        pure
        returns (BasketConversionStep memory)
    {
        bool zero = Currency.unwrap(key.currency0) == input;
        return BasketConversionStep(
            key, SwapParams(zero, amount, zero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), data
        );
    }

    function _convert() private {
        address[] memory targets = new address[](1);
        targets[0] = DIAMOND;
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeCall(
            IStaticsBasketConversion.createBasketConversionMarket, (basketId, USDG, 0, block.timestamp + 30 days)
        );
        _executeSafe(owner, targets, new uint256[](1), payloads, "create-conversion-market");
        _run(
            "zap-buy",
            address(zap),
            abi.encodeCall(StaticsBasketConversionZap.buy, (conversionKey.toId(), 10 ether, alice, _request(true))),
            ""
        );
        BasketConversionStep[] memory steps = new BasketConversionStep[](1);
        steps[0] = _step(conversionKey, USDG, int256(1 ether), abi.encode(_request(true)));
        BasketConversionBounds memory bounds = BasketConversionBounds(0, 0, 1 ether, block.timestamp + 30 days);
        bytes memory error = abi.encodeWithSelector(LibBasketConversion.ConversionBound.selector);
        _router("late-buy-bound", steps, 0, bounds, error);
        bounds.maxQuoteIn = 10_000e6;
        _router("router-buy-retry", steps, 0, bounds, "");
        steps[0] = _step(conversionKey, token, -int256(1 ether), abi.encode(_request(false)));
        bounds = BasketConversionBounds(0, type(uint256).max, 0, block.timestamp + 30 days);
        _router("late-sell-bound", steps, 1 ether, bounds, error);
        bounds.minQuoteOut = 1;
        _router("router-prefunded-sell-retry", steps, 1 ether, bounds, "");
        steps = new BasketConversionStep[](2);
        steps[0] = _step(conversionKey, USDG, int256(1 ether), abi.encode(_request(true)));
        steps[1] = _step(ordinaryKey, token, -int256(1 ether), "");
        bounds.minQuoteOut = type(uint256).max;
        _router("late-profit-bound", steps, 0, bounds, error);
        bounds.minQuoteOut = 1;
        _router("conversion-arbitrage-retry", steps, 0, bounds, "");
        assertGt(globalRewards.unfundedSwapRewards(AAPL), 0, "General callback did not index swap fees");
        uint256 index = globalRewards.rewardAsset(AAPL).indexRay;
        _run(
            "fund-general-rewards",
            DIAMOND,
            abi.encodeCall(IStaticsGlobalRewards.settlePublicSwapRewards, (AAPL, type(uint256).max)),
            ""
        );
        assertEq(globalRewards.rewardAsset(AAPL).indexRay, index, "funding indexes the same fee twice");
        bytes32 funded = _books();
        _run(
            "fund-general-rewards-repeat",
            DIAMOND,
            abi.encodeCall(IStaticsGlobalRewards.settlePublicSwapRewards, (AAPL, type(uint256).max)),
            ""
        );
        assertEq(_books(), funded, "repeated funding changes financial state");
    }

    function _router(
        string memory label,
        BasketConversionStep[] memory steps,
        uint256 prefund,
        BasketConversionBounds memory bounds,
        bytes memory error
    ) private {
        _run(
            label,
            address(router),
            abi.encodeCall(StaticsBasketConversionRouter.execute, (conversionKey.toId(), steps, prefund, bounds)),
            error
        );
    }

    function _run(string memory label, address target, bytes memory data, bytes memory error) private {
        bytes32 beforeState = _books();
        _recordForkCall(label, alice, target, data, error);
        vm.prank(alice);
        (bool ok, bytes memory result) = target.call(data);
        if (error.length != 0) {
            assertFalse(ok);
            assertEq(result, error);
            assertEq(_books(), beforeState, "financial rollback");
        } else {
            if (!ok) {
                assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
            }
        }
    }

    function _books() private view returns (bytes32 state) {
        address[4] memory tokens = [AAPL, META, USDG, token];
        address[5] memory holders = [alice, DIAMOND, address(hook), address(zap), address(router)];
        for (uint256 i; i < tokens.length; ++i) {
            address a = tokens[i];
            state = keccak256(
                abi.encode(
                    state,
                    custody.globalReservedByToken(a),
                    baskets.vaultBalance(basketId, a),
                    globalRewards.rewardAsset(a),
                    globalRewards.unfundedSwapRewards(a),
                    globalRewards.treasuryAccrued(a)
                )
            );
            for (uint256 j; j < holders.length; ++j) {
                state = keccak256(
                    abi.encode(
                        state, IERC20(a).balanceOf(holders[j]), poolManager.currencyDelta(holders[j], Currency.wrap(a))
                    )
                );
            }
        }
        PoolId[3] memory ids = [ordinaryKey.toId(), generalKey.toId(), _key(META, USDG, address(0), 3000, 60).toId()];
        for (uint256 i; i < ids.length; ++i) {
            (uint160 price, int24 tick,,) = poolManager.getSlot0(ids[i]);
            (uint256 fee0, uint256 fee1) = poolManager.getFeeGrowthGlobals(ids[i]);
            state = keccak256(abi.encode(state, price, tick, fee0, fee1, poolManager.getLiquidity(ids[i])));
        }
        return keccak256(abi.encode(state, IERC20(token).totalSupply()));
    }

    function _recordForkCall(string memory label, address sender, address target, bytes memory data, bytes memory error)
        internal
        override
    {
        if (!recording) return;
        string memory key = string.concat("upgrade-action-", vm.toString(actions.length));
        vm.serializeString(key, "label", label);
        vm.serializeAddress(key, "sender", sender);
        vm.serializeAddress(key, "target", target);
        vm.serializeBytes(key, "data", data);
        actions.push(vm.serializeBytes(key, "expectedError", error));
    }

    function _export() private {
        if (bytes(output).length == 0) return;
        string memory key = "upgrade-fixture";
        vm.serializeString(key, "commit", vm.envString("STATICS_CONVERSION_CANDIDATE"));
        vm.serializeAddress(key, "core", DIAMOND);
        vm.serializeAddress(key, "owner", owner);
        vm.serializeAddress(key, "safeBatch", address(safeBatch));
        vm.serializeAddress(key, "buyer", alice);
        vm.serializeAddress(key, "quote", USDG);
        vm.serializeAddress(key, "basket", token);
        vm.serializeAddress(key, "hook", address(hook));
        vm.serializeAddress(key, "zap", address(zap));
        vm.serializeAddress(key, "router", address(router));
        vm.serializeAddress(key, "poolManager", address(poolManager));
        vm.serializeAddress(key, "generalHook", address(swapFeeHook));
        vm.serializeAddress(key, "basketHook", address(_localBasketHook));
        vm.serializeUint(key, "basketId", basketId);
        vm.serializeUint(key, "stake", stake);
        vm.serializeUint(key, "timestamp", block.timestamp);
        vm.serializeBytes32(key, "conversionPool", PoolId.unwrap(conversionKey.toId()));
        vm.serializeBytes32(key, "ordinaryPool", PoolId.unwrap(ordinaryKey.toId()));
        vm.serializeBytes32(key, "generalPool", PoolId.unwrap(generalKey.toId()));
        vm.serializeBytes32(key, "realUnderlyingPool", PoolId.unwrap(_key(META, USDG, address(0), 3000, 60).toId()));
        vm.serializeAddress(key, "assets", baskets.basket(basketId).assets);
        vm.serializeBytes(key, "safeBatchRuntime", address(safeBatch).code);
        string memory result = vm.serializeString(key, "actions", actions);
        vm.writeJson(result, string.concat(output, "/upgrade-fixture.json"));
    }
}
