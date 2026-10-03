// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IStaticsPositionRoyalty} from "../interfaces/IStaticsPositionRoyalty.sol";

library LibPositionRoyalty {
    bytes32 internal constant STORAGE_POSITION = keccak256("statics.position.royalty.storage.v1");
    uint16 internal constant DEFAULT_ROYALTY_BPS = 500;
    uint16 internal constant MAX_ROYALTY_BPS = 1_000;

    struct RoyaltyStorage {
        address receiver;
        uint16 royaltyBps;
        bool initialized;
    }

    function royaltyStorage() internal pure returns (RoyaltyStorage storage rs) {
        bytes32 position = STORAGE_POSITION;
        assembly ("memory-safe") {
            rs.slot := position
        }
    }

    function initialize(address receiver) internal {
        RoyaltyStorage storage rs = royaltyStorage();
        if (rs.initialized) revert IStaticsPositionRoyalty.PositionRoyaltyAlreadyInitialized();
        _validate(receiver, DEFAULT_ROYALTY_BPS);
        rs.receiver = receiver;
        rs.royaltyBps = DEFAULT_ROYALTY_BPS;
        rs.initialized = true;
        emit IStaticsPositionRoyalty.PositionRoyaltyUpdated(receiver, DEFAULT_ROYALTY_BPS);
    }

    function set(address receiver, uint16 royaltyBps) internal {
        RoyaltyStorage storage rs = royaltyStorage();
        if (!rs.initialized) revert IStaticsPositionRoyalty.PositionRoyaltyNotInitialized();
        _validate(receiver, royaltyBps);
        if (royaltyBps == 0) receiver = address(0);
        rs.receiver = receiver;
        rs.royaltyBps = royaltyBps;
        emit IStaticsPositionRoyalty.PositionRoyaltyUpdated(receiver, royaltyBps);
    }

    function _validate(address receiver, uint16 royaltyBps) private view {
        if (royaltyBps > MAX_ROYALTY_BPS) {
            revert IStaticsPositionRoyalty.PositionRoyaltyExceedsMaximum(royaltyBps, MAX_ROYALTY_BPS);
        }
        if (royaltyBps != 0 && (receiver == address(0) || receiver == address(this))) {
            revert IStaticsPositionRoyalty.InvalidPositionRoyaltyReceiver(receiver);
        }
    }
}
