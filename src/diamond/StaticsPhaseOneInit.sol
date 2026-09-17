// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";

import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {IERC5192} from "../interfaces/IERC5192.sol";
import {IModularPositionNFT} from "../interfaces/IModularPositionNFT.sol";
import {IPositionOwnerIndex} from "../interfaces/IPositionOwnerIndex.sol";
import {IStaticsGlobalRewards} from "../interfaces/IStaticsGlobalRewards.sol";
import {IStaticsPosition, IStaticsPositionFees} from "../interfaces/IStaticsPosition.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {LibPosition} from "../position/LibPosition.sol";

/// @notice Constructor-only initializer for the Phase 1 DEX and global staking selector surface.
contract StaticsPhaseOneInit is ERC721Upgradeable {
    struct InitArgs {
        address guardian;
        address treasury;
        address stakingToken;
        uint256 positionCreationFeeAmount;
        uint256 poolCreationFeeAmount;
    }

    error InvalidGuardian();
    error InvalidTreasury();

    function genesis(IDiamondCut.FacetCut[] calldata cut, InitArgs calldata args) external initializer {
        if (args.guardian == address(0)) revert InvalidGuardian();
        if (args.treasury == address(0) || args.treasury == address(this)) revert InvalidTreasury();

        LibDiamond.diamondCut(cut, address(0), "");
        __ERC721_init("Statics Position", "STXPOS");
        LibPosition.initialize(args.positionCreationFeeAmount);
        LibGlobalRewards.initialize(args.stakingToken);

        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.supportedInterfaces[type(IStaticsGlobalRewards).interfaceId] = true;
        ds.supportedInterfaces[type(IERC721).interfaceId] = true;
        ds.supportedInterfaces[type(IERC721Metadata).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsPosition).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsPositionFees).interfaceId] = true;
        ds.supportedInterfaces[type(IModularPositionNFT).interfaceId] = true;
        ds.supportedInterfaces[type(IPositionOwnerIndex).interfaceId] = true;
        ds.supportedInterfaces[type(IERC5192).interfaceId] = true;

        LibGovernance.governanceStorage().guardian = args.guardian;
        LibBasket.basketStorage().treasury = args.treasury;
        LibProtocolPools.protocolPoolStorage().poolCreationFeeAmount = args.poolCreationFeeAmount;
    }
}
