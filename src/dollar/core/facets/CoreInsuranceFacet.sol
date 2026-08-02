// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IStaticsDollarCoreTypes} from "../../interfaces/IStaticsDollarCoreTypes.sol";
import {LibCoreAccounting} from "../libraries/LibCoreAccounting.sol";
import {LibCoreStorage} from "../libraries/LibCoreStorage.sol";

contract CoreInsuranceFacet is ReentrancyGuard {
    event InsuranceToppedUp(
        address indexed payer, uint256 indexed profileId, address indexed collateralToken, uint256 amount
    );
    error ZeroAmount();
    error InvalidProfileKind(
        uint256 profileId, IStaticsDollarCoreTypes.ProfileKind expected, IStaticsDollarCoreTypes.ProfileKind actual
    );
    function topUpInsurance(uint256 profileId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        LibCoreAccounting.enforceBootstrapFinalized(cs);
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = LibCoreAccounting.profile(cs, profileId);
        LibCoreAccounting.pullExact(profile.collateralToken, msg.sender, amount);
        if (
            profile.kind == IStaticsDollarCoreTypes.ProfileKind.Volatile
                && profile.mode == IStaticsDollarCoreTypes.ProfileMode.Retired
        ) {
            IStaticsDollarCoreTypes.RiskSeries storage series = cs.riskSeries[profile.activeSeriesId];
            if (series.status == IStaticsDollarCoreTypes.SeriesStatus.Closed) {
                profile.insuranceReserve += amount;
            } else {
                profile.accountedCollateral += amount;
                series.accountedCollateral += amount;
                LibCoreAccounting.updateSeriesIndex(cs, profile.activeSeriesId);
            }
        } else {
            profile.insuranceReserve += amount;
        }
        cs.accountedCollateralByToken[profile.collateralToken] += amount;
        LibCoreAccounting.enforceCustody(cs, profile.collateralToken);
        emit InsuranceToppedUp(msg.sender, profileId, profile.collateralToken, amount);
    }

    function profileHealth(uint256 profileId)
        external
        view
        returns (bool oracleHealthy, IStaticsDollarCoreTypes.ProfileMode recommendedMode, uint256 priceWad)
    {
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = LibCoreAccounting.profile(cs, profileId);
        if (profile.kind != IStaticsDollarCoreTypes.ProfileKind.Pegged) {
            revert InvalidProfileKind(profileId, IStaticsDollarCoreTypes.ProfileKind.Pegged, profile.kind);
        }
        (bool available, uint256 currentPrice) = _tryPrice(profile.oracle);
        if (available) {
            priceWad = currentPrice;
            oracleHealthy = currentPrice >= profile.pegMinPriceWad && currentPrice <= profile.pegMaxPriceWad;
        }
        recommendedMode = oracleHealthy
            ? IStaticsDollarCoreTypes.ProfileMode.Active
            : IStaticsDollarCoreTypes.ProfileMode.ReduceOnly;
    }

    function insuranceTarget(uint256 profileId) external view returns (uint256 target) {
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = LibCoreAccounting.profile(cs, profileId);
        if (profile.kind == IStaticsDollarCoreTypes.ProfileKind.Pegged) return 0;
        return LibCoreAccounting.insuranceTarget(profile, LibCoreAccounting.readPriceWad(profile));
    }

    function insuranceDeficit(uint256 profileId) external view returns (uint256 deficit) {
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = LibCoreAccounting.profile(cs, profileId);
        if (profile.kind == IStaticsDollarCoreTypes.ProfileKind.Pegged) return 0;
        uint256 target = LibCoreAccounting.insuranceTarget(profile, LibCoreAccounting.readPriceWad(profile));
        return target > profile.insuranceReserve ? target - profile.insuranceReserve : 0;
    }

    function _tryPrice(address oracle) private view returns (bool available, uint256 priceWad) {
        (bool ok, bytes memory data) = oracle.staticcall(abi.encodeWithSignature("priceWad()"));
        if (!ok || data.length < 32) return (false, 0);
        priceWad = abi.decode(data, (uint256));
        return (priceWad != 0, priceWad);
    }
}
