// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity 0.8.33;

import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {StaticsBasketTokenFactory} from "../liquidity/StaticsBasketTokenFactory.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibBasketDeployment} from "../libraries/LibBasketDeployment.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/// @notice Install the standalone Basket hook and token factory.
contract PublicHookPolicyFacet {
    error BasketHookAlreadyInstalled();
    event BasketHookInstalled(address indexed basketHook, address basketTokenFactory);

    function installBasketHook(address basketHook, address basketTokenFactory) public {
        LibDiamond.enforceIsContractOwner();
        LibBasketDeployment.DeploymentStorage storage ds = LibBasketDeployment.deploymentStorage();
        if (address(ds.factory) != address(0)) revert BasketHookAlreadyInstalled();
        ds.basketHook = basketHook;
        ds.factory = StaticsBasketTokenFactory(basketTokenFactory);
        IStaticsSwapFeeHook general = IStaticsSwapFeeHook(LibBasketLiquidity.liquidityStorage().hook);
        (uint16 inputFee, uint16 outputFee) = general.defaultFeeRate();
        IStaticsSwapFeeHook(basketHook).setDefaultFeeRate(inputFee, outputFee);
        IStaticsSwapFeeHook(basketHook).setBasketFeeAllocation(general.basketFeeAllocation());
        emit BasketHookInstalled(basketHook, basketTokenFactory);
    }

    function basketHookConfiguration() external view returns (address basketHook, address basketTokenFactory) {
        LibBasketDeployment.DeploymentStorage storage ds = LibBasketDeployment.deploymentStorage();
        return (ds.basketHook, address(ds.factory));
    }
}
