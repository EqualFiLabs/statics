// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {IStaticsGaugeIncentives} from "../interfaces/IStaticsGaugeIncentives.sol";
import {IStaticsProtocolRevenue} from "../interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsRangeGauge} from "../interfaces/IStaticsRangeGauge.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibProtocolRevenue} from "../libraries/LibProtocolRevenue.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {LibRangeGauge} from "../libraries/LibRangeGauge.sol";
import {LibBasketMarkets} from "../libraries/LibBasketMarkets.sol";
import {LibRestrictedBasket} from "../libraries/LibRestrictedBasket.sol";
import {StaticsBasketToken} from "../tokens/StaticsBasketToken.sol";

contract BasketLiquidityLifecycleFacet is ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error BasketNotFound(uint256 basketId);
    error AssetNotInBasket(uint256 basketId, address asset);
    error CanonicalPoolNotConfigured(uint256 basketId, address asset);
    error BasketNotExitOnly(uint256 basketId, IStaticsBasket.BasketStatus status);
    error BasketLiquidityAlreadyUnwound(uint256 basketId, address asset);
    error ReleasedAmountMismatch(address token, uint256 reported, uint256 observed);
    error InsufficientVaultBalance(address asset, uint256 required, uint256 available);
    error ActiveProtocolPolPositions(PoolId poolId, uint256 count);
    error IndependentMarketRequired(PoolId poolId);
    error BasketMarketNotExitOnly(PoolId poolId);

    event ProtocolPolTreasuryAccrued(
        uint256 indexed basketId, address indexed sourcePoolAsset, address indexed rewardAsset, uint256 amount
    );
    event BasketLiquidityUnwound(
        uint256 indexed basketId,
        address indexed asset,
        PoolId indexed poolId,
        uint256 constituentReleased,
        uint256 basketTokensBurned
    );
    event BasketMarketUnwound(PoolId indexed poolId);

    struct TreasuryAccrual {
        uint256 basketId;
        address sourcePoolAsset;
        uint256 shares;
        uint256 supply;
        bytes32 basketAccount;
        bytes32 feeAccount;
    }

    function unwindBasketLiquidity(uint256 basketId, address asset) external nonReentrant {
        LibBasket.Basket storage configured = _basket(basketId);
        if (configured.status != IStaticsBasket.BasketStatus.ExitOnly) {
            revert BasketNotExitOnly(basketId, configured.status);
        }
        _enforceConstituent(configured, basketId, asset);
        (LibBasketLiquidity.LiquidityStorage storage ls, LibBasketLiquidity.CanonicalPool storage stored) =
            _configuredPool(basketId, asset);
        address basketToken = configured.token;
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(address(stored.key.hooks));
        PoolId poolId = stored.key.toId();
        if (hook.poolDecommissioned(poolId)) revert BasketLiquidityAlreadyUnwound(basketId, asset);
        uint256 activePositions = LibProtocolPools.protocolPoolStorage().activePolPositionCount[poolId];
        if (activePositions != 0) revert ActiveProtocolPolPositions(poolId, activePositions);
        _stopRangeGauge(ls, stored.key);
        hook.decommissionPool(stored.key);
        if (LibBasketMarkets.marketStorage().markets[poolId].lifecycle != LibBasketMarkets.Lifecycle.None) {
            LibBasketMarkets.transition(poolId, LibBasketMarkets.Lifecycle.Decommissioned);
        }
        _settleHookAsset(hook, stored.key, poolId, stored.key.currency0);
        _settleHookAsset(hook, stored.key, poolId, stored.key.currency1);

        bytes32 polAccount = LibCustody.protocolPolAccount(PoolId.unwrap(poolId));
        uint256 basketTokens = LibCustody.accountReserved(polAccount, basketToken);
        uint256 constituent = LibCustody.accountReserved(polAccount, asset);
        LibCustody.release(polAccount, basketToken, basketTokens);

        if (constituent != 0) {
            LibCustody.moveReservation(polAccount, LibCustody.feeAccount(), asset, constituent);
            LibGlobalRewards.accrueReservedTreasuryFee(asset, constituent);
            emit ProtocolPolTreasuryAccrued(basketId, asset, asset, constituent);
        }
        _burnPolBasketTokens(configured, basketId, asset, basketTokens);
        emit BasketLiquidityUnwound(basketId, asset, poolId, constituent, basketTokens);
    }

    /// @notice Retire one independent market after either restricted currency becomes exit-only.
    /// User positions and historical claims are not relocated or deleted.
    function unwindBasketMarket(PoolId poolId) external nonReentrant {
        LibBasketMarkets.Market storage market = LibBasketMarkets.requireMarket(poolId);
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        PoolKey memory key = market.key;
        if (PoolId.unwrap(ls.canonicalPools[market.basketId][market.basketAsset].key.toId()) == PoolId.unwrap(poolId)) {
            revert IndependentMarketRequired(poolId);
        }
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        if (!_currencyExitOnly(token0) && !_currencyExitOnly(token1)) revert BasketMarketNotExitOnly(poolId);
        if (market.lifecycle == LibBasketMarkets.Lifecycle.Decommissioned) {
            revert LibBasketMarkets.BasketMarketNotActive(poolId);
        }
        uint256 count = LibProtocolPools.protocolPoolStorage().activePolPositionCount[poolId];
        if (count != 0) revert ActiveProtocolPolPositions(poolId, count);
        _stopRangeGauge(ls, key);
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(address(key.hooks));
        hook.decommissionPool(key);
        LibBasketMarkets.transition(poolId, LibBasketMarkets.Lifecycle.Decommissioned);
        _settleHookAsset(hook, key, poolId, key.currency0);
        _settleHookAsset(hook, key, poolId, key.currency1);
        _recoverMarketCurrency(poolId, token0, token1);
        _recoverMarketCurrency(poolId, token1, token0);
        LibProtocolPools.protocolPoolStorage().polDecommissionFinalized[poolId] = true;
        emit BasketMarketUnwound(poolId);
    }

    function _currencyExitOnly(address token) private view returns (bool) {
        uint256 idPlusOne = LibRestrictedBasket.restrictedStorage().basketIds[token];
        return idPlusOne != 0
            && LibBasket.basketStorage().baskets[idPlusOne - 1].status == IStaticsBasket.BasketStatus.ExitOnly;
    }

    function _recoverMarketCurrency(PoolId poolId, address token, address paired) private {
        bytes32 account = LibCustody.protocolPolAccount(PoolId.unwrap(poolId));
        uint256 amount = LibCustody.accountReserved(account, token);
        if (amount == 0) return;
        uint256 idPlusOne = LibRestrictedBasket.restrictedStorage().basketIds[token];
        if (idPlusOne != 0) {
            LibCustody.release(account, token, amount);
            _burnPolBasketTokens(_basket(idPlusOne - 1), idPlusOne - 1, paired, amount);
        } else {
            LibCustody.moveReservation(account, LibCustody.feeAccount(), token, amount);
            LibGlobalRewards.accrueReservedTreasuryFee(token, amount);
        }
    }

    function _settleHookAsset(IStaticsSwapFeeHook hook, PoolKey memory key, PoolId poolId, Currency currency) private {
        address token = Currency.unwrap(currency);
        // Distribution settlement can reclassify an ineligible basket-staker share into POL.
        // Normalize and accrue revenue first so the following POL drain includes that final amount.
        uint256 revenueBefore = IERC20(token).balanceOf(address(this));
        IStaticsSwapFeeHook.FeeDistribution memory distribution =
            hook.settleFeeDistribution(key, currency, address(this));
        _enforceReleased(token, revenueBefore, _distributionTotal(distribution));
        _accrueDistribution(poolId, token, distribution);

        uint256 pending = hook.pendingProtocolPol(poolId, currency);
        if (pending != 0) {
            uint256 beforeBalance = IERC20(token).balanceOf(address(this));
            uint256 settled = hook.settleProtocolPol(key, currency, address(this), pending);
            _enforceReleased(token, beforeBalance, settled);
            LibCustody.reserve(LibCustody.protocolPolAccount(PoolId.unwrap(poolId)), token, settled);
        }
    }

    function _burnPolBasketTokens(
        LibBasket.Basket storage configured,
        uint256 basketId,
        address sourcePoolAsset,
        uint256 shares
    ) private {
        if (shares == 0) return;
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        uint256 supply = IERC20(configured.token).totalSupply();
        uint256 balanceBefore = LibCustody.beginUnreservedDebit(configured.token, shares);
        StaticsBasketToken(configured.token).burn(address(this), shares);
        uint256 spent = LibCustody.finishUnreservedDebit(configured.token, balanceBefore, shares);
        if (spent != shares) revert ReleasedAmountMismatch(configured.token, shares, spent);

        TreasuryAccrual memory accrual = TreasuryAccrual({
            basketId: basketId,
            sourcePoolAsset: sourcePoolAsset,
            shares: shares,
            supply: supply,
            basketAccount: LibCustody.basketAccount(basketId),
            feeAccount: LibCustody.feeAccount()
        });
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            _accrueTreasuryAsset(bs, configured, accrual, i);
        }
    }

    function _accrueTreasuryAsset(
        LibBasket.BasketStorage storage bs,
        LibBasket.Basket storage configured,
        TreasuryAccrual memory accrual,
        uint256 index
    ) private {
        address rewardAsset = configured.assets[index];
        uint256 amount = LibBasket.backingReduction(configured.bundleAmounts[index], accrual.supply, accrual.shares);
        uint256 available = bs.vaultBalances[accrual.basketId][rewardAsset];
        if (amount > available) revert InsufficientVaultBalance(rewardAsset, amount, available);
        bs.vaultBalances[accrual.basketId][rewardAsset] = available - amount;
        LibCustody.moveReservation(accrual.basketAccount, accrual.feeAccount, rewardAsset, amount);
        LibGlobalRewards.accrueReservedTreasuryFee(rewardAsset, amount);
        emit ProtocolPolTreasuryAccrued(accrual.basketId, accrual.sourcePoolAsset, rewardAsset, amount);
    }

    function _configuredPool(uint256 basketId, address asset)
        private
        view
        returns (LibBasketLiquidity.LiquidityStorage storage ls, LibBasketLiquidity.CanonicalPool storage stored)
    {
        ls = LibBasketLiquidity.liquidityStorage();
        stored = ls.canonicalPools[basketId][asset];
        if (address(stored.key.hooks) == address(0)) revert CanonicalPoolNotConfigured(basketId, asset);
    }

    function _stopRangeGauge(LibBasketLiquidity.LiquidityStorage storage ls, PoolKey memory key) private {
        PoolId poolId = key.toId();
        (, int24 liveTick,,) = IPoolManager(ls.poolManager).getSlot0(poolId);
        uint40 currentTime = LibRangeGauge.timestamp40(block.timestamp);
        IStaticsGaugeIncentives(address(this)).checkpointGaugePool(poolId);
        LibRangeGauge.stopGauge(poolId, key.tickSpacing, liveTick, currentTime);
        IStaticsGaugeIncentives(address(this)).checkpointGaugePool(poolId);
        emit IStaticsRangeGauge.PoolGaugeStopped(poolId);
    }

    function _basket(uint256 basketId) private view returns (LibBasket.Basket storage configured) {
        configured = LibBasket.basketStorage().baskets[basketId];
        if (configured.token == address(0)) revert BasketNotFound(basketId);
    }

    function _enforceConstituent(LibBasket.Basket storage configured, uint256 basketId, address asset) private view {
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            if (configured.assets[i] == asset) return;
        }
        revert AssetNotInBasket(basketId, asset);
    }

    function _enforceReleased(address token, uint256 beforeBalance, uint256 reported) private view {
        uint256 afterBalance = IERC20(token).balanceOf(address(this));
        uint256 observed = afterBalance > beforeBalance ? afterBalance - beforeBalance : 0;
        if (observed != reported) revert ReleasedAmountMismatch(token, reported, observed);
    }

    function _accrueDistribution(PoolId poolId, address token, IStaticsSwapFeeHook.FeeDistribution memory distribution)
        private
    {
        LibProtocolRevenue.accrueReceived(
            poolId,
            token,
            IStaticsProtocolRevenue.ProtocolFeeDistribution({
                basketStaker: distribution.basketStaker,
                staticsStaker: distribution.staticsStaker,
                creator: distribution.creator,
                treasury: distribution.treasury
            })
        );
    }

    function _distributionTotal(IStaticsSwapFeeHook.FeeDistribution memory distribution)
        private
        pure
        returns (uint256)
    {
        return distribution.basketStaker + distribution.staticsStaker + distribution.creator + distribution.treasury;
    }
}
