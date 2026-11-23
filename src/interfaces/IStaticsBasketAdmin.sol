// SPDX-License-Identifier: BUSL-1.1
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

    function setCreationFee(uint256 amount) external;
    function setTreasury(address newTreasury) external;
    function creationFee() external view returns (uint256 amount);
    function treasury() external view returns (address);
}
