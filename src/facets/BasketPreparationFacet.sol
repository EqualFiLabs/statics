// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {StaticsBasketTokenFactory} from "../liquidity/StaticsBasketTokenFactory.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketDeployment} from "../libraries/LibBasketDeployment.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

contract BasketPreparationFacet is ReentrancyGuard {
    error InvalidPreparationShape();
    error LaunchDeadlineExpired(uint256 deadline, uint256 timestamp);

    event PreparedBasketTokenDeployed(bytes32 indexed preparationId, uint256 indexed basketId, address token);

    /// @notice Deploy an unfunded restricted token and retain its launch terms for source verification before finalization.
    /// @dev Reserved basket IDs may leave holes after expiry. No basket is usable until finalization.
    function prepareBasketToken(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 deadline,
        uint256 tokenNonce
    ) external nonReentrant returns (bytes32 id, uint256 basketId, address token) {
        LibProtocolPools.enforcePoolCreationAllowed(msg.sender);
        if (LibBasket.basketStorage().creationFeeAmount == 0) LibDiamond.enforceIsContractOwner();
        if (
            params.assets.length == 0 || params.assets.length > LibBasket.MAX_ASSETS
                || params.assets.length != pools.length || pools.length != maxAmountsIn.length
        ) revert InvalidPreparationShape();
        if (block.timestamp > deadline) revert LaunchDeadlineExpired(deadline, block.timestamp);
        bytes32 configuration = LibBasketDeployment.configurationHash(params, pools, maxAmountsIn, deadline);
        return _deploy(params, configuration, tokenNonce);
    }

    function _deploy(IStaticsBasket.CreateBasketParams calldata params, bytes32 configuration, uint256 tokenNonce)
        private
        returns (bytes32 id, uint256 basketId, address token)
    {
        StaticsBasketTokenFactory configured = LibBasketDeployment.factory();
        id = configured.preparedSaltFor(msg.sender, configuration, tokenNonce);
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        basketId = bs.basketCount++;
        token = configured.deployBasketToken(id, params.name, params.symbol, basketId);
        LibBasket.registerToken(token, basketId);
        LibBasketDeployment.deploymentStorage().deployed[id] =
            LibBasketDeployment.PreparedContracts(basketId + 1, token, false, msg.sender, configuration);
        emit PreparedBasketTokenDeployed(id, basketId, token);
    }

    function preparedBasketContracts(bytes32 id)
        external
        view
        returns (uint256 basketId, address token, bool finalized)
    {
        LibBasketDeployment.PreparedContracts storage deployed = LibBasketDeployment.deploymentStorage().deployed[id];
        return (deployed.basketIdPlusOne == 0 ? 0 : deployed.basketIdPlusOne - 1, deployed.token, deployed.finalized);
    }

    function basketCreationConfigurationHash(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 deadline
    ) external pure returns (bytes32) {
        return LibBasketDeployment.configurationHash(params, pools, maxAmountsIn, deadline);
    }
}
