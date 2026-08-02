// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

interface IStaticsFlashLoan {
    event BasketFlashLoan(
        uint256 indexed basketId,
        address indexed initiator,
        address indexed receiver,
        uint256 shares,
        uint256[] amounts,
        uint256[] fees
    );

    function flashLoan(uint256 basketId, uint256 shares, address receiver, bytes calldata data) external;
    function quoteFlashLoan(uint256 basketId, uint256 shares)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts, uint256[] memory fees);
}
