// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {IStaticsBasketLaunchModule} from "../interfaces/IStaticsBasketLaunchModule.sol";
import {IStaticsBasketLiquidity} from "../interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsLiquidityManager} from "../interfaces/IStaticsLiquidityManager.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibBasketLiquidityMath} from "../libraries/LibBasketLiquidityMath.sol";
import {LibBasketMint} from "../libraries/LibBasketMint.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {StaticsBasketToken} from "../tokens/StaticsBasketToken.sol";

contract BasketLiquidityFacet is IStaticsBasketLiquidity, IStaticsBasketLaunchModule, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    uint24 private constant CANONICAL_LP_FEE = 0;
    int24 private constant CANONICAL_TICK_SPACING = 10;

    error LiquidityIntegrationAlreadyInstalled();
    error LiquidityIntegrationNotInstalled();
    error LiquidityManagerAlreadyInstalled();
    error LiquidityManagerNotInstalled();
    error InvalidIntegrationContract(address target);
    error InvalidIntegrationBinding(address target, address expected, address actual);
    error BasketNotFound(uint256 basketId);
    error AssetNotInBasket(uint256 basketId, address asset);
    error CanonicalPoolNotConfigured(uint256 basketId, address asset);
    error BasketNotExitOnly(uint256 basketId, IStaticsBasket.BasketStatus status);
    error BasketLiquidityAlreadyUnwound(uint256 basketId, address asset);
    error ReleasedAmountMismatch(address token, uint256 reported, uint256 observed);
    error InsufficientVaultBalance(address asset, uint256 required, uint256 available);
    error ActionPaused(uint256 action);
    error OnlyDiamondSelf(address caller);
    error InvalidPoolLaunchParameters();
    error InvalidPoolLaunchPrice(address asset, uint160 sqrtPriceAssetPerBasketX96);
    error InvalidPoolLaunchLiquidity(address asset, uint256 pairedAssetAmount);
    error CanonicalPoolAlreadyAssociated(PoolId poolId, uint256 basketId, address asset);
    error LaunchInputExceedsMaximum(address asset, uint256 required, uint256 maximum);
    error InsufficientLaunchAssetReceived(address asset, uint256 required, uint256 received);
    error LaunchDebitExceedsMaximum(address asset, uint256 actualDebit, uint256 maximum);

    struct TreasuryAccrual {
        uint256 basketId;
        address sourcePoolAsset;
        uint256 shares;
        uint256 supply;
        bytes32 basketAccount;
        bytes32 feeAccount;
    }

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

    function launchBasketPools(
        uint256 basketId,
        address payer,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn
    ) external returns (uint256 basketShares) {
        if (msg.sender != address(this)) revert OnlyDiamondSelf(msg.sender);
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (!ls.integrationInstalled) revert LiquidityIntegrationNotInstalled();
        if (!ls.managerInstalled) revert LiquidityManagerNotInstalled();
        LibBasket.Basket storage configured = _basket(basketId);
        uint256 length = configured.assets.length;
        if (pools.length != length || maxAmountsIn.length != length) revert InvalidPoolLaunchParameters();
        uint256[] memory payerBalancesBefore = _payerBalances(configured, payer);

        IStaticsSwapFeeHook.PermanentLiquiditySeed[] memory seeds;
        uint256[] memory assetAmounts;
        (seeds, assetAmounts, basketShares) = _prepareBasketPools(ls, configured, basketId, pools, maxAmountsIn);
        IStaticsBasketLaunchModule(address(this))
            .mintBasketLaunch(basketId, payer, basketShares, assetAmounts, maxAmountsIn);
        _fundAndSeedBasketPools(ls, configured, payer, seeds, assetAmounts, basketShares);
        _enforcePayerDebits(configured, payer, payerBalancesBefore, maxAmountsIn);
    }

    function mintBasketLaunch(
        uint256 basketId,
        address payer,
        uint256 basketShares,
        uint256[] calldata assetAmounts,
        uint256[] calldata maxAmountsIn
    ) external {
        if (msg.sender != address(this)) revert OnlyDiamondSelf(msg.sender);
        uint256 length = assetAmounts.length;
        if (maxAmountsIn.length != length) revert InvalidPoolLaunchParameters();
        uint256[] memory mintMaximums = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            mintMaximums[i] = maxAmountsIn[i] - assetAmounts[i];
        }
        LibBasketMint.mintFromPayer(basketId, basketShares, payer, address(this), mintMaximums);
    }

    function _prepareBasketPools(
        LibBasketLiquidity.LiquidityStorage storage ls,
        LibBasket.Basket storage configured,
        uint256 basketId,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn
    )
        private
        returns (
            IStaticsSwapFeeHook.PermanentLiquiditySeed[] memory seeds,
            uint256[] memory assetAmounts,
            uint256 basketShares
        )
    {
        uint256 length = configured.assets.length;
        seeds = new IStaticsSwapFeeHook.PermanentLiquiditySeed[](length);
        assetAmounts = new uint256[](length);

        for (uint256 i; i < length; ++i) {
            address asset = configured.assets[i];
            IStaticsBasket.PoolLaunchParams calldata launch = pools[i];
            uint256 basketAmount;
            (seeds[i], basketAmount, assetAmounts[i]) = _prepareCanonicalPoolSeed(
                ls, configured.token, basketId, asset, launch.sqrtPriceAssetPerBasketX96, launch.pairedAssetAmount
            );
            if (assetAmounts[i] >= maxAmountsIn[i]) {
                revert LaunchInputExceedsMaximum(asset, assetAmounts[i], maxAmountsIn[i]);
            }
            basketShares += basketAmount;
        }
    }

    function _prepareCanonicalPoolSeed(
        LibBasketLiquidity.LiquidityStorage storage ls,
        address basketToken,
        uint256 basketId,
        address asset,
        uint160 sqrtPriceAssetPerBasketX96,
        uint256 pairedAssetAmount
    )
        private
        returns (IStaticsSwapFeeHook.PermanentLiquiditySeed memory seed, uint256 basketAmount, uint256 assetAmount)
    {
        (PoolKey memory key, uint160 sqrtPriceX96) =
            _initializeCanonicalPool(ls, basketToken, basketId, asset, sqrtPriceAssetPerBasketX96);
        bool assetIsCurrency0 = Currency.unwrap(key.currency0) == asset;
        uint128 liquidity;
        (liquidity, basketAmount, assetAmount) =
            LibBasketLiquidityMath.fullRangeAmounts(sqrtPriceX96, assetIsCurrency0, pairedAssetAmount);
        if (liquidity == 0 || basketAmount == 0 || assetAmount == 0) {
            revert InvalidPoolLaunchLiquidity(asset, pairedAssetAmount);
        }
        seed = IStaticsSwapFeeHook.PermanentLiquiditySeed({key: key, liquidity: liquidity});
    }

    function _fundAndSeedBasketPools(
        LibBasketLiquidity.LiquidityStorage storage ls,
        LibBasket.Basket storage configured,
        address payer,
        IStaticsSwapFeeHook.PermanentLiquiditySeed[] memory seeds,
        uint256[] memory assetAmounts,
        uint256 basketShares
    ) private {
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            address asset = configured.assets[i];
            uint256 required = assetAmounts[i];
            uint256 received = LibCustody.pull(asset, payer, required);
            if (received < required) revert InsufficientLaunchAssetReceived(asset, required, received);
            IERC20(asset).forceApprove(ls.hook, required);
        }
        IERC20(configured.token).forceApprove(ls.hook, basketShares);
        IStaticsSwapFeeHook(ls.hook).seedPermanentLiquidity(seeds);
    }

    function _payerBalances(LibBasket.Basket storage configured, address payer)
        private
        view
        returns (uint256[] memory balances)
    {
        uint256 length = configured.assets.length;
        balances = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            balances[i] = IERC20(configured.assets[i]).balanceOf(payer);
        }
    }

    function _enforcePayerDebits(
        LibBasket.Basket storage configured,
        address payer,
        uint256[] memory balancesBefore,
        uint256[] calldata maximums
    ) private view {
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            address asset = configured.assets[i];
            uint256 balanceAfter = IERC20(asset).balanceOf(payer);
            uint256 actualDebit = balancesBefore[i] > balanceAfter ? balancesBefore[i] - balanceAfter : 0;
            if (actualDebit > maximums[i]) {
                revert LaunchDebitExceedsMaximum(asset, actualDebit, maximums[i]);
            }
        }
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
        address basketToken = configured.token;
        uint256 basketBefore = IERC20(basketToken).balanceOf(address(this));
        uint256 assetBefore = IERC20(asset).balanceOf(address(this));
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(ls.hook);
        if (hook.poolDecommissioned(stored.key.toId())) revert BasketLiquidityAlreadyUnwound(basketId, asset);
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

    function canonicalPool(uint256 basketId, address asset) external view returns (CanonicalPoolView memory pool) {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        LibBasketLiquidity.CanonicalPool storage stored = ls.canonicalPools[basketId][asset];
        if (address(stored.key.hooks) == address(0)) revert CanonicalPoolNotConfigured(basketId, asset);
        PoolId poolId = stored.key.toId();
        (, int24 spotTick,,) = IPoolManager(ls.poolManager).getSlot0(poolId);
        pool = CanonicalPoolView({
            poolId: poolId,
            basketToken: _basket(basketId).token,
            asset: asset,
            currency0: Currency.unwrap(stored.key.currency0),
            currency1: Currency.unwrap(stored.key.currency1),
            hook: address(stored.key.hooks),
            lpFee: stored.key.fee,
            tickSpacing: stored.key.tickSpacing,
            spotTick: spotTick
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
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        LibBasketLiquidity.CanonicalPool storage stored = ls.canonicalPools[basketId][asset];
        if (address(stored.key.hooks) == address(0)) return false;
        return IStaticsSwapFeeHook(ls.hook).poolDecommissioned(stored.key.toId());
    }

    function _initializeCanonicalPool(
        LibBasketLiquidity.LiquidityStorage storage ls,
        address basketToken,
        uint256 basketId,
        address asset,
        uint160 sqrtPriceAssetPerBasketX96
    ) private returns (PoolKey memory key, uint160 sqrtPriceX96) {
        sqrtPriceX96 = _canonicalSqrtPrice(basketToken, asset, sqrtPriceAssetPerBasketX96);
        (Currency currency0, Currency currency1) = basketToken < asset
            ? (Currency.wrap(basketToken), Currency.wrap(asset))
            : (Currency.wrap(asset), Currency.wrap(basketToken));
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: CANONICAL_LP_FEE,
            tickSpacing: CANONICAL_TICK_SPACING,
            hooks: IHooks(ls.hook)
        });
        PoolId poolId = key.toId();
        LibProtocolPools.enforceUnregistered(poolId);
        LibBasketLiquidity.PoolAssociation storage association = ls.poolAssociations[poolId];
        if (association.associated) {
            revert CanonicalPoolAlreadyAssociated(poolId, association.basketId, association.asset);
        }

        LibBasketLiquidity.CanonicalPool storage stored = ls.canonicalPools[basketId][asset];
        stored.key = key;
        association.basketId = basketId;
        association.asset = asset;
        association.associated = true;

        IStaticsSwapFeeHook(ls.hook).registerPool(key);
        int24 tick = IPoolManager(ls.poolManager).initialize(key, sqrtPriceX96);
        emit CanonicalPoolInitialized(
            basketId, asset, poolId, Currency.unwrap(currency0), Currency.unwrap(currency1), sqrtPriceX96, tick
        );
    }

    function _canonicalSqrtPrice(address basketToken, address asset, uint160 sqrtPriceAssetPerBasketX96)
        private
        pure
        returns (uint160 sqrtPriceX96)
    {
        if (
            sqrtPriceAssetPerBasketX96 < TickMath.MIN_SQRT_PRICE
                || sqrtPriceAssetPerBasketX96 >= TickMath.MAX_SQRT_PRICE
        ) {
            revert InvalidPoolLaunchPrice(asset, sqrtPriceAssetPerBasketX96);
        }
        if (basketToken < asset) {
            sqrtPriceX96 = sqrtPriceAssetPerBasketX96;
        } else {
            uint256 inverse = Math.mulDiv(1 << 96, 1 << 96, sqrtPriceAssetPerBasketX96);
            if (inverse < TickMath.MIN_SQRT_PRICE || inverse >= TickMath.MAX_SQRT_PRICE) {
                revert InvalidPoolLaunchPrice(asset, sqrtPriceAssetPerBasketX96);
            }
            sqrtPriceX96 = uint160(inverse);
        }
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(CANONICAL_TICK_SPACING));
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(CANONICAL_TICK_SPACING));
        if (sqrtPriceX96 <= sqrtLower || sqrtPriceX96 >= sqrtUpper) {
            revert InvalidPoolLaunchPrice(asset, sqrtPriceAssetPerBasketX96);
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
