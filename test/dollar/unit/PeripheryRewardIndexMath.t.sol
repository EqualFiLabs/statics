// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibPeriphery} from "src/dollar/periphery/libraries/LibPeriphery.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract PeripheryConsumptionMathHarness {
    uint256 internal constant SERIES_ID = 1;

    function addLiquidity(uint256 amount) external returns (uint256 storedAdded) {
        return LibPeriphery.addLiquidity(LibPeriphery.s().series[SERIES_ID], amount);
    }

    function consume(uint256 amount) external returns (uint256 scaleRay) {
        return LibPeriphery.consume(LibPeriphery.s(), SERIES_ID, amount);
    }

    function accrue(address token, uint256 totalStored, uint256 amount)
        external
        returns (uint256 delta, uint256 remainder)
    {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        LibPeriphery.ProceedsIndex storage index = ps.series[SERIES_ID].collateralProceeds[0];
        uint256 beforeIndex = index.accPerStoredRay;
        LibPeriphery.accrueRiskProceeds(ps, SERIES_ID, 0, totalStored, token, amount, "FILL");
        delta = index.accPerStoredRay - beforeIndex;
        remainder = index.remainderRay;
    }

    function state() external view returns (uint256 totalStored, uint256 effectivePrincipal, uint256 scaleRay) {
        LibPeriphery.SeriesBook storage book = LibPeriphery.s().series[SERIES_ID];
        return (book.totalStored, book.effectivePrincipal, book.scaleRay);
    }

    function proportionalRelease(uint256 reserve, uint256 fill, uint256 availableBefore)
        external
        pure
        returns (uint256)
    {
        return LibPeriphery.proportionalRelease(reserve, fill, availableBefore);
    }
}

contract PeripheryRewardIndexMathTest is Test {
    uint256 internal constant RAY = 1e27;

    PeripheryConsumptionMathHarness internal harness;
    MockERC20 internal token;

    function setUp() public {
        harness = new PeripheryConsumptionMathHarness();
        token = new MockERC20("Collateral", "COL", 18);
    }

    function test_ConsumptionIndexHandlesRepresentableQuotientAboveRawProductLimit() public {
        uint256 amount = uint256(1) << 230;
        uint256 denominator = uint256(1) << 220;
        token.mint(address(harness), amount);

        (uint256 delta, uint256 remainder) = harness.accrue(address(token), denominator, amount);

        assertEq(delta, Math.mulDiv(amount, RAY, denominator));
        assertEq(remainder, mulmod(amount, RAY, denominator));
    }

    function testFuzz_PartialConsumptionPreservesPositiveScale(uint256 rawSupply, uint256 rawFill) public {
        uint256 supply = bound(rawSupply, 2, type(uint128).max);
        uint256 minimumRemainder = Math.ceilDiv(supply, RAY);
        uint256 fill = bound(rawFill, 1, supply - minimumRemainder);
        harness.addLiquidity(supply);

        uint256 scaleRay = harness.consume(fill);
        (uint256 totalStored, uint256 effectivePrincipal,) = harness.state();

        assertEq(totalStored, supply);
        assertEq(effectivePrincipal, supply - fill);
        assertEq(scaleRay, Math.mulDiv(supply - fill, RAY, supply));
        assertGt(scaleRay, 0);
    }

    function testFuzz_IncentiveReleaseIsProportionalAndFullFillDrainsRemainder(
        uint256 rawReserve,
        uint256 rawAvailable,
        uint256 rawFill
    ) public view {
        uint256 reserve = bound(rawReserve, 1, type(uint128).max);
        uint256 available = bound(rawAvailable, 1, type(uint128).max);
        uint256 fill = bound(rawFill, 1, available);
        uint256 released = harness.proportionalRelease(reserve, fill, available);

        if (fill == available) {
            assertEq(released, reserve);
        } else {
            assertEq(released, Math.mulDiv(reserve, fill, available));
            assertLe(released, reserve);
        }
    }
}
