// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {DiamondKernel} from "../../diamond/DiamondKernel.sol";
import {IDiamondCut} from "../../interfaces/IDiamondCut.sol";

/// @notice Permanent Statics Dollar collateral and token-authority address.
contract StaticsDollarCoreDiamond is DiamondKernel {
    constructor(address upgradeGovernor, IDiamondCut.FacetCut[] memory genesisCut, address init, bytes memory initData)
        DiamondKernel(upgradeGovernor, genesisCut, init, initData)
    {}
}
