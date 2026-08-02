// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IStaticsDollarCoreTypes} from "../../interfaces/IStaticsDollarCoreTypes.sol";
import {IUsdOracle} from "../../interfaces/IUsdOracle.sol";
import {LibCoreStorage} from "./LibCoreStorage.sol";
import {LibSolvencyIndex} from "./LibSolvencyIndex.sol";

library LibCoreHealth {
    using LibSolvencyIndex for LibSolvencyIndex.Tree;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant GLOBAL_RECOVERY_DELAY = 48 hours;

    event GlobalHealthSynced(
        IStaticsDollarCoreTypes.GlobalHealthPhase phase,
        uint256 unhealthyProfileBitmap,
        uint256 totalSeniorDeficitWad,
        uint256 recoveryAvailableAt
    );

    function profileSolvency(
        LibCoreStorage.CS storage cs,
        uint256 profileId,
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile
    ) internal view returns (IStaticsDollarCoreTypes.ProfileSolvency memory solvency) {
        solvency.seniorLiabilitiesWad = profile.seniorOutstanding;
        if (solvency.seniorLiabilitiesWad == 0) {
            solvency.oracleAvailable = true;
            solvency.healthy = true;
            return solvency;
        }

        (bool priceAvailable, uint256 priceWad) = tryPrice(profile.oracle);
        if (!priceAvailable || priceWad == 0) return solvency;

        (bool balanceAvailable, uint256 actualBalance) = tryBalance(profile.collateralToken);
        if (!balanceAvailable) return solvency;
        solvency.oracleAvailable = true;

        uint256 recordedSupportingCollateral = profile.accountedCollateral + profile.insuranceReserve;
        uint256 custodySupportingCollateral =
            actualBalance < recordedSupportingCollateral ? actualBalance : recordedSupportingCollateral;
        (bool normalized, uint256 custodySupportingWad) = toWad(custodySupportingCollateral, profile.decimals);
        if (!normalized) {
            solvency.oracleAvailable = false;
            return solvency;
        }
        solvency.collateralValueWad = valueWad(custodySupportingWad, priceWad);

        uint256 aggregateDeficit = solvency.seniorLiabilitiesWad > solvency.collateralValueWad
            ? solvency.seniorLiabilitiesWad - solvency.collateralValueWad
            : 0;
        (uint256 indexedSeriesDeficit,,,) = cs.solvencyIndex[profileId].deficitAt(priceWad);
        uint256 custodyInsuranceCollateral = custodySupportingCollateral > profile.accountedCollateral
            ? custodySupportingCollateral - profile.accountedCollateral
            : 0;
        (normalized, custodySupportingWad) = toWad(custodyInsuranceCollateral, profile.decimals);
        if (!normalized) {
            solvency.oracleAvailable = false;
            solvency.collateralValueWad = 0;
            return solvency;
        }
        uint256 insuranceValueWad = valueWad(custodySupportingWad, priceWad);
        uint256 seriesDeficitAfterInsurance =
            indexedSeriesDeficit > insuranceValueWad ? indexedSeriesDeficit - insuranceValueWad : 0;

        uint256 missingAccountedCollateral =
            actualBalance < profile.accountedCollateral ? profile.accountedCollateral - actualBalance : 0;
        (normalized, custodySupportingWad) = toWad(missingAccountedCollateral, profile.decimals);
        if (!normalized) {
            solvency.oracleAvailable = false;
            solvency.collateralValueWad = 0;
            return solvency;
        }
        uint256 missingAccountedValueWad = valueWad(custodySupportingWad, priceWad);
        uint256 isolatedCustodyDeficit = saturatingAdd(seriesDeficitAfterInsurance, missingAccountedValueWad);

        solvency.seniorDeficitWad =
            aggregateDeficit > isolatedCustodyDeficit ? aggregateDeficit : isolatedCustodyDeficit;
        solvency.healthy = solvency.seniorDeficitWad == 0;
    }

    function currentGlobalHealth(LibCoreStorage.CS storage cs)
        internal
        view
        returns (IStaticsDollarCoreTypes.GlobalHealthPhase phase, uint256 unhealthyBitmap, uint256 totalDeficitWad)
    {
        bool unavailable;
        phase = IStaticsDollarCoreTypes.GlobalHealthPhase.Healthy;
        for (uint256 profileId = 1; profileId < cs.nextProfileId; ++profileId) {
            IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[profileId];
            if (profile.collateralToken == address(0)) continue;
            IStaticsDollarCoreTypes.ProfileSolvency memory solvency = profileSolvency(cs, profileId, profile);
            if (solvency.healthy) continue;
            unhealthyBitmap |= uint256(1) << profileId;
            totalDeficitWad = saturatingAdd(totalDeficitWad, solvency.seniorDeficitWad);
            if (!solvency.oracleAvailable) unavailable = true;
        }
        if (unhealthyBitmap != 0) {
            phase = unavailable
                ? IStaticsDollarCoreTypes.GlobalHealthPhase.Unavailable
                : IStaticsDollarCoreTypes.GlobalHealthPhase.Impaired;
        }
    }

    function checkpointGlobalHealth(LibCoreStorage.CS storage cs, bool emitHealthy)
        internal
        returns (
            IStaticsDollarCoreTypes.ExitStatus status,
            uint256 unhealthyBitmap,
            uint256 totalDeficitWad,
            uint256 recoveryAvailableAt
        )
    {
        (IStaticsDollarCoreTypes.GlobalHealthPhase phase, uint256 bitmap, uint256 deficit) = currentGlobalHealth(cs);
        bool wasLatched = cs.globalImpairmentLatched;
        unhealthyBitmap = bitmap;
        totalDeficitWad = deficit;
        if (phase != IStaticsDollarCoreTypes.GlobalHealthPhase.Healthy) {
            cs.globalImpairmentLatched = true;
            cs.globalRecoveryStartedAt = 0;
            cs.peggedRedemptionLatched = true;
            cs.peggedRecoveryStartedAt = 0;
            status = phase == IStaticsDollarCoreTypes.GlobalHealthPhase.Unavailable
                ? IStaticsDollarCoreTypes.ExitStatus.HealthUnavailable
                : IStaticsDollarCoreTypes.ExitStatus.Impaired;
        } else if (cs.globalImpairmentLatched) {
            if (cs.globalRecoveryStartedAt == 0) {
                cs.globalRecoveryStartedAt = uint64(block.timestamp);
            } else if (block.timestamp >= uint256(cs.globalRecoveryStartedAt) + GLOBAL_RECOVERY_DELAY) {
                cs.globalImpairmentLatched = false;
                cs.globalRecoveryStartedAt = 0;
            }
            if (cs.globalImpairmentLatched) {
                phase = IStaticsDollarCoreTypes.GlobalHealthPhase.Recovering;
                status = IStaticsDollarCoreTypes.ExitStatus.Recovering;
                recoveryAvailableAt = uint256(cs.globalRecoveryStartedAt) + GLOBAL_RECOVERY_DELAY;
            }
        } else {
            status = IStaticsDollarCoreTypes.ExitStatus.Available;
        }
        if (phase == IStaticsDollarCoreTypes.GlobalHealthPhase.Healthy && !cs.globalImpairmentLatched) {
            status = IStaticsDollarCoreTypes.ExitStatus.Available;
        }
        if (
            emitHealthy || phase != IStaticsDollarCoreTypes.GlobalHealthPhase.Healthy || cs.globalImpairmentLatched
                || wasLatched
        ) {
            emit GlobalHealthSynced(phase, bitmap, deficit, recoveryAvailableAt);
        }
    }

    function tryPrice(address oracle) internal view returns (bool available, uint256 priceWad) {
        try IUsdOracle(oracle).priceWad() returns (uint256 price) {
            return (price != 0, price);
        } catch {
            return (false, 0);
        }
    }

    function tryBalance(address token) internal view returns (bool available, uint256 balance) {
        (bool success, bytes memory result) = token.staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        if (!success || result.length < 32) return (false, 0);
        return (true, abi.decode(result, (uint256)));
    }

    function toWad(uint256 raw, uint8 decimals) internal pure returns (bool valid, uint256 wad) {
        if (decimals == 18) return (true, raw);
        uint256 scale = 10 ** (18 - decimals);
        if (raw > type(uint256).max / scale) return (false, 0);
        return (true, raw * scale);
    }

    function valueWad(uint256 collateralWad, uint256 priceWad) internal pure returns (uint256 value) {
        if (priceWad > WAD && collateralWad > Math.mulDiv(type(uint256).max, WAD, priceWad)) {
            return type(uint256).max;
        }
        return Math.mulDiv(collateralWad, priceWad, WAD);
    }

    function saturatingAdd(uint256 left, uint256 right) internal pure returns (uint256 sum) {
        unchecked {
            sum = left + right;
            if (sum < left) return type(uint256).max;
        }
    }
}
