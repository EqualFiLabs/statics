// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {StaticsSwapFeeHook} from "../../src/liquidity/StaticsSwapFeeHook.sol";

contract HookInvariantFeeReceiver {
    using SafeERC20 for IERC20;

    address public hook;
    mapping(address asset => uint256 amount) public stakerFees;
    mapping(address asset => uint256 amount) public treasuryFees;

    function configureHook(address hook_) external {
        require(hook == address(0));
        hook = hook_;
    }

    function canAccrueStakerRewards(address) external pure returns (bool) {
        return true;
    }

    function canAccrueLiquidityRewards(PoolId) external pure returns (bool) {
        return false;
    }

    function canAccrueBasketRewards(PoolId) external pure returns (bool) {
        return false;
    }

    function routeSwapFees(address asset, uint256 stakerAmount, uint256 treasuryAmount) public {
        require(msg.sender == hook);
        uint256 total = stakerAmount + treasuryAmount;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), total);
        stakerFees[asset] += stakerAmount;
        treasuryFees[asset] += treasuryAmount;
    }

    function routeCanonicalSwapFees(
        PoolId,
        address asset,
        uint256 liquidityProviderAmount,
        uint256 basketStakerAmount,
        uint256 staticsStakerAmount,
        uint256 treasuryAmount
    ) external {
        require(liquidityProviderAmount == 0);
        require(basketStakerAmount == 0);
        routeSwapFees(asset, staticsStakerAmount, treasuryAmount);
    }

    function registerPool(PoolKey calldata key) external returns (PoolId) {
        return IStaticsSwapFeeHook(hook).registerPool(key);
    }

    function setPoolFeeConfiguration(PoolId poolId, IStaticsSwapFeeHook.FeeConfiguration calldata configuration)
        external
    {
        IStaticsSwapFeeHook(hook).setPoolFeeConfiguration(poolId, configuration);
    }

    function clearPoolFeeConfiguration(PoolId poolId) external {
        IStaticsSwapFeeHook(hook).clearPoolFeeConfiguration(poolId);
    }
}

contract HookAccountingHandler is Test {
    PoolSwapTest private immutable router;
    PoolDonateTest private immutable donor;
    StaticsSwapFeeHook private immutable hook;
    HookInvariantFeeReceiver private immutable receiver;
    PoolId private immutable poolId;
    address private immutable token0;
    address private immutable token1;
    PoolKey private key;

    uint128 public lastLockedLiquidity;
    uint256 public successfulSwaps;
    bool public missedFeeLeg;
    bool public liquidityDecreased;

    constructor(
        PoolSwapTest router_,
        PoolDonateTest donor_,
        StaticsSwapFeeHook hook_,
        HookInvariantFeeReceiver receiver_,
        PoolKey memory key_
    ) {
        router = router_;
        donor = donor_;
        hook = hook_;
        receiver = receiver_;
        key = key_;
        poolId = key_.toId();
        token0 = Currency.unwrap(key_.currency0);
        token1 = Currency.unwrap(key_.currency1);
        IERC20(token0).approve(address(router_), type(uint256).max);
        IERC20(token1).approve(address(router_), type(uint256).max);
        IERC20(token0).approve(address(donor_), type(uint256).max);
        IERC20(token1).approve(address(donor_), type(uint256).max);
    }

    function swapExactInput(uint256 rawAmount, bool zeroForOne) external {
        uint256 amount = bound(rawAmount, 1_000, 0.001 ether);
        _swap(-int256(amount), zeroForOne);
    }

    function swapExactOutput(uint256 rawAmount, bool zeroForOne) external {
        uint256 amount = bound(rawAmount, 1_000, 0.0001 ether);
        _swap(int256(amount), zeroForOne);
    }

    function donate(uint256 rawAmount0, uint256 rawAmount1) external {
        uint256 amount0 = bound(rawAmount0, 1, 0.001 ether);
        uint256 amount1 = bound(rawAmount1, 1, 0.001 ether);
        PoolKey memory poolKey = key;
        try donor.donate(poolKey, amount0, amount1, "") {} catch {}
    }

    function setPoolConfiguration(
        uint256 rawInputFeeBps,
        uint256 rawOutputFeeBps,
        uint256 rawPolShareBps,
        uint256 rawLiquidityProviderShareBps,
        uint256 rawStakerShareBps
    ) external {
        uint256 inputFeeBps = bound(rawInputFeeBps, 1, 199);
        uint256 outputFeeBps = bound(rawOutputFeeBps, 1, 200 - inputFeeBps);
        uint256 polShareBps = bound(rawPolShareBps, 0, 10_000);
        uint256 liquidityProviderShareBps = bound(rawLiquidityProviderShareBps, 0, 10_000 - polShareBps);
        uint256 staticsStakerShareBps = bound(rawStakerShareBps, 0, 10_000 - polShareBps - liquidityProviderShareBps);
        uint256 treasuryShareBps = 10_000 - polShareBps - liquidityProviderShareBps - staticsStakerShareBps;
        receiver.setPoolFeeConfiguration(
            poolId,
            IStaticsSwapFeeHook.FeeConfiguration({
                inputFeeBps: uint16(inputFeeBps),
                outputFeeBps: uint16(outputFeeBps),
                polShareBps: uint16(polShareBps),
                liquidityProviderShareBps: uint16(liquidityProviderShareBps),
                basketStakerShareBps: 0,
                staticsStakerShareBps: uint16(staticsStakerShareBps),
                treasuryShareBps: uint16(treasuryShareBps)
            })
        );
    }

    function clearPoolConfiguration() external {
        receiver.clearPoolFeeConfiguration(poolId);
    }

    function _swap(int256 amountSpecified, bool zeroForOne) private {
        uint256 token0FeesBefore = _routed(token0);
        uint256 token1FeesBefore = _routed(token1);
        PoolKey memory poolKey = key;
        try router.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) returns (
            BalanceDelta delta
        ) {
            ++successfulSwaps;
            IStaticsSwapFeeHook.PoolFeeConfigurationView memory configuration = hook.poolFeeConfiguration(poolId);
            bool routesExternalFees = configuration.staticsStakerShareBps != 0 || configuration.treasuryShareBps != 0;
            if (
                routesExternalFees && delta.amount0() != 0 && delta.amount1() != 0
                    && (_routed(token0) <= token0FeesBefore || _routed(token1) <= token1FeesBefore)
            ) missedFeeLeg = true;
            uint128 locked = hook.lockedLiquidity(poolId);
            if (locked < lastLockedLiquidity) liquidityDecreased = true;
            lastLockedLiquidity = locked;
        } catch {}
    }

    function _routed(address asset) private view returns (uint256) {
        return receiver.stakerFees(asset) + receiver.treasuryFees(asset);
    }
}

contract HookAccountingInvariantTest is StdInvariant, Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint16 private constant INPUT_FEE_BPS = 25;
    uint16 private constant OUTPUT_FEE_BPS = 25;
    uint160 private constant REQUIRED_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    HookInvariantFeeReceiver private receiver;
    StaticsSwapFeeHook private hook;
    HookAccountingHandler private handler;
    PoolKey private poolKey;
    PoolId private poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        receiver = new HookInvariantFeeReceiver();
        hook = _deployHook();
        receiver.configureHook(address(hook));
        poolKey = PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 10, hooks: IHooks(hook)});
        poolId = receiver.registerPool(poolKey);
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, "");

        handler = new HookAccountingHandler(swapRouter, donateRouter, hook, receiver, poolKey);
        MockERC20(Currency.unwrap(currency0)).mint(address(handler), 1_000_000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(handler), 1_000_000 ether);
        targetContract(address(handler));
    }

    function invariantEverySuccessfulSwapRoutesBothFeeLegs() public view {
        assertFalse(handler.missedFeeLeg(), "realized two-asset swap missed one fee leg");
        assertFalse(handler.liquidityDecreased(), "locked POL liquidity decreased");
    }

    function invariantReceiverBalancesMatchRoutedFeeLedgers() public view {
        _assertReceiverBalance(currency0);
        _assertReceiverBalance(currency1);
    }

    function invariantHookBalancesCoverPendingPermanentLiquidity() public view {
        assertGe(
            IERC20(Currency.unwrap(currency0)).balanceOf(address(hook)),
            hook.pendingPermanentLiquidity(poolId, currency0)
        );
        assertGe(
            IERC20(Currency.unwrap(currency1)).balanceOf(address(hook)),
            hook.pendingPermanentLiquidity(poolId, currency1)
        );
    }

    function invariantEffectivePoolConfigurationIsValid() public view {
        IStaticsSwapFeeHook.PoolFeeConfigurationView memory configuration = hook.poolFeeConfiguration(poolId);
        assertLe(uint256(configuration.inputFeeBps) + uint256(configuration.outputFeeBps), 200);
        assertEq(
            uint256(configuration.polShareBps) + uint256(configuration.liquidityProviderShareBps)
                + uint256(configuration.basketStakerShareBps) + uint256(configuration.staticsStakerShareBps)
                + uint256(configuration.treasuryShareBps),
            10_000
        );
    }

    function _assertReceiverBalance(Currency currency) private view {
        address asset = Currency.unwrap(currency);
        assertEq(IERC20(asset).balanceOf(address(receiver)), receiver.stakerFees(asset) + receiver.treasuryFees(asset));
    }

    function _deployHook() private returns (StaticsSwapFeeHook deployed) {
        bytes memory constructorArgs = abi.encode(manager, address(receiver), INPUT_FEE_BPS, OUTPUT_FEE_BPS);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_FLAGS, type(StaticsSwapFeeHook).creationCode, constructorArgs);
        deployed = new StaticsSwapFeeHook{salt: salt}(manager, address(receiver), INPUT_FEE_BPS, OUTPUT_FEE_BPS);
        assertEq(address(deployed), expected);
    }
}
