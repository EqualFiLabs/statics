// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PrepareStaticsBasketTokenFactory} from "../../script/PrepareStaticsBasketTokenFactory.s.sol";
import {StaticsBasketTokenFactory} from "../../src/liquidity/StaticsBasketTokenFactory.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

contract PrepareStaticsBasketTokenFactoryTest is StaticsTestBase {
    function testReplenishmentRejectsPreparedSalt() public {
        PrepareStaticsBasketTokenFactory script = new PrepareStaticsBasketTokenFactory();
        StaticsBasketTokenFactory.Intent memory intent = StaticsBasketTokenFactory.Intent({
            payer: alice,
            creator: alice,
            configurationHash: keccak256("prepared helper regression"),
            deadline: block.timestamp + 1 days,
            version: 1
        });
        bytes32[] memory salts = new bytes32[](1);
        salts[0] = _localBasketFactory.preparedSaltFor(intent, 0);
        assertTrue(_localBasketFactory.saltAvailable(salts[0]));
        vm.expectPartialRevert(PrepareStaticsBasketTokenFactory.InvalidSalt.selector);
        script.replenishmentPayload(_localBasketFactory, salts);
    }

    function testFactoryValidationChecksRuntimeAndBindings() public {
        PrepareStaticsBasketTokenFactory script = new PrepareStaticsBasketTokenFactory();
        script.validateFactory(address(diamond), address(_localBasketFactory), address(_localBasketFactory).codehash);
        vm.expectRevert(PrepareStaticsBasketTokenFactory.InvalidFactory.selector);
        script.validateFactory(address(diamond), address(_localBasketFactory), keccak256("wrong runtime"));
        vm.expectRevert(PrepareStaticsBasketTokenFactory.InvalidFactory.selector);
        script.validateFactory(address(diamond), address(_localBasketFactory), bytes32(0));
    }

    function testPermissionlessQueuePayloadRejectsDuplicatesAndOccupiedEntries() public {
        PrepareStaticsBasketTokenFactory script = new PrepareStaticsBasketTokenFactory();
        bytes32[] memory salts = new bytes32[](1);
        salts[0] = _localBasketFactory.saltFor(((uint88(1) << 87) - 1) - 1);
        bytes memory payload = script.replenishmentPayload(_localBasketFactory, salts);
        assertEq(payload, abi.encodeCall(StaticsBasketTokenFactory.enqueueSalts, (salts)));
        vm.prank(bob);
        (bool ok,) = address(_localBasketFactory).call(payload);
        assertTrue(ok);
        vm.expectPartialRevert(PrepareStaticsBasketTokenFactory.InvalidSalt.selector);
        script.replenishmentPayload(_localBasketFactory, salts);
        salts = new bytes32[](2);
        salts[0] = _localBasketFactory.saltFor(((uint88(1) << 87) - 1) - 2);
        salts[1] = salts[0];
        vm.expectPartialRevert(PrepareStaticsBasketTokenFactory.InvalidSalt.selector);
        script.replenishmentPayload(_localBasketFactory, salts);
    }
}
