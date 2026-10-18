// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IStaticsBasketConversion, IStaticsBasketConversionDelivery} from "../interfaces/IStaticsBasketConversion.sol";
import {IStaticsBasketToken} from "../interfaces/IStaticsBasketToken.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketMarkets} from "../libraries/LibBasketMarkets.sol";
import {LibBasketMint} from "../libraries/LibBasketMint.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";

/// @notice Conversion capabilities use existing basket identities, custody and fees.
contract BasketConversionFacet is IStaticsBasketConversion, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;

    address private immutable conversionHook;
    address private immutable conversionZap;
    address private immutable conversionRouter;
    IPoolManager private immutable manager;

    error InvalidConversionMarket();
    error UnauthorizedConversion();
    error ConversionCreationPaused();
    error PermissionlessConversionCreationDisabled();
    error IncorrectConversionCreationFee();
    error ConversionFeeTransferFailed();
    error StaleConversionQuote();
    error ConversionArrivalMismatch(address token);
    error ConversionSettlementMismatch();

    constructor(address hook, address zap, address router, IPoolManager poolManager) {
        conversionHook = hook;
        conversionZap = zap;
        conversionRouter = router;
        manager = poolManager;
    }

    function basketConversionConfiguration() external view returns (Configuration memory) {
        return Configuration(conversionHook, conversionZap, conversionRouter, address(manager));
    }

    function basketConversionMarket(PoolId id) external view returns (Market memory result) {
        LibBasketMarkets.Market storage m = _market(id);
        result = Market(
            m.key,
            m.basketId,
            LibBasket.basketStorage().baskets[m.basketId].token,
            m.basketAsset,
            m.lifecycle == LibBasketMarkets.Lifecycle.Active
        );
    }

    function createBasketConversionMarket(uint256 id, address quote, uint256 maximum, uint256 deadline)
        external
        payable
        nonReentrant
        returns (PoolId poolId)
    {
        LibBasket.Basket storage b = LibBasketMint.basket(LibBasket.basketStorage(), id);
        LibBasket.enforceActive(b, id);
        if (block.timestamp > deadline || quote.code.length == 0 || LibBasket.isBasketToken(quote)) {
            revert InvalidConversionMarket();
        }
        for (uint256 i; i < b.assets.length; ++i) {
            if (b.assets[i].code.length == 0 || LibBasket.isBasketToken(b.assets[i])) revert InvalidConversionMarket();
        }
        if (LibGovernance.governanceStorage().pausedActions & LibGovernance.PAUSE_LIQUIDITY != 0) {
            revert ConversionCreationPaused();
        }
        _collectFee(maximum);
        (address a, address c) = b.token < quote ? (b.token, quote) : (quote, b.token);
        PoolKey memory key = PoolKey(Currency.wrap(a), Currency.wrap(c), 0, 1, IHooks(conversionHook));
        poolId = key.toId();
        LibBasketMarkets.register(key, b.creator, id, quote);
        LibBasketMarkets.marketStorage().markets[poolId].conversion = true;
        manager.initialize(key, uint160(1 << 96));
        emit BasketConversionMarketCreated(poolId, id, quote);
    }

    function decommissionBasketConversionMarket(PoolId id) external {
        LibDiamond.enforceIsContractOwner();
        _market(id);
        LibBasketMarkets.decommission(id);
        emit BasketConversionMarketDecommissioned(id);
    }

    function mintBasketConversion(PoolId poolId, uint256 shares, address receiver, uint256[] calldata expected)
        external
        nonReentrant
    {
        if (msg.sender != conversionHook && msg.sender != conversionZap) revert UnauthorizedConversion();
        LibBasketMarkets.Market storage m = _activeMarket(poolId);
        if (!manager.isUnlocked()) revert UnauthorizedConversion();
        LibBasket.Basket storage b = LibBasket.basketStorage().baskets[m.basketId];
        uint256 supply = IERC20(b.token).totalSupply();
        uint256[] memory required = LibBasketMint.quote(b, shares, supply);
        if (expected.length != required.length) revert StaleConversionQuote();
        uint256[] memory beforeBalances = new uint256[](required.length);
        for (uint256 i; i < required.length; ++i) {
            if (required[i] != expected[i]) revert StaleConversionQuote();
            beforeBalances[i] = IERC20(b.assets[i]).balanceOf(address(this));
        }
        IStaticsBasketConversionDelivery(msg.sender)
            .deliverBasketConversion(poolId, m.basketId, shares, receiver, required);
        for (uint256 i; i < required.length; ++i) {
            address asset = b.assets[i];
            if (IERC20(asset).balanceOf(address(this)) != beforeBalances[i] + required[i]) {
                revert ConversionArrivalMismatch(asset);
            }
            LibCustody.reserve(LibCustody.basketAccount(m.basketId), asset, required[i]);
        }
        LibBasketMint.mintFromRetainedPrincipal(m.basketId, shares, msg.sender, receiver);
    }

    function prefundBasketConversion(PoolId id, address payer, uint256 amount) external nonReentrant {
        if (msg.sender != conversionRouter || amount == 0 || !manager.isUnlocked()) revert UnauthorizedConversion();
        LibBasketMarkets.Market storage m = _activeMarket(id);
        address token = LibBasket.basketStorage().baskets[m.basketId].token;
        IStaticsBasketToken(token).authorizePoolSettlement(amount, 0);
        manager.sync(Currency.wrap(token));
        IERC20(token).safeTransferFrom(payer, address(manager), amount);
        if (manager.settleFor(conversionRouter) != amount) revert ConversionSettlementMismatch();
    }

    function _market(PoolId id) private view returns (LibBasketMarkets.Market storage m) {
        m = LibBasketMarkets.requireMarket(id);
        if (!m.conversion || address(m.key.hooks) != conversionHook) revert InvalidConversionMarket();
    }

    function _activeMarket(PoolId id) private view returns (LibBasketMarkets.Market storage m) {
        m = _market(id);
        LibBasketMarkets.validate(m, id, 0);
    }

    function _collectFee(uint256 maximum) private {
        uint256 fee = LibProtocolPools.protocolPoolStorage().poolCreationFeeAmount;
        if (fee == 0 && msg.sender != LibDiamond.contractOwner()) revert PermissionlessConversionCreationDisabled();
        if (fee > maximum || msg.value != fee) revert IncorrectConversionCreationFee();
        if (fee != 0) {
            (bool ok,) = payable(LibBasket.basketStorage().treasury).call{value: fee}("");
            if (!ok) revert ConversionFeeTransferFailed();
        }
    }
}
