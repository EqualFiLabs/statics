// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IStaticsDollarCoreTypes} from "../../interfaces/IStaticsDollarCoreTypes.sol";
import {IStaticsDollarRiskIncentives} from "../../interfaces/IStaticsDollarRiskIncentives.sol";
import {IStaticsDollarCore} from "../../core/interfaces/IStaticsDollarCore.sol";
import {LibCustody} from "../../../libraries/LibCustody.sol";
import {LibGlobalRewards} from "../../../libraries/LibGlobalRewards.sol";
import {LibPeriphery} from "./LibPeriphery.sol";

library LibRiskLiquidity {
    error SeriesIncentivesNotFinalizable(uint256 seriesId);
    error UnknownRiskLiquidity(uint256 positionId, uint256 seriesId);
    error UnexpectedRiskIngressState();

    function finalizeIncentives(
        LibPeriphery.PS storage ps,
        uint256 seriesId,
        IStaticsDollarCoreTypes.RiskSeries memory series
    ) internal returns (uint256 destinationSeriesId, bool routedGlobal) {
        LibPeriphery.SeriesBook storage book = ps.series[seriesId];
        if (book.incentivesFinalized) {
            return (book.incentiveDestinationSeriesId, book.incentivesRoutedGlobal);
        }

        IStaticsDollarCore core = IStaticsDollarCore(ps.pool);
        IStaticsDollarCoreTypes.StableCollateralProfile memory profile = core.collateralProfile(series.profileId);
        if (profile.mode != IStaticsDollarCoreTypes.ProfileMode.Retired) {
            destinationSeriesId = profile.activeSeriesId;
            if (
                (series.status != IStaticsDollarCoreTypes.SeriesStatus.Recoverable
                        && series.status != IStaticsDollarCoreTypes.SeriesStatus.Closed)
                    || destinationSeriesId == seriesId
                    || core.riskSeries(destinationSeriesId).status != IStaticsDollarCoreTypes.SeriesStatus.Active
            ) {
                revert SeriesIncentivesNotFinalizable(seriesId);
            }
        } else if (
            series.status != IStaticsDollarCoreTypes.SeriesStatus.Recoverable
                && series.status != IStaticsDollarCoreTypes.SeriesStatus.Retired
                && series.status != IStaticsDollarCoreTypes.SeriesStatus.Closed
        ) {
            revert SeriesIncentivesNotFinalizable(seriesId);
        }

        uint256 collateralAmount = book.collateralIncentiveReserve;
        uint256 staticsDollarAmount = book.staticsDollarIncentiveReserve;
        uint256 staticsAmount = book.staticsIncentiveReserve;
        book.collateralIncentiveReserve = 0;
        book.staticsDollarIncentiveReserve = 0;
        book.staticsIncentiveReserve = 0;
        book.incentiveDestinationSeriesId = destinationSeriesId;
        routedGlobal = profile.mode == IStaticsDollarCoreTypes.ProfileMode.Retired;
        book.incentivesRoutedGlobal = routedGlobal;
        book.incentivesFinalized = true;

        if (routedGlobal) {
            _routeGlobal(ps, series.collateralToken, collateralAmount);
            _routeGlobal(ps, ps.staticsDollar, staticsDollarAmount);
            _routeGlobal(ps, ps.staticsToken, staticsAmount);
            emit IStaticsDollarRiskIncentives.RiskIncentivesRoutedGlobal(
                seriesId, collateralAmount, staticsDollarAmount, staticsAmount
            );
        } else {
            LibPeriphery.SeriesBook storage destination = ps.series[destinationSeriesId];
            destination.collateralIncentiveReserve += collateralAmount;
            destination.staticsDollarIncentiveReserve += staticsDollarAmount;
            destination.staticsIncentiveReserve += staticsAmount;
            emit IStaticsDollarRiskIncentives.RiskIncentivesRolledOver(
                seriesId, destinationSeriesId, collateralAmount, staticsDollarAmount, staticsAmount
            );
        }
    }

    function leg(LibPeriphery.PS storage ps, uint256 positionId, uint256 seriesId)
        internal
        view
        returns (LibPeriphery.PositionLeg storage leg_)
    {
        leg_ = ps.leg[positionId][seriesId];
        if (!leg_.exists) revert UnknownRiskLiquidity(positionId, seriesId);
    }

    function expectIngress(LibPeriphery.PS storage ps, address operator, address from, uint256 seriesId, uint256 amount)
        internal
    {
        if (amount == 0) return;
        if (ps.expectedRiskIngress.active) revert UnexpectedRiskIngressState();
        ps.expectedRiskIngress = LibPeriphery.ExpectedRiskIngress({
            operator: operator, from: from, seriesId: seriesId, amount: amount, active: true
        });
    }

    function requireIngressConsumed(LibPeriphery.PS storage ps) internal view {
        if (ps.expectedRiskIngress.active) revert UnexpectedRiskIngressState();
    }

    function _routeGlobal(LibPeriphery.PS storage ps, address token, uint256 amount) private {
        if (amount == 0) return;
        ps.reservedByToken[token] -= amount;
        LibGlobalRewards.accrueNonSwapFee(LibCustody.dollarAccount(), token, amount);
    }
}
