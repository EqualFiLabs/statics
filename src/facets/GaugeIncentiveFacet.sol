// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsGaugeIncentives} from "../interfaces/IStaticsGaugeIncentives.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGaugeEpoch} from "../libraries/LibGaugeEpoch.sol";
import {LibGaugeReserve} from "../libraries/LibGaugeReserve.sol";
import {LibGaugeRouting} from "../libraries/LibGaugeRouting.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibMorpho} from "../libraries/LibMorpho.sol";
import {LibPosition} from "../position/LibPosition.sol";
import {LibRangeGauge} from "../libraries/LibRangeGauge.sol";

contract GaugeIncentiveFacet is ReentrancyGuard {
    function fundGaugeReserve(uint256 amount) external nonReentrant returns (uint256 received) {
        if (amount == 0) revert IStaticsGaugeIncentives.InvalidGaugeFundingAmount();
        uint64 currentEpoch = LibGaugeEpoch.epochAt(block.timestamp);
        address statics = LibRangeGauge.staticsToken();
        received = LibCustody.pullAndReserve(LibCustody.gaugeReserveAccount(), statics, msg.sender, amount);
        if (received != amount) revert IStaticsGaugeIncentives.IncompatibleGaugeTokenTransfer(amount, received);
        LibGaugeReserve.defer(received, currentEpoch);
        emit IStaticsGaugeIncentives.GaugeReserveFunded(msg.sender, received, currentEpoch + 1);
    }

    function setGaugeAllocations(uint256 positionId, PoolId[] calldata poolIds, uint256[] calldata amounts)
        external
        nonReentrant
    {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibMorpho.syncIfInitialized(positionId, msg.sender);
        LibGaugeRouting.checkpointEpoch(uint40(block.timestamp));
        uint256 staked = LibGlobalRewards.rewardStorage().positions[positionId].balance;
        (uint64 effectiveEpoch, uint256 totalAllocated) =
            LibGaugeRouting.setAllocations(positionId, poolIds, amounts, staked);
        emit IStaticsGaugeIncentives.PositionGaugeAllocationsScheduled(positionId, effectiveEpoch, totalAllocated);
    }

    function checkpointGaugeEpoch()
        external
        nonReentrant
        returns (uint64 epoch, uint256 committedBudget, bool finalized)
    {
        (epoch, committedBudget, finalized) = LibGaugeRouting.checkpointEpoch(uint40(block.timestamp));
        if (!finalized) return (epoch, committedBudget, false);
        LibGaugeRouting.EpochState storage state = LibGaugeRouting.routingStorage().epochs[epoch];
        emit IStaticsGaugeIncentives.GaugeEpochFinalized(
            epoch,
            state.activatedAt,
            state.finish,
            state.releaseBps,
            state.nominalBudget,
            state.committedBudget,
            state.totalWeight,
            state.winnerCount
        );
        for (uint256 i; i < state.winnerCount; ++i) {
            emit IStaticsGaugeIncentives.ProtocolGaugeRewardCommitted(
                epoch, state.pools[i], state.weights[i], state.budgets[i]
            );
        }
    }

    function refreshGaugePoolWeight(PoolId poolId) external returns (uint256 removedWeight) {
        bytes32 previous;
        bytes32 current;
        (removedWeight, previous, current) = LibGaugeRouting.refreshPoolWeight(poolId);
        emit IStaticsGaugeIncentives.GaugePoolWeightRefreshed(poolId, previous, current, removedWeight);
    }

    function scheduleGaugeReleaseBps(uint16 releaseBps) external {
        LibDiamond.enforceIsContractOwner();
        uint64 effectiveEpoch = LibGaugeEpoch.epochAt(block.timestamp) + 1;
        LibGaugeReserve.scheduleReleaseBps(releaseBps, effectiveEpoch);
        emit IStaticsGaugeIncentives.GaugeReleaseBpsScheduled(releaseBps, effectiveEpoch);
    }
}
