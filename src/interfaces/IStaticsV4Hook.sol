// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IStaticsV4Hook {
    struct FeeConfiguration {
        uint16 inputFeeBps;
        uint16 outputFeeBps;
        uint16 polShareBps;
        uint16 liquidityProviderShareBps;
        uint16 basketStakerShareBps;
        uint16 staticsStakerShareBps;
        uint16 partnerShareBps;
        uint16 creatorShareBps;
        uint16 treasuryShareBps;
    }

    struct RevenueRecipients {
        address liquidityProvider;
        address basketStaker;
        address staticsStaker;
        address partner;
        address creator;
        address treasury;
    }

    struct PoolConfigurationView {
        FeeConfiguration fees;
        RevenueRecipients recipients;
        uint160 expectedSqrtPriceX96;
        address initializer;
        bool registered;
        bool initialized;
        bool externalLiquidityEnabled;
    }

    event PoolRegistered(
        PoolId indexed poolId, uint160 expectedSqrtPriceX96, address indexed initializer, bool canonicalLaunch
    );
    event PoolConfigurationSet(PoolId indexed poolId, FeeConfiguration fees, RevenueRecipients recipients);
    event ExternalLiquidityActivated(PoolId indexed poolId, address indexed liquidityProviderRecipient);
    event CanonicalLaunchInitialized(
        PoolId indexed poolId, uint160 sqrtPriceX96, uint256 inventory, uint256 inventorySettled, uint256 roundingDust
    );
    event LaunchPositionInstalled(
        PoolId indexed poolId,
        uint8 indexed band,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        uint128 liquidity,
        uint256 staticsAmount
    );
    event SwapLegFeeAccrued(
        PoolId indexed poolId,
        Currency indexed currency,
        bool indexed inputLeg,
        uint256 realizedAmount,
        uint256 chargedAmount,
        uint256 polAmount,
        uint256 routedAmount
    );
    event PermanentLiquidityAdded(
        PoolId indexed poolId, uint128 liquidity, uint256 amount0, uint256 amount1, uint256 pending0, uint256 pending1
    );

    function controller() external view returns (address);
    function statics() external view returns (address);
    function weth() external view returns (address);
    function canonicalPoolKey() external view returns (PoolKey memory);
    function canonicalPoolId() external view returns (PoolId);
    function poolConfiguration(PoolId poolId) external view returns (PoolConfigurationView memory configuration);
    function setPoolConfiguration(PoolId poolId, FeeConfiguration calldata fees, RevenueRecipients calldata recipients)
        external;
    function activateExternalLiquidity(
        PoolId poolId,
        FeeConfiguration calldata fees,
        RevenueRecipients calldata recipients
    ) external;
    function compoundPermanentLiquidity(PoolKey calldata key) external returns (uint128 liquidityAdded);
    function pendingPermanentLiquidity(PoolId poolId, Currency currency) external view returns (uint256 amount);
    function lockedPermanentLiquidity(PoolId poolId) external view returns (uint128 liquidity);
    function launchRoundingDust() external view returns (uint256 amount);
    function launchBandTicks(uint8 band) external view returns (int24 tickLower, int24 tickUpper);
    function launchBandTarget(uint8 band) external pure returns (uint256 amount);
    function launchBandSalt(uint8 band) external pure returns (bytes32 salt);
}
