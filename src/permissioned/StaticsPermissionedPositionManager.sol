// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
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
    using PoolIdLibrary for PoolKey;

    IStaticsPermissionedSwapFeeHook public immutable permissionedHook;
    PermissionedPositionClaims public immutable positionClaims;

    error PositionTransferDisabled();
    error InvalidPermissionedPool(address hook);
    error InvalidMintOwner(address owner, address caller);

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

    function forceUnwind(uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData)
        external
        isNotLocked
    {
        (PoolKey memory key,) = getPoolAndPositionInfo(tokenId);
        if (address(key.hooks) != address(permissionedHook)) revert InvalidPermissionedPool(address(key.hooks));
        PoolId poolId = key.toId();
        positionClaims.enforceForceUnwind(poolId, msg.sender);

        address owner = ownerOf(tokenId);
        uint256 balance0Before = IERC20(Currency.unwrap(key.currency0)).balanceOf(address(positionClaims));
        uint256 balance1Before = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(positionClaims));
        getApproved[tokenId] = msg.sender;

        bytes memory actions = abi.encodePacked(bytes1(uint8(Actions.BURN_POSITION)), bytes1(uint8(Actions.TAKE_PAIR)));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, amount0Min, amount1Min, hookData);
        params[1] = abi.encode(key.currency0, key.currency1, address(positionClaims));
        poolManager.unlock(abi.encode(actions, params));

        uint256 amount0 = IERC20(Currency.unwrap(key.currency0)).balanceOf(address(positionClaims)) - balance0Before;
        uint256 amount1 = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(positionClaims)) - balance1Before;
        positionClaims.deliverOrCredit(poolId, owner, key.currency0, amount0);
        positionClaims.deliverOrCredit(poolId, owner, key.currency1, amount1);
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
