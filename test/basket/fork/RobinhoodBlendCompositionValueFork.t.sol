// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";

import {IStaticsBasket} from "../../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IBlendBasket, RobinhoodBlendBasketForkBase} from "./RobinhoodBlendBasketFork.t.sol";

interface IBlendCompositionBasket is IBlendBasket {
    function redeem(uint256 shares, address to) external;
}

/// @notice Product proof comparing wrapped Blend exposure with the equivalent flattened stock vector.
contract RobinhoodBlendCompositionValueForkTest is RobinhoodBlendBasketForkBase {
    bytes32 private constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    uint256 private constant STOCK_BOOTSTRAP_SHARES = 15 ether;
    uint256 private constant OPERATION_SHARES = 1 ether;

    struct ComparableBasket {
        uint256 basketId;
        address token;
        uint256 launchGas;
        uint256 normalizedSeedInput;
    }

    struct OperationResult {
        uint256 mintGas;
        uint256 redemptionGas;
        uint256 mintTransfers;
        uint256 redemptionTransfers;
    }

    function testWrappedBlendCompositionReducesImmediateExecutionAndPoolSurface() public {
        IBlendCompositionBasket blend = IBlendCompositionBasket(BLEND_AI);
        address[] memory constituents = blend.constituents();
        uint256[] memory units = _blendUnits(blend, constituents);
        _fundFlattenedConstruction(blend, constituents);

        ComparableBasket memory wrapped = _createComparableWrappedBasket();
        ComparableBasket memory flattened = _createComparableFlattenedBasket(constituents, units);
        _assertEquivalentTopology(wrapped, flattened, constituents, units);

        OperationResult memory wrappedOps = _measureRoundTrip(wrapped.basketId, wrapped.token);
        OperationResult memory flattenedOps = _measureRoundTrip(flattened.basketId, flattened.token);

        assertEq(wrappedOps.mintTransfers, 1);
        assertEq(wrappedOps.redemptionTransfers, 1);
        assertEq(flattenedOps.mintTransfers, constituents.length);
        assertEq(flattenedOps.redemptionTransfers, constituents.length);
        assertLt(wrapped.launchGas, flattened.launchGas);
        assertLt(wrapped.normalizedSeedInput, flattened.normalizedSeedInput);
        assertLt(wrappedOps.mintGas, flattenedOps.mintGas);
        assertLt(wrappedOps.redemptionGas, flattenedOps.redemptionGas);

        emit log("Equivalent exposure: one Blend ERC-20 edge versus three immediate Stock Token edges");
        emit log_named_uint("Wrapped canonical pools", 1);
        emit log_named_uint("Flattened canonical pools", constituents.length);
        emit log_named_uint("Wrapped launch gas", wrapped.launchGas);
        emit log_named_uint("Flattened launch gas", flattened.launchGas);
        emit log_named_uint("Wrapped normalized seed input", wrapped.normalizedSeedInput);
        emit log_named_uint("Flattened normalized seed input", flattened.normalizedSeedInput);
        emit log_named_uint("Wrapped mint gas", wrappedOps.mintGas);
        emit log_named_uint("Flattened mint gas", flattenedOps.mintGas);
        emit log_named_uint("Wrapped redemption gas", wrappedOps.redemptionGas);
        emit log_named_uint("Flattened redemption gas", flattenedOps.redemptionGas);
    }

    function _fundFlattenedConstruction(IBlendCompositionBasket blend, address[] memory constituents) private {
        vm.prank(alice);
        blend.redeem(STOCK_BOOTSTRAP_SHARES, alice);
        for (uint256 i; i < constituents.length; ++i) {
            assertGt(IERC20(constituents[i]).balanceOf(alice), 0);
            vm.prank(alice);
            assertTrue(IERC20(constituents[i]).approve(address(diamond), type(uint256).max));
        }
    }

    function _createComparableWrappedBasket() private returns (ComparableBasket memory result) {
        address[] memory assets = new address[](1);
        assets[0] = BLEND_AI;
        uint256[] memory bundles = new uint256[](1);
        bundles[0] = 1 ether;
        uint256 blendBefore = IERC20(BLEND_AI).balanceOf(alice);
        uint256 gasBefore = gasleft();
        (result.basketId, result.token) = _launchComparableBasket("Wrapped Blend AI", "sWAI", assets, bundles);
        result.launchGas = gasBefore - gasleft();
        result.normalizedSeedInput = blendBefore - IERC20(BLEND_AI).balanceOf(alice);
    }

    function _createComparableFlattenedBasket(address[] memory assets, uint256[] memory bundles)
        private
        returns (ComparableBasket memory result)
    {
        uint256[] memory balancesBefore = _balances(assets, alice);
        uint256 gasBefore = gasleft();
        (result.basketId, result.token) = _launchComparableBasket("Flattened Blend AI", "sFAI", assets, bundles);
        result.launchGas = gasBefore - gasleft();
        for (uint256 i; i < assets.length; ++i) {
            uint256 debit = balancesBefore[i] - IERC20(assets[i]).balanceOf(alice);
            result.normalizedSeedInput += Math.mulDiv(debit, 1 ether, bundles[i]);
        }
    }

    function _launchComparableBasket(
        string memory name,
        string memory symbol,
        address[] memory assets,
        uint256[] memory bundles
    ) private returns (uint256 basketId, address basketToken) {
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: name,
            symbol: symbol,
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
        IStaticsBasket.PoolLaunchParams[] memory pools = new IStaticsBasket.PoolLaunchParams[](assets.length);
        uint256[] memory maximums = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            pools[i] = IStaticsBasket.PoolLaunchParams({
                lpFee: 3_000,
                tickSpacing: 10,
                sqrtPriceAssetPerBasketX96: _semanticSqrtPrice(bundles[i]),
                pairedAssetAmount: bundles[i]
            });
            maximums[i] = IERC20(assets[i]).balanceOf(alice);
        }
        uint256 creationFee = basketAdmin.creationFee();
        vm.prank(alice);
        return baskets.createBasket{value: creationFee}(params, pools, maximums, block.timestamp + 1 hours);
    }

    function _measureRoundTrip(uint256 basketId, address basketToken) private returns (OperationResult memory result) {
        IStaticsBasket.BasketView memory configured = baskets.basket(basketId);
        uint256[] memory mintQuote = baskets.quoteMint(basketId, OPERATION_SHARES);
        vm.recordLogs();
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        baskets.mint(basketId, OPERATION_SHARES, alice, mintQuote);
        result.mintGas = gasBefore - gasleft();
        result.mintTransfers = _countTransfers(vm.getRecordedLogs(), configured.assets, alice, address(diamond));

        assertEq(IERC20(basketToken).balanceOf(alice), OPERATION_SHARES);
        uint256[] memory redemptionQuote = baskets.quoteRedeem(basketId, OPERATION_SHARES);
        vm.recordLogs();
        gasBefore = gasleft();
        vm.prank(alice);
        baskets.redeem(basketId, OPERATION_SHARES, alice, redemptionQuote);
        result.redemptionGas = gasBefore - gasleft();
        result.redemptionTransfers = _countTransfers(vm.getRecordedLogs(), configured.assets, address(diamond), alice);
        assertEq(IERC20(basketToken).balanceOf(alice), 0);
    }

    function _assertEquivalentTopology(
        ComparableBasket memory wrapped,
        ComparableBasket memory flattened,
        address[] memory constituents,
        uint256[] memory units
    ) private view {
        IStaticsBasket.BasketView memory wrappedConfig = baskets.basket(wrapped.basketId);
        IStaticsBasket.BasketView memory flattenedConfig = baskets.basket(flattened.basketId);
        assertEq(wrappedConfig.assets.length, 1);
        assertEq(wrappedConfig.assets[0], BLEND_AI);
        assertEq(wrappedConfig.bundleAmounts[0], 1 ether);
        assertEq(flattenedConfig.assets, constituents);
        assertEq(flattenedConfig.bundleAmounts, units);

        IStaticsBasketLiquidity.CanonicalPoolView memory wrappedPool =
            basketLiquidity.canonicalPool(wrapped.basketId, BLEND_AI);
        assertGt(staticsHook.lockedLiquidity(wrappedPool.poolId), 0);
        for (uint256 i; i < constituents.length; ++i) {
            IStaticsBasketLiquidity.CanonicalPoolView memory flattenedPool =
                basketLiquidity.canonicalPool(flattened.basketId, constituents[i]);
            assertGt(staticsHook.lockedLiquidity(flattenedPool.poolId), 0);
        }
    }

    function _blendUnits(IBlendCompositionBasket blend, address[] memory constituents)
        private
        view
        returns (uint256[] memory units)
    {
        units = new uint256[](constituents.length);
        for (uint256 i; i < constituents.length; ++i) {
            units[i] = blend.units(constituents[i]);
            assertGt(units[i], 0);
        }
    }

    function _semanticSqrtPrice(uint256 assetUnitsPerShare) private pure returns (uint160) {
        uint256 ratioRoot = Math.sqrt(assetUnitsPerShare * 1 ether);
        return uint160(Math.mulDiv(ratioRoot, 1 << 96, 1 ether));
    }

    function _balances(address[] memory tokens, address owner) private view returns (uint256[] memory result) {
        result = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            result[i] = IERC20(tokens[i]).balanceOf(owner);
        }
    }

    function _countTransfers(Vm.Log[] memory logs, address[] memory tokens, address from, address to)
        private
        pure
        returns (uint256 count)
    {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (
                entry.topics.length >= 3 && entry.topics[0] == TRANSFER_TOPIC
                    && address(uint160(uint256(entry.topics[1]))) == from
                    && address(uint160(uint256(entry.topics[2]))) == to && _contains(tokens, entry.emitter)
            ) ++count;
        }
    }

    function _contains(address[] memory tokens, address candidate) private pure returns (bool) {
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == candidate) return true;
        }
        return false;
    }
}
