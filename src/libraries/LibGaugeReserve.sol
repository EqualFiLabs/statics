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
        uint40 pendingReleaseAt;
        uint40 deferredMaturityAt;
        uint256 available;
        uint256 deferred;
        uint256 committed;
    }

    error GaugeReserveAlreadyInitialized();
    error InvalidGaugeReleaseBps(uint256 releaseBps);
    error GaugeReserveUnderflow(uint256 requested, uint256 available);
    error GaugeCommitmentUnderflow(uint256 requested, uint256 committed);
    error DeferredMaturityMismatch(uint40 storedMaturity, uint40 requestedMaturity);

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

    function setPreActivationReleaseBps(uint16 releaseBps) internal {
        _validateReleaseBps(releaseBps);
        ReserveStorage storage rs = reserveStorage();
        rs.releaseBps = releaseBps;
        rs.pendingReleaseBps = 0;
        rs.pendingReleaseAt = 0;
    }

    function scheduleReleaseBps(uint16 releaseBps, uint40 effectiveAt) internal {
        _validateReleaseBps(releaseBps);
        ReserveStorage storage rs = reserveStorage();
        rs.pendingReleaseBps = releaseBps;
        rs.pendingReleaseAt = effectiveAt;
    }

    function applyScheduledRelease(uint40 boundary) internal returns (uint16 releaseBps) {
        ReserveStorage storage rs = reserveStorage();
        uint40 pendingAt = rs.pendingReleaseAt;
        if (pendingAt != 0 && pendingAt <= boundary) {
            rs.releaseBps = rs.pendingReleaseBps;
            rs.pendingReleaseBps = 0;
            rs.pendingReleaseAt = 0;
        }
        return rs.releaseBps;
    }

    function rollDeferred(uint40 boundary) internal returns (uint256 matured) {
        ReserveStorage storage rs = reserveStorage();
        uint40 maturity = rs.deferredMaturityAt;
        if (maturity == 0 || maturity > boundary) return 0;
        matured = rs.deferred;
        rs.deferred = 0;
        rs.deferredMaturityAt = 0;
        rs.available += matured;
    }

    function makeAvailable(uint256 amount) internal {
        if (amount != 0) reserveStorage().available += amount;
    }

    function defer(uint256 amount, uint40 maturityAt) internal {
        if (amount == 0) return;
        ReserveStorage storage rs = reserveStorage();
        uint40 storedMaturity = rs.deferredMaturityAt;
        if (storedMaturity != 0 && storedMaturity != maturityAt) {
            revert DeferredMaturityMismatch(storedMaturity, maturityAt);
        }
        rs.deferredMaturityAt = maturityAt;
        rs.deferred += amount;
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
