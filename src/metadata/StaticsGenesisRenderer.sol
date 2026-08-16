// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IStaticsGenesisProtocol} from "../interfaces/IStaticsGenesis.sol";
import {IStaticsGenesisRenderer} from "../interfaces/IStaticsGenesisRenderer.sol";
import {LibAvatarTraits} from "./LibAvatarTraits.sol";
import {StaticsAvatarSVG} from "./StaticsAvatarSVG.sol";

contract StaticsGenesisRenderer is IStaticsGenesisRenderer {
    using Strings for uint256;

    StaticsAvatarSVG public immutable avatarSVG;

    error InvalidAvatarRenderer();

    constructor(StaticsAvatarSVG avatarSVG_) {
        if (address(avatarSVG_) == address(0)) revert InvalidAvatarRenderer();
        avatarSVG = avatarSVG_;
    }

    function renderTokenURI(address collection, uint256 tokenId, address protocol)
        external
        view
        returns (string memory uri)
    {
        uint8 tier;
        if (protocol != address(0)) {
            try IStaticsGenesisProtocol(protocol).genesisTier(tokenId) returns (uint8 reportedTier) {
                tier = reportedTier;
            } catch {}
        }
        bytes32 seed = LibAvatarTraits.seed(block.chainid, collection, tokenId);
        LibAvatarTraits.Traits memory traits_ = LibAvatarTraits.derive(seed);
        string memory image =
            string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(avatarSVG.renderSVG(seed, traits_, tier))));
        bytes memory json = abi.encodePacked(
            '{"name":"Statics Genesis #',
            tokenId.toString(),
            '","description":"A fixed-supply Statics Genesis NFT redeemable for 180,010 STATICS.","image":"',
            image,
            '","attributes":[',
            _attributes(traits_),
            ",",
            _numericAttribute("Activation Tier", tier),
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

    function _numericAttribute(string memory traitType, uint256 value) private pure returns (string memory) {
        return string.concat('{"trait_type":"', traitType, '","value":', value.toString(), "}");
    }
}
