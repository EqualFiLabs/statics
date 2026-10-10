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
        uint16 inputFeePips;
        uint16 outputFeePips;
        bool overridden;
    }

    /// @notice Global allocation profile for basket canonical pools. The fixed 500-bps creator share
    /// is applied separately, so the configurable shares total 9,500 bps.
    struct BasketFeeAllocation {
        uint16 polShareBps;
        uint16 basketStakerShareBps;
        uint16 staticsStakerShareBps;
        uint16 treasuryShareBps;
    }

    /// @notice Global allocation profile for general pools. General pools have no basket-staker share.
    struct GeneralFeeAllocation {
        uint16 polShareBps;
        uint16 staticsStakerShareBps;
        uint16 treasuryShareBps;
    }

    struct FeeDistribution {
        uint256 basketStaker;
        uint256 staticsStaker;
        uint256 creator;
        uint256 treasury;
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
        uint256 basketStakerAmount,
        uint256 staticsStakerAmount,
        uint256 creatorAmount,
        uint256 treasuryAmount
    );
    event PendingFeeDistributionReallocated(
        PoolId indexed poolId, Currency indexed currency, uint256 basketStakerToPol, uint256 staticsStakerToTreasury
    );
    event ProtocolPolSettled(
        PoolId indexed poolId, Currency indexed currency, address indexed receiver, uint256 amount
    );
    event PoolDecommissioned(PoolId indexed poolId);
    event PoolFeeRateSet(PoolId indexed poolId, uint16 inputFeePips, uint16 outputFeePips, bool overridden);
    event DefaultFeeRateSet(uint16 inputFeePips, uint16 outputFeePips);
    event BasketFeeAllocationSet(
        uint16 polShareBps, uint16 basketStakerShareBps, uint16 staticsStakerShareBps, uint16 treasuryShareBps
    );
    event GeneralFeeAllocationSet(uint16 polShareBps, uint16 staticsStakerShareBps, uint16 treasuryShareBps);

    function weth() external view returns (address);

    function staticsDiamond() external view returns (address);

    // --- Fee rate (PoolId-local) ---
    function defaultFeeRate() external view returns (uint16 inputFeePips, uint16 outputFeePips);
    function setDefaultFeeRate(uint16 inputFeePips, uint16 outputFeePips) external;
    function setPoolFeeRate(PoolId poolId, uint16 inputFeePips, uint16 outputFeePips) external;
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

    // --- Managed POL inventory ---
    function pendingProtocolPol(PoolId poolId, Currency currency) external view returns (uint256 amount);
    function pendingStakerRewards(Currency currency) external view returns (uint256 amount);
    function pendingFeeDistribution(PoolId poolId, Currency currency)
        external
        view
        returns (FeeDistribution memory distribution);
    function claimLiability(Currency currency) external view returns (uint256 amount);
    function settleFeeDistribution(PoolKey calldata key, Currency currency, address receiver)
        external
        returns (FeeDistribution memory distribution);
    function settleStakerRewards(Currency currency, address receiver, uint256 amount) external returns (uint256 settled);
    function settleProtocolPol(PoolKey calldata key, Currency currency, address receiver, uint256 maximumAmount)
        external
        returns (uint256 amount);
}
