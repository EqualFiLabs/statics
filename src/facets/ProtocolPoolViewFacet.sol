// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {LibPermissionedPools} from "../libraries/LibPermissionedPools.sol";

/// @notice Bounded protocol-pool resolution and configuration views.
contract ProtocolPoolViewFacet {
    error LiquidityIntegrationNotInstalled();
    error PublicProtocolPoolRequired(PoolId poolId);

    function protocolPool(PoolId poolId) external view returns (IStaticsProtocolPools.ProtocolPoolView memory pool) {
        (IStaticsProtocolPools.ProtocolPoolKind kind, PoolKey memory key, uint256 basketId, address basketAsset) =
            LibProtocolPools.resolve(poolId);
        bool registered = kind != IStaticsProtocolPools.ProtocolPoolKind.None;
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(_liquidityStorage().hook);
        bool permissioned = kind == IStaticsProtocolPools.ProtocolPoolKind.PermissionedGeneral;
        pool = IStaticsProtocolPools.ProtocolPoolView({
            poolId: poolId,
            key: key,
            kind: kind,
            decommissioned: permissioned
                ? LibPermissionedPools.resolve(poolId).decommissioned
                : registered && hook.poolDecommissioned(poolId),
            basketId: basketId,
            basketAsset: basketAsset,
            creator: LibProtocolPools.creatorOf(poolId),
            permanentLiquidity: registered && !permissioned ? hook.lockedLiquidity(poolId) : 0
        });
    }

    function isProtocolPool(PoolId poolId) external view returns (bool registered) {
        (IStaticsProtocolPools.ProtocolPoolKind kind,,,) = LibProtocolPools.resolve(poolId);
        return kind != IStaticsProtocolPools.ProtocolPoolKind.None;
    }

    function poolCreationFee() external view returns (uint256 amount) {
        return LibProtocolPools.protocolPoolStorage().poolCreationFeeAmount;
    }

    function isPoolCreationNonceUsed(address creator, uint256 nonce) external view returns (bool used) {
        return LibProtocolPools.protocolPoolStorage().poolCreationNonceUsed[creator][nonce];
    }

    function basketFeeAllocation() external view returns (IStaticsProtocolPools.BasketFeeAllocation memory allocation) {
        IStaticsSwapFeeHook.BasketFeeAllocation memory stored =
            IStaticsSwapFeeHook(_liquidityStorage().hook).basketFeeAllocation();
        allocation = IStaticsProtocolPools.BasketFeeAllocation({
            polShareBps: stored.polShareBps,
            basketStakerShareBps: stored.basketStakerShareBps,
            staticsStakerShareBps: stored.staticsStakerShareBps,
            treasuryShareBps: stored.treasuryShareBps
        });
    }

    function generalFeeAllocation()
        external
        view
        returns (IStaticsProtocolPools.GeneralFeeAllocation memory allocation)
    {
        IStaticsSwapFeeHook.GeneralFeeAllocation memory
            stored = IStaticsSwapFeeHook(_liquidityStorage().hook).generalFeeAllocation();
        allocation = IStaticsProtocolPools.GeneralFeeAllocation({
            polShareBps: stored.polShareBps,
            staticsStakerShareBps: stored.staticsStakerShareBps,
            treasuryShareBps: stored.treasuryShareBps
        });
    }

    function protocolPoolFeeRate(PoolId poolId)
        external
        view
        returns (IStaticsProtocolPools.PoolFeeRateView memory feeRate)
    {
        (IStaticsProtocolPools.ProtocolPoolKind kind,,,) = LibProtocolPools.enforceRegistered(poolId);
        if (kind == IStaticsProtocolPools.ProtocolPoolKind.PermissionedGeneral) {
            revert PublicProtocolPoolRequired(poolId);
        }
        IStaticsSwapFeeHook.PoolFeeRate memory stored =
            IStaticsSwapFeeHook(_liquidityStorage().hook).poolFeeRate(poolId);
        feeRate = IStaticsProtocolPools.PoolFeeRateView({
            inputFeeBps: stored.inputFeeBps, outputFeeBps: stored.outputFeeBps, overridden: stored.overridden
        });
    }

    function defaultProtocolPoolFeeRate() external view returns (IStaticsProtocolPools.PoolSwapFeeRate memory feeRate) {
        (uint16 inputFeeBps, uint16 outputFeeBps) = IStaticsSwapFeeHook(_liquidityStorage().hook).defaultFeeRate();
        feeRate = IStaticsProtocolPools.PoolSwapFeeRate({inputFeeBps: inputFeeBps, outputFeeBps: outputFeeBps});
    }

    function protocolPoolCreator(PoolId poolId) external view returns (address creator) {
        return LibProtocolPools.creatorOf(poolId);
    }

    function permanentLiquidityHarvester() external view returns (address harvester) {
        return LibProtocolPools.protocolPoolStorage().permanentLiquidityHarvester;
    }

    function _liquidityStorage() private view returns (LibBasketLiquidity.LiquidityStorage storage ls) {
        ls = LibBasketLiquidity.liquidityStorage();
        if (!ls.integrationInstalled) revert LiquidityIntegrationNotInstalled();
    }
}
