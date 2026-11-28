// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PublicHookPolicyFacet} from "../facets/PublicHookPolicyFacet.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibDeploymentPhases} from "../libraries/LibDeploymentPhases.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";

/// @notice Atomic Phase 2 basket activation; no Dollar or Morpho initialization.
contract StaticsPublicHookReleaseInit is PublicHookPolicyFacet {
    function initialize(
        address basketHook,
        address basketTokenFactory,
        address manager,
        uint256 basketFee,
        uint256 flashFeeBps
    ) external {
        LibDiamond.enforceIsContractOwner();
        LibDeploymentPhases.initializePhaseTwo(basketFee, flashFeeBps);
        installBasketHook(basketHook, basketTokenFactory);
        _replaceManager(manager);
    }

    function _replaceManager(address manager) private {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        address previous = ls.manager;
        // Existing legs keep their recorded manager. Only future positions use this release.
        ls.manager = manager;
        emit IStaticsProtocolPools.LiquidityManagerReplaced(previous, manager);
    }
}
