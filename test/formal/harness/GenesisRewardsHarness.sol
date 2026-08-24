// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LibGenesisIntegration} from "../../../src/libraries/LibGenesisIntegration.sol";
import {LibGenesisRewards} from "../../../src/libraries/LibGenesisRewards.sol";

contract GenesisRewardsHarness {
    function initializeHarness(
        address genesis,
        address registry,
        address feeReceiver,
        address vault,
        address statics,
        address numeraire,
        uint256 rewardShareBps
    ) external {
        if (rewardShareBps > type(uint16).max) revert();
        LibGenesisIntegration.GenesisStorage storage gs = LibGenesisIntegration.genesisStorage();
        gs.genesis = genesis;
        gs.vault = vault;
        gs.activationRegistry = registry;
        gs.feeReceiver = feeReceiver;
        gs.statics = statics;
        gs.numeraire = numeraire;
        gs.genesisRewardShareBps = uint16(rewardShareBps);
        gs.initialized = true;
    }

    function seedRegistered(uint256 genesisId, uint256 weight) external {
        LibGenesisIntegration.GenesisStorage storage gs = LibGenesisIntegration.genesisStorage();
        gs.registered[genesisId] = true;
        gs.effectiveWeight[genesisId] = weight;
        gs.totalWeight += weight;
    }

    function setIndex(address asset, uint256 indexRay) external {
        LibGenesisIntegration.genesisStorage().rewardBooks[asset].indexRay = indexRay;
    }

    function registerGenesis(uint256 genesisId) external {
        LibGenesisRewards.register(genesisId);
    }

    function allocate(address asset, uint256 amount) external {
        LibGenesisRewards.allocate(LibGenesisIntegration.genesisStorage(), asset, amount);
    }

    function indexRecovery(uint256 amount) external {
        LibGenesisRewards.increaseRecoveryIndex(LibGenesisIntegration.genesisStorage(), amount);
    }

    function pending(uint256 genesisId, address asset) external view returns (uint256) {
        return LibGenesisRewards.pending(genesisId, asset);
    }

    function registration(uint256 genesisId)
        external
        view
        returns (
            bool registered,
            uint256 weight,
            uint256 totalWeight,
            uint256 staticsCheckpoint,
            uint256 numeraireCheckpoint
        )
    {
        LibGenesisIntegration.GenesisStorage storage gs = LibGenesisIntegration.genesisStorage();
        return (
            gs.registered[genesisId],
            gs.effectiveWeight[genesisId],
            gs.totalWeight,
            gs.genesisAssetState[genesisId][gs.statics].checkpointRay,
            gs.genesisAssetState[genesisId][gs.numeraire].checkpointRay
        );
    }

    function book(address asset)
        external
        view
        returns (
            uint256 indexRay,
            uint256 indexRemainder,
            uint256 indexedAmount,
            uint256 crystallizedAmount,
            uint256 totalClaimable,
            uint256 totalClaimed,
            uint256 treasuryClaimable
        )
    {
        LibGenesisIntegration.RewardBook storage stored = LibGenesisIntegration.genesisStorage().rewardBooks[asset];
        return (
            stored.indexRay,
            stored.indexRemainder,
            stored.indexedAmount,
            stored.crystallizedAmount,
            stored.totalClaimable,
            stored.totalClaimed,
            stored.treasuryClaimable
        );
    }
}
