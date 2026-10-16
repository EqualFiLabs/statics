// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {StaticsBasketTokenFactory} from "../liquidity/StaticsBasketTokenFactory.sol";
import {LibRestrictedBasket} from "../libraries/LibRestrictedBasket.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketDeployment} from "../libraries/LibBasketDeployment.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

contract BasketPreparationFacet is ReentrancyGuard {
    error InvalidPreparationShape();

    event PreparedBasketContractsDeployed(bytes32 indexed preparationId, uint256 indexed basketId, address token);

    /// @notice Deploy uninitialized, unfunded identities for source verification before finalization.
    /// @dev Reserved basket IDs may leave holes after expiry. No basket is usable until finalization.
    function deployPreparedBasketContracts(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 deadline,
        bytes32 id
    ) external nonReentrant returns (uint256 basketId, address token) {
        LibProtocolPools.enforcePoolCreationAllowed(msg.sender);
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        if (bs.creationFeeAmount == 0) LibDiamond.enforceIsContractOwner();
        if (
            id == bytes32(0) || params.assets.length == 0 || params.assets.length > LibBasket.MAX_ASSETS
                || params.assets.length != pools.length || pools.length != maxAmountsIn.length
        ) revert InvalidPreparationShape();
        LibBasketDeployment.DeploymentStorage storage ds = LibBasketDeployment.deploymentStorage();
        if (ds.deployed[id].token != address(0)) revert LibBasketDeployment.PreparationIntentMismatch();
        LibBasketDeployment.begin(
            id,
            LibBasketDeployment.configurationHash(params, pools, maxAmountsIn, deadline),
            deadline,
            msg.sender,
            msg.sender
        );
        basketId = bs.basketCount++;
        token = ds.factory.deployBasketToken(id, params.name, params.symbol, basketId);
        LibRestrictedBasket.register(token, basketId);
        ds.deployed[id] = LibBasketDeployment.PreparedContracts(basketId + 1, token, false);
        emit PreparedBasketContractsDeployed(id, basketId, token);
    }

    function preparedBasketContracts(bytes32 id)
        external
        view
        returns (uint256 basketId, address token, bool finalized)
    {
        LibBasketDeployment.PreparedContracts storage deployed = LibBasketDeployment.deploymentStorage().deployed[id];
        return (deployed.basketIdPlusOne == 0 ? 0 : deployed.basketIdPlusOne - 1, deployed.token, deployed.finalized);
    }

    function basketTokenFactory() external view returns (address) {
        return address(LibBasketDeployment.deploymentStorage().factory);
    }

    function basketFactory() external view returns (address) {
        return address(LibBasketDeployment.deploymentStorage().factory);
    }

    function basketCreationConfigurationHash(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 deadline
    ) external view returns (bytes32) {
        return LibBasketDeployment.configurationHash(params, pools, maxAmountsIn, deadline);
    }

    function prepareBasketCreation(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 deadline,
        uint256 tokenNonce
    ) external nonReentrant returns (bytes32 id, address token) {
        if (params.assets.length != pools.length || maxAmountsIn.length != pools.length) {
            revert InvalidPreparationShape();
        }
        LibProtocolPools.enforcePoolCreationAllowed(msg.sender);
        StaticsBasketTokenFactory configured = LibBasketDeployment.factory();
        StaticsBasketTokenFactory.Intent memory intent = StaticsBasketTokenFactory.Intent(
            msg.sender,
            msg.sender,
            LibBasketDeployment.configurationHash(params, pools, maxAmountsIn, deadline),
            deadline,
            configured.VERSION()
        );
        id = configured.reserve(intent, tokenNonce);
        (token,) = configured.predict(configured.preparedSaltFor(intent, tokenNonce));
    }
}
