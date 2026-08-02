// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract StaticsBasketToken is ERC20, ERC20Permit {
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable protocol;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint256 public immutable basketId;

    error OnlyProtocol(address caller);

    constructor(string memory name, string memory symbol, address protocol_, uint256 basketId_)
        ERC20(name, symbol)
        ERC20Permit(name)
    {
        protocol = protocol_;
        basketId = basketId_;
    }

    function mint(address receiver, uint256 shares) external {
        if (msg.sender != protocol) revert OnlyProtocol(msg.sender);
        _mint(receiver, shares);
    }

    function burn(address owner, uint256 shares) external {
        if (msg.sender != protocol) revert OnlyProtocol(msg.sender);
        _burn(owner, shares);
    }
}
