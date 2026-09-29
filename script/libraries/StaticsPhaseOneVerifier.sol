// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {StaticsInterfaceInit} from "../../src/diamond/StaticsInterfaceInit.sol";
import {BasketAdminFacet} from "../../src/facets/BasketAdminFacet.sol";
import {BasketLiquidityFacet} from "../../src/facets/BasketLiquidityFacet.sol";
import {CustodyFacet} from "../../src/facets/CustodyFacet.sol";
import {DiamondCutFacet} from "../../src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/facets/DiamondLoupeFacet.sol";
import {GaugeIncentiveFacet} from "../../src/facets/GaugeIncentiveFacet.sol";
import {GaugeIncentiveViewFacet} from "../../src/facets/GaugeIncentiveViewFacet.sol";
import {GlobalRewardsFacet} from "../../src/facets/GlobalRewardsFacet.sol";
import {GovernanceFacet} from "../../src/facets/GovernanceFacet.sol";
import {OwnershipFacet} from "../../src/facets/OwnershipFacet.sol";
import {PermissionedPoolAdminFacet} from "../../src/facets/PermissionedPoolAdminFacet.sol";
import {PermissionedPoolCreationFacet} from "../../src/facets/PermissionedPoolCreationFacet.sol";
import {PermissionedPoolViewFacet} from "../../src/facets/PermissionedPoolViewFacet.sol";
import {ProtocolPoolAdminFacet} from "../../src/facets/ProtocolPoolAdminFacet.sol";
import {ProtocolPoolMaintenanceFacet} from "../../src/facets/ProtocolPoolMaintenanceFacet.sol";
import {ProtocolPolFacet} from "../../src/facets/ProtocolPolFacet.sol";
import {ProtocolPoolCreationFacet} from "../../src/facets/ProtocolPoolCreationFacet.sol";
import {ProtocolPoolViewFacet} from "../../src/facets/ProtocolPoolViewFacet.sol";
import {ProtocolRevenueFacet} from "../../src/facets/ProtocolRevenueFacet.sol";
import {RangeGaugeCallbackFacet} from "../../src/facets/RangeGaugeCallbackFacet.sol";
import {MarketTapeViewFacet} from "../../src/facets/MarketTapeViewFacet.sol";
import {MarketTapeObservationFacet} from "../../src/facets/MarketTapeObservationFacet.sol";
import {RangeGaugeFacet} from "../../src/facets/RangeGaugeFacet.sol";
import {RangeGaugeLivenessFacet} from "../../src/facets/RangeGaugeLivenessFacet.sol";
import {RangeGaugePositionFacet} from "../../src/facets/RangeGaugePositionFacet.sol";
import {RangeGaugePositionManagementFacet} from "../../src/facets/RangeGaugePositionManagementFacet.sol";
import {RangeGaugeViewFacet} from "../../src/facets/RangeGaugeViewFacet.sol";
import {RewardPolicyFacet} from "../../src/facets/RewardPolicyFacet.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";
import {PositionNFTFacet} from "../../src/position/PositionNFTFacet.sol";

/// @notice Exact Phase 1 selector-route and facet-runtime verification shared by deployment ceremonies.
library StaticsPhaseOneVerifier {
    error InvalidFacet(address facet, bytes32 expected, bytes32 actual);
    error InvalidFacetRoute(bytes4 selector, address expected, address actual);

    function validateRuntimes(address diamond) internal view {
        _validateFacetSet(diamond, StaticsSelectors.diamondCut(), keccak256(type(DiamondCutFacet).runtimeCode));
        _validateFacetSet(diamond, StaticsSelectors.diamondLoupe(), keccak256(type(DiamondLoupeFacet).runtimeCode));
        _validateFacetSet(diamond, StaticsSelectors.ownership(), keccak256(type(OwnershipFacet).runtimeCode));
        _validateFacetSet(diamond, StaticsSelectors.phaseOneGovernance(), keccak256(type(GovernanceFacet).runtimeCode));
        _validateFacetSet(diamond, StaticsSelectors.position(), keccak256(type(PositionNFTFacet).runtimeCode));
        _validateFacetSet(diamond, StaticsSelectors.phaseOneCustody(), keccak256(type(CustodyFacet).runtimeCode));
        _validateFacetSet(
            diamond, StaticsSelectors.phaseOneTreasuryAdmin(), keccak256(type(BasketAdminFacet).runtimeCode)
        );
        _validateFacetSet(
            diamond, StaticsSelectors.phaseOneLiquidityIntegration(), keccak256(type(BasketLiquidityFacet).runtimeCode)
        );
        _validateFacetSet(diamond, StaticsSelectors.globalRewards(), keccak256(type(GlobalRewardsFacet).runtimeCode));
        _validateFacetSet(diamond, StaticsSelectors.interfaceInit(), keccak256(type(StaticsInterfaceInit).runtimeCode));
        _validateFacetSet(
            diamond, StaticsSelectors.protocolPoolCreation(), keccak256(type(ProtocolPoolCreationFacet).runtimeCode)
        );
        _validateFacetSet(
            diamond, StaticsSelectors.phaseOneProtocolPoolAdmin(), keccak256(type(ProtocolPoolAdminFacet).runtimeCode)
        );
        _validateFacetSet(
            diamond,
            StaticsSelectors.protocolPoolMaintenance(),
            keccak256(type(ProtocolPoolMaintenanceFacet).runtimeCode)
        );
        _validateFacetSet(diamond, StaticsSelectors.protocolPol(), keccak256(type(ProtocolPolFacet).runtimeCode));
        _validateFacetSet(
            diamond, StaticsSelectors.phaseOneProtocolPoolView(), keccak256(type(ProtocolPoolViewFacet).runtimeCode)
        );
        _validateFacetSet(
            diamond, StaticsSelectors.phaseOneProtocolRevenue(), keccak256(type(ProtocolRevenueFacet).runtimeCode)
        );
        _validateFacetSet(diamond, StaticsSelectors.rewardPolicy(), keccak256(type(RewardPolicyFacet).runtimeCode));
        _validateFacetSet(
            diamond,
            StaticsSelectors.permissionedPoolCreation(),
            keccak256(type(PermissionedPoolCreationFacet).runtimeCode)
        );
        _validateFacetSet(
            diamond, StaticsSelectors.permissionedPoolAdmin(), keccak256(type(PermissionedPoolAdminFacet).runtimeCode)
        );
        _validateFacetSet(
            diamond, StaticsSelectors.permissionedPoolView(), keccak256(type(PermissionedPoolViewFacet).runtimeCode)
        );
        _validateFacetSet(diamond, StaticsSelectors.rangeGaugeActions(), keccak256(type(RangeGaugeFacet).runtimeCode));
        _validateFacetSet(
            diamond, StaticsSelectors.rangeGaugePositionIngress(), keccak256(type(RangeGaugePositionFacet).runtimeCode)
        );
        _validateFacetSet(
            diamond,
            StaticsSelectors.rangeGaugePositionManagement(),
            keccak256(type(RangeGaugePositionManagementFacet).runtimeCode)
        );
        _validateFacetSet(
            diamond, StaticsSelectors.rangeGaugeLiveness(), keccak256(type(RangeGaugeLivenessFacet).runtimeCode)
        );
        _validateFacetSet(diamond, StaticsSelectors.rangeGaugeViews(), keccak256(type(RangeGaugeViewFacet).runtimeCode));
        _validateFacetSet(
            diamond, StaticsSelectors.rangeGaugeCallback(), keccak256(type(RangeGaugeCallbackFacet).runtimeCode)
        );
        _validateFacetSet(diamond, StaticsSelectors.marketTapeViews(), keccak256(type(MarketTapeViewFacet).runtimeCode));
        _validateFacetSet(
            diamond, StaticsSelectors.marketTapeObservations(), keccak256(type(MarketTapeObservationFacet).runtimeCode)
        );
        _validateFacetSet(
            diamond, StaticsSelectors.gaugeIncentiveActions(), keccak256(type(GaugeIncentiveFacet).runtimeCode)
        );
        _validateFacetSet(
            diamond, StaticsSelectors.gaugeIncentiveViews(), keccak256(type(GaugeIncentiveViewFacet).runtimeCode)
        );
    }

    function _validateFacetSet(address diamond, bytes4[] memory selectors, bytes32 expectedHash) private view {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        address facet = loupe.facetAddress(selectors[0]);
        bytes32 actualHash = facet.codehash;
        if (facet == address(0) || actualHash != expectedHash) revert InvalidFacet(facet, expectedHash, actualHash);
        for (uint256 i = 1; i < selectors.length; ++i) {
            address actual = loupe.facetAddress(selectors[i]);
            if (actual != facet) revert InvalidFacetRoute(selectors[i], facet, actual);
        }
    }
}
