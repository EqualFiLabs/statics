// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ISequencerAwareOracle} from "src/dollar/interfaces/ISequencerAwareOracle.sol";

contract SequencerAwareMockOracle is ISequencerAwareOracle {
    uint256 internal immutable _priceWad;
    address public immutable sequencerUptimeFeed;
    uint256 public immutable sequencerGracePeriod;

    constructor(uint256 priceWad_, address sequencerUptimeFeed_, uint256 sequencerGracePeriod_) {
        _priceWad = priceWad_;
        sequencerUptimeFeed = sequencerUptimeFeed_;
        sequencerGracePeriod = sequencerGracePeriod_;
    }

    function priceWad() external view returns (uint256) {
        if (_priceWad == 0) revert InvalidPrice();
        return _priceWad;
    }
}
