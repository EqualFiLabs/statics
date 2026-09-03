// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IMorphoBlue} from "../interfaces/IMorphoBlue.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal deterministic account that delegates all Morpho position management to one Statics Diamond.
contract StaticsMorphoAccount {
    address public immutable diamond;

    error UnauthorizedCaller(address caller);
    error TokenTransferFailed(address token);

    constructor(address morpho, address diamond_) {
        diamond = diamond_;
        IMorphoBlue(morpho).setAuthorization(diamond_, true);
    }

    function sweepToken(address token, address receiver, uint256 amount) external {
        if (msg.sender != diamond) revert UnauthorizedCaller(msg.sender);
        if (!IERC20(token).transfer(receiver, amount)) revert TokenTransferFailed(token);
    }
}
