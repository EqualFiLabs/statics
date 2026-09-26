// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {V4Router} from "@uniswap/v4-periphery/src/V4Router.sol";
import {Permit2Forwarder} from "@uniswap/v4-periphery/src/base/Permit2Forwarder.sol";
import {ReentrancyLock} from "@uniswap/v4-periphery/src/base/ReentrancyLock.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {IStaticsPermissionedRouter} from "../interfaces/IStaticsPermissionedRouter.sol";

/// @notice Narrow exact-input router for permissioned Statics pools.
/// @dev Settlement and output always resolve against the caller returned by `msgSender`; callers
/// cannot supply an arbitrary recipient or arbitrary v4 action sequence.
contract StaticsPermissionedRouter is IStaticsPermissionedRouter, V4Router, Permit2Forwarder, ReentrancyLock {
    address public immutable permissionedHook;

    error DeadlineExpired(uint256 deadline);
    error InvalidPermissionedPoolHook(address actual, address expected);
    error NativeCurrencyUnsupported();

    constructor(IPoolManager manager, IAllowanceTransfer permit2_, address hook)
        V4Router(manager)
        Permit2Forwarder(permit2_)
    {
        if (hook == address(0) || hook.code.length == 0) {
            revert InvalidPermissionedPoolHook(hook, address(0));
        }
        permissionedHook = hook;
    }

    function swapExactInputSingle(IV4Router.ExactInputSingleParams calldata params, uint256 deadline)
        external
        isNotLocked
        returns (uint256 amountOut)
    {
        if (deadline < block.timestamp) revert DeadlineExpired(deadline);
        if (address(params.poolKey.hooks) != permissionedHook) {
            revert InvalidPermissionedPoolHook(address(params.poolKey.hooks), permissionedHook);
        }
        Currency input = params.zeroForOne ? params.poolKey.currency0 : params.poolKey.currency1;
        Currency output = params.zeroForOne ? params.poolKey.currency1 : params.poolKey.currency0;
        _enforceErc20(input);
        _enforceErc20(output);
        uint256 beforeBalance = output.balanceOf(msg.sender);

        bytes memory actions = abi.encodePacked(
            bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)),
            bytes1(uint8(Actions.SETTLE_ALL)),
            bytes1(uint8(Actions.TAKE_ALL))
        );
        bytes[] memory actionParams = new bytes[](3);
        actionParams[0] = abi.encode(params);
        actionParams[1] = abi.encode(input, uint256(params.amountIn));
        actionParams[2] = abi.encode(output, uint256(params.amountOutMinimum));
        poolManager.unlock(abi.encode(actions, actionParams));
        amountOut = output.balanceOf(msg.sender) - beforeBalance;
    }

    function swapExactInput(IV4Router.ExactInputParams calldata params, uint256 deadline)
        external
        isNotLocked
        returns (uint256 amountOut)
    {
        if (deadline < block.timestamp) revert DeadlineExpired(deadline);
        uint256 pathLength = params.path.length;
        if (pathLength == 0) revert InvalidPermissionedPoolHook(address(0), permissionedHook);
        for (uint256 i; i < pathLength; ++i) {
            if (address(params.path[i].hooks) != permissionedHook) {
                revert InvalidPermissionedPoolHook(address(params.path[i].hooks), permissionedHook);
            }
            _enforceErc20(params.path[i].intermediateCurrency);
        }
        _enforceErc20(params.currencyIn);
        Currency output = params.path[pathLength - 1].intermediateCurrency;
        uint256 beforeBalance = output.balanceOf(msg.sender);

        bytes memory actions = abi.encodePacked(
            bytes1(uint8(Actions.SWAP_EXACT_IN)), bytes1(uint8(Actions.SETTLE_ALL)), bytes1(uint8(Actions.TAKE_ALL))
        );
        bytes[] memory actionParams = new bytes[](3);
        actionParams[0] = abi.encode(params);
        actionParams[1] = abi.encode(params.currencyIn, uint256(params.amountIn));
        actionParams[2] = abi.encode(output, uint256(params.amountOutMinimum));
        poolManager.unlock(abi.encode(actions, actionParams));
        amountOut = output.balanceOf(msg.sender) - beforeBalance;
    }

    function msgSender() public view override returns (address) {
        return _getLocker();
    }

    function _pay(Currency currency, address payer, uint256 amount) internal override {
        if (payer == address(this)) {
            currency.transfer(address(poolManager), amount);
        } else {
            permit2.transferFrom(payer, address(poolManager), uint160(amount), Currency.unwrap(currency));
        }
    }

    function _enforceErc20(Currency currency) private pure {
        if (currency.isAddressZero()) revert NativeCurrencyUnsupported();
    }
}
