// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract StaticsTimelock is TimelockController {
    uint256 public constant PRODUCTION_INITIAL_DELAY = 7 days;
    uint256 public constant DEVELOPMENT_INITIAL_DELAY = 2 minutes;
    uint256 public constant ROBINHOOD_TESTNET_CHAIN_ID = 46_630;
    uint256 public constant LOCAL_CHAIN_ID = 31_337;

    constructor(address[] memory proposers, address[] memory executors, address bootstrapAdmin)
        TimelockController(_initialDelay(block.chainid), proposers, executors, bootstrapAdmin)
    {}

    function _initialDelay(uint256 chainId) private pure returns (uint256) {
        if (chainId == ROBINHOOD_TESTNET_CHAIN_ID || chainId == LOCAL_CHAIN_ID) {
            return DEVELOPMENT_INITIAL_DELAY;
        }
        return PRODUCTION_INITIAL_DELAY;
    }
}
