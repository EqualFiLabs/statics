// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {MockERC20} from "./MockERC20.sol";

contract MockImpairableERC20 is MockERC20 {
    bool public failBalances;
    bool public failTransfers;
    error AssetFrozen();

    constructor() MockERC20("Impairable", "BAD", 18) {}

    function setFailures(bool balances, bool transfers) external {
        failBalances = balances;
        failTransfers = transfers;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (failBalances) revert AssetFrozen();
        return super.balanceOf(account);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (failTransfers) revert AssetFrozen();
        super._update(from, to, value);
    }
}
