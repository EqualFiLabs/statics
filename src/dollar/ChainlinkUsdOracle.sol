// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ISequencerAwareOracle} from "./interfaces/ISequencerAwareOracle.sol";

interface IChainlinkAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract ChainlinkUsdOracle is ISequencerAwareOracle {
    error ZeroAddress();
    error InvalidMaxStaleness();
    error InvalidPriceBounds(uint256 minPriceWad, uint256 maxPriceWad);
    error InvalidSequencerConfiguration();
    error UnsupportedFeedDecimals(uint8 decimals);
    error PriceOutOfBounds(uint256 priceWad, uint256 minPriceWad, uint256 maxPriceWad);
    error InvalidSequencerRound();
    error InvalidSequencerStatus(int256 status);
    error SequencerDown();
    error SequencerGracePeriodActive(uint256 startedAt, uint256 gracePeriod);

    address public immutable feed;
    uint256 public immutable maxStaleness;
    uint256 public immutable minPriceWad;
    uint256 public immutable maxPriceWad;
    address public immutable sequencerUptimeFeed;
    uint256 public immutable sequencerGracePeriod;
    uint8 public immutable feedDecimals;

    constructor(
        address feed_,
        uint256 maxStaleness_,
        uint256 minPriceWad_,
        uint256 maxPriceWad_,
        address sequencerUptimeFeed_,
        uint256 sequencerGracePeriod_
    ) {
        if (feed_ == address(0)) revert ZeroAddress();
        if (maxStaleness_ == 0) revert InvalidMaxStaleness();
        if (maxPriceWad_ != 0 && maxPriceWad_ <= minPriceWad_) {
            revert InvalidPriceBounds(minPriceWad_, maxPriceWad_);
        }
        if ((sequencerUptimeFeed_ == address(0)) != (sequencerGracePeriod_ == 0)) {
            revert InvalidSequencerConfiguration();
        }

        uint8 decimals_ = IChainlinkAggregatorV3(feed_).decimals();
        if (decimals_ > 18) revert UnsupportedFeedDecimals(decimals_);

        feed = feed_;
        maxStaleness = maxStaleness_;
        minPriceWad = minPriceWad_;
        maxPriceWad = maxPriceWad_;
        sequencerUptimeFeed = sequencerUptimeFeed_;
        sequencerGracePeriod = sequencerGracePeriod_;
        feedDecimals = decimals_;
    }

    function priceWad() external view returns (uint256 normalizedPriceWad) {
        _requireSequencerUp();

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkAggregatorV3(feed).latestRoundData();
        if (
            roundId == 0 || answer <= 0 || startedAt == 0 || updatedAt == 0 || startedAt > updatedAt
                || updatedAt > block.timestamp || answeredInRound < roundId
        ) revert InvalidPrice();
        if (block.timestamp - updatedAt > maxStaleness) revert StalePrice(updatedAt, maxStaleness);

        normalizedPriceWad = uint256(answer);
        if (feedDecimals < 18) normalizedPriceWad *= 10 ** (18 - feedDecimals);
        if (
            (minPriceWad != 0 && normalizedPriceWad <= minPriceWad)
                || (maxPriceWad != 0 && normalizedPriceWad >= maxPriceWad)
        ) revert PriceOutOfBounds(normalizedPriceWad, minPriceWad, maxPriceWad);
    }

    function _requireSequencerUp() internal view {
        if (sequencerUptimeFeed == address(0)) return;

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkAggregatorV3(sequencerUptimeFeed).latestRoundData();
        if (
            roundId == 0 || startedAt == 0 || updatedAt == 0 || startedAt > updatedAt || updatedAt > block.timestamp
                || answeredInRound < roundId
        ) revert InvalidSequencerRound();
        if (answer != 0 && answer != 1) revert InvalidSequencerStatus(answer);
        if (answer == 1) revert SequencerDown();
        if (block.timestamp - startedAt <= sequencerGracePeriod) {
            revert SequencerGracePeriodActive(startedAt, sequencerGracePeriod);
        }
    }
}
