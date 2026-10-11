// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity 0.8.33;

import {DefaultVenueController} from "./DefaultVenueController.sol";

contract DefaultVenueControllerFactory {
    event VenueControllerCreated(address indexed creator, address indexed controller);

    function createController() external returns (address controller) {
        controller = address(new DefaultVenueController(msg.sender));
        emit VenueControllerCreated(msg.sender, controller);
    }
}
