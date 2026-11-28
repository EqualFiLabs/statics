// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity 0.8.33;

interface IStaticsBasketAdmin {
    event BasketDistributorSet(uint256 indexed basketId, address indexed account, bool allowed);

    /// @notice Approve a custody endpoint for ordinary transfers of the specified basket token.
    function setBasketDistributor(uint256 basketId, address account, bool allowed) external;
    /// @notice Ownership and spender approval do not imply distributor approval.
    function isBasketDistributor(uint256 basketId, address account) external view returns (bool);

    event CreationFeeChanged(uint256 amount);
    event CreationFeePaid(address indexed creator, address indexed treasury, uint256 amount);
    event TreasuryChanged(address indexed previousTreasury, address indexed newTreasury);
    event BasketMintRedemptionStakerShareSet(uint256 indexed basketId, uint16 previousShareBps, uint16 newShareBps);

    function setCreationFee(uint256 amount) external;
    function setTreasury(address newTreasury) external;
    function creationFee() external view returns (uint256 amount);
    function treasury() external view returns (address);

    /// @notice Set the eligible basket stakers' share of subsequent mint and redemption fees.
    function setBasketMintRedemptionStakerShareBps(uint256 basketId, uint16 shareBps) external;
    /// @notice Configured share, before the Treasury fallback for ineligible rewards.
    function basketMintRedemptionStakerShareBps(uint256 basketId) external view returns (uint16);
}
