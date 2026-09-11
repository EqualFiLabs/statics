// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

interface IStaticsFlashAssetBorrower {
    function onStaticsFlashLoanAsset(
        address initiator,
        address asset,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32);
}
