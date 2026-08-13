// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IStaticsSwapFeeHook {
    struct PermanentLiquiditySeed {
        PoolKey key;
        uint128 liquidity;
    }

    struct PoolRegistration {
        Currency currency0;
        Currency currency1;
        bool registered;
    }

    struct FeeConfiguration {
        uint16 inputFeeBps;
        uint16 outputFeeBps;
        uint16 lockedLiquidityShareBps;
        uint16 liquidityProviderShareBps;
        uint16 basketStakerShareBps;
        uint16 staticsStakerShareBps;
        uint16 stonkBrokersShareBps;
        uint16 indexCreatorShareBps;
        uint16 treasuryShareBps;
    }

    struct PoolFeeConfigurationView {
        uint16 inputFeeBps;
        uint16 outputFeeBps;
        uint16 lockedLiquidityShareBps;
        uint16 liquidityProviderShareBps;
        uint16 basketStakerShareBps;
        uint16 staticsStakerShareBps;
        uint16 stonkBrokersShareBps;
        uint16 indexCreatorShareBps;
        uint16 treasuryShareBps;
        bool overridden;
    }

    event PoolRegistered(PoolId indexed poolId, Currency indexed currency0, Currency indexed currency1);
    event SwapLegFeeAccrued(
        PoolId indexed poolId,
        Currency indexed currency,
        bool indexed specifiedLeg,
        uint256 realizedAmount,
        uint256 chargedAmount,
        uint256 lockedLiquidityAmount,
        uint256 liquidityProviderAmount,
        uint256 basketStakerAmount,
        uint256 staticsStakerAmount,
        uint256 stonkBrokersAmount,
        uint256 indexCreatorAmount,
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
    event FeeConfigurationSet(
        uint16 inputFeeBps,
        uint16 outputFeeBps,
        uint16 lockedLiquidityShareBps,
        uint16 liquidityProviderShareBps,
        uint16 basketStakerShareBps,
        uint16 staticsStakerShareBps,
        uint16 stonkBrokersShareBps,
        uint16 indexCreatorShareBps,
        uint16 treasuryShareBps
    );
    event PoolFeeConfigurationSet(
        PoolId indexed poolId,
        uint16 inputFeeBps,
        uint16 outputFeeBps,
        uint16 lockedLiquidityShareBps,
        uint16 liquidityProviderShareBps,
        uint16 basketStakerShareBps,
        uint16 staticsStakerShareBps,
        uint16 stonkBrokersShareBps,
        uint16 indexCreatorShareBps,
        uint16 treasuryShareBps
    );
    event PoolFeeConfigurationCleared(PoolId indexed poolId);
    function staticsDiamond() external view returns (address);
    function feeConfiguration() external view returns (FeeConfiguration memory config);
    function setFeeConfiguration(
        uint16 inputFeeBps,
        uint16 outputFeeBps,
        uint16 lockedLiquidityShareBps,
        uint16 liquidityProviderShareBps,
        uint16 basketStakerShareBps,
        uint16 staticsStakerShareBps,
        uint16 stonkBrokersShareBps,
        uint16 indexCreatorShareBps,
        uint16 treasuryShareBps
    ) external;
    function setPoolFeeConfiguration(PoolId poolId, FeeConfiguration calldata configuration) external;
    function clearPoolFeeConfiguration(PoolId poolId) external;
    function poolFeeConfiguration(PoolId poolId) external view returns (PoolFeeConfigurationView memory configuration);
    function registerPool(PoolKey calldata key) external returns (PoolId poolId);
    function decommissionPool(PoolKey calldata key) external;
    function poolDecommissioned(PoolId poolId) external view returns (bool decommissioned);
    function poolRegistration(PoolId poolId) external view returns (PoolRegistration memory registration);
    function pendingPermanentLiquidity(PoolId poolId, Currency currency) external view returns (uint256 amount);
    function lockedLiquidity(PoolId poolId) external view returns (uint128 liquidity);
    function seedPermanentLiquidity(PermanentLiquiditySeed[] calldata seeds) external;
    function compoundPermanentLiquidity(PoolKey calldata key) external returns (uint128 liquidityAdded);
    function releasePermanentLiquidity(PoolKey calldata key, address receiver)
        external
        returns (uint256 amount0, uint256 amount1);
}
