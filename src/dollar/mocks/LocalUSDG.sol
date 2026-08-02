// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice Six-decimal local-only collateral used by Anvil deployment rehearsals.
contract LocalUSDG is ERC20, ERC20Permit {
    constructor() ERC20("Local USDG", "USDG") ERC20Permit("Local USDG") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
