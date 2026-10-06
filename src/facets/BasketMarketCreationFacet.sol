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
import {StaticsBasketFactory} from "../liquidity/StaticsBasketFactory.sol";
import {StaticsBasketHook} from "../liquidity/StaticsBasketHook.sol";
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

/// @notice Additional independent restricted-token markets; canonical launch pointers stay unchanged.
contract BasketMarketCreationFacet is IStaticsBasketMarkets, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;

    error InvalidBasketMarketParameters();
    error RestrictedCurrencyRequired();
    error MarketCreationPaused();
    error PermissionlessMarketCreationDisabled();
    error IncorrectMarketCreationFee(uint256 required, uint256 provided);
    error MarketCreationFeeTransferFailed();

    function prepareBasketMarket(MarketParams calldata params, bytes32 hookSalt)
        external
        nonReentrant
        returns (bytes32 id, address hook)
    {
        _validate(params);
        StaticsBasketFactory factory = LibBasketDeployment.factory();
        id = factory.reserveMarket(_intent(params), hookSalt);
        (hook,) = factory.predict(hookSalt);
    }

    function createBasketMarket(MarketParams calldata params, bytes32 preparationId)
        external
        payable
        nonReentrant
        returns (PoolId id)
    {
        _validate(params);
        if (LibGovernance.governanceStorage().pausedActions & LibGovernance.PAUSE_LIQUIDITY != 0) {
            revert MarketCreationPaused();
        }
        _collectFee(params.maximumCreationFee);
        StaticsBasketFactory factory = LibBasketDeployment.factory();
        bytes32 prepared = _begin(factory, params, preparationId);
        (Currency currency0, Currency currency1) = params.tokenA < params.tokenB
            ? (Currency.wrap(params.tokenA), Currency.wrap(params.tokenB))
            : (Currency.wrap(params.tokenB), Currency.wrap(params.tokenA));
        address hook = factory.deployBasketHook(
            prepared, StaticsBasketHook.Binding(currency0, currency1, params.lpFee, params.tickSpacing, msg.sender, 1)
        );
        PoolKey memory key = PoolKey(currency0, currency1, params.lpFee, params.tickSpacing, IHooks(hook));
        id = key.toId();
        _register(params, key);
        uint160 price = params.tokenA < params.tokenB
            ? params.sqrtPriceBPerAX96
            : uint160(Math.mulDiv(1 << 96, 1 << 96, params.sqrtPriceBPerAX96));
        int24 tick = IPoolManager(LibBasketLiquidity.liquidityStorage().poolManager).initialize(key, price);
        LibRangeGauge.initializePool(id, tick);
    }

    function _register(MarketParams calldata params, PoolKey memory key) private {
        address token = LibRestrictedBasket.isRestricted(params.tokenA) ? params.tokenA : params.tokenB;
        address paired = token == params.tokenA ? params.tokenB : params.tokenA;
        uint256 basketId = LibRestrictedBasket.restrictedStorage().basketIds[token] - 1;
        LibProtocolPools.enforceUnregistered(key.toId());
        LibBasketMarkets.register(key, msg.sender, basketId, paired, 1);
        emit BasketMarketCreated(key.toId(), msg.sender, address(key.hooks), basketId);
    }

    function _begin(StaticsBasketFactory factory, MarketParams calldata params, bytes32 id) private returns (bytes32) {
        StaticsBasketFactory.Intent memory intent = _intent(params);
        if (id == bytes32(0)) return factory.reserveQueuedMarket(intent);
        StaticsBasketFactory.Preparation memory prepared = factory.preparation(id);
        if (
            prepared.tokenSalt != bytes32(0) || !prepared.tokenDeployed || prepared.hookCursor != 0
                || prepared.hookSalts.length != 1
                || keccak256(abi.encode(prepared.intent)) != keccak256(abi.encode(intent))
        ) {
            revert LibBasketDeployment.PreparationIntentMismatch();
        }
        return id;
    }

    function _intent(MarketParams calldata params) private view returns (StaticsBasketFactory.Intent memory) {
        bytes32 configuration = keccak256(
            abi.encode(
                params,
                LibBasketDeployment.environmentHash(),
                LibProtocolPools.protocolPoolStorage().poolCreationFeeAmount
            )
        );
        return StaticsBasketFactory.Intent(msg.sender, msg.sender, configuration, params.deadline, 1);
    }

    function _validate(MarketParams calldata params) private view {
        if (
            params.tokenA == params.tokenB || params.tokenA.code.length == 0 || params.tokenB.code.length == 0
                || !LibProtocolPoolFee.isValidStaticLpFee(params.lpFee)
                || !LibProtocolPoolFee.isValidTickSpacing(params.tickSpacing) || block.timestamp > params.deadline
                || params.sqrtPriceBPerAX96 < TickMath.MIN_SQRT_PRICE
                || params.sqrtPriceBPerAX96 >= TickMath.MAX_SQRT_PRICE
        ) revert InvalidBasketMarketParameters();
        if (!LibRestrictedBasket.isRestricted(params.tokenA) && !LibRestrictedBasket.isRestricted(params.tokenB)) {
            revert RestrictedCurrencyRequired();
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
