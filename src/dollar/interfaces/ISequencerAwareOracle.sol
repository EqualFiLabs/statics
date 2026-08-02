// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IUsdOracle} from "./IUsdOracle.sol";

interface ISequencerAwareOracle is IUsdOracle {
    function sequencerUptimeFeed() external view returns (address);

    function sequencerGracePeriod() external view returns (uint256);
}
