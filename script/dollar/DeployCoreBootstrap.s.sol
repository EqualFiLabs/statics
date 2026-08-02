// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";

import {DeployStaticsProtocol} from "./DeployStaticsProtocol.s.sol";
import {CoreInit} from "../../src/dollar/core/CoreInit.sol";
import {StaticsDollarCoreDiamond} from "../../src/dollar/core/StaticsDollarCoreDiamond.sol";
import {CoreGovernanceFacet} from "../../src/dollar/core/facets/CoreGovernanceFacet.sol";
import {CoreHealthFacet} from "../../src/dollar/core/facets/CoreHealthFacet.sol";
import {CoreInsuranceFacet} from "../../src/dollar/core/facets/CoreInsuranceFacet.sol";
import {CoreMintFacet} from "../../src/dollar/core/facets/CoreMintFacet.sol";
import {CoreRecoveryFacet} from "../../src/dollar/core/facets/CoreRecoveryFacet.sol";
import {CoreReceiverFacet} from "../../src/dollar/core/facets/CoreReceiverFacet.sol";
import {CoreTransitionFacet} from "../../src/dollar/core/facets/CoreTransitionFacet.sol";
import {CoreViewFacet} from "../../src/dollar/core/facets/CoreViewFacet.sol";
import {DiamondCutFacet} from "../../src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/facets/OwnershipFacet.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {StaticsDollarRiskShares} from "../../src/dollar/StaticsDollarRiskShares.sol";
import {StaticsDollar} from "../../src/dollar/StaticsDollar.sol";

struct CoreBootstrapConfig {
    address owner;
    address profileGuardian;
    address treasury;
    uint256 creationFeeAmount;
    address initialOracle;
    address requiredSequencerUptimeFeed;
    uint256 minimumSequencerGracePeriod;
    address weth;
    uint256 collateralRatioBps;
    uint256 priceBandBps;
    uint256 debtCeiling;
    string riskUri;
}

struct CoreBootstrapDeployment {
    address core;
    address staticsDollar;
    address staticsDollarRisk;
    address diamond;
    address positionNFT;
}

contract DeployCoreBootstrap is Script, DeployStaticsProtocol {
    struct CoreParts {
        address cut;
        address loupe;
        address ownership;
        address governance;
        address health;
        address insurance;
        address mint;
        address recovery;
        address transition;
        address receiver;
        address viewFacet;
        address init;
    }

    error ZeroAddress();
    error CorePredictionMismatch(address predicted, address actual);

    function deploy(CoreBootstrapConfig memory config) public virtual returns (CoreBootstrapDeployment memory) {
        return deploy(config, address(this));
    }

    function deploy(CoreBootstrapConfig memory config, address deploymentCreator)
        public
        virtual
        returns (CoreBootstrapDeployment memory)
    {
        if (
            config.owner == address(0) || config.profileGuardian == address(0) || config.initialOracle == address(0)
                || config.weth == address(0) || deploymentCreator == address(0)
        ) revert ZeroAddress();
        if (config.collateralRatioBps == 0) config.collateralRatioBps = 15_000;
        if (config.priceBandBps == 0) config.priceBandBps = 15_000;
        if (config.debtCeiling == 0) config.debtCeiling = 1_000_000e18;

        (address core, address staticsDollar, address staticsDollarRisk) = _deployCore(config, deploymentCreator);
        if (config.treasury == address(0)) config.treasury = config.owner;
        (address diamond, address positionNFT) = _deployUnifiedProtocol(config, core);
        CoreGovernanceFacet(core).finalizeBootstrap(diamond);
        return CoreBootstrapDeployment({
            core: core,
            staticsDollar: staticsDollar,
            staticsDollarRisk: staticsDollarRisk,
            diamond: diamond,
            positionNFT: positionNFT
        });
    }

    function _deployUnifiedProtocol(CoreBootstrapConfig memory config, address core)
        private
        returns (address diamond, address positionNFT)
    {
        return _deployStaticsProtocol(
            core, config.weth, config.owner, config.profileGuardian, config.treasury, config.creationFeeAmount
        );
    }

    function _deployCore(CoreBootstrapConfig memory config, address deploymentCreator)
        private
        returns (address coreAddress, address staticsDollar, address staticsDollarRisk)
    {
        CoreParts memory parts = _deployCoreParts();
        address predictedCore = vm.computeCreateAddress(deploymentCreator, vm.getNonce(deploymentCreator) + 2);
        staticsDollar = address(new StaticsDollar(predictedCore));
        staticsDollarRisk = address(new StaticsDollarRiskShares(predictedCore, config.riskUri));
        IDiamondCut.FacetCut[] memory genesis = _coreGenesis(parts);
        CoreInit.InitArgs memory args = CoreInit.InitArgs({
            staticsDollar: staticsDollar,
            staticsDollarRisk: staticsDollarRisk,
            initialOracle: config.initialOracle,
            requiredSequencerUptimeFeed: config.requiredSequencerUptimeFeed,
            minimumSequencerGracePeriod: config.minimumSequencerGracePeriod,
            profileGuardian: config.profileGuardian,
            initialCollateralToken: config.weth,
            collateralRatioBps: config.collateralRatioBps,
            priceBandBps: config.priceBandBps,
            debtCeiling: config.debtCeiling
        });
        StaticsDollarCoreDiamond core =
            new StaticsDollarCoreDiamond(config.owner, genesis, parts.init, abi.encodeCall(CoreInit.init, (args)));
        coreAddress = address(core);
        if (coreAddress != predictedCore) revert CorePredictionMismatch(predictedCore, coreAddress);
    }

    function _deployCoreParts() internal returns (CoreParts memory parts) {
        parts.cut = address(new DiamondCutFacet());
        parts.loupe = address(new DiamondLoupeFacet());
        parts.ownership = address(new OwnershipFacet());
        parts.governance = address(new CoreGovernanceFacet());
        parts.health = address(new CoreHealthFacet());
        parts.insurance = address(new CoreInsuranceFacet());
        parts.mint = address(new CoreMintFacet());
        parts.recovery = address(new CoreRecoveryFacet());
        parts.transition = address(new CoreTransitionFacet());
        parts.receiver = address(new CoreReceiverFacet());
        parts.viewFacet = address(new CoreViewFacet());
        parts.init = address(new CoreInit());
    }

    function _coreGenesis(CoreParts memory parts) internal pure returns (IDiamondCut.FacetCut[] memory genesis) {
        genesis = new IDiamondCut.FacetCut[](11);
        genesis[0] = IDiamondCut.FacetCut(parts.cut, IDiamondCut.FacetCutAction.Add, _coreCutSelectors());
        genesis[1] = IDiamondCut.FacetCut(parts.loupe, IDiamondCut.FacetCutAction.Add, _coreLoupeSelectors());
        genesis[2] = IDiamondCut.FacetCut(parts.ownership, IDiamondCut.FacetCutAction.Add, _coreOwnershipSelectors());
        genesis[3] = IDiamondCut.FacetCut(parts.governance, IDiamondCut.FacetCutAction.Add, _coreGovernanceSelectors());
        genesis[4] = IDiamondCut.FacetCut(parts.health, IDiamondCut.FacetCutAction.Add, _coreHealthSelectors());
        genesis[5] = IDiamondCut.FacetCut(parts.insurance, IDiamondCut.FacetCutAction.Add, _coreInsuranceSelectors());
        genesis[6] = IDiamondCut.FacetCut(parts.mint, IDiamondCut.FacetCutAction.Add, _coreMintSelectors());
        genesis[7] = IDiamondCut.FacetCut(parts.transition, IDiamondCut.FacetCutAction.Add, _coreTransitionSelectors());
        genesis[8] = IDiamondCut.FacetCut(parts.recovery, IDiamondCut.FacetCutAction.Add, _coreRecoverySelectors());
        genesis[9] = IDiamondCut.FacetCut(parts.receiver, IDiamondCut.FacetCutAction.Add, _coreReceiverSelectors());
        genesis[10] = IDiamondCut.FacetCut(parts.viewFacet, IDiamondCut.FacetCutAction.Add, _coreViewSelectors());
    }

    function _coreCutSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IDiamondCut.diamondCut.selector;
    }

    function _coreLoupeSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = DiamondLoupeFacet.facets.selector;
        selectors[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        selectors[2] = DiamondLoupeFacet.facetAddresses.selector;
        selectors[3] = DiamondLoupeFacet.facetAddress.selector;
        selectors[4] = DiamondLoupeFacet.supportsInterface.selector;
    }

    function _coreOwnershipSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = OwnershipFacet.transferOwnership.selector;
        selectors[1] = OwnershipFacet.owner.selector;
    }

    function _coreGovernanceSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](10);
        selectors[0] = CoreGovernanceFacet.finalizeBootstrap.selector;
        selectors[1] = CoreGovernanceFacet.createCollateralProfile.selector;
        selectors[2] = CoreGovernanceFacet.createPeggedCollateralProfile.selector;
        selectors[3] = CoreGovernanceFacet.setProfileRiskConfig.selector;
        selectors[4] = CoreGovernanceFacet.reduceDebtCeiling.selector;
        selectors[5] = CoreGovernanceFacet.enterReduceOnly.selector;
        selectors[6] = CoreGovernanceFacet.setProfileMode.selector;
        selectors[7] = CoreGovernanceFacet.pauseProfileOperations.selector;
        selectors[8] = CoreGovernanceFacet.resumeProfileOperations.selector;
        selectors[9] = CoreGovernanceFacet.setProfileOracle.selector;
    }

    function _coreHealthSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](8);
        selectors[0] = bytes4(keccak256("GLOBAL_RECOVERY_DELAY()"));
        selectors[1] = CoreHealthFacet.profileSolvency.selector;
        selectors[2] = CoreHealthFacet.globalImpairment.selector;
        selectors[3] = CoreHealthFacet.syncProfileHealth.selector;
        selectors[4] = CoreHealthFacet.syncGlobalHealth.selector;
        selectors[5] = CoreHealthFacet.checkpointGlobalCollateralExit.selector;
        selectors[6] = CoreHealthFacet.peggedRedemptionStatus.selector;
        selectors[7] = CoreHealthFacet.checkpointPeggedRedemption.selector;
    }

    function _coreInsuranceSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = CoreInsuranceFacet.topUpInsurance.selector;
        selectors[1] = CoreInsuranceFacet.profileHealth.selector;
        selectors[2] = CoreInsuranceFacet.insuranceTarget.selector;
        selectors[3] = CoreInsuranceFacet.insuranceDeficit.selector;
    }

    function _coreMintSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](10);
        selectors[0] = CoreMintFacet.depositCollateral.selector;
        selectors[1] = CoreMintFacet.mintPegged.selector;
        selectors[2] = CoreMintFacet.redeemPegged.selector;
        selectors[3] = CoreMintFacet.recombine.selector;
        selectors[4] = CoreMintFacet.previewDeposit.selector;
        selectors[5] = CoreMintFacet.previewPeggedMint.selector;
        selectors[6] = CoreMintFacet.previewPeggedRedemption.selector;
        selectors[7] = CoreMintFacet.previewRecombine.selector;
        selectors[8] = CoreMintFacet.requiredSharesForRecombine.selector;
        selectors[9] = CoreMintFacet.recombineManaged.selector;
    }

    function _coreTransitionSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](7);
        selectors[0] = bytes4(keccak256("SERIES_TRANSITION_DELAY()"));
        selectors[1] = CoreTransitionFacet.registerManagedRecoveryHolder.selector;
        selectors[2] = CoreTransitionFacet.startSeriesTransition.selector;
        selectors[3] = CoreTransitionFacet.cancelSeriesTransition.selector;
        selectors[4] = CoreTransitionFacet.returnRiskShares.selector;
        selectors[5] = CoreTransitionFacet.reclaimReturnedRiskShares.selector;
        selectors[6] = CoreTransitionFacet.finalizeSeriesTransition.selector;
    }

    function _coreRecoverySelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = CoreRecoveryFacet.previewReturnedRiskClaim.selector;
        selectors[1] = CoreRecoveryFacet.claimReturnedRisk.selector;
        selectors[2] = CoreRecoveryFacet.redeemRecoverySenior.selector;
        selectors[3] = CoreRecoveryFacet.previewExpiredRiskRecovery.selector;
        selectors[4] = CoreRecoveryFacet.recoverExpiredRisk.selector;
    }

    function _coreReceiverSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = CoreReceiverFacet.onERC1155Received.selector;
        selectors[1] = CoreReceiverFacet.onERC1155BatchReceived.selector;
    }

    function _coreViewSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](41);
        selectors[0] = CoreViewFacet.staticsDollar.selector;
        selectors[1] = CoreViewFacet.staticsDollarRisk.selector;
        selectors[2] = CoreViewFacet.initialOracle.selector;
        selectors[3] = CoreViewFacet.requiredSequencerUptimeFeed.selector;
        selectors[4] = CoreViewFacet.minimumSequencerGracePeriod.selector;
        selectors[5] = CoreViewFacet.profileGuardian.selector;
        selectors[6] = CoreViewFacet.bootstrapAuthority.selector;
        selectors[7] = CoreViewFacet.periphery.selector;
        selectors[8] = CoreViewFacet.positionNFT.selector;
        selectors[9] = CoreViewFacet.initialized.selector;
        selectors[10] = CoreViewFacet.bootstrapFinalized.selector;
        selectors[11] = CoreViewFacet.firstCollateralProfileId.selector;
        selectors[12] = CoreViewFacet.nextProfileId.selector;
        selectors[13] = CoreViewFacet.nextSeriesId.selector;
        selectors[14] = CoreViewFacet.seniorLiabilities.selector;
        selectors[15] = CoreViewFacet.globalImpairmentLatched.selector;
        selectors[16] = CoreViewFacet.globalRecoveryStartedAt.selector;
        selectors[17] = CoreViewFacet.collateralProfile.selector;
        selectors[18] = CoreViewFacet.riskSeries.selector;
        selectors[19] = CoreViewFacet.seriesRecoveryState.selector;
        selectors[20] = CoreViewFacet.returnedRiskShares.selector;
        selectors[21] = CoreViewFacet.totalCollateral.selector;
        selectors[22] = CoreViewFacet.profileSeniorLiabilities.selector;
        selectors[23] = CoreViewFacet.insuranceReserve.selector;
        selectors[24] = CoreViewFacet.profileSeriesCount.selector;
        selectors[25] = CoreViewFacet.profileSeriesAt.selector;
        selectors[26] = CoreViewFacet.pausedProfileOperations.selector;
        selectors[27] = CoreViewFacet.solvencyBookContribution.selector;
        selectors[28] = CoreViewFacet.solvencyIndexMetadata.selector;
        selectors[29] = CoreViewFacet.collateralTokenProfileId.selector;
        selectors[30] = CoreViewFacet.profileOracleRevision.selector;
        selectors[31] = CoreViewFacet.profileOperationPaused.selector;
        selectors[32] = CoreViewFacet.cumulativeFeesPaid.selector;
        selectors[33] = CoreViewFacet.seriesCollateralValueWad.selector;
        selectors[34] = CoreViewFacet.seriesCollateralRatioBps.selector;
        selectors[35] = CoreViewFacet.collateralUsdPriceWad.selector;
        selectors[36] = CoreViewFacet.seriesDownsideTriggerPriceWad.selector;
        selectors[37] = CoreViewFacet.seriesUpsideTriggerPriceWad.selector;
        selectors[38] = CoreViewFacet.expiredRecoveryBook.selector;
        selectors[39] = CoreViewFacet.transitionSnapshot.selector;
        selectors[40] = CoreViewFacet.managedRecoveryHolder.selector;
    }
}
