// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract MockDopplerToken is ERC20, ERC20Burnable {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;

    constructor(address recipient) ERC20("Statics", "STATICS") {
        _mint(recipient, INITIAL_SUPPLY);
    }
}
