// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

interface IStaticsFlashBorrower {
    function onStaticsFlashLoan(
        address initiator,
        uint256 basketId,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata fees,
        bytes calldata data
    ) external returns (bytes32);
}
