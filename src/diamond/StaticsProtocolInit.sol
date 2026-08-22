// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../interfaces/IDiamondLoupe.sol";
import {IERC173} from "../interfaces/IERC173.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {IStaticsBasketAdmin} from "../interfaces/IStaticsBasketAdmin.sol";
import {IStaticsBasketCollateral} from "../interfaces/IStaticsBasketCollateral.sol";
import {IStaticsBasketRewards} from "../interfaces/IStaticsBasketRewards.sol";
import {IStaticsGlobalRewards} from "../interfaces/IStaticsGlobalRewards.sol";
import {IStaticsBasketLiquidity} from "../interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsBorrowLiquidity} from "../interfaces/IStaticsBorrowLiquidity.sol";
import {IStaticsCustody} from "../interfaces/IStaticsCustody.sol";
import {IStaticsFlashLoan} from "../interfaces/IStaticsFlashLoan.sol";
import {IStaticsGovernance} from "../interfaces/IStaticsGovernance.sol";
import {IStaticsLending} from "../interfaces/IStaticsLending.sol";
import {IStaticsLiquidityRewards} from "../interfaces/IStaticsLiquidityRewards.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IStaticsPosition, IStaticsPositionFees} from "../interfaces/IStaticsPosition.sol";
import {IModularPositionNFT} from "../interfaces/IModularPositionNFT.sol";
import {IPositionOwnerIndex} from "../interfaces/IPositionOwnerIndex.sol";
import {IStaticsPositionPortfolio} from "../interfaces/IStaticsPositionPortfolio.sol";
import {IStaticsDollarRiskLiquidity} from "../dollar/interfaces/IStaticsDollarRiskLiquidity.sol";
import {IStaticsDollarRiskIncentives} from "../dollar/interfaces/IStaticsDollarRiskIncentives.sol";
import {IStaticsDollarGateway} from "../dollar/interfaces/IStaticsDollarGateway.sol";
import {LibPeriphery} from "../dollar/periphery/libraries/LibPeriphery.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibPosition} from "../position/LibPosition.sol";

contract StaticsProtocolInit is ERC721Upgradeable {
    struct UnifiedInitArgs {
        address guardian;
        address treasury;
        address stakingToken;
        uint256 creationFeeAmount;
        uint256 positionCreationFeeAmount;
        LibPeriphery.InitArgs dollar;
    }

    error AlreadyInitialized();
    error InvalidGuardian();
    error InvalidTreasury();

    function initialize(
        address guardian,
        address treasury,
        address stakingToken,
        uint256 creationFeeAmount,
        uint256 positionCreationFeeAmount
    ) external initializer {
        _initializeProtocol(guardian, treasury, stakingToken, creationFeeAmount, positionCreationFeeAmount);
    }

    function initializeUnified(UnifiedInitArgs calldata args) external initializer {
        _initializeUnified(args);
    }

    /// @dev Applies the genesis facet cut before scalar protocol initialization inside the
    /// Diamond's constructor, keeping nested facet arrays out of diamond constructor arguments.
    function genesisInitialize(
        IDiamondCut.FacetCut[] calldata cut,
        address guardian,
        address treasury,
        address stakingToken,
        uint256 creationFeeAmount,
        uint256 positionCreationFeeAmount
    ) external initializer {
        LibDiamond.diamondCut(cut, address(0), "");
        _initializeProtocol(guardian, treasury, stakingToken, creationFeeAmount, positionCreationFeeAmount);
    }

    /// @dev Applies the genesis facet cut before unified initialization inside the Diamond's
    /// constructor, keeping nested facet arrays out of diamond constructor arguments.
    function genesis(IDiamondCut.FacetCut[] calldata cut, UnifiedInitArgs calldata args) external initializer {
        LibDiamond.diamondCut(cut, address(0), "");
        _initializeUnified(args);
    }

    function _initializeUnified(UnifiedInitArgs calldata args) private {
        _initializeProtocol(
            args.guardian, args.treasury, args.stakingToken, args.creationFeeAmount, args.positionCreationFeeAmount
        );
        LibPeriphery.initialize(args.dollar);
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.supportedInterfaces[type(IERC1155Receiver).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsDollarRiskLiquidity).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsDollarRiskIncentives).interfaceId] = true;
    }

    function _initializeProtocol(
        address guardian,
        address treasury,
        address stakingToken,
        uint256 creationFeeAmount,
        uint256 positionCreationFeeAmount
    ) private {
        if (guardian == address(0)) revert InvalidGuardian();
        if (treasury == address(0) || treasury == address(this)) revert InvalidTreasury();
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        if (ds.supportedInterfaces[type(IERC165).interfaceId]) revert AlreadyInitialized();

        __ERC721_init("Statics Position", "STXPOS");
        LibPosition.initialize(positionCreationFeeAmount);
        LibGlobalRewards.initialize(stakingToken);

        ds.supportedInterfaces[type(IERC165).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondCut).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondLoupe).interfaceId] = true;
        ds.supportedInterfaces[type(IERC173).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsGovernance).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsBasket).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsBasketAdmin).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsBasketCollateral).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsBasketRewards).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsGlobalRewards).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsBasketLiquidity).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsBorrowLiquidity).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsCustody).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsLending).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsFlashLoan).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsLiquidityRewards).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsProtocolPools).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsDollarGateway).interfaceId] = true;
        ds.supportedInterfaces[type(IERC721).interfaceId] = true;
        ds.supportedInterfaces[type(IERC721Metadata).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsPosition).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsPositionFees).interfaceId] = true;
        ds.supportedInterfaces[type(IModularPositionNFT).interfaceId] = true;
        ds.supportedInterfaces[type(IPositionOwnerIndex).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsPositionPortfolio).interfaceId] = true;

        LibGovernance.governanceStorage().guardian = guardian;
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        bs.treasury = treasury;
        bs.creationFeeAmount = creationFeeAmount;
    }
}
