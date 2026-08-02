// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract MockUSDC is ERC20, ERC20Permit {
    bool public paused;
    bool public revertIssuerControls;
    mapping(address account => bool blocked) internal _blacklisted;

    error TokenPaused();
    error AccountBlacklisted(address account);
    error IssuerControlsFailed();

    constructor() ERC20("Mock USDC", "mUSDC") ERC20Permit("Mock USDC") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function setBlacklisted(address account, bool value) external {
        _blacklisted[account] = value;
    }

    function setRevertIssuerControls(bool value) external {
        revertIssuerControls = value;
    }

    function isBlacklisted(address account) external view returns (bool) {
        if (revertIssuerControls) revert IssuerControlsFailed();
        return _blacklisted[account];
    }

    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert TokenPaused();
        if (from != address(0) && _blacklisted[from]) revert AccountBlacklisted(from);
        if (to != address(0) && _blacklisted[to]) revert AccountBlacklisted(to);
        super._update(from, to, value);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
