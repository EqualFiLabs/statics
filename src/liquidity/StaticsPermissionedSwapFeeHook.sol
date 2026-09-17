// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IMsgSender} from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsGovernance} from "../interfaces/IStaticsGovernance.sol";
import {IStaticsPermissionedSwapFeeHook} from "../interfaces/IStaticsPermissionedSwapFeeHook.sol";
import {IStaticsProtocolRevenue} from "../interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsRewardPolicy} from "../interfaces/IStaticsRewardPolicy.sol";
import {IVenueController} from "../interfaces/IVenueController.sol";
import {LibPermissionedFeeMath} from "../libraries/LibPermissionedFeeMath.sol";
import {LibProtocolPoolFee} from "../libraries/LibProtocolPoolFee.sol";

/// @notice Exact-input permissioned venue hook with PoolId-local output fees and reward-only normalization.
/// @dev Creator and treasury revenue always remain in the original output currency. Only staker-designated
/// revenue may be exchanged through the same pool, and that internal exchange pays the pool's native LP fee.
contract StaticsPermissionedSwapFeeHook is BaseHook, IStaticsPermissionedSwapFeeHook {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    uint256 private constant SWAP_ALLOWED = 1 << 0;
    uint256 private constant LIQUIDITY_ALLOWED = 1 << 1;
    uint256 private constant PAUSE_LIQUIDITY = 1 << 5;

    struct SwapFeeContext {
        PoolId poolId;
        Currency outputCurrency;
        Currency pairedCurrency;
        uint256 grossOutput;
        uint256 fee;
        uint256 normalizedInput;
        uint256 normalizedOutput;
        LibPermissionedFeeMath.Distribution distribution;
    }

    address public immutable staticsDiamond;

    mapping(PoolId poolId => PoolRegistration registration) private registrations;
    mapping(PoolId poolId => PoolEconomics economics) private economicsByPool;
    mapping(address periphery => bool trusted) private trustedPeripheries;
    mapping(PoolId poolId => bool active) private normalizing;

    error OnlyStaticsDiamond(address caller);
    error PoolAlreadyRegistered(PoolId poolId);
    error PoolNotRegistered(PoolId poolId);
    error PoolIsDecommissioned(PoolId poolId);
    error InvalidController(address controller);
    error InvalidCreator(address creator);
    error InvalidEconomics();
    error InvalidNativeLpFee(uint24 fee);
    error NativeCurrencyUnsupported();
    error UntrustedPeriphery(address periphery);
    error InvalidEndUser(address account);
    error VenuePoolHalted(PoolId poolId);
    error VenueAssetHalted(address asset);
    error PermissionDenied(PoolId poolId, address account, uint256 requiredPermission);
    error ExactOutputNotAllowed();
    error CanonicalPoolDonationForbidden();
    error IncompatiblePoolCurrency(Currency currency, uint256 expected, uint256 observed);
    error UnexpectedSettlement(Currency currency, uint256 expected, uint256 observed);
    error UnexpectedInternalSwapInput(uint256 expected, uint256 observed);
    error UnexpectedTokenAllowance(Currency currency, uint256 allowance);

    constructor(IPoolManager manager, address diamond) BaseHook(manager) {
        if (diamond == address(0) || diamond.code.length == 0) revert InvalidCreator(diamond);
        staticsDiamond = diamond;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.afterInitialize = true;
        permissions.beforeAddLiquidity = true;
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        permissions.afterSwapReturnDelta = true;
        permissions.beforeDonate = true;
    }

    function registerPool(PoolKey calldata key, address controller, address creator, PoolEconomics calldata economics)
        external
        returns (PoolId poolId)
    {
        _enforceDiamond();
        if (key.currency0.isAddressZero() || key.currency1.isAddressZero()) revert NativeCurrencyUnsupported();
        if (address(key.hooks) != address(this)) revert PoolNotRegistered(key.toId());
        if (!LibProtocolPoolFee.isValidStaticLpFee(key.fee)) revert InvalidNativeLpFee(key.fee);
        if (controller.code.length == 0) revert InvalidController(controller);
        if (creator == address(0)) revert InvalidCreator(creator);
        _validateEconomics(economics);
        poolId = key.toId();
        if (registrations[poolId].registered) revert PoolAlreadyRegistered(poolId);
        registrations[poolId] = PoolRegistration({
            currency0: key.currency0,
            currency1: key.currency1,
            controller: controller,
            creator: creator,
            registered: true,
            decommissioned: false
        });
        economicsByPool[poolId] = economics;
        emit PermissionedPoolRegistered(poolId, key.currency0, key.currency1, controller, creator, economics);
    }

    function setPoolEconomics(PoolId poolId, PoolEconomics calldata economics) external {
        _enforceDiamond();
        _enforceRegistered(poolId);
        _validateEconomics(economics);
        PoolEconomics memory previous = economicsByPool[poolId];
        economicsByPool[poolId] = economics;
        emit PermissionedPoolEconomicsSet(poolId, previous, economics);
    }

    function decommissionPool(PoolKey calldata key) external {
        _enforceDiamond();
        PoolId poolId = key.toId();
        PoolRegistration storage registration = _enforceRegistered(poolId);
        if (registration.decommissioned) revert PoolIsDecommissioned(poolId);
        registration.decommissioned = true;
        emit PermissionedPoolDecommissioned(poolId);
    }

    function setTrustedPeriphery(address periphery, bool trusted) external {
        _enforceDiamond();
        if (periphery == address(0) || (trusted && periphery.code.length == 0)) revert UntrustedPeriphery(periphery);
        trustedPeripheries[periphery] = trusted;
        emit TrustedPermissionedPeripherySet(periphery, trusted);
    }

    function poolRegistration(PoolId poolId) external view returns (PoolRegistration memory registration) {
        return registrations[poolId];
    }

    function poolEconomics(PoolId poolId) external view returns (PoolEconomics memory economics) {
        _enforceRegistered(poolId);
        return economicsByPool[poolId];
    }

    function trustedPeriphery(address periphery) external view returns (bool trusted) {
        return trustedPeripheries[periphery];
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal view override returns (bytes4) {
        _enforceRegistered(key.toId());
        return IHooks.afterInitialize.selector;
    }

    function _beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        PoolRegistration storage registration = _enforceActive(poolId);
        if (IStaticsGovernance(staticsDiamond).isPaused(PAUSE_LIQUIDITY)) revert VenuePoolHalted(poolId);
        address account = _resolveAccount(sender);
        _enforceVenueAccess(key, poolId, registration, account, LIQUIDITY_ALLOWED);
        return IHooks.beforeAddLiquidity.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (params.amountSpecified >= 0) revert ExactOutputNotAllowed();
        PoolId poolId = key.toId();
        if (normalizing[poolId] && sender == address(this)) {
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }
        PoolRegistration storage registration = _enforceActive(poolId);
        if (IStaticsGovernance(staticsDiamond).protocolPoolSwapsBlocked(poolId)) revert VenuePoolHalted(poolId);
        address account = _resolveAccount(sender);
        _enforceVenueAccess(key, poolId, registration, account, SWAP_ALLOWED);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128 feeDelta)
    {
        if (normalizing[key.toId()]) return (IHooks.afterSwap.selector, 0);
        return (IHooks.afterSwap.selector, _chargeAndRoute(key, params, delta));
    }

    function _chargeAndRoute(PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        private
        returns (int128 feeDelta)
    {
        SwapFeeContext memory context;
        context.poolId = key.toId();
        PoolEconomics memory economics = economicsByPool[context.poolId];
        context.outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;
        context.pairedCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        int128 signedOutput = params.zeroForOne ? delta.amount1() : delta.amount0();
        if (signedOutput <= 0) revert ExactOutputNotAllowed();
        context.grossOutput = uint256(uint128(signedOutput));
        context.fee = Math.mulDiv(context.grossOutput, economics.venueFeeBps, BPS);
        if (context.fee == 0) return 0;

        bool outputRestricted =
            _isRewardRestricted(context.poolId, context.outputCurrency, economics.additionalRewardRestrictedMask);
        bool pairedRestricted =
            _isRewardRestricted(context.poolId, context.pairedCurrency, economics.additionalRewardRestrictedMask);
        _takeExact(context.outputCurrency, address(this), context.fee);

        if (outputRestricted && pairedRestricted) {
            context.distribution = LibPermissionedFeeMath.bothRestricted(context.fee);
        } else {
            context.distribution = LibPermissionedFeeMath.split(context.fee, economics.allocation);
        }
        if (outputRestricted && !pairedRestricted) {
            (context.distribution, context.normalizedInput) =
                LibPermissionedFeeMath.removeStakerRewards(context.distribution);
            if (context.normalizedInput != 0) {
                context.normalizedOutput =
                    _normalize(key, context.outputCurrency, context.pairedCurrency, context.normalizedInput);
            }
        }

        _route(context.poolId, context.outputCurrency, context.distribution);
        if (context.normalizedOutput != 0) {
            LibPermissionedFeeMath.Distribution memory normalized;
            uint256 combinedShare = uint256(economics.allocation.staticsStakerShareBps)
                + uint256(economics.allocation.basketStakerShareBps);
            normalized.staticsStaker =
                Math.mulDiv(context.normalizedOutput, economics.allocation.staticsStakerShareBps, combinedShare);
            normalized.basketStaker = context.normalizedOutput - normalized.staticsStaker;
            _route(context.poolId, context.pairedCurrency, normalized);
            emit PermissionedRewardsNormalized(
                context.poolId,
                context.outputCurrency,
                context.pairedCurrency,
                context.normalizedInput,
                context.normalizedOutput
            );
        }

        emit PermissionedVenueFeeCharged(
            context.poolId,
            context.outputCurrency,
            context.grossOutput,
            context.fee,
            context.distribution.creator,
            context.distribution.treasury,
            context.distribution.staticsStaker,
            context.distribution.basketStaker
        );
        return context.fee.toInt128();
    }

    function _beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert CanonicalPoolDonationForbidden();
    }

    function _normalize(PoolKey calldata key, Currency input, Currency output, uint256 amountIn)
        private
        returns (uint256 amountOut)
    {
        PoolId poolId = key.toId();
        normalizing[poolId] = true;
        bool zeroForOne = input == key.currency0;
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        normalizing[poolId] = false;
        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0) revert UnexpectedInternalSwapInput(amountIn, 0);
        uint256 settledInput = uint256(-int256(inputDelta));
        if (settledInput != amountIn) revert UnexpectedInternalSwapInput(amountIn, settledInput);
        _settleExact(input, amountIn);
        amountOut = uint256(uint128(outputDelta));
        _takeExact(output, address(this), amountOut);
    }

    function _route(PoolId poolId, Currency currency, LibPermissionedFeeMath.Distribution memory distribution) private {
        uint256 total =
            distribution.basketStaker + distribution.staticsStaker + distribution.creator + distribution.treasury;
        if (total == 0) return;
        IERC20 token = IERC20(Currency.unwrap(currency));
        uint256 beforeBalance = token.balanceOf(address(this));
        token.forceApprove(staticsDiamond, total);
        IStaticsProtocolRevenue(staticsDiamond)
            .routeProtocolSwapFees(
                poolId,
                Currency.unwrap(currency),
                IStaticsProtocolRevenue.ProtocolFeeDistribution({
                    basketStaker: distribution.basketStaker,
                    staticsStaker: distribution.staticsStaker,
                    creator: distribution.creator,
                    treasury: distribution.treasury
                })
            );
        uint256 afterBalance = token.balanceOf(address(this));
        uint256 spent = beforeBalance >= afterBalance ? beforeBalance - afterBalance : 0;
        if (spent != total) revert IncompatiblePoolCurrency(currency, total, spent);
        uint256 remainingAllowance = token.allowance(address(this), staticsDiamond);
        if (remainingAllowance != 0) revert UnexpectedTokenAllowance(currency, remainingAllowance);
    }

    function _takeExact(Currency currency, address receiver, uint256 amount) private {
        uint256 managerBefore = IERC20(Currency.unwrap(currency)).balanceOf(address(poolManager));
        uint256 receiverBefore = IERC20(Currency.unwrap(currency)).balanceOf(receiver);
        poolManager.take(currency, receiver, amount);
        uint256 managerAfter = IERC20(Currency.unwrap(currency)).balanceOf(address(poolManager));
        uint256 receiverAfter = IERC20(Currency.unwrap(currency)).balanceOf(receiver);
        uint256 debit = managerBefore >= managerAfter ? managerBefore - managerAfter : 0;
        uint256 received = receiverAfter >= receiverBefore ? receiverAfter - receiverBefore : 0;
        if (debit != amount || received != amount) revert IncompatiblePoolCurrency(currency, amount, received);
    }

    function _settleExact(Currency currency, uint256 amount) private {
        IERC20 token = IERC20(Currency.unwrap(currency));
        uint256 senderBefore = token.balanceOf(address(this));
        uint256 managerBefore = token.balanceOf(address(poolManager));
        poolManager.sync(currency);
        token.safeTransfer(address(poolManager), amount);
        uint256 settled = poolManager.settle();
        if (settled != amount) revert UnexpectedSettlement(currency, amount, settled);
        uint256 senderAfter = token.balanceOf(address(this));
        uint256 managerAfter = token.balanceOf(address(poolManager));
        uint256 spent = senderBefore >= senderAfter ? senderBefore - senderAfter : 0;
        uint256 received = managerAfter >= managerBefore ? managerAfter - managerBefore : 0;
        if (spent != amount || received != amount) revert IncompatiblePoolCurrency(currency, amount, received);
    }

    function _isRewardRestricted(PoolId poolId, Currency currency, uint8 additionalMask) private view returns (bool) {
        PoolRegistration storage registration = registrations[poolId];
        uint8 bit = currency == registration.currency0 ? 1 : 2;
        return
            additionalMask & bit != 0
                || IStaticsRewardPolicy(staticsDiamond).rewardRestricted(Currency.unwrap(currency));
    }

    function _resolveAccount(address sender) private view returns (address account) {
        if (!trustedPeripheries[sender]) revert UntrustedPeriphery(sender);
        account = IMsgSender(sender).msgSender();
        if (account == address(0) || account == sender) revert InvalidEndUser(account);
    }

    function _enforceVenueAccess(
        PoolKey calldata key,
        PoolId poolId,
        PoolRegistration storage registration,
        address account,
        uint256 requiredPermission
    ) private view {
        IVenueController controller = IVenueController(registration.controller);
        if (controller.poolStatus(poolId) != IVenueController.TradingStatus.Active) revert VenuePoolHalted(poolId);
        address asset0 = Currency.unwrap(key.currency0);
        address asset1 = Currency.unwrap(key.currency1);
        if (controller.assetStatus(asset0) != IVenueController.TradingStatus.Active) revert VenueAssetHalted(asset0);
        if (controller.assetStatus(asset1) != IVenueController.TradingStatus.Active) revert VenueAssetHalted(asset1);
        if (controller.permissions(poolId, account) & requiredPermission == 0) {
            revert PermissionDenied(poolId, account, requiredPermission);
        }
    }

    function _enforceActive(PoolId poolId) private view returns (PoolRegistration storage registration) {
        registration = _enforceRegistered(poolId);
        if (registration.decommissioned) revert PoolIsDecommissioned(poolId);
    }

    function _enforceRegistered(PoolId poolId) private view returns (PoolRegistration storage registration) {
        registration = registrations[poolId];
        if (!registration.registered) revert PoolNotRegistered(poolId);
    }

    function _validateEconomics(PoolEconomics calldata economics) private pure {
        FeeAllocation calldata allocation = economics.allocation;
        uint256 total = uint256(allocation.creatorShareBps) + uint256(allocation.treasuryShareBps)
            + uint256(allocation.staticsStakerShareBps) + uint256(allocation.basketStakerShareBps);
        // The shared hook remains Phase-2-ready for permissioned basket pools. Phase 1 general-pool
        // facets and revenue accounting independently require basketStakerShareBps == 0.
        if (economics.venueFeeBps > BPS || economics.additionalRewardRestrictedMask > 3 || total != BPS) {
            revert InvalidEconomics();
        }
    }

    function _enforceDiamond() private view {
        if (msg.sender != staticsDiamond) revert OnlyStaticsDiamond(msg.sender);
    }
}
