// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Standalone fee hook for temporary Statics launch pools.
/// @dev Liquidity positions are ordinary externally owned Uniswap v4 PositionManager NFTs. The
/// hook neither owns nor accounts for liquidity.
interface IStaticsLaunchLiquidityHook {
    struct PoolRegistration {
        Currency currency0;
        Currency currency1;
        uint24 nativeLpFee;
        int24 tickSpacing;
        uint160 expectedSqrtPriceX96;
        uint16 inputFeeBps;
        uint16 outputFeeBps;
        address launchOperator;
        bool initialized;
        bool active;
        bool registered;
    }

    event PoolRegistered(
        PoolId indexed poolId,
        Currency indexed currency0,
        Currency indexed currency1,
        uint24 nativeLpFee,
        int24 tickSpacing,
        uint160 expectedSqrtPriceX96,
        uint16 inputFeeBps,
        uint16 outputFeeBps,
        address launchOperator
    );
    event PoolInitialized(PoolId indexed poolId);
    event PoolActivated(PoolId indexed poolId, address indexed activator);
    event HookFeesSet(
        PoolId indexed poolId,
        uint16 previousInputFeeBps,
        uint16 newInputFeeBps,
        uint16 previousOutputFeeBps,
        uint16 newOutputFeeBps
    );
    event SwapLegFeeRouted(
        PoolId indexed poolId,
        Currency indexed currency,
        bool indexed specifiedLeg,
        uint256 realizedAmount,
        uint256 chargedAmount,
        address receiver
    );
    event FeeReceiverSet(address indexed previousReceiver, address indexed newReceiver);

    /// @notice Registers immutable launch parameters before a pool is initialized.
    /// @dev Callable by the hook owner or by an account holding the owner's existing timelock proposer role.
    function registerPool(
        PoolKey calldata key,
        uint160 expectedSqrtPriceX96,
        uint16 inputFeeBps,
        uint16 outputFeeBps,
        address launchOperator
    ) external returns (PoolId poolId);
    function activatePool(PoolId poolId) external;
    function setHookFees(PoolId poolId, uint16 inputFeeBps, uint16 outputFeeBps) external;
    function setFeeReceiver(address newReceiver) external;

    function poolRegistration(PoolId poolId) external view returns (PoolRegistration memory registration);
    function feeReceiver() external view returns (address);
    function positionManager() external view returns (address);
}
