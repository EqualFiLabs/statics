// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Owner-published Morpho price used only for public testnet rehearsals.
/// @dev Morpho expects the price of one collateral unit in loan-token units,
///      scaled according to the token decimals. For two 18-decimal tokens the
///      scale is 1e36.
contract TestnetMorphoOracle is Ownable {
    error InvalidPrice();

    event PricePublished(uint256 price);

    uint256 public price;

    constructor(address owner_, uint256 initialPrice) Ownable(owner_) {
        _publish(initialPrice);
    }

    function publishPrice(uint256 newPrice) external onlyOwner {
        _publish(newPrice);
    }

    function _publish(uint256 newPrice) private {
        if (newPrice == 0) revert InvalidPrice();
        price = newPrice;
        emit PricePublished(newPrice);
    }
}
