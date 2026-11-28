// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity 0.8.33;

import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {StaticsBasketTokenFactory} from "../liquidity/StaticsBasketTokenFactory.sol";

library LibBasketDeployment {
    bytes32 private constant STORAGE_POSITION = keccak256("statics.storage.basket.deployment");

    struct PreparedContracts {
        uint256 basketIdPlusOne;
        address token;
        bool finalized;
        address creator;
        bytes32 configurationHash;
    }

    struct StagedLaunch {
        bytes32 terms;
        uint256 nextPool;
        uint256 basketShares;
        uint256[] assetDebits;
    }

    struct DeploymentStorage {
        StaticsBasketTokenFactory factory;
        address basketHook;
        mapping(bytes32 id => PreparedContracts contracts) deployed;
        mapping(uint256 basketId => StagedLaunch launch) staged;
    }

    error BasketFactoryNotInstalled();
    error PreparationIntentMismatch();

    function deploymentStorage() internal pure returns (DeploymentStorage storage ds) {
        bytes32 slot = STORAGE_POSITION;
        assembly ("memory-safe") { ds.slot := slot }
    }

    function factory() internal view returns (StaticsBasketTokenFactory configured) {
        configured = deploymentStorage().factory;
        if (address(configured) == address(0)) revert BasketFactoryNotInstalled();
    }

    /// @dev A prepared token is bound only to the creator's basket and launch terms.
    function configurationHash(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(params, pools, maxAmountsIn, deadline));
    }
}
