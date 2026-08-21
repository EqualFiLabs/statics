// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {LibStaticsLogoSVG} from "./LibStaticsLogoSVG.sol";

library LibPositionSVG {
    using Strings for uint256;

    function render(uint256 positionId) internal pure returns (string memory) {
        string memory displayId = positionId.toString();
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256" role="img">',
            "<title>Statics Position #",
            displayId,
            "</title>",
            '<rect width="256" height="256" fill="#fefefe"/>',
            '<rect x="15" y="15" width="226" height="226" fill="#000000"/>',
            '<g transform="translate(32 12) scale(.75)" shape-rendering="crispEdges">',
            LibStaticsLogoSVG.mark(),
            "</g>",
            '<text x="128" y="225" fill="#fefefe" font-family="monospace" font-size="14" font-weight="700" text-anchor="middle">POSITION #',
            displayId,
            "</text></svg>"
        );
    }
}
