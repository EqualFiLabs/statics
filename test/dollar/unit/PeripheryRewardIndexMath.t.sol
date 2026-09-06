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

    function addPosition(uint256 positionId, uint256 amount) external {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        LibPeriphery.SeriesBook storage book = ps.series[SERIES_ID];
        LibPeriphery.PositionLeg storage leg = ps.leg[positionId][SERIES_ID];
        leg.exists = true;
        leg.epoch = book.epoch;
        leg.stored += LibPeriphery.addLiquidity(book, amount);
    }

    function accrueReserved(address token, uint256 amount, LibPeriphery.IncentiveKind kind) external {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        LibPeriphery.SeriesBook storage book = ps.series[SERIES_ID];
        LibPeriphery.reserve(ps, token, amount);
        LibPeriphery.accrueReservedRiskIncentive(
            ps, SERIES_ID, book.epoch, book.totalStored, token, amount, kind, "INCENTIVE"
        );
    }

    function settle(uint256 positionId) external {
        LibPeriphery.settleLeg(LibPeriphery.s(), positionId, SERIES_ID);
    }

    function pending(uint256 positionId)
        external
        view
        returns (uint256 collateral, uint256 staticsDollar, uint256 statics)
    {
        return LibPeriphery.pendingProceeds(LibPeriphery.s(), positionId, SERIES_ID);
    }

    function accrued(uint256 positionId)
        external
        view
        returns (uint256 collateral, uint256 staticsDollar, uint256 statics)
    {
        LibPeriphery.PositionLeg storage leg = LibPeriphery.s().leg[positionId][SERIES_ID];
        return (leg.accruedCollateral, leg.accruedStaticsDollar, leg.accruedStatics);
    }

    function indexAccounting(LibPeriphery.IncentiveKind kind)
        external
        view
        returns (uint256 remainder, uint256 funded, uint256 crystallized)
    {
        LibPeriphery.SeriesBook storage book = LibPeriphery.s().series[SERIES_ID];
        LibPeriphery.ProceedsIndex storage index;
        if (kind == LibPeriphery.IncentiveKind.Collateral) index = book.collateralProceeds[0];
        else if (kind == LibPeriphery.IncentiveKind.StaticsDollar) index = book.staticsDollarProceeds[0];
        else index = book.staticsProceeds[0];
        return (index.remainderRay, index.fundedAmount, index.crystallizedAmount);
    }

    function clearZeroValueLiquidity(uint256 positionId) external returns (uint256 clearedStored) {
        return LibPeriphery.clearZeroValueLiquidity(LibPeriphery.s(), positionId, SERIES_ID);
    }

    function reserved(address token) external view returns (uint256) {
        return LibPeriphery.s().reservedByToken[token];
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

    function test_FinalOldEpochLegReceivesEveryTerminalResidue() public {
        MockERC20 dollar = new MockERC20("Dollar", "DOL", 18);
        MockERC20 statics = new MockERC20("Statics", "STX", 18);
        token.mint(address(harness), 1);
        dollar.mint(address(harness), 1);
        statics.mint(address(harness), 1);
        harness.addPosition(1, 1);
        harness.addPosition(2, 2);
        harness.accrueReserved(address(token), 1, LibPeriphery.IncentiveKind.Collateral);
        harness.accrueReserved(address(dollar), 1, LibPeriphery.IncentiveKind.StaticsDollar);
        harness.accrueReserved(address(statics), 1, LibPeriphery.IncentiveKind.Statics);

        harness.consume(3);
        harness.settle(1);
        (uint256 firstCollateral, uint256 firstDollar, uint256 firstStatics) = harness.accrued(1);
        assertEq(firstCollateral, 0);
        assertEq(firstDollar, 0);
        assertEq(firstStatics, 0);
        (uint256 pendingCollateral, uint256 pendingDollar, uint256 pendingStatics) = harness.pending(2);
        assertEq(pendingCollateral, 1);
        assertEq(pendingDollar, 1);
        assertEq(pendingStatics, 1);

        harness.settle(2);
        (uint256 finalCollateral, uint256 finalDollar, uint256 finalStatics) = harness.accrued(2);
        assertEq(finalCollateral, 1);
        assertEq(finalDollar, 1);
        assertEq(finalStatics, 1);
        _assertClosedIndex(LibPeriphery.IncentiveKind.Collateral);
        _assertClosedIndex(LibPeriphery.IncentiveKind.StaticsDollar);
        _assertClosedIndex(LibPeriphery.IncentiveKind.Statics);
        assertEq(harness.reserved(address(token)), 1);
        assertEq(harness.reserved(address(dollar)), 1);
        assertEq(harness.reserved(address(statics)), 1);
    }

    function test_SettlementOrderChangesOnlyTheResidueRecipient() public {
        token.mint(address(harness), 1);
        harness.addPosition(1, 1);
        harness.addPosition(2, 2);
        harness.accrueReserved(address(token), 1, LibPeriphery.IncentiveKind.Collateral);
        harness.consume(3);

        harness.settle(2);
        harness.settle(1);

        (uint256 first,,) = harness.accrued(1);
        (uint256 second,,) = harness.accrued(2);
        assertEq(first + second, 1);
        assertEq(first, 1);
        _assertClosedIndex(LibPeriphery.IncentiveKind.Collateral);
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

    function _assertClosedIndex(LibPeriphery.IncentiveKind kind) private view {
        (uint256 remainder, uint256 funded, uint256 crystallized) = harness.indexAccounting(kind);
        assertEq(remainder, 0);
        assertEq(funded, 1);
        assertEq(crystallized, funded);
    }
}
