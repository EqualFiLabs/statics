// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity 0.8.33;

import {LibAvatarSVG} from "./LibAvatarSVG.sol";
import {LibAvatarTraits} from "./LibAvatarTraits.sol";

/// @notice Stateless SVG assembly helper for the Genesis NFT metadata renderer.
contract StaticsAvatarSVG {
    /// @notice Renders deterministic SVG artwork from a trait seed and activation tier.
    /// @param seed Trait seed derived from chain, collection, and token ID.
    /// @param traits_ Derived avatar traits.
    /// @param tier Activation tier displayed by the artwork.
    /// @return SVG document for the avatar.
    function renderSVG(bytes32 seed, LibAvatarTraits.Traits calldata traits_, uint8 tier)
        external
        pure
        returns (string memory)
    {
        return LibAvatarSVG.render(seed, traits_, tier);
    }
}
