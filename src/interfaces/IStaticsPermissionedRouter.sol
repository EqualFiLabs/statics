// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.26 <0.9.0;

import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";

interface IStaticsPermissionedRouter {
    function swapExactInputSingle(IV4Router.ExactInputSingleParams calldata params, uint256 deadline)
        external
        returns (uint256 amountOut);
    function swapExactInput(IV4Router.ExactInputParams calldata params, uint256 deadline)
        external
        returns (uint256 amountOut);
}
