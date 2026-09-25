// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LibGaugeReserve} from "../../../src/libraries/LibGaugeReserve.sol";

contract GaugeReserveFormalHarness {
    function initialize(uint16 releaseBps) external {
        LibGaugeReserve.initialize(releaseBps);
    }

    function defer(uint256 amount, uint64 currentEpoch) external {
        LibGaugeReserve.defer(amount, currentEpoch);
    }

    function rollDeferred(uint64 currentEpoch) external returns (uint256 matured) {
        return LibGaugeReserve.rollDeferred(currentEpoch);
    }

    function commit(uint256 amount) external {
        LibGaugeReserve.commit(amount);
    }

    function consumeCommitted(uint256 amount) external {
        LibGaugeReserve.consumeCommitted(amount);
    }

    function recycle(uint256 amount, uint64 sourceEpoch, uint64 currentEpoch) external {
        LibGaugeReserve.recycle(amount, sourceEpoch, currentEpoch);
    }

    function schedule(uint16 releaseBps, uint64 effectiveEpoch, uint64 currentEpoch) external {
        LibGaugeReserve.scheduleReleaseBps(releaseBps, effectiveEpoch, currentEpoch);
    }

    function applyScheduled(uint64 currentEpoch) external returns (uint16 releaseBps) {
        return LibGaugeReserve.applyScheduledRelease(currentEpoch);
    }

    function state() external view returns (uint16 releaseBps, uint256 available, uint256 deferred, uint256 committed) {
        LibGaugeReserve.ReserveStorage storage stored = LibGaugeReserve.reserveStorage();
        return (stored.releaseBps, stored.available, stored.deferred, stored.committed);
    }

    function scheduleState()
        external
        view
        returns (uint16 releaseBps, uint16 pendingReleaseBps, uint64 pendingReleaseEpoch)
    {
        LibGaugeReserve.ReserveStorage storage stored = LibGaugeReserve.reserveStorage();
        return (stored.releaseBps, stored.pendingReleaseBps, stored.pendingReleaseEpoch);
    }
}
