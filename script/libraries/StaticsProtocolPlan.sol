// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";

/// @dev Addresses for every facet in the complete Statics Diamond. A phase deployment only
/// populates the fields it installs or extends. The complete deployment and every staged cut use
/// this same struct and the same cut builders so selector ownership cannot drift between paths.
struct StaticsProtocolParts {
    address cut;
    address loupe;
    address ownership;
    address governance;
    address position;
    address positionPortfolio;
    address custody;
    address basketCreation;
    address basketMint;
    address basketRedemption;
    address basketView;
    address basketCollateral;
    address basketRewards;
    address globalRewards;
    address basketAdmin;
    address basketLiquidity;
    address basketLiquidityLifecycle;
    address borrowLiquidity;
    address lending;
    address flashLoan;
    address interfaceInit;
    address dollarStaking;
    address seriesMigration;
    address feeRouter;
    address pairingVault;
    address dollarGateway;
    address init;
    address protocolPoolCreation;
    address protocolPoolAdmin;
    address protocolPoolView;
    address protocolRevenue;
    address genesisNFT;
    address morphoActions;
    address morphoRecovery;
    address morphoSettlement;
    address morphoAdmin;
    address morphoView;
}

/// @notice Canonical selector-to-phase assignment for both fresh and staged deployments.
library StaticsProtocolPlan {
    uint8 internal constant PHASE_ONE = 1;
    uint8 internal constant PHASE_TWO = 2;
    uint8 internal constant PHASE_THREE = 3;
    uint8 internal constant PHASE_FOUR = 4;

    error InvalidPhase(uint256 phase);

    function phaseOne(StaticsProtocolParts memory parts) internal pure returns (IDiamondCut.FacetCut[] memory cut) {
        cut = new IDiamondCut.FacetCut[](14);
        cut[0] = _add(parts.cut, StaticsSelectors.diamondCut());
        cut[1] = _add(parts.loupe, StaticsSelectors.diamondLoupe());
        cut[2] = _add(parts.ownership, StaticsSelectors.ownership());
        cut[3] = _add(parts.governance, StaticsSelectors.phaseOneGovernance());
        cut[4] = _add(parts.position, StaticsSelectors.position());
        cut[5] = _add(parts.custody, StaticsSelectors.phaseOneCustody());
        cut[6] = _add(parts.basketAdmin, StaticsSelectors.phaseOneTreasuryAdmin());
        cut[7] = _add(parts.basketLiquidity, StaticsSelectors.phaseOneLiquidityIntegration());
        cut[8] = _add(parts.globalRewards, StaticsSelectors.globalRewards());
        cut[9] = _add(parts.interfaceInit, StaticsSelectors.interfaceInit());
        cut[10] = _add(parts.protocolPoolCreation, StaticsSelectors.protocolPoolCreation());
        cut[11] = _add(parts.protocolPoolAdmin, StaticsSelectors.phaseOneProtocolPoolAdmin());
        cut[12] = _add(parts.protocolPoolView, StaticsSelectors.phaseOneProtocolPoolView());
        cut[13] = _add(parts.protocolRevenue, StaticsSelectors.phaseOneProtocolRevenue());
    }

    function phaseTwo(StaticsProtocolParts memory parts) internal pure returns (IDiamondCut.FacetCut[] memory cut) {
        cut = new IDiamondCut.FacetCut[](19);
        cut[0] = _add(parts.governance, StaticsSelectors.phaseTwoGovernance());
        cut[1] = _add(parts.custody, StaticsSelectors.phaseTwoCustody());
        cut[2] = _add(parts.basketAdmin, StaticsSelectors.phaseTwoBasketAdmin());
        cut[3] = _add(parts.basketLiquidity, StaticsSelectors.phaseTwoBasketLiquidity());
        cut[4] = _add(parts.protocolPoolAdmin, StaticsSelectors.phaseTwoProtocolPoolAdmin());
        cut[5] = _add(parts.protocolPoolView, StaticsSelectors.phaseTwoProtocolPoolView());
        cut[6] = _add(parts.protocolRevenue, StaticsSelectors.phaseTwoProtocolRevenue());
        cut[7] = _add(parts.positionPortfolio, StaticsSelectors.phaseTwoPositionPortfolio());
        cut[8] = _add(parts.basketCreation, StaticsSelectors.basketCreation());
        cut[9] = _add(parts.basketMint, StaticsSelectors.basketMint());
        cut[10] = _add(parts.basketRedemption, StaticsSelectors.basketRedemption());
        cut[11] = _add(parts.basketView, StaticsSelectors.basketView());
        cut[12] = _add(parts.basketCollateral, StaticsSelectors.basketCollateral());
        cut[13] = _add(parts.basketRewards, StaticsSelectors.basketRewards());
        cut[14] = _add(parts.basketLiquidityLifecycle, StaticsSelectors.basketLiquidityLifecycle());
        cut[15] = _add(parts.lending, StaticsSelectors.lending());
        cut[16] = _add(parts.flashLoan, StaticsSelectors.flashLoan());
        cut[17] = _add(parts.genesisNFT, StaticsSelectors.genesisNFT());
        cut[18] = _add(parts.borrowLiquidity, StaticsSelectors.borrowLiquidity());
    }

    function phaseThree(StaticsProtocolParts memory parts) internal pure returns (IDiamondCut.FacetCut[] memory cut) {
        cut = new IDiamondCut.FacetCut[](7);
        cut[0] = _add(parts.custody, StaticsSelectors.phaseThreeCustody());
        cut[1] = _add(parts.positionPortfolio, StaticsSelectors.phaseThreePositionPortfolio());
        cut[2] = _add(parts.dollarStaking, StaticsSelectors.dollarStaking());
        cut[3] = _add(parts.feeRouter, StaticsSelectors.dollarFeeRouter());
        cut[4] = _add(parts.pairingVault, StaticsSelectors.dollarPairingVault());
        cut[5] = _add(parts.dollarGateway, StaticsSelectors.dollarGateway());
        cut[6] = _add(parts.seriesMigration, StaticsSelectors.dollarSeriesMigration());
    }

    function phaseFour(StaticsProtocolParts memory parts) internal pure returns (IDiamondCut.FacetCut[] memory cut) {
        cut = new IDiamondCut.FacetCut[](6);
        cut[0] = _add(parts.positionPortfolio, StaticsSelectors.phaseFourPositionPortfolio());
        cut[1] = _add(parts.morphoAdmin, StaticsSelectors.morphoAdmin());
        cut[2] = _add(parts.morphoActions, StaticsSelectors.morphoActions());
        cut[3] = _add(parts.morphoSettlement, StaticsSelectors.morphoSettlement());
        cut[4] = _add(parts.morphoView, StaticsSelectors.morphoView());
        cut[5] = _add(parts.morphoRecovery, StaticsSelectors.morphoRecovery());
    }

    function cumulative(StaticsProtocolParts memory parts, uint8 throughPhase)
        internal
        pure
        returns (IDiamondCut.FacetCut[] memory cut)
    {
        if (throughPhase == 0 || throughPhase > PHASE_FOUR) revert InvalidPhase(throughPhase);
        IDiamondCut.FacetCut[] memory one = phaseOne(parts);
        IDiamondCut.FacetCut[] memory two = throughPhase >= PHASE_TWO ? phaseTwo(parts) : new IDiamondCut.FacetCut[](0);
        IDiamondCut.FacetCut[] memory three =
            throughPhase >= PHASE_THREE ? phaseThree(parts) : new IDiamondCut.FacetCut[](0);
        IDiamondCut.FacetCut[] memory four =
            throughPhase >= PHASE_FOUR ? phaseFour(parts) : new IDiamondCut.FacetCut[](0);
        cut = new IDiamondCut.FacetCut[](one.length + two.length + three.length + four.length);
        uint256 cursor = _copy(one, cut, 0);
        cursor = _copy(two, cut, cursor);
        cursor = _copy(three, cut, cursor);
        _copy(four, cut, cursor);
    }

    function selectorCount(IDiamondCut.FacetCut[] memory cut) internal pure returns (uint256 count) {
        for (uint256 i; i < cut.length; ++i) {
            count += cut[i].functionSelectors.length;
        }
    }

    function _add(address facet, bytes4[] memory selectors) private pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({
            facetAddress: facet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
    }

    function _copy(IDiamondCut.FacetCut[] memory source, IDiamondCut.FacetCut[] memory destination, uint256 cursor)
        private
        pure
        returns (uint256)
    {
        for (uint256 i; i < source.length; ++i) {
            destination[cursor++] = source[i];
        }
        return cursor;
    }
}
