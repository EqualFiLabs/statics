// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsMarketTape} from "../interfaces/IStaticsMarketTape.sol";
import {LibMarketTape} from "../libraries/LibMarketTape.sol";

contract MarketTapeViewFacet is IStaticsMarketTape {
    function canonicalMarketState(PoolId poolId) external view returns (CanonicalMarketState memory state) {
        state = LibMarketTape.marketTapeStorage().canonical[poolId];
        state.tickCumulative =
            LibMarketTape.currentTickCumulative(LibMarketTape.marketTapeStorage().canonical[poolId], block.timestamp);
    }
}
