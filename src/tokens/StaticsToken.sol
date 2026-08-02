// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice Owner-mintable token used for Statics protocol staking on testnet.
contract StaticsToken is ERC20, ERC20Permit, Ownable {
    constructor(address recipient, uint256 initialSupply)
        ERC20("Statics", "STATICS")
        ERC20Permit("Statics")
        Ownable(recipient)
    {
        _mint(recipient, initialSupply);
    }

    function mint(address recipient, uint256 amount) external onlyOwner {
        _mint(recipient, amount);
    }
}
