// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {CalldataDecoder} from "@uniswap/v4-periphery/src/libraries/CalldataDecoder.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IStaticsPermissionedSwapFeeHook} from "../interfaces/IStaticsPermissionedSwapFeeHook.sol";
import {IVenueController} from "../interfaces/IVenueController.sol";
import {PermissionedPositionClaims} from "./PermissionedPositionClaims.sol";

/// @notice Non-transferable, owner-held v4 positions for permissioned Statics venues.
/// @dev Standard decreases, collections, and burns remain owner-controlled. A venue operator may
/// force a burn only while its controller reports the pool halted; proceeds become
/// PoolManager-claim-backed owner credit for separate withdrawal.
contract StaticsPermissionedPositionManager is PositionManager {
    using CalldataDecoder for bytes;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

    uint256 private constant LIQUIDITY_ALLOWED = 1 << 1;

    IStaticsPermissionedSwapFeeHook public immutable permissionedHook;
    PermissionedPositionClaims public immutable positionClaims;

    error PositionTransferDisabled();
    error InvalidPermissionedPool(address hook);
    error InvalidMintOwner(address owner, address caller);
    error PositionOwnerNotEligible(PoolId poolId, address owner);
    error OnlyPositionClaims(address caller);

    constructor(
        IPoolManager manager,
        IAllowanceTransfer permit2_,
        uint256 unsubscribeGasLimit,
        IPositionDescriptor descriptor,
        IWETH9 weth9,
        IStaticsPermissionedSwapFeeHook hook
    ) PositionManager(manager, permit2_, unsubscribeGasLimit, descriptor, weth9) {
        permissionedHook = hook;
        positionClaims = new PermissionedPositionClaims(manager, address(this), hook);
    }

    function transferFrom(address, address, uint256) public pure override {
        revert PositionTransferDisabled();
    }

    /// @notice Executes the state-sensitive burn leg of a claims-authorized forced unwind.
    /// @dev Operator authorization, halted-pool validation, and owner settlement live in the claims companion.
    function executeForceUnwind(uint256 tokenId, bytes calldata unlockData) external isNotLocked {
        if (msg.sender != address(positionClaims)) revert OnlyPositionClaims(msg.sender);
        _detachSubscriber(tokenId);
        getApproved[tokenId] = msg.sender;
        poolManager.unlock(unlockData);
    }

    function _handleAction(uint256 action, bytes calldata params) internal override {
        if (action == Actions.MINT_POSITION) {
            (,,,,,, address owner,) = params.decodeMintParams();
            _enforceMintOwner(owner);
        } else if (action == Actions.MINT_POSITION_FROM_DELTAS) {
            (,,,,, address owner,) = params.decodeMintFromDeltasParams();
            _enforceMintOwner(owner);
        } else if (action == Actions.INCREASE_LIQUIDITY) {
            (uint256 tokenId, uint256 liquidity,,,) = params.decodeModifyLiquidityParams();
            if (liquidity != 0) _enforceIncreaseOwner(tokenId);
        } else if (action == Actions.INCREASE_LIQUIDITY_FROM_DELTAS) {
            (uint256 tokenId,,,) = params.decodeIncreaseLiquidityFromDeltasParams();
            _enforceIncreaseFromDeltasOwner(tokenId);
        }
        super._handleAction(action, params);
    }

    function _enforceMintOwner(address owner) private view {
        address caller = msgSender();
        if (owner != caller && owner != ActionConstants.MSG_SENDER) revert InvalidMintOwner(owner, caller);
    }

    function _enforceIncreaseOwner(uint256 tokenId) private view {
        (PoolKey memory key,) = getPoolAndPositionInfo(tokenId);
        if (address(key.hooks) != address(permissionedHook)) revert InvalidPermissionedPool(address(key.hooks));
        PoolId poolId = key.toId();
        address owner = ownerOf(tokenId);
        IStaticsPermissionedSwapFeeHook.PoolRegistration memory registration = permissionedHook.poolRegistration(poolId);
        if (IVenueController(registration.controller).permissions(poolId, owner) & LIQUIDITY_ALLOWED == 0) {
            revert PositionOwnerNotEligible(poolId, owner);
        }
    }

    function _enforceIncreaseFromDeltasOwner(uint256 tokenId) private view {
        (PoolKey memory key,) = getPoolAndPositionInfo(tokenId);
        if (_getFullCredit(key.currency0) == 0 && _getFullCredit(key.currency1) == 0) return;
        _enforceIncreaseOwner(tokenId);
    }

    function _detachSubscriber(uint256 tokenId) private {
        if (!positionInfo[tokenId].hasSubscriber()) return;
        address detached = address(subscriber[tokenId]);
        _setUnsubscribed(tokenId);
        delete subscriber[tokenId];
        emit Unsubscription(tokenId, detached);
    }
}
