// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {LibPositionSVG} from "../../src/metadata/LibPositionSVG.sol";
import {PositionNFTFacet} from "../../src/position/PositionNFTFacet.sol";

contract PositionSVGHarness {
    function render(uint256 positionId) external pure returns (string memory) {
        return LibPositionSVG.render(positionId);
    }
}

contract PositionRendererTest is Test {
    using Strings for uint256;

    PositionSVGHarness internal harness;

    function setUp() public {
        harness = new PositionSVGHarness();
    }

    function test_RenderContainsApprovedStaticsIdentity() public view {
        string memory svg = harness.render(42);

        assertTrue(_startsWith(svg, '<svg xmlns="http://www.w3.org/2000/svg"'));
        assertTrue(_contains(svg, "<title>Statics Position #42</title>"));
        assertTrue(_contains(svg, '<rect width="256" height="256" fill="#fefefe"/>'));
        assertTrue(_contains(svg, '<rect x="15" y="15" width="226" height="226" fill="#000000"/>'));
        assertTrue(_contains(svg, '<path fill="#82ca17" d="M183 186h40v40h-40z"/>'));
        assertTrue(_contains(svg, ">POSITION #42</text>"));
        assertTrue(_contains(svg, "</svg>"));
        assertFalse(_contains(svg, "<script"));
        assertFalse(_contains(svg, "javascript:"));
        assertFalse(_contains(svg, "<image"));
        assertFalse(_contains(svg, "<foreignObject"));
        assertFalse(_contains(svg, "@import"));
        assertLt(bytes(svg).length, 2_000);
    }

    function testFuzz_RenderIncludesExactDecimalPositionId(uint256 positionId) public view {
        string memory displayId = positionId.toString();
        string memory svg = harness.render(positionId);

        assertTrue(_contains(svg, string.concat("<title>Statics Position #", displayId, "</title>")));
        assertTrue(_contains(svg, string.concat(">POSITION #", displayId, "</text>")));
    }

    function test_PositionFacetRetainsEip170Headroom() public {
        PositionNFTFacet facet = new PositionNFTFacet();
        assertLt(address(facet).code.length, 12_000);
    }

    function _startsWith(string memory value, string memory prefix) private pure returns (bool) {
        bytes memory valueBytes = bytes(value);
        bytes memory prefixBytes = bytes(prefix);
        if (valueBytes.length < prefixBytes.length) return false;
        for (uint256 i; i < prefixBytes.length; ++i) {
            if (valueBytes[i] != prefixBytes[i]) return false;
        }
        return true;
    }

    function _contains(string memory value, string memory needle) private pure returns (bool) {
        bytes memory haystack = bytes(value);
        bytes memory sought = bytes(needle);
        if (sought.length > haystack.length) return false;
        for (uint256 i; i <= haystack.length - sought.length; ++i) {
            bool match_ = true;
            for (uint256 j; j < sought.length; ++j) {
                if (haystack[i + j] != sought[j]) {
                    match_ = false;
                    break;
                }
            }
            if (match_) return true;
        }
        return false;
    }
}
