// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsGenesis} from "../interfaces/IStaticsGenesis.sol";
import {IStaticsGenesisStaking} from "../interfaces/IStaticsGenesisStaking.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGenesis} from "../libraries/LibGenesis.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";

interface IStaticsBurnable {
    function burnFrom(address account, uint256 amount) external;
}

contract GenesisFacet is IStaticsGenesisStaking, ReentrancyGuard {
    error GenesisOwnerMismatch(uint256 genesisId, address expected, address actual);
    error PositionOwnerMismatch(uint256 positionId, address expected, address actual);
    error UnauthorizedGenesisCollection(address caller);
    error ActivationBurnExceedsMaximum(uint256 required, uint256 maximum);

    function linkGenesis(uint256 genesisId, uint256 positionId) external nonReentrant {
        LibGenesis.GenesisStorage storage gs = LibGenesis.genesisStorage();
        address positionOwner = IERC721(address(this)).ownerOf(positionId);
        if (positionOwner != msg.sender) revert PositionOwnerMismatch(positionId, msg.sender, positionOwner);
        address genesisOwner = IERC721(gs.collection).ownerOf(genesisId);
        if (genesisOwner != msg.sender) revert GenesisOwnerMismatch(genesisId, msg.sender, genesisOwner);

        uint16 multiplierBps = LibGenesis.multiplierForTier(gs.tiers[genesisId]);
        if (multiplierBps != LibGenesis.BASE_MULTIPLIER_BPS) {
            LibGlobalRewards.transitionPositionWeight(positionId, LibGenesis.BASE_MULTIPLIER_BPS, multiplierBps);
        }
        LibGenesis.link(genesisId, positionId);
        emit GenesisLinked(genesisId, positionId, msg.sender);
    }

    function unlinkGenesis(uint256 genesisId) external nonReentrant {
        LibGenesis.GenesisStorage storage gs = LibGenesis.genesisStorage();
        uint256 positionId = gs.linkedPosition[genesisId];
        if (positionId == 0) revert LibGenesis.GenesisNotLinked(genesisId);
        address positionOwner = IERC721(address(this)).ownerOf(positionId);
        if (positionOwner != msg.sender) revert PositionOwnerMismatch(positionId, msg.sender, positionOwner);
        uint16 previousMultiplier = LibGenesis.multiplierForTier(gs.tiers[genesisId]);
        if (previousMultiplier != LibGenesis.BASE_MULTIPLIER_BPS) {
            LibGlobalRewards.transitionPositionWeight(positionId, previousMultiplier, LibGenesis.BASE_MULTIPLIER_BPS);
        }
        LibGenesis.unlink(genesisId);
        emit GenesisUnlinked(genesisId, positionId, msg.sender);
    }

    function activateGenesis(uint256 genesisId, uint8 targetTier, uint256 maxBurn) external nonReentrant {
        LibGenesis.GenesisStorage storage gs = LibGenesis.genesisStorage();
        address genesisOwner = IERC721(gs.collection).ownerOf(genesisId);
        if (genesisOwner != msg.sender) revert GenesisOwnerMismatch(genesisId, msg.sender, genesisOwner);
        uint8 previousTier = gs.tiers[genesisId];
        uint256 burnAmount = LibGenesis.cumulativeActivationCost(previousTier, targetTier);
        if (burnAmount > maxBurn) revert ActivationBurnExceedsMaximum(burnAmount, maxBurn);

        uint256 positionId = gs.linkedPosition[genesisId];
        if (positionId != 0) {
            LibGlobalRewards.transitionPositionWeight(
                positionId, LibGenesis.multiplierForTier(previousTier), LibGenesis.multiplierForTier(targetTier)
            );
        }
        gs.tiers[genesisId] = targetTier;
        IStaticsBurnable(gs.staticsToken).burnFrom(msg.sender, burnAmount);
        IStaticsGenesis(gs.collection).refreshMetadata(genesisId);
        emit GenesisActivated(genesisId, previousTier, targetTier, burnAmount, LibGenesis.multiplierForTier(targetTier));
    }

    function setGenesisActivationCost(uint8 tier, uint256 cost) external {
        LibDiamond.enforceIsContractOwner();
        uint256 previousCost = LibGenesis.setActivationCost(tier, cost);
        emit GenesisActivationCostSet(tier, previousCost, cost);
    }

    function onGenesisTransfer(uint256 genesisId, address previousOwner, address newOwner) external {
        LibGenesis.GenesisStorage storage gs = LibGenesis.genesisStorage();
        if (msg.sender != gs.collection) revert UnauthorizedGenesisCollection(msg.sender);
        uint256 positionId = gs.linkedPosition[genesisId];
        if (positionId != 0) revert LibGenesis.GenesisLinkedOnTransfer(genesisId, positionId);
        delete gs.tiers[genesisId];
        emit GenesisActivationReset(genesisId, previousOwner, newOwner);
    }

    function genesisCollection() external view returns (address) {
        return LibGenesis.genesisStorage().collection;
    }

    function genesisState(uint256 genesisId) external view returns (GenesisState memory state) {
        LibGenesis.GenesisStorage storage gs = LibGenesis.genesisStorage();
        uint8 tier = gs.tiers[genesisId];
        state = GenesisState({
            tier: tier,
            multiplierBps: LibGenesis.multiplierForTier(tier),
            linkedPositionId: gs.linkedPosition[genesisId]
        });
    }

    function genesisTier(uint256 genesisId) external view returns (uint8) {
        return LibGenesis.genesisStorage().tiers[genesisId];
    }

    function genesisActivationCost(uint8 tier) external view returns (uint256) {
        return LibGenesis.genesisStorage().activationCosts[tier];
    }

    function linkedPosition(uint256 genesisId) external view returns (uint256) {
        return LibGenesis.genesisStorage().linkedPosition[genesisId];
    }

    function linkedGenesis(uint256 positionId) external view returns (uint256) {
        return LibGenesis.genesisStorage().linkedGenesis[positionId];
    }

    function positionRewardMultiplierBps(uint256 positionId) external view returns (uint16) {
        return LibGenesis.positionMultiplier(positionId);
    }
}
