// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice Fixed-supply token used for Statics protocol staking.
contract StaticsToken is ERC20, ERC20Permit {
    constructor(address recipient, uint256 initialSupply)
        ERC20("Statics", "STATICS")
        ERC20Permit("Statics")
    {
        _mint(recipient, initialSupply);
    }
}
