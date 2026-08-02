// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IUsdOracle} from "../interfaces/IUsdOracle.sol";

/// @notice Owner-published normalized USD price for public testnet collateral.
contract TestnetUsdOracle is IUsdOracle, Ownable {
    error InvalidMaxStaleness();

    event PricePublished(uint256 priceWad, uint256 updatedAt);

    uint256 public immutable maxStaleness;
    uint256 public updatedAt;

    uint256 private _priceWad;

    constructor(address owner_, uint256 initialPriceWad, uint256 maxStaleness_) Ownable(owner_) {
        if (maxStaleness_ == 0) revert InvalidMaxStaleness();
        maxStaleness = maxStaleness_;
        _publish(initialPriceWad);
    }

    function publishPrice(uint256 priceWad_) external onlyOwner {
        _publish(priceWad_);
    }

    function priceWad() external view returns (uint256 price) {
        price = _priceWad;
        if (price == 0) revert InvalidPrice();

        uint256 lastUpdate = updatedAt;
        if (lastUpdate == 0 || lastUpdate > block.timestamp || block.timestamp - lastUpdate > maxStaleness) {
            revert StalePrice(lastUpdate, maxStaleness);
        }
    }

    function _publish(uint256 priceWad_) private {
        _priceWad = priceWad_;
        updatedAt = block.timestamp;
        emit PricePublished(priceWad_, block.timestamp);
    }
}
