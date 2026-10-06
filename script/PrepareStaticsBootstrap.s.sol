// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {BasketBootstrapFactory} from "../src/bootstrap/BasketBootstrapFactory.sol";
import {StaticsAssetZap} from "../src/periphery/StaticsAssetZap.sol";
import {BasketPreparationFacet} from "../src/facets/BasketPreparationFacet.sol";
import {StaticsBasketFactory} from "../src/liquidity/StaticsBasketFactory.sol";
import {IStaticsBasketLiquidity} from "../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsBasketDelegation} from "../src/interfaces/IStaticsBasketDelegation.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";

/// @notice Explicit deployment helper; this script neither broadcasts nor changes Diamond configuration.
contract PrepareStaticsBootstrap is Script {
    error InvalidBootstrapConfiguration();

    function deployPeriphery(address diamond, address wrappedNative, bytes32 expectedWrappedRuntimeHash)
        public
        returns (BasketBootstrapFactory factory, StaticsAssetZap zap)
    {
        if (
            diamond.code.length == 0 || wrappedNative.code.length == 0 || expectedWrappedRuntimeHash == bytes32(0)
                || wrappedNative.codehash != expectedWrappedRuntimeHash
                || IDiamondLoupe(diamond).facetAddress(IStaticsBasketDelegation.createBasketFor.selector) == address(0)
        ) {
            revert InvalidBootstrapConfiguration();
        }
        address basketFactory = BasketPreparationFacet(diamond).basketFactory();
        (address manager,, bool installed) = IStaticsBasketLiquidity(diamond).liquidityIntegration();
        if (
            !installed || basketFactory.code.length == 0 || manager.code.length == 0
                || StaticsBasketFactory(basketFactory).staticsDiamond() != diamond
                || address(StaticsBasketFactory(basketFactory).poolManager()) != manager
                || StaticsBasketFactory(basketFactory).VERSION() != 1
        ) revert InvalidBootstrapConfiguration();
        factory = new BasketBootstrapFactory(diamond);
        zap = new StaticsAssetZap(diamond, wrappedNative, factory);
    }
}
