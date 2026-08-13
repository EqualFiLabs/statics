// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {DeployStaticsToken} from "../../script/DeployStaticsToken.s.sol";
import {StaticsToken} from "../../src/tokens/StaticsToken.sol";

contract DeployStaticsTokenTest is Test {
    function testDeploysFixedSupplyToConfiguredTreasury() public {
        address recipient = makeAddr("recipient");
        uint256 initialSupply = 1_000_000_000 ether;

        StaticsToken token = new DeployStaticsToken().deploy(recipient);

        assertEq(token.name(), "Statics");
        assertEq(token.symbol(), "STATICS");
        assertEq(token.totalSupply(), initialSupply);
        assertEq(token.balanceOf(recipient), initialSupply);
        assertEq(token.nonces(recipient), 0);
        vm.prank(recipient);
        token.burn(initialSupply / 10);
        assertEq(token.totalSupply(), initialSupply * 9 / 10);
    }
}
