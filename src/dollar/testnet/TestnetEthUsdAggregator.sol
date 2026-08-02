// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Owner-published ETH/USD rounds for public testnet deployments.
/// @dev Uses Chainlink AggregatorV3 round semantics and eight price decimals.
contract TestnetEthUsdAggregator is Ownable {
    error PriceExceedsInt256(uint256 price);

    event PricePublished(uint80 indexed roundId, uint256 price, uint256 updatedAt);

    uint8 public constant decimals = 8;
    string public constant description = "Testnet ETH / USD";
    uint256 public constant version = 1;

    uint80 private _roundId;
    int256 private _answer;
    uint256 private _startedAt;
    uint256 private _updatedAt;

    constructor(address owner_, uint256 initialPrice) Ownable(owner_) {
        _publish(initialPrice);
    }

    function publishPrice(uint256 price) external onlyOwner {
        _publish(price);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        roundId = _roundId;
        answer = _answer;
        startedAt = _startedAt;
        updatedAt = _updatedAt;
        answeredInRound = roundId;
    }

    function _publish(uint256 price) private {
        if (price > uint256(type(int256).max)) revert PriceExceedsInt256(price);

        uint80 roundId = _roundId + 1;
        _roundId = roundId;
        _answer = int256(price);
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
        emit PricePublished(roundId, price, block.timestamp);
    }
}
