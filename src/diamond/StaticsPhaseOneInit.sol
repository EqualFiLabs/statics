// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";

import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibDeploymentPhases} from "../libraries/LibDeploymentPhases.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibGaugeRouting} from "../libraries/LibGaugeRouting.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {LibRangeGauge} from "../libraries/LibRangeGauge.sol";
import {LibPosition} from "../position/LibPosition.sol";

/// @notice Constructor-only initializer for the Phase 1 DEX and global staking selector surface.
contract StaticsPhaseOneInit is ERC721Upgradeable {
    struct InitArgs {
        address guardian;
        address treasury;
        address stakingToken;
        uint256 positionCreationFeeAmount;
        uint256 poolCreationFeeAmount;
        uint16 weeklyGaugeReleaseBps;
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
        LibRangeGauge.initializeGlobalConfig();
        LibGaugeRouting.initialize(args.weeklyGaugeReleaseBps);
        LibRangeGauge.setRewardAssetAllowed(args.stakingToken, true);

        LibDeploymentPhases.initializePhaseOneInterfaces();

        LibGovernance.governanceStorage().guardian = args.guardian;
        LibBasket.basketStorage().treasury = args.treasury;
        LibProtocolPools.protocolPoolStorage().poolCreationFeeAmount = args.poolCreationFeeAmount;
    }
}
