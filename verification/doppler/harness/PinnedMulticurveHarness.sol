// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Curve, Multicurve} from "doppler/libraries/Multicurve.sol";
import {Position} from "doppler/types/Position.sol";

/// @notice Thin external wrapper around the exact pinned upstream Multicurve library.
contract PinnedMulticurveHarness {
    function adjustCurves(Curve[] memory curves, int24 offset, int24 tickSpacing, bool isToken0)
        external
        pure
        returns (Curve[] memory adjusted, int24 lowerBoundary, int24 upperBoundary)
    {
        return Multicurve.adjustCurves(curves, offset, tickSpacing, isToken0);
    }

    function calculatePositions(
        Curve[] memory curves,
        int24 tickSpacing,
        uint256 numTokensToSell,
        uint256 otherCurrencySupply,
        bool isToken0
    ) external pure returns (Position[] memory positions) {
        return Multicurve.calculatePositions(curves, tickSpacing, numTokensToSell, otherCurrencySupply, isToken0);
    }
}
