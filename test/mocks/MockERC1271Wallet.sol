// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title MockERC1271Wallet
/// @notice Minimal ERC-1271 smart-contract wallet used to prove that a contract
///         creator can authorize Statics general-pool creation. The wallet
///         validates a candidate signature against a fixed owner key and can be
///         toggled to reject every signature to model a malicious or misbehaving
///         wallet.
contract MockERC1271Wallet {
    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;

    address public immutable owner;
    bool public rejectAll;

    constructor(address owner_) {
        owner = owner_;
    }

    /// @notice Toggle whether the wallet rejects all signatures.
    function setRejectAll(bool value) external {
        rejectAll = value;
    }

    /// @notice ERC-1271 signature validation against the fixed owner key.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (rejectAll) return 0xffffffff;
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == owner) {
            return MAGIC_VALUE;
        }
        return 0xffffffff;
    }
}
