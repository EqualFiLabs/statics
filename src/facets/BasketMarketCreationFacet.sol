// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsBasketMarkets} from "../interfaces/IStaticsBasketMarkets.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketMarkets} from "../libraries/LibBasketMarkets.sol";
import {LibBasketDeployment} from "../libraries/LibBasketDeployment.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibRestrictedBasket} from "../libraries/LibRestrictedBasket.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {LibProtocolPoolFee} from "../libraries/LibProtocolPoolFee.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibRangeGauge} from "../libraries/LibRangeGauge.sol";
import {LibPublicHookPolicy} from "../libraries/LibPublicHookPolicy.sol";

/// @notice Additional independent restricted-token markets; canonical launch pointers stay unchanged.
contract BasketMarketCreationFacet is IStaticsBasketMarkets, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;

    error InvalidBasketMarketParameters();
    error RestrictedCurrencyRequired();
    error MarketCreationPaused();
    error PermissionlessMarketCreationDisabled();
    error IncorrectMarketCreationFee(uint256 required, uint256 provided);
    error MarketCreationFeeTransferFailed();

    function createBasketMarket(MarketParams calldata params) external payable nonReentrant returns (PoolId id) {
        _validate(params);
        if (LibGovernance.governanceStorage().pausedActions & LibGovernance.PAUSE_LIQUIDITY != 0) {
            revert MarketCreationPaused();
        }
        _collectFee(params.maximumCreationFee);
        LibProtocolPools.enforcePoolCreationAllowed(msg.sender);
        (Currency currency0, Currency currency1) = params.tokenA < params.tokenB
            ? (Currency.wrap(params.tokenA), Currency.wrap(params.tokenB))
            : (Currency.wrap(params.tokenB), Currency.wrap(params.tokenA));
        address hook = LibPublicHookPolicy.policyStorage().basketHook;
        if (hook.code.length == 0) revert InvalidBasketMarketParameters();
        PoolKey memory key = PoolKey(currency0, currency1, params.lpFee, params.tickSpacing, IHooks(hook));
        id = key.toId();
        _register(key);
        uint160 price = params.tokenA < params.tokenB
            ? params.sqrtPriceBPerAX96
            : uint160(Math.mulDiv(1 << 96, 1 << 96, params.sqrtPriceBPerAX96));
        int24 tick = IPoolManager(LibBasketLiquidity.liquidityStorage().poolManager).initialize(key, price);
        LibRangeGauge.initializePool(id, tick);
    }

    function _register(PoolKey memory key) private {
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        address token = LibRestrictedBasket.isRestricted(currency0) ? currency0 : currency1;
        address paired = token == currency0 ? currency1 : currency0;
        uint256 basketId = LibRestrictedBasket.restrictedStorage().basketIds[token] - 1;
        address creator = LibBasket.basketStorage().baskets[basketId].creator;
        LibProtocolPools.enforceUnregistered(key.toId());
        IStaticsSwapFeeHook(address(key.hooks)).registerPool(key, IStaticsSwapFeeHook.PoolKind.BasketCanonical, creator);
        LibBasketMarkets.register(key, creator, basketId, paired, 1);
        emit BasketMarketCreated(key.toId(), creator, address(key.hooks), basketId);
    }

    function basketMarketConfigurationHash(MarketParams calldata params) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                params,
                LibBasketDeployment.environmentHash(),
                LibProtocolPools.protocolPoolStorage().poolCreationFeeAmount
            )
        );
    }

    function _validate(MarketParams calldata params) private view {
        if (
            params.tokenA == params.tokenB || (params.tokenA != address(0) && params.tokenA.code.length == 0)
                || (params.tokenB != address(0) && params.tokenB.code.length == 0)
                || !LibProtocolPoolFee.isValidStaticLpFee(params.lpFee)
                || !LibProtocolPoolFee.isValidTickSpacing(params.tickSpacing) || block.timestamp > params.deadline
                || params.sqrtPriceBPerAX96 < TickMath.MIN_SQRT_PRICE
                || params.sqrtPriceBPerAX96 >= TickMath.MAX_SQRT_PRICE
        ) revert InvalidBasketMarketParameters();
        _enforceFinalizedCurrency(params.tokenA);
        _enforceFinalizedCurrency(params.tokenB);
        if (!LibRestrictedBasket.isRestricted(params.tokenA) && !LibRestrictedBasket.isRestricted(params.tokenB)) {
            revert RestrictedCurrencyRequired();
        }
    }

    function _enforceFinalizedCurrency(address token) private view {
        uint256 id = LibRestrictedBasket.restrictedStorage().basketIds[token];
        if (id != 0) {
            LibBasket.Basket storage configured = LibBasket.basketStorage().baskets[id - 1];
            if (configured.token != token) revert InvalidBasketMarketParameters();
            LibBasket.enforceActive(configured, id - 1);
        }
    }

    function _collectFee(uint256 maximum) private {
        uint256 fee = LibProtocolPools.protocolPoolStorage().poolCreationFeeAmount;
        if (fee == 0 && msg.sender != LibDiamond.contractOwner()) revert PermissionlessMarketCreationDisabled();
        if (fee > maximum || msg.value != fee) revert IncorrectMarketCreationFee(fee, msg.value);
        if (fee != 0) {
            (bool ok,) = payable(LibBasket.basketStorage().treasury).call{value: fee}("");
            if (!ok) revert MarketCreationFeeTransferFailed();
        }
    }
}
