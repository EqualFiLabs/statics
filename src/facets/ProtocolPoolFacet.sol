// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
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
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IStaticsBasketLiquidity} from "../interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IStaticsLiquidityManager} from "../interfaces/IStaticsLiquidityManager.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibBasketLiquidityMath} from "../libraries/LibBasketLiquidityMath.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";

contract ProtocolPoolFacet is IStaticsProtocolPools, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    uint24 private constant PROTOCOL_LP_FEE = 0;
    int24 private constant PROTOCOL_TICK_SPACING = 10;
    uint256 private constant Q96 = 1 << 96;

    error LiquidityIntegrationNotInstalled();
    error InvalidToken(address token);
    error IdenticalTokens(address token);
    error InvalidPayer();
    error DeadlineExpired(uint256 deadline);
    error InvalidPoolPrice(uint160 sqrtPriceBPerAX96);
    error InsufficientSeedLiquidity(uint128 calculated, uint128 minimum);
    error InvalidSeedAmounts(uint256 amountA, uint256 amountB);
    error IncompatibleTokenTransfer(address token, uint256 expected, uint256 observed);
    error PoolAlreadyInitialized(PoolId poolId);
    error PoolAlreadyRegisteredInHook(PoolId poolId);
    error PoolAlreadyDecommissioned(PoolId poolId);
    error ActionPaused(uint256 action);
    error InvalidLiquidityManager(address manager);
    error LiquidityManagerBindingMismatch(address manager, address expected, address actual);
    error LiquidityManagerUnchanged(address manager);
    error LiquidityManagerApprovalMismatch(address manager, bool expected);

    function quoteGovernancePool(CreateGovernancePoolParams calldata params)
        external
        view
        returns (
            PoolKey memory key,
            PoolId poolId,
            uint160 sqrtPriceX96,
            uint128 liquidity,
            uint256 amountA,
            uint256 amountB
        )
    {
        return _quote(params);
    }

    function createGovernancePool(CreateGovernancePoolParams calldata params)
        external
        nonReentrant
        returns (PoolId poolId, uint128 liquidity, uint256 amountA, uint256 amountB)
    {
        LibDiamond.enforceIsContractOwner();
        _enforceLiquidityAvailable();
        if (params.deadline < block.timestamp) revert DeadlineExpired(params.deadline);
        if (params.payer == address(0)) revert InvalidPayer();

        PoolKey memory key;
        uint160 sqrtPriceX96;
        (key, poolId, sqrtPriceX96, liquidity, amountA, amountB) = _quote(params);
        LibProtocolPools.enforceUnregistered(poolId);

        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(ls.hook);
        if (hook.poolRegistration(poolId).registered) revert PoolAlreadyRegisteredInHook(poolId);
        (uint160 initializedPrice,,,) = IPoolManager(ls.poolManager).getSlot0(poolId);
        if (initializedPrice != 0) revert PoolAlreadyInitialized(poolId);

        uint256 payerABefore = IERC20(params.tokenA).balanceOf(params.payer);
        uint256 payerBBefore = IERC20(params.tokenB).balanceOf(params.payer);
        _pullExact(params.tokenA, params.payer, amountA);
        _pullExact(params.tokenB, params.payer, amountB);

        LibProtocolPools.GovernancePool storage stored = LibProtocolPools.protocolPoolStorage().governancePools[poolId];
        stored.key = key;
        stored.registered = true;

        hook.registerPool(key);
        int24 tick = IPoolManager(ls.poolManager).initialize(key, sqrtPriceX96);
        IERC20(Currency.unwrap(key.currency0)).forceApprove(ls.hook, _amount0(params, amountA, amountB));
        IERC20(Currency.unwrap(key.currency1)).forceApprove(ls.hook, _amount1(params, amountA, amountB));
        IStaticsSwapFeeHook.PermanentLiquiditySeed[] memory seeds = new IStaticsSwapFeeHook.PermanentLiquiditySeed[](1);
        seeds[0] = IStaticsSwapFeeHook.PermanentLiquiditySeed({key: key, liquidity: liquidity});
        hook.seedPermanentLiquidity(seeds);
        IERC20(Currency.unwrap(key.currency0)).forceApprove(ls.hook, 0);
        IERC20(Currency.unwrap(key.currency1)).forceApprove(ls.hook, 0);

        _enforcePayerDebit(params.tokenA, params.payer, payerABefore, amountA, params.amountAMax);
        _enforcePayerDebit(params.tokenB, params.payer, payerBBefore, amountB, params.amountBMax);
        emit GovernancePoolCreated(
            poolId,
            params.tokenA,
            params.tokenB,
            params.payer,
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1),
            sqrtPriceX96,
            tick,
            liquidity,
            amountA,
            amountB
        );
    }

    function setProtocolPoolFeeConfiguration(
        PoolId poolId,
        IStaticsBasketLiquidity.SwapFeeConfiguration calldata configuration
    ) external {
        LibDiamond.enforceIsContractOwner();
        LibProtocolPools.enforceRegistered(poolId);
        IStaticsSwapFeeHook(_liquidityStorage().hook).setPoolFeeConfiguration(poolId, _hookConfiguration(configuration));
        emit ProtocolPoolFeeConfigurationSet(poolId);
    }

    function clearProtocolPoolFeeConfiguration(PoolId poolId) external {
        LibDiamond.enforceIsContractOwner();
        LibProtocolPools.enforceRegistered(poolId);
        IStaticsSwapFeeHook(_liquidityStorage().hook).clearPoolFeeConfiguration(poolId);
        emit ProtocolPoolFeeConfigurationCleared(poolId);
    }

    function protocolPoolFeeConfiguration(PoolId poolId)
        external
        view
        returns (IStaticsBasketLiquidity.PoolFeeConfigurationView memory configuration)
    {
        LibProtocolPools.enforceRegistered(poolId);
        IStaticsSwapFeeHook.PoolFeeConfigurationView memory stored =
            IStaticsSwapFeeHook(_liquidityStorage().hook).poolFeeConfiguration(poolId);
        configuration = IStaticsBasketLiquidity.PoolFeeConfigurationView({
            inputFeeBps: stored.inputFeeBps,
            outputFeeBps: stored.outputFeeBps,
            lockedLiquidityShareBps: stored.lockedLiquidityShareBps,
            liquidityProviderShareBps: stored.liquidityProviderShareBps,
            basketStakerShareBps: stored.basketStakerShareBps,
            staticsStakerShareBps: stored.staticsStakerShareBps,
            stonkBrokersShareBps: stored.stonkBrokersShareBps,
            indexCreatorShareBps: stored.indexCreatorShareBps,
            treasuryShareBps: stored.treasuryShareBps,
            overridden: stored.overridden
        });
    }

    function decommissionGovernancePool(PoolId poolId)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        LibDiamond.enforceIsContractOwner();
        LibProtocolPools.GovernancePool storage stored = LibProtocolPools.governancePool(poolId);
        LibBasketLiquidity.LiquidityStorage storage ls = _liquidityStorage();
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(ls.hook);
        if (hook.poolDecommissioned(poolId)) revert PoolAlreadyDecommissioned(poolId);
        address currency0 = Currency.unwrap(stored.key.currency0);
        address currency1 = Currency.unwrap(stored.key.currency1);
        uint256 before0 = IERC20(currency0).balanceOf(address(this));
        uint256 before1 = IERC20(currency1).balanceOf(address(this));
        hook.decommissionPool(stored.key);
        (amount0, amount1) = hook.releasePermanentLiquidity(stored.key, address(this));
        _enforceReceived(currency0, before0, amount0);
        _enforceReceived(currency1, before1, amount1);
        _reserveTreasury(currency0, amount0);
        _reserveTreasury(currency1, amount1);
        emit GovernancePoolDecommissioned(poolId, currency0, currency1, amount0, amount1);
    }

    function replaceLiquidityManager(address newManager) external {
        LibDiamond.enforceIsContractOwner();
        LibBasketLiquidity.LiquidityStorage storage ls = _liquidityStorage();
        address oldManager = ls.manager;
        if (!ls.managerInstalled || oldManager.code.length == 0 || newManager.code.length == 0) {
            revert InvalidLiquidityManager(newManager);
        }
        if (newManager == oldManager) revert LiquidityManagerUnchanged(newManager);
        IStaticsLiquidityManager oldBinding = IStaticsLiquidityManager(oldManager);
        IStaticsLiquidityManager newBinding = IStaticsLiquidityManager(newManager);
        address positionManager = oldBinding.positionManager();
        _enforceManagerBinding(newManager, address(this), newBinding.staticsDiamond());
        _enforceManagerBinding(newManager, ls.poolManager, newBinding.poolManager());
        _enforceManagerBinding(newManager, positionManager, newBinding.positionManager());
        _enforceManagerBinding(newManager, oldBinding.permit2(), newBinding.permit2());

        IERC721 positions = IERC721(positionManager);
        positions.setApprovalForAll(oldManager, false);
        positions.setApprovalForAll(newManager, true);
        ls.manager = newManager;
        if (positions.isApprovedForAll(address(this), oldManager)) {
            revert LiquidityManagerApprovalMismatch(oldManager, false);
        }
        if (!positions.isApprovedForAll(address(this), newManager)) {
            revert LiquidityManagerApprovalMismatch(newManager, true);
        }
        emit LiquidityManagerReplaced(oldManager, newManager);
    }

    function protocolPool(PoolId poolId) external view returns (ProtocolPoolView memory pool) {
        (ProtocolPoolKind kind, PoolKey memory key, uint256 basketId, address basketAsset) =
            LibProtocolPools.resolve(poolId);
        bool registered = kind != ProtocolPoolKind.None;
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(_liquidityStorage().hook);
        pool = ProtocolPoolView({
            poolId: poolId,
            key: key,
            kind: kind,
            decommissioned: registered && hook.poolDecommissioned(poolId),
            basketId: basketId,
            basketAsset: basketAsset,
            permanentLiquidity: registered ? hook.lockedLiquidity(poolId) : 0
        });
    }

    function isProtocolPool(PoolId poolId) external view returns (bool registered) {
        (ProtocolPoolKind kind,,,) = LibProtocolPools.resolve(poolId);
        return kind != ProtocolPoolKind.None;
    }

    function _quote(CreateGovernancePoolParams calldata params)
        private
        view
        returns (
            PoolKey memory key,
            PoolId poolId,
            uint160 sqrtPriceX96,
            uint128 liquidity,
            uint256 amountA,
            uint256 amountB
        )
    {
        LibBasketLiquidity.LiquidityStorage storage ls = _liquidityStorage();
        _validateToken(params.tokenA);
        _validateToken(params.tokenB);
        if (params.tokenA == params.tokenB) revert IdenticalTokens(params.tokenA);
        sqrtPriceX96 = _sortedSqrtPrice(params.tokenA, params.tokenB, params.sqrtPriceBPerAX96);
        (Currency currency0, Currency currency1) = params.tokenA < params.tokenB
            ? (Currency.wrap(params.tokenA), Currency.wrap(params.tokenB))
            : (Currency.wrap(params.tokenB), Currency.wrap(params.tokenA));
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: PROTOCOL_LP_FEE,
            tickSpacing: PROTOCOL_TICK_SPACING,
            hooks: IHooks(ls.hook)
        });
        poolId = key.toId();

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(PROTOCOL_TICK_SPACING));
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(PROTOCOL_TICK_SPACING));
        uint256 max0 = params.tokenA < params.tokenB ? params.amountAMax : params.amountBMax;
        uint256 max1 = params.tokenA < params.tokenB ? params.amountBMax : params.amountAMax;
        liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtLower, sqrtUpper, max0, max1);
        if (liquidity == 0 || liquidity < params.minLiquidity) {
            revert InsufficientSeedLiquidity(liquidity, params.minLiquidity);
        }
        (uint256 amount0, uint256 amount1) = LibBasketLiquidityMath.rangeAmounts(
            sqrtPriceX96,
            TickMath.minUsableTick(PROTOCOL_TICK_SPACING),
            TickMath.maxUsableTick(PROTOCOL_TICK_SPACING),
            liquidity
        );
        (amountA, amountB) = params.tokenA < params.tokenB ? (amount0, amount1) : (amount1, amount0);
        if (amountA == 0 || amountB == 0 || amountA > params.amountAMax || amountB > params.amountBMax) {
            revert InvalidSeedAmounts(amountA, amountB);
        }
    }

    function _sortedSqrtPrice(address tokenA, address tokenB, uint160 sqrtPriceBPerAX96)
        private
        pure
        returns (uint160 sqrtPriceX96)
    {
        if (sqrtPriceBPerAX96 == 0) revert InvalidPoolPrice(sqrtPriceBPerAX96);
        uint256 sorted =
            tokenA < tokenB ? uint256(sqrtPriceBPerAX96) : Math.mulDiv(Q96, Q96, uint256(sqrtPriceBPerAX96));
        if (sorted > type(uint160).max) revert InvalidPoolPrice(sqrtPriceBPerAX96);
        sqrtPriceX96 = uint160(sorted);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(PROTOCOL_TICK_SPACING));
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(PROTOCOL_TICK_SPACING));
        if (sqrtPriceX96 <= sqrtLower || sqrtPriceX96 >= sqrtUpper) revert InvalidPoolPrice(sqrtPriceBPerAX96);
    }

    function _pullExact(address token, address payer, uint256 amount) private {
        uint256 received = LibCustody.pull(token, payer, amount);
        if (received != amount) revert IncompatibleTokenTransfer(token, amount, received);
    }

    function _enforcePayerDebit(address token, address payer, uint256 beforeBalance, uint256 amount, uint256 maximum)
        private
        view
    {
        uint256 afterBalance = IERC20(token).balanceOf(payer);
        uint256 debit = beforeBalance > afterBalance ? beforeBalance - afterBalance : 0;
        if (debit != amount || debit > maximum) revert IncompatibleTokenTransfer(token, amount, debit);
    }

    function _enforceReceived(address token, uint256 beforeBalance, uint256 reported) private view {
        uint256 afterBalance = IERC20(token).balanceOf(address(this));
        uint256 observed = afterBalance > beforeBalance ? afterBalance - beforeBalance : 0;
        if (observed != reported) revert IncompatibleTokenTransfer(token, reported, observed);
    }

    function _reserveTreasury(address token, uint256 amount) private {
        if (amount == 0) return;
        LibCustody.reserve(LibCustody.feeAccount(), token, amount);
        LibGlobalRewards.accrueReservedTreasuryFee(token, amount);
    }

    function _amount0(CreateGovernancePoolParams calldata params, uint256 amountA, uint256 amountB)
        private
        pure
        returns (uint256)
    {
        return params.tokenA < params.tokenB ? amountA : amountB;
    }

    function _amount1(CreateGovernancePoolParams calldata params, uint256 amountA, uint256 amountB)
        private
        pure
        returns (uint256)
    {
        return params.tokenA < params.tokenB ? amountB : amountA;
    }

    function _hookConfiguration(IStaticsBasketLiquidity.SwapFeeConfiguration calldata configuration)
        private
        pure
        returns (IStaticsSwapFeeHook.FeeConfiguration memory)
    {
        return IStaticsSwapFeeHook.FeeConfiguration({
            inputFeeBps: configuration.inputFeeBps,
            outputFeeBps: configuration.outputFeeBps,
            lockedLiquidityShareBps: configuration.lockedLiquidityShareBps,
            liquidityProviderShareBps: configuration.liquidityProviderShareBps,
            basketStakerShareBps: configuration.basketStakerShareBps,
            staticsStakerShareBps: configuration.staticsStakerShareBps,
            stonkBrokersShareBps: configuration.stonkBrokersShareBps,
            indexCreatorShareBps: configuration.indexCreatorShareBps,
            treasuryShareBps: configuration.treasuryShareBps
        });
    }

    function _liquidityStorage() private view returns (LibBasketLiquidity.LiquidityStorage storage ls) {
        ls = LibBasketLiquidity.liquidityStorage();
        if (!ls.integrationInstalled) revert LiquidityIntegrationNotInstalled();
    }

    function _validateToken(address token) private view {
        if (token == address(0) || token.code.length == 0) revert InvalidToken(token);
    }

    function _enforceManagerBinding(address manager, address expected, address actual) private pure {
        if (expected != actual) revert LiquidityManagerBindingMismatch(manager, expected, actual);
    }

    function _enforceLiquidityAvailable() private view {
        if (LibGovernance.governanceStorage().pausedActions & LibGovernance.PAUSE_LIQUIDITY != 0) {
            revert ActionPaused(LibGovernance.PAUSE_LIQUIDITY);
        }
    }
}
