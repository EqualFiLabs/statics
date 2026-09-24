// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../interfaces/IDiamondLoupe.sol";
import {IERC173} from "../interfaces/IERC173.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {IStaticsBasketAdmin} from "../interfaces/IStaticsBasketAdmin.sol";
import {IStaticsBasketCollateral} from "../interfaces/IStaticsBasketCollateral.sol";
import {IStaticsBasketRewards} from "../interfaces/IStaticsBasketRewards.sol";
import {IStaticsGlobalRewards} from "../interfaces/IStaticsGlobalRewards.sol";
import {IStaticsBasketLiquidity} from "../interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsBasketLaunchModule} from "../interfaces/IStaticsBasketLaunchModule.sol";
import {IStaticsBorrowLiquidity} from "../interfaces/IStaticsBorrowLiquidity.sol";
import {IStaticsCustody} from "../interfaces/IStaticsCustody.sol";
import {IStaticsFlashLoan} from "../interfaces/IStaticsFlashLoan.sol";
import {IStaticsGovernance} from "../interfaces/IStaticsGovernance.sol";
import {IStaticsLending} from "../interfaces/IStaticsLending.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IStaticsProtocolRevenue} from "../interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsRangeGauge} from "../interfaces/IStaticsRangeGauge.sol";
import {IStaticsRangeGaugeCallback} from "../interfaces/IStaticsRangeGaugeCallback.sol";
import {IStaticsRewardPolicy} from "../interfaces/IStaticsRewardPolicy.sol";
import {IStaticsPermissionedPools} from "../interfaces/IStaticsPermissionedPools.sol";
import {IModularPositionNFT} from "../interfaces/IModularPositionNFT.sol";
import {IPositionOwnerIndex} from "../interfaces/IPositionOwnerIndex.sol";
import {IStaticsPositionPortfolio} from "../interfaces/IStaticsPositionPortfolio.sol";
import {IStaticsPosition, IStaticsPositionFees, IStaticsPositionModule} from "../interfaces/IStaticsPosition.sol";
import {IERC5192} from "../interfaces/IERC5192.sol";
import {IStaticsGenesisIntegration} from "../interfaces/IStaticsGenesisIntegration.sol";
import {IStaticsMorpho} from "../interfaces/IStaticsMorpho.sol";
import {StaticsInterfaceInit} from "../diamond/StaticsInterfaceInit.sol";
import {IStaticsDollarSeriesMigration} from "../dollar/interfaces/IStaticsDollarSeriesMigration.sol";
import {FeeRouterFacet} from "../dollar/periphery/facets/FeeRouterFacet.sol";
import {PairingVaultFacet} from "../dollar/periphery/facets/PairingVaultFacet.sol";
import {StakingFacet} from "../dollar/periphery/facets/StakingFacet.sol";
import {StaticsDollarGatewayFacet} from "../dollar/periphery/facets/StaticsDollarGatewayFacet.sol";

library StaticsSelectors {
    function rangeGaugeActions() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = IStaticsRangeGauge.setGaugeRewardAssetAllowed.selector;
        selectors[1] = IStaticsRangeGauge.setGaugeRewardDuration.selector;
        selectors[2] = IStaticsRangeGauge.appendPoolRewardAsset.selector;
        selectors[3] = IStaticsRangeGauge.fundPoolReward.selector;
    }

    function rangeGaugePositions() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = IStaticsRangeGauge.provideLiquidity.selector;
        selectors[1] = IStaticsRangeGauge.attachLiquidity.selector;
        selectors[2] = IStaticsRangeGauge.increaseLiquidity.selector;
        selectors[3] = IStaticsRangeGauge.decreaseLiquidity.selector;
        selectors[4] = IStaticsRangeGauge.collectNativeFees.selector;
        selectors[5] = IStaticsRangeGauge.rebalanceLiquidity.selector;
    }

    function rangeGaugeLiveness() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = IStaticsRangeGauge.exitLiquidity.selector;
        selectors[1] = IStaticsRangeGauge.claimLpRewards.selector;
        selectors[2] = IStaticsRangeGauge.forfeitLpReward.selector;
        selectors[3] = IStaticsRangeGauge.recoverUnboundPosm.selector;
        selectors[4] = IStaticsRangeGauge.reconcilePoolRewardSurplus.selector;
    }

    /// @dev liquidityManager() is intentionally routed through BasketLiquidityFacet.
    function rangeGaugeViews() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](12);
        selectors[0] = IStaticsRangeGauge.gaugeRewardDuration.selector;
        selectors[1] = IStaticsRangeGauge.gaugeRewardAssetAllowed.selector;
        selectors[2] = IStaticsRangeGauge.poolRewardConfig.selector;
        selectors[3] = IStaticsRangeGauge.gaugePool.selector;
        selectors[4] = IStaticsRangeGauge.poolRewardStream.selector;
        selectors[5] = IStaticsRangeGauge.poolRewardCustodyAccount.selector;
        selectors[6] = IStaticsRangeGauge.gaugeBoundary.selector;
        selectors[7] = IStaticsRangeGauge.lpLeg.selector;
        selectors[8] = IStaticsRangeGauge.positionGaugePools.selector;
        selectors[9] = IStaticsRangeGauge.posmBinding.selector;
        selectors[10] = IStaticsRangeGauge.recordedLiquidityManager.selector;
        selectors[11] = IStaticsRangeGauge.previewLpRewards.selector;
    }

    function rangeGaugeCallback() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IStaticsRangeGaugeCallback.afterProtocolPoolSwap.selector;
    }

    function rewardPolicy() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = IStaticsRewardPolicy.addRewardRestriction.selector;
        selectors[1] = IStaticsRewardPolicy.removeRewardRestriction.selector;
        selectors[2] = IStaticsRewardPolicy.rewardRestricted.selector;
    }

    function diamondCut() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IDiamondCut.diamondCut.selector;
    }

    function diamondLoupe() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = IDiamondLoupe.facets.selector;
        selectors[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        selectors[2] = IDiamondLoupe.facetAddresses.selector;
        selectors[3] = IDiamondLoupe.facetAddress.selector;
        selectors[4] = IERC165.supportsInterface.selector;
    }

    function ownership() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = IERC173.owner.selector;
        selectors[1] = IERC173.transferOwnership.selector;
    }

    function governance() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](16);
        selectors[0] = IStaticsGovernance.guardian.selector;
        selectors[1] = IStaticsGovernance.pausedActions.selector;
        selectors[2] = IStaticsGovernance.isPaused.selector;
        selectors[3] = IStaticsGovernance.setGuardian.selector;
        selectors[4] = IStaticsGovernance.pause.selector;
        selectors[5] = IStaticsGovernance.unpause.selector;
        selectors[6] = IStaticsGovernance.quarantineBasket.selector;
        selectors[7] = IStaticsGovernance.releaseBasketQuarantine.selector;
        selectors[8] = IStaticsGovernance.decommissionBasket.selector;
        selectors[9] = IStaticsGovernance.pauseProtocolSwaps.selector;
        selectors[10] = IStaticsGovernance.unpauseProtocolSwaps.selector;
        selectors[11] = IStaticsGovernance.quarantineProtocolPool.selector;
        selectors[12] = IStaticsGovernance.releaseProtocolPoolQuarantine.selector;
        selectors[13] = IStaticsGovernance.protocolSwapsPaused.selector;
        selectors[14] = IStaticsGovernance.isProtocolPoolQuarantined.selector;
        selectors[15] = IStaticsGovernance.protocolPoolSwapsBlocked.selector;
    }

    function phaseOneGovernance() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](13);
        selectors[0] = IStaticsGovernance.guardian.selector;
        selectors[1] = IStaticsGovernance.pausedActions.selector;
        selectors[2] = IStaticsGovernance.isPaused.selector;
        selectors[3] = IStaticsGovernance.setGuardian.selector;
        selectors[4] = IStaticsGovernance.pause.selector;
        selectors[5] = IStaticsGovernance.unpause.selector;
        selectors[6] = IStaticsGovernance.pauseProtocolSwaps.selector;
        selectors[7] = IStaticsGovernance.unpauseProtocolSwaps.selector;
        selectors[8] = IStaticsGovernance.quarantineProtocolPool.selector;
        selectors[9] = IStaticsGovernance.releaseProtocolPoolQuarantine.selector;
        selectors[10] = IStaticsGovernance.protocolSwapsPaused.selector;
        selectors[11] = IStaticsGovernance.isProtocolPoolQuarantined.selector;
        selectors[12] = IStaticsGovernance.protocolPoolSwapsBlocked.selector;
    }

    function phaseTwoGovernance() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = IStaticsGovernance.quarantineBasket.selector;
        selectors[1] = IStaticsGovernance.releaseBasketQuarantine.selector;
        selectors[2] = IStaticsGovernance.decommissionBasket.selector;
    }

    function position() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](27);
        selectors[0] = IERC721.balanceOf.selector;
        selectors[1] = IERC721.ownerOf.selector;
        selectors[2] = IERC721.approve.selector;
        selectors[3] = IERC721.getApproved.selector;
        selectors[4] = IERC721.setApprovalForAll.selector;
        selectors[5] = IERC721.isApprovedForAll.selector;
        selectors[6] = IERC721.transferFrom.selector;
        selectors[7] = bytes4(keccak256("safeTransferFrom(address,address,uint256)"));
        selectors[8] = bytes4(keccak256("safeTransferFrom(address,address,uint256,bytes)"));
        selectors[9] = IERC721Metadata.name.selector;
        selectors[10] = IERC721Metadata.symbol.selector;
        selectors[11] = IERC721Metadata.tokenURI.selector;
        selectors[12] = IStaticsPosition.createPosition.selector;
        selectors[13] = IStaticsPosition.closePosition.selector;
        selectors[14] = IStaticsPosition.nextPositionId.selector;
        selectors[15] = IStaticsPosition.activeLegCount.selector;
        selectors[16] = IStaticsPosition.positionInitializing.selector;
        selectors[17] = IModularPositionNFT.positionState.selector;
        selectors[18] = IModularPositionNFT.isLegActive.selector;
        selectors[19] = IModularPositionNFT.isPositionClosable.selector;
        selectors[20] = IStaticsPositionModule.createPositionForModule.selector;
        selectors[21] = IStaticsPositionFees.setPositionCreationFee.selector;
        selectors[22] = IStaticsPositionFees.positionCreationFee.selector;
        selectors[23] = IPositionOwnerIndex.positionCount.selector;
        selectors[24] = IPositionOwnerIndex.positionsOfOwner.selector;
        selectors[25] = IPositionOwnerIndex.syncPositionOwnerIndex.selector;
        selectors[26] = IERC5192.locked.selector;
    }

    function interfaceInit() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = StaticsInterfaceInit.setInterfaces.selector;
    }

    function positionPortfolio() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = IStaticsPositionPortfolio.positionPortfolioCounts.selector;
        selectors[1] = IStaticsPositionPortfolio.basketIdsOfPosition.selector;
        selectors[2] = IStaticsPositionPortfolio.loanIdsOfPosition.selector;
        selectors[3] = IStaticsPositionPortfolio.globalRewardAssetsOfPosition.selector;
        selectors[4] = IStaticsPositionPortfolio.riskSeriesIdsOfPosition.selector;
        selectors[5] = IStaticsPositionPortfolio.morphoMarketIdsOfPosition.selector;
    }

    function phaseTwoPositionPortfolio() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = IStaticsPositionPortfolio.positionPortfolioCounts.selector;
        selectors[1] = IStaticsPositionPortfolio.basketIdsOfPosition.selector;
        selectors[2] = IStaticsPositionPortfolio.loanIdsOfPosition.selector;
        selectors[3] = IStaticsPositionPortfolio.globalRewardAssetsOfPosition.selector;
    }

    function phaseThreePositionPortfolio() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IStaticsPositionPortfolio.riskSeriesIdsOfPosition.selector;
    }

    function phaseFourPositionPortfolio() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IStaticsPositionPortfolio.morphoMarketIdsOfPosition.selector;
    }

    function morphoAdmin() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = IStaticsMorpho.initializeMorphoIntegration.selector;
        selectors[1] = IStaticsMorpho.registerMorphoMarket.selector;
        selectors[2] = IStaticsMorpho.setMorphoMarketMode.selector;
        selectors[3] = IStaticsMorpho.setMorphoSyncBountyBps.selector;
        selectors[4] = IStaticsMorpho.setMorphoPerformanceFeeConfig.selector;
    }

    function morphoActions() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](7);
        selectors[0] = IStaticsMorpho.deployMorphoCollateral.selector;
        selectors[1] = IStaticsMorpho.recallMorphoCollateral.selector;
        selectors[2] = IStaticsMorpho.borrowMorphoUsd.selector;
        selectors[3] = IStaticsMorpho.repayMorphoUsd.selector;
        selectors[4] = IStaticsMorpho.syncMorpho.selector;
        selectors[5] = IStaticsMorpho.syncMorphoForModule.selector;
        selectors[6] = IStaticsMorpho.liquidateMorphoAndSync.selector;
    }

    function morphoSettlement() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = IStaticsMorpho.claimMorphoSyncBounties.selector;
        selectors[1] = IStaticsMorpho.routeMorphoPerformanceFee.selector;
        selectors[2] = IStaticsMorpho.recoverMorphoAccountToken.selector;
    }

    function morphoRecovery() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IStaticsMorpho.withdrawUntrackedMorphoCollateral.selector;
    }

    function morphoView() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](10);
        selectors[0] = IStaticsMorpho.morpho.selector;
        selectors[1] = IStaticsMorpho.morphoUsdStx.selector;
        selectors[2] = IStaticsMorpho.morphoAccount.selector;
        selectors[3] = IStaticsMorpho.morphoMarket.selector;
        selectors[4] = IStaticsMorpho.morphoPositionMarket.selector;
        selectors[5] = IStaticsMorpho.morphoSyncBountyBps.selector;
        selectors[6] = IStaticsMorpho.morphoSyncBounty.selector;
        selectors[7] = IStaticsMorpho.quoteMorphoPerformanceFee.selector;
        selectors[8] = IStaticsMorpho.morphoPerformanceFeeConfig.selector;
        selectors[9] = IStaticsMorpho.enforceMorphoAccountEmpty.selector;
    }

    function custody() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](8);
        selectors[0] = IStaticsCustody.globalReservedByToken.selector;
        selectors[1] = IStaticsCustody.reservedByAccount.selector;
        selectors[2] = IStaticsCustody.unreservedBalance.selector;
        selectors[3] = IStaticsCustody.dollarCustodyAccount.selector;
        selectors[4] = IStaticsCustody.basketCustodyAccount.selector;
        selectors[5] = IStaticsCustody.feeCustodyAccount.selector;
        selectors[6] = IStaticsCustody.stakingCustodyAccount.selector;
        selectors[7] = IStaticsCustody.genesisRewardCustodyAccount.selector;
    }

    function phaseOneCustody() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = IStaticsCustody.globalReservedByToken.selector;
        selectors[1] = IStaticsCustody.reservedByAccount.selector;
        selectors[2] = IStaticsCustody.unreservedBalance.selector;
        selectors[3] = IStaticsCustody.feeCustodyAccount.selector;
        selectors[4] = IStaticsCustody.stakingCustodyAccount.selector;
    }

    function phaseTwoCustody() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = IStaticsCustody.basketCustodyAccount.selector;
        selectors[1] = IStaticsCustody.genesisRewardCustodyAccount.selector;
    }

    function phaseThreeCustody() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IStaticsCustody.dollarCustodyAccount.selector;
    }

    function basketCreation() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IStaticsBasket.createBasket.selector;
    }

    function basketMint() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = IStaticsBasket.mint.selector;
        selectors[1] = IStaticsBasket.quoteMint.selector;
        selectors[2] = IStaticsBasketCollateral.createAndMintBasketCollateral.selector;
        selectors[3] = IStaticsBasketCollateral.mintBasketCollateral.selector;
    }

    function basketRedemption() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = IStaticsBasket.redeem.selector;
        selectors[1] = IStaticsBasket.quoteRedeem.selector;
        selectors[2] = IStaticsBasketCollateral.redeemBasketCollateral.selector;
    }

    function basketView() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = IStaticsBasket.basket.selector;
        selectors[1] = IStaticsBasket.basketCount.selector;
        selectors[2] = IStaticsBasket.basketIdOf.selector;
        selectors[3] = IStaticsBasket.vaultBalance.selector;
        selectors[4] = IStaticsBasket.feeSharesFor.selector;
        selectors[5] = IStaticsBasket.basketStatus.selector;
    }

    function basketCollateral() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = IStaticsBasketCollateral.createAndDepositBasketCollateral.selector;
        selectors[1] = IStaticsBasketCollateral.depositBasketCollateral.selector;
        selectors[2] = IStaticsBasketCollateral.withdrawBasketCollateral.selector;
        selectors[3] = IStaticsBasketCollateral.basketCollateralPosition.selector;
    }

    function basketRewards() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = IStaticsBasketRewards.getBasketRewardAssets.selector;
        selectors[1] = IStaticsBasketRewards.getBasketRewards.selector;
        selectors[2] = IStaticsBasketRewards.claimBasketRewards.selector;
        selectors[3] = IStaticsBasketRewards.basketRewardState.selector;
    }

    function globalRewards() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](24);
        selectors[0] = IStaticsGlobalRewards.createAndStake.selector;
        selectors[1] = IStaticsGlobalRewards.stake.selector;
        selectors[2] = IStaticsGlobalRewards.unstake.selector;
        selectors[3] = IStaticsGlobalRewards.optInRewardAssets.selector;
        selectors[4] = IStaticsGlobalRewards.optOutRewardAssets.selector;
        selectors[5] = IStaticsGlobalRewards.claimRewards.selector;
        selectors[6] = IStaticsGlobalRewards.distributeTreasuryFees.selector;
        selectors[7] = IStaticsGlobalRewards.pendingRewards.selector;
        selectors[8] = IStaticsGlobalRewards.stakePosition.selector;
        selectors[9] = IStaticsGlobalRewards.rewardAsset.selector;
        selectors[10] = IStaticsGlobalRewards.positionRewardAssets.selector;
        selectors[11] = IStaticsGlobalRewards.isRewardAssetOptedIn.selector;
        selectors[12] = IStaticsGlobalRewards.rewardSelection.selector;
        selectors[13] = IStaticsGlobalRewards.maxRewardAssetsPerPosition.selector;
        selectors[14] = IStaticsGlobalRewards.rewardEligibilityDelay.selector;
        selectors[15] = IStaticsGlobalRewards.rewardEligibilityBucketSize.selector;
        selectors[16] = IStaticsGlobalRewards.stakingToken.selector;
        selectors[17] = IStaticsGlobalRewards.totalStaked.selector;
        selectors[18] = IStaticsGlobalRewards.treasuryAccrued.selector;
        selectors[19] = IStaticsGlobalRewards.canAccrueStakerRewards.selector;
        selectors[20] = IStaticsGlobalRewards.checkpointRewardAssets.selector;
        selectors[21] = IStaticsGlobalRewards.rewardBookNeedsCheckpoint.selector;
        selectors[22] = IStaticsGlobalRewards.hardMaxRewardAssetsPerPosition.selector;
        selectors[23] = IStaticsGlobalRewards.increaseMaxRewardAssetsPerPosition.selector;
    }

    function genesisNFT() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](34);
        selectors[0] = IStaticsGenesisIntegration.linkGenesis.selector;
        selectors[1] = IStaticsGenesisIntegration.unlinkGenesis.selector;
        selectors[2] = IStaticsGenesisIntegration.linkedGenesis.selector;
        selectors[3] = IStaticsGenesisIntegration.linkedPosition.selector;
        selectors[4] = IStaticsGenesisIntegration.genesisCollection.selector;
        selectors[5] = IStaticsGenesisIntegration.genesisRecoveryVault.selector;
        selectors[6] = IStaticsGenesisIntegration.genesisRecoveryAsset.selector;
        selectors[7] = IStaticsGenesisIntegration.genesisRecoveryReady.selector;
        selectors[8] = IStaticsGenesisIntegration.genesisIntegrationReady.selector;
        selectors[9] = IStaticsGenesisIntegration.genesisRecoveryCallback.selector;
        selectors[10] = IStaticsGenesisIntegration.onGenesisRecovery.selector;
        selectors[11] = IStaticsGenesisIntegration.onGenesisTransition.selector;
        selectors[12] = IStaticsGenesisIntegration.acceptGenesisDistributorRole.selector;
        selectors[13] = IStaticsGenesisIntegration.acceptGenesisConsumerRole.selector;
        selectors[14] = IStaticsGenesisIntegration.registerGenesis.selector;
        selectors[15] = IStaticsGenesisIntegration.accrueGenesisRewards.selector;
        selectors[16] = IStaticsGenesisIntegration.claimGenesisRewards.selector;
        selectors[17] = IStaticsGenesisIntegration.claimGenesisOwnerRewards.selector;
        selectors[18] = IStaticsGenesisIntegration.claimGenesisTreasuryRewards.selector;
        selectors[19] = IStaticsGenesisIntegration.setGenesisRewardShareBps.selector;
        selectors[20] = IStaticsGenesisIntegration.checkpointGenesisRecovery.selector;
        selectors[21] = IStaticsGenesisIntegration.accrueGenesisRecovery.selector;
        selectors[22] = IStaticsGenesisIntegration.migratePendingGenesisRecovery.selector;
        selectors[23] = IStaticsGenesisIntegration.acceptPendingGenesisRecovery.selector;
        selectors[24] = IStaticsGenesisIntegration.pendingGenesisRewards.selector;
        selectors[25] = IStaticsGenesisIntegration.genesisRewardBook.selector;
        selectors[26] = IStaticsGenesisIntegration.genesisRegistered.selector;
        selectors[27] = IStaticsGenesisIntegration.genesisEffectiveWeight.selector;
        selectors[28] = IStaticsGenesisIntegration.genesisTotalWeight.selector;
        selectors[29] = IStaticsGenesisIntegration.genesisRewardShareBps.selector;
        selectors[30] = IStaticsGenesisIntegration.genesisOwnerClaimable.selector;
        selectors[31] = IStaticsGenesisIntegration.pendingGenesisRecovery.selector;
        selectors[32] = IStaticsGenesisIntegration.claimAllGenesisRewards.selector;
        selectors[33] = IStaticsGenesisIntegration.claimAllGenesisTreasuryRewards.selector;
    }

    function basketAdmin() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = IStaticsBasketAdmin.setCreationFee.selector;
        selectors[1] = IStaticsBasketAdmin.setTreasury.selector;
        selectors[2] = IStaticsBasketAdmin.creationFee.selector;
        selectors[3] = IStaticsBasketAdmin.treasury.selector;
    }

    function phaseOneTreasuryAdmin() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = IStaticsBasketAdmin.setTreasury.selector;
        selectors[1] = IStaticsBasketAdmin.treasury.selector;
    }

    function phaseTwoBasketAdmin() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = IStaticsBasketAdmin.setCreationFee.selector;
        selectors[1] = IStaticsBasketAdmin.creationFee.selector;
    }

    function basketLiquidity() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](10);
        selectors[0] = IStaticsBasketLiquidity.installCanonicalPoolIntegration.selector;
        selectors[1] = IStaticsBasketLiquidity.installLiquidityManager.selector;
        selectors[2] = IStaticsBasketLaunchModule.launchBasketPools.selector;
        selectors[3] = IStaticsBasketLaunchModule.mintBasketLaunch.selector;
        selectors[4] = IStaticsBasketLiquidity.liquidityIntegration.selector;
        selectors[5] = IStaticsBasketLiquidity.liquidityManager.selector;
        selectors[6] = IStaticsBasketLiquidity.canonicalPool.selector;
        selectors[7] = IStaticsBasketLiquidity.basketLiquidityUnwound.selector;
        selectors[8] = IStaticsBasketLiquidity.installPermissionedPoolIntegration.selector;
        selectors[9] = IStaticsBasketLiquidity.permissionedLiquidityIntegration.selector;
    }

    function phaseOneLiquidityIntegration() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = IStaticsBasketLiquidity.installCanonicalPoolIntegration.selector;
        selectors[1] = IStaticsBasketLiquidity.installLiquidityManager.selector;
        selectors[2] = IStaticsBasketLiquidity.liquidityIntegration.selector;
        selectors[3] = IStaticsBasketLiquidity.liquidityManager.selector;
        selectors[4] = IStaticsBasketLiquidity.installPermissionedPoolIntegration.selector;
        selectors[5] = IStaticsBasketLiquidity.permissionedLiquidityIntegration.selector;
    }

    function phaseTwoBasketLiquidity() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = IStaticsBasketLaunchModule.launchBasketPools.selector;
        selectors[1] = IStaticsBasketLaunchModule.mintBasketLaunch.selector;
        selectors[2] = IStaticsBasketLiquidity.canonicalPool.selector;
        selectors[3] = IStaticsBasketLiquidity.basketLiquidityUnwound.selector;
    }

    function basketLiquidityLifecycle() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IStaticsBasketLiquidity.unwindBasketLiquidity.selector;
    }

    function protocolPoolCreation() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = IStaticsProtocolPools.quotePool.selector;
        selectors[1] = IStaticsProtocolPools.createPool.selector;
        selectors[2] = IStaticsProtocolPools.invalidatePoolCreationNonce.selector;
    }

    function permissionedPoolCreation() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = IStaticsPermissionedPools.quotePermissionedPool.selector;
        selectors[1] = IStaticsPermissionedPools.createPermissionedPool.selector;
        selectors[2] = IStaticsPermissionedPools.invalidatePermissionedAuthorizationNonce.selector;
    }

    function permissionedPoolAdmin() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](7);
        selectors[0] = IStaticsPermissionedPools.applyPermissionedPoolTerms.selector;
        selectors[1] = IStaticsPermissionedPools.replacePermissionedPoolController.selector;
        selectors[2] = IStaticsPermissionedPools.invalidatePermissionedConfigurationNonce.selector;
        selectors[3] = IStaticsPermissionedPools.decommissionPermissionedPool.selector;
        selectors[4] = IStaticsPermissionedPools.setPermissionedTrustedPeriphery.selector;
        selectors[5] = IStaticsPermissionedPools.permissionedTermsDigest.selector;
        selectors[6] = IStaticsPermissionedPools.permissionedControllerReplacementDigest.selector;
    }

    function permissionedPoolView() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = IStaticsPermissionedPools.permissionedPool.selector;
        selectors[1] = IStaticsPermissionedPools.isPermissionedPool.selector;
        selectors[2] = IStaticsPermissionedPools.isPermissionedAuthorizationNonceUsed.selector;
    }

    function protocolPoolAdmin() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](10);
        selectors[0] = IStaticsProtocolPools.setPoolCreationFee.selector;
        selectors[1] = IStaticsProtocolPools.setDefaultProtocolPoolFeeRate.selector;
        selectors[2] = IStaticsProtocolPools.setProtocolPoolFeeRate.selector;
        selectors[3] = IStaticsProtocolPools.clearProtocolPoolFeeRate.selector;
        selectors[4] = IStaticsProtocolPools.setBasketFeeAllocation.selector;
        selectors[5] = IStaticsProtocolPools.setGeneralFeeAllocation.selector;
        selectors[6] = IStaticsProtocolPools.decommissionGeneralPool.selector;
        selectors[7] = IStaticsProtocolPools.replaceLiquidityManager.selector;
        selectors[8] = IStaticsProtocolPools.setPermanentLiquidityHarvester.selector;
        selectors[9] = IStaticsProtocolPools.harvestPermanentLiquidityFees.selector;
    }

    function phaseOneProtocolPoolAdmin() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](9);
        selectors[0] = IStaticsProtocolPools.setPoolCreationFee.selector;
        selectors[1] = IStaticsProtocolPools.setDefaultProtocolPoolFeeRate.selector;
        selectors[2] = IStaticsProtocolPools.setProtocolPoolFeeRate.selector;
        selectors[3] = IStaticsProtocolPools.clearProtocolPoolFeeRate.selector;
        selectors[4] = IStaticsProtocolPools.setGeneralFeeAllocation.selector;
        selectors[5] = IStaticsProtocolPools.decommissionGeneralPool.selector;
        selectors[6] = IStaticsProtocolPools.replaceLiquidityManager.selector;
        selectors[7] = IStaticsProtocolPools.setPermanentLiquidityHarvester.selector;
        selectors[8] = IStaticsProtocolPools.harvestPermanentLiquidityFees.selector;
    }

    function phaseTwoProtocolPoolAdmin() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IStaticsProtocolPools.setBasketFeeAllocation.selector;
    }

    function protocolPoolView() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](10);
        selectors[0] = IStaticsProtocolPools.protocolPool.selector;
        selectors[1] = IStaticsProtocolPools.isProtocolPool.selector;
        selectors[2] = IStaticsProtocolPools.poolCreationFee.selector;
        selectors[3] = IStaticsProtocolPools.isPoolCreationNonceUsed.selector;
        selectors[4] = IStaticsProtocolPools.basketFeeAllocation.selector;
        selectors[5] = IStaticsProtocolPools.generalFeeAllocation.selector;
        selectors[6] = IStaticsProtocolPools.defaultProtocolPoolFeeRate.selector;
        selectors[7] = IStaticsProtocolPools.protocolPoolFeeRate.selector;
        selectors[8] = IStaticsProtocolPools.protocolPoolCreator.selector;
        selectors[9] = IStaticsProtocolPools.permanentLiquidityHarvester.selector;
    }

    function phaseOneProtocolPoolView() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](9);
        selectors[0] = IStaticsProtocolPools.protocolPool.selector;
        selectors[1] = IStaticsProtocolPools.isProtocolPool.selector;
        selectors[2] = IStaticsProtocolPools.poolCreationFee.selector;
        selectors[3] = IStaticsProtocolPools.isPoolCreationNonceUsed.selector;
        selectors[4] = IStaticsProtocolPools.generalFeeAllocation.selector;
        selectors[5] = IStaticsProtocolPools.defaultProtocolPoolFeeRate.selector;
        selectors[6] = IStaticsProtocolPools.protocolPoolFeeRate.selector;
        selectors[7] = IStaticsProtocolPools.protocolPoolCreator.selector;
        selectors[8] = IStaticsProtocolPools.permanentLiquidityHarvester.selector;
    }

    function phaseTwoProtocolPoolView() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IStaticsProtocolPools.basketFeeAllocation.selector;
    }

    function protocolRevenue() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = IStaticsProtocolRevenue.routeProtocolSwapFees.selector;
        selectors[1] = IStaticsProtocolRevenue.claimCreatorRevenue.selector;
        selectors[2] = IStaticsProtocolRevenue.creatorRevenue.selector;
        selectors[3] = IStaticsProtocolRevenue.totalCreatorRevenue.selector;
        selectors[4] = IStaticsProtocolRevenue.canAccrueBasketRewards.selector;
    }

    function phaseOneProtocolRevenue() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = IStaticsProtocolRevenue.routeProtocolSwapFees.selector;
        selectors[1] = IStaticsProtocolRevenue.claimCreatorRevenue.selector;
        selectors[2] = IStaticsProtocolRevenue.creatorRevenue.selector;
        selectors[3] = IStaticsProtocolRevenue.totalCreatorRevenue.selector;
    }

    function phaseTwoProtocolRevenue() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IStaticsProtocolRevenue.canAccrueBasketRewards.selector;
    }

    function lending() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](10);
        selectors[0] = IStaticsLending.borrow.selector;
        selectors[1] = IStaticsLending.repay.selector;
        selectors[2] = IStaticsLending.extend.selector;
        selectors[3] = IStaticsLending.recover.selector;
        selectors[4] = IStaticsLending.quoteBorrow.selector;
        selectors[5] = IStaticsLending.quoteRecovery.selector;
        selectors[6] = IStaticsLending.quoteExtension.selector;
        selectors[7] = IStaticsLending.loan.selector;
        selectors[8] = IStaticsLending.outstandingPrincipal.selector;
        selectors[9] = IStaticsLending.recoveryGracePeriod.selector;
    }

    function borrowLiquidity() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IStaticsBorrowLiquidity.borrowAndProvideLiquidity.selector;
    }

    function flashLoan() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](7);
        selectors[0] = IStaticsFlashLoan.flashLoan.selector;
        selectors[1] = IStaticsFlashLoan.quoteFlashLoan.selector;
        selectors[2] = IStaticsFlashLoan.flashLoanAsset.selector;
        selectors[3] = IStaticsFlashLoan.quoteFlashLoanAsset.selector;
        selectors[4] = IStaticsFlashLoan.maxFlashLoan.selector;
        selectors[5] = IStaticsFlashLoan.singleAssetFlashFeeBps.selector;
        selectors[6] = IStaticsFlashLoan.setSingleAssetFlashFeeBps.selector;
    }

    function dollarStaking() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](22);
        selectors[0] = StakingFacet.createAndStakeRiskShares.selector;
        selectors[1] = StakingFacet.stakeRiskShares.selector;
        selectors[2] = StakingFacet.unstakeRiskShares.selector;
        selectors[3] = StakingFacet.claimRiskProceeds.selector;
        selectors[4] = StakingFacet.closeRiskLiquidity.selector;
        selectors[5] = StakingFacet.riskLiquidity.selector;
        selectors[6] = StakingFacet.totalRiskLiquidity.selector;
        selectors[7] = StakingFacet.riskLiquidityScaleRay.selector;
        selectors[8] = StakingFacet.positionSeriesCount.selector;
        selectors[9] = StakingFacet.positionSeriesAt.selector;
        selectors[10] = StakingFacet.reservedBalance.selector;
        selectors[11] = StakingFacet.onERC1155Received.selector;
        selectors[12] = StakingFacet.onERC1155BatchReceived.selector;
        selectors[13] = StakingFacet.pool.selector;
        selectors[14] = StakingFacet.staticsDollar.selector;
        selectors[15] = StakingFacet.staticsDollarRisk.selector;
        selectors[16] = StakingFacet.positionNFT.selector;
        selectors[17] = StakingFacet.fundRiskCollateralIncentives.selector;
        selectors[18] = StakingFacet.fundRiskDollarIncentives.selector;
        selectors[19] = StakingFacet.fundRiskStaticsIncentives.selector;
        selectors[20] = StakingFacet.riskIncentives.selector;
        selectors[21] = StakingFacet.finalizeRiskIncentives.selector;
    }

    function dollarSeriesMigration() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = IStaticsDollarSeriesMigration.processSeriesTransition.selector;
        selectors[1] = IStaticsDollarSeriesMigration.settleSeriesMigration.selector;
        selectors[2] = IStaticsDollarSeriesMigration.seriesMigration.selector;
    }

    function dollarFeeRouter() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](7);
        selectors[0] = FeeRouterFacet.onSeriesFee.selector;
        selectors[1] = FeeRouterFacet.onPeggedProfileFee.selector;
        selectors[2] = FeeRouterFacet.onRetiredSurplus.selector;
        selectors[3] = FeeRouterFacet.routePendingInsurance.selector;
        selectors[4] = FeeRouterFacet.setSplit.selector;
        selectors[5] = FeeRouterFacet.splits.selector;
        selectors[6] = FeeRouterFacet.pendingInsurance.selector;
    }

    function dollarPairingVault() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = PairingVaultFacet.redeem.selector;
        selectors[1] = PairingVaultFacet.redeemToETH.selector;
        selectors[2] = PairingVaultFacet.previewRedeem.selector;
        selectors[3] = PairingVaultFacet.setRedemptionParams.selector;
        selectors[4] = PairingVaultFacet.redemptionParams.selector;
        selectors[5] = PairingVaultFacet.redeemableLiquidity.selector;
    }

    function dollarGateway() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](18);
        selectors[0] = StaticsDollarGatewayFacet.depositETH.selector;
        selectors[1] = StaticsDollarGatewayFacet.depositWETH.selector;
        selectors[2] = StaticsDollarGatewayFacet.recombineToWETH.selector;
        selectors[3] = StaticsDollarGatewayFacet.recombineToWETHWithPermit.selector;
        selectors[4] = StaticsDollarGatewayFacet.recombineToETH.selector;
        selectors[5] = StaticsDollarGatewayFacet.recombineToETHWithPermit.selector;
        selectors[6] = StaticsDollarGatewayFacet.weth.selector;
        selectors[7] = StaticsDollarGatewayFacet.wethProfileId.selector;
        selectors[8] = StaticsDollarGatewayFacet.previewPeggedMint.selector;
        selectors[9] = StaticsDollarGatewayFacet.mintPegged.selector;
        selectors[10] = StaticsDollarGatewayFacet.mintPeggedWithPermit.selector;
        selectors[11] = StaticsDollarGatewayFacet.quoteMintPeggedAndRecombine.selector;
        selectors[12] = StaticsDollarGatewayFacet.mintPeggedAndRecombine.selector;
        selectors[13] = StaticsDollarGatewayFacet.mintPeggedAndRecombineWithPermit.selector;
        selectors[14] = StaticsDollarGatewayFacet.previewPeggedRedemption.selector;
        selectors[15] = StaticsDollarGatewayFacet.redeemPegged.selector;
        selectors[16] = StaticsDollarGatewayFacet.redeemPeggedWithPermit.selector;
        selectors[17] = StaticsDollarGatewayFacet.peggedRedemptionStatus.selector;
    }
}
