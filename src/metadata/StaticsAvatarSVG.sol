// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LibAvatarSVG} from "./LibAvatarSVG.sol";
import {LibAvatarTraits} from "./LibAvatarTraits.sol";

/// @notice Stateless SVG assembly helper for the Genesis NFT metadata renderer.
contract StaticsAvatarSVG {
    function renderSVG(bytes32 seed, LibAvatarTraits.Traits calldata traits_, uint8 tier)
        external
        pure
        returns (string memory)
    {
        return LibAvatarSVG.render(seed, traits_, tier);
    }
}
