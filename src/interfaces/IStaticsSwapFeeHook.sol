// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IStaticsSwapFeeHook {
    struct PoolRegistration {
        Currency currency0;
        Currency currency1;
        bool registered;
    }

    struct OracleStateView {
        uint40 initializedAt;
        uint40 lastCheckpointAt;
        uint40 latestObservationAt;
        int24 lastTick;
        int56 tickCumulative;
        uint8 observationIndex;
        uint8 observationCardinality;
    }

    event PoolRegistered(PoolId indexed poolId, Currency indexed currency0, Currency indexed currency1);
    event SwapFeeAccrued(
        PoolId indexed poolId,
        Currency indexed currency,
        uint256 realizedAmount,
        uint256 chargedAmount,
        uint256 receivedAmount
    );
    event PoolFeesWithdrawn(
        PoolId indexed poolId,
        Currency indexed currency,
        uint256 spentAmount,
        uint256 receivedAmount,
        uint256 remainingAmount
    );
    event TickObservationRecorded(
        PoolId indexed poolId, uint40 indexed timestamp, int24 tick, int56 tickCumulative, uint8 cardinality
    );

    function staticsDiamond() external view returns (address);
    function hookFeeBps() external view returns (uint16);
    function registerPool(PoolKey calldata key) external returns (PoolId poolId);
    function poolRegistration(PoolId poolId) external view returns (PoolRegistration memory registration);
    function accruedFees(PoolId poolId, Currency currency) external view returns (uint256 amount);
    function totalLiability(Currency currency) external view returns (uint256 amount);
    function checkpoint(PoolKey calldata key) external returns (bool observationStored);
    function oracleState(PoolId poolId) external view returns (OracleStateView memory state);
    function observationAt(PoolId poolId, uint8 index) external view returns (uint40 timestamp, int56 tickCumulative);
    function consult(PoolId poolId, uint32 window)
        external
        view
        returns (int24 referenceTick, int24 spotTick, uint40 oldestObservationAt);
    function withdrawPoolFees(PoolId poolId)
        external
        returns (uint256 spent0, uint256 received0, uint256 spent1, uint256 received1);
}
