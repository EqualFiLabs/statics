// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity 0.8.33;

interface IStaticsPositionRoyalty {
    event PositionRoyaltyUpdated(address indexed receiver, uint16 royaltyBps);

    error PositionRoyaltyAlreadyInitialized();
    error PositionRoyaltyNotInitialized();
    error InvalidPositionRoyaltyReceiver(address receiver);
    error PositionRoyaltyExceedsMaximum(uint256 royaltyBps, uint256 maximumRoyaltyBps);

    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount);
    function positionRoyalty() external view returns (address receiver, uint16 royaltyBps);
    function setPositionRoyalty(address receiver, uint16 royaltyBps) external;
}
