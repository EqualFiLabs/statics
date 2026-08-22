// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IStaticsDollarCoreTypes} from "../../interfaces/IStaticsDollarCoreTypes.sol";
import {LibCoreHealth} from "./LibCoreHealth.sol";
import {LibCoreStorage} from "./LibCoreStorage.sol";

library LibCorePeggedRedemption {
    uint256 internal constant RECOVERY_DELAY = 48 hours;

    event PeggedRedemptionQuarantined(uint256 indexed seriesId, uint256 pendingDownsideTransitions);
    event PeggedDownsideTransitionResolved(uint256 indexed seriesId, uint256 pendingDownsideTransitions);
    event PeggedRedemptionHealthCheckpointed(
        IStaticsDollarCoreTypes.ExitStatus status,
        uint256 unhealthyProfileBitmap,
        uint256 totalSeniorDeficitWad,
        uint256 recoveryAvailableAt
    );

    function startDownside(LibCoreStorage.CS storage cs, uint256 seriesId) internal {
        if (!cs.downsideTransitionPending[seriesId]) {
            cs.downsideTransitionPending[seriesId] = true;
            cs.pendingDownsideTransitions++;
        }
        cs.peggedRedemptionLatched = true;
        cs.peggedRecoveryStartedAt = 0;
        emit PeggedRedemptionQuarantined(seriesId, cs.pendingDownsideTransitions);
    }

    function resolveDownside(LibCoreStorage.CS storage cs, uint256 seriesId) internal {
        if (!cs.downsideTransitionPending[seriesId]) return;
        cs.downsideTransitionPending[seriesId] = false;
        cs.pendingDownsideTransitions--;
        cs.peggedRedemptionLatched = true;
        cs.peggedRecoveryStartedAt = 0;
        emit PeggedDownsideTransitionResolved(seriesId, cs.pendingDownsideTransitions);
    }

    function status(LibCoreStorage.CS storage cs)
        internal
        view
        returns (
            IStaticsDollarCoreTypes.ExitStatus exitStatus,
            uint256 unhealthyProfileBitmap,
            uint256 totalSeniorDeficitWad,
            uint256 recoveryAvailableAt
        )
    {
        if (cs.pendingDownsideTransitions != 0) {
            return (IStaticsDollarCoreTypes.ExitStatus.DownsideTransition, 0, 0, 0);
        }
        (IStaticsDollarCoreTypes.GlobalHealthPhase phase, uint256 bitmap, uint256 deficit) =
            LibCoreHealth.currentGlobalHealth(cs);
        unhealthyProfileBitmap = bitmap;
        totalSeniorDeficitWad = deficit;
        if (phase == IStaticsDollarCoreTypes.GlobalHealthPhase.Unavailable) {
            return
                (IStaticsDollarCoreTypes.ExitStatus.HealthUnavailable, unhealthyProfileBitmap, totalSeniorDeficitWad, 0);
        }
        if (phase == IStaticsDollarCoreTypes.GlobalHealthPhase.Impaired) {
            return (IStaticsDollarCoreTypes.ExitStatus.Impaired, unhealthyProfileBitmap, totalSeniorDeficitWad, 0);
        }
        if (!cs.peggedRedemptionLatched) {
            return (IStaticsDollarCoreTypes.ExitStatus.Available, 0, 0, 0);
        }
        if (cs.peggedRecoveryStartedAt != 0) {
            recoveryAvailableAt = uint256(cs.peggedRecoveryStartedAt) + RECOVERY_DELAY;
        }
        return (IStaticsDollarCoreTypes.ExitStatus.Recovering, 0, 0, recoveryAvailableAt);
    }

    function checkpoint(LibCoreStorage.CS storage cs)
        internal
        returns (
            IStaticsDollarCoreTypes.ExitStatus exitStatus,
            uint256 unhealthyProfileBitmap,
            uint256 totalSeniorDeficitWad,
            uint256 recoveryAvailableAt
        )
    {
        (exitStatus, unhealthyProfileBitmap, totalSeniorDeficitWad, recoveryAvailableAt) = status(cs);
        if (
            exitStatus == IStaticsDollarCoreTypes.ExitStatus.DownsideTransition
                || exitStatus == IStaticsDollarCoreTypes.ExitStatus.HealthUnavailable
                || exitStatus == IStaticsDollarCoreTypes.ExitStatus.Impaired
        ) {
            cs.peggedRedemptionLatched = true;
            cs.peggedRecoveryStartedAt = 0;
        } else if (exitStatus == IStaticsDollarCoreTypes.ExitStatus.Recovering) {
            if (cs.peggedRecoveryStartedAt == 0) {
                cs.peggedRecoveryStartedAt = uint64(block.timestamp);
                recoveryAvailableAt = block.timestamp + RECOVERY_DELAY;
            } else if (block.timestamp >= recoveryAvailableAt) {
                cs.peggedRedemptionLatched = false;
                cs.peggedRecoveryStartedAt = 0;
                exitStatus = IStaticsDollarCoreTypes.ExitStatus.Available;
                recoveryAvailableAt = 0;
            }
        }
        emit PeggedRedemptionHealthCheckpointed(
            exitStatus, unhealthyProfileBitmap, totalSeniorDeficitWad, recoveryAvailableAt
        );
    }
}
