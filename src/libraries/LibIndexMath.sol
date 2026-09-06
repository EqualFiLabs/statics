// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Shared full-precision reward-index numerator accounting.
library LibIndexMath {
    uint256 internal constant RAY = 1e27;

    function indexDelta(uint256 amount, uint256 denominator, uint256 priorRemainder)
        internal
        pure
        returns (uint256 delta, uint256 remainder)
    {
        delta = Math.mulDiv(amount, RAY, denominator);
        remainder = mulmod(amount, RAY, denominator);
        delta += priorRemainder / denominator;
        uint256 normalizedPrior = priorRemainder % denominator;
        uint256 room = denominator - normalizedPrior;
        if (remainder >= room) {
            ++delta;
            remainder -= room;
        } else {
            remainder += normalizedPrior;
        }
    }
}
