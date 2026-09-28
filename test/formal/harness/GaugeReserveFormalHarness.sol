// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LibGaugeReserve} from "../../../src/libraries/LibGaugeReserve.sol";

contract GaugeReserveFormalHarness {
    function initialize(uint16 releaseBps) external {
        LibGaugeReserve.initialize(releaseBps);
    }

    function defer(uint256 amount, uint40 maturityAt) external {
        LibGaugeReserve.defer(amount, maturityAt);
    }

    function makeAvailable(uint256 amount) external {
        LibGaugeReserve.makeAvailable(amount);
    }

    function rollDeferred(uint40 boundary) external returns (uint256 matured) {
        return LibGaugeReserve.rollDeferred(boundary);
    }

    function commit(uint256 amount) external {
        LibGaugeReserve.commit(amount);
    }

    function consumeCommitted(uint256 amount) external {
        LibGaugeReserve.consumeCommitted(amount);
    }

    function recycle(uint256 amount, uint40 maturityAt) external {
        LibGaugeReserve.consumeCommitted(amount);
        LibGaugeReserve.defer(amount, maturityAt);
    }

    function schedule(uint16 releaseBps, uint40 effectiveAt) external {
        LibGaugeReserve.scheduleReleaseBps(releaseBps, effectiveAt);
    }

    function applyScheduled(uint40 boundary) external returns (uint16 releaseBps) {
        return LibGaugeReserve.applyScheduledRelease(boundary);
    }

    function state() external view returns (uint16 releaseBps, uint256 available, uint256 deferred, uint256 committed) {
        LibGaugeReserve.ReserveStorage storage stored = LibGaugeReserve.reserveStorage();
        return (stored.releaseBps, stored.available, stored.deferred, stored.committed);
    }

    function scheduleState()
        external
        view
        returns (uint16 releaseBps, uint16 pendingReleaseBps, uint40 pendingReleaseAt)
    {
        LibGaugeReserve.ReserveStorage storage stored = LibGaugeReserve.reserveStorage();
        return (stored.releaseBps, stored.pendingReleaseBps, stored.pendingReleaseAt);
    }
}
