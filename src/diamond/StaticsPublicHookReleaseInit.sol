// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PublicHookPolicyFacet} from "../facets/PublicHookPolicyFacet.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibDeploymentPhases} from "../libraries/LibDeploymentPhases.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {IStaticsPublicHookPolicy} from "../interfaces/IStaticsPublicHookPolicy.sol";
import {IStaticsLiquidityManager} from "../interfaces/IStaticsLiquidityManager.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";

/// @notice Atomic Phase 1 replacement and restricted-basket activation; no Dollar or Morpho initialization.
contract StaticsPublicHookReleaseInit is PublicHookPolicyFacet {
    error CreationGateMustRemainClosed();
    error InvalidReleaseManager(address manager);

    function initialize(
        address generalHook,
        address basketHook,
        address basketTokenFactory,
        address manager,
        uint256 basketFee,
        uint256 flashFeeBps
    ) external {
        LibDiamond.enforceIsContractOwner();
        if (LibProtocolPools.protocolPoolStorage().poolCreationFeeAmount != 0) revert CreationGateMustRemainClosed();
        LibDeploymentPhases.initializePhaseTwo(basketFee, flashFeeBps);
        installPublicHooks(generalHook, basketHook, basketTokenFactory);
        _replaceManager(manager);
        LibDiamond.diamondStorage().supportedInterfaces[type(IStaticsPublicHookPolicy).interfaceId] = true;
    }

    function _replaceManager(address manager) private {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        address previous = ls.manager;
        if (!ls.managerInstalled || previous.code.length == 0 || manager.code.length == 0 || manager == previous) {
            revert InvalidReleaseManager(manager);
        }
        IStaticsLiquidityManager oldBinding = IStaticsLiquidityManager(previous);
        IStaticsLiquidityManager newBinding = IStaticsLiquidityManager(manager);
        if (
            newBinding.staticsDiamond() != address(this) || newBinding.poolManager() != ls.poolManager
                || newBinding.positionManager() != oldBinding.positionManager()
                || newBinding.permit2() != oldBinding.permit2()
        ) {
            revert InvalidReleaseManager(manager);
        }
        // Existing legs keep their recorded manager. Only future positions use this release.
        ls.manager = manager;
        emit IStaticsProtocolPools.LiquidityManagerReplaced(previous, manager);
    }
}
