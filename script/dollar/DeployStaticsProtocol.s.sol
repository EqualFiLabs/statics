// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {DiamondCutFacet} from "../../src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/facets/OwnershipFacet.sol";
import {GovernanceFacet} from "../../src/facets/GovernanceFacet.sol";
import {BasketFacet} from "../../src/facets/BasketFacet.sol";
import {BasketRewardsFacet} from "../../src/facets/BasketRewardsFacet.sol";
import {BasketAdminFacet} from "../../src/facets/BasketAdminFacet.sol";
import {BasketLiquidityFacet} from "../../src/facets/BasketLiquidityFacet.sol";
import {BorrowLiquidityFacet} from "../../src/facets/BorrowLiquidityFacet.sol";
import {LendingFacet} from "../../src/facets/LendingFacet.sol";
import {FlashLoanFacet} from "../../src/facets/FlashLoanFacet.sol";
import {CustodyFacet} from "../../src/facets/CustodyFacet.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {StaticsDiamond} from "../../src/diamond/StaticsDiamond.sol";
import {StaticsInterfaceInit} from "../../src/diamond/StaticsInterfaceInit.sol";
import {StaticsProtocolInit} from "../../src/diamond/StaticsProtocolInit.sol";
import {FeeRouterFacet} from "../../src/dollar/periphery/facets/FeeRouterFacet.sol";
import {OptInFacet} from "../../src/dollar/periphery/facets/OptInFacet.sol";
import {PairingVaultFacet} from "../../src/dollar/periphery/facets/PairingVaultFacet.sol";
import {RewardsFacet} from "../../src/dollar/periphery/facets/RewardsFacet.sol";
import {StakingFacet} from "../../src/dollar/periphery/facets/StakingFacet.sol";
import {StaticsDollarGatewayFacet} from "../../src/dollar/periphery/facets/StaticsDollarGatewayFacet.sol";
import {LibPeriphery} from "../../src/dollar/periphery/libraries/LibPeriphery.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";
import {PositionNFTFacet} from "../../src/position/PositionNFTFacet.sol";

abstract contract DeployStaticsProtocol {
    struct ProtocolParts {
        address cut;
        address loupe;
        address ownership;
        address governance;
        address position;
        address custody;
        address basket;
        address basketRewards;
        address basketAdmin;
        address borrowLiquidity;
        address lending;
        address flashLoan;
        address interfaceInit;
        address staking;
        address rewards;
        address optIn;
        address fee;
        address vault;
        address gateway;
        address init;
    }

    function _deployStaticsProtocol(
        address pool,
        address weth,
        address finalOwner,
        address guardian,
        address treasury,
        uint256 creationFeeAmount
    ) internal returns (address diamond, address positionNFT) {
        ProtocolParts memory parts = _deployProtocolParts();
        IDiamondCut.FacetCut[] memory cut = _protocolCut(parts, address(new BasketLiquidityFacet()));
        LibPeriphery.InitArgs memory dollarArgs = LibPeriphery.InitArgs({
            pool: pool,
            weth: weth,
            baseBps: 7_000,
            insuranceBps: 3_000,
            passiveRewardBps: 3_000,
            redemptionFeeBps: 50,
            redemptionStakerShareBps: 8_000
        });
        StaticsProtocolInit.UnifiedInitArgs memory args = StaticsProtocolInit.UnifiedInitArgs({
            guardian: guardian, treasury: treasury, creationFeeAmount: creationFeeAmount, dollar: dollarArgs
        });
        StaticsDiamond deployedDiamond = new StaticsDiamond(
            finalOwner, cut, parts.init, abi.encodeCall(StaticsProtocolInit.initializeUnified, (args)), weth
        );
        return (address(deployedDiamond), address(deployedDiamond));
    }

    function _deployProtocolParts() internal returns (ProtocolParts memory parts) {
        parts.cut = address(new DiamondCutFacet());
        parts.loupe = address(new DiamondLoupeFacet());
        parts.ownership = address(new OwnershipFacet());
        parts.governance = address(new GovernanceFacet());
        parts.position = address(new PositionNFTFacet());
        parts.custody = address(new CustodyFacet());
        parts.basket = address(new BasketFacet());
        parts.basketRewards = address(new BasketRewardsFacet());
        parts.basketAdmin = address(new BasketAdminFacet());
        parts.borrowLiquidity = address(new BorrowLiquidityFacet());
        parts.lending = address(new LendingFacet());
        parts.flashLoan = address(new FlashLoanFacet());
        parts.interfaceInit = address(new StaticsInterfaceInit());
        parts.staking = address(new StakingFacet());
        parts.rewards = address(new RewardsFacet());
        parts.optIn = address(new OptInFacet());
        parts.fee = address(new FeeRouterFacet());
        parts.vault = address(new PairingVaultFacet());
        parts.gateway = address(new StaticsDollarGatewayFacet());
        parts.init = address(new StaticsProtocolInit());
    }

    function _protocolCut(ProtocolParts memory parts, address basketLiquidity)
        internal
        pure
        returns (IDiamondCut.FacetCut[] memory cut)
    {
        cut = new IDiamondCut.FacetCut[](20);
        cut[0] = IDiamondCut.FacetCut(parts.cut, IDiamondCut.FacetCutAction.Add, StaticsSelectors.diamondCut());
        cut[1] = IDiamondCut.FacetCut(parts.loupe, IDiamondCut.FacetCutAction.Add, StaticsSelectors.diamondLoupe());
        cut[2] = IDiamondCut.FacetCut(parts.ownership, IDiamondCut.FacetCutAction.Add, StaticsSelectors.ownership());
        cut[3] = IDiamondCut.FacetCut(parts.governance, IDiamondCut.FacetCutAction.Add, StaticsSelectors.governance());
        cut[4] = IDiamondCut.FacetCut(parts.position, IDiamondCut.FacetCutAction.Add, StaticsSelectors.position());
        cut[5] = IDiamondCut.FacetCut(parts.custody, IDiamondCut.FacetCutAction.Add, StaticsSelectors.custody());
        cut[6] = IDiamondCut.FacetCut(parts.basket, IDiamondCut.FacetCutAction.Add, StaticsSelectors.basket());
        cut[7] = IDiamondCut.FacetCut(parts.basketAdmin, IDiamondCut.FacetCutAction.Add, StaticsSelectors.basketAdmin());
        cut[8] = IDiamondCut.FacetCut(parts.lending, IDiamondCut.FacetCutAction.Add, StaticsSelectors.lending());
        cut[9] = IDiamondCut.FacetCut(parts.flashLoan, IDiamondCut.FacetCutAction.Add, StaticsSelectors.flashLoan());
        cut[10] =
            IDiamondCut.FacetCut(parts.interfaceInit, IDiamondCut.FacetCutAction.Add, StaticsSelectors.interfaceInit());
        cut[11] = IDiamondCut.FacetCut(parts.staking, IDiamondCut.FacetCutAction.Add, _dollarStakingSelectors());
        cut[12] = IDiamondCut.FacetCut(parts.rewards, IDiamondCut.FacetCutAction.Add, _dollarRewardsSelectors());
        cut[13] = IDiamondCut.FacetCut(parts.optIn, IDiamondCut.FacetCutAction.Add, _dollarOptInSelectors());
        cut[14] = IDiamondCut.FacetCut(parts.fee, IDiamondCut.FacetCutAction.Add, _dollarFeeSelectors());
        cut[15] = IDiamondCut.FacetCut(parts.vault, IDiamondCut.FacetCutAction.Add, _dollarVaultSelectors());
        cut[16] =
            IDiamondCut.FacetCut(parts.basketRewards, IDiamondCut.FacetCutAction.Add, StaticsSelectors.basketRewards());
        cut[17] = IDiamondCut.FacetCut(parts.gateway, IDiamondCut.FacetCutAction.Add, _dollarGatewaySelectors());
        cut[18] =
            IDiamondCut.FacetCut(basketLiquidity, IDiamondCut.FacetCutAction.Add, StaticsSelectors.basketLiquidity());
        cut[19] = IDiamondCut.FacetCut(
            parts.borrowLiquidity, IDiamondCut.FacetCutAction.Add, StaticsSelectors.borrowLiquidity()
        );
    }

    function _dollarStakingSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](19);
        s[0] = StakingFacet.createAndStake.selector;
        s[1] = StakingFacet.stake.selector;
        s[2] = StakingFacet.activateLeg.selector;
        s[3] = StakingFacet.withdrawLeg.selector;
        s[4] = StakingFacet.migrateLeg.selector;
        s[5] = StakingFacet.processSeriesTransition.selector;
        s[6] = StakingFacet.settleSeriesMigration.selector;
        s[7] = StakingFacet.closeLeg.selector;
        s[8] = StakingFacet.leg.selector;
        s[9] = StakingFacet.positionSeriesCount.selector;
        s[10] = StakingFacet.positionSeriesAt.selector;
        s[11] = StakingFacet.seriesMigration.selector;
        s[12] = StakingFacet.rewardEligibleAt.selector;
        s[13] = StakingFacet.onERC1155Received.selector;
        s[14] = StakingFacet.onERC1155BatchReceived.selector;
        s[15] = StakingFacet.pool.selector;
        s[16] = StakingFacet.staticsDollar.selector;
        s[17] = StakingFacet.staticsDollarRisk.selector;
        s[18] = StakingFacet.positionNFT.selector;
    }

    function _dollarRewardsSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](7);
        s[0] = RewardsFacet.donateCollateralRewards.selector;
        s[1] = RewardsFacet.donateStaticsDollarRewards.selector;
        s[2] = RewardsFacet.claimSeriesRewards.selector;
        s[3] = RewardsFacet.pendingSeriesRewards.selector;
        s[4] = RewardsFacet.finalizeRetiredSeriesRewards.selector;
        s[5] = RewardsFacet.seriesRewardState.selector;
        s[6] = RewardsFacet.reservedBalance.selector;
    }

    function _dollarOptInSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = OptInFacet.optIn.selector;
        s[1] = OptInFacet.optOut.selector;
        s[2] = OptInFacet.optInBalanceOf.selector;
        s[3] = OptInFacet.optInTotal.selector;
        s[4] = OptInFacet.optInScaleRay.selector;
        s[5] = OptInFacet.cleanupOptInDust.selector;
    }

    function _dollarFeeSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](10);
        s[0] = FeeRouterFacet.onSeriesFee.selector;
        s[1] = FeeRouterFacet.onPeggedProfileFee.selector;
        s[2] = FeeRouterFacet.routePendingInsurance.selector;
        s[3] = FeeRouterFacet.setSplit.selector;
        s[4] = FeeRouterFacet.splits.selector;
        s[5] = FeeRouterFacet.pendingInsurance.selector;
        s[6] = FeeRouterFacet.setRewardSplit.selector;
        s[7] = FeeRouterFacet.rewardSplit.selector;
        s[8] = FeeRouterFacet.peggedProtocolRevenue.selector;
        s[9] = FeeRouterFacet.claimPeggedProtocolRevenue.selector;
    }

    function _dollarVaultSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = PairingVaultFacet.redeem.selector;
        s[1] = PairingVaultFacet.redeemToETH.selector;
        s[2] = PairingVaultFacet.previewRedeem.selector;
        s[3] = PairingVaultFacet.setRedemptionParams.selector;
        s[4] = PairingVaultFacet.redemptionParams.selector;
        s[5] = PairingVaultFacet.redeemableLiquidity.selector;
    }

    function _dollarGatewaySelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](15);
        s[0] = StaticsDollarGatewayFacet.depositETH.selector;
        s[1] = StaticsDollarGatewayFacet.depositWETH.selector;
        s[2] = StaticsDollarGatewayFacet.recombineToWETH.selector;
        s[3] = StaticsDollarGatewayFacet.recombineToWETHWithPermit.selector;
        s[4] = StaticsDollarGatewayFacet.recombineToETH.selector;
        s[5] = StaticsDollarGatewayFacet.recombineToETHWithPermit.selector;
        s[6] = StaticsDollarGatewayFacet.weth.selector;
        s[7] = StaticsDollarGatewayFacet.wethProfileId.selector;
        s[8] = StaticsDollarGatewayFacet.previewPeggedMint.selector;
        s[9] = StaticsDollarGatewayFacet.mintPegged.selector;
        s[10] = StaticsDollarGatewayFacet.mintPeggedWithPermit.selector;
        s[11] = StaticsDollarGatewayFacet.previewPeggedRedemption.selector;
        s[12] = StaticsDollarGatewayFacet.redeemPegged.selector;
        s[13] = StaticsDollarGatewayFacet.redeemPeggedWithPermit.selector;
        s[14] = StaticsDollarGatewayFacet.peggedRedemptionStatus.selector;
    }
}
