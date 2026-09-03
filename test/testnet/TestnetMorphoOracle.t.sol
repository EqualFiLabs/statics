// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";

import {TestnetMorphoOracle} from "../../src/testnet/TestnetMorphoOracle.sol";

contract TestnetMorphoOracleTest is Test {
    address private owner = makeAddr("owner");
    address private stranger = makeAddr("stranger");
    TestnetMorphoOracle private oracle;

    function setUp() public {
        oracle = new TestnetMorphoOracle(owner, 1e36);
    }

    function testOwnerCanPublishLiquidationPrice() public {
        vm.prank(owner);
        oracle.publishPrice(0.25e36);
        assertEq(oracle.price(), 0.25e36);
    }

    function testRevertWhenNonOwnerPublishes() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        oracle.publishPrice(0.5e36);
    }

    function testRevertWhenPriceIsZero() public {
        vm.prank(owner);
        vm.expectRevert(TestnetMorphoOracle.InvalidPrice.selector);
        oracle.publishPrice(0);
    }
}
