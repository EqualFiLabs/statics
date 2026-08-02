// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IUsdOracle {
    error InvalidPrice();
    error StalePrice(uint256 updatedAt, uint256 maxStaleness);

    function priceWad() external view returns (uint256 priceWad);
}
