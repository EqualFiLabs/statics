// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract StaticsTimelock is TimelockController {
    uint256 public constant INITIAL_DELAY = 15 minutes;

    constructor(address[] memory proposers, address[] memory executors, address bootstrapAdmin)
        TimelockController(INITIAL_DELAY, proposers, executors, bootstrapAdmin)
    {}
}
