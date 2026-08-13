// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice Fixed-supply staking and governance token for the Statics protocol.
contract StaticsToken is ERC20, ERC20Burnable, ERC20Permit {
    uint256 public constant FIXED_SUPPLY = 1_000_000_000 ether;

    error InvalidTreasury();

    constructor(address treasury) ERC20("Statics", "STATICS") ERC20Permit("Statics") {
        if (treasury == address(0)) revert InvalidTreasury();
        _mint(treasury, FIXED_SUPPLY);
    }
}
