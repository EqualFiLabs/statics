// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IDiamondLoupe} from "../interfaces/IDiamondLoupe.sol";
import {IERC173} from "../interfaces/IERC173.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IStaticsBasketLiquidity} from "../interfaces/IStaticsBasketLiquidity.sol";

/// @notice Preflight the exact old topology in the same owner batch immediately before diamondCut.
contract StaticsPublicHookUpgradeGuard {
    error UpgradeSnapshotChanged(bytes32 expected, bytes32 actual);

    struct Route {
        bytes4 selector;
        address facet;
        bytes32 codeHash;
    }

    function snapshot(address diamond) public view returns (bytes32 commitment) {
        IDiamondLoupe.Facet[] memory facets = IDiamondLoupe(diamond).facets();
        uint256 count;
        for (uint256 i; i < facets.length; ++i) {
            count += facets[i].functionSelectors.length;
        }
        Route[] memory routes = new Route[](count);
        uint256 cursor;
        for (uint256 i; i < facets.length; ++i) {
            address facet = facets[i].facetAddress;
            for (uint256 j; j < facets[i].functionSelectors.length; ++j) {
                routes[cursor++] = Route(facets[i].functionSelectors[j], facet, facet.codehash);
            }
        }
        for (uint256 i = 1; i < count; ++i) {
            Route memory route = routes[i];
            uint256 j = i;
            while (j != 0 && uint32(routes[j - 1].selector) > uint32(route.selector)) {
                routes[j] = routes[j - 1];
                --j;
            }
            routes[j] = route;
        }
        (address manager, bool installed) = IStaticsBasketLiquidity(diamond).liquidityManager();
        (address poolManager, address legacyHook, bool integration) =
            IStaticsBasketLiquidity(diamond).liquidityIntegration();
        commitment = keccak256(
            abi.encode(
                block.chainid,
                diamond,
                IERC173(diamond).owner(),
                routes,
                IStaticsProtocolPools(diamond).poolCreationFee(),
                manager,
                installed,
                poolManager,
                legacyHook,
                integration
            )
        );
    }

    function assertSnapshot(address diamond, bytes32 expected) external view {
        bytes32 actual = snapshot(diamond);
        if (actual != expected) revert UpgradeSnapshotChanged(expected, actual);
    }
}
