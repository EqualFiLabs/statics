// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LibBasketConversion} from "../../src/libraries/LibBasketConversion.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {BasketConversionFacet} from "../../src/facets/BasketConversionFacet.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";
import {BasketConversionRequest} from "../../src/interfaces/IStaticsBasketConversionRoutes.sol";
import {BasketConversionTestBase} from "../helpers/BasketConversionTestBase.sol";
import {ConversionDeliveryProbe} from "../helpers/ConversionDeliveryProbe.sol";

contract ConversionDataHook {
    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata data)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        require(keccak256(data) == keccak256("typed conversion data"), "missing hook data");
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }
}

/// @dev A real underlying callback attempts a second pool on the same shared hook.
contract ConversionReentryHook {
    IPoolManager private pm;
    PoolKey private target;
    SwapParams private params;
    bytes private hookData;
    bool public blocked;

    function configure(IPoolManager pm_, PoolKey memory target_, SwapParams memory params_, bytes memory data)
        external
    {
        pm = pm_;
        target = target_;
        params = params_;
        hookData = data;
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (bool ok, bytes memory reason) = address(pm).call(abi.encodeCall(IPoolManager.swap, (target, params, hookData)));
        require(!ok, "recursive conversion succeeded");
        for (uint256 i; i + 4 <= reason.length; ++i) {
            bytes4 selector;
            assembly ("memory-safe") { selector := mload(add(add(reason, 32), i)) }
            if (selector == LibBasketConversion.ConversionReentered.selector) blocked = true;
        }
        require(blocked, "wrong reentry rejection");
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }
}

contract BasketConversionAbuseTest is BasketConversionTestBase {
    function _probe() private returns (ConversionDeliveryProbe probe) {
        probe = new ConversionDeliveryProbe(baskets, pm);
        BasketConversionFacet facet =
            new BasketConversionFacet(address(conversionHook), address(probe), address(conversionRouter), pm);
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut(
            address(facet), IDiamondCut.FacetCutAction.Replace, StaticsSelectors.basketConversion()
        );
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        assetA.mint(address(probe), 100 ether);
        assetB.mint(address(probe), 100 ether);
    }

    function testDirectMintRejectsMissingPartialExcessStaleAndReusedArrivals() public {
        Fixture memory f = _fixture(false);
        ConversionDeliveryProbe probe = _probe();
        uint256 donation = 1 ether;
        assetA.mint(address(diamond), donation);
        for (uint256 mode = 1; mode <= 6; ++mode) {
            if (mode == 5) continue;
            vm.expectRevert();
            probe.execute(f.poolId, 1 ether, alice, mode);
            assertEq(IERC20(f.token).totalSupply(), 0);
            assertEq(baskets.vaultBalance(f.basketId, address(assetA)), 0);
        }
        probe.execute(f.poolId, 1 ether, alice, 0);
        _assertBacking(f);
        assertGe(assetA.balanceOf(address(diamond)), donation);
    }

    function testDirectMintHoldsSharedGuardAndRejectsLockedManager() public {
        Fixture memory f = _fixture(false);
        ConversionDeliveryProbe probe = _probe();
        vm.prank(address(probe));
        vm.expectRevert(BasketConversionFacet.UnauthorizedConversion.selector);
        conversion.mintBasketConversion(f.poolId, 1 ether, alice, new uint256[](2));
        probe.execute(f.poolId, 1 ether, alice, 5);
        assertTrue(probe.blockedReentry());
        _assertBacking(f);
    }

    function testUnderlyingHookReceivesTypedDataInBothDirections() public {
        Fixture memory f = _fixture(false);
        address dataHook = address(0x10080);
        vm.etch(dataHook, type(ConversionDataHook).runtimeCode);
        PoolKey memory key = _key(quoteToken, address(assetA), dataHook, 3000, 60);
        pm.initialize(key, uint160(1 << 96));
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-887220, 887220, 100_000 ether, bytes32(0)));
        f.routes[0].pools[0] = key;
        vm.expectRevert();
        _trade(f, true, 1 ether, false, false);
        f.routes[0].hookData[0] = "typed conversion data";
        _trade(f, true, 10 ether, false, false);
        _trade(f, false, 1 ether, true, false);
        _assertBacking(f);
    }

    function testMultiHopAndPerRouteSellBounds() public {
        Fixture memory f = _fixture(false);
        _seedUnderlying(address(assetA), address(assetB));
        f.routes[0].currencies = new address[](3);
        f.routes[0].currencies[0] = quoteToken;
        f.routes[0].currencies[1] = address(assetB);
        f.routes[0].currencies[2] = address(assetA);
        f.routes[0].pools = new PoolKey[](2);
        f.routes[0].pools[0] = _key(quoteToken, address(assetB), address(0), 3000, 60);
        f.routes[0].pools[1] = _key(address(assetA), address(assetB), address(0), 3000, 60);
        f.routes[0].hookData = new bytes[](2);
        _trade(f, true, 10 ether, false, false);
        BasketConversionRequest memory r = _request(f, false, false);
        r.routeLimits[0] = type(uint128).max;
        vm.prank(alice);
        vm.expectRevert();
        conversionZap.sell(f.poolId, 1 ether, alice, r);
        _trade(f, false, 1 ether, true, false);
        _assertBacking(f);
    }

    function testUnderlyingCallbackCannotReenterSharedHookThroughAnotherPool() public {
        Fixture memory first = _fixture(false);
        Fixture memory second = _fixture(true);
        address callback = address(0x20080);
        vm.etch(callback, type(ConversionReentryHook).runtimeCode);
        PoolKey memory underlying = _key(quoteToken, address(assetA), callback, 3000, 60);
        pm.initialize(underlying, uint160(1 << 96));
        liquidityRouter.modifyLiquidity(underlying, ModifyLiquidityParams(-887220, 887220, 100_000 ether, bytes32(0)));
        ConversionReentryHook(callback)
            .configure(
                pm,
                second.key,
                _step(second.key, quoteToken, int256(1 ether), "").params,
                abi.encode(_request(second, true, false))
            );
        first.routes[0].pools[0] = underlying;
        _trade(first, true, 1 ether, false, false);
        assertTrue(ConversionReentryHook(callback).blocked());
        assertEq(IERC20(second.token).totalSupply(), 0);
        _assertBacking(first);
        _assertBacking(second);
    }
}
