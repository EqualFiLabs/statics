// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {StaticsBasketTokenFactory} from "../liquidity/StaticsBasketTokenFactory.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibBasketDeployment} from "../libraries/LibBasketDeployment.sol";
import {LibPublicHookPolicy} from "../libraries/LibPublicHookPolicy.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/// @notice Install independently governed, standalone public-market hooks.
contract PublicHookPolicyFacet {
    uint160 private constant GENERAL_FLAGS = 0x10ec;
    uint160 private constant BASKET_FLAGS = 0x1fec;
    uint160 private constant ALL_HOOK_BITS = (1 << 14) - 1;

    error PublicHooksAlreadyInstalled();
    error InvalidPublicHooks();
    event PublicHooksInstalled(
        address indexed generalHook, address indexed basketHook, address basketTokenFactory, address legacyHook
    );

    function installPublicHooks(address generalHook, address basketHook, address basketTokenFactory) public {
        LibDiamond.enforceIsContractOwner();
        LibPublicHookPolicy.PolicyStorage storage ps = LibPublicHookPolicy.policyStorage();
        LibBasketDeployment.DeploymentStorage storage ds = LibBasketDeployment.deploymentStorage();
        if (ps.initialized || address(ds.factory) != address(0)) revert PublicHooksAlreadyInstalled();
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (!ls.integrationInstalled || basketTokenFactory.code.length == 0 || generalHook == basketHook) {
            revert InvalidPublicHooks();
        }
        address weth = IStaticsSwapFeeHook(ls.hook).weth();
        _validate(generalHook, GENERAL_FLAGS, ls.poolManager, weth);
        _validate(basketHook, BASKET_FLAGS, ls.poolManager, weth);
        StaticsBasketTokenFactory factory = StaticsBasketTokenFactory(basketTokenFactory);
        if (
            factory.staticsDiamond() != address(this) || address(factory.poolManager()) != ls.poolManager
                || factory.VERSION() != 1
        ) revert InvalidPublicHooks();
        ps.generalHook = generalHook;
        ps.basketHook = basketHook;
        ps.legacyHook = ls.hook;
        ps.weth = weth;
        ps.initialized = true;
        ds.factory = factory;
        IStaticsSwapFeeHook legacy = IStaticsSwapFeeHook(ls.hook);
        (uint16 inputFee, uint16 outputFee) = legacy.defaultFeeRate();
        IStaticsSwapFeeHook(generalHook).setDefaultFeeRate(inputFee, outputFee);
        IStaticsSwapFeeHook(basketHook).setDefaultFeeRate(inputFee, outputFee);
        IStaticsSwapFeeHook(generalHook).setGeneralFeeAllocation(legacy.generalFeeAllocation());
        IStaticsSwapFeeHook(basketHook).setBasketFeeAllocation(legacy.basketFeeAllocation());
        emit PublicHooksInstalled(generalHook, basketHook, basketTokenFactory, ls.hook);
    }

    function _validate(address target, uint160 flags, address manager, address weth) private view {
        if (target.code.length == 0 || uint160(target) & ALL_HOOK_BITS != flags) revert InvalidPublicHooks();
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(target);
        if (
            hook.staticsDiamond() != address(this) || hook.weth() != weth
                || address(PublicHookBinding(target).poolManager()) != manager
                || PublicHookBinding(target).VERSION() != 1
        ) revert InvalidPublicHooks();
    }

    function publicHookConfiguration()
        external
        view
        returns (address generalHook, address basketHook, address basketTokenFactory, address legacyHook)
    {
        LibPublicHookPolicy.PolicyStorage storage ps = LibPublicHookPolicy.policyStorage();
        return (ps.generalHook, ps.basketHook, address(LibBasketDeployment.deploymentStorage().factory), ps.legacyHook);
    }
}

interface PublicHookBinding {
    function poolManager() external view returns (IPoolManager);
    function VERSION() external view returns (uint256);
}
