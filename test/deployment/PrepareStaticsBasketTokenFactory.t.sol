// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PrepareStaticsBasketTokenFactory} from "../../script/PrepareStaticsBasketTokenFactory.s.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

contract PrepareStaticsBasketTokenFactoryTest is StaticsTestBase {
    function testFactoryValidationChecksRuntimeAndBindings() public {
        PrepareStaticsBasketTokenFactory script = new PrepareStaticsBasketTokenFactory();
        script.validateFactory(address(diamond), address(_localBasketFactory), address(_localBasketFactory).codehash);
        vm.expectRevert(PrepareStaticsBasketTokenFactory.InvalidFactory.selector);
        script.validateFactory(address(diamond), address(_localBasketFactory), keccak256("wrong runtime"));
        vm.expectRevert(PrepareStaticsBasketTokenFactory.InvalidFactory.selector);
        script.validateFactory(address(diamond), address(_localBasketFactory), bytes32(0));
    }
}
