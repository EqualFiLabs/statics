// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibSwapRewardSources} from "../libraries/LibSwapRewardSources.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibPoolRewards} from "../libraries/LibPoolRewards.sol";
import {LibCustody} from "../libraries/LibCustody.sol";

/// @notice Funding capability entered only through guarded Diamond reward actions.
contract SwapRewardFundingFacet {
    error LiquidityIntegrationNotInstalled();

    function fundPublicSwapRewards(address asset, uint256 amount) external returns (uint256 funded) {
        require(msg.sender == address(this), "Statics: only self");
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (!ls.integrationInstalled) revert LiquidityIntegrationNotInstalled();
        LibSwapRewardSources.SourceQueue storage queue = LibSwapRewardSources.sourceStorage().sources[asset];
        uint256 legacy = LibGlobalRewards.unfundedSwapRewards(asset) - queue.total;
        if (legacy != 0) {
            uint256 requested = legacy < amount ? legacy : amount;
            LibPoolRewards.settleStaker(asset, requested);
            _fundSwapReward(asset, requested);
            funded = requested;
        }
        for (
            uint256 i;
            funded < amount && queue.head < queue.entries.length && i < LibSwapRewardSources.MAX_SETTLEMENT_SOURCES;
            ++i
        ) {
            LibSwapRewardSources.Source memory source = queue.entries[queue.head];
            PoolId poolId = queue.poolIds[queue.head];
            bytes32 id = LibSwapRewardSources.sourceId(source.hook, poolId, source.currency);
            uint256 remaining = amount - funded;
            uint256 pending = queue.pending[id];
            uint256 requested = pending < remaining ? pending : remaining;
            LibSwapRewardSources.consume(queue, source, poolId, id, requested);
            LibPoolRewards.settleSource(source.hook, poolId, source.currency, requested);
            _fundSwapReward(asset, requested);
            funded += requested;
        }
    }

    function _fundSwapReward(address asset, uint256 amount) private {
        LibCustody.reserve(LibCustody.feeAccount(), asset, amount);
        LibGlobalRewards.fundCrystallizedSwapFee(asset, amount);
    }
}
