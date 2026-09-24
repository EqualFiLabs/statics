// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {GaugeReserveFormalHarness} from "./harness/GaugeReserveFormalHarness.sol";

contract GaugeReserveHalmosTest is SymTest, Test {
    uint256 private constant BPS = 10_000;
    uint16 private constant MAX_RELEASE_BPS = 1_000;

    GaugeReserveFormalHarness private reserve;

    function setUp() public {
        reserve = new GaugeReserveFormalHarness();
    }

    function testRepresentativeCommitmentConservation() public {
        check_releaseCommitmentPreservesReservePartition(1_000 ether, 400);
    }

    function testRepresentativeClaimAndRecycleConservation() public {
        check_claimAndRecycleConserveBackedReserve(1_000 ether, 400, 10 ether);
    }

    function check_releaseCommitmentPreservesReservePartition(uint96 reserveAmount, uint16 releaseBps) public {
        vm.assume(releaseBps <= MAX_RELEASE_BPS);
        reserve.initialize(releaseBps);
        reserve.defer(reserveAmount, 0);
        assertEq(reserve.rollDeferred(1), reserveAmount);

        uint256 budget = Math.mulDiv(reserveAmount, releaseBps, BPS);
        reserve.commit(budget);
        (uint16 storedRate, uint256 available, uint256 deferred, uint256 committed) = reserve.state();
        assertEq(storedRate, releaseBps);
        assertEq(committed, budget);
        assertEq(deferred, 0);
        assertEq(available + committed, reserveAmount);
    }

    function check_claimAndRecycleConserveBackedReserve(uint96 reserveAmount, uint16 releaseBps, uint96 recycledAmount)
        public
    {
        vm.assume(releaseBps <= MAX_RELEASE_BPS);
        uint256 budget = Math.mulDiv(reserveAmount, releaseBps, BPS);
        vm.assume(recycledAmount <= budget);
        reserve.initialize(releaseBps);
        reserve.defer(reserveAmount, 0);
        reserve.rollDeferred(1);
        reserve.commit(budget);

        uint256 claimed = budget - recycledAmount;
        reserve.consumeCommitted(claimed);
        reserve.consumeCommitted(recycledAmount);
        reserve.recycle(recycledAmount, 1, 1);

        (, uint256 available, uint256 deferred, uint256 committed) = reserve.state();
        assertEq(committed, 0);
        assertEq(deferred, recycledAmount);
        assertEq(available + deferred + claimed, reserveAmount);
    }
}
