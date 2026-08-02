// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibPeriphery} from "src/dollar/periphery/libraries/LibPeriphery.sol";

contract PeripheryRewardIndexHarness {
    uint256 internal constant SERIES_ID = 1;
    uint64 internal constant EPOCH = 1;
    address internal constant REWARD_TOKEN = address(1);

    function accruePassive(uint256 denominator, uint256 amount) external returns (uint256 delta, uint256 remainder) {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        LibPeriphery.SeriesBook storage book = ps.series[SERIES_ID];
        book.eligiblePrincipal = denominator;
        uint256 beforeIndex = book.collateralPassive.accPerStoredRay;
        LibPeriphery.accruePassive(ps, SERIES_ID, REWARD_TOKEN, amount, "TEST", true);
        delta = book.collateralPassive.accPerStoredRay - beforeIndex;
        remainder = book.collateralPassive.remainderRay;
    }

    function accrueOptIn(uint256 denominator, uint256 amount) external returns (uint256 delta, uint256 remainder) {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        LibPeriphery.RewardIndex storage index = ps.series[SERIES_ID].collateralOptIn[EPOCH];
        uint256 beforeIndex = index.accPerStoredRay;
        LibPeriphery.accrueOptIn(ps, SERIES_ID, EPOCH, denominator, REWARD_TOKEN, amount, "TEST", true);
        delta = index.accPerStoredRay - beforeIndex;
        remainder = index.remainderRay;
    }
}

contract PeripheryRewardIndexMathTest is Test {
    uint256 internal constant RAY = 1e27;

    PeripheryRewardIndexHarness internal harness;

    function setUp() public {
        harness = new PeripheryRewardIndexHarness();
    }

    function test_PassiveIndexHandlesRepresentableQuotientAboveRawProductLimit() public {
        _assertLargeAccrual(false);
    }

    function test_OptInIndexHandlesRepresentableQuotientAboveRawProductLimit() public {
        _assertLargeAccrual(true);
    }

    function _assertLargeAccrual(bool optIn) private {
        uint256 amount = uint256(1) << 230;
        uint256 denominator = uint256(1) << 220;
        uint256 expectedDelta = Math.mulDiv(amount, RAY, denominator);
        uint256 expectedRemainder = mulmod(amount, RAY, denominator);

        (uint256 delta, uint256 remainder) =
            optIn ? harness.accrueOptIn(denominator, amount) : harness.accruePassive(denominator, amount);

        assertEq(delta, expectedDelta);
        assertEq(remainder, expectedRemainder);
    }
}
