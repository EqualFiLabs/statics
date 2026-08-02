// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LibSolvencyIndex} from "src/dollar/core/libraries/LibSolvencyIndex.sol";

contract SolvencyIndexHarness {
    using LibSolvencyIndex for LibSolvencyIndex.Tree;

    LibSolvencyIndex.Tree internal tree;

    function update(uint256 bookId, uint256 liabilityWad, uint256 collateralWad) external {
        tree.update(bytes32(bookId), liabilityWad, collateralWad);
    }

    function remove(uint256 bookId) external {
        tree.remove(bytes32(bookId));
    }

    function deficitAt(uint256 priceWad)
        external
        view
        returns (uint256 deficitWad, uint256 liabilityWad, uint256 collateralWad, uint256 count)
    {
        return tree.deficitAt(priceWad);
    }

    function contribution(uint256 bookId) external view returns (LibSolvencyIndex.BookContribution memory) {
        return tree.bookContribution(bytes32(bookId));
    }

    function rootHeight() external view returns (uint256) {
        return tree.rootHeight();
    }

    function activeBooks() external view returns (uint256) {
        return tree.activeBooks;
    }
}

contract CoreSolvencyIndexInvariantsTest is Test {
    uint256 internal constant WAD = 1e18;

    function test_DuplicatePricesZeroCollateralAndRemovalStayExact() public {
        SolvencyIndexHarness index = new SolvencyIndexHarness();
        index.update(1, 100e18, 50e18);
        index.update(2, 200e18, 100e18);
        index.update(3, 7e18, 0);
        (uint256 deficit, uint256 liability, uint256 collateral, uint256 count) = index.deficitAt(1e18);
        assertEq(deficit, 157e18 + 1);
        assertEq(liability, 307e18);
        assertEq(collateral, 150e18);
        assertEq(count, 3);

        index.remove(1);
        index.update(2, 50e18, 100e18);
        index.remove(3);
        (deficit, liability, collateral, count) = index.deficitAt(1e18);
        assertEq(deficit, 0);
        assertEq(liability, 0);
        assertEq(collateral, 0);
        assertEq(count, 0);
        assertEq(index.activeBooks(), 1);
    }

    function testFuzz_IndexNeverUnderstatesSlowReference(
        uint128[16] memory rawLiabilities,
        uint128[16] memory rawCollateral,
        uint128 rawPrice
    ) public {
        SolvencyIndexHarness index = new SolvencyIndexHarness();
        uint256 priceWad = bound(uint256(rawPrice), 1, 1e24);
        uint256 slowDeficit;
        for (uint256 i; i < rawLiabilities.length; i++) {
            uint256 liabilityWad = bound(uint256(rawLiabilities[i]), 0, 1e30);
            uint256 collateralWad = bound(uint256(rawCollateral[i]), 0, 1e30);
            index.update(i + 1, liabilityWad, collateralWad);
            uint256 collateralValue = Math.mulDiv(collateralWad, priceWad, WAD);
            if (liabilityWad > collateralValue) slowDeficit += liabilityWad - collateralValue;
        }
        (uint256 indexedDeficit,,,) = index.deficitAt(priceWad);
        assertGe(indexedDeficit, slowDeficit);
        assertLe(indexedDeficit - slowDeficit, rawLiabilities.length - 1);
    }

    function testFuzz_UpdateAndDeleteMatchSlowReference(
        uint96 firstLiability,
        uint96 firstCollateral,
        uint96 secondLiability,
        uint96 secondCollateral,
        uint96 rawPrice
    ) public {
        SolvencyIndexHarness index = new SolvencyIndexHarness();
        uint256 priceWad = bound(uint256(rawPrice), 1, 1e24);
        index.update(1, uint256(firstLiability), uint256(firstCollateral));
        index.update(1, uint256(secondLiability), uint256(secondCollateral));
        uint256 collateralValue = Math.mulDiv(uint256(secondCollateral), priceWad, WAD);
        uint256 expected = uint256(secondLiability) > collateralValue ? uint256(secondLiability) - collateralValue : 0;
        (uint256 actual,,,) = index.deficitAt(priceWad);
        assertEq(actual, expected);
        if (secondLiability != 0) index.remove(1);
        (actual,,,) = index.deficitAt(priceWad);
        assertEq(actual, 0);
        assertEq(index.activeBooks(), 0);
    }

    function test_RemovingInternalNodesPreservesEverySuffixAggregate() public {
        SolvencyIndexHarness index = new SolvencyIndexHarness();
        for (uint256 i = 1; i <= 127; i++) {
            index.update(i, i * WAD, WAD);
        }
        for (uint256 i = 2; i <= 126; i += 2) {
            index.remove(i);
        }
        assertEq(index.activeBooks(), 64);
        assertLe(index.rootHeight(), 8);

        for (uint256 price; price <= 127; price++) {
            uint256 expected;
            uint256 expectedCount;
            for (uint256 book = 1; book <= 127; book += 2) {
                if (book > price) {
                    expected += (book - price) * WAD;
                    expectedCount++;
                }
            }
            (uint256 deficit,,, uint256 count) = index.deficitAt(price * WAD);
            assertGe(deficit, expected);
            if (count != 0) assertLe(deficit - expected, count - 1);
            assertEq(count, expectedCount);
        }
    }

    function test_TenThousandBookHeightAndQueryGasRemainBounded() public {
        SolvencyIndexHarness index = new SolvencyIndexHarness();
        vm.pauseGasMetering();
        for (uint256 i = 1; i <= 10_000; i++) {
            index.update(i, i * WAD, WAD);
        }
        vm.resumeGasMetering();
        assertLe(index.rootHeight(), 20);
        uint256 gasBefore = gasleft();
        (uint256 deficit,,,) = index.deficitAt(5_000e18);
        uint256 gasUsed = gasBefore - gasleft();
        assertGt(deficit, 0);
        assertLt(gasUsed, 250_000);

        gasBefore = gasleft();
        index.update(10_001, 5_001e18, WAD);
        gasUsed = gasBefore - gasleft();
        assertLt(gasUsed, 1_000_000);
        assertLe(index.rootHeight(), 20);
    }
}
