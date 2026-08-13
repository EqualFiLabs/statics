// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _TOKEN_DECIMALS;

    constructor(string memory name, string memory symbol, uint8 tokenDecimals) ERC20(name, symbol) {
        _TOKEN_DECIMALS = tokenDecimals;
    }

    function decimals() public view override returns (uint8) {
        return _TOKEN_DECIMALS;
    }

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }

    function burnFrom(address account, uint256 amount) external {
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }
}

contract MockFeeOnTransferERC20 is MockERC20 {
    constructor() MockERC20("Taxed", "TAX", 18) {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

contract MockOutboundFeeERC20 is MockERC20 {
    address public taxedSender;

    constructor() MockERC20("Outbound Tax", "OTAX", 18) {}

    function setTaxedSender(address sender) external {
        taxedSender = sender;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (taxedSender != address(0) && from == taxedSender && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

contract MockSenderExtraFeeERC20 is MockERC20 {
    address public taxedSender;

    constructor() MockERC20("Sender Extra Tax", "SETAX", 18) {}

    function setTaxedSender(address sender) external {
        taxedSender = sender;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (taxedSender != address(0) && from == taxedSender && to != address(0)) {
            super._update(from, address(0), value / 100);
        }
        super._update(from, to, value);
    }
}

contract MockReentrantERC20 is MockERC20 {
    address public guardedSender;
    address public callbackTarget;
    bytes public callbackData;
    bool public reentrySucceeded;
    bytes public reentryResult;

    constructor() MockERC20("Reentrant", "REENTER", 18) {}

    function setCallback(address sender, address target, bytes calldata data) external {
        guardedSender = sender;
        callbackTarget = target;
        callbackData = data;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from == guardedSender && to != address(0) && callbackTarget != address(0)) {
            (reentrySucceeded, reentryResult) = callbackTarget.call(callbackData);
        }
    }
}
