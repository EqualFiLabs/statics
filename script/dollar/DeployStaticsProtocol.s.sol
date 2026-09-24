// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {DiamondCutFacet} from "../../src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/facets/OwnershipFacet.sol";
import {GovernanceFacet} from "../../src/facets/GovernanceFacet.sol";
import {BasketCreationFacet} from "../../src/facets/BasketCreationFacet.sol";
import {BasketMintFacet} from "../../src/facets/BasketMintFacet.sol";
import {BasketRedemptionFacet} from "../../src/facets/BasketRedemptionFacet.sol";
import {BasketViewFacet} from "../../src/facets/BasketViewFacet.sol";
import {BasketCollateralFacet} from "../../src/facets/BasketCollateralFacet.sol";
import {BasketRewardsFacet} from "../../src/facets/BasketRewardsFacet.sol";
import {GlobalRewardsFacet} from "../../src/facets/GlobalRewardsFacet.sol";
import {ProtocolPoolCreationFacet} from "../../src/facets/ProtocolPoolCreationFacet.sol";
import {ProtocolPoolAdminFacet} from "../../src/facets/ProtocolPoolAdminFacet.sol";
import {ProtocolPoolViewFacet} from "../../src/facets/ProtocolPoolViewFacet.sol";
import {ProtocolRevenueFacet} from "../../src/facets/ProtocolRevenueFacet.sol";
import {RewardPolicyFacet} from "../../src/facets/RewardPolicyFacet.sol";
import {RangeGaugeFacet} from "../../src/facets/RangeGaugeFacet.sol";
import {RangeGaugePositionFacet} from "../../src/facets/RangeGaugePositionFacet.sol";
import {RangeGaugeLivenessFacet} from "../../src/facets/RangeGaugeLivenessFacet.sol";
import {RangeGaugeViewFacet} from "../../src/facets/RangeGaugeViewFacet.sol";
import {RangeGaugeCallbackFacet} from "../../src/facets/RangeGaugeCallbackFacet.sol";
import {PermissionedPoolCreationFacet} from "../../src/facets/PermissionedPoolCreationFacet.sol";
import {PermissionedPoolAdminFacet} from "../../src/facets/PermissionedPoolAdminFacet.sol";
import {PermissionedPoolViewFacet} from "../../src/facets/PermissionedPoolViewFacet.sol";
import {BasketAdminFacet} from "../../src/facets/BasketAdminFacet.sol";
import {BasketLiquidityFacet} from "../../src/facets/BasketLiquidityFacet.sol";
import {BasketLiquidityLifecycleFacet} from "../../src/facets/BasketLiquidityLifecycleFacet.sol";
import {BorrowLiquidityFacet} from "../../src/facets/BorrowLiquidityFacet.sol";
import {LendingFacet} from "../../src/facets/LendingFacet.sol";
import {FlashLoanFacet} from "../../src/facets/FlashLoanFacet.sol";
import {CustodyFacet} from "../../src/facets/CustodyFacet.sol";
import {GenesisNFTFacet} from "../../src/facets/GenesisNFTFacet.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {StaticsDiamond} from "../../src/diamond/StaticsDiamond.sol";
import {StaticsInterfaceInit} from "../../src/diamond/StaticsInterfaceInit.sol";
import {StaticsPhaseOneInit} from "../../src/diamond/StaticsPhaseOneInit.sol";
import {StaticsProtocolInit} from "../../src/diamond/StaticsProtocolInit.sol";
import {FeeRouterFacet} from "../../src/dollar/periphery/facets/FeeRouterFacet.sol";
import {PairingVaultFacet} from "../../src/dollar/periphery/facets/PairingVaultFacet.sol";
import {SeriesMigrationFacet} from "../../src/dollar/periphery/facets/SeriesMigrationFacet.sol";
import {StakingFacet} from "../../src/dollar/periphery/facets/StakingFacet.sol";
import {StaticsDollarGatewayFacet} from "../../src/dollar/periphery/facets/StaticsDollarGatewayFacet.sol";
import {LibPeriphery} from "../../src/dollar/periphery/libraries/LibPeriphery.sol";
import {PositionNFTFacet} from "../../src/position/PositionNFTFacet.sol";
import {PositionPortfolioFacet} from "../../src/facets/PositionPortfolioFacet.sol";
import {MorphoFacet} from "../../src/facets/MorphoFacet.sol";
import {MorphoRecoveryFacet} from "../../src/facets/MorphoRecoveryFacet.sol";
import {MorphoSettlementFacet} from "../../src/facets/MorphoSettlementFacet.sol";
import {MorphoAdminFacet} from "../../src/facets/MorphoAdminFacet.sol";
import {MorphoViewFacet} from "../../src/facets/MorphoViewFacet.sol";
import {StaticsProtocolParts, StaticsProtocolPlan} from "../libraries/StaticsProtocolPlan.sol";

abstract contract DeployStaticsProtocol {
    struct ProtocolDeploymentConfig {
        address pool;
        address weth;
        address finalOwner;
        address guardian;
        address treasury;
        address stakingToken;
        uint256 creationFeeAmount;
        uint256 positionCreationFeeAmount;
        uint256 poolCreationFeeAmount;
        uint256 singleAssetFlashFeeBps;
    }

    struct PhaseOneProtocolDeploymentConfig {
        address weth;
        address finalOwner;
        address guardian;
        address treasury;
        address stakingToken;
        uint256 positionCreationFeeAmount;
        uint256 poolCreationFeeAmount;
    }

    function _deployStaticsProtocol(ProtocolDeploymentConfig memory config)
        internal
        returns (address diamond, address positionNFT)
    {
        StaticsProtocolParts memory parts = _deployProtocolParts();
        IDiamondCut.FacetCut[] memory cut = _protocolCut(parts);
        LibPeriphery.InitArgs memory dollarArgs = LibPeriphery.InitArgs({
            pool: config.pool,
            weth: config.weth,
            baseBps: 7_000,
            insuranceBps: 3_000,
            redemptionFeeBps: 50,
            redemptionSupplierShareBps: 8_000
        });
        StaticsProtocolInit.UnifiedInitArgs memory args = StaticsProtocolInit.UnifiedInitArgs({
            guardian: config.guardian,
            treasury: config.treasury,
            stakingToken: config.stakingToken,
            creationFeeAmount: config.creationFeeAmount,
            positionCreationFeeAmount: config.positionCreationFeeAmount,
            poolCreationFeeAmount: config.poolCreationFeeAmount,
            singleAssetFlashFeeBps: config.singleAssetFlashFeeBps,
            dollar: dollarArgs
        });
        StaticsDiamond deployedDiamond = new StaticsDiamond(
            config.finalOwner, config.weth, parts.init, abi.encodeCall(StaticsProtocolInit.genesis, (cut, args))
        );
        return (address(deployedDiamond), address(deployedDiamond));
    }

    function _deployPhaseOneStaticsProtocol(PhaseOneProtocolDeploymentConfig memory config)
        internal
        returns (address diamond, address positionNFT)
    {
        StaticsProtocolParts memory parts = _deployPhaseOneProtocolParts();
        parts.init = address(new StaticsPhaseOneInit());
        IDiamondCut.FacetCut[] memory cut = _phaseOneProtocolCut(parts);
        StaticsDiamond deployedDiamond = new StaticsDiamond(
            config.finalOwner,
            config.weth,
            parts.init,
            abi.encodeCall(
                StaticsPhaseOneInit.genesis,
                (
                    cut,
                    StaticsPhaseOneInit.InitArgs({
                        guardian: config.guardian,
                        treasury: config.treasury,
                        stakingToken: config.stakingToken,
                        positionCreationFeeAmount: config.positionCreationFeeAmount,
                        poolCreationFeeAmount: config.poolCreationFeeAmount
                    })
                )
            )
        );
        return (address(deployedDiamond), address(deployedDiamond));
    }

    function _deployProtocolParts() internal returns (StaticsProtocolParts memory parts) {
        parts = _deployPhaseOneProtocolParts();
        parts.init = address(new StaticsProtocolInit());
        parts = _deployPhaseTwoProtocolParts(parts);
        parts = _deployPhaseThreeProtocolParts(parts);
        parts = _deployPhaseFourProtocolParts(parts);
    }

    function _deployPhaseTwoProtocolParts(StaticsProtocolParts memory parts)
        internal
        returns (StaticsProtocolParts memory)
    {
        parts.positionPortfolio = address(new PositionPortfolioFacet());
        parts.basketCreation = address(new BasketCreationFacet());
        parts.basketMint = address(new BasketMintFacet());
        parts.basketRedemption = address(new BasketRedemptionFacet());
        parts.basketView = address(new BasketViewFacet());
        parts.basketCollateral = address(new BasketCollateralFacet());
        parts.basketRewards = address(new BasketRewardsFacet());
        parts.basketLiquidityLifecycle = address(new BasketLiquidityLifecycleFacet());
        parts.lending = address(new LendingFacet());
        parts.flashLoan = address(new FlashLoanFacet());
        parts.genesisNFT = address(new GenesisNFTFacet());
        parts.borrowLiquidity = address(new BorrowLiquidityFacet());
        return parts;
    }

    function _deployPhaseThreeProtocolParts(StaticsProtocolParts memory parts)
        internal
        returns (StaticsProtocolParts memory)
    {
        parts.dollarStaking = address(new StakingFacet());
        parts.seriesMigration = address(new SeriesMigrationFacet());
        parts.feeRouter = address(new FeeRouterFacet());
        parts.pairingVault = address(new PairingVaultFacet());
        parts.dollarGateway = address(new StaticsDollarGatewayFacet());
        return parts;
    }

    function _deployPhaseFourProtocolParts(StaticsProtocolParts memory parts)
        internal
        returns (StaticsProtocolParts memory)
    {
        parts.morphoActions = address(new MorphoFacet());
        parts.morphoRecovery = address(new MorphoRecoveryFacet());
        parts.morphoSettlement = address(new MorphoSettlementFacet());
        parts.morphoAdmin = address(new MorphoAdminFacet());
        parts.morphoView = address(new MorphoViewFacet());
        return parts;
    }

    function _deployPhaseOneProtocolParts() internal returns (StaticsProtocolParts memory parts) {
        parts.cut = address(new DiamondCutFacet());
        parts.loupe = address(new DiamondLoupeFacet());
        parts.ownership = address(new OwnershipFacet());
        parts.governance = address(new GovernanceFacet());
        parts.position = address(new PositionNFTFacet());
        parts.custody = address(new CustodyFacet());
        parts.globalRewards = address(new GlobalRewardsFacet());
        parts.basketAdmin = address(new BasketAdminFacet());
        parts.basketLiquidity = address(new BasketLiquidityFacet());
        parts.interfaceInit = address(new StaticsInterfaceInit());
        parts.protocolPoolCreation = address(new ProtocolPoolCreationFacet());
        parts.protocolPoolAdmin = address(new ProtocolPoolAdminFacet());
        parts.protocolPoolView = address(new ProtocolPoolViewFacet());
        parts.protocolRevenue = address(new ProtocolRevenueFacet());
        parts.rewardPolicy = address(new RewardPolicyFacet());
        parts.permissionedPoolCreation = address(new PermissionedPoolCreationFacet());
        parts.permissionedPoolAdmin = address(new PermissionedPoolAdminFacet());
        parts.permissionedPoolView = address(new PermissionedPoolViewFacet());
        parts.rangeGauge = address(new RangeGaugeFacet());
        parts.rangeGaugePosition = address(new RangeGaugePositionFacet());
        parts.rangeGaugeLiveness = address(new RangeGaugeLivenessFacet());
        parts.rangeGaugeView = address(new RangeGaugeViewFacet());
        parts.rangeGaugeCallback = address(new RangeGaugeCallbackFacet());
    }

    function _phaseOneProtocolCut(StaticsProtocolParts memory parts)
        internal
        pure
        returns (IDiamondCut.FacetCut[] memory cut)
    {
        return StaticsProtocolPlan.phaseOne(parts);
    }

    function _phaseTwoProtocolCut(StaticsProtocolParts memory parts)
        internal
        pure
        returns (IDiamondCut.FacetCut[] memory cut)
    {
        return StaticsProtocolPlan.phaseTwo(parts);
    }

    function _phaseThreeProtocolCut(StaticsProtocolParts memory parts)
        internal
        pure
        returns (IDiamondCut.FacetCut[] memory cut)
    {
        return StaticsProtocolPlan.phaseThree(parts);
    }

    function _phaseFourProtocolCut(StaticsProtocolParts memory parts)
        internal
        pure
        returns (IDiamondCut.FacetCut[] memory cut)
    {
        return StaticsProtocolPlan.phaseFour(parts);
    }

    function _protocolCut(StaticsProtocolParts memory parts) internal pure returns (IDiamondCut.FacetCut[] memory cut) {
        return StaticsProtocolPlan.cumulative(parts, 4);
    }
}
