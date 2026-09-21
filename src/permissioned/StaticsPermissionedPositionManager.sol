// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {CalldataDecoder} from "@uniswap/v4-periphery/src/libraries/CalldataDecoder.sol";
import {IStaticsPermissionedSwapFeeHook} from "../interfaces/IStaticsPermissionedSwapFeeHook.sol";
import {PermissionedPositionClaims} from "./PermissionedPositionClaims.sol";

/// @notice Non-transferable, owner-held v4 positions for permissioned Statics venues.
/// @dev Standard decreases, collections, and burns remain owner-controlled. A venue operator may
/// force a burn only while its controller reports the pool halted; proceeds go to the owner or to
/// a PoolManager-claim-backed owner credit if the token cannot deliver to that owner.
contract StaticsPermissionedPositionManager is PositionManager {
    using CalldataDecoder for bytes;

    IStaticsPermissionedSwapFeeHook public immutable permissionedHook;
    PermissionedPositionClaims public immutable positionClaims;

    error PositionTransferDisabled();
    error InvalidMintOwner(address owner, address caller);
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
        }
        super._handleAction(action, params);
    }

    function _enforceMintOwner(address owner) private view {
        address caller = msgSender();
        if (owner != caller && owner != ActionConstants.MSG_SENDER) revert InvalidMintOwner(owner, caller);
    }
}
