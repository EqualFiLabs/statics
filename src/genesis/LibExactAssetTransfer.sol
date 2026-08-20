// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

library LibExactAssetTransfer {
    using SafeERC20 for IERC20;

    error IncompatibleAssetTransfer(address asset, uint256 requested, uint256 spent, uint256 received);

    function pullExact(IERC20 token, address from, uint256 amount) internal {
        uint256 fromBefore = token.balanceOf(from);
        uint256 receiverBefore = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 fromAfter = token.balanceOf(from);
        uint256 receiverAfter = token.balanceOf(address(this));
        uint256 spent = fromBefore >= fromAfter ? fromBefore - fromAfter : 0;
        uint256 received = receiverAfter >= receiverBefore ? receiverAfter - receiverBefore : 0;
        if (spent != amount || received != amount) {
            revert IncompatibleAssetTransfer(address(token), amount, spent, received);
        }
    }

    function pushExact(IERC20 token, address receiver, uint256 amount) internal {
        uint256 senderBefore = token.balanceOf(address(this));
        uint256 receiverBefore = token.balanceOf(receiver);
        token.safeTransfer(receiver, amount);
        uint256 senderAfter = token.balanceOf(address(this));
        uint256 receiverAfter = token.balanceOf(receiver);
        uint256 spent = senderBefore >= senderAfter ? senderBefore - senderAfter : 0;
        uint256 received = receiverAfter >= receiverBefore ? receiverAfter - receiverBefore : 0;
        if (spent != amount || received != amount) {
            revert IncompatibleAssetTransfer(address(token), amount, spent, received);
        }
    }
}
