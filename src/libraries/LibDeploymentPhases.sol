// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";

import {IStaticsDollarGateway} from "../dollar/interfaces/IStaticsDollarGateway.sol";
import {IStaticsDollarRiskIncentives} from "../dollar/interfaces/IStaticsDollarRiskIncentives.sol";
import {IStaticsDollarRiskLiquidity} from "../dollar/interfaces/IStaticsDollarRiskLiquidity.sol";
import {IStaticsDollarSeriesMigration} from "../dollar/interfaces/IStaticsDollarSeriesMigration.sol";
import {LibPeriphery} from "../dollar/periphery/libraries/LibPeriphery.sol";
import {IERC5192} from "../interfaces/IERC5192.sol";
import {IModularPositionNFT} from "../interfaces/IModularPositionNFT.sol";
import {IPositionOwnerIndex} from "../interfaces/IPositionOwnerIndex.sol";
import {IStaticsPositionRoyalty} from "../interfaces/IStaticsPositionRoyalty.sol";
import {IStaticsPositionMarket} from "../interfaces/IStaticsPositionMarket.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {IStaticsBasketPreparation} from "../interfaces/IStaticsBasketPreparation.sol";
import {IStaticsBasketLaunchPreview} from "../interfaces/IStaticsBasketLaunchPreview.sol";
import {IStaticsBasketDelegation} from "../interfaces/IStaticsBasketDelegation.sol";
import {IStaticsBasketArbitrage} from "../interfaces/IStaticsBasketArbitrage.sol";
import {IStaticsBasketMarkets} from "../interfaces/IStaticsBasketMarkets.sol";
import {IStaticsBasketAdmin} from "../interfaces/IStaticsBasketAdmin.sol";
import {IStaticsBasketCollateral} from "../interfaces/IStaticsBasketCollateral.sol";
import {IStaticsBasketLiquidity} from "../interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsBasketRewards} from "../interfaces/IStaticsBasketRewards.sol";
import {IStaticsBorrowLiquidity} from "../interfaces/IStaticsBorrowLiquidity.sol";
import {IStaticsCustody} from "../interfaces/IStaticsCustody.sol";
import {IStaticsFlashLoan} from "../interfaces/IStaticsFlashLoan.sol";
import {IStaticsGenesisIntegration} from "../interfaces/IStaticsGenesisIntegration.sol";
import {IStaticsGlobalRewards} from "../interfaces/IStaticsGlobalRewards.sol";
import {IStaticsGaugeIncentives} from "../interfaces/IStaticsGaugeIncentives.sol";
import {IStaticsGovernance} from "../interfaces/IStaticsGovernance.sol";
import {IStaticsLending} from "../interfaces/IStaticsLending.sol";
import {IStaticsMarketTape} from "../interfaces/IStaticsMarketTape.sol";
import {IStaticsMarketObservations} from "../interfaces/IStaticsMarketObservations.sol";
import {IStaticsMorpho} from "../interfaces/IStaticsMorpho.sol";
import {IStaticsPosition, IStaticsPositionFees} from "../interfaces/IStaticsPosition.sol";
import {IStaticsPositionPortfolio} from "../interfaces/IStaticsPositionPortfolio.sol";
import {IStaticsPermissionedPools} from "../interfaces/IStaticsPermissionedPools.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IStaticsProtocolRevenue} from "../interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsRangeGauge} from "../interfaces/IStaticsRangeGauge.sol";
import {IStaticsRewardPolicy} from "../interfaces/IStaticsRewardPolicy.sol";
import {LibBasket} from "./LibBasket.sol";
import {LibDiamond} from "./LibDiamond.sol";
import {LibFlashLoan} from "./LibFlashLoan.sol";

/// @notice Shared one-time state and interface initialization for fresh and staged deployments.
library LibDeploymentPhases {
    bytes32 internal constant STORAGE_POSITION = keccak256("statics.storage.deployment.phases.v1");

    struct PhaseStorage {
        uint8 activePhase;
    }

    error UnexpectedDeploymentPhase(uint256 expected, uint256 actual);

    event DeploymentPhaseActivated(uint8 indexed phase);

    function phaseStorage() internal pure returns (PhaseStorage storage ps) {
        bytes32 position = STORAGE_POSITION;
        assembly ("memory-safe") {
            ps.slot := position
        }
    }

    function initializePhaseOneInterfaces() internal {
        _advance(0, 1);
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.supportedInterfaces[type(IStaticsGlobalRewards).interfaceId] = true;
        ds.supportedInterfaces[type(IERC721).interfaceId] = true;
        ds.supportedInterfaces[type(IERC721Metadata).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsPosition).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsPositionFees).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsRangeGauge).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsGaugeIncentives).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsMarketTape).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsMarketObservations).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsRewardPolicy).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsPermissionedPools).interfaceId] = true;
        ds.supportedInterfaces[type(IModularPositionNFT).interfaceId] = true;
        ds.supportedInterfaces[type(IPositionOwnerIndex).interfaceId] = true;
        ds.supportedInterfaces[type(IERC5192).interfaceId] = true;
        ds.supportedInterfaces[type(IERC2981).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsPositionRoyalty).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsPositionMarket).interfaceId] = true;
    }

    function initializePhaseTwo(uint256 creationFeeAmount, uint256 singleAssetFlashFeeBps) internal {
        _advance(1, 2);
        LibBasket.basketStorage().creationFeeAmount = creationFeeAmount;
        LibFlashLoan.initialize(singleAssetFlashFeeBps);

        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.supportedInterfaces[type(IStaticsGovernance).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsBasket).interfaceId] = true;
        // The prepared-creation selector is additive; retain discovery for existing integrations.
        ds.supportedInterfaces[type(IStaticsBasket).interfaceId ^ IStaticsBasket.createBasketPrepared.selector] = true;
        ds.supportedInterfaces[type(IStaticsBasketPreparation).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsBasketLaunchPreview).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsBasketDelegation).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsBasketMarkets).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsBasketArbitrage).interfaceId] = true;
        ds.supportedInterfaces[
            type(IStaticsBasketLiquidity).interfaceId ^ IStaticsBasketLiquidity.unwindBasketMarket.selector
        ] = true;
        ds.supportedInterfaces[type(IStaticsBasketAdmin).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsBasketCollateral).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsBasketRewards).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsGenesisIntegration).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsBasketLiquidity).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsBorrowLiquidity).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsLending).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsFlashLoan).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsProtocolPools).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsProtocolRevenue).interfaceId] = true;
    }

    function initializePhaseThree(LibPeriphery.InitArgs memory args) internal {
        _advance(2, 3);
        LibPeriphery.initialize(args);

        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.supportedInterfaces[type(IStaticsCustody).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsDollarGateway).interfaceId] = true;
        ds.supportedInterfaces[type(IERC1155Receiver).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsDollarRiskLiquidity).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsDollarRiskIncentives).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsDollarSeriesMigration).interfaceId] = true;
    }

    function initializePhaseFour() internal {
        _advance(3, 4);
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.supportedInterfaces[type(IStaticsPositionPortfolio).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsMorpho).interfaceId] = true;
    }

    function _advance(uint8 expected, uint8 next) private {
        PhaseStorage storage ps = phaseStorage();
        if (ps.activePhase != expected) revert UnexpectedDeploymentPhase(expected, ps.activePhase);
        ps.activePhase = next;
        emit DeploymentPhaseActivated(next);
    }
}
