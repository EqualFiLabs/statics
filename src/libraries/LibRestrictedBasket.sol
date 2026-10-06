// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IStaticsRestrictedBasketToken} from "../interfaces/IStaticsRestrictedBasketToken.sol";

/// @notice Explicit V2 identities. Never discovers authority by calling an arbitrary token marker.
library LibRestrictedBasket {
    bytes32 private constant STORAGE_POSITION = keccak256("statics.storage.restricted.basket.v1");

    struct RestrictedStorage {
        mapping(address token => uint256 basketIdPlusOne) basketIds;
    }

    error RestrictedTokenAlreadyRegistered(address token);

    function restrictedStorage() internal pure returns (RestrictedStorage storage rs) {
        bytes32 slot = STORAGE_POSITION;
        assembly ("memory-safe") {
            rs.slot := slot
        }
    }

    /// @dev Called only by approved protocol creation code, not an externally callable registration endpoint.
    function register(address token, uint256 basketId) internal {
        RestrictedStorage storage rs = restrictedStorage();
        if (rs.basketIds[token] != 0) revert RestrictedTokenAlreadyRegistered(token);
        rs.basketIds[token] = basketId + 1;
    }

    function isRestricted(address token) internal view returns (bool) {
        return restrictedStorage().basketIds[token] != 0;
    }

    function authorizeProtocolTransfer(address token, address from, address to, uint256 amount) internal {
        if (isRestricted(token)) {
            IStaticsRestrictedBasketToken(token).authorizeProtocolTransfer(from, to, amount);
        }
    }
}
