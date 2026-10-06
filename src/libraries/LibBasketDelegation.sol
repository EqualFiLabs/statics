// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IStaticsBasketDelegation} from "../interfaces/IStaticsBasketDelegation.sol";
import {LibBasket} from "./LibBasket.sol";

library LibBasketDelegation {
    bytes32 private constant STORAGE_POSITION = keccak256("statics.storage.basket.delegation.v1");
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant TYPEHASH = keccak256(
        "BasketCreation(address creator,address payer,bytes32 preparationId,bytes32 configurationHash,uint256 nonce,uint256 deadline,uint256 maxNativeFee)"
    );

    struct Storage {
        mapping(address creator => mapping(uint256 word => uint256 bits)) nonces;
    }
    error InvalidCreationAuthorization();
    error CreationNonceAlreadyUsed();
    event CreationNoncesInvalidated(address indexed creator, uint256 indexed word, uint256 mask);

    function delegationStorage() internal pure returns (Storage storage ds) {
        bytes32 slot = STORAGE_POSITION;
        assembly ("memory-safe") { ds.slot := slot }
    }

    function digest(IStaticsBasketDelegation.Authorization calldata authorization) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256("Statics Basket Creation"), keccak256("1"), block.chainid, address(this)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, keccak256(abi.encode(TYPEHASH, authorization))));
    }

    function used(address creator, uint256 nonce) internal view returns (bool) {
        return delegationStorage().nonces[creator][nonce >> 8] & (uint256(1) << uint8(nonce)) != 0;
    }

    function validate(
        IStaticsBasketDelegation.Authorization calldata authorization,
        bytes calldata signature,
        bytes32 configuration,
        bool consume
    ) internal {
        if (used(authorization.creator, authorization.nonce)) {
            revert CreationNonceAlreadyUsed();
        }
        if (
            authorization.creator == address(0) || authorization.payer != msg.sender
                || authorization.preparationId == bytes32(0) || block.timestamp >= authorization.deadline
                || authorization.configurationHash != configuration
                || LibBasket.basketStorage().creationFeeAmount > authorization.maxNativeFee
                || !SignatureChecker.isValidSignatureNow(authorization.creator, digest(authorization), signature)
        ) {
            revert InvalidCreationAuthorization();
        }
        if (consume) {
            delegationStorage().nonces[authorization.creator][authorization.nonce >> 8] |= uint256(1)
            << uint8(authorization.nonce);
        }
    }
}
