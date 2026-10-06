// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PrepareStaticsBasketFactory} from "../../script/PrepareStaticsBasketFactory.s.sol";
import {IStaticsBasketPreparation} from "../../src/interfaces/IStaticsBasketPreparation.sol";
import {StaticsBasketFactory} from "../../src/liquidity/StaticsBasketFactory.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

contract PrepareStaticsBasketFactoryTest is StaticsTestBase {
    function testQueuePayloadRejectsAvailablePreparedTokenAndHookSalts() public {
        PrepareStaticsBasketFactory script = new PrepareStaticsBasketFactory();
        StaticsBasketFactory.Intent memory intent = StaticsBasketFactory.Intent({
            payer: alice,
            creator: alice,
            configurationHash: keccak256("prepared helper regression"),
            deadline: uint64(block.timestamp + 1 days),
            version: 1
        });
        bytes32[] memory salts = new bytes32[](1);
        salts[0] = _localBasketFactory.preparedSaltFor(intent, 0);
        assertTrue(_localBasketFactory.saltAvailable(salts[0]));
        vm.expectPartialRevert(PrepareStaticsBasketFactory.InvalidSalt.selector);
        script.replenishmentPayload(_localBasketFactory, salts, false);
        (uint256 nonce,) = _minePreparedTestHook(_localBasketFactory, intent, 0);
        salts[0] = _localBasketFactory.preparedSaltFor(intent, nonce);
        assertTrue(_localBasketFactory.saltAvailable(salts[0]));
        vm.expectPartialRevert(PrepareStaticsBasketFactory.InvalidSalt.selector);
        script.replenishmentPayload(_localBasketFactory, salts, true);
    }

    function testFactoryPreparationValidatesBindingsAndEncodesOwnerAction() public {
        PrepareStaticsBasketFactory script = new PrepareStaticsBasketFactory();
        bytes memory payload = script.installationPayload(
            address(diamond), address(_localBasketFactory), address(_localBasketFactory).codehash
        );
        assertEq(
            payload, abi.encodeCall(IStaticsBasketPreparation.installBasketFactory, (address(_localBasketFactory)))
        );
        vm.expectRevert(PrepareStaticsBasketFactory.InvalidFactory.selector);
        script.installationPayload(address(diamond), address(_localBasketFactory), keccak256("wrong runtime"));
        vm.expectRevert(PrepareStaticsBasketFactory.InvalidFactory.selector);
        script.installationPayload(address(diamond), address(_localBasketFactory), bytes32(0));
    }

    function testPermissionlessQueuePayloadRejectsDuplicatesAndOccupiedEntries() public {
        PrepareStaticsBasketFactory script = new PrepareStaticsBasketFactory();
        bytes32[] memory salts = new bytes32[](1);
        salts[0] = _localBasketFactory.saltFor(((uint88(1) << 87) - 1) - 1);
        bytes memory payload = script.replenishmentPayload(_localBasketFactory, salts, false);
        assertEq(payload, abi.encodeCall(StaticsBasketFactory.enqueueSalts, (salts, false)));
        vm.prank(bob);
        (bool ok,) = address(_localBasketFactory).call(payload);
        assertTrue(ok);
        vm.expectPartialRevert(PrepareStaticsBasketFactory.InvalidSalt.selector);
        script.replenishmentPayload(_localBasketFactory, salts, false);
        salts = new bytes32[](2);
        salts[0] = _localBasketFactory.saltFor(((uint88(1) << 87) - 1) - 2);
        salts[1] = salts[0];
        vm.expectPartialRevert(PrepareStaticsBasketFactory.InvalidSalt.selector);
        script.replenishmentPayload(_localBasketFactory, salts, false);
    }
}
