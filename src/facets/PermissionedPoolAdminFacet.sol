// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsPermissionedPools} from "../interfaces/IStaticsPermissionedPools.sol";
import {IStaticsPermissionedSwapFeeHook} from "../interfaces/IStaticsPermissionedSwapFeeHook.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibPermissionedPools} from "../libraries/LibPermissionedPools.sol";

/// @notice Timelock-owned acceptance path for exact creator-authorized permissioned-pool terms.
contract PermissionedPoolAdminFacet is ReentrancyGuard {
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant DOMAIN_NAME_HASH = keccak256(bytes("Statics Permissioned Pools"));
    bytes32 private constant DOMAIN_VERSION_HASH = keccak256(bytes("1"));
    bytes32 private constant TERMS_TYPEHASH = keccak256(
        "PermissionedPoolTerms(bytes32 poolId,bytes32 economicsHash,uint256 nonce,uint256 deadline,bytes32 agreementHash)"
    );
    bytes32 private constant CONTROLLER_REPLACEMENT_TYPEHASH = keccak256(
        "PermissionedPoolControllerReplacement(bytes32 poolId,address currentController,address newController,uint256 nonce,uint256 deadline,bytes32 agreementHash)"
    );

    error PermissionedLiquidityIntegrationNotInstalled();
    error DeadlineExpired(uint256 deadline);
    error InvalidEconomics();
    error InvalidCreatorAuthorization(address creator);
    error InvalidConfigurationNonce(PoolId poolId, uint256 expected, uint256 provided);
    error UnexpectedPoolController(PoolId poolId, address expected, address actual);
    error OnlyPoolCreator(address caller, address creator);
    error PoolAlreadyDecommissioned(PoolId poolId);

    function applyPermissionedPoolTerms(
        PoolId poolId,
        IStaticsPermissionedSwapFeeHook.PoolEconomics calldata economics,
        uint256 nonce,
        uint256 deadline,
        bytes32 agreementHash,
        bytes calldata creatorAuthorization
    ) external nonReentrant {
        LibDiamond.enforceIsContractOwner();
        if (deadline < block.timestamp) revert DeadlineExpired(deadline);
        _validateEconomics(economics);
        LibPermissionedPools.PermissionedPool storage pool = LibPermissionedPools.enforceRegistered(poolId);
        if (pool.configurationNonce != nonce) {
            revert InvalidConfigurationNonce(poolId, pool.configurationNonce, nonce);
        }
        bytes32 digest = _termsDigest(poolId, economics, nonce, deadline, agreementHash);
        if (!SignatureChecker.isValidSignatureNow(pool.creator, digest, creatorAuthorization)) {
            revert InvalidCreatorAuthorization(pool.creator);
        }

        IStaticsPermissionedSwapFeeHook hook = _hook();
        IStaticsPermissionedSwapFeeHook.PoolEconomics memory previous = hook.poolEconomics(poolId);
        pool.configurationNonce = nonce + 1;
        hook.setPoolEconomics(poolId, economics);
        emit IStaticsPermissionedPools.PermissionedPoolTermsChanged(poolId, nonce, agreementHash, previous, economics);
    }

    function replacePermissionedPoolController(
        PoolId poolId,
        address currentController,
        address newController,
        uint256 nonce,
        uint256 deadline,
        bytes32 agreementHash,
        bytes calldata creatorAuthorization
    ) external nonReentrant {
        LibDiamond.enforceIsContractOwner();
        if (deadline < block.timestamp) revert DeadlineExpired(deadline);
        LibPermissionedPools.PermissionedPool storage pool = LibPermissionedPools.enforceRegistered(poolId);
        if (pool.decommissioned) revert PoolAlreadyDecommissioned(poolId);
        if (pool.configurationNonce != nonce) {
            revert InvalidConfigurationNonce(poolId, pool.configurationNonce, nonce);
        }
        IStaticsPermissionedSwapFeeHook hook = _hook();
        address registeredController = hook.poolRegistration(poolId).controller;
        if (registeredController != currentController) {
            revert UnexpectedPoolController(poolId, currentController, registeredController);
        }
        bytes32 digest =
            _controllerReplacementDigest(poolId, currentController, newController, nonce, deadline, agreementHash);
        if (!SignatureChecker.isValidSignatureNow(pool.creator, digest, creatorAuthorization)) {
            revert InvalidCreatorAuthorization(pool.creator);
        }

        pool.configurationNonce = nonce + 1;
        hook.setPoolController(poolId, newController);
        emit IStaticsPermissionedPools.PermissionedPoolControllerReplaced(
            poolId, currentController, newController, nonce, agreementHash
        );
    }

    function invalidatePermissionedConfigurationNonce(PoolId poolId, uint256 nonce) external {
        LibPermissionedPools.PermissionedPool storage pool = LibPermissionedPools.enforceRegistered(poolId);
        if (msg.sender != pool.creator) revert OnlyPoolCreator(msg.sender, pool.creator);
        if (pool.configurationNonce != nonce) {
            revert InvalidConfigurationNonce(poolId, pool.configurationNonce, nonce);
        }
        pool.configurationNonce = nonce + 1;
        emit IStaticsPermissionedPools.PermissionedConfigurationNonceInvalidated(poolId, nonce, nonce + 1);
    }

    function decommissionPermissionedPool(PoolId poolId) external nonReentrant {
        LibDiamond.enforceIsContractOwner();
        LibPermissionedPools.PermissionedPool storage pool = LibPermissionedPools.enforceRegistered(poolId);
        if (pool.decommissioned) revert PoolAlreadyDecommissioned(poolId);
        pool.decommissioned = true;
        _hook().decommissionPool(pool.key);
        emit IStaticsPermissionedPools.PermissionedPoolDecommissioned(poolId);
    }

    function setPermissionedTrustedPeriphery(address periphery, bool trusted) external {
        LibDiamond.enforceIsContractOwner();
        _hook().setTrustedPeriphery(periphery, trusted);
        emit IStaticsPermissionedPools.PermissionedTrustedPeripherySet(periphery, trusted);
    }

    function permissionedTermsDigest(
        PoolId poolId,
        IStaticsPermissionedSwapFeeHook.PoolEconomics calldata economics,
        uint256 nonce,
        uint256 deadline,
        bytes32 agreementHash
    ) external view returns (bytes32 digest) {
        LibPermissionedPools.enforceRegistered(poolId);
        return _termsDigest(poolId, economics, nonce, deadline, agreementHash);
    }

    function permissionedControllerReplacementDigest(
        PoolId poolId,
        address currentController,
        address newController,
        uint256 nonce,
        uint256 deadline,
        bytes32 agreementHash
    ) external view returns (bytes32 digest) {
        LibPermissionedPools.enforceRegistered(poolId);
        return _controllerReplacementDigest(poolId, currentController, newController, nonce, deadline, agreementHash);
    }

    function _termsDigest(
        PoolId poolId,
        IStaticsPermissionedSwapFeeHook.PoolEconomics calldata economics,
        uint256 nonce,
        uint256 deadline,
        bytes32 agreementHash
    ) private view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(TERMS_TYPEHASH, PoolId.unwrap(poolId), _economicsHash(economics), nonce, deadline, agreementHash)
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _controllerReplacementDigest(
        PoolId poolId,
        address currentController,
        address newController,
        uint256 nonce,
        uint256 deadline,
        bytes32 agreementHash
    ) private view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                CONTROLLER_REPLACEMENT_TYPEHASH,
                PoolId.unwrap(poolId),
                currentController,
                newController,
                nonce,
                deadline,
                agreementHash
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _economicsHash(IStaticsPermissionedSwapFeeHook.PoolEconomics calldata economics)
        private
        pure
        returns (bytes32)
    {
        IStaticsPermissionedSwapFeeHook.FeeAllocation calldata a = economics.allocation;
        return keccak256(
            abi.encode(
                economics.venueFeeBps,
                economics.additionalRewardRestrictedMask,
                a.creatorShareBps,
                a.treasuryShareBps,
                a.staticsStakerShareBps,
                a.basketStakerShareBps
            )
        );
    }

    function _domainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, DOMAIN_NAME_HASH, DOMAIN_VERSION_HASH, block.chainid, address(this))
        );
    }

    function _validateEconomics(IStaticsPermissionedSwapFeeHook.PoolEconomics calldata economics) private pure {
        IStaticsPermissionedSwapFeeHook.FeeAllocation calldata a = economics.allocation;
        uint256 total = uint256(a.creatorShareBps) + uint256(a.treasuryShareBps) + uint256(a.staticsStakerShareBps)
            + uint256(a.basketStakerShareBps);
        if (
            economics.venueFeeBps > 10_000 || economics.additionalRewardRestrictedMask > 3 || total != 10_000
                || a.basketStakerShareBps != 0
        ) revert InvalidEconomics();
    }

    function _hook() private view returns (IStaticsPermissionedSwapFeeHook hook) {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (!ls.permissionedIntegrationInstalled) revert PermissionedLiquidityIntegrationNotInstalled();
        hook = IStaticsPermissionedSwapFeeHook(ls.permissionedHook);
    }
}
