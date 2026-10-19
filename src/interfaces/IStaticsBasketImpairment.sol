// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity 0.8.33;

/// @notice Explicit exits permanently forfeit backing in owner-marked impaired assets.
interface IStaticsBasketImpairment {
    error AssetNotInBasket(uint256 basketId, address asset);
    error AssetAlreadyImpaired(uint256 basketId, address asset);
    error BasketNotImpaired(uint256 basketId);
    error ImpairedRedemptionRequired(uint256 basketId);

    event BasketAssetImpaired(uint256 indexed basketId, address indexed asset);
    event BasketImpairedRedeemed(
        uint256 indexed basketId, address indexed owner, address indexed receiver, uint256 shares
    );

    function markBasketAssetImpaired(uint256 basketId, address asset) external;
    function isBasketAssetImpaired(uint256 basketId, address asset) external view returns (bool);
    /// @dev Impaired entries must have zero minimum output; their backing is permanently forfeited.
    function redeemImpaired(uint256 basketId, uint256 shares, address receiver, uint256[] calldata minAmountsOut)
        external
        returns (uint256[] memory amountsOut);
    function redeemImpairedBasketCollateral(
        uint256 positionId,
        uint256 basketId,
        uint256 shares,
        address receiver,
        uint256[] calldata minAmountsOut
    ) external returns (uint256[] memory amountsOut);
    function quoteRedeemImpaired(uint256 basketId, uint256 shares) external view returns (uint256[] memory amountsOut);
}
