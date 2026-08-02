// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IStaticsDollarCoreTypes} from "../../interfaces/IStaticsDollarCoreTypes.sol";
import {LibCoreHealth} from "../libraries/LibCoreHealth.sol";
import {LibCorePeggedRedemption} from "../libraries/LibCorePeggedRedemption.sol";
import {LibCoreStorage} from "../libraries/LibCoreStorage.sol";

contract CoreHealthFacet {
    uint256 public constant GLOBAL_RECOVERY_DELAY = 48 hours;

    event GlobalHealthSynced(
        IStaticsDollarCoreTypes.GlobalHealthPhase phase,
        uint256 unhealthyProfileBitmap,
        uint256 totalSeniorDeficitWad,
        uint256 recoveryAvailableAt
    );

    error InvalidProfile(uint256 profileId);

    function profileSolvency(uint256 profileId)
        external
        view
        returns (IStaticsDollarCoreTypes.ProfileSolvency memory solvency)
    {
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[profileId];
        if (profile.collateralToken == address(0)) revert InvalidProfile(profileId);
        return LibCoreHealth.profileSolvency(cs, profileId, profile);
    }

    function globalImpairment()
        external
        view
        returns (
            IStaticsDollarCoreTypes.GlobalHealthPhase phase,
            uint256 unhealthyProfileBitmap,
            uint256 totalSeniorDeficitWad,
            uint256 recoveryAvailableAt
        )
    {
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        (phase, unhealthyProfileBitmap, totalSeniorDeficitWad) = LibCoreHealth.currentGlobalHealth(cs);
        if (phase == IStaticsDollarCoreTypes.GlobalHealthPhase.Healthy && cs.globalImpairmentLatched) {
            if (cs.globalRecoveryStartedAt != 0) {
                recoveryAvailableAt = uint256(cs.globalRecoveryStartedAt) + GLOBAL_RECOVERY_DELAY;
                if (block.timestamp >= recoveryAvailableAt) return (phase, 0, 0, 0);
            }
            phase = IStaticsDollarCoreTypes.GlobalHealthPhase.Recovering;
        }
    }

    function syncProfileHealth(uint256 profileId) external {
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        if (cs.collateralProfiles[profileId].collateralToken == address(0)) revert InvalidProfile(profileId);
        LibCoreHealth.checkpointGlobalHealth(cs, true);
    }

    function syncGlobalHealth() external {
        LibCoreHealth.checkpointGlobalHealth(LibCoreStorage.s(), true);
    }

    function checkpointGlobalCollateralExit()
        external
        returns (
            IStaticsDollarCoreTypes.ExitStatus status,
            uint256 unhealthyProfileBitmap,
            uint256 totalSeniorDeficitWad,
            uint256 recoveryAvailableAt
        )
    {
        return LibCoreHealth.checkpointGlobalHealth(LibCoreStorage.s(), false);
    }

    function peggedRedemptionStatus()
        external
        view
        returns (
            IStaticsDollarCoreTypes.ExitStatus status,
            uint256 unhealthyProfileBitmap,
            uint256 totalSeniorDeficitWad,
            uint256 recoveryAvailableAt
        )
    {
        return LibCorePeggedRedemption.status(LibCoreStorage.s());
    }

    function checkpointPeggedRedemption()
        external
        returns (
            IStaticsDollarCoreTypes.ExitStatus status,
            uint256 unhealthyProfileBitmap,
            uint256 totalSeniorDeficitWad,
            uint256 recoveryAvailableAt
        )
    {
        return LibCorePeggedRedemption.checkpoint(LibCoreStorage.s());
    }
}
