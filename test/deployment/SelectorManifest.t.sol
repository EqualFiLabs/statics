// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsBasketLaunchModule} from "../../src/interfaces/IStaticsBasketLaunchModule.sol";
import {IStaticsBorrowLiquidity} from "../../src/interfaces/IStaticsBorrowLiquidity.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsLiquidityRewards} from "../../src/interfaces/IStaticsLiquidityRewards.sol";
import {IStaticsLending} from "../../src/interfaces/IStaticsLending.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsProtocolRevenue} from "../../src/interfaces/IStaticsProtocolRevenue.sol";
import {IModularPositionNFT} from "../../src/interfaces/IModularPositionNFT.sol";
import {IPositionOwnerIndex} from "../../src/interfaces/IPositionOwnerIndex.sol";
import {IERC5192} from "../../src/interfaces/IERC5192.sol";
import {IStaticsPositionPortfolio} from "../../src/interfaces/IStaticsPositionPortfolio.sol";
import {IStaticsGenesisIntegration} from "../../src/interfaces/IStaticsGenesisIntegration.sol";
import {IStaticsMorpho} from "../../src/interfaces/IStaticsMorpho.sol";
import {
    IStaticsPosition,
    IStaticsPositionFees,
    IStaticsPositionModule
} from "../../src/interfaces/IStaticsPosition.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";

contract SelectorManifestTest is Test {
    function testGenesisNFTSelectorManifestIsExactAndCollisionFree() public pure {
        bytes4[] memory actual = StaticsSelectors.genesisNFT();
        bytes4[] memory expected = new bytes4[](34);
        expected[0] = IStaticsGenesisIntegration.linkGenesis.selector;
        expected[1] = IStaticsGenesisIntegration.unlinkGenesis.selector;
        expected[2] = IStaticsGenesisIntegration.linkedGenesis.selector;
        expected[3] = IStaticsGenesisIntegration.linkedPosition.selector;
        expected[4] = IStaticsGenesisIntegration.genesisCollection.selector;
        expected[5] = IStaticsGenesisIntegration.genesisRecoveryVault.selector;
        expected[6] = IStaticsGenesisIntegration.genesisRecoveryAsset.selector;
        expected[7] = IStaticsGenesisIntegration.genesisRecoveryReady.selector;
        expected[8] = IStaticsGenesisIntegration.genesisIntegrationReady.selector;
        expected[9] = IStaticsGenesisIntegration.genesisRecoveryCallback.selector;
        expected[10] = IStaticsGenesisIntegration.onGenesisRecovery.selector;
        expected[11] = IStaticsGenesisIntegration.onGenesisTransition.selector;
        expected[12] = IStaticsGenesisIntegration.acceptGenesisDistributorRole.selector;
        expected[13] = IStaticsGenesisIntegration.acceptGenesisConsumerRole.selector;
        expected[14] = IStaticsGenesisIntegration.registerGenesis.selector;
        expected[15] = IStaticsGenesisIntegration.accrueGenesisRewards.selector;
        expected[16] = IStaticsGenesisIntegration.claimGenesisRewards.selector;
        expected[17] = IStaticsGenesisIntegration.claimGenesisOwnerRewards.selector;
        expected[18] = IStaticsGenesisIntegration.claimGenesisTreasuryRewards.selector;
        expected[19] = IStaticsGenesisIntegration.setGenesisRewardShareBps.selector;
        expected[20] = IStaticsGenesisIntegration.checkpointGenesisRecovery.selector;
        expected[21] = IStaticsGenesisIntegration.accrueGenesisRecovery.selector;
        expected[22] = IStaticsGenesisIntegration.migratePendingGenesisRecovery.selector;
        expected[23] = IStaticsGenesisIntegration.acceptPendingGenesisRecovery.selector;
        expected[24] = IStaticsGenesisIntegration.pendingGenesisRewards.selector;
        expected[25] = IStaticsGenesisIntegration.genesisRewardBook.selector;
        expected[26] = IStaticsGenesisIntegration.genesisRegistered.selector;
        expected[27] = IStaticsGenesisIntegration.genesisEffectiveWeight.selector;
        expected[28] = IStaticsGenesisIntegration.genesisTotalWeight.selector;
        expected[29] = IStaticsGenesisIntegration.genesisRewardShareBps.selector;
        expected[30] = IStaticsGenesisIntegration.genesisOwnerClaimable.selector;
        expected[31] = IStaticsGenesisIntegration.pendingGenesisRecovery.selector;
        expected[32] = IStaticsGenesisIntegration.claimAllGenesisRewards.selector;
        expected[33] = IStaticsGenesisIntegration.claimAllGenesisTreasuryRewards.selector;
        assertEq(actual.length, expected.length);
        for (uint256 i; i < actual.length; ++i) {
            assertEq(actual[i], expected[i]);
            for (uint256 j; j < i; ++j) {
                assertNotEq(actual[i], actual[j]);
            }
        }
    }

    function testPositionSelectorManifestIncludesFeesAndOwnerIndex() public pure {
        assertEq(type(IModularPositionNFT).interfaceId, bytes4(0x212b8e93));
        assertEq(type(IPositionOwnerIndex).interfaceId, bytes4(0x7ef5913d));
        bytes4[] memory selectors = StaticsSelectors.position();
        assertEq(selectors.length, 27);
        assertEq(selectors[12], IStaticsPosition.createPosition.selector);
        assertEq(selectors[17], IModularPositionNFT.positionState.selector);
        assertEq(selectors[18], IModularPositionNFT.isLegActive.selector);
        assertEq(selectors[26], IERC5192.locked.selector);
        assertEq(selectors[19], IModularPositionNFT.isPositionClosable.selector);
        assertEq(selectors[20], IStaticsPositionModule.createPositionForModule.selector);
        assertEq(selectors[21], IStaticsPositionFees.setPositionCreationFee.selector);
        assertEq(selectors[22], IStaticsPositionFees.positionCreationFee.selector);
        assertEq(selectors[23], IPositionOwnerIndex.positionCount.selector);
        assertEq(selectors[24], IPositionOwnerIndex.positionsOfOwner.selector);
        assertEq(selectors[25], IPositionOwnerIndex.syncPositionOwnerIndex.selector);
        for (uint256 i; i < selectors.length; ++i) {
            for (uint256 j; j < i; ++j) {
                assertNotEq(selectors[i], selectors[j]);
            }
        }
    }

    function testLiquiditySelectorManifestIsExactAndCollisionFree() public pure {
        bytes4[] memory actual = StaticsSelectors.basketLiquidity();
        bytes4[] memory expected = new bytes4[](14);
        expected[0] = IStaticsBasketLiquidity.installCanonicalPoolIntegration.selector;
        expected[1] = IStaticsBasketLiquidity.installLiquidityManager.selector;
        expected[2] = IStaticsBasketLaunchModule.launchBasketPools.selector;
        expected[3] = IStaticsBasketLaunchModule.mintBasketLaunch.selector;
        expected[4] = IStaticsBasketLiquidity.setSwapFeeConfiguration.selector;
        expected[5] = IStaticsBasketLiquidity.unwindBasketLiquidity.selector;
        expected[6] = IStaticsBasketLiquidity.liquidityIntegration.selector;
        expected[7] = IStaticsBasketLiquidity.liquidityManager.selector;
        expected[8] = IStaticsBasketLiquidity.canonicalPool.selector;
        expected[9] = IStaticsBasketLiquidity.swapFeeConfiguration.selector;
        expected[10] = IStaticsBasketLiquidity.basketLiquidityUnwound.selector;
        expected[11] = IStaticsBasketLiquidity.setCanonicalPoolFeeConfiguration.selector;
        expected[12] = IStaticsBasketLiquidity.clearCanonicalPoolFeeConfiguration.selector;
        expected[13] = IStaticsBasketLiquidity.canonicalPoolFeeConfiguration.selector;

        assertEq(actual.length, expected.length);
        for (uint256 i; i < actual.length; ++i) {
            assertEq(actual[i], expected[i]);
            for (uint256 j; j < i; ++j) {
                assertNotEq(actual[i], actual[j]);
            }
        }
    }

    function testProtocolPoolCreationSelectorManifestIsExactAndCollisionFree() public pure {
        bytes4[] memory actual = StaticsSelectors.protocolPoolCreation();
        bytes4[] memory expected = new bytes4[](3);
        expected[0] = IStaticsProtocolPools.quotePool.selector;
        expected[1] = IStaticsProtocolPools.createPool.selector;
        expected[2] = IStaticsProtocolPools.invalidatePoolCreationNonce.selector;
        _assertExact(actual, expected);
    }

    function testProtocolPoolAdminSelectorManifestIsExactAndCollisionFree() public pure {
        bytes4[] memory actual = StaticsSelectors.protocolPoolAdmin();
        bytes4[] memory expected = new bytes4[](6);
        expected[0] = IStaticsProtocolPools.setPoolCreationFee.selector;
        expected[1] = IStaticsProtocolPools.setProtocolPoolFeeRate.selector;
        expected[2] = IStaticsProtocolPools.setBasketFeeAllocation.selector;
        expected[3] = IStaticsProtocolPools.setGeneralFeeAllocation.selector;
        expected[4] = IStaticsProtocolPools.decommissionGeneralPool.selector;
        expected[5] = IStaticsProtocolPools.replaceLiquidityManager.selector;
        _assertExact(actual, expected);
    }

    function testProtocolPoolViewSelectorManifestIsExactAndCollisionFree() public pure {
        bytes4[] memory actual = StaticsSelectors.protocolPoolView();
        bytes4[] memory expected = new bytes4[](8);
        expected[0] = IStaticsProtocolPools.protocolPool.selector;
        expected[1] = IStaticsProtocolPools.isProtocolPool.selector;
        expected[2] = IStaticsProtocolPools.poolCreationFee.selector;
        expected[3] = IStaticsProtocolPools.isPoolCreationNonceUsed.selector;
        expected[4] = IStaticsProtocolPools.basketFeeAllocation.selector;
        expected[5] = IStaticsProtocolPools.generalFeeAllocation.selector;
        expected[6] = IStaticsProtocolPools.protocolPoolFeeRate.selector;
        expected[7] = IStaticsProtocolPools.protocolPoolCreator.selector;
        _assertExact(actual, expected);
    }

    function testProtocolRevenueSelectorManifestIsExactAndCollisionFree() public pure {
        bytes4[] memory actual = StaticsSelectors.protocolRevenue();
        bytes4[] memory expected = new bytes4[](4);
        expected[0] = IStaticsProtocolRevenue.routeProtocolSwapFees.selector;
        expected[1] = IStaticsProtocolRevenue.claimCreatorRevenue.selector;
        expected[2] = IStaticsProtocolRevenue.creatorRevenue.selector;
        expected[3] = IStaticsProtocolRevenue.totalCreatorRevenue.selector;
        _assertExact(actual, expected);
    }

    function _assertExact(bytes4[] memory actual, bytes4[] memory expected) private pure {
        assertEq(actual.length, expected.length);
        for (uint256 i; i < actual.length; ++i) {
            assertEq(actual[i], expected[i]);
            for (uint256 j; j < i; ++j) {
                assertNotEq(actual[i], actual[j]);
            }
        }
    }

    function testPositionPortfolioSelectorManifestIsExactAndCollisionFree() public pure {
        bytes4[] memory actual = StaticsSelectors.positionPortfolio();
        bytes4[] memory expected = new bytes4[](7);
        expected[0] = IStaticsPositionPortfolio.positionPortfolioCounts.selector;
        expected[1] = IStaticsPositionPortfolio.basketIdsOfPosition.selector;
        expected[2] = IStaticsPositionPortfolio.loanIdsOfPosition.selector;
        expected[3] = IStaticsPositionPortfolio.liquidityPositionIdsOfPosition.selector;
        expected[4] = IStaticsPositionPortfolio.globalRewardAssetsOfPosition.selector;
        expected[5] = IStaticsPositionPortfolio.riskSeriesIdsOfPosition.selector;
        expected[6] = IStaticsPositionPortfolio.morphoMarketIdsOfPosition.selector;
        assertEq(actual.length, expected.length);
        for (uint256 i; i < actual.length; ++i) {
            assertEq(actual[i], expected[i]);
            for (uint256 j; j < i; ++j) {
                assertNotEq(actual[i], actual[j]);
            }
        }
    }

    function testMorphoSelectorManifestsAreExactAndCollisionFree() public pure {
        bytes4[] memory admin = StaticsSelectors.morphoAdmin();
        bytes4[] memory actions = StaticsSelectors.morphoActions();
        bytes4[] memory views = StaticsSelectors.morphoView();
        assertEq(admin.length, 5);
        assertEq(actions.length, 10);
        assertEq(views.length, 9);
        bytes4[] memory all = new bytes4[](24);
        for (uint256 i; i < admin.length; ++i) {
            all[i] = admin[i];
        }
        for (uint256 i; i < actions.length; ++i) {
            all[admin.length + i] = actions[i];
        }
        for (uint256 i; i < views.length; ++i) {
            all[admin.length + actions.length + i] = views[i];
        }
        for (uint256 i; i < all.length; ++i) {
            for (uint256 j; j < i; ++j) {
                assertNotEq(all[i], all[j]);
            }
        }
        assertEq(admin[0], IStaticsMorpho.initializeMorphoIntegration.selector);
        assertEq(actions[0], IStaticsMorpho.deployMorphoCollateral.selector);
        assertEq(views[0], IStaticsMorpho.morpho.selector);
    }

    function testBorrowLiquiditySelectorManifestIsExact() public pure {
        bytes4[] memory selectors = StaticsSelectors.borrowLiquidity();
        assertEq(selectors.length, 2);
        assertEq(selectors[0], IStaticsBorrowLiquidity.borrowAndProvideLiquidity.selector);
        assertEq(selectors[1], IStaticsBorrowLiquidity.borrowAndStakeLiquidity.selector);
    }

    function testLendingSelectorManifestIsExactAndCollisionFree() public pure {
        bytes4[] memory actual = StaticsSelectors.lending();
        bytes4[] memory expected = new bytes4[](10);
        expected[0] = IStaticsLending.borrow.selector;
        expected[1] = IStaticsLending.repay.selector;
        expected[2] = IStaticsLending.extend.selector;
        expected[3] = IStaticsLending.recover.selector;
        expected[4] = IStaticsLending.quoteBorrow.selector;
        expected[5] = IStaticsLending.quoteRecovery.selector;
        expected[6] = IStaticsLending.quoteExtension.selector;
        expected[7] = IStaticsLending.loan.selector;
        expected[8] = IStaticsLending.outstandingPrincipal.selector;
        expected[9] = IStaticsLending.recoveryGracePeriod.selector;
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
        bytes4[] memory expected = new bytes4[](23);
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
        expected[21] = IStaticsGlobalRewards.checkpointRewardAssets.selector;
        expected[22] = IStaticsGlobalRewards.rewardBookNeedsCheckpoint.selector;
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
        expected[5] = IStaticsLiquidityRewards.stakedLiquidityPosition.selector;
        expected[6] = IStaticsLiquidityRewards.poolLiquidityRewards.selector;
        expected[7] = IStaticsLiquidityRewards.pendingLiquidityRewards.selector;
        expected[8] = IStaticsLiquidityRewards.canAccrueLiquidityRewards.selector;
        expected[9] = IStaticsLiquidityRewards.canAccrueBasketRewards.selector;
        assertEq(actual.length, expected.length);
        for (uint256 i; i < actual.length; ++i) {
            assertEq(actual[i], expected[i]);
            for (uint256 j; j < i; ++j) {
                assertNotEq(actual[i], actual[j]);
            }
        }
    }
}
