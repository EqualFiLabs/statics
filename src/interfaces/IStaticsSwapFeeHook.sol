// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IStaticsSwapFeeHook {
    /// @dev Normalized protocol-pool class. Mirrors `IStaticsProtocolPools.ProtocolPoolKind` but is
    /// duplicated here so the hook can compile against the pinned `^0.8.26` profile without importing
    /// the Diamond-side interface, and so registration records the immutable class locally.
    enum PoolKind {
        None,
        BasketCanonical,
        General
    }

    struct PermanentLiquiditySeed {
        PoolKey key;
        uint128 liquidity;
    }

    struct PoolRegistration {
        Currency currency0;
        Currency currency1;
        PoolKind kind;
        address creator;
        bool registered;
    }

    /// @notice PoolId-local Statics bilateral swap-fee rate. Allocation of the collected fee is
    /// governed by the global class profiles rather than this per-pool rate.
    struct PoolFeeRate {
        uint16 inputFeeBps;
        uint16 outputFeeBps;
        bool overridden;
    }

    /// @notice Global allocation profile for basket canonical pools. The fixed 500-bps creator share
    /// is applied separately, so the configurable shares total 9,500 bps.
    struct BasketFeeAllocation {
        uint16 polShareBps;
        uint16 liquidityProviderShareBps;
        uint16 basketStakerShareBps;
        uint16 staticsStakerShareBps;
        uint16 treasuryShareBps;
    }

    /// @notice Global allocation profile for general pools. General pools have no basket-staker share.
    struct GeneralFeeAllocation {
        uint16 polShareBps;
        uint16 liquidityProviderShareBps;
        uint16 staticsStakerShareBps;
        uint16 treasuryShareBps;
    }

    event PoolRegistered(
        PoolId indexed poolId, Currency indexed currency0, Currency indexed currency1, PoolKind kind, address creator
    );
    event SwapLegFeeAccrued(
        PoolId indexed poolId,
        Currency indexed currency,
        bool indexed specifiedLeg,
        uint256 realizedAmount,
        uint256 chargedAmount,
        uint256 polAmount,
        uint256 liquidityProviderAmount,
        uint256 basketStakerAmount,
        uint256 staticsStakerAmount,
        uint256 creatorAmount,
        uint256 treasuryAmount
    );
    event PermanentLiquidityAdded(
        PoolId indexed poolId, uint128 liquidity, uint256 amount0, uint256 amount1, uint256 pending0, uint256 pending1
    );
    event PermanentLiquiditySeeded(PoolId indexed poolId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event PermanentLiquidityFeesCollected(
        PoolId indexed poolId, Currency indexed currency, uint256 amount, uint256 pendingAmount
    );
    event PermanentLiquidityReleased(
        PoolId indexed poolId, address indexed receiver, uint128 liquidity, uint256 amount0, uint256 amount1
    );
    event PoolDecommissioned(PoolId indexed poolId);
    event PoolFeeRateSet(PoolId indexed poolId, uint16 inputFeeBps, uint16 outputFeeBps, bool overridden);
    event DefaultFeeRateSet(uint16 inputFeeBps, uint16 outputFeeBps);
    event BasketFeeAllocationSet(
        uint16 polShareBps,
        uint16 liquidityProviderShareBps,
        uint16 basketStakerShareBps,
        uint16 staticsStakerShareBps,
        uint16 treasuryShareBps
    );
    event GeneralFeeAllocationSet(
        uint16 polShareBps, uint16 liquidityProviderShareBps, uint16 staticsStakerShareBps, uint16 treasuryShareBps
    );

    function staticsDiamond() external view returns (address);

    // --- Fee rate (PoolId-local) ---
    function defaultFeeRate() external view returns (uint16 inputFeeBps, uint16 outputFeeBps);
    function setDefaultFeeRate(uint16 inputFeeBps, uint16 outputFeeBps) external;
    function setPoolFeeRate(PoolId poolId, uint16 inputFeeBps, uint16 outputFeeBps) external;
    function clearPoolFeeRate(PoolId poolId) external;
    function poolFeeRate(PoolId poolId) external view returns (PoolFeeRate memory rate);

    // --- Allocation profiles (global) ---
    function basketFeeAllocation() external view returns (BasketFeeAllocation memory allocation);
    function generalFeeAllocation() external view returns (GeneralFeeAllocation memory allocation);
    function setBasketFeeAllocation(BasketFeeAllocation calldata allocation) external;
    function setGeneralFeeAllocation(GeneralFeeAllocation calldata allocation) external;

    // --- Registration and lifecycle ---
    function registerPool(PoolKey calldata key, PoolKind kind, address creator) external returns (PoolId poolId);
    function decommissionPool(PoolKey calldata key) external;
    function poolDecommissioned(PoolId poolId) external view returns (bool decommissioned);
    function poolRegistration(PoolId poolId) external view returns (PoolRegistration memory registration);

    // --- Permanent liquidity ---
    function pendingPermanentLiquidity(PoolId poolId, Currency currency) external view returns (uint256 amount);
    function lockedLiquidity(PoolId poolId) external view returns (uint128 liquidity);
    function seedPermanentLiquidity(PermanentLiquiditySeed[] calldata seeds) external;
    function compoundPermanentLiquidity(PoolKey calldata key) external returns (uint128 liquidityAdded);
    function releasePermanentLiquidity(PoolKey calldata key, address receiver)
        external
        returns (uint256 amount0, uint256 amount1);
}
