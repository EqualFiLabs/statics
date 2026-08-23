// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {DopplerLaunchTypes} from "./DopplerLaunchTypes.sol";

/// @notice Authoritative six-curve STATICS launch geometry shared by deployment and verification.
library StaticsLaunchCurves {
    function defaultCurves() internal pure returns (DopplerLaunchTypes.Curve[] memory curves) {
        curves = new DopplerLaunchTypes.Curve[](6);
        curves[0] =
            DopplerLaunchTypes.Curve({tickLower: -168_800, tickUpper: -153_800, numPositions: 11, shares: 0.025 ether});
        curves[1] =
            DopplerLaunchTypes.Curve({tickLower: -160_700, tickUpper: -139_900, numPositions: 11, shares: 0.075 ether});
        curves[2] =
            DopplerLaunchTypes.Curve({tickLower: -146_900, tickUpper: -123_800, numPositions: 11, shares: 0.125 ether});
        curves[3] =
            DopplerLaunchTypes.Curve({tickLower: -130_800, tickUpper: -100_800, numPositions: 11, shares: 0.2 ether});
        curves[4] =
            DopplerLaunchTypes.Curve({tickLower: -107_700, tickUpper: -77_800, numPositions: 11, shares: 0.425 ether});
        curves[5] =
            DopplerLaunchTypes.Curve({tickLower: -77_800, tickUpper: 887_200, numPositions: 1, shares: 0.15 ether});
    }
}
