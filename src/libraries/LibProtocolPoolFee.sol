// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @notice Single shared pure fee-policy implementation used by both the Statics Diamond and
/// `StaticsSwapFeeHook`. Keeping the canonical Statics swap-fee bound in one place prevents the
/// Diamond and hook from maintaining independent copies that could diverge.
library LibProtocolPoolFee {
    /// @dev The fixed creator allocation, sourced from the prior treasury allocation.
    uint16 internal constant CREATOR_SHARE_BPS = 500;

    /// @dev Total basis points.
    uint16 internal constant TOTAL_SHARE_BPS = 10_000;

    /// @dev Configurable (non-creator) allocation share that every stored profile must total.
    uint16 internal constant CONFIGURABLE_SHARE_BPS = 9_500;

    /// @dev Maximum combined bilateral swap-fee rate.
    uint256 internal constant MAX_COMBINED_FEE_BPS = 200;

    /// @dev Inclusive tick-spacing bounds enforced before requesting creator authorization.
    int24 internal constant MIN_TICK_SPACING = 1;
    int24 internal constant MAX_TICK_SPACING = 32_767;

    /// @return valid Whether `inputFeeBps + outputFeeBps` satisfies the canonical Statics bound.
    function isValidFeeRate(uint16 inputFeeBps, uint16 outputFeeBps) internal pure returns (bool valid) {
        return uint256(inputFeeBps) + uint256(outputFeeBps) <= MAX_COMBINED_FEE_BPS;
    }

    /// @return valid Whether the configurable shares sum to exactly 9,500 bps.
    function isValidConfigurableShares(
        uint16 polShareBps,
        uint16 liquidityProviderShareBps,
        uint16 basketStakerShareBps,
        uint16 staticsStakerShareBps,
        uint16 treasuryShareBps
    ) internal pure returns (bool valid) {
        return uint256(polShareBps) + uint256(liquidityProviderShareBps) + uint256(basketStakerShareBps)
                + uint256(staticsStakerShareBps) + uint256(treasuryShareBps) == CONFIGURABLE_SHARE_BPS;
    }

    /// @return valid Whether the tick spacing lies within the inclusive Statics policy bounds.
    function isValidTickSpacing(int24 tickSpacing) internal pure returns (bool valid) {
        return tickSpacing >= MIN_TICK_SPACING && tickSpacing <= MAX_TICK_SPACING;
    }
}
