// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IStaticsGenesisProtocol} from "../../src/interfaces/IStaticsGenesis.sol";
import {LibAvatarSVG} from "../../src/metadata/LibAvatarSVG.sol";
import {LibAvatarTraits} from "../../src/metadata/LibAvatarTraits.sol";
import {StaticsAvatarSVG} from "../../src/metadata/StaticsAvatarSVG.sol";
import {StaticsGenesisRenderer} from "../../src/metadata/StaticsGenesisRenderer.sol";

contract AvatarRendererHarness {
    function seed(uint256 chainId, address collection, uint256 tokenId) external pure returns (bytes32) {
        return LibAvatarTraits.seed(chainId, collection, tokenId);
    }

    function traits(bytes32 value) external pure returns (uint8[8] memory values) {
        LibAvatarTraits.Traits memory derived = LibAvatarTraits.derive(value);
        values = [
            derived.field,
            derived.boundary,
            derived.shell,
            derived.interfaceType,
            derived.mantle,
            derived.telemetry,
            derived.sigil,
            derived.signal
        ];
    }

    function svg(uint8[8] calldata values, bytes32 value) external pure returns (string memory) {
        LibAvatarTraits.Traits memory selected = LibAvatarTraits.Traits({
            field: values[0],
            boundary: values[1],
            shell: values[2],
            interfaceType: values[3],
            mantle: values[4],
            telemetry: values[5],
            sigil: values[6],
            signal: values[7]
        });
        return LibAvatarSVG.render(value, selected, 0);
    }
}

contract GenesisTierMock is IStaticsGenesisProtocol {
    mapping(uint256 genesisId => uint8 tier) internal tiers;

    function setTier(uint256 genesisId, uint8 tier) external {
        tiers[genesisId] = tier;
    }

    function genesisTier(uint256 genesisId) external view returns (uint8) {
        return tiers[genesisId];
    }

    function onGenesisTransfer(uint256, address, address) external pure {}
}

contract GenesisRendererTest is Test {
    string internal constant JSON_PREFIX = "data:application/json;base64,";
    string internal constant SVG_PREFIX = "data:image/svg+xml;base64,";

    StaticsGenesisRenderer internal renderer;
    GenesisTierMock internal protocol;
    AvatarRendererHarness internal harness;

    function setUp() public {
        vm.chainId(46_630);
        renderer = new StaticsGenesisRenderer(new StaticsAvatarSVG());
        protocol = new GenesisTierMock();
        harness = new AvatarRendererHarness();
    }

    function test_RenderTokenURIContainsSelfContainedMetadata() public view {
        string memory uri = renderer.renderTokenURI(address(0x51A71C5), 42, address(protocol));
        assertTrue(_startsWith(uri, JSON_PREFIX));

        string memory json = string(_decodeBase64(_afterPrefix(uri, JSON_PREFIX)));
        assertEq(vm.parseJsonString(json, ".name"), "Statics Genesis #42");
        assertEq(
            vm.parseJsonString(json, ".description"),
            "A scarce Genesis asset enhancing STATICS staking reward weight."
        );
        assertEq(vm.parseJsonUint(json, ".attributes[8].value"), 0);

        string memory image = vm.parseJsonString(json, ".image");
        assertTrue(_startsWith(image, SVG_PREFIX));

        string memory svg = string(_decodeBase64(_afterPrefix(image, SVG_PREFIX)));
        assertTrue(_contains(svg, '<svg xmlns="http://www.w3.org/2000/svg"'));
        assertTrue(_contains(svg, '<rect width="256" height="256" fill="#030504"/>'));
        assertTrue(_contains(svg, "</svg>"));
        assertFalse(_contains(svg, "<script"));
        assertFalse(_contains(svg, "javascript:"));
        assertFalse(_contains(svg, "<image"));
        assertFalse(_contains(svg, "<foreignObject"));
        assertFalse(_contains(svg, "@import"));
        assertLt(bytes(uri).length, 12_000);
    }

    function test_RenderTokenURIIsStableForIdentity() public view {
        string memory first = renderer.renderTokenURI(address(0x51A71C5), 42, address(protocol));
        string memory second = renderer.renderTokenURI(address(0x51A71C5), 42, address(protocol));
        assertEq(first, second);
    }

    function test_ActivationTierChangesOnlyTierPresentation() public {
        string memory beforeUri = renderer.renderTokenURI(address(0x51A71C5), 42, address(protocol));
        protocol.setTier(42, 4);
        string memory afterUri = renderer.renderTokenURI(address(0x51A71C5), 42, address(protocol));

        assertNotEq(beforeUri, afterUri);
        string memory json = string(_decodeBase64(_afterPrefix(afterUri, JSON_PREFIX)));
        assertEq(vm.parseJsonUint(json, ".attributes[8].value"), 4);
        string memory svg = string(_decodeBase64(_afterPrefix(vm.parseJsonString(json, ".image"), SVG_PREFIX)));
        assertTrue(_contains(svg, 'id="activation-tier"'));
    }

    function test_SeedSeparatesChainCollectionAndToken() public view {
        bytes32 seed = harness.seed(46_630, address(0x51A71C5), 42);
        assertNotEq(seed, harness.seed(46_631, address(0x51A71C5), 42));
        assertNotEq(seed, harness.seed(46_630, address(0x51A71C6), 42));
        assertNotEq(seed, harness.seed(46_630, address(0x51A71C5), 43));
    }

    function testFuzz_TraitsRemainWithinBounds(bytes32 seed) public view {
        uint8[8] memory values = harness.traits(seed);
        assertLt(values[0], 8);
        assertLt(values[1], 6);
        assertLt(values[2], 8);
        assertLt(values[3], 8);
        assertLt(values[4], 6);
        assertLt(values[5], 8);
        assertLt(values[6], 8);
        assertLt(values[7], 6);
    }

    function test_AllTraitComponentsRender() public view {
        uint8[8] memory values;
        bytes32 seed = keccak256("component coverage");

        for (uint8 field; field < 8; ++field) {
            values[0] = field;
            _assertValidSVG(harness.svg(values, seed));
        }
        values[0] = 0;
        for (uint8 boundary; boundary < 6; ++boundary) {
            values[1] = boundary;
            _assertValidSVG(harness.svg(values, seed));
        }
        values[1] = 0;
        for (uint8 shell; shell < 8; ++shell) {
            values[2] = shell;
            _assertValidSVG(harness.svg(values, seed));
        }
        values[2] = 0;
        for (uint8 interfaceType; interfaceType < 8; ++interfaceType) {
            values[3] = interfaceType;
            _assertValidSVG(harness.svg(values, seed));
        }
        values[3] = 0;
        for (uint8 mantle; mantle < 6; ++mantle) {
            values[4] = mantle;
            _assertValidSVG(harness.svg(values, seed));
        }
        values[4] = 0;
        for (uint8 telemetry; telemetry < 8; ++telemetry) {
            values[5] = telemetry;
            _assertValidSVG(harness.svg(values, seed));
        }
        values[5] = 0;
        for (uint8 sigil; sigil < 8; ++sigil) {
            values[6] = sigil;
            _assertValidSVG(harness.svg(values, seed));
        }
        values[6] = 0;
        for (uint8 signal; signal < 6; ++signal) {
            values[7] = signal;
            _assertValidSVG(harness.svg(values, seed));
        }
    }

    function test_GliderUsesFiveCircularDots() public view {
        uint8[8] memory values;
        values[3] = 3;
        string memory svg = harness.svg(values, bytes32(0));

        assertTrue(_contains(svg, '<circle cx="108" cy="133" r="7"'));
        assertTrue(_contains(svg, '<circle cx="128" cy="133" r="7"'));
        assertTrue(_contains(svg, '<circle cx="148" cy="133" r="7"'));
        assertTrue(_contains(svg, '<circle cx="148" cy="114" r="7"'));
        assertTrue(_contains(svg, '<circle cx="128" cy="95" r="7"'));
    }

    function test_MaximumComponentCompositionFitsMetadataBudget() public view {
        uint8[8] memory values;
        uint8[8] memory counts = [uint8(8), 6, 8, 8, 6, 8, 8, 6];
        bytes32 seed = keccak256("maximum component composition");

        for (uint256 axis; axis < counts.length; ++axis) {
            uint256 largestLength;
            uint8 largestOption;
            for (uint8 option; option < counts[axis]; ++option) {
                values[axis] = option;
                uint256 length = bytes(harness.svg(values, seed)).length;
                if (length > largestLength) {
                    largestLength = length;
                    largestOption = option;
                }
            }
            values[axis] = largestOption;
        }

        uint256 svgLength = bytes(harness.svg(values, seed)).length;
        uint256 imageLength = bytes(SVG_PREFIX).length + 4 * ((svgLength + 2) / 3);
        uint256 conservativeJsonLength = imageLength + 1_200;
        uint256 conservativeUriLength = bytes(JSON_PREFIX).length + 4 * ((conservativeJsonLength + 2) / 3);
        assertLt(conservativeUriLength, 12_000);
    }

    function test_RendererRuntimeLeavesDeploymentHeadroom() public view {
        assertLt(address(renderer).code.length, 23_500);
        assertLt(address(renderer.avatarSVG()).code.length, 23_500);
    }

    function _assertValidSVG(string memory svg) internal pure {
        assertTrue(_startsWith(svg, '<svg xmlns="http://www.w3.org/2000/svg"'));
        assertTrue(_contains(svg, "</svg>"));
        assertLt(bytes(svg).length, 8_000);
    }

    function _startsWith(string memory value, string memory prefix) internal pure returns (bool) {
        bytes memory valueBytes = bytes(value);
        bytes memory prefixBytes = bytes(prefix);
        if (valueBytes.length < prefixBytes.length) return false;
        for (uint256 i; i < prefixBytes.length; ++i) {
            if (valueBytes[i] != prefixBytes[i]) return false;
        }
        return true;
    }

    function _contains(string memory value, string memory needle) internal pure returns (bool) {
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

    function _afterPrefix(string memory value, string memory prefix) internal pure returns (string memory) {
        bytes memory input = bytes(value);
        uint256 prefixLength = bytes(prefix).length;
        bytes memory output = new bytes(input.length - prefixLength);
        for (uint256 i; i < output.length; ++i) {
            output[i] = input[i + prefixLength];
        }
        return string(output);
    }

    function _decodeBase64(string memory value) internal pure returns (bytes memory decoded) {
        bytes memory input = bytes(value);
        require(input.length % 4 == 0, "invalid base64 length");
        uint256 padding = input.length == 0 ? 0 : (input[input.length - 1] == "=" ? 1 : 0);
        if (input.length > 1 && input[input.length - 2] == "=") ++padding;
        decoded = new bytes((input.length / 4) * 3 - padding);

        uint256 cursor;
        for (uint256 i; i < input.length; i += 4) {
            uint256 chunk = (uint256(_base64Value(input[i])) << 18) | (uint256(_base64Value(input[i + 1])) << 12)
                | (uint256(_base64Value(input[i + 2])) << 6) | uint256(_base64Value(input[i + 3]));
            if (cursor < decoded.length) decoded[cursor++] = bytes1(uint8(chunk >> 16));
            if (cursor < decoded.length) decoded[cursor++] = bytes1(uint8(chunk >> 8));
            if (cursor < decoded.length) decoded[cursor++] = bytes1(uint8(chunk));
        }
    }

    function _base64Value(bytes1 character) internal pure returns (uint8) {
        uint8 value = uint8(character);
        if (value >= 65 && value <= 90) return value - 65;
        if (value >= 97 && value <= 122) return value - 71;
        if (value >= 48 && value <= 57) return value + 4;
        if (character == "+") return 62;
        if (character == "/") return 63;
        if (character == "=") return 0;
        revert("invalid base64 character");
    }
}
