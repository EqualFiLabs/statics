// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {DeployStaticsToken} from "../../script/DeployStaticsToken.s.sol";
import {StaticsToken} from "../../src/tokens/StaticsToken.sol";

contract DeployStaticsTokenTest is Test {
    function testDeploysFixedSupplyToConfiguredRecipient() public {
        address recipient = makeAddr("recipient");

        StaticsToken token = new DeployStaticsToken().deploy(recipient);

        assertEq(token.name(), "Statics");
        assertEq(token.symbol(), "STATICS");
        assertEq(token.totalSupply(), 999_955_550 ether);
        assertEq(token.balanceOf(recipient), 999_955_550 ether);
        assertEq(token.nonces(recipient), 0);
    }
}
