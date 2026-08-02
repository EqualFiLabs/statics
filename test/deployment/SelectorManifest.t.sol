// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsBorrowLiquidity} from "../../src/interfaces/IStaticsBorrowLiquidity.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsLiquidityRewards} from "../../src/interfaces/IStaticsLiquidityRewards.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";

contract SelectorManifestTest is Test {
    function testLiquiditySelectorManifestIsExactAndCollisionFree() public pure {
        bytes4[] memory actual = StaticsSelectors.basketLiquidity();
        bytes4[] memory expected = new bytes4[](17);
        expected[0] = IStaticsBasketLiquidity.installCanonicalPoolIntegration.selector;
        expected[1] = IStaticsBasketLiquidity.installLiquidityManager.selector;
        expected[2] = IStaticsBasketLiquidity.initializeCanonicalPool.selector;
        expected[3] = IStaticsBasketLiquidity.checkpointCanonicalPool.selector;
        expected[4] = IStaticsBasketLiquidity.activateCanonicalPool.selector;
        expected[5] = IStaticsBasketLiquidity.syncCanonicalPoolToManager.selector;
        expected[6] = IStaticsBasketLiquidity.setSwapFeeConfiguration.selector;
        expected[7] = IStaticsBasketLiquidity.unwindBasketLiquidity.selector;
        expected[8] = IStaticsBasketLiquidity.liquidityIntegration.selector;
        expected[9] = IStaticsBasketLiquidity.liquidityManager.selector;
        expected[10] = IStaticsBasketLiquidity.liquiditySafetyParameters.selector;
        expected[11] = IStaticsBasketLiquidity.canonicalPool.selector;
        expected[12] = IStaticsBasketLiquidity.swapFeeConfiguration.selector;
        expected[13] = IStaticsBasketLiquidity.basketLiquidityUnwound.selector;
        expected[14] = IStaticsBasketLiquidity.setCanonicalPoolFeeConfiguration.selector;
        expected[15] = IStaticsBasketLiquidity.clearCanonicalPoolFeeConfiguration.selector;
        expected[16] = IStaticsBasketLiquidity.canonicalPoolFeeConfiguration.selector;

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

    function testGlobalRewardsSelectorManifestIsExactAndCollisionFree() public pure {
        bytes4[] memory actual = StaticsSelectors.globalRewards();
        bytes4[] memory expected = new bytes4[](18);
        expected[0] = IStaticsGlobalRewards.createAndStake.selector;
        expected[1] = IStaticsGlobalRewards.stake.selector;
        expected[2] = IStaticsGlobalRewards.unstake.selector;
        expected[3] = IStaticsGlobalRewards.optInRewardAssets.selector;
        expected[4] = IStaticsGlobalRewards.optOutRewardAssets.selector;
        expected[5] = IStaticsGlobalRewards.claimRewards.selector;
        expected[6] = IStaticsGlobalRewards.distributeTreasuryFees.selector;
        expected[7] = IStaticsGlobalRewards.pendingRewards.selector;
        expected[8] = IStaticsGlobalRewards.stakePosition.selector;
        expected[9] = IStaticsGlobalRewards.rewardAsset.selector;
        expected[10] = IStaticsGlobalRewards.positionRewardAssets.selector;
        expected[11] = IStaticsGlobalRewards.isRewardAssetOptedIn.selector;
        expected[12] = IStaticsGlobalRewards.maxRewardAssetsPerPosition.selector;
        expected[13] = IStaticsGlobalRewards.stakingToken.selector;
        expected[14] = IStaticsGlobalRewards.totalStaked.selector;
        expected[15] = IStaticsGlobalRewards.treasuryAccrued.selector;
        expected[16] = IStaticsGlobalRewards.canAccrueStakerRewards.selector;
        expected[17] = IStaticsGlobalRewards.routeSwapFees.selector;
        assertEq(actual.length, expected.length);
        for (uint256 i; i < actual.length; ++i) {
            assertEq(actual[i], expected[i]);
            for (uint256 j; j < i; ++j) {
                assertNotEq(actual[i], actual[j]);
            }
        }
    }

    function testLiquidityRewardsSelectorManifestIsExactAndCollisionFree() public pure {
        bytes4[] memory actual = StaticsSelectors.liquidityRewards();
        bytes4[] memory expected = new bytes4[](10);
        expected[0] = IStaticsLiquidityRewards.stakeLiquidityPosition.selector;
        expected[1] = IStaticsLiquidityRewards.activateLiquidityPosition.selector;
        expected[2] = IStaticsLiquidityRewards.increaseStakedLiquidity.selector;
        expected[3] = IStaticsLiquidityRewards.unstakeLiquidityPosition.selector;
        expected[4] = IStaticsLiquidityRewards.claimLiquidityRewards.selector;
        expected[5] = IStaticsLiquidityRewards.routeCanonicalSwapFees.selector;
        expected[6] = IStaticsLiquidityRewards.stakedLiquidityPosition.selector;
        expected[7] = IStaticsLiquidityRewards.poolLiquidityRewards.selector;
        expected[8] = IStaticsLiquidityRewards.pendingLiquidityRewards.selector;
        expected[9] = IStaticsLiquidityRewards.canAccrueLiquidityRewards.selector;
        assertEq(actual.length, expected.length);
        for (uint256 i; i < actual.length; ++i) {
            assertEq(actual[i], expected[i]);
            for (uint256 j; j < i; ++j) {
                assertNotEq(actual[i], actual[j]);
            }
        }
    }
}
