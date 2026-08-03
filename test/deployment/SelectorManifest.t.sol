// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsBasketLaunchModule} from "../../src/interfaces/IStaticsBasketLaunchModule.sol";
import {IStaticsBorrowLiquidity} from "../../src/interfaces/IStaticsBorrowLiquidity.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsLiquidityRewards} from "../../src/interfaces/IStaticsLiquidityRewards.sol";
import {IStaticsLending} from "../../src/interfaces/IStaticsLending.sol";
import {IModularPositionNFT} from "../../src/interfaces/IModularPositionNFT.sol";
import {
    IStaticsPosition,
    IStaticsPositionFees,
    IStaticsPositionModule
} from "../../src/interfaces/IStaticsPosition.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";

contract SelectorManifestTest is Test {
    function testPositionSelectorManifestIncludesCreationFeeConfiguration() public pure {
        assertEq(type(IModularPositionNFT).interfaceId, bytes4(0x212b8e93));
        bytes4[] memory selectors = StaticsSelectors.position();
        assertEq(selectors.length, 23);
        assertEq(selectors[12], IStaticsPosition.createPosition.selector);
        assertEq(selectors[17], IModularPositionNFT.positionState.selector);
        assertEq(selectors[18], IModularPositionNFT.isLegActive.selector);
        assertEq(selectors[19], IModularPositionNFT.isPositionClosable.selector);
        assertEq(selectors[20], IStaticsPositionModule.createPositionForModule.selector);
        assertEq(selectors[21], IStaticsPositionFees.setPositionCreationFee.selector);
        assertEq(selectors[22], IStaticsPositionFees.positionCreationFee.selector);
        for (uint256 i; i < selectors.length; ++i) {
            for (uint256 j; j < i; ++j) {
                assertNotEq(selectors[i], selectors[j]);
            }
        }
    }

    function testLiquiditySelectorManifestIsExactAndCollisionFree() public pure {
        bytes4[] memory actual = StaticsSelectors.basketLiquidity();
        bytes4[] memory expected = new bytes4[](17);
        expected[0] = IStaticsBasketLiquidity.installCanonicalPoolIntegration.selector;
        expected[1] = IStaticsBasketLiquidity.installLiquidityManager.selector;
        expected[2] = IStaticsBasketLaunchModule.launchBasketPools.selector;
        expected[3] = IStaticsBasketLaunchModule.mintBasketLaunch.selector;
        expected[4] = IStaticsBasketLiquidity.checkpointCanonicalPool.selector;
        expected[5] = IStaticsBasketLiquidity.activateCanonicalPool.selector;
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
        assertEq(selectors.length, 2);
        assertEq(selectors[0], IStaticsBorrowLiquidity.borrowAndProvideLiquidity.selector);
        assertEq(selectors[1], IStaticsBorrowLiquidity.borrowAndStakeLiquidity.selector);
    }

    function testLendingSelectorManifestIsExactAndCollisionFree() public pure {
        bytes4[] memory actual = StaticsSelectors.lending();
        bytes4[] memory expected = new bytes4[](9);
        expected[0] = IStaticsLending.borrow.selector;
        expected[1] = IStaticsLending.repay.selector;
        expected[2] = IStaticsLending.extend.selector;
        expected[3] = IStaticsLending.recover.selector;
        expected[4] = IStaticsLending.quoteBorrow.selector;
        expected[5] = IStaticsLending.quoteRecovery.selector;
        expected[6] = IStaticsLending.quoteExtension.selector;
        expected[7] = IStaticsLending.loan.selector;
        expected[8] = IStaticsLending.outstandingPrincipal.selector;
        assertEq(actual.length, expected.length);
        for (uint256 i; i < actual.length; ++i) {
            assertEq(actual[i], expected[i]);
            for (uint256 j; j < i; ++j) {
                assertNotEq(actual[i], actual[j]);
            }
        }
    }

    function testGlobalRewardsSelectorManifestIsExactAndCollisionFree() public pure {
        bytes4[] memory actual = StaticsSelectors.globalRewards();
        bytes4[] memory expected = new bytes4[](21);
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
        expected[12] = IStaticsGlobalRewards.rewardSelection.selector;
        expected[13] = IStaticsGlobalRewards.maxRewardAssetsPerPosition.selector;
        expected[14] = IStaticsGlobalRewards.rewardEligibilityDelay.selector;
        expected[15] = IStaticsGlobalRewards.rewardEligibilityBucketSize.selector;
        expected[16] = IStaticsGlobalRewards.stakingToken.selector;
        expected[17] = IStaticsGlobalRewards.totalStaked.selector;
        expected[18] = IStaticsGlobalRewards.treasuryAccrued.selector;
        expected[19] = IStaticsGlobalRewards.canAccrueStakerRewards.selector;
        expected[20] = IStaticsGlobalRewards.routeSwapFees.selector;
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
        bytes4[] memory expected = new bytes4[](11);
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
        expected[10] = IStaticsLiquidityRewards.canAccrueBasketRewards.selector;
        assertEq(actual.length, expected.length);
        for (uint256 i; i < actual.length; ++i) {
            assertEq(actual[i], expected[i]);
            for (uint256 j; j < i; ++j) {
                assertNotEq(actual[i], actual[j]);
            }
        }
    }
}
