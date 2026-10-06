// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {IStaticsPermissionedSwapFeeHook} from "../interfaces/IStaticsPermissionedSwapFeeHook.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibBasketLaunchMath} from "../libraries/LibBasketLaunchMath.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibProtocolPoolFee} from "../libraries/LibProtocolPoolFee.sol";
import {LibProtocolPol} from "../libraries/LibProtocolPol.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {LibRangeGauge} from "../libraries/LibRangeGauge.sol";
import {LibBasketDeployment} from "../libraries/LibBasketDeployment.sol";
import {LibBasketMarkets} from "../libraries/LibBasketMarkets.sol";
import {LibRestrictedBasket} from "../libraries/LibRestrictedBasket.sol";
import {StaticsBasketHook} from "../liquidity/StaticsBasketHook.sol";

contract BasketLiquidityFacet {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error LiquidityIntegrationAlreadyInstalled();
    error LiquidityIntegrationNotInstalled();
    error LiquidityManagerAlreadyInstalled();
    error PermissionedLiquidityIntegrationAlreadyInstalled();
    error LiquidityManagerNotInstalled();
    error InvalidIntegrationContract(address target);
    error InvalidIntegrationBinding(address target, address expected, address actual);
    error BasketNotFound(uint256 basketId);
    error CanonicalPoolNotConfigured(uint256 basketId, address asset);
    error OnlyDiamondSelf(address caller);
    error InvalidPoolLaunchParameters();
    error InvalidPoolLaunchLpFee(address asset, uint24 lpFee);
    error InvalidPoolLaunchTickSpacing(address asset, int24 tickSpacing);
    error InvalidPoolLaunchPrice(address asset, uint160 sqrtPriceAssetPerBasketX96);
    error InvalidPoolLaunchLiquidity(address asset, uint256 pairedAssetAmount);
    error CanonicalPoolAlreadyAssociated(PoolId poolId, uint256 basketId, address asset);
    error LaunchInputExceedsMaximum(address asset, uint256 required, uint256 maximum);
    error InsufficientLaunchAssetReceived(address asset, uint256 required, uint256 received);
    error LaunchDebitExceedsMaximum(address asset, uint256 actualDebit, uint256 maximum);

    event LiquidityIntegrationInstalled(address indexed poolManager, address indexed hook);
    event LiquidityManagerInstalled(address indexed manager);
    event PermissionedLiquidityIntegrationInstalled(
        address indexed hook, address indexed router, address indexed positionManager, address quoter
    );
    event CanonicalPoolInitialized(
        uint256 indexed basketId,
        address indexed asset,
        PoolId indexed poolId,
        address currency0,
        address currency1,
        uint160 sqrtPriceX96,
        int24 tick
    );

    struct BasketPolPlan {
        IStaticsProtocolPools.ProtocolPolOpenParams[] positions;
        uint256[] basketAmounts;
        uint256[] assetAmounts;
        uint256 basketShares;
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
        emit LiquidityManagerInstalled(manager);
    }

    function installPermissionedPoolIntegration(address hook, address router, address positionManager, address quoter)
        external
    {
        LibDiamond.enforceIsContractOwner();
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (!ls.integrationInstalled) revert LiquidityIntegrationNotInstalled();
        if (ls.permissionedIntegrationInstalled) revert PermissionedLiquidityIntegrationAlreadyInstalled();
        _enforceContract(hook);
        _enforceContract(router);
        _enforceContract(positionManager);
        _enforceContract(quoter);
        _enforceBinding(hook, address(this), IStaticsPermissionedSwapFeeHook(hook).staticsDiamond());
        _enforceBinding(hook, ls.poolManager, address(StaticsSwapFeeHookLike(hook).poolManager()));
        _enforceBinding(router, ls.poolManager, address(StaticsSwapFeeHookLike(router).poolManager()));
        _enforceBinding(router, hook, PermissionedPeripheryLike(router).permissionedHook());
        _enforceBinding(positionManager, ls.poolManager, address(StaticsSwapFeeHookLike(positionManager).poolManager()));
        _enforceBinding(positionManager, hook, PermissionedPeripheryLike(positionManager).permissionedHook());
        _enforceBinding(quoter, ls.poolManager, address(StaticsSwapFeeHookLike(quoter).poolManager()));
        ls.permissionedHook = hook;
        ls.permissionedRouter = router;
        ls.permissionedPositionManager = positionManager;
        ls.permissionedQuoter = quoter;
        ls.permissionedIntegrationInstalled = true;
        emit PermissionedLiquidityIntegrationInstalled(hook, router, positionManager, quoter);
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

        BasketPolPlan memory plan = _prepareBasketPools(ls, configured, basketId, pools, maxAmountsIn);
        basketShares = plan.basketShares;
        IStaticsBasketLaunchModule(address(this))
            .mintBasketLaunch(basketId, payer, basketShares, plan.assetAmounts, maxAmountsIn);
        _fundAndOpenBasketPools(configured, payer, plan);
        _enforcePayerDebits(configured, payer, payerBalancesBefore, maxAmountsIn);
    }

    function _prepareBasketPools(
        LibBasketLiquidity.LiquidityStorage storage ls,
        LibBasket.Basket storage configured,
        uint256 basketId,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn
    ) private returns (BasketPolPlan memory plan) {
        uint256 length = configured.assets.length;
        plan.positions = new IStaticsProtocolPools.ProtocolPolOpenParams[](length);
        plan.basketAmounts = new uint256[](length);
        plan.assetAmounts = new uint256[](length);

        for (uint256 i; i < length; ++i) {
            address asset = configured.assets[i];
            IStaticsBasket.PoolLaunchParams calldata launch = pools[i];
            (plan.positions[i], plan.basketAmounts[i], plan.assetAmounts[i]) =
                _prepareCanonicalPoolSeed(ls, configured.token, basketId, asset, launch);
            if (plan.assetAmounts[i] >= maxAmountsIn[i]) {
                revert LaunchInputExceedsMaximum(asset, plan.assetAmounts[i], maxAmountsIn[i]);
            }
            plan.basketShares += plan.basketAmounts[i];
        }
    }

    function _prepareCanonicalPoolSeed(
        LibBasketLiquidity.LiquidityStorage storage ls,
        address basketToken,
        uint256 basketId,
        address asset,
        IStaticsBasket.PoolLaunchParams calldata launch
    )
        private
        returns (IStaticsProtocolPools.ProtocolPolOpenParams memory position, uint256 basketAmount, uint256 assetAmount)
    {
        (PoolKey memory key,) = _initializeCanonicalPool(ls, basketToken, basketId, asset, launch);
        bool assetIsCurrency0 = Currency.unwrap(key.currency0) == asset;
        uint128 liquidity;
        (, liquidity, basketAmount, assetAmount) = LibBasketLaunchMath.seed(basketToken, asset, launch);
        if (liquidity == 0 || basketAmount == 0 || assetAmount == 0) {
            revert InvalidPoolLaunchLiquidity(asset, launch.pairedAssetAmount);
        }
        position = IStaticsProtocolPools.ProtocolPolOpenParams({
            poolId: key.toId(),
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing),
            liquidity: liquidity,
            amount0Maximum: assetIsCurrency0 ? assetAmount : basketAmount,
            amount1Maximum: assetIsCurrency0 ? basketAmount : assetAmount,
            deadline: block.timestamp
        });
    }

    function _fundAndOpenBasketPools(LibBasket.Basket storage configured, address payer, BasketPolPlan memory plan)
        private
    {
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            address asset = configured.assets[i];
            uint256 required = plan.assetAmounts[i];
            uint256 received = LibCustody.pull(asset, payer, required);
            if (received < required) revert InsufficientLaunchAssetReceived(asset, required, received);
            bytes32 account = LibCustody.protocolPolAccount(PoolId.unwrap(plan.positions[i].poolId));
            LibCustody.reserve(account, asset, received);
            LibCustody.reserve(account, configured.token, plan.basketAmounts[i]);
            LibProtocolPol.open(plan.positions[i]);
        }
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

    function liquidityIntegration() external view returns (address poolManager, address hook, bool installed) {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        return (ls.poolManager, ls.hook, ls.integrationInstalled);
    }

    function liquidityManager() external view returns (address manager, bool installed) {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        return (ls.manager, ls.managerInstalled);
    }

    function permissionedLiquidityIntegration()
        external
        view
        returns (address hook, address router, address positionManager, address quoter, bool installed)
    {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        return (
            ls.permissionedHook,
            ls.permissionedRouter,
            ls.permissionedPositionManager,
            ls.permissionedQuoter,
            ls.permissionedIntegrationInstalled
        );
    }

    function canonicalPool(uint256 basketId, address asset)
        external
        view
        returns (IStaticsBasketLiquidity.CanonicalPoolView memory pool)
    {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        LibBasketLiquidity.CanonicalPool storage stored = ls.canonicalPools[basketId][asset];
        if (address(stored.key.hooks) == address(0)) revert CanonicalPoolNotConfigured(basketId, asset);
        PoolId poolId = stored.key.toId();
        (, int24 spotTick,,) = IPoolManager(ls.poolManager).getSlot0(poolId);
        pool = IStaticsBasketLiquidity.CanonicalPoolView({
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

    function basketLiquidityUnwound(uint256 basketId, address asset) external view returns (bool unwound) {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        LibBasketLiquidity.CanonicalPool storage stored = ls.canonicalPools[basketId][asset];
        if (address(stored.key.hooks) == address(0)) return false;
        return IStaticsSwapFeeHook(address(stored.key.hooks)).poolDecommissioned(stored.key.toId());
    }

    function _initializeCanonicalPool(
        LibBasketLiquidity.LiquidityStorage storage ls,
        address basketToken,
        uint256 basketId,
        address asset,
        IStaticsBasket.PoolLaunchParams calldata launch
    ) private returns (PoolKey memory key, uint160 sqrtPriceX96) {
        if (!LibProtocolPoolFee.isValidStaticLpFee(launch.lpFee)) {
            revert InvalidPoolLaunchLpFee(asset, launch.lpFee);
        }
        if (!LibProtocolPoolFee.isValidTickSpacing(launch.tickSpacing)) {
            revert InvalidPoolLaunchTickSpacing(asset, launch.tickSpacing);
        }
        sqrtPriceX96 =
            LibBasketLaunchMath.sqrtPrice(basketToken, asset, launch.tickSpacing, launch.sqrtPriceAssetPerBasketX96);
        (Currency currency0, Currency currency1) = basketToken < asset
            ? (Currency.wrap(basketToken), Currency.wrap(asset))
            : (Currency.wrap(asset), Currency.wrap(basketToken));
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: launch.lpFee,
            tickSpacing: launch.tickSpacing,
            hooks: IHooks(ls.hook)
        });
        if (LibRestrictedBasket.isRestricted(basketToken)) {
            bytes32 preparation = LibBasketDeployment.deploymentStorage().launching[basketId];
            key.hooks = IHooks(
                LibBasketDeployment.factory()
                    .deployBasketHook(
                        preparation,
                        StaticsBasketHook.Binding(
                            currency0,
                            currency1,
                            launch.lpFee,
                            launch.tickSpacing,
                            LibBasket.basketStorage().baskets[basketId].creator,
                            1
                        )
                    )
            );
        }
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

        if (LibRestrictedBasket.isRestricted(basketToken)) {
            LibBasketMarkets.register(key, LibBasket.basketStorage().baskets[basketId].creator, basketId, asset, 1);
        } else {
            IStaticsSwapFeeHook(ls.hook)
                .registerPool(
                    key,
                    IStaticsSwapFeeHook.PoolKind.BasketCanonical,
                    LibBasket.basketStorage().baskets[basketId].creator
                );
        }
        IPoolManager(ls.poolManager).initialize(key, sqrtPriceX96);
        (, int24 tick,,) = IPoolManager(ls.poolManager).getSlot0(poolId);
        LibRangeGauge.initializePool(poolId, tick);
        emit CanonicalPoolInitialized(
            basketId, asset, poolId, Currency.unwrap(currency0), Currency.unwrap(currency1), sqrtPriceX96, tick
        );
    }

    function _basket(uint256 basketId) private view returns (LibBasket.Basket storage configured) {
        configured = LibBasket.basketStorage().baskets[basketId];
        if (configured.token == address(0)) revert BasketNotFound(basketId);
    }

    function _enforceContract(address target) private view {
        if (target.code.length == 0) revert InvalidIntegrationContract(target);
    }

    function _enforceBinding(address target, address expected, address actual) private pure {
        if (expected != actual) revert InvalidIntegrationBinding(target, expected, actual);
    }
}

interface StaticsSwapFeeHookLike {
    function poolManager() external view returns (IPoolManager);
}

interface PermissionedPeripheryLike {
    function permissionedHook() external view returns (address);
}
