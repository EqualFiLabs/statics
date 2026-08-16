// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice Fixed-supply token mechanically paired with the 5,555 Statics Genesis NFTs.
contract StaticsToken is ERC20, ERC20Burnable, ERC20Permit {
    uint256 public constant GENESIS_SUPPLY = 999_955_550 ether;

    error InvalidInitialRecipient();

    constructor(address initialRecipient) ERC20("Statics", "STATICS") ERC20Permit("Statics") {
        if (initialRecipient == address(0)) revert InvalidInitialRecipient();
        _mint(initialRecipient, GENESIS_SUPPLY);
    }
}
