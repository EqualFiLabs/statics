// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IStaticsRangeGauge} from "../interfaces/IStaticsRangeGauge.sol";
import {IStaticsLiquidityManager} from "../interfaces/IStaticsLiquidityManager.sol";

/// @dev Event-only value construction; does not change custody or returned liquidity movements.
library LibLiquidityStatement {
    function input(
        IStaticsLiquidityManager.ManagedPositionMovement memory managed,
        address payer,
        address receiver,
        uint256 paid0,
        uint256 paid1
    ) internal pure returns (IStaticsRangeGauge.LiquidityStatementMovement memory statement) {
        statement = IStaticsRangeGauge.LiquidityStatementMovement({
                liquidityBefore: managed.liquidityBefore,
                liquidityAfter: managed.liquidityAfter,
                payer: payer,
                receiver: receiver,
                paid0: paid0,
                received0: managed.refund0,
                paid1: paid1,
                received1: managed.refund1
            });
    }

    function output(IStaticsLiquidityManager.ManagedPositionMovement memory managed, address receiver)
        internal
        pure
        returns (IStaticsRangeGauge.LiquidityStatementMovement memory statement)
    {
        statement = IStaticsRangeGauge.LiquidityStatementMovement({
            liquidityBefore: managed.liquidityBefore,
            liquidityAfter: managed.liquidityAfter,
            payer: address(0),
            receiver: receiver,
            paid0: 0,
            received0: managed.received0,
            paid1: 0,
            received1: managed.received1
        });
    }
}
