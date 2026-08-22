// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {LibStaticsLogoSVG} from "./LibStaticsLogoSVG.sol";

/// @notice Canonical, fully onchain metadata for the Doppler-created STATICS ERC-20.
library LibStaticsTokenMetadata {
    function imageURI() internal pure returns (string memory) {
        return string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(LibStaticsLogoSVG.tokenLogo())));
    }

    function tokenURI() internal pure returns (string memory) {
        bytes memory json = abi.encodePacked(
            '{"name":"Statics","symbol":"STATICS","description":"The protocol token of Statics Protocol.","image":"',
            imageURI(),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }
}
