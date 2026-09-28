// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.26 <0.9.0;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IVenueController {
    enum TradingStatus {
        Active,
        Halted
    }

    function operator() external view returns (address);
    function permissions(PoolId poolId, address account) external view returns (uint256 flags);
    function assetStatus(address asset) external view returns (TradingStatus status);
    function poolStatus(PoolId poolId) external view returns (TradingStatus status);
}
