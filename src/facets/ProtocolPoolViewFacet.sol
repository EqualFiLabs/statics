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
        _liquidityStorage();
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(address(key.hooks));
        bool permissioned = kind == IStaticsProtocolPools.ProtocolPoolKind.PermissionedGeneral;
        pool.poolId = poolId;
        pool.key = key;
        pool.kind = kind;
        pool.decommissioned = permissioned
            ? LibPermissionedPools.resolve(poolId).decommissioned
            : registered && hook.poolDecommissioned(poolId);
        pool.basketId = basketId;
        pool.basketAsset = basketAsset;
        pool.creator = LibProtocolPools.creatorOf(poolId);

        LibProtocolPools.ProtocolPoolStorage storage ps = LibProtocolPools.protocolPoolStorage();
        LibProtocolPools.PolFundingConfig storage polConfig = ps.polFunding[poolId];
        pool.polActivated = kind == IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical || polConfig.activated;
        pool.polShareOverridden = polConfig.overrideSet;
        if (pool.polActivated && !permissioned) {
            if (polConfig.overrideSet) {
                uint16 available;
                if (kind == IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical) {
                    IStaticsSwapFeeHook.BasketFeeAllocation memory allocation = hook.basketFeeAllocation();
                    available = allocation.polShareBps + allocation.treasuryShareBps;
                } else {
                    IStaticsSwapFeeHook.GeneralFeeAllocation memory allocation = hook.generalFeeAllocation();
                    available = allocation.polShareBps + allocation.treasuryShareBps;
                }
                pool.polShareBps = polConfig.shareBps < available ? polConfig.shareBps : available;
            } else if (kind == IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical) {
                IStaticsSwapFeeHook.BasketFeeAllocation memory allocation = hook.basketFeeAllocation();
                pool.polShareBps = allocation.polShareBps;
            } else {
                IStaticsSwapFeeHook.GeneralFeeAllocation memory allocation = hook.generalFeeAllocation();
                pool.polShareBps = allocation.polShareBps;
            }
        }
        pool.activePolPositions = ps.activePolPositionCount[poolId];
    }

    function isProtocolPool(PoolId poolId) external view returns (bool registered) {
        (IStaticsProtocolPools.ProtocolPoolKind kind,,,) = LibProtocolPools.resolve(poolId);
        return kind != IStaticsProtocolPools.ProtocolPoolKind.None;
    }

    function poolCreationFee() external view returns (uint256 amount) {
        return LibProtocolPools.protocolPoolStorage().poolCreationFeeAmount;
    }

    function protocolPolActivationFee() external view returns (uint256 amount) {
        return LibProtocolPools.protocolPoolStorage().polActivationFeeAmount;
    }

    function protocolPolOperator() external view returns (address operator) {
        return LibProtocolPools.protocolPoolStorage().polOperator;
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
            IStaticsSwapFeeHook(LibProtocolPools.publicHook(poolId)).poolFeeRate(poolId);
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

    function protocolPoolMaintenanceConfig()
        external
        view
        returns (IStaticsProtocolPools.ProtocolPoolMaintenanceConfig memory config)
    {
        LibProtocolPools.ProtocolPoolStorage storage ps = LibProtocolPools.protocolPoolStorage();
        config = IStaticsProtocolPools.ProtocolPoolMaintenanceConfig({revenueTipBps: ps.revenueTipBps});
    }

    function protocolPolPosition(uint256 positionId)
        external
        view
        returns (IStaticsProtocolPools.ProtocolPolPositionView memory position)
    {
        LibProtocolPools.ProtocolPolPosition storage stored =
            LibProtocolPools.protocolPoolStorage().polPositions[positionId];
        position = IStaticsProtocolPools.ProtocolPolPositionView({
            positionId: positionId,
            poolId: stored.poolId,
            manager: stored.manager,
            posmTokenId: stored.posmTokenId,
            tickLower: stored.tickLower,
            tickUpper: stored.tickUpper,
            liquidity: stored.liquidity,
            active: stored.active
        });
    }

    function protocolPolPositionIds(PoolId poolId) external view returns (uint256[] memory positionIds) {
        return LibProtocolPools.protocolPoolStorage().polPositionIds[poolId];
    }

    function _liquidityStorage() private view returns (LibBasketLiquidity.LiquidityStorage storage ls) {
        ls = LibBasketLiquidity.liquidityStorage();
        if (!ls.integrationInstalled) revert LiquidityIntegrationNotInstalled();
    }
}
