// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Internal callback used by the installed public Statics hook after a protocol-pool swap.
interface IStaticsRangeGaugeCallback {
    function afterProtocolPoolSwap(PoolId poolId) external;
}
