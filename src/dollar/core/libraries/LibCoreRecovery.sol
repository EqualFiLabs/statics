// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IStaticsDollarRiskShares} from "../../interfaces/IStaticsDollarRiskShares.sol";
import {IStaticsDollarCoreTypes} from "../../interfaces/IStaticsDollarCoreTypes.sol";
import {LibCoreAccounting} from "./LibCoreAccounting.sol";
import {LibCoreStorage} from "./LibCoreStorage.sol";

library LibCoreRecovery {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant KEEPER_BOUNTY_BPS = 50;

    error EmptyPool();
    error DepositTooSmall();
    error RecoveryBookQuoteChanged(uint256 expectedGross, uint256 actualGross);

    event InsuranceDrawn(
        uint256 indexed profileId, uint256 indexed seriesId, address indexed collateralToken, uint256 amount
    );

    function drawAvailableInsurance(
        LibCoreStorage.CS storage cs,
        uint256 seriesId,
        IStaticsDollarCoreTypes.RiskSeries storage series,
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile,
        uint256 priceWad
    ) internal returns (uint256 amount) {
        uint256 required = LibCoreAccounting.seniorReserveCollateral(
            series.seniorOutstanding, priceWad, profile.decimals
        );
        if (required <= series.accountedCollateral) return 0;
        uint256 shortfall = required - series.accountedCollateral;
        amount = shortfall < profile.insuranceReserve ? shortfall : profile.insuranceReserve;
        if (amount == 0) return 0;
        profile.insuranceReserve -= amount;
        profile.accountedCollateral += amount;
        series.accountedCollateral += amount;
        emit InsuranceDrawn(series.profileId, seriesId, series.collateralToken, amount);
        LibCoreAccounting.enforceCustody(cs, series.collateralToken);
    }

    function partitionReturned(
        LibCoreStorage.CS storage cs,
        uint256 seriesId,
        IStaticsDollarCoreTypes.RiskSeries storage series,
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile,
        IStaticsDollarCoreTypes.SeriesRecoveryState storage recovery,
        uint256 priceWad
    ) internal {
        uint256 returned = recovery.returnedShares;
        if (returned == 0) return;
        uint256 totalShares = series.riskSharesOutstanding;
        if (returned > totalShares || returned > series.seniorOutstanding) revert EmptyPool();
        uint256 gross = returned == totalShares
            ? series.accountedCollateral
            : Math.mulDiv(series.accountedCollateral, returned, totalShares);
        uint256 totalSeniorReserve =
            LibCoreAccounting.seniorReserveCollateral(series.seniorOutstanding, priceWad, profile.decimals);
        if (totalSeniorReserve > series.accountedCollateral) totalSeniorReserve = series.accountedCollateral;
        uint256 seniorCollateral =
            returned == totalShares ? totalSeniorReserve : Math.mulDiv(totalSeniorReserve, returned, totalShares);

        series.seniorOutstanding -= returned;
        series.riskSharesOutstanding -= returned;
        series.accountedCollateral -= gross;
        recovery.seniorRecoveryOutstanding = returned;
        recovery.seniorRecoveryCollateral = seniorCollateral;
        recovery.juniorRecoveryShares = returned;
        recovery.juniorRecoveryCollateral = gross - seniorCollateral;
        IStaticsDollarRiskShares(cs.staticsDollarRisk).burn(address(this), seriesId, returned);
    }

    function snapshotExpiredBook(
        LibCoreStorage.CS storage cs,
        uint256 seriesId,
        IStaticsDollarCoreTypes.RiskSeries storage series,
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile,
        uint256 priceWad
    ) internal {
        uint256 seniorCollateral =
            LibCoreAccounting.seniorReserveCollateral(series.seniorOutstanding, priceWad, profile.decimals);
        if (seniorCollateral > series.accountedCollateral) seniorCollateral = series.accountedCollateral;
        uint256 juniorCollateral = series.accountedCollateral - seniorCollateral;
        cs.expiredRecoveryBook[seriesId] = LibCoreStorage.ExpiredRecoveryBook({
            remainingShares: series.seniorOutstanding,
            remainingCollateral: series.accountedCollateral,
            remainingSeniorCollateral: seniorCollateral,
            remainingBountyCollateral: Math.mulDiv(juniorCollateral, KEEPER_BOUNTY_BPS, BPS)
        });
    }

    function openSeries(
        LibCoreStorage.CS storage cs,
        uint256 seriesId,
        uint256 profileId,
        uint256 priceWad,
        uint256 ratioBps,
        uint256 bandBps
    ) internal {
        uint256 collateralPerPairWad = Math.mulDiv(Math.mulDiv(WAD, ratioBps, BPS), WAD, priceWad);
        if (collateralPerPairWad == 0) revert DepositTooSmall();
        uint256 seniorCollateralPerUnitWad = Math.mulDiv(WAD, WAD, priceWad);
        cs.riskSeries[seriesId] = IStaticsDollarCoreTypes.RiskSeries({
            profileId: profileId,
            collateralToken: cs.collateralProfiles[profileId].collateralToken,
            seniorOutstanding: 0,
            riskSharesOutstanding: 0,
            accountedCollateral: 0,
            startPriceWad: priceWad,
            collateralPerPairWad: collateralPerPairWad,
            seniorCollateralPerUnitWad: seniorCollateralPerUnitWad,
            juniorCollateralPerUnitWad: collateralPerPairWad - seniorCollateralPerUnitWad,
            collateralRatioBps: ratioBps,
            priceBandBps: bandBps,
            startedAt: block.timestamp,
            retiredAt: 0,
            successorSeriesId: 0,
            status: IStaticsDollarCoreTypes.SeriesStatus.Active
        });
        cs.profileSeries[profileId].push(seriesId);
    }

    function sharesForCollateral(uint256 rawCollateral, uint8 decimals, uint256 collateralPerPairWad)
        internal
        pure
        returns (uint256)
    {
        if (rawCollateral == 0) return 0;
        return Math.mulDiv(LibCoreAccounting.toWad(rawCollateral, decimals), WAD, collateralPerPairWad);
    }

    function collateralForShares(uint256 shares, uint8 decimals, uint256 collateralPerPairWad)
        internal
        pure
        returns (uint256)
    {
        if (shares == 0) return 0;
        return
            LibCoreAccounting.fromWadCeil(Math.mulDiv(shares, collateralPerPairWad, WAD, Math.Rounding.Ceil), decimals);
    }

    function proRata(uint256 remainingAmount, uint256 shares, uint256 remainingShares) internal pure returns (uint256) {
        if (shares == remainingShares) return remainingAmount;
        return Math.mulDiv(remainingAmount, shares, remainingShares);
    }

    function expiredBookSlice(LibCoreStorage.ExpiredRecoveryBook storage book, uint256 shares)
        internal
        view
        returns (uint256 gross, uint256 senior, uint256 bounty)
    {
        uint256 remainingShares = book.remainingShares;
        if (shares == 0 || remainingShares == 0 || shares > remainingShares) revert EmptyPool();
        gross = proRata(book.remainingCollateral, shares, remainingShares);
        senior = proRata(book.remainingSeniorCollateral, shares, remainingShares);
        bounty = proRata(book.remainingBountyCollateral, shares, remainingShares);

        uint256 junior = gross - senior;
        uint256 juniorAfter = (book.remainingCollateral - gross) - (book.remainingSeniorCollateral - senior);
        uint256 minimumBounty =
            book.remainingBountyCollateral > juniorAfter ? book.remainingBountyCollateral - juniorAfter : 0;
        if (bounty < minimumBounty) bounty = minimumBounty;
        if (bounty > junior) bounty = junior;
    }

    function consumeExpiredBook(LibCoreStorage.ExpiredRecoveryBook storage book, uint256 shares, uint256 expectedGross)
        internal
        returns (uint256 gross, uint256 senior, uint256 bounty)
    {
        (gross, senior, bounty) = expiredBookSlice(book, shares);
        if (gross != expectedGross) revert RecoveryBookQuoteChanged(expectedGross, gross);

        book.remainingShares -= shares;
        book.remainingCollateral -= gross;
        book.remainingSeniorCollateral -= senior;
        book.remainingBountyCollateral -= bounty;
    }

    function closeIfEmpty(LibCoreStorage.CS storage cs, uint256 seriesId) internal returns (bool closed) {
        IStaticsDollarCoreTypes.RiskSeries storage series = cs.riskSeries[seriesId];
        IStaticsDollarCoreTypes.SeriesRecoveryState storage recovery = cs.seriesRecovery[seriesId];
        LibCoreStorage.ExpiredRecoveryBook storage book = cs.expiredRecoveryBook[seriesId];
        if (
            series.seniorOutstanding == 0 && series.riskSharesOutstanding == 0 && series.accountedCollateral == 0
                && recovery.seniorRecoveryOutstanding == 0 && recovery.seniorRecoveryCollateral == 0
                && recovery.juniorRecoveryShares == 0 && recovery.juniorRecoveryCollateral == 0
                && book.remainingShares == 0 && book.remainingCollateral == 0 && book.remainingSeniorCollateral == 0
                && book.remainingBountyCollateral == 0
        ) {
            series.status = IStaticsDollarCoreTypes.SeriesStatus.Closed;
            return true;
        }
    }
}
