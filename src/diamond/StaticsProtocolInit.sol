// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {LibPeriphery} from "../dollar/periphery/libraries/LibPeriphery.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibDeploymentPhases} from "../libraries/LibDeploymentPhases.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {LibPosition} from "../position/LibPosition.sol";

contract StaticsProtocolInit is ERC721Upgradeable {
    struct UnifiedInitArgs {
        address guardian;
        address treasury;
        address stakingToken;
        uint256 creationFeeAmount;
        uint256 positionCreationFeeAmount;
        uint256 poolCreationFeeAmount;
        uint256 singleAssetFlashFeeBps;
        LibPeriphery.InitArgs dollar;
    }

    error InvalidGuardian();
    error InvalidTreasury();

    function initialize(
        address guardian,
        address treasury,
        address stakingToken,
        uint256 creationFeeAmount,
        uint256 positionCreationFeeAmount,
        uint256 poolCreationFeeAmount,
        uint256 singleAssetFlashFeeBps
    ) external initializer {
        _initializeProtocol(
            guardian,
            treasury,
            stakingToken,
            creationFeeAmount,
            positionCreationFeeAmount,
            poolCreationFeeAmount,
            singleAssetFlashFeeBps
        );
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
        uint256 positionCreationFeeAmount,
        uint256 poolCreationFeeAmount,
        uint256 singleAssetFlashFeeBps
    ) external initializer {
        LibDiamond.diamondCut(cut, address(0), "");
        _initializeProtocol(
            guardian,
            treasury,
            stakingToken,
            creationFeeAmount,
            positionCreationFeeAmount,
            poolCreationFeeAmount,
            singleAssetFlashFeeBps
        );
    }

    /// @dev Applies the genesis facet cut before unified initialization inside the Diamond's
    /// constructor, keeping nested facet arrays out of diamond constructor arguments.
    function genesis(IDiamondCut.FacetCut[] calldata cut, UnifiedInitArgs calldata args) external initializer {
        LibDiamond.diamondCut(cut, address(0), "");
        _initializeUnified(args);
    }

    function _initializeUnified(UnifiedInitArgs calldata args) private {
        _initializeProtocol(
            args.guardian,
            args.treasury,
            args.stakingToken,
            args.creationFeeAmount,
            args.positionCreationFeeAmount,
            args.poolCreationFeeAmount,
            args.singleAssetFlashFeeBps
        );
        LibDeploymentPhases.initializePhaseThree(args.dollar);
        LibDeploymentPhases.initializePhaseFour();
    }

    function _initializeProtocol(
        address guardian,
        address treasury,
        address stakingToken,
        uint256 creationFeeAmount,
        uint256 positionCreationFeeAmount,
        uint256 poolCreationFeeAmount,
        uint256 singleAssetFlashFeeBps
    ) private {
        if (guardian == address(0)) revert InvalidGuardian();
        if (treasury == address(0) || treasury == address(this)) revert InvalidTreasury();
        __ERC721_init("Statics Position", "STXPOS");
        LibPosition.initialize(positionCreationFeeAmount);
        LibGlobalRewards.initialize(stakingToken);
        LibDeploymentPhases.initializePhaseOneInterfaces();

        LibGovernance.governanceStorage().guardian = guardian;
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        bs.treasury = treasury;
        LibProtocolPools.protocolPoolStorage().poolCreationFeeAmount = poolCreationFeeAmount;
        LibDeploymentPhases.initializePhaseTwo(creationFeeAmount, singleAssetFlashFeeBps);
    }
}
