// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ImmutablePublicHookUpgradeForkTest, PublicHookCandidateDeployer} from "./ImmutablePublicHookUpgradeFork.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC173} from "../../src/interfaces/IERC173.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketConversion} from "../../src/interfaces/IStaticsBasketConversion.sol";
import {BasketConversionRoute, BasketConversionRequest} from "../../src/interfaces/IStaticsBasketConversionRoutes.sol";
import {BasketConversionFacet} from "../../src/facets/BasketConversionFacet.sol";
import {StaticsBasketConversionHook} from "../../src/liquidity/StaticsBasketConversionHook.sol";
import {StaticsBasketConversionZap} from "../../src/liquidity/StaticsBasketConversionZap.sol";
import {StaticsBasketConversionRouter} from "../../src/liquidity/StaticsBasketConversionRouter.sol";
import {StaticsInterfaceInit} from "../../src/diamond/StaticsInterfaceInit.sol";
import {PrepareStaticsBasketConversionUpgrade} from "../../script/PrepareStaticsBasketConversionUpgrade.s.sol";
import {StaticsProtocolPlan, StaticsProtocolParts} from "../../script/libraries/StaticsProtocolPlan.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/// @notice Original Phase 1 fixture → Phase 2 → conversion at the prototype's pinned block.
contract BasketConversionUpgradeForkTest is ImmutablePublicHookUpgradeForkTest {
    address private constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address private constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address private constant META = 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35;

    function setUp() public override {
        if (!vm.envOr("STATICS_CONVERSION_UPGRADE_FORK", false)) {
            vm.skip(true);
            return;
        }
        vm.setEnv("STATICS_PUBLIC_HOOK_FORK", "true");
        super.setUp();
        vm.rollFork(91_275_907);
    }

    StaticsBasketConversionZap private zap;
    address private facet;

    function testPinnedOriginalDiamondConversionUpgrade() public {
        _upgrade();
        // Use distinct candidate addresses so the Safe batch must replace installed facets.
        StaticsProtocolParts memory parts = new PublicHookCandidateDeployer().deployParts();
        _assertRouting(parts, false);
        _deployConversion();
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
    }

    function _assertRouting(StaticsProtocolParts memory parts, bool installed) private view {
        IDiamondCut.FacetCut[] memory expected = StaticsProtocolPlan.cumulative(parts, 2);
        for (uint256 i; i < expected.length; ++i) {
            for (uint256 j; j < expected[i].functionSelectors.length; ++j) {
                address actual = IDiamondLoupe(address(diamond)).facetAddress(expected[i].functionSelectors[j]);
                if (installed) assertEq(actual, expected[i].facetAddress, "candidate selector not replaced");
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
        StaticsBasketConversionHook hook = new StaticsBasketConversionHook{salt: salt}(poolManager, baskets);
        zap = new StaticsBasketConversionZap(poolManager, baskets, address(hook));
        StaticsBasketConversionRouter router = new StaticsBasketConversionRouter(poolManager, baskets, address(hook));
        facet = address(new BasketConversionFacet(address(hook), address(zap), address(router), poolManager));
    }

    function _applyConversion(StaticsProtocolParts memory parts) private {
        address core = address(diamond);
        address owner = IERC173(core).owner();
        PrepareStaticsBasketConversionUpgrade builder = new PrepareStaticsBasketConversionUpgrade();
        address init = address(new StaticsInterfaceInit());
        (address[] memory targets,, bytes[] memory payloads) =
            builder.buildBatch(core, facet, init, address(zap), parts);
        string memory safe = builder.buildSafeJson(core, facet, init, address(zap), parts);
        assertEq(vm.parseJsonBytes(safe, ".transactions[0].data"), payloads[0]);
        for (uint256 i; i < targets.length; ++i) {
            vm.prank(owner);
            (bool ok, bytes memory result) = targets[i].call(payloads[i]);
            if (!ok) {
                assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
            }
        }
        assertEq(IERC173(core).owner(), owner);
    }

    function _convert() private {
        address owner = IERC173(address(diamond)).owner();
        vm.deal(owner, 100 ether);
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
        (uint256 id, address token) = baskets.createBasket(p, launches, new uint256[](2), block.timestamp);
        vm.prank(owner);
        PoolId pool =
            IStaticsBasketConversion(address(diamond)).createBasketConversionMarket(id, USDG, 0, block.timestamp);
        BasketConversionRequest memory r;
        r.deadline = block.timestamp;
        r.limit = 10_000e6;
        r.routeLimits = new uint256[](2);
        r.routes = new BasketConversionRoute[](2);
        for (uint256 i; i < 2; ++i) {
            r.routeLimits[i] = r.limit;
            address asset = p.assets[i];
            r.routes[i].currencies = new address[](2);
            r.routes[i].currencies[0] = USDG;
            r.routes[i].currencies[1] = asset;
            r.routes[i].pools = new PoolKey[](1);
            r.routes[i].hookData = new bytes[](1);
            r.routes[i].pools[0] = PoolKey(
                Currency.wrap(asset < USDG ? asset : USDG),
                Currency.wrap(asset < USDG ? USDG : asset),
                3000,
                60,
                IHooks(address(0))
            );
        }
        deal(USDG, alice, 10_000e6);
        vm.startPrank(alice);
        IERC20(USDG).approve(address(zap), type(uint256).max);
        zap.buy(pool, 10 ether, alice, r);
        IERC20(token).approve(address(zap), type(uint256).max);
        r.limit = 0;
        r.routeLimits = new uint256[](2);
        zap.sell(pool, 5 ether, alice, r);
        vm.stopPrank();
        assertEq(IERC20(token).balanceOf(alice), 5 ether);
        for (uint256 i; i < 2; ++i) {
            assertEq(baskets.vaultBalance(id, p.assets[i]), 0.005 ether);
        }
    }
}
