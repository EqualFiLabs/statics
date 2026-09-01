// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IMorphoBlue} from "../interfaces/IMorphoBlue.sol";

/// @notice Minimal deterministic account that delegates all Morpho position management to one Statics Diamond.
contract StaticsMorphoAccount {
    constructor(address morpho, address diamond) {
        IMorphoBlue(morpho).setAuthorization(diamond, true);
    }
}
