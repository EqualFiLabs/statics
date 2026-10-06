// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {StaticsBasketFactory} from "../liquidity/StaticsBasketFactory.sol";
import {LibBasketDeployment} from "../libraries/LibBasketDeployment.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketLaunchMath} from "../libraries/LibBasketLaunchMath.sol";
import {IStaticsBasketDelegation} from "../interfaces/IStaticsBasketDelegation.sol";
import {LibBasketDelegation} from "../libraries/LibBasketDelegation.sol";

contract BasketPreparationFacet is ReentrancyGuard {
    error InvalidBasketFactory();
    error BasketFactoryAlreadyInstalled();
    error InvalidPreparationShape();

    event BasketFactoryInstalled(address indexed factory);

    function creationAuthorizationDigest(IStaticsBasketDelegation.Authorization calldata authorization)
        external
        view
        returns (bytes32)
    {
        return LibBasketDelegation.digest(authorization);
    }

    function creationNonceUsed(address creator, uint256 nonce) external view returns (bool) {
        return LibBasketDelegation.used(creator, nonce);
    }

    function invalidateCreationNonces(uint256 word, uint256 mask) external {
        LibBasketDelegation.delegationStorage().nonces[msg.sender][word] |= mask;
        emit LibBasketDelegation.CreationNoncesInvalidated(msg.sender, word, mask);
    }

    function prepareBasketCreationFor(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maximums,
        uint256 tokenNonce,
        uint256[] calldata hookNonces,
        IStaticsBasketDelegation.Authorization calldata authorization,
        bytes calldata signature
    ) external nonReentrant returns (bytes32 id, address token) {
        if (
            params.assets.length != pools.length || pools.length != hookNonces.length || maximums.length != pools.length
        ) revert InvalidPreparationShape();
        bytes32 configuration = LibBasketDeployment.configurationHash(params, pools, maximums, authorization.deadline);
        LibBasketDelegation.validate(authorization, signature, configuration, false);
        StaticsBasketFactory configured = LibBasketDeployment.factory();
        StaticsBasketFactory.Intent memory intent = StaticsBasketFactory.Intent(
            msg.sender, authorization.creator, configuration, authorization.deadline, configured.VERSION()
        );
        id = configured.reserve(intent, tokenNonce, hookNonces);
        if (id != authorization.preparationId) revert LibBasketDelegation.InvalidCreationAuthorization();
        (token,) = configured.predict(configured.preparedSaltFor(intent, tokenNonce));
    }

    function previewBasketLaunch(
        bytes32 preparationId,
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maximums,
        uint256 deadline
    ) external view returns (address token, LibBasketLaunchMath.Requirements memory requirements) {
        StaticsBasketFactory configured = LibBasketDeployment.factory();
        StaticsBasketFactory.Preparation memory prepared = configured.preparation(preparationId);
        if (
            prepared.tokenDeployed || prepared.intent.deadline != deadline || block.timestamp > deadline
                || prepared.intent.configurationHash
                    != LibBasketDeployment.configurationHash(params, pools, maximums, deadline)
                || prepared.hookSalts.length != params.assets.length
        ) revert LibBasketDeployment.PreparationIntentMismatch();
        (token,) = configured.predict(prepared.tokenSalt);
        requirements = LibBasketLaunchMath.preview(token, params, pools, LibBasket.basketStorage().creationFeeAmount);
        if (maximums.length != requirements.totalAmounts.length) revert InvalidPreparationShape();
        for (uint256 i; i < maximums.length; ++i) {
            if (requirements.totalAmounts[i] > maximums[i]) revert InvalidPreparationShape();
        }
    }

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
