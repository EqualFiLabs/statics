// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity 0.8.33;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IGenesisActivationRegistry} from "../interfaces/IGenesisActivationRegistry.sol";
import {IStaticsGenesisRenderer} from "../interfaces/IStaticsGenesisRenderer.sol";
import {LibAvatarTraits} from "./LibAvatarTraits.sol";
import {StaticsAvatarSVG} from "./StaticsAvatarSVG.sol";

/// @notice Stateless renderer for deterministic Genesis SVG and JSON data URIs.
contract StaticsGenesisRenderer is IStaticsGenesisRenderer {
    using Strings for uint256;

    StaticsAvatarSVG public immutable avatarSVG;

    error InvalidAvatarRenderer();

    constructor(StaticsAvatarSVG avatarSVG_) {
        if (address(avatarSVG_) == address(0)) revert InvalidAvatarRenderer();
        avatarSVG = avatarSVG_;
    }

    /// @inheritdoc IStaticsGenesisRenderer
    function renderTokenURI(address collection, uint256 tokenId, address activationRegistry)
        external
        view
        returns (string memory uri)
    {
        uint8 tier;
        if (activationRegistry != address(0)) {
            try IGenesisActivationRegistry(activationRegistry).tierOf(tokenId) returns (uint8 reportedTier) {
                tier = reportedTier;
            } catch {}
        }
        bytes32 seed = LibAvatarTraits.seed(block.chainid, collection, tokenId);
        LibAvatarTraits.Traits memory traits_ = LibAvatarTraits.derive(seed);
        string memory image =
            string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(avatarSVG.renderSVG(seed, traits_, tier))));
        bytes memory json = abi.encodePacked(
            '{"name":"STATICS Operators #',
            tokenId.toString(),
            '","description":"A fixed-supply, dual-backed STATICS Operators NFT redeemable for 180,000 STATICS plus a 1/5,555 share of the permanent native ETH reserve after the Genesis Epoch.","image":"',
            image,
            '","attributes":[',
            _attributes(traits_),
            ",",
            _numericAttribute("Activation Tier", tier, 4),
            "]}"
        );
        uri = string.concat("data:application/json;base64,", Base64.encode(json));
    }

    function _attributes(LibAvatarTraits.Traits memory traits_) private pure returns (string memory) {
        return string.concat(
            _attribute("Field", LibAvatarTraits.fieldName(traits_.field)),
            ",",
            _attribute("Boundary", LibAvatarTraits.boundaryName(traits_.boundary)),
            ",",
            _attribute("Shell", LibAvatarTraits.shellName(traits_.shell)),
            ",",
            _attribute("Interface", LibAvatarTraits.interfaceName(traits_.interfaceType)),
            ",",
            _attribute("Mantle", LibAvatarTraits.mantleName(traits_.mantle)),
            ",",
            _attribute("Telemetry", LibAvatarTraits.telemetryName(traits_.telemetry)),
            ",",
            _attribute("Sigil", LibAvatarTraits.sigilName(traits_.sigil)),
            ",",
            _attribute("Signal", LibAvatarTraits.signalName(traits_.signal))
        );
    }

    function _attribute(string memory traitType, string memory value) private pure returns (string memory) {
        return string.concat('{"trait_type":"', traitType, '","value":"', value, '"}');
    }

    function _numericAttribute(string memory traitType, uint256 value, uint256 maxValue)
        private
        pure
        returns (string memory)
    {
        return string.concat(
            '{"display_type":"number","trait_type":"',
            traitType,
            '","value":',
            value.toString(),
            ',"max_value":',
            maxValue.toString(),
            "}"
        );
    }
}
