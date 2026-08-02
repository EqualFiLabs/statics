// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsLiquidityManager} from "../interfaces/IStaticsLiquidityManager.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {StaticsBasketToken} from "../tokens/StaticsBasketToken.sol";

contract BasketLiquidityFacet is IStaticsBasketLiquidity, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 private constant CANONICAL_LP_FEE = 0;
    int24 private constant CANONICAL_TICK_SPACING = 10;
    uint40 private constant POOL_WARMUP = 1 hours;
    uint32 private constant REFERENCE_WINDOW = 30 minutes;
    uint16 private constant MAX_DEVIATION_BPS = 100;
    int24 private constant MAX_POSITIVE_TICK_DEVIATION = 99;
    int24 private constant MAX_NEGATIVE_TICK_DEVIATION = -100;

    error LiquidityIntegrationAlreadyInstalled();
    error LiquidityIntegrationNotInstalled();
    error LiquidityManagerAlreadyInstalled();
    error LiquidityManagerNotInstalled();
    error InvalidIntegrationContract(address target);
    error InvalidIntegrationBinding(address target, address expected, address actual);
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
    error BasketNotExitOnly(uint256 basketId, IStaticsBasket.BasketStatus status);
    error BasketLiquidityAlreadyUnwound(uint256 basketId, address asset);
    error ReleasedAmountMismatch(address token, uint256 reported, uint256 observed);
    error InsufficientVaultBalance(address asset, uint256 required, uint256 available);
    error ActionPaused(uint256 action);

    function installCanonicalPoolIntegration(address poolManager, address hook) external {
        LibDiamond.enforceIsContractOwner();
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (ls.integrationInstalled) revert LiquidityIntegrationAlreadyInstalled();
        _enforceContract(poolManager);
        _enforceContract(hook);
        _enforceBinding(hook, address(this), IStaticsSwapFeeHook(hook).staticsDiamond());
        _enforceBinding(hook, poolManager, address(StaticsSwapFeeHookLike(hook).poolManager()));
        ls.poolManager = poolManager;
        ls.hook = hook;
        ls.integrationInstalled = true;
        emit LiquidityIntegrationInstalled(poolManager, hook);
    }

    function installLiquidityManager(address manager) external {
        LibDiamond.enforceIsContractOwner();
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (!ls.integrationInstalled) revert LiquidityIntegrationNotInstalled();
        if (ls.managerInstalled) revert LiquidityManagerAlreadyInstalled();
        _enforceContract(manager);
        _enforceBinding(manager, address(this), IStaticsLiquidityManager(manager).staticsDiamond());
        _enforceBinding(manager, ls.poolManager, IStaticsLiquidityManager(manager).poolManager());
        ls.manager = manager;
        ls.managerInstalled = true;
        IERC721Like(IStaticsLiquidityManager(manager).positionManager()).setApprovalForAll(manager, true);
        emit LiquidityManagerInstalled(manager);
    }

    function initializeCanonicalPool(uint256 basketId, address asset, uint160 sqrtPriceX96)
        external
        returns (PoolId poolId, int24 tick)
    {
        LibDiamond.enforceIsContractOwner();
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
        (Currency currency0, Currency currency1) = configured.token < asset
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
        LibDiamond.enforceIsContractOwner();
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
        _enforceDeviation(referenceTick, spotTick);
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

    function setSwapFeeConfiguration(SwapFeeConfiguration calldata configuration) external {
        LibDiamond.enforceIsContractOwner();
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (!ls.integrationInstalled) revert LiquidityIntegrationNotInstalled();
        IStaticsSwapFeeHook(ls.hook)
            .setFeeConfiguration(
                configuration.inputFeeBps,
                configuration.outputFeeBps,
                configuration.polShareBps,
                configuration.liquidityProviderShareBps,
                configuration.basketStakerShareBps,
                configuration.staticsStakerShareBps,
                configuration.treasuryShareBps
            );
        emit SwapFeeConfigurationChanged(configuration);
    }

    function setCanonicalPoolFeeConfiguration(
        uint256 basketId,
        address asset,
        SwapFeeConfiguration calldata configuration
    ) external {
        LibDiamond.enforceIsContractOwner();
        (LibBasketLiquidity.LiquidityStorage storage ls, LibBasketLiquidity.CanonicalPool storage stored) =
            _configuredPool(basketId, asset);
        PoolId poolId = stored.key.toId();
        IStaticsSwapFeeHook(ls.hook)
            .setPoolFeeConfiguration(
                poolId,
                IStaticsSwapFeeHook.FeeConfiguration({
                    inputFeeBps: configuration.inputFeeBps,
                    outputFeeBps: configuration.outputFeeBps,
                    polShareBps: configuration.polShareBps,
                    liquidityProviderShareBps: configuration.liquidityProviderShareBps,
                    basketStakerShareBps: configuration.basketStakerShareBps,
                    staticsStakerShareBps: configuration.staticsStakerShareBps,
                    treasuryShareBps: configuration.treasuryShareBps
                })
            );
        emit CanonicalPoolFeeConfigurationSet(
            basketId,
            asset,
            poolId,
            configuration.inputFeeBps,
            configuration.outputFeeBps,
            configuration.polShareBps,
            configuration.liquidityProviderShareBps,
            configuration.basketStakerShareBps,
            configuration.staticsStakerShareBps,
            configuration.treasuryShareBps
        );
    }

    function clearCanonicalPoolFeeConfiguration(uint256 basketId, address asset) external {
        LibDiamond.enforceIsContractOwner();
        (LibBasketLiquidity.LiquidityStorage storage ls, LibBasketLiquidity.CanonicalPool storage stored) =
            _configuredPool(basketId, asset);
        PoolId poolId = stored.key.toId();
        IStaticsSwapFeeHook(ls.hook).clearPoolFeeConfiguration(poolId);
        emit CanonicalPoolFeeConfigurationCleared(basketId, asset, poolId);
    }

    function unwindBasketLiquidity(uint256 basketId, address asset) external nonReentrant {
        LibBasket.Basket storage configured = _basket(basketId);
        if (configured.status != IStaticsBasket.BasketStatus.ExitOnly) {
            revert BasketNotExitOnly(basketId, configured.status);
        }
        _enforceConstituent(configured, basketId, asset);
        (LibBasketLiquidity.LiquidityStorage storage ls, LibBasketLiquidity.CanonicalPool storage stored) =
            _configuredPool(basketId, asset);
        if (ls.liquidityUnwound[basketId][asset]) revert BasketLiquidityAlreadyUnwound(basketId, asset);
        ls.liquidityUnwound[basketId][asset] = true;

        address basketToken = configured.token;
        uint256 basketBefore = IERC20(basketToken).balanceOf(address(this));
        uint256 assetBefore = IERC20(asset).balanceOf(address(this));
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(ls.hook);
        hook.decommissionPool(stored.key);
        (uint256 released0, uint256 released1) = hook.releasePermanentLiquidity(stored.key, address(this));
        bool basketIsCurrency0 = Currency.unwrap(stored.key.currency0) == basketToken;
        uint256 basketTokens = basketIsCurrency0 ? released0 : released1;
        uint256 constituent = basketIsCurrency0 ? released1 : released0;
        _enforceReleased(basketToken, basketBefore, basketTokens);
        _enforceReleased(asset, assetBefore, constituent);

        if (constituent != 0) {
            LibCustody.reserve(LibCustody.feeAccount(), asset, constituent);
            LibGlobalRewards.accrueReservedTreasuryFee(asset, constituent);
            emit PermanentLiquidityTreasuryAccrued(basketId, asset, asset, constituent);
        }
        _burnPolBasketTokens(configured, basketId, asset, basketTokens);
        emit BasketLiquidityUnwound(basketId, asset, stored.key.toId(), constituent, basketTokens);
    }

    function liquidityIntegration() external view returns (address poolManager, address hook, bool installed) {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        return (ls.poolManager, ls.hook, ls.integrationInstalled);
    }

    function liquidityManager() external view returns (address manager, bool installed) {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        return (ls.manager, ls.managerInstalled);
    }

    function liquiditySafetyParameters()
        external
        pure
        returns (uint24 lpFee, int24 tickSpacing, uint40 warmup, uint32 referenceWindow, uint16 maxDeviationBps)
    {
        return (CANONICAL_LP_FEE, CANONICAL_TICK_SPACING, POOL_WARMUP, REFERENCE_WINDOW, MAX_DEVIATION_BPS);
    }

    function canonicalPool(uint256 basketId, address asset) external view returns (CanonicalPoolView memory pool) {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        LibBasketLiquidity.CanonicalPool storage stored = ls.canonicalPools[basketId][asset];
        if (stored.status == CanonicalPoolStatus.Unconfigured) revert CanonicalPoolNotConfigured(basketId, asset);
        PoolId poolId = stored.key.toId();
        (, int24 spotTick,,) = IPoolManager(ls.poolManager).getSlot0(poolId);
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(ls.hook);
        IStaticsSwapFeeHook.OracleStateView memory oracle = hook.oracleState(poolId);
        int24 referenceTick;
        bool referenceAvailable;
        if (block.timestamp >= REFERENCE_WINDOW) {
            try hook.consult(poolId, REFERENCE_WINDOW) returns (int24 referenceTick_, int24, uint40) {
                referenceTick = referenceTick_;
                referenceAvailable = true;
            } catch {}
        }
        pool = CanonicalPoolView({
            poolId: poolId,
            basketToken: _basket(basketId).token,
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

    function swapFeeConfiguration() external view returns (SwapFeeConfiguration memory configuration) {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (!ls.integrationInstalled) revert LiquidityIntegrationNotInstalled();
        IStaticsSwapFeeHook.FeeConfiguration memory stored = IStaticsSwapFeeHook(ls.hook).feeConfiguration();
        configuration = SwapFeeConfiguration({
            inputFeeBps: stored.inputFeeBps,
            outputFeeBps: stored.outputFeeBps,
            polShareBps: stored.polShareBps,
            liquidityProviderShareBps: stored.liquidityProviderShareBps,
            basketStakerShareBps: stored.basketStakerShareBps,
            staticsStakerShareBps: stored.staticsStakerShareBps,
            treasuryShareBps: stored.treasuryShareBps
        });
    }

    function canonicalPoolFeeConfiguration(uint256 basketId, address asset)
        external
        view
        returns (PoolFeeConfigurationView memory configuration)
    {
        (LibBasketLiquidity.LiquidityStorage storage ls, LibBasketLiquidity.CanonicalPool storage stored) =
            _configuredPool(basketId, asset);
        IStaticsSwapFeeHook.PoolFeeConfigurationView memory effective =
            IStaticsSwapFeeHook(ls.hook).poolFeeConfiguration(stored.key.toId());
        configuration = PoolFeeConfigurationView({
            inputFeeBps: effective.inputFeeBps,
            outputFeeBps: effective.outputFeeBps,
            polShareBps: effective.polShareBps,
            liquidityProviderShareBps: effective.liquidityProviderShareBps,
            basketStakerShareBps: effective.basketStakerShareBps,
            staticsStakerShareBps: effective.staticsStakerShareBps,
            treasuryShareBps: effective.treasuryShareBps,
            overridden: effective.overridden
        });
    }

    function basketLiquidityUnwound(uint256 basketId, address asset) external view returns (bool unwound) {
        return LibBasketLiquidity.liquidityStorage().liquidityUnwound[basketId][asset];
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

        bytes32 basketAccount = LibCustody.basketAccount(basketId);
        bytes32 feeAccount = LibCustody.feeAccount();
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            address rewardAsset = configured.assets[i];
            uint256 amount = LibBasket.backingReduction(configured.bundleAmounts[i], supply, shares);
            uint256 available = bs.vaultBalances[basketId][rewardAsset];
            if (amount > available) revert InsufficientVaultBalance(rewardAsset, amount, available);
            bs.vaultBalances[basketId][rewardAsset] = available - amount;
            LibCustody.moveReservation(basketAccount, feeAccount, rewardAsset, amount);
            LibGlobalRewards.accrueReservedTreasuryFee(rewardAsset, amount);
            emit PermanentLiquidityTreasuryAccrued(basketId, sourcePoolAsset, rewardAsset, amount);
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

    function _enforceDeviation(int24 referenceTick, int24 spotTick) private pure {
        int256 deviation = int256(spotTick) - int256(referenceTick);
        if (deviation > MAX_POSITIVE_TICK_DEVIATION || deviation < MAX_NEGATIVE_TICK_DEVIATION) {
            revert PriceDeviationTooHigh(referenceTick, spotTick);
        }
    }

    function _enforceReleased(address token, uint256 beforeBalance, uint256 reported) private view {
        uint256 afterBalance = IERC20(token).balanceOf(address(this));
        uint256 observed = afterBalance > beforeBalance ? afterBalance - beforeBalance : 0;
        if (observed != reported) revert ReleasedAmountMismatch(token, reported, observed);
    }

    function _enforceContract(address target) private view {
        if (target.code.length == 0) revert InvalidIntegrationContract(target);
    }

    function _enforceBinding(address target, address expected, address actual) private pure {
        if (expected != actual) revert InvalidIntegrationBinding(target, expected, actual);
    }

    function _enforceLiquidityAvailable() private view {
        if (LibGovernance.governanceStorage().pausedActions & LibGovernance.PAUSE_LIQUIDITY != 0) {
            revert ActionPaused(LibGovernance.PAUSE_LIQUIDITY);
        }
    }
}

interface StaticsSwapFeeHookLike {
    function poolManager() external view returns (IPoolManager);
}

interface IERC721Like {
    function setApprovalForAll(address operator, bool approved) external;
}
