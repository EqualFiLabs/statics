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
import {LibRangeGauge} from "../libraries/LibRangeGauge.sol";
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

    event PermanentLiquidityTreasuryAccrued(
        uint256 indexed basketId, address indexed sourcePoolAsset, address indexed rewardAsset, uint256 amount
    );
    event BasketLiquidityUnwound(
        uint256 indexed basketId,
        address indexed asset,
        PoolId indexed poolId,
        uint256 constituentReleased,
        uint256 basketTokensBurned
    );

    struct TreasuryAccrual {
        uint256 basketId;
        address sourcePoolAsset;
        uint256 shares;
        uint256 supply;
        bytes32 basketAccount;
        bytes32 feeAccount;
    }

    struct BasketReleaseContext {
        PoolId poolId;
        address basketToken;
        address asset;
        uint256 basketBefore;
        uint256 assetBefore;
        bool basketIsCurrency0;
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
        uint256 basketBefore = IERC20(basketToken).balanceOf(address(this));
        uint256 assetBefore = IERC20(asset).balanceOf(address(this));
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(ls.hook);
        if (hook.poolDecommissioned(stored.key.toId())) revert BasketLiquidityAlreadyUnwound(basketId, asset);
        _stopRangeGauge(ls, stored.key);
        hook.decommissionPool(stored.key);
        PoolId poolId = stored.key.toId();
        IStaticsSwapFeeHook.PermanentLiquidityRelease memory released =
            hook.releasePermanentLiquidity(stored.key, address(this));
        BasketReleaseContext memory context = BasketReleaseContext({
            poolId: poolId,
            basketToken: basketToken,
            asset: asset,
            basketBefore: basketBefore,
            assetBefore: assetBefore,
            basketIsCurrency0: Currency.unwrap(stored.key.currency0) == basketToken
        });
        (uint256 basketTokens, uint256 constituent) = _settleBasketRelease(context, released);

        if (constituent != 0) {
            LibCustody.reserve(LibCustody.feeAccount(), asset, constituent);
            LibGlobalRewards.accrueReservedTreasuryFee(asset, constituent);
            emit PermanentLiquidityTreasuryAccrued(basketId, asset, asset, constituent);
        }
        _burnPolBasketTokens(configured, basketId, asset, basketTokens);
        emit BasketLiquidityUnwound(basketId, asset, poolId, constituent, basketTokens);
    }

    function _settleBasketRelease(
        BasketReleaseContext memory context,
        IStaticsSwapFeeHook.PermanentLiquidityRelease memory released
    ) private returns (uint256 basketTokens, uint256 constituent) {
        basketTokens = context.basketIsCurrency0
            ? released.principal0 + released.pendingPol0
            : released.principal1 + released.pendingPol1;
        constituent = context.basketIsCurrency0
            ? released.principal1 + released.pendingPol1
            : released.principal0 + released.pendingPol0;
        IStaticsSwapFeeHook.FeeDistribution memory basketDistribution =
            context.basketIsCurrency0 ? released.distribution0 : released.distribution1;
        IStaticsSwapFeeHook.FeeDistribution memory assetDistribution =
            context.basketIsCurrency0 ? released.distribution1 : released.distribution0;
        _enforceReleased(
            context.basketToken, context.basketBefore, basketTokens + _distributionTotal(basketDistribution)
        );
        _enforceReleased(context.asset, context.assetBefore, constituent + _distributionTotal(assetDistribution));
        _accrueDistribution(context.poolId, context.basketToken, basketDistribution);
        _accrueDistribution(context.poolId, context.asset, assetDistribution);
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
        emit PermanentLiquidityTreasuryAccrued(accrual.basketId, accrual.sourcePoolAsset, rewardAsset, amount);
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

    function _stopRangeGauge(LibBasketLiquidity.LiquidityStorage storage ls, PoolKey storage key) private {
        PoolId poolId = key.toId();
        (, int24 liveTick,,) = IPoolManager(ls.poolManager).getSlot0(poolId);
        uint40 currentTime = LibRangeGauge.timestamp40(block.timestamp);
        IStaticsGaugeIncentives(address(this)).checkpointGaugePool(poolId);
        LibRangeGauge.stopGauge(poolId, key.tickSpacing, liveTick, currentTime);
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
