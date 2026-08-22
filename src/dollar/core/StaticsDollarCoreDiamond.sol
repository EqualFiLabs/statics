// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {DiamondKernel} from "../../diamond/DiamondKernel.sol";

/// @notice Permanent Statics Dollar collateral and token-authority address.
contract StaticsDollarCoreDiamond is DiamondKernel {
    constructor(address upgradeGovernor, address init, bytes memory initData)
        DiamondKernel(upgradeGovernor, init, initData)
    {}
}
