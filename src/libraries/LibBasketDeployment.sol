// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {StaticsBasketFactory} from "../liquidity/StaticsBasketFactory.sol";
import {LibBasket} from "./LibBasket.sol";
import {LibBasketLiquidity} from "./LibBasketLiquidity.sol";
import {LibDiamond} from "./LibDiamond.sol";

library LibBasketDeployment {
    bytes32 private constant STORAGE_POSITION = keccak256("statics.storage.basket.deployment.v1");

    struct DeploymentStorage {
        StaticsBasketFactory factory;
        mapping(uint256 basketId => bytes32 id) launching;
    }

    error BasketFactoryNotInstalled();
    error PreparationIntentMismatch();

    function deploymentStorage() internal pure returns (DeploymentStorage storage ds) {
        bytes32 slot = STORAGE_POSITION;
        assembly ("memory-safe") { ds.slot := slot }
    }

    function factory() internal view returns (StaticsBasketFactory configured) {
        configured = deploymentStorage().factory;
        if (address(configured) == address(0)) revert BasketFactoryNotInstalled();
    }

    /// @dev Prepared economics fail closed on configuration or installed implementation changes.
    function configurationHash(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 deadline
    ) internal view returns (bytes32) {
        return keccak256(abi.encode(params, pools, maxAmountsIn, deadline, _environmentHash()));
    }

    function _environmentHash() private view returns (bytes32) {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        return keccak256(
            abi.encode(
                bs.creationFeeAmount,
                bs.treasury,
                address(factory()),
                ls.poolManager,
                ls.hook,
                ls.manager,
                _implementationHash()
            )
        );
    }

    function _implementationHash() private view returns (bytes32 commitment) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        commitment = keccak256(abi.encode(ds.facetAddresses));
        for (uint256 i; i < ds.facetAddresses.length; ++i) {
            address facet = ds.facetAddresses[i];
            commitment = keccak256(
                abi.encode(commitment, facet, facet.codehash, ds.facetFunctionSelectors[facet].functionSelectors)
            );
        }
    }

    function begin(
        bytes32 id,
        bytes32 configuration,
        uint256 deadline,
        uint256 hookCount,
        address payer,
        address creator
    ) internal returns (bytes32) {
        StaticsBasketFactory configured = factory();
        StaticsBasketFactory.Intent memory intent =
            StaticsBasketFactory.Intent(payer, creator, configuration, deadline, configured.VERSION());
        if (id == bytes32(0)) return configured.reserveQueued(intent, hookCount);
        StaticsBasketFactory.Preparation memory prepared = configured.preparation(id);
        if (
            prepared.tokenDeployed || prepared.hookSalts.length != hookCount
                || keccak256(abi.encode(prepared.intent)) != keccak256(abi.encode(intent))
        ) {
            revert PreparationIntentMismatch();
        }
        return id;
    }
}
