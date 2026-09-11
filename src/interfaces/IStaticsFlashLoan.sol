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

    event AssetFlashLoan(
        address indexed asset, address indexed initiator, address indexed receiver, uint256 amount, uint256 fee
    );

    event SingleAssetFlashFeeBpsUpdated(uint16 previousFeeBps, uint16 newFeeBps);

    function flashLoan(uint256 basketId, uint256 shares, address receiver, bytes calldata data) external;

    function flashLoanAsset(address asset, uint256 amount, address receiver, bytes calldata data) external;

    function quoteFlashLoan(uint256 basketId, uint256 shares)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts, uint256[] memory fees);

    function quoteFlashLoanAsset(address asset, uint256 amount) external view returns (uint256 fee);

    function maxFlashLoan(address asset) external view returns (uint256);

    function singleAssetFlashFeeBps() external view returns (uint16);

    function setSingleAssetFlashFeeBps(uint16 newFeeBps) external;
}
