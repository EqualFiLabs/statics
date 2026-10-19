// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
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
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibProtocolPol} from "../libraries/LibProtocolPol.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {LibProtocolPoolFee} from "../libraries/LibProtocolPoolFee.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibRangeGauge} from "../libraries/LibRangeGauge.sol";
import {LibBasketDeployment} from "../libraries/LibBasketDeployment.sol";

/// @notice Additional independent restricted-token markets; canonical launch pointers stay unchanged.
contract BasketMarketCreationFacet is IStaticsBasketMarkets, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;

    error InvalidBasketMarketParameters();
    error BasketCurrencyRequired();
    error MarketCreationPaused();
    error PermissionlessMarketCreationDisabled();
    error IncorrectMarketCreationFee(uint256 required, uint256 provided);
    error MarketCreationFeeTransferFailed();

    function createBasketMarket(MarketParams calldata params) external payable nonReentrant returns (PoolId id) {
        _validate(params);
        if (LibGovernance.governanceStorage().pausedActions & LibGovernance.PAUSE_LIQUIDITY != 0) {
            revert MarketCreationPaused();
        }
        _collectFee(params.maximumCreationFee, params.activateManagedPol);
        (Currency currency0, Currency currency1) = params.tokenA < params.tokenB
            ? (Currency.wrap(params.tokenA), Currency.wrap(params.tokenB))
            : (Currency.wrap(params.tokenB), Currency.wrap(params.tokenA));
        address hook = LibBasketDeployment.deploymentStorage().basketHook;
        if (hook.code.length == 0) revert InvalidBasketMarketParameters();
        PoolKey memory key = PoolKey(currency0, currency1, params.lpFee, params.tickSpacing, IHooks(hook));
        id = key.toId();
        _register(key);
        if (params.activateManagedPol) {
            LibProtocolPol.activate(id, msg.sender, LibProtocolPools.protocolPoolStorage().polActivationFeeAmount);
        }
        uint160 price = params.tokenA < params.tokenB
            ? params.sqrtPriceBPerAX96
            : uint160(Math.mulDiv(1 << 96, 1 << 96, params.sqrtPriceBPerAX96));
        int24 tick = IPoolManager(LibBasketLiquidity.liquidityStorage().poolManager).initialize(key, price);
        LibRangeGauge.initializePool(id, tick);
    }

    function _register(PoolKey memory key) private {
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        address token = LibBasket.isBasketToken(currency0) ? currency0 : currency1;
        address paired = token == currency0 ? currency1 : currency0;
        uint256 basketId = LibBasket.basketStorage().basketIds[token] - 1;
        address creator = LibBasket.basketStorage().baskets[basketId].creator;
        LibProtocolPools.enforceUnregistered(key.toId());
        IStaticsSwapFeeHook(address(key.hooks)).registerPool(key, IStaticsSwapFeeHook.PoolKind.BasketCanonical, creator);
        LibBasketMarkets.register(key, creator, basketId, paired);
        emit BasketMarketCreated(key.toId(), creator, address(key.hooks), basketId);
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
        if (!LibBasket.isBasketToken(params.tokenA) && !LibBasket.isBasketToken(params.tokenB)) {
            revert BasketCurrencyRequired();
        }
    }

    function _enforceFinalizedCurrency(address token) private view {
        uint256 id = LibBasket.basketStorage().basketIds[token];
        if (id != 0) {
            LibBasket.Basket storage configured = LibBasket.basketStorage().baskets[id - 1];
            if (configured.token != token) revert InvalidBasketMarketParameters();
            LibBasket.enforceActive(configured, id - 1);
        }
    }

    function _collectFee(uint256 maximum, bool activateManagedPol) private {
        uint256 fee = LibProtocolPools.protocolPoolStorage().poolCreationFeeAmount;
        if (fee == 0 && msg.sender != LibDiamond.contractOwner()) revert PermissionlessMarketCreationDisabled();
        uint256 total = fee + (activateManagedPol ? LibProtocolPools.protocolPoolStorage().polActivationFeeAmount : 0);
        if (fee > maximum || msg.value != total) revert IncorrectMarketCreationFee(total, msg.value);
        if (total != 0) {
            (bool ok,) = payable(LibBasket.basketStorage().treasury).call{value: total}("");
            if (!ok) revert MarketCreationFeeTransferFailed();
        }
    }
}
