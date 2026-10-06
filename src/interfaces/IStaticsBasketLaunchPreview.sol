// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IStaticsBasket} from "./IStaticsBasket.sol";
import {LibBasketLaunchMath} from "../libraries/LibBasketLaunchMath.sol";

interface IStaticsBasketLaunchPreview {
    function previewBasketLaunch(
        bytes32 preparationId,
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maximums,
        uint256 deadline
    ) external view returns (address token, LibBasketLaunchMath.Requirements memory requirements);
}
