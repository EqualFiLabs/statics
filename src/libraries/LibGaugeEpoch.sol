// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

library LibGaugeEpoch {
    uint256 internal constant WEEK = 7 days;
    uint256 internal constant MONDAY_OFFSET = 3 days;

    function epochAt(uint256 timestamp) internal pure returns (uint64 epoch) {
        uint256 value = (timestamp + MONDAY_OFFSET) / WEEK;
        if (value > type(uint64).max) revert();
        epoch = uint64(value);
    }

    function epochStart(uint64 epoch) internal pure returns (uint40 start) {
        uint256 value = uint256(epoch) * WEEK - MONDAY_OFFSET;
        if (value > type(uint40).max) revert();
        start = uint40(value);
    }

    function epochFinish(uint64 epoch) internal pure returns (uint40 finish) {
        uint256 value = uint256(epoch + 1) * WEEK - MONDAY_OFFSET;
        if (value > type(uint40).max) revert();
        finish = uint40(value);
    }
}
