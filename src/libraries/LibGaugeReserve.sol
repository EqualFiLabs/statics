// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

library LibGaugeReserve {
    bytes32 internal constant STORAGE_POSITION = keccak256("statics.storage.gauge.reserve.v1");
    uint16 internal constant BPS = 10_000;
    uint16 internal constant DEFAULT_WEEKLY_RELEASE_BPS = 400;
    uint16 internal constant MAX_WEEKLY_RELEASE_BPS = 1_000;

    struct ReserveStorage {
        bool initialized;
        uint16 releaseBps;
        uint16 pendingReleaseBps;
        uint64 pendingReleaseEpoch;
        uint64 deferredMaturityEpoch;
        uint256 available;
        uint256 deferred;
        uint256 committed;
    }

    error GaugeReserveAlreadyInitialized();
    error InvalidGaugeReleaseBps(uint256 releaseBps);
    error GaugeReserveUnderflow(uint256 requested, uint256 available);
    error GaugeCommitmentUnderflow(uint256 requested, uint256 committed);
    error DeferredEpochMismatch(uint64 storedEpoch, uint64 requestedEpoch);

    function reserveStorage() internal pure returns (ReserveStorage storage rs) {
        bytes32 position = STORAGE_POSITION;
        assembly ("memory-safe") {
            rs.slot := position
        }
    }

    function initialize(uint16 releaseBps) internal {
        ReserveStorage storage rs = reserveStorage();
        if (rs.initialized) revert GaugeReserveAlreadyInitialized();
        _validateReleaseBps(releaseBps);
        rs.initialized = true;
        rs.releaseBps = releaseBps;
    }

    function scheduleReleaseBps(uint16 releaseBps, uint64 effectiveEpoch) internal {
        _validateReleaseBps(releaseBps);
        ReserveStorage storage rs = reserveStorage();
        rs.pendingReleaseBps = releaseBps;
        rs.pendingReleaseEpoch = effectiveEpoch;
    }

    function applyScheduledRelease(uint64 currentEpoch) internal returns (uint16 releaseBps) {
        ReserveStorage storage rs = reserveStorage();
        uint64 pendingEpoch = rs.pendingReleaseEpoch;
        if (pendingEpoch != 0 && pendingEpoch <= currentEpoch) {
            rs.releaseBps = rs.pendingReleaseBps;
            rs.pendingReleaseBps = 0;
            rs.pendingReleaseEpoch = 0;
        }
        return rs.releaseBps;
    }

    function rollDeferred(uint64 currentEpoch) internal returns (uint256 matured) {
        ReserveStorage storage rs = reserveStorage();
        uint64 maturity = rs.deferredMaturityEpoch;
        if (maturity == 0 || maturity > currentEpoch) return 0;
        matured = rs.deferred;
        rs.deferred = 0;
        rs.deferredMaturityEpoch = 0;
        rs.available += matured;
    }

    function defer(uint256 amount, uint64 currentEpoch) internal {
        if (amount == 0) return;
        rollDeferred(currentEpoch);
        ReserveStorage storage rs = reserveStorage();
        uint64 maturity = currentEpoch + 1;
        uint64 storedMaturity = rs.deferredMaturityEpoch;
        if (storedMaturity != 0 && storedMaturity != maturity) {
            revert DeferredEpochMismatch(storedMaturity, maturity);
        }
        rs.deferredMaturityEpoch = maturity;
        rs.deferred += amount;
    }

    function recycle(uint256 amount, uint64 sourceEpoch, uint64 currentEpoch) internal {
        if (amount == 0) return;
        if (sourceEpoch < currentEpoch) {
            rollDeferred(currentEpoch);
            reserveStorage().available += amount;
        } else {
            defer(amount, currentEpoch);
        }
    }

    function commit(uint256 amount) internal {
        if (amount == 0) return;
        ReserveStorage storage rs = reserveStorage();
        uint256 available = rs.available;
        if (amount > available) revert GaugeReserveUnderflow(amount, available);
        rs.available = available - amount;
        rs.committed += amount;
    }

    function consumeCommitted(uint256 amount) internal {
        if (amount == 0) return;
        ReserveStorage storage rs = reserveStorage();
        uint256 committed = rs.committed;
        if (amount > committed) revert GaugeCommitmentUnderflow(amount, committed);
        rs.committed = committed - amount;
    }

    function _validateReleaseBps(uint16 releaseBps) private pure {
        if (releaseBps > MAX_WEEKLY_RELEASE_BPS) revert InvalidGaugeReleaseBps(releaseBps);
    }
}
