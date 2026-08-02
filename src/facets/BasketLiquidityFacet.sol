// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsBasketLiquidity} from "../interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsLiquidityManager} from "../interfaces/IStaticsLiquidityManager.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibBasketLiquidityMath} from "../libraries/LibBasketLiquidityMath.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {StaticsBasketToken} from "../tokens/StaticsBasketToken.sol";

contract BasketLiquidityFacet is IStaticsBasketLiquidity, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 private constant CANONICAL_LP_FEE = 500;
    int24 private constant CANONICAL_TICK_SPACING = 10;
    uint40 private constant POOL_WARMUP = 1 hours;
    uint32 private constant REFERENCE_WINDOW = 30 minutes;
    uint16 private constant MAX_DEVIATION_BPS = 100;
    int24 private constant MAX_POSITIVE_TICK_DEVIATION = 99;
    int24 private constant MAX_NEGATIVE_TICK_DEVIATION = -100;
    uint40 private constant LIQUIDITY_INTERVAL = 24 hours;
    uint40 private constant YOUNG_POOL_PERIOD = 7 days;
    uint16 private constant YOUNG_POOL_CAP_BPS = 1_000;
    uint256 private constant MINIMUM_COMPOUND_SHARES = 1e12;
    uint16 private constant LP_POL_SHARE_BPS = 9_000;
    uint16 private constant LP_REVENUE_SHARE_BPS = 1_000;

    error LiquidityIntegrationAlreadyInstalled();
    error LiquidityIntegrationNotInstalled();
    error LiquidityManagerAlreadyInstalled();
    error LiquidityManagerNotInstalled();
    error BasketNotFound(uint256 basketId);
    error AssetNotInBasket(uint256 basketId, address asset);
    error CanonicalPoolAlreadyConfigured(uint256 basketId, address asset);
    error CanonicalPoolNotConfigured(uint256 basketId, address asset);
    error CanonicalPoolAlreadyAssociated(PoolId poolId, uint256 basketId, address asset);
    error InvalidCanonicalPoolStatus(uint256 basketId, address asset, CanonicalPoolStatus status);
    error PoolStillWarming(uint256 basketId, address asset, uint256 readyAt);
    error InsufficientObservations(uint256 basketId, address asset, uint8 cardinality);
    error PriceDeviationTooHigh(int24 referenceTick, int24 spotTick);
    error CanonicalPoolAlreadySynced(uint256 basketId, address asset);
    error LiquidityEpochNotReady(uint256 basketId, uint256 readyAt);
    error CompoundAmountBelowMinimum(uint256 shares, uint256 minimumShares);
    error NoUsablePoolLiquidity(uint256 basketId, address asset);
    error BasketTokenDemandExceedsMint(uint256 demand, uint256 minted);
    error UnexpectedLpCollectionDebit(address token, uint256 amount);
    error BasketNotExitOnly(uint256 basketId, IStaticsBasket.BasketStatus status);
    error BasketLiquidityAlreadyUnwound(uint256 basketId, address asset);
    error ActionPaused(uint256 action);
    error HookSettlementMismatch(
        address token, uint256 reportedSpent, uint256 observedSpent, uint256 reportedReceived, uint256 observedReceived
    );

    struct WithdrawalSnapshot {
        uint256 hookBalance0;
        uint256 diamondBalance0;
        uint256 hookBalance1;
        uint256 diamondBalance1;
    }

    struct CompoundPoolPlan {
        address asset;
        PoolKey key;
        uint160 sqrtPriceX96;
        uint256 backingAdded;
        uint256 assetSpent;
        uint256 assetReceived;
        uint128 liquidity;
        uint256 basketTokenLimit;
        uint256 assetLimit;
    }

    function installCanonicalPoolIntegration(address poolManager, address hook) external {
        LibDiamond.enforceIsContractOwner();
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (ls.integrationInstalled) revert LiquidityIntegrationAlreadyInstalled();
        ls.poolManager = poolManager;
        ls.hook = hook;
        ls.integrationInstalled = true;
        emit LiquidityIntegrationInstalled(poolManager, hook);
    }

    function installLiquidityManager(address manager) external {
        LibDiamond.enforceIsContractOwner();
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (ls.managerInstalled) revert LiquidityManagerAlreadyInstalled();
        ls.manager = manager;
        ls.managerInstalled = true;
        emit LiquidityManagerInstalled(manager);
    }

    function initializeCanonicalPool(uint256 basketId, address asset, uint160 sqrtPriceX96)
        external
        returns (PoolId poolId, int24 tick)
    {
        _enforceLiquidityAvailable();
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (!ls.integrationInstalled) revert LiquidityIntegrationNotInstalled();
        LibBasket.Basket storage configured = _basket(basketId);
        LibBasket.enforceActive(configured, basketId);
        _enforceConstituent(configured, basketId, asset);

        LibBasketLiquidity.CanonicalPool storage stored = ls.canonicalPools[basketId][asset];
        if (stored.status != CanonicalPoolStatus.Unconfigured) {
            revert CanonicalPoolAlreadyConfigured(basketId, asset);
        }
        (Currency currency0, Currency currency1) = address(configured.token) < asset
            ? (Currency.wrap(configured.token), Currency.wrap(asset))
            : (Currency.wrap(asset), Currency.wrap(configured.token));
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: CANONICAL_LP_FEE,
            tickSpacing: CANONICAL_TICK_SPACING,
            hooks: IHooks(ls.hook)
        });
        poolId = key.toId();
        LibBasketLiquidity.PoolAssociation storage association = ls.poolAssociations[poolId];
        if (association.associated) {
            revert CanonicalPoolAlreadyAssociated(poolId, association.basketId, association.asset);
        }

        stored.key = key;
        stored.status = CanonicalPoolStatus.Warming;
        stored.initializedAt = uint40(block.timestamp);
        association.basketId = basketId;
        association.asset = asset;
        association.associated = true;

        IStaticsSwapFeeHook(ls.hook).registerPool(key);
        tick = IPoolManager(ls.poolManager).initialize(key, sqrtPriceX96);
        if (ls.managerInstalled) _syncPoolToManager(ls, basketId, asset, stored);
        emit CanonicalPoolInitialized(
            basketId, asset, poolId, Currency.unwrap(currency0), Currency.unwrap(currency1), sqrtPriceX96, tick
        );
    }

    function checkpointCanonicalPool(uint256 basketId, address asset) external returns (bool observationStored) {
        (LibBasketLiquidity.LiquidityStorage storage ls, LibBasketLiquidity.CanonicalPool storage stored) =
            _configuredPool(basketId, asset);
        observationStored = IStaticsSwapFeeHook(ls.hook).checkpoint(stored.key);
        emit CanonicalPoolCheckpointed(basketId, asset, stored.key.toId(), observationStored);
    }

    function activateCanonicalPool(uint256 basketId, address asset)
        external
        returns (int24 referenceTick, int24 spotTick)
    {
        _enforceLiquidityAvailable();
        LibBasket.enforceActive(_basket(basketId), basketId);
        (LibBasketLiquidity.LiquidityStorage storage ls, LibBasketLiquidity.CanonicalPool storage stored) =
            _configuredPool(basketId, asset);
        if (stored.status != CanonicalPoolStatus.Warming) {
            revert InvalidCanonicalPoolStatus(basketId, asset, stored.status);
        }
        uint256 readyAt = uint256(stored.initializedAt) + POOL_WARMUP;
        if (block.timestamp < readyAt) revert PoolStillWarming(basketId, asset, readyAt);

        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(ls.hook);
        hook.checkpoint(stored.key);
        IStaticsSwapFeeHook.OracleStateView memory oracle = hook.oracleState(stored.key.toId());
        if (oracle.observationCardinality < 2) {
            revert InsufficientObservations(basketId, asset, oracle.observationCardinality);
        }
        (referenceTick, spotTick,) = hook.consult(stored.key.toId(), REFERENCE_WINDOW);
        int256 deviation = int256(spotTick) - int256(referenceTick);
        if (deviation > MAX_POSITIVE_TICK_DEVIATION || deviation < MAX_NEGATIVE_TICK_DEVIATION) {
            revert PriceDeviationTooHigh(referenceTick, spotTick);
        }
        stored.status = CanonicalPoolStatus.Active;
        stored.activatedAt = uint40(block.timestamp);
        emit CanonicalPoolActivated(basketId, asset, stored.key.toId(), referenceTick, spotTick);
    }

    function syncCanonicalPoolToManager(uint256 basketId, address asset) external returns (bool synced) {
        (LibBasketLiquidity.LiquidityStorage storage ls, LibBasketLiquidity.CanonicalPool storage stored) =
            _configuredPool(basketId, asset);
        if (!ls.managerInstalled) revert LiquidityManagerNotInstalled();
        if (ls.managerPoolSynced[basketId][asset]) revert CanonicalPoolAlreadySynced(basketId, asset);
        _syncPoolToManager(ls, basketId, asset, stored);
        return true;
    }

    function compoundBasketLiquidity(uint256 basketId) external nonReentrant returns (uint256 sharesMinted) {
        _enforceLiquidityAvailable();
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        LibBasket.Basket storage configured = _basket(basketId);
        LibBasket.enforceActive(configured, basketId);
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (!ls.managerInstalled) revert LiquidityManagerNotInstalled();

        LibBasketLiquidity.BasketLiquidityState storage state = ls.basketLiquidityStates[basketId];
        if (state.nextCompoundAt != 0 && block.timestamp < state.nextCompoundAt) {
            revert LiquidityEpochNotReady(basketId, state.nextCompoundAt);
        }

        (CompoundPoolPlan[] memory plans, bool youngPoolCapApplied) = _prepareCompoundPools(ls, configured, basketId);
        sharesMinted = _compoundShares(ls, configured, basketId, youngPoolCapApplied);
        if (sharesMinted < MINIMUM_COMPOUND_SHARES) {
            revert CompoundAmountBelowMinimum(sharesMinted, MINIMUM_COMPOUND_SHARES);
        }

        uint256 supply = IERC20(configured.token).totalSupply();
        _fundManagerInventory(bs, ls, configured, basketId, supply, sharesMinted, plans);
        StaticsBasketToken(configured.token).mint(ls.manager, sharesMinted);
        IStaticsLiquidityManager(ls.manager).creditProtocolInventory(basketId, configured.token, sharesMinted);
        _sizePoolPlans(ls.manager, configured.token, basketId, plans);
        _deployCompoundPlans(ls.manager, basketId, plans);

        state.lastCompoundAt = uint40(block.timestamp);
        state.nextCompoundAt = uint40(block.timestamp) + LIQUIDITY_INTERVAL;
        state.cumulativeSharesMinted += sharesMinted;
        emit BasketLiquidityCompounded(basketId, sharesMinted, state.nextCompoundAt, youngPoolCapApplied);
    }

    function liquidityIntegration() external view returns (address poolManager, address hook, bool installed) {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        return (ls.poolManager, ls.hook, ls.integrationInstalled);
    }

    function liquidityManager() external view returns (address manager, bool installed) {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        return (ls.manager, ls.managerInstalled);
    }

    function basketLiquidityState(uint256 basketId) external view returns (BasketLiquidityStateView memory state) {
        LibBasketLiquidity.BasketLiquidityState storage stored =
            LibBasketLiquidity.liquidityStorage().basketLiquidityStates[basketId];
        state = BasketLiquidityStateView({
            lastCompoundAt: stored.lastCompoundAt,
            nextCompoundAt: stored.nextCompoundAt,
            cumulativeSharesMinted: stored.cumulativeSharesMinted
        });
    }

    function cumulativeLiquidityFunding(uint256 basketId, address asset)
        external
        view
        returns (uint256 assetSpent, uint256 assetReceived)
    {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        return (ls.cumulativeLiquidityAssetSent[basketId][asset], ls.cumulativeLiquidityAssetReceived[basketId][asset]);
    }

    function liquidityEpochParameters()
        external
        pure
        returns (uint40 interval, uint40 youngPoolPeriod, uint16 youngPoolCapBps, uint256 minimumShares)
    {
        return (LIQUIDITY_INTERVAL, YOUNG_POOL_PERIOD, YOUNG_POOL_CAP_BPS, MINIMUM_COMPOUND_SHARES);
    }

    function protocolLpFeeAllocation() external pure returns (uint16 polShareBps, uint16 revenueShareBps) {
        return (LP_POL_SHARE_BPS, LP_REVENUE_SHARE_BPS);
    }

    function liquiditySafetyParameters()
        external
        pure
        returns (uint24 lpFee, int24 tickSpacing, uint40 warmup, uint32 referenceWindow, uint16 maxDeviationBps)
    {
        return (CANONICAL_LP_FEE, CANONICAL_TICK_SPACING, POOL_WARMUP, REFERENCE_WINDOW, MAX_DEVIATION_BPS);
    }

    function canonicalPool(uint256 basketId, address asset) external view returns (CanonicalPoolView memory pool) {
        LibBasket.Basket storage configured = _basket(basketId);
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        LibBasketLiquidity.CanonicalPool storage stored = ls.canonicalPools[basketId][asset];
        if (stored.status == CanonicalPoolStatus.Unconfigured) revert CanonicalPoolNotConfigured(basketId, asset);
        PoolId poolId = stored.key.toId();
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(ls.hook);
        IStaticsSwapFeeHook.OracleStateView memory oracle = hook.oracleState(poolId);
        (, int24 spotTick,,) = IPoolManager(ls.poolManager).getSlot0(poolId);
        int24 referenceTick;
        bool referenceAvailable;
        try hook.consult(poolId, REFERENCE_WINDOW) returns (int24 referenceTick_, int24, uint40) {
            referenceTick = referenceTick_;
            referenceAvailable = true;
        } catch {}
        pool = CanonicalPoolView({
            poolId: poolId,
            basketToken: configured.token,
            asset: asset,
            currency0: Currency.unwrap(stored.key.currency0),
            currency1: Currency.unwrap(stored.key.currency1),
            hook: address(stored.key.hooks),
            lpFee: stored.key.fee,
            tickSpacing: stored.key.tickSpacing,
            status: stored.status,
            initializedAt: stored.initializedAt,
            activatedAt: stored.activatedAt,
            spotTick: spotTick,
            referenceTick: referenceTick,
            observationCardinality: oracle.observationCardinality,
            referenceAvailable: referenceAvailable
        });
    }

    function settleCanonicalHookFees(uint256 basketId, address asset)
        external
        nonReentrant
        returns (HookSettlementTotals memory settled)
    {
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        LibBasket.Basket storage configured = _basket(basketId);
        (LibBasketLiquidity.LiquidityStorage storage ls, LibBasketLiquidity.CanonicalPool storage stored) =
            _configuredPool(basketId, asset);
        PoolId poolId = stored.key.toId();
        address currency0 = Currency.unwrap(stored.key.currency0);
        address currency1 = Currency.unwrap(stored.key.currency1);
        WithdrawalSnapshot memory before_ = WithdrawalSnapshot({
            hookBalance0: IERC20(currency0).balanceOf(ls.hook),
            diamondBalance0: IERC20(currency0).balanceOf(address(this)),
            hookBalance1: IERC20(currency1).balanceOf(ls.hook),
            diamondBalance1: IERC20(currency1).balanceOf(address(this))
        });

        (uint256 spent0, uint256 received0, uint256 spent1, uint256 received1) =
            IStaticsSwapFeeHook(ls.hook).withdrawPoolFees(poolId);
        _verifySettlement(currency0, ls.hook, before_.hookBalance0, before_.diamondBalance0, spent0, received0);
        _verifySettlement(currency1, ls.hook, before_.hookBalance1, before_.diamondBalance1, spent1, received1);

        bool basketIsCurrency0 = currency0 == configured.token;
        settled = HookSettlementTotals({
            constituentHookDebit: basketIsCurrency0 ? spent1 : spent0,
            constituentRevenue: basketIsCurrency0 ? received1 : received0,
            basketTokenHookDebit: basketIsCurrency0 ? spent0 : spent1,
            basketTokensBurned: basketIsCurrency0 ? received0 : received1
        });
        bytes32 account = LibCustody.basketAccount(basketId);
        if (settled.constituentRevenue != 0) {
            LibCustody.reserve(account, asset, settled.constituentRevenue);
            bs.protocolRevenue[basketId][asset] += settled.constituentRevenue;
            ls.cumulativeHookRevenue[basketId][asset] += settled.constituentRevenue;
        }
        if (settled.basketTokensBurned != 0) {
            uint256[] memory amounts =
                LibBasketLiquidity.burnBasketTokensToRevenue(bs, configured, basketId, settled.basketTokensBurned);
            uint256 length = configured.assets.length;
            for (uint256 i; i < length; ++i) {
                ls.cumulativeHookRevenue[basketId][configured.assets[i]] += amounts[i];
                emit HookBasketTokenRevenueReclassified(basketId, asset, configured.assets[i], amounts[i]);
            }
        }
        _accumulateHookSettlement(ls.cumulativeHookSettlements[basketId][asset], settled);
        emit CanonicalHookFeesSettled(
            basketId,
            asset,
            poolId,
            settled.constituentHookDebit,
            settled.constituentRevenue,
            settled.basketTokenHookDebit,
            settled.basketTokensBurned
        );
    }

    function collectProtocolLpFees(uint256 basketId, address asset)
        external
        nonReentrant
        returns (ProtocolLpFeeTotals memory fees)
    {
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        LibBasket.Basket storage configured = _basket(basketId);
        (LibBasketLiquidity.LiquidityStorage storage ls, LibBasketLiquidity.CanonicalPool storage stored) =
            _configuredPool(basketId, asset);
        if (!ls.managerInstalled) revert LiquidityManagerNotInstalled();
        return _collectProtocolLpFees(bs, configured, ls, stored, basketId, asset);
    }

    function unwindBasketLiquidity(uint256 basketId, address asset) external nonReentrant {
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        LibBasket.Basket storage configured = _basket(basketId);
        if (configured.status != IStaticsBasket.BasketStatus.ExitOnly) {
            revert BasketNotExitOnly(basketId, configured.status);
        }
        _enforceConstituent(configured, basketId, asset);
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (ls.liquidityUnwound[basketId][asset]) revert BasketLiquidityAlreadyUnwound(basketId, asset);

        uint256 positionTokenId;
        IStaticsLiquidityManager manager;
        if (ls.managerInstalled) {
            manager = IStaticsLiquidityManager(ls.manager);
            positionTokenId = manager.protocolPositionId(basketId, asset);
            if (positionTokenId != 0) {
                LibBasketLiquidity.CanonicalPool storage stored = ls.canonicalPools[basketId][asset];
                _collectProtocolLpFees(bs, configured, ls, stored, basketId, asset);
                IStaticsLiquidityManager.PositionMovement memory movement =
                    manager.burnProtocolPosition(basketId, asset, 0, 0, block.timestamp);
                if (movement.spent0 != 0) {
                    revert UnexpectedLpCollectionDebit(Currency.unwrap(stored.key.currency0), movement.spent0);
                }
                if (movement.spent1 != 0) {
                    revert UnexpectedLpCollectionDebit(Currency.unwrap(stored.key.currency1), movement.spent1);
                }
            }
        }

        uint256 reserveReclassified = ls.liquidityReserve[basketId][asset];
        if (reserveReclassified != 0) {
            ls.liquidityReserve[basketId][asset] = 0;
            bs.protocolRevenue[basketId][asset] += reserveReclassified;
        }
        (uint256 constituentDebit, uint256 constituentRevenue) =
            _returnConstituentInventory(bs, manager, basketId, asset);
        (uint256 basketTokenDebit, uint256 basketTokensBurned) =
            _returnBasketTokenInventory(bs, configured, manager, basketId);

        ls.liquidityUnwound[basketId][asset] = true;
        emit BasketLiquidityUnwound(
            basketId,
            asset,
            positionTokenId,
            reserveReclassified,
            constituentDebit,
            constituentRevenue,
            basketTokenDebit,
            basketTokensBurned
        );
    }

    function pendingCanonicalHookFees(uint256 basketId, address asset)
        external
        view
        returns (uint256 basketTokenAmount, uint256 constituentAmount)
    {
        (LibBasketLiquidity.LiquidityStorage storage ls, LibBasketLiquidity.CanonicalPool storage stored) =
            _configuredPool(basketId, asset);
        PoolId poolId = stored.key.toId();
        address basketToken = _basket(basketId).token;
        basketTokenAmount = IStaticsSwapFeeHook(ls.hook).accruedFees(poolId, Currency.wrap(basketToken));
        constituentAmount = IStaticsSwapFeeHook(ls.hook).accruedFees(poolId, Currency.wrap(asset));
    }

    function cumulativeCanonicalHookSettlement(uint256 basketId, address asset)
        external
        view
        returns (HookSettlementTotals memory totals)
    {
        return LibBasketLiquidity.liquidityStorage().cumulativeHookSettlements[basketId][asset];
    }

    function cumulativeHookRevenue(uint256 basketId, address revenueAsset) external view returns (uint256 amount) {
        return LibBasketLiquidity.liquidityStorage().cumulativeHookRevenue[basketId][revenueAsset];
    }

    function cumulativeProtocolLpFees(uint256 basketId, address asset)
        external
        view
        returns (ProtocolLpFeeTotals memory totals)
    {
        return LibBasketLiquidity.liquidityStorage().cumulativeProtocolLpFees[basketId][asset];
    }

    function basketLiquidityUnwound(uint256 basketId, address asset) external view returns (bool unwound) {
        return LibBasketLiquidity.liquidityStorage().liquidityUnwound[basketId][asset];
    }

    function liquidityReserve(uint256 basketId, address asset) external view returns (uint256 amount) {
        return LibBasketLiquidity.liquidityStorage().liquidityReserve[basketId][asset];
    }

    function cumulativePrimaryFees(uint256 basketId, address asset)
        external
        view
        returns (PrimaryFeeTotals memory totals)
    {
        LibBasketLiquidity.PrimaryFeeTotals storage stored =
            LibBasketLiquidity.liquidityStorage().cumulativePrimaryFees[basketId][asset];
        totals = PrimaryFeeTotals({
            holderAmount: stored.holderAmount,
            liquidityAmount: stored.liquidityAmount,
            protocolAmount: stored.protocolAmount
        });
    }

    function _prepareCompoundPools(
        LibBasketLiquidity.LiquidityStorage storage ls,
        LibBasket.Basket storage configured,
        uint256 basketId
    ) private returns (CompoundPoolPlan[] memory plans, bool youngPoolCapApplied) {
        uint256 length = configured.assets.length;
        plans = new CompoundPoolPlan[](length);
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(ls.hook);
        for (uint256 i; i < length; ++i) {
            address asset = configured.assets[i];
            LibBasketLiquidity.CanonicalPool storage stored = ls.canonicalPools[basketId][asset];
            if (stored.status != CanonicalPoolStatus.Active) {
                revert InvalidCanonicalPoolStatus(basketId, asset, stored.status);
            }
            if (!ls.managerPoolSynced[basketId][asset]) _syncPoolToManager(ls, basketId, asset, stored);

            hook.checkpoint(stored.key);
            (int24 referenceTick, int24 spotTick,) = hook.consult(stored.key.toId(), REFERENCE_WINDOW);
            int256 deviation = int256(spotTick) - int256(referenceTick);
            if (deviation > MAX_POSITIVE_TICK_DEVIATION || deviation < MAX_NEGATIVE_TICK_DEVIATION) {
                revert PriceDeviationTooHigh(referenceTick, spotTick);
            }
            (uint160 sqrtPriceX96,,,) = IPoolManager(ls.poolManager).getSlot0(stored.key.toId());
            plans[i].asset = asset;
            plans[i].key = stored.key;
            plans[i].sqrtPriceX96 = sqrtPriceX96;
            if (block.timestamp < uint256(stored.activatedAt) + YOUNG_POOL_PERIOD) youngPoolCapApplied = true;
        }
    }

    function _compoundShares(
        LibBasketLiquidity.LiquidityStorage storage ls,
        LibBasket.Basket storage configured,
        uint256 basketId,
        bool youngPoolCapApplied
    ) private view returns (uint256 shares) {
        shares = type(uint256).max;
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            uint256 candidate = LibBasketLiquidityMath.maxSharesForMatchedReserve(
                ls.liquidityReserve[basketId][configured.assets[i]], configured.bundleAmounts[i]
            );
            if (candidate < shares) shares = candidate;
        }
        if (youngPoolCapApplied) shares = Math.mulDiv(shares, YOUNG_POOL_CAP_BPS, 10_000);
    }

    function _fundManagerInventory(
        LibBasket.BasketStorage storage bs,
        LibBasketLiquidity.LiquidityStorage storage ls,
        LibBasket.Basket storage configured,
        uint256 basketId,
        uint256 supply,
        uint256 shares,
        CompoundPoolPlan[] memory plans
    ) private {
        bytes32 account = LibCustody.basketAccount(basketId);
        uint256 length = plans.length;
        for (uint256 i; i < length; ++i) {
            CompoundPoolPlan memory plan = plans[i];
            uint256 backing = LibBasket.backingIncrease(configured.bundleAmounts[i], supply, shares);
            uint256 available = ls.liquidityReserve[basketId][plan.asset];
            if (backing > available) revert NoUsablePoolLiquidity(basketId, plan.asset);

            bs.vaultBalances[basketId][plan.asset] += backing;
            available -= backing;
            (uint256 spent, uint256 received) =
                LibCustody.pushReserved(account, plan.asset, ls.manager, backing, backing);
            if (spent < backing) LibCustody.reserve(account, plan.asset, backing - spent);
            if (spent > available) revert NoUsablePoolLiquidity(basketId, plan.asset);
            ls.liquidityReserve[basketId][plan.asset] = available - spent;
            ls.cumulativeLiquidityAssetSent[basketId][plan.asset] += spent;
            ls.cumulativeLiquidityAssetReceived[basketId][plan.asset] += received;
            if (received != 0) {
                IStaticsLiquidityManager(ls.manager).creditProtocolInventory(basketId, plan.asset, received);
            }
            plans[i].backingAdded = backing;
            plans[i].assetSpent = spent;
            plans[i].assetReceived = received;
        }
    }

    function _sizePoolPlans(address manager, address basketToken, uint256 basketId, CompoundPoolPlan[] memory plans)
        private
        view
    {
        IStaticsLiquidityManager liquidityManager_ = IStaticsLiquidityManager(manager);
        uint256 shares = liquidityManager_.protocolInventory(basketId, basketToken);
        uint256 totalBasketDemand;
        uint256 length = plans.length;
        for (uint256 i; i < length; ++i) {
            CompoundPoolPlan memory plan = plans[i];
            bool assetIsCurrency0 = Currency.unwrap(plan.key.currency0) == plan.asset;
            (plans[i].liquidity, plans[i].basketTokenLimit, plans[i].assetLimit) =
                LibBasketLiquidityMath.fullRangeAmounts(
                    plan.sqrtPriceX96, assetIsCurrency0, liquidityManager_.protocolInventory(basketId, plan.asset)
                );
            if (plans[i].liquidity == 0) revert NoUsablePoolLiquidity(basketId, plan.asset);
            totalBasketDemand += plans[i].basketTokenLimit;
        }
        if (totalBasketDemand <= shares) return;

        uint256 basketBudget = shares - length;
        uint256 scaledDemand;
        for (uint256 i; i < length; ++i) {
            CompoundPoolPlan memory plan = plans[i];
            bool assetIsCurrency0 = Currency.unwrap(plan.key.currency0) == plan.asset;
            (plans[i].liquidity, plans[i].basketTokenLimit, plans[i].assetLimit) =
                LibBasketLiquidityMath.scaleLiquidityToBasketBudget(
                    plan.sqrtPriceX96, assetIsCurrency0, plan.liquidity, basketBudget, totalBasketDemand
                );
            if (plans[i].liquidity == 0) revert NoUsablePoolLiquidity(basketId, plan.asset);
            scaledDemand += plans[i].basketTokenLimit;
        }
        if (scaledDemand > shares) revert BasketTokenDemandExceedsMint(scaledDemand, shares);
    }

    function _collectProtocolLpFees(
        LibBasket.BasketStorage storage bs,
        LibBasket.Basket storage configured,
        LibBasketLiquidity.LiquidityStorage storage ls,
        LibBasketLiquidity.CanonicalPool storage stored,
        uint256 basketId,
        address asset
    ) private returns (ProtocolLpFeeTotals memory fees) {
        IStaticsLiquidityManager manager = IStaticsLiquidityManager(ls.manager);
        IStaticsLiquidityManager.PositionMovement memory movement =
            manager.collectProtocolPosition(basketId, asset, block.timestamp);
        address currency0 = Currency.unwrap(stored.key.currency0);
        address currency1 = Currency.unwrap(stored.key.currency1);
        if (movement.spent0 != 0) revert UnexpectedLpCollectionDebit(currency0, movement.spent0);
        if (movement.spent1 != 0) revert UnexpectedLpCollectionDebit(currency1, movement.spent1);

        bool basketIsCurrency0 = currency0 == configured.token;
        fees.constituentCollected = basketIsCurrency0 ? movement.received1 : movement.received0;
        fees.basketTokenCollected = basketIsCurrency0 ? movement.received0 : movement.received1;
        ProtocolLpFeeTotals storage cumulative = ls.cumulativeProtocolLpFees[basketId][asset];
        uint256 constituentRevenueTarget = _nextRevenueDebit(
            cumulative.constituentCollected, cumulative.constituentRevenueDebit, fees.constituentCollected
        );
        uint256 basketTokenRevenueTarget = _nextRevenueDebit(
            cumulative.basketTokenCollected, cumulative.basketTokenRevenueDebit, fees.basketTokenCollected
        );
        (fees.constituentPolRetained, fees.constituentRevenueDebit, fees.constituentRevenue) =
            _settleConstituentLpRevenue(
                bs, manager, basketId, asset, fees.constituentCollected, constituentRevenueTarget
            );
        (fees.basketTokenPolRetained, fees.basketTokenRevenueDebit, fees.basketTokensBurned) =
            _settleBasketTokenLpRevenue(
                bs, configured, manager, basketId, asset, fees.basketTokenCollected, basketTokenRevenueTarget
            );

        _accumulateProtocolLpFees(cumulative, fees);
        emit ProtocolLpFeesCollected(basketId, asset, movement.tokenId, fees);
    }

    function _returnConstituentInventory(
        LibBasket.BasketStorage storage bs,
        IStaticsLiquidityManager manager,
        uint256 basketId,
        address asset
    ) private returns (uint256 debit, uint256 revenue) {
        if (address(manager) == address(0)) return (0, 0);
        uint256 inventory = manager.protocolInventory(basketId, asset);
        if (inventory == 0) return (0, 0);
        (debit, revenue) = manager.returnProtocolInventory(basketId, asset, inventory);
        if (revenue != 0) {
            LibCustody.reserve(LibCustody.basketAccount(basketId), asset, revenue);
            bs.protocolRevenue[basketId][asset] += revenue;
        }
    }

    function _returnBasketTokenInventory(
        LibBasket.BasketStorage storage bs,
        LibBasket.Basket storage configured,
        IStaticsLiquidityManager manager,
        uint256 basketId
    ) private returns (uint256 debit, uint256 burned) {
        if (address(manager) == address(0)) return (0, 0);
        uint256 inventory = manager.protocolInventory(basketId, configured.token);
        if (inventory == 0) return (0, 0);
        (debit, burned) = manager.returnProtocolInventory(basketId, configured.token, inventory);
        if (burned != 0) LibBasketLiquidity.burnBasketTokensToRevenue(bs, configured, basketId, burned);
    }

    function _settleConstituentLpRevenue(
        LibBasket.BasketStorage storage bs,
        IStaticsLiquidityManager manager,
        uint256 basketId,
        address asset,
        uint256 collected,
        uint256 target
    ) private returns (uint256 retained, uint256 revenueDebit, uint256 revenue) {
        retained = collected;
        if (target == 0) return (retained, 0, 0);
        (revenueDebit, revenue) = manager.returnProtocolInventory(basketId, asset, target);
        retained -= revenueDebit;
        if (revenue != 0) {
            LibCustody.reserve(LibCustody.basketAccount(basketId), asset, revenue);
            bs.protocolRevenue[basketId][asset] += revenue;
        }
    }

    function _settleBasketTokenLpRevenue(
        LibBasket.BasketStorage storage bs,
        LibBasket.Basket storage configured,
        IStaticsLiquidityManager manager,
        uint256 basketId,
        address sourcePoolAsset,
        uint256 collected,
        uint256 target
    ) private returns (uint256 retained, uint256 revenueDebit, uint256 burned) {
        retained = collected;
        if (target == 0) return (retained, 0, 0);
        (revenueDebit, burned) = manager.returnProtocolInventory(basketId, configured.token, target);
        retained -= revenueDebit;
        if (burned == 0) return (retained, revenueDebit, 0);
        uint256[] memory amounts = LibBasketLiquidity.burnBasketTokensToRevenue(bs, configured, basketId, burned);
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            emit LpBasketTokenRevenueReclassified(basketId, sourcePoolAsset, configured.assets[i], amounts[i]);
        }
    }

    function _nextRevenueDebit(uint256 priorCollected, uint256 priorRevenueDebit, uint256 collected)
        private
        pure
        returns (uint256)
    {
        return Math.mulDiv(priorCollected + collected, LP_REVENUE_SHARE_BPS, 10_000) - priorRevenueDebit;
    }

    function _deployCompoundPlans(address manager, uint256 basketId, CompoundPoolPlan[] memory plans) private {
        IStaticsLiquidityManager liquidityManager_ = IStaticsLiquidityManager(manager);
        uint256 length = plans.length;
        for (uint256 i; i < length; ++i) {
            CompoundPoolPlan memory plan = plans[i];
            bool assetIsCurrency0 = Currency.unwrap(plan.key.currency0) == plan.asset;
            IStaticsLiquidityManager.PositionRequest memory request = IStaticsLiquidityManager.PositionRequest({
                basketId: basketId,
                asset: plan.asset,
                poolKey: plan.key,
                tickLower: TickMath.minUsableTick(CANONICAL_TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(CANONICAL_TICK_SPACING),
                liquidity: plan.liquidity,
                amount0Limit: assetIsCurrency0 ? plan.assetLimit : plan.basketTokenLimit,
                amount1Limit: assetIsCurrency0 ? plan.basketTokenLimit : plan.assetLimit,
                deadline: block.timestamp
            });
            IStaticsLiquidityManager.PositionMovement memory movement;
            if (liquidityManager_.protocolPositionId(basketId, plan.asset) == 0) {
                movement = liquidityManager_.mintProtocolPosition(request);
            } else {
                movement = liquidityManager_.increaseProtocolPosition(request);
            }
            emit BasketLiquidityPoolFunded(
                basketId,
                plan.asset,
                movement.tokenId,
                plan.backingAdded,
                plan.assetSpent,
                plan.assetReceived,
                plan.basketTokenLimit,
                plan.assetLimit,
                plan.liquidity
            );
        }
    }

    function _syncPoolToManager(
        LibBasketLiquidity.LiquidityStorage storage ls,
        uint256 basketId,
        address asset,
        LibBasketLiquidity.CanonicalPool storage stored
    ) private {
        IStaticsLiquidityManager(ls.manager).registerCanonicalPool(basketId, asset, stored.key);
        ls.managerPoolSynced[basketId][asset] = true;
        emit CanonicalPoolSyncedToManager(basketId, asset, stored.key.toId(), ls.manager);
    }

    function _configuredPool(uint256 basketId, address asset)
        private
        view
        returns (LibBasketLiquidity.LiquidityStorage storage ls, LibBasketLiquidity.CanonicalPool storage stored)
    {
        ls = LibBasketLiquidity.liquidityStorage();
        if (!ls.integrationInstalled) revert LiquidityIntegrationNotInstalled();
        stored = ls.canonicalPools[basketId][asset];
        if (stored.status == CanonicalPoolStatus.Unconfigured) revert CanonicalPoolNotConfigured(basketId, asset);
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

    function _enforceLiquidityAvailable() private view {
        if (LibGovernance.governanceStorage().pausedActions & LibGovernance.PAUSE_LIQUIDITY != 0) {
            revert ActionPaused(LibGovernance.PAUSE_LIQUIDITY);
        }
    }

    function _verifySettlement(
        address token,
        address hook,
        uint256 hookBalanceBefore,
        uint256 diamondBalanceBefore,
        uint256 reportedSpent,
        uint256 reportedReceived
    ) private view {
        uint256 hookBalanceAfter = IERC20(token).balanceOf(hook);
        uint256 diamondBalanceAfter = IERC20(token).balanceOf(address(this));
        uint256 observedSpent = hookBalanceBefore > hookBalanceAfter ? hookBalanceBefore - hookBalanceAfter : 0;
        uint256 observedReceived =
            diamondBalanceAfter > diamondBalanceBefore ? diamondBalanceAfter - diamondBalanceBefore : 0;
        if (reportedSpent != observedSpent || reportedReceived != observedReceived) {
            revert HookSettlementMismatch(token, reportedSpent, observedSpent, reportedReceived, observedReceived);
        }
    }

    function _accumulateHookSettlement(HookSettlementTotals storage cumulative, HookSettlementTotals memory settled)
        private
    {
        cumulative.constituentHookDebit += settled.constituentHookDebit;
        cumulative.constituentRevenue += settled.constituentRevenue;
        cumulative.basketTokenHookDebit += settled.basketTokenHookDebit;
        cumulative.basketTokensBurned += settled.basketTokensBurned;
    }

    function _accumulateProtocolLpFees(ProtocolLpFeeTotals storage cumulative, ProtocolLpFeeTotals memory fees)
        private
    {
        cumulative.constituentCollected += fees.constituentCollected;
        cumulative.constituentPolRetained += fees.constituentPolRetained;
        cumulative.constituentRevenueDebit += fees.constituentRevenueDebit;
        cumulative.constituentRevenue += fees.constituentRevenue;
        cumulative.basketTokenCollected += fees.basketTokenCollected;
        cumulative.basketTokenPolRetained += fees.basketTokenPolRetained;
        cumulative.basketTokenRevenueDebit += fees.basketTokenRevenueDebit;
        cumulative.basketTokensBurned += fees.basketTokensBurned;
    }
}
