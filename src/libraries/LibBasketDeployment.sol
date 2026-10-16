// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {StaticsBasketTokenFactory} from "../liquidity/StaticsBasketTokenFactory.sol";
import {LibBasket} from "./LibBasket.sol";
import {LibBasketLiquidity} from "./LibBasketLiquidity.sol";
import {LibProtocolPools} from "./LibProtocolPools.sol";
import {LibPublicHookPolicy} from "./LibPublicHookPolicy.sol";
import {LibDiamond} from "./LibDiamond.sol";

library LibBasketDeployment {
    bytes32 private constant STORAGE_POSITION = keccak256("statics.storage.basket.deployment.v1");

    struct PreparedContracts {
        uint256 basketIdPlusOne;
        address token;
        bool finalized;
    }

    struct StagedLaunch {
        bytes32 terms;
        uint256 nextPool;
        uint256 basketShares;
        uint256[] assetDebits;
    }

    struct DeploymentStorage {
        StaticsBasketTokenFactory factory;
        mapping(uint256 basketId => bytes32 id) launching;
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

    /// @dev Prepared economics fail closed on configuration or installed implementation changes.
    function configurationHash(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 deadline
    ) internal view returns (bytes32) {
        return keccak256(abi.encode(params, pools, maxAmountsIn, deadline, environmentHash()));
    }

    function environmentHash() internal view returns (bytes32) {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        return keccak256(
            abi.encode(
                bs.creationFeeAmount,
                LibProtocolPools.protocolPoolStorage().poolCreationFeeAmount,
                bs.treasury,
                address(factory()),
                ls.poolManager,
                ls.hook,
                LibPublicHookPolicy.policyStorage().basketHook,
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

    function begin(bytes32 id, bytes32 configuration, uint256 deadline, address payer, address creator)
        internal
        returns (bytes32)
    {
        StaticsBasketTokenFactory configured = factory();
        StaticsBasketTokenFactory.Intent memory intent =
            StaticsBasketTokenFactory.Intent(payer, creator, configuration, deadline, configured.VERSION());
        if (id == bytes32(0)) return configured.reserveNext(intent);
        StaticsBasketTokenFactory.Preparation memory prepared = configured.preparation(id);
        if (
            (prepared.tokenDeployed
                    && (deploymentStorage().deployed[id].token == address(0)
                        || deploymentStorage().deployed[id].finalized))
                || keccak256(abi.encode(prepared.intent)) != keccak256(abi.encode(intent))
        ) {
            revert PreparationIntentMismatch();
        }
        return id;
    }
}
