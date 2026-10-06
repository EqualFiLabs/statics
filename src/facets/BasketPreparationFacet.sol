// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {StaticsBasketFactory} from "../liquidity/StaticsBasketFactory.sol";
import {LibBasketDeployment} from "../libraries/LibBasketDeployment.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

contract BasketPreparationFacet is ReentrancyGuard {
    error InvalidBasketFactory();
    error BasketFactoryAlreadyInstalled();
    error InvalidPreparationShape();

    event BasketFactoryInstalled(address indexed factory);

    function installBasketFactory(address target) external {
        LibDiamond.enforceIsContractOwner();
        LibBasketDeployment.DeploymentStorage storage ds = LibBasketDeployment.deploymentStorage();
        if (address(ds.factory) != address(0)) revert BasketFactoryAlreadyInstalled();
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        StaticsBasketFactory configured = StaticsBasketFactory(target);
        if (
            !ls.integrationInstalled || target.code.length == 0 || configured.staticsDiamond() != address(this)
                || address(configured.poolManager()) != ls.poolManager || address(configured.feePolicy()) != ls.hook
                || configured.VERSION() != 1
        ) revert InvalidBasketFactory();
        ds.factory = configured;
        emit BasketFactoryInstalled(target);
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
        uint256 tokenNonce,
        uint256[] calldata hookNonces
    ) external nonReentrant returns (bytes32 id, address token) {
        if (
            params.assets.length != pools.length || pools.length != hookNonces.length
                || maxAmountsIn.length != pools.length
        ) revert InvalidPreparationShape();
        StaticsBasketFactory configured = LibBasketDeployment.factory();
        StaticsBasketFactory.Intent memory intent = StaticsBasketFactory.Intent(
            msg.sender,
            msg.sender,
            LibBasketDeployment.configurationHash(params, pools, maxAmountsIn, deadline),
            deadline,
            configured.VERSION()
        );
        id = configured.reserve(intent, tokenNonce, hookNonces);
        (token,) = configured.predict(configured.preparedSaltFor(intent, tokenNonce));
    }
}
