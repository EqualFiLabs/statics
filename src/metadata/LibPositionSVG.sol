// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

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
            '<path fill="#fefefe" d="M33 34h94v40H75v37h51v40H33z"/>',
            '<path fill="#fefefe" d="M132 34h91v40h-91z"/>',
            '<path fill="#fefefe" d="M131 111h92v72h-40v-32h-52z"/>',
            '<path fill="#fefefe" d="M33 186h94v40H33z"/>',
            '<path fill="#fefefe" d="M132 186h47v40h-47z"/>',
            '<path fill="#82ca17" d="M183 186h40v40h-40z"/>',
            "</g>",
            '<text x="128" y="225" fill="#fefefe" font-family="monospace" font-size="14" font-weight="700" text-anchor="middle">POSITION #',
            displayId,
            "</text></svg>"
        );
    }
}
