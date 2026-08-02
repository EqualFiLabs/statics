// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsBorrowLiquidity} from "../../src/interfaces/IStaticsBorrowLiquidity.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";

contract SelectorManifestTest is Test {
    function testLiquiditySelectorManifestIsExactAndCollisionFree() public pure {
        bytes4[] memory actual = StaticsSelectors.basketLiquidity();
        bytes4[] memory expected = new bytes4[](25);
        expected[0] = IStaticsBasketLiquidity.liquidityReserve.selector;
        expected[1] = IStaticsBasketLiquidity.cumulativePrimaryFees.selector;
        expected[2] = IStaticsBasketLiquidity.installCanonicalPoolIntegration.selector;
        expected[3] = IStaticsBasketLiquidity.initializeCanonicalPool.selector;
        expected[4] = IStaticsBasketLiquidity.checkpointCanonicalPool.selector;
        expected[5] = IStaticsBasketLiquidity.activateCanonicalPool.selector;
        expected[6] = IStaticsBasketLiquidity.liquidityIntegration.selector;
        expected[7] = IStaticsBasketLiquidity.liquiditySafetyParameters.selector;
        expected[8] = IStaticsBasketLiquidity.canonicalPool.selector;
        expected[9] = IStaticsBasketLiquidity.settleCanonicalHookFees.selector;
        expected[10] = IStaticsBasketLiquidity.pendingCanonicalHookFees.selector;
        expected[11] = IStaticsBasketLiquidity.cumulativeCanonicalHookSettlement.selector;
        expected[12] = IStaticsBasketLiquidity.cumulativeHookRevenue.selector;
        expected[13] = IStaticsBasketLiquidity.installLiquidityManager.selector;
        expected[14] = IStaticsBasketLiquidity.syncCanonicalPoolToManager.selector;
        expected[15] = IStaticsBasketLiquidity.compoundBasketLiquidity.selector;
        expected[16] = IStaticsBasketLiquidity.liquidityManager.selector;
        expected[17] = IStaticsBasketLiquidity.basketLiquidityState.selector;
        expected[18] = IStaticsBasketLiquidity.cumulativeLiquidityFunding.selector;
        expected[19] = IStaticsBasketLiquidity.liquidityEpochParameters.selector;
        expected[20] = IStaticsBasketLiquidity.collectProtocolLpFees.selector;
        expected[21] = IStaticsBasketLiquidity.cumulativeProtocolLpFees.selector;
        expected[22] = IStaticsBasketLiquidity.protocolLpFeeAllocation.selector;
        expected[23] = IStaticsBasketLiquidity.unwindBasketLiquidity.selector;
        expected[24] = IStaticsBasketLiquidity.basketLiquidityUnwound.selector;

        assertEq(actual.length, expected.length);
        for (uint256 i; i < actual.length; ++i) {
            assertEq(actual[i], expected[i]);
            for (uint256 j; j < i; ++j) {
                assertNotEq(actual[i], actual[j]);
            }
        }
    }

    function testBorrowLiquiditySelectorManifestIsExact() public pure {
        bytes4[] memory selectors = StaticsSelectors.borrowLiquidity();
        assertEq(selectors.length, 1);
        assertEq(selectors[0], IStaticsBorrowLiquidity.borrowAndProvideLiquidity.selector);
    }
}
