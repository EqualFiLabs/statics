// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {DeployStaticsGenesis} from "../../script/DeployStaticsGenesis.s.sol";
import {LibStaticsLogoSVG} from "../../src/metadata/LibStaticsLogoSVG.sol";
import {LibStaticsTokenMetadata} from "../../src/metadata/LibStaticsTokenMetadata.sol";

contract StaticsTokenMetadataHarness {
    function logo() external pure returns (string memory) {
        return LibStaticsLogoSVG.tokenLogo();
    }

    function imageURI() external pure returns (string memory) {
        return LibStaticsTokenMetadata.imageURI();
    }

    function tokenURI() external pure returns (string memory) {
        return LibStaticsTokenMetadata.tokenURI();
    }
}

contract StaticsTokenMetadataTest is Test {
    StaticsTokenMetadataHarness private harness;

    function setUp() public {
        harness = new StaticsTokenMetadataHarness();
    }

    function testCanonicalLogoMatchesApprovedStaticsIdentity() public view {
        string memory svg = harness.logo();
        assertEq(bytes(svg).length, 559);
        assertTrue(_contains(svg, '<rect width="256" height="256" fill="#fefefe"/>'));
        assertTrue(_contains(svg, '<rect x="15" y="15" width="226" height="226" fill="#000000"/>'));
        assertTrue(_contains(svg, '<path fill="#fefefe" d="M33 34h94v40H75v37h51v40H33z"/>'));
        assertTrue(_contains(svg, '<path fill="#82ca17" d="M183 186h40v40h-40z"/>'));
        assertFalse(_contains(svg, "<script"));
        assertFalse(_contains(svg, "javascript:"));
        assertFalse(_contains(svg, "<image"));
        assertFalse(_contains(svg, "<foreignObject"));
        assertFalse(_contains(svg, "@import"));
    }

    function testCanonicalTokenUriMatchesReviewedPayload() public view {
        string memory uri = harness.tokenURI();
        assertEq(bytes(uri).length, 1_201);
        assertEq(sha256(bytes(uri)), hex"6a3b3de0ae40af1df020a398bb2114bd97f64b5751906bd31024ae2676f0fd68");
        assertTrue(_startsWith(uri, "data:application/json;base64,"));
        assertTrue(_startsWith(harness.imageURI(), "data:image/svg+xml;base64,"));
    }

    function testProductionDeployerExposesSameCanonicalUri() public {
        DeployStaticsGenesis deployer = new DeployStaticsGenesis();
        assertEq(deployer.staticsTokenURI(), harness.tokenURI());
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
