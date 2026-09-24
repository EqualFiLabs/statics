// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsBasketAdmin} from "../../src/interfaces/IStaticsBasketAdmin.sol";
import {IStaticsBasketLaunchModule} from "../../src/interfaces/IStaticsBasketLaunchModule.sol";
import {IStaticsBorrowLiquidity} from "../../src/interfaces/IStaticsBorrowLiquidity.sol";
import {IStaticsCustody} from "../../src/interfaces/IStaticsCustody.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsFlashLoan} from "../../src/interfaces/IStaticsFlashLoan.sol";
import {IStaticsLending} from "../../src/interfaces/IStaticsLending.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsProtocolRevenue} from "../../src/interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {IStaticsRangeGaugeCallback} from "../../src/interfaces/IStaticsRangeGaugeCallback.sol";
import {IStaticsPermissionedPools} from "../../src/interfaces/IStaticsPermissionedPools.sol";
import {IStaticsRewardPolicy} from "../../src/interfaces/IStaticsRewardPolicy.sol";
import {IModularPositionNFT} from "../../src/interfaces/IModularPositionNFT.sol";
import {IPositionOwnerIndex} from "../../src/interfaces/IPositionOwnerIndex.sol";
import {IERC5192} from "../../src/interfaces/IERC5192.sol";
import {IStaticsPositionPortfolio} from "../../src/interfaces/IStaticsPositionPortfolio.sol";
import {IStaticsGenesisIntegration} from "../../src/interfaces/IStaticsGenesisIntegration.sol";
import {IStaticsGovernance} from "../../src/interfaces/IStaticsGovernance.sol";
import {IStaticsMorpho} from "../../src/interfaces/IStaticsMorpho.sol";
import {
    IStaticsPosition,
    IStaticsPositionFees,
    IStaticsPositionModule
} from "../../src/interfaces/IStaticsPosition.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";

contract SelectorManifestTest is Test {
    function testPhaseOneSelectorSubsetsAreExactAndCollisionFree() public pure {
        bytes4[] memory governance = new bytes4[](13);
        governance[0] = IStaticsGovernance.guardian.selector;
        governance[1] = IStaticsGovernance.pausedActions.selector;
        governance[2] = IStaticsGovernance.isPaused.selector;
        governance[3] = IStaticsGovernance.setGuardian.selector;
        governance[4] = IStaticsGovernance.pause.selector;
        governance[5] = IStaticsGovernance.unpause.selector;
        governance[6] = IStaticsGovernance.pauseProtocolSwaps.selector;
        governance[7] = IStaticsGovernance.unpauseProtocolSwaps.selector;
        governance[8] = IStaticsGovernance.quarantineProtocolPool.selector;
        governance[9] = IStaticsGovernance.releaseProtocolPoolQuarantine.selector;
        governance[10] = IStaticsGovernance.protocolSwapsPaused.selector;
        governance[11] = IStaticsGovernance.isProtocolPoolQuarantined.selector;
        governance[12] = IStaticsGovernance.protocolPoolSwapsBlocked.selector;
        _assertExact(StaticsSelectors.phaseOneGovernance(), governance);

        bytes4[] memory custody = new bytes4[](5);
        custody[0] = IStaticsCustody.globalReservedByToken.selector;
        custody[1] = IStaticsCustody.reservedByAccount.selector;
        custody[2] = IStaticsCustody.unreservedBalance.selector;
        custody[3] = IStaticsCustody.feeCustodyAccount.selector;
        custody[4] = IStaticsCustody.stakingCustodyAccount.selector;
        _assertExact(StaticsSelectors.phaseOneCustody(), custody);

        bytes4[] memory treasury = new bytes4[](2);
        treasury[0] = IStaticsBasketAdmin.setTreasury.selector;
        treasury[1] = IStaticsBasketAdmin.treasury.selector;
        _assertExact(StaticsSelectors.phaseOneTreasuryAdmin(), treasury);

        bytes4[] memory liquidity = new bytes4[](6);
        liquidity[0] = IStaticsBasketLiquidity.installCanonicalPoolIntegration.selector;
        liquidity[1] = IStaticsBasketLiquidity.installLiquidityManager.selector;
        liquidity[2] = IStaticsBasketLiquidity.liquidityIntegration.selector;
        liquidity[3] = IStaticsBasketLiquidity.liquidityManager.selector;
        liquidity[4] = IStaticsBasketLiquidity.installPermissionedPoolIntegration.selector;
        liquidity[5] = IStaticsBasketLiquidity.permissionedLiquidityIntegration.selector;
        _assertExact(StaticsSelectors.phaseOneLiquidityIntegration(), liquidity);

        bytes4[] memory admin = new bytes4[](9);
        admin[0] = IStaticsProtocolPools.setPoolCreationFee.selector;
        admin[1] = IStaticsProtocolPools.setDefaultProtocolPoolFeeRate.selector;
        admin[2] = IStaticsProtocolPools.setProtocolPoolFeeRate.selector;
        admin[3] = IStaticsProtocolPools.clearProtocolPoolFeeRate.selector;
        admin[4] = IStaticsProtocolPools.setGeneralFeeAllocation.selector;
        admin[5] = IStaticsProtocolPools.decommissionGeneralPool.selector;
        admin[6] = IStaticsProtocolPools.replaceLiquidityManager.selector;
        admin[7] = IStaticsProtocolPools.setPermanentLiquidityHarvester.selector;
        admin[8] = IStaticsProtocolPools.harvestPermanentLiquidityFees.selector;
        _assertExact(StaticsSelectors.phaseOneProtocolPoolAdmin(), admin);

        bytes4[] memory views = new bytes4[](9);
        views[0] = IStaticsProtocolPools.protocolPool.selector;
        views[1] = IStaticsProtocolPools.isProtocolPool.selector;
        views[2] = IStaticsProtocolPools.poolCreationFee.selector;
        views[3] = IStaticsProtocolPools.isPoolCreationNonceUsed.selector;
        views[4] = IStaticsProtocolPools.generalFeeAllocation.selector;
        views[5] = IStaticsProtocolPools.defaultProtocolPoolFeeRate.selector;
        views[6] = IStaticsProtocolPools.protocolPoolFeeRate.selector;
        views[7] = IStaticsProtocolPools.protocolPoolCreator.selector;
        views[8] = IStaticsProtocolPools.permanentLiquidityHarvester.selector;
        _assertExact(StaticsSelectors.phaseOneProtocolPoolView(), views);

        bytes4[] memory revenue = new bytes4[](4);
        revenue[0] = IStaticsProtocolRevenue.routeProtocolSwapFees.selector;
        revenue[1] = IStaticsProtocolRevenue.claimCreatorRevenue.selector;
        revenue[2] = IStaticsProtocolRevenue.creatorRevenue.selector;
        revenue[3] = IStaticsProtocolRevenue.totalCreatorRevenue.selector;
        _assertExact(StaticsSelectors.phaseOneProtocolRevenue(), revenue);
    }

    function testRangeGaugeSelectorSubsetsAreExactAndCollisionFree() public pure {
        bytes4[] memory actions = new bytes4[](4);
        actions[0] = IStaticsRangeGauge.setGaugeRewardAssetAllowed.selector;
        actions[1] = IStaticsRangeGauge.setGaugeRewardDuration.selector;
        actions[2] = IStaticsRangeGauge.appendPoolRewardAsset.selector;
        actions[3] = IStaticsRangeGauge.fundPoolReward.selector;
        _assertExact(StaticsSelectors.rangeGaugeActions(), actions);

        bytes4[] memory positions = new bytes4[](6);
        positions[0] = IStaticsRangeGauge.provideLiquidity.selector;
        positions[1] = IStaticsRangeGauge.attachLiquidity.selector;
        positions[2] = IStaticsRangeGauge.increaseLiquidity.selector;
        positions[3] = IStaticsRangeGauge.decreaseLiquidity.selector;
        positions[4] = IStaticsRangeGauge.collectNativeFees.selector;
        positions[5] = IStaticsRangeGauge.rebalanceLiquidity.selector;
        _assertExact(StaticsSelectors.rangeGaugePositions(), positions);

        bytes4[] memory liveness = new bytes4[](5);
        liveness[0] = IStaticsRangeGauge.exitLiquidity.selector;
        liveness[1] = IStaticsRangeGauge.claimLpRewards.selector;
        liveness[2] = IStaticsRangeGauge.forfeitLpReward.selector;
        liveness[3] = IStaticsRangeGauge.recoverUnboundPosm.selector;
        liveness[4] = IStaticsRangeGauge.reconcilePoolRewardSurplus.selector;
        _assertExact(StaticsSelectors.rangeGaugeLiveness(), liveness);

        bytes4[] memory views = new bytes4[](12);
        views[0] = IStaticsRangeGauge.gaugeRewardDuration.selector;
        views[1] = IStaticsRangeGauge.gaugeRewardAssetAllowed.selector;
        views[2] = IStaticsRangeGauge.poolRewardConfig.selector;
        views[3] = IStaticsRangeGauge.gaugePool.selector;
        views[4] = IStaticsRangeGauge.poolRewardStream.selector;
        views[5] = IStaticsRangeGauge.poolRewardCustodyAccount.selector;
        views[6] = IStaticsRangeGauge.gaugeBoundary.selector;
        views[7] = IStaticsRangeGauge.lpLeg.selector;
        views[8] = IStaticsRangeGauge.positionGaugePools.selector;
        views[9] = IStaticsRangeGauge.posmBinding.selector;
        views[10] = IStaticsRangeGauge.recordedLiquidityManager.selector;
        views[11] = IStaticsRangeGauge.previewLpRewards.selector;
        _assertExact(StaticsSelectors.rangeGaugeViews(), views);

        bytes4[] memory callback = new bytes4[](1);
        callback[0] = IStaticsRangeGaugeCallback.afterProtocolPoolSwap.selector;
        _assertExact(StaticsSelectors.rangeGaugeCallback(), callback);

        bytes4[] memory all = new bytes4[](28);
        uint256 cursor;
        cursor = _copy(actions, all, cursor);
        cursor = _copy(positions, all, cursor);
        cursor = _copy(liveness, all, cursor);
        cursor = _copy(views, all, cursor);
        _copy(callback, all, cursor);
        for (uint256 i; i < all.length; ++i) {
            for (uint256 j; j < i; ++j) {
                assertNotEq(all[i], all[j]);
            }
        }
    }

    function testPhaseTwoLiquidityDeltaExcludesPhaseOneManagerSelectors() public pure {
        bytes4[] memory liquidity = new bytes4[](4);
        liquidity[0] = IStaticsBasketLaunchModule.launchBasketPools.selector;
        liquidity[1] = IStaticsBasketLaunchModule.mintBasketLaunch.selector;
        liquidity[2] = IStaticsBasketLiquidity.canonicalPool.selector;
        liquidity[3] = IStaticsBasketLiquidity.basketLiquidityUnwound.selector;
        _assertExact(StaticsSelectors.phaseTwoBasketLiquidity(), liquidity);

        bytes4[] memory admin = new bytes4[](1);
        admin[0] = IStaticsProtocolPools.setBasketFeeAllocation.selector;
        _assertExact(StaticsSelectors.phaseTwoProtocolPoolAdmin(), admin);
    }

    function testGovernanceSelectorManifestIsExactAndCollisionFree() public pure {
        bytes4[] memory actual = StaticsSelectors.governance();
        bytes4[] memory expected = new bytes4[](16);
        expected[0] = IStaticsGovernance.guardian.selector;
        expected[1] = IStaticsGovernance.pausedActions.selector;
        expected[2] = IStaticsGovernance.isPaused.selector;
        expected[3] = IStaticsGovernance.setGuardian.selector;
        expected[4] = IStaticsGovernance.pause.selector;
        expected[5] = IStaticsGovernance.unpause.selector;
        expected[6] = IStaticsGovernance.quarantineBasket.selector;
        expected[7] = IStaticsGovernance.releaseBasketQuarantine.selector;
        expected[8] = IStaticsGovernance.decommissionBasket.selector;
        expected[9] = IStaticsGovernance.pauseProtocolSwaps.selector;
        expected[10] = IStaticsGovernance.unpauseProtocolSwaps.selector;
        expected[11] = IStaticsGovernance.quarantineProtocolPool.selector;
        expected[12] = IStaticsGovernance.releaseProtocolPoolQuarantine.selector;
        expected[13] = IStaticsGovernance.protocolSwapsPaused.selector;
        expected[14] = IStaticsGovernance.isProtocolPoolQuarantined.selector;
        expected[15] = IStaticsGovernance.protocolPoolSwapsBlocked.selector;
        _assertExact(actual, expected);
    }

    function testFlashLoanSelectorManifestIsExactAndCollisionFree() public pure {
        bytes4[] memory actual = StaticsSelectors.flashLoan();
        bytes4[] memory expected = new bytes4[](7);
        expected[0] = IStaticsFlashLoan.flashLoan.selector;
        expected[1] = IStaticsFlashLoan.quoteFlashLoan.selector;
        expected[2] = IStaticsFlashLoan.flashLoanAsset.selector;
        expected[3] = IStaticsFlashLoan.quoteFlashLoanAsset.selector;
        expected[4] = IStaticsFlashLoan.maxFlashLoan.selector;
        expected[5] = IStaticsFlashLoan.singleAssetFlashFeeBps.selector;
        expected[6] = IStaticsFlashLoan.setSingleAssetFlashFeeBps.selector;
        _assertExact(actual, expected);
    }

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
        bytes4[] memory expected = new bytes4[](10);
        expected[0] = IStaticsBasketLiquidity.installCanonicalPoolIntegration.selector;
        expected[1] = IStaticsBasketLiquidity.installLiquidityManager.selector;
        expected[2] = IStaticsBasketLaunchModule.launchBasketPools.selector;
        expected[3] = IStaticsBasketLaunchModule.mintBasketLaunch.selector;
        expected[4] = IStaticsBasketLiquidity.liquidityIntegration.selector;
        expected[5] = IStaticsBasketLiquidity.liquidityManager.selector;
        expected[6] = IStaticsBasketLiquidity.canonicalPool.selector;
        expected[7] = IStaticsBasketLiquidity.basketLiquidityUnwound.selector;
        expected[8] = IStaticsBasketLiquidity.installPermissionedPoolIntegration.selector;
        expected[9] = IStaticsBasketLiquidity.permissionedLiquidityIntegration.selector;

        assertEq(actual.length, expected.length);
        for (uint256 i; i < actual.length; ++i) {
            assertEq(actual[i], expected[i]);
            for (uint256 j; j < i; ++j) {
                assertNotEq(actual[i], actual[j]);
            }
        }
    }

    function testLiquidityLifecycleSelectorManifestIsExact() public pure {
        bytes4[] memory selectors = StaticsSelectors.basketLiquidityLifecycle();
        assertEq(selectors.length, 1);
        assertEq(selectors[0], IStaticsBasketLiquidity.unwindBasketLiquidity.selector);
    }

    function testProtocolPoolCreationSelectorManifestIsExactAndCollisionFree() public pure {
        bytes4[] memory actual = StaticsSelectors.protocolPoolCreation();
        bytes4[] memory expected = new bytes4[](3);
        expected[0] = IStaticsProtocolPools.quotePool.selector;
        expected[1] = IStaticsProtocolPools.createPool.selector;
        expected[2] = IStaticsProtocolPools.invalidatePoolCreationNonce.selector;
        _assertExact(actual, expected);
    }

    function testPermissionedAndRewardPolicySelectorManifestsAreExact() public pure {
        bytes4[] memory reward = new bytes4[](5);
        reward[0] = IStaticsRewardPolicy.addRewardRestriction.selector;
        reward[1] = IStaticsRewardPolicy.removeRewardRestriction.selector;
        reward[2] = IStaticsRewardPolicy.rewardRestricted.selector;
        reward[3] = IStaticsRewardPolicy.rewardRestrictionNonce.selector;
        reward[4] = IStaticsRewardPolicy.rewardRestrictionTimestamp.selector;
        _assertExact(StaticsSelectors.rewardPolicy(), reward);

        bytes4[] memory creation = new bytes4[](3);
        creation[0] = IStaticsPermissionedPools.quotePermissionedPool.selector;
        creation[1] = IStaticsPermissionedPools.createPermissionedPool.selector;
        creation[2] = IStaticsPermissionedPools.invalidatePermissionedAuthorizationNonce.selector;
        _assertExact(StaticsSelectors.permissionedPoolCreation(), creation);

        bytes4[] memory admin = new bytes4[](7);
        admin[0] = IStaticsPermissionedPools.applyPermissionedPoolTerms.selector;
        admin[1] = IStaticsPermissionedPools.replacePermissionedPoolController.selector;
        admin[2] = IStaticsPermissionedPools.invalidatePermissionedConfigurationNonce.selector;
        admin[3] = IStaticsPermissionedPools.decommissionPermissionedPool.selector;
        admin[4] = IStaticsPermissionedPools.setPermissionedTrustedPeriphery.selector;
        admin[5] = IStaticsPermissionedPools.permissionedTermsDigest.selector;
        admin[6] = IStaticsPermissionedPools.permissionedControllerReplacementDigest.selector;
        _assertExact(StaticsSelectors.permissionedPoolAdmin(), admin);

        bytes4[] memory views = new bytes4[](3);
        views[0] = IStaticsPermissionedPools.permissionedPool.selector;
        views[1] = IStaticsPermissionedPools.isPermissionedPool.selector;
        views[2] = IStaticsPermissionedPools.isPermissionedAuthorizationNonceUsed.selector;
        _assertExact(StaticsSelectors.permissionedPoolView(), views);
    }

    function testProtocolPoolAdminSelectorManifestIsExactAndCollisionFree() public pure {
        bytes4[] memory actual = StaticsSelectors.protocolPoolAdmin();
        bytes4[] memory expected = new bytes4[](10);
        expected[0] = IStaticsProtocolPools.setPoolCreationFee.selector;
        expected[1] = IStaticsProtocolPools.setDefaultProtocolPoolFeeRate.selector;
        expected[2] = IStaticsProtocolPools.setProtocolPoolFeeRate.selector;
        expected[3] = IStaticsProtocolPools.clearProtocolPoolFeeRate.selector;
        expected[4] = IStaticsProtocolPools.setBasketFeeAllocation.selector;
        expected[5] = IStaticsProtocolPools.setGeneralFeeAllocation.selector;
        expected[6] = IStaticsProtocolPools.decommissionGeneralPool.selector;
        expected[7] = IStaticsProtocolPools.replaceLiquidityManager.selector;
        expected[8] = IStaticsProtocolPools.setPermanentLiquidityHarvester.selector;
        expected[9] = IStaticsProtocolPools.harvestPermanentLiquidityFees.selector;
        _assertExact(actual, expected);
    }

    function testProtocolPoolViewSelectorManifestIsExactAndCollisionFree() public pure {
        bytes4[] memory actual = StaticsSelectors.protocolPoolView();
        bytes4[] memory expected = new bytes4[](10);
        expected[0] = IStaticsProtocolPools.protocolPool.selector;
        expected[1] = IStaticsProtocolPools.isProtocolPool.selector;
        expected[2] = IStaticsProtocolPools.poolCreationFee.selector;
        expected[3] = IStaticsProtocolPools.isPoolCreationNonceUsed.selector;
        expected[4] = IStaticsProtocolPools.basketFeeAllocation.selector;
        expected[5] = IStaticsProtocolPools.generalFeeAllocation.selector;
        expected[6] = IStaticsProtocolPools.defaultProtocolPoolFeeRate.selector;
        expected[7] = IStaticsProtocolPools.protocolPoolFeeRate.selector;
        expected[8] = IStaticsProtocolPools.protocolPoolCreator.selector;
        expected[9] = IStaticsProtocolPools.permanentLiquidityHarvester.selector;
        _assertExact(actual, expected);
    }

    function testProtocolRevenueSelectorManifestIsExactAndCollisionFree() public pure {
        bytes4[] memory actual = StaticsSelectors.protocolRevenue();
        bytes4[] memory expected = new bytes4[](5);
        expected[0] = IStaticsProtocolRevenue.routeProtocolSwapFees.selector;
        expected[1] = IStaticsProtocolRevenue.claimCreatorRevenue.selector;
        expected[2] = IStaticsProtocolRevenue.creatorRevenue.selector;
        expected[3] = IStaticsProtocolRevenue.totalCreatorRevenue.selector;
        expected[4] = IStaticsProtocolRevenue.canAccrueBasketRewards.selector;
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

    function _copy(bytes4[] memory source, bytes4[] memory destination, uint256 cursor) private pure returns (uint256) {
        for (uint256 i; i < source.length; ++i) {
            destination[cursor++] = source[i];
        }
        return cursor;
    }

    function testPositionPortfolioSelectorManifestIsExactAndCollisionFree() public pure {
        bytes4[] memory actual = StaticsSelectors.positionPortfolio();
        bytes4[] memory expected = new bytes4[](6);
        expected[0] = IStaticsPositionPortfolio.positionPortfolioCounts.selector;
        expected[1] = IStaticsPositionPortfolio.basketIdsOfPosition.selector;
        expected[2] = IStaticsPositionPortfolio.loanIdsOfPosition.selector;
        expected[3] = IStaticsPositionPortfolio.globalRewardAssetsOfPosition.selector;
        expected[4] = IStaticsPositionPortfolio.riskSeriesIdsOfPosition.selector;
        expected[5] = IStaticsPositionPortfolio.morphoMarketIdsOfPosition.selector;
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
        bytes4[] memory settlement = StaticsSelectors.morphoSettlement();
        bytes4[] memory recovery = StaticsSelectors.morphoRecovery();
        bytes4[] memory views = StaticsSelectors.morphoView();
        assertEq(admin.length, 5);
        assertEq(actions.length, 7);
        assertEq(settlement.length, 3);
        assertEq(recovery.length, 1);
        assertEq(views.length, 10);
        bytes4[] memory all = new bytes4[](26);
        for (uint256 i; i < admin.length; ++i) {
            all[i] = admin[i];
        }
        for (uint256 i; i < actions.length; ++i) {
            all[admin.length + i] = actions[i];
        }
        for (uint256 i; i < settlement.length; ++i) {
            all[admin.length + actions.length + i] = settlement[i];
        }
        for (uint256 i; i < recovery.length; ++i) {
            all[admin.length + actions.length + settlement.length + i] = recovery[i];
        }
        for (uint256 i; i < views.length; ++i) {
            all[admin.length + actions.length + settlement.length + recovery.length + i] = views[i];
        }
        for (uint256 i; i < all.length; ++i) {
            for (uint256 j; j < i; ++j) {
                assertNotEq(all[i], all[j]);
            }
        }
        assertEq(admin[0], IStaticsMorpho.initializeMorphoIntegration.selector);
        assertEq(actions[0], IStaticsMorpho.deployMorphoCollateral.selector);
        assertEq(settlement[2], IStaticsMorpho.recoverMorphoAccountToken.selector);
        assertEq(recovery[0], IStaticsMorpho.withdrawUntrackedMorphoCollateral.selector);
        assertEq(views[0], IStaticsMorpho.morpho.selector);
        assertEq(views[9], IStaticsMorpho.enforceMorphoAccountEmpty.selector);
    }

    function testBorrowLiquiditySelectorManifestIsExact() public pure {
        bytes4[] memory selectors = StaticsSelectors.borrowLiquidity();
        assertEq(selectors.length, 1);
        assertEq(selectors[0], IStaticsBorrowLiquidity.borrowAndProvideLiquidity.selector);
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
        bytes4[] memory expected = new bytes4[](24);
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
        expected[20] = IStaticsGlobalRewards.checkpointRewardAssets.selector;
        expected[21] = IStaticsGlobalRewards.rewardBookNeedsCheckpoint.selector;
        expected[22] = IStaticsGlobalRewards.hardMaxRewardAssetsPerPosition.selector;
        expected[23] = IStaticsGlobalRewards.increaseMaxRewardAssetsPerPosition.selector;
        assertEq(actual.length, expected.length);
        for (uint256 i; i < actual.length; ++i) {
            assertEq(actual[i], expected[i]);
            for (uint256 j; j < i; ++j) {
                assertNotEq(actual[i], actual[j]);
            }
        }
    }
}
