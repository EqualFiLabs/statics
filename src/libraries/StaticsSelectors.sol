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
import {IStaticsLiquidityRewards} from "../interfaces/IStaticsLiquidityRewards.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IModularPositionNFT} from "../interfaces/IModularPositionNFT.sol";
import {IPositionOwnerIndex} from "../interfaces/IPositionOwnerIndex.sol";
import {IStaticsPositionPortfolio} from "../interfaces/IStaticsPositionPortfolio.sol";
import {IStaticsPosition, IStaticsPositionFees, IStaticsPositionModule} from "../interfaces/IStaticsPosition.sol";
import {StaticsInterfaceInit} from "../diamond/StaticsInterfaceInit.sol";

library StaticsSelectors {
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
        selectors = new bytes4[](9);
        selectors[0] = IStaticsGovernance.guardian.selector;
        selectors[1] = IStaticsGovernance.pausedActions.selector;
        selectors[2] = IStaticsGovernance.isPaused.selector;
        selectors[3] = IStaticsGovernance.setGuardian.selector;
        selectors[4] = IStaticsGovernance.pause.selector;
        selectors[5] = IStaticsGovernance.unpause.selector;
        selectors[6] = IStaticsGovernance.quarantineBasket.selector;
        selectors[7] = IStaticsGovernance.releaseBasketQuarantine.selector;
        selectors[8] = IStaticsGovernance.decommissionBasket.selector;
    }

    function position() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](26);
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
        selectors[3] = IStaticsPositionPortfolio.liquidityPositionIdsOfPosition.selector;
        selectors[4] = IStaticsPositionPortfolio.globalRewardAssetsOfPosition.selector;
        selectors[5] = IStaticsPositionPortfolio.riskSeriesIdsOfPosition.selector;
    }

    function custody() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](7);
        selectors[0] = IStaticsCustody.globalReservedByToken.selector;
        selectors[1] = IStaticsCustody.reservedByAccount.selector;
        selectors[2] = IStaticsCustody.unreservedBalance.selector;
        selectors[3] = IStaticsCustody.dollarCustodyAccount.selector;
        selectors[4] = IStaticsCustody.basketCustodyAccount.selector;
        selectors[5] = IStaticsCustody.feeCustodyAccount.selector;
        selectors[6] = IStaticsCustody.stakingCustodyAccount.selector;
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
        selectors = new bytes4[](21);
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
        selectors[20] = IStaticsGlobalRewards.routeSwapFees.selector;
    }

    function basketAdmin() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = IStaticsBasketAdmin.setCreationFee.selector;
        selectors[1] = IStaticsBasketAdmin.setTreasury.selector;
        selectors[2] = IStaticsBasketAdmin.creationFee.selector;
        selectors[3] = IStaticsBasketAdmin.treasury.selector;
    }

    function basketLiquidity() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](14);
        selectors[0] = IStaticsBasketLiquidity.installCanonicalPoolIntegration.selector;
        selectors[1] = IStaticsBasketLiquidity.installLiquidityManager.selector;
        selectors[2] = IStaticsBasketLaunchModule.launchBasketPools.selector;
        selectors[3] = IStaticsBasketLaunchModule.mintBasketLaunch.selector;
        selectors[4] = IStaticsBasketLiquidity.setSwapFeeConfiguration.selector;
        selectors[5] = IStaticsBasketLiquidity.unwindBasketLiquidity.selector;
        selectors[6] = IStaticsBasketLiquidity.liquidityIntegration.selector;
        selectors[7] = IStaticsBasketLiquidity.liquidityManager.selector;
        selectors[8] = IStaticsBasketLiquidity.canonicalPool.selector;
        selectors[9] = IStaticsBasketLiquidity.swapFeeConfiguration.selector;
        selectors[10] = IStaticsBasketLiquidity.basketLiquidityUnwound.selector;
        selectors[11] = IStaticsBasketLiquidity.setCanonicalPoolFeeConfiguration.selector;
        selectors[12] = IStaticsBasketLiquidity.clearCanonicalPoolFeeConfiguration.selector;
        selectors[13] = IStaticsBasketLiquidity.canonicalPoolFeeConfiguration.selector;
    }

    function protocolPools() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](9);
        selectors[0] = IStaticsProtocolPools.quoteGovernancePool.selector;
        selectors[1] = IStaticsProtocolPools.createGovernancePool.selector;
        selectors[2] = IStaticsProtocolPools.setProtocolPoolFeeConfiguration.selector;
        selectors[3] = IStaticsProtocolPools.clearProtocolPoolFeeConfiguration.selector;
        selectors[4] = IStaticsProtocolPools.protocolPoolFeeConfiguration.selector;
        selectors[5] = IStaticsProtocolPools.decommissionGovernancePool.selector;
        selectors[6] = IStaticsProtocolPools.replaceLiquidityManager.selector;
        selectors[7] = IStaticsProtocolPools.protocolPool.selector;
        selectors[8] = IStaticsProtocolPools.isProtocolPool.selector;
    }

    function liquidityRewards() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](11);
        selectors[0] = IStaticsLiquidityRewards.stakeLiquidityPosition.selector;
        selectors[1] = IStaticsLiquidityRewards.activateLiquidityPosition.selector;
        selectors[2] = IStaticsLiquidityRewards.increaseStakedLiquidity.selector;
        selectors[3] = IStaticsLiquidityRewards.unstakeLiquidityPosition.selector;
        selectors[4] = IStaticsLiquidityRewards.claimLiquidityRewards.selector;
        selectors[5] = IStaticsLiquidityRewards.routeCanonicalSwapFees.selector;
        selectors[6] = IStaticsLiquidityRewards.stakedLiquidityPosition.selector;
        selectors[7] = IStaticsLiquidityRewards.poolLiquidityRewards.selector;
        selectors[8] = IStaticsLiquidityRewards.pendingLiquidityRewards.selector;
        selectors[9] = IStaticsLiquidityRewards.canAccrueLiquidityRewards.selector;
        selectors[10] = IStaticsLiquidityRewards.canAccrueBasketRewards.selector;
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
        selectors = new bytes4[](2);
        selectors[0] = IStaticsBorrowLiquidity.borrowAndProvideLiquidity.selector;
        selectors[1] = IStaticsBorrowLiquidity.borrowAndStakeLiquidity.selector;
    }

    function flashLoan() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = IStaticsFlashLoan.flashLoan.selector;
        selectors[1] = IStaticsFlashLoan.quoteFlashLoan.selector;
    }
}
