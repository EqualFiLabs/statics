// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity 0.8.33;

import {IStaticsBasket} from "./IStaticsBasket.sol";

interface IStaticsBasketStaging {
    event BasketLaunchProgress(uint256 indexed basketId, uint256 completedPools, uint256 totalPools);
    event BasketLaunchCancelled(uint256 indexed basketId);

    /// @notice Start and fund an explicitly bounded first batch. Zero preparationId deploys the basket token.
    function createBasketStaged(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 deadline,
        bytes32 preparationId,
        uint256 poolCount
    ) external payable returns (uint256 basketId, address token);

    function continueBasketLaunch(
        uint256 basketId,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 deadline,
        uint256 poolCount
    ) external payable;

    /// @notice Cancel into exit-only. Contributions remain protocol POL and use existing unwind rails.
    function cancelBasketLaunch(uint256 basketId) external;

    function basketLaunchProgress(uint256 basketId)
        external
        view
        returns (uint256 completedPools, uint256 basketShares, uint256[] memory assetDebits);
}
