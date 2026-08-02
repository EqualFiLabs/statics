// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

// Retain the pinned Permit2 creation artifact for deterministic local v4
// lifecycle tests. Production uses Robinhood Chain's deployed Permit2.
import {Permit2} from "permit2/src/Permit2.sol";

abstract contract Permit2Compilation {
    function _permit2CreationCode() internal pure returns (bytes memory) {
        return type(Permit2).creationCode;
    }
}
