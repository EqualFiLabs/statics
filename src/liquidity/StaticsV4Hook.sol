// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsHookController, RevenueChannel} from "../interfaces/IStaticsHookController.sol";
import {IStaticsV4Hook} from "../interfaces/IStaticsV4Hook.sol";

/// @notice Standalone multi-pool bilateral-fee hook and permanent STATICS/WETH inventory market.
contract StaticsV4Hook is BaseHook, IStaticsV4Hook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    uint256 public constant BPS = 10_000;
    uint16 public constant MAX_COMBINED_HOOK_FEE_BPS = 200;
    uint256 public constant PUBLIC_LAUNCH_INVENTORY = 810_045_000 ether;
    int24 public constant CANONICAL_TICK_SPACING = 10;
    uint8 public constant LAUNCH_BAND_COUNT = 6;

    uint8 private constant UNLOCK_INSTALL_LAUNCH = 1;
    uint8 private constant UNLOCK_COMPOUND = 2;
    bytes32 private constant PERMANENT_LIQUIDITY_SALT = keccak256("statics.genesis.permanent.liquidity");

    struct StoredPoolConfiguration {
        FeeConfiguration fees;
        RevenueRecipients recipients;
        uint160 expectedSqrtPriceX96;
        address initializer;
        bool registered;
        bool initialized;
        bool externalLiquidityEnabled;
    }

    address public immutable override controller;
    address public immutable override statics;
    address public immutable override weth;

    PoolKey private canonicalKey;
    PoolId private canonicalId;
    mapping(PoolId poolId => StoredPoolConfiguration configuration) private configurations;
    mapping(PoolId poolId => mapping(Currency currency => uint256 amount)) private polPending;
    mapping(Currency currency => uint256 amount) private totalPolPending;
    mapping(PoolId poolId => uint128 liquidity) private permanentLiquidity;
    mapping(uint8 band => uint128 liquidity) public launchBandLiquidity;
    mapping(uint8 band => uint256 amount) public launchBandStatics;
    uint256 public override launchRoundingDust;
    bool public launchInventoryInstalled;
    bool private launchInstallationCallbackActive;
    bool private liquidityModificationActive;
    bytes32 private activeLiquiditySalt;
    int24 private activeTickLower;
    int24 private activeTickUpper;
    bool private entered;

    error ZeroAddress();
    error IdenticalCurrencies();
    error OnlyController(address caller);
    error ControllerNotBound();
    error InvalidFeeConfiguration();
    error InvalidRevenueRecipient(RevenueChannel channel);
    error PoolAlreadyRegistered(PoolId poolId);
    error PoolNotRegistered(PoolId poolId);
    error PoolAlreadyInitialized(PoolId poolId);
    error PoolNotInitialized(PoolId poolId);
    error InvalidPoolKey();
    error InvalidPoolPrice(uint160 expected, uint160 actual);
    error UnauthorizedPoolInitialization(address sender);
    error InsufficientLaunchInventory(uint256 expected, uint256 actual);
    error LaunchInstallationFailed();
    error InvalidLaunchBand(uint8 band);
    error InvalidLaunchLiquidity(uint8 band);
    error LaunchInventoryOverspent(uint8 band, uint256 maximum, uint256 actual);
    error UnexpectedLaunchCurrencyDelta(Currency currency, int256 delta);
    error ExternalLiquidityDisabled(PoolId poolId);
    error ExternalLiquidityAlreadyEnabled(PoolId poolId);
    error ExternalLiquidityRequiresLpRewards();
    error PermanentLiquidityRemovalForbidden();
    error CanonicalPoolDonationForbidden();
    error InvalidUnlockCaller(address caller);
    error InvalidUnlockAction(uint8 action);
    error ReentrantHookCall();
    error HookFeeConsumesSwap(uint256 amountSpecified, uint256 fee);
    error PartialSwapUnsupported(uint256 expectedSpecified, uint256 actualSpecified);
    error UnexpectedLiquidityModification(address sender);
    error PendingLiquidityInsolvent(Currency currency, uint256 required, uint256 available);
    error PermanentLiquidityExceedsPending(Currency currency, uint256 required, uint256 available);
    error UnexpectedTokenDebit(Currency currency, uint256 expected, uint256 actual);
    error IncompatiblePoolCurrency(Currency currency, uint256 expected, uint256 actual);
    error UnexpectedSettlement(Currency currency, uint256 expected, uint256 actual);

    modifier onlyController() {
        if (msg.sender != controller) revert OnlyController(msg.sender);
        _;
    }

    modifier nonReentrantHook() {
        if (entered) revert ReentrantHookCall();
        entered = true;
        _;
        entered = false;
    }

    constructor(
        IPoolManager manager,
        address controller_,
        address statics_,
        address weth_,
        address treasuryRecipient,
        uint16 inputFeeBps,
        uint16 outputFeeBps
    ) BaseHook(manager) {
        if (
            controller_ == address(0) || statics_ == address(0) || weth_ == address(0)
                || treasuryRecipient == address(0)
        ) revert ZeroAddress();
        if (statics_ == weth_) revert IdenticalCurrencies();
        controller = controller_;
        statics = statics_;
        weth = weth_;

        Currency staticsCurrency = Currency.wrap(statics_);
        Currency wethCurrency = Currency.wrap(weth_);
        (Currency currency0, Currency currency1) =
            statics_ < weth_ ? (staticsCurrency, wethCurrency) : (wethCurrency, staticsCurrency);
        canonicalKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0,
            tickSpacing: CANONICAL_TICK_SPACING,
            hooks: IHooks(address(this))
        });
        canonicalId = canonicalKey.toId();

        FeeConfiguration memory fees = FeeConfiguration({
            inputFeeBps: inputFeeBps,
            outputFeeBps: outputFeeBps,
            polShareBps: 2_500,
            liquidityProviderShareBps: 0,
            basketStakerShareBps: 0,
            staticsStakerShareBps: 0,
            partnerShareBps: 0,
            creatorShareBps: 0,
            treasuryShareBps: 7_500
        });
        RevenueRecipients memory recipients;
        recipients.treasury = treasuryRecipient;
        _validateConfiguration(fees, recipients);
        configurations[canonicalId] = StoredPoolConfiguration({
            fees: fees,
            recipients: recipients,
            expectedSqrtPriceX96: TickMath.getSqrtPriceAtTick(_openingTick()),
            initializer: controller_,
            registered: true,
            initialized: false,
            externalLiquidityEnabled: false
        });
        emit PoolRegistered(canonicalId, TickMath.getSqrtPriceAtTick(_openingTick()), controller_, true);
        emit PoolConfigurationSet(canonicalId, fees, recipients);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.afterInitialize = true;
        permissions.beforeAddLiquidity = true;
        permissions.beforeRemoveLiquidity = true;
        permissions.beforeDonate = true;
        permissions.beforeSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwap = true;
        permissions.afterSwapReturnDelta = true;
    }

    function canonicalPoolKey() external view override returns (PoolKey memory) {
        return canonicalKey;
    }

    function canonicalPoolId() external view override returns (PoolId) {
        return canonicalId;
    }

    function poolConfiguration(PoolId poolId)
        external
        view
        override
        returns (PoolConfigurationView memory configuration)
    {
        StoredPoolConfiguration storage stored = configurations[poolId];
        configuration = PoolConfigurationView({
            fees: stored.fees,
            recipients: stored.recipients,
            expectedSqrtPriceX96: stored.expectedSqrtPriceX96,
            initializer: stored.initializer,
            registered: stored.registered,
            initialized: stored.initialized,
            externalLiquidityEnabled: stored.externalLiquidityEnabled
        });
    }

    function registerPool(
        PoolKey calldata key,
        uint160 expectedSqrtPriceX96,
        address initializer,
        FeeConfiguration calldata fees,
        RevenueRecipients calldata recipients
    ) external override onlyController returns (PoolId poolId) {
        if (
            key.currency0.isAddressZero() || key.currency1.isAddressZero() || key.fee != 0
                || address(key.hooks) != address(this) || expectedSqrtPriceX96 == 0 || initializer == address(0)
        ) revert InvalidPoolKey();
        poolId = key.toId();
        if (configurations[poolId].registered) revert PoolAlreadyRegistered(poolId);
        _validateConfiguration(fees, recipients);
        configurations[poolId] = StoredPoolConfiguration({
            fees: fees,
            recipients: recipients,
            expectedSqrtPriceX96: expectedSqrtPriceX96,
            initializer: initializer,
            registered: true,
            initialized: false,
            externalLiquidityEnabled: false
        });
        emit PoolRegistered(poolId, expectedSqrtPriceX96, initializer, false);
        emit PoolConfigurationSet(poolId, fees, recipients);
    }

    function setPoolConfiguration(PoolId poolId, FeeConfiguration calldata fees, RevenueRecipients calldata recipients)
        external
        override
        onlyController
    {
        StoredPoolConfiguration storage configuration = _registered(poolId);
        if (!configuration.externalLiquidityEnabled && fees.liquidityProviderShareBps != 0) {
            revert ExternalLiquidityRequiresLpRewards();
        }
        _validateConfiguration(fees, recipients);
        configuration.fees = fees;
        configuration.recipients = recipients;
        emit PoolConfigurationSet(poolId, fees, recipients);
    }

    function activateExternalLiquidity(
        PoolId poolId,
        FeeConfiguration calldata fees,
        RevenueRecipients calldata recipients
    ) external override onlyController {
        StoredPoolConfiguration storage configuration = _initialized(poolId);
        if (configuration.externalLiquidityEnabled) revert ExternalLiquidityAlreadyEnabled(poolId);
        if (fees.liquidityProviderShareBps == 0 || recipients.liquidityProvider == address(0)) {
            revert ExternalLiquidityRequiresLpRewards();
        }
        _validateConfiguration(fees, recipients);
        configuration.externalLiquidityEnabled = true;
        configuration.fees = fees;
        configuration.recipients = recipients;
        emit PoolConfigurationSet(poolId, fees, recipients);
        emit ExternalLiquidityActivated(poolId, recipients.liquidityProvider);
    }

    function compoundPermanentLiquidity(PoolKey calldata key)
        external
        override
        nonReentrantHook
        returns (uint128 liquidityAdded)
    {
        PoolId poolId = key.toId();
        _initialized(poolId);
        bytes memory result = poolManager.unlock(abi.encode(UNLOCK_COMPOUND, abi.encode(key)));
        liquidityAdded = abi.decode(result, (uint128));
    }

    function pendingPermanentLiquidity(PoolId poolId, Currency currency)
        external
        view
        override
        returns (uint256 amount)
    {
        return polPending[poolId][currency];
    }

    function lockedPermanentLiquidity(PoolId poolId) external view override returns (uint128 liquidity) {
        return permanentLiquidity[poolId];
    }

    function launchBandTicks(uint8 band) external view override returns (int24 tickLower, int24 tickUpper) {
        return _bandTicks(band);
    }

    function launchBandTarget(uint8 band) external pure override returns (uint256 amount) {
        return _bandInventory(band);
    }

    function launchBandSalt(uint8 band) external pure override returns (bytes32 salt) {
        if (band == 0 || band > LAUNCH_BAND_COUNT) revert InvalidLaunchBand(band);
        return keccak256(abi.encode("statics.genesis.launch.band", band));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert InvalidUnlockCaller(msg.sender);
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (action == UNLOCK_INSTALL_LAUNCH) {
            if (!launchInstallationCallbackActive || launchInventoryInstalled) revert LaunchInstallationFailed();
            _installLaunchPositions();
            return "";
        }
        if (action == UNLOCK_COMPOUND) {
            PoolKey memory key = abi.decode(payload, (PoolKey));
            return abi.encode(_compoundUnlocked(key, key.toId()));
        }
        revert InvalidUnlockAction(action);
    }

    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24)
        internal
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        StoredPoolConfiguration storage configuration = _registered(poolId);
        if (configuration.initialized) revert PoolAlreadyInitialized(poolId);
        if (sqrtPriceX96 != configuration.expectedSqrtPriceX96) {
            revert InvalidPoolPrice(configuration.expectedSqrtPriceX96, sqrtPriceX96);
        }
        if (PoolId.unwrap(poolId) == PoolId.unwrap(canonicalId)) {
            if (sender != controller || IStaticsHookController(controller).hook() != address(this)) {
                revert UnauthorizedPoolInitialization(sender);
            }
            uint256 inventory = IERC20(statics).balanceOf(address(this));
            if (inventory < PUBLIC_LAUNCH_INVENTORY) {
                revert InsufficientLaunchInventory(PUBLIC_LAUNCH_INVENTORY, inventory);
            }
            launchInstallationCallbackActive = true;
            poolManager.unlock(abi.encode(UNLOCK_INSTALL_LAUNCH, bytes("")));
            launchInstallationCallbackActive = false;
            if (!launchInventoryInstalled) revert LaunchInstallationFailed();
        } else if (sender != configuration.initializer) {
            revert UnauthorizedPoolInitialization(sender);
        }
        configuration.initialized = true;
        return IHooks.afterInitialize.selector;
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        PoolId poolId = key.toId();
        StoredPoolConfiguration storage configuration = configurations[poolId];
        if (
            liquidityModificationActive && sender == address(this) && params.liquidityDelta > 0
                && params.salt == activeLiquiditySalt && params.tickLower == activeTickLower
                && params.tickUpper == activeTickUpper
        ) return IHooks.beforeAddLiquidity.selector;
        if (!configuration.externalLiquidityEnabled) revert ExternalLiquidityDisabled(poolId);
        return IHooks.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        PoolId poolId = key.toId();
        if (sender == address(this)) revert PermanentLiquidityRemovalForbidden();
        if (!configurations[poolId].externalLiquidityEnabled) revert ExternalLiquidityDisabled(poolId);
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function _beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert CanonicalPoolDonationForbidden();
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        FeeConfiguration memory fees = _initialized(poolId).fees;
        bool exactInput = params.amountSpecified < 0;
        uint16 feeBps = exactInput ? fees.inputFeeBps : fees.outputFeeBps;
        uint256 realized = _absolute(params.amountSpecified);
        uint256 charged = Math.mulDiv(realized, feeBps, BPS, Math.Rounding.Ceil);
        if (charged == 0) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        if (exactInput && charged >= realized) revert HookFeeConsumesSwap(realized, charged);

        Currency specified = params.zeroForOne == exactInput ? key.currency0 : key.currency1;
        _allocateAndRoute(poolId, specified, realized, charged, true);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(charged.toInt128(), 0), 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        FeeConfiguration memory fees = configurations[poolId].fees;
        bool exactInput = params.amountSpecified < 0;
        bool specifiedCurrencyIs0 = exactInput == params.zeroForOne;
        int128 specifiedDelta = specifiedCurrencyIs0 ? delta.amount0() : delta.amount1();
        uint256 requestedSpecified = _absolute(params.amountSpecified);
        uint16 specifiedFeeBps = exactInput ? fees.inputFeeBps : fees.outputFeeBps;
        uint256 specifiedFee = Math.mulDiv(requestedSpecified, specifiedFeeBps, BPS, Math.Rounding.Ceil);
        uint256 expectedSpecified = exactInput ? requestedSpecified - specifiedFee : requestedSpecified + specifiedFee;
        uint256 actualSpecified = _absolute(int256(specifiedDelta));
        if (actualSpecified != expectedSpecified) revert PartialSwapUnsupported(expectedSpecified, actualSpecified);

        Currency unspecified = specifiedCurrencyIs0 ? key.currency1 : key.currency0;
        int128 unspecifiedDelta = specifiedCurrencyIs0 ? delta.amount1() : delta.amount0();
        uint16 feeBps = exactInput ? fees.outputFeeBps : fees.inputFeeBps;
        uint256 realized = _absolute(int256(unspecifiedDelta));
        uint256 charged = Math.mulDiv(realized, feeBps, BPS, Math.Rounding.Ceil);
        if (charged != 0) {
            _allocateAndRoute(poolId, unspecified, realized, charged, false);
        }

        _compoundUnlocked(key, poolId);
        return (IHooks.afterSwap.selector, charged.toInt128());
    }

    function _installLaunchPositions() private {
        uint256 settled;
        for (uint8 band = 1; band <= LAUNCH_BAND_COUNT; ++band) {
            uint256 target = _bandInventory(band);
            (int24 tickLower, int24 tickUpper) = _bandTicks(band);
            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
            uint128 liquidity = Currency.unwrap(canonicalKey.currency0) == statics
                ? LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, target)
                : LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, target);
            if (liquidity == 0) revert InvalidLaunchLiquidity(band);
            bytes32 salt = keccak256(abi.encode("statics.genesis.launch.band", band));
            ModifyLiquidityParams memory params = ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: salt
            });
            _beginLiquidityModification(tickLower, tickUpper, salt);
            (BalanceDelta delta,) = poolManager.modifyLiquidity(canonicalKey, params, "");
            _endLiquidityModification();

            int128 staticsDelta = Currency.unwrap(canonicalKey.currency0) == statics ? delta.amount0() : delta.amount1();
            int128 wethDelta = Currency.unwrap(canonicalKey.currency0) == weth ? delta.amount0() : delta.amount1();
            if (staticsDelta >= 0) {
                revert UnexpectedLaunchCurrencyDelta(Currency.wrap(statics), int256(staticsDelta));
            }
            if (wethDelta != 0) revert UnexpectedLaunchCurrencyDelta(Currency.wrap(weth), int256(wethDelta));
            uint256 staticsPaid = _absolute(int256(staticsDelta));
            if (staticsPaid > target) revert LaunchInventoryOverspent(band, target, staticsPaid);
            _settle(Currency.wrap(statics), staticsPaid);
            launchBandLiquidity[band] = liquidity;
            launchBandStatics[band] = staticsPaid;
            settled += staticsPaid;
            emit LaunchPositionInstalled(canonicalId, band, tickLower, tickUpper, salt, liquidity, staticsPaid);
        }
        if (settled > PUBLIC_LAUNCH_INVENTORY) {
            revert LaunchInventoryOverspent(0, PUBLIC_LAUNCH_INVENTORY, settled);
        }
        launchRoundingDust = PUBLIC_LAUNCH_INVENTORY - settled;
        launchInventoryInstalled = true;
        _assertPendingSolvency(Currency.wrap(statics));
        emit CanonicalLaunchInitialized(
            canonicalId,
            configurations[canonicalId].expectedSqrtPriceX96,
            PUBLIC_LAUNCH_INVENTORY,
            settled,
            launchRoundingDust
        );
    }

    function _allocateAndRoute(PoolId poolId, Currency currency, uint256 realized, uint256 charged, bool inputLeg)
        private
    {
        StoredPoolConfiguration storage configuration = configurations[poolId];
        FeeConfiguration memory fees = configuration.fees;
        uint256 polAmount = Math.mulDiv(charged, fees.polShareBps, BPS);
        uint256 liquidityProviderAmount = Math.mulDiv(charged, fees.liquidityProviderShareBps, BPS);
        uint256 basketStakerAmount = Math.mulDiv(charged, fees.basketStakerShareBps, BPS);
        uint256 staticsStakerAmount = Math.mulDiv(charged, fees.staticsStakerShareBps, BPS);
        uint256 partnerAmount = Math.mulDiv(charged, fees.partnerShareBps, BPS);
        uint256 creatorAmount = Math.mulDiv(charged, fees.creatorShareBps, BPS);
        uint256 treasuryAmount = charged - polAmount - liquidityProviderAmount - basketStakerAmount
            - staticsStakerAmount - partnerAmount - creatorAmount;
        _creditPending(poolId, currency, polAmount);

        uint256 routed = charged - polAmount;
        if (routed != 0) {
            poolManager.mint(controller, currency.toId(), routed);
            RevenueRecipients memory recipients = configuration.recipients;
            _accrue(
                poolId,
                currency,
                RevenueChannel.LiquidityProvider,
                recipients.liquidityProvider,
                liquidityProviderAmount
            );
            _accrue(poolId, currency, RevenueChannel.BasketStaker, recipients.basketStaker, basketStakerAmount);
            _accrue(poolId, currency, RevenueChannel.StaticsStaker, recipients.staticsStaker, staticsStakerAmount);
            _accrue(poolId, currency, RevenueChannel.Partner, recipients.partner, partnerAmount);
            _accrue(poolId, currency, RevenueChannel.Creator, recipients.creator, creatorAmount);
            _accrue(poolId, currency, RevenueChannel.Treasury, recipients.treasury, treasuryAmount);
        }
        _assertPendingSolvency(currency);
        emit SwapLegFeeAccrued(poolId, currency, inputLeg, realized, charged, polAmount, routed);
    }

    function _accrue(PoolId poolId, Currency currency, RevenueChannel channel, address recipient, uint256 amount)
        private
    {
        if (amount != 0) {
            IStaticsHookController(controller).accrueRevenue(poolId, currency, channel, recipient, amount);
        }
    }

    function _compoundUnlocked(PoolKey memory key, PoolId poolId) private returns (uint128 liquidityAdded) {
        uint256 available0 = polPending[poolId][key.currency0];
        uint256 available1 = polPending[poolId][key.currency1];
        if (available0 == 0 || available1 == 0) return 0;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        liquidityAdded = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            available0,
            available1
        );
        if (liquidityAdded == 0) return 0;

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidityAdded)),
            salt: PERMANENT_LIQUIDITY_SALT
        });
        _beginLiquidityModification(tickLower, tickUpper, PERMANENT_LIQUIDITY_SALT);
        (BalanceDelta delta,) = poolManager.modifyLiquidity(key, params, "");
        _endLiquidityModification();
        (uint256 amount0,) = _applyLiquidityDelta(poolId, key.currency0, delta.amount0(), available0);
        (uint256 amount1,) = _applyLiquidityDelta(poolId, key.currency1, delta.amount1(), available1);
        permanentLiquidity[poolId] += liquidityAdded;
        emit PermanentLiquidityAdded(
            poolId,
            liquidityAdded,
            amount0,
            amount1,
            polPending[poolId][key.currency0],
            polPending[poolId][key.currency1]
        );
    }

    function _applyLiquidityDelta(PoolId poolId, Currency currency, int128 delta, uint256 available)
        private
        returns (uint256 amountPaid, uint256 amountCollected)
    {
        if (delta < 0) {
            amountPaid = _absolute(int256(delta));
            if (amountPaid > available) revert PermanentLiquidityExceedsPending(currency, amountPaid, available);
            polPending[poolId][currency] = available - amountPaid;
            totalPolPending[currency] -= amountPaid;
            poolManager.burn(address(this), currency.toId(), amountPaid);
        } else if (delta > 0) {
            amountCollected = uint256(uint128(delta));
            _creditPending(poolId, currency, amountCollected);
        }
        _assertPendingSolvency(currency);
    }

    function _creditPending(PoolId poolId, Currency currency, uint256 amount) private {
        if (amount == 0) return;
        poolManager.mint(address(this), currency.toId(), amount);
        polPending[poolId][currency] += amount;
        totalPolPending[currency] += amount;
    }

    function _beginLiquidityModification(int24 tickLower, int24 tickUpper, bytes32 salt) private {
        liquidityModificationActive = true;
        activeTickLower = tickLower;
        activeTickUpper = tickUpper;
        activeLiquiditySalt = salt;
    }

    function _endLiquidityModification() private {
        liquidityModificationActive = false;
        delete activeTickLower;
        delete activeTickUpper;
        delete activeLiquiditySalt;
    }

    function _settle(Currency currency, uint256 amount) private {
        if (amount == 0) return;
        poolManager.sync(currency);
        uint256 senderBefore = currency.balanceOfSelf();
        uint256 receiverBefore = currency.balanceOf(address(poolManager));
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
        uint256 senderAfter = currency.balanceOfSelf();
        uint256 receiverAfter = currency.balanceOf(address(poolManager));
        _enforceExactDebit(currency, senderBefore, senderAfter, amount);
        uint256 received = receiverAfter >= receiverBefore ? receiverAfter - receiverBefore : 0;
        if (received != amount) revert IncompatiblePoolCurrency(currency, amount, received);
        uint256 settled = poolManager.settle();
        if (settled != amount) revert UnexpectedSettlement(currency, amount, settled);
    }

    function _assertPendingSolvency(Currency currency) private view {
        uint256 required = totalPolPending[currency];
        uint256 available = poolManager.balanceOf(address(this), currency.toId());
        if (available < required) revert PendingLiquidityInsolvent(currency, required, available);
        if (Currency.unwrap(currency) == statics && currency.balanceOfSelf() < launchRoundingDust) {
            revert PendingLiquidityInsolvent(currency, launchRoundingDust, currency.balanceOfSelf());
        }
    }

    function _enforceExactDebit(Currency currency, uint256 beforeBalance, uint256 afterBalance, uint256 expected)
        private
        pure
    {
        uint256 actual = beforeBalance >= afterBalance ? beforeBalance - afterBalance : 0;
        if (actual != expected) revert UnexpectedTokenDebit(currency, expected, actual);
    }

    function _validateConfiguration(FeeConfiguration memory fees, RevenueRecipients memory recipients) private pure {
        uint256 combinedFee = uint256(fees.inputFeeBps) + fees.outputFeeBps;
        uint256 allocation = uint256(fees.polShareBps) + fees.liquidityProviderShareBps + fees.basketStakerShareBps
            + fees.staticsStakerShareBps + fees.partnerShareBps + fees.creatorShareBps + fees.treasuryShareBps;
        if (combinedFee > MAX_COMBINED_HOOK_FEE_BPS || allocation != BPS) revert InvalidFeeConfiguration();
        _requireRecipient(
            fees.liquidityProviderShareBps, recipients.liquidityProvider, RevenueChannel.LiquidityProvider
        );
        _requireRecipient(fees.basketStakerShareBps, recipients.basketStaker, RevenueChannel.BasketStaker);
        _requireRecipient(fees.staticsStakerShareBps, recipients.staticsStaker, RevenueChannel.StaticsStaker);
        _requireRecipient(fees.partnerShareBps, recipients.partner, RevenueChannel.Partner);
        _requireRecipient(fees.creatorShareBps, recipients.creator, RevenueChannel.Creator);
        _requireRecipient(fees.treasuryShareBps, recipients.treasury, RevenueChannel.Treasury);
    }

    function _requireRecipient(uint16 share, address recipient, RevenueChannel channel) private pure {
        if ((share == 0) != (recipient == address(0))) revert InvalidRevenueRecipient(channel);
    }

    function _registered(PoolId poolId) private view returns (StoredPoolConfiguration storage configuration) {
        configuration = configurations[poolId];
        if (!configuration.registered) revert PoolNotRegistered(poolId);
    }

    function _initialized(PoolId poolId) private view returns (StoredPoolConfiguration storage configuration) {
        configuration = _registered(poolId);
        if (!configuration.initialized) revert PoolNotInitialized(poolId);
    }

    function _openingTick() private view returns (int24) {
        return Currency.unwrap(canonicalKey.currency0) == statics ? int24(-166_040) : int24(166_040);
    }

    function _bandTicks(uint8 band) private view returns (int24 tickLower, int24 tickUpper) {
        if (band == 1) (tickLower, tickUpper) = (-166_040, -143_020);
        else if (band == 2) (tickLower, tickUpper) = (-143_020, -119_990);
        else if (band == 3) (tickLower, tickUpper) = (-119_990, -96_960);
        else if (band == 4) (tickLower, tickUpper) = (-96_960, -73_940);
        else if (band == 5) (tickLower, tickUpper) = (-73_940, -50_910);
        else if (band == 6) (tickLower, tickUpper) = (-50_910, -27_880);
        else revert InvalidLaunchBand(band);
        if (Currency.unwrap(canonicalKey.currency0) != statics) {
            (tickLower, tickUpper) = (-tickUpper, -tickLower);
        }
    }

    function _bandInventory(uint8 band) private pure returns (uint256) {
        if (band == 1) return 24_301_350 ether;
        if (band == 2) return 56_703_150 ether;
        if (band == 3) return 162_009_000 ether;
        if (band == 4) return 202_511_250 ether;
        if (band == 5) return 243_013_500 ether;
        if (band == 6) return 121_506_750 ether;
        revert InvalidLaunchBand(band);
    }

    function _absolute(int256 value) private pure returns (uint256) {
        return value < 0 ? uint256(-(value + 1)) + 1 : uint256(value);
    }
}
