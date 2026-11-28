// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {Morpho} from "../../verification/morpho/vendor/morpho-blue/src/Morpho.sol";

/// @dev Compile pinned upstream separately; the protocol suite uses its actual bytecode through deployCode.
contract UpstreamMorphoCompilation is Morpho {
    constructor(address owner) Morpho(owner) {}
}
