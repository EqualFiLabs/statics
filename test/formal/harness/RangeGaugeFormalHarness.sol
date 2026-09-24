// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LibRangeGauge} from "../../../src/libraries/LibRangeGauge.sol";

contract RangeGaugeFormalHarness {
    LibRangeGauge.GaugeRewardStream internal formalStream;

    function _fund(uint256 amount, uint40 timestamp, uint40 duration, uint128 activeLiquidity)
        internal
        returns (uint256 emission, uint40 remainingDuration)
    {
        return LibRangeGauge.fundStream(formalStream, amount, timestamp, duration, activeLiquidity);
    }

    function _checkpoint(uint40 timestamp, uint128 activeLiquidity) internal returns (uint256 emission) {
        return LibRangeGauge.checkpointStream(formalStream, timestamp, activeLiquidity);
    }

    function _stream() internal view returns (LibRangeGauge.GaugeRewardStream memory) {
        return formalStream;
    }

    function _positionAccrual(uint128 liquidity, uint256 growthDeltaRay, uint256 priorRemainderRay)
        internal
        pure
        returns (uint256 claimableDelta, uint256 newRemainderRay)
    {
        return LibRangeGauge.positionAccrual(liquidity, growthDeltaRay, priorRemainderRay);
    }

    function _combinePositionAccrual(uint256 whole, uint256 productRemainderRay, uint256 priorRemainderRay)
        internal
        pure
        returns (uint256 claimableDelta, uint256 newRemainderRay)
    {
        return LibRangeGauge.combinePositionAccrual(whole, productRemainderRay, priorRemainderRay);
    }

    function _applyCrossing(uint128 activeLiquidity, int128 netLiquidity, bool rightward)
        internal
        pure
        returns (uint128)
    {
        return LibRangeGauge.applyCrossingLiquidity(activeLiquidity, netLiquidity, rightward);
    }

    function _inside(
        uint256 global,
        uint256 lowerOutside,
        uint256 upperOutside,
        int24 tickLower,
        int24 tickUpper,
        int24 currentTick
    ) internal pure returns (uint256) {
        return LibRangeGauge.growthInsideValues(global, lowerOutside, upperOutside, tickLower, tickUpper, currentTick);
    }

    function _addBoundaryValues(uint128 gross, int128 net, uint128 liquidity, bool lower)
        internal
        pure
        returns (uint128 updatedGross, int128 updatedNet)
    {
        return LibRangeGauge.addBoundaryLiquidity(gross, net, liquidity, lower, lower ? int24(-100) : int24(100));
    }

    function _removeBoundaryValues(uint128 gross, int128 net, uint128 liquidity, bool lower)
        internal
        pure
        returns (uint128 updatedGross, int128 updatedNet)
    {
        return LibRangeGauge.removeBoundaryLiquidity(gross, net, liquidity, lower, lower ? int24(-100) : int24(100));
    }
}
