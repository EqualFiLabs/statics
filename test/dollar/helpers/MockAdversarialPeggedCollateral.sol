// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract MockAdversarialPeggedCollateral is ERC20, ERC20Permit {
    uint16 public transferFeeBps;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackEnabled;

    constructor() ERC20("Adversarial Pegged Collateral", "APC") ERC20Permit("Adversarial Pegged Collateral") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function setTransferFeeBps(uint16 feeBps) external {
        transferFeeBps = feeBps;
    }

    function setCallback(address target, bytes calldata data, bool enabled) external {
        callbackTarget = target;
        callbackData = data;
        callbackEnabled = enabled;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (callbackEnabled && from != address(0) && to != address(0)) {
            (bool ok, bytes memory reason) = callbackTarget.call(callbackData);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(reason, 32), mload(reason))
                }
            }
        }
        uint256 fee = from != address(0) && to != address(0) ? (value * transferFeeBps) / 10_000 : 0;
        if (fee != 0) super._update(from, address(0xdead), fee);
        super._update(from, to, value - fee);
    }
}
