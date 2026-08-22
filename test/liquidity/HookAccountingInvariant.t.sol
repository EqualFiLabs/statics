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
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IStaticsProtocolRevenue} from "../../src/interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {StaticsSwapFeeHook} from "../../src/liquidity/StaticsSwapFeeHook.sol";

contract HookInvariantFeeReceiver {
    using SafeERC20 for IERC20;

    address public hook;
    mapping(address asset => uint256 amount) public stakerFees;
    mapping(address asset => uint256 amount) public creatorFees;
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

    function routeProtocolSwapFees(
        PoolId,
        address asset,
        IStaticsProtocolRevenue.ProtocolFeeDistribution calldata distribution
    ) external {
        require(msg.sender == hook);
        require(distribution.liquidityProvider == 0);
        require(distribution.basketStaker == 0);
        uint256 total = distribution.staticsStaker + distribution.creator + distribution.treasury;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), total);
        stakerFees[asset] += distribution.staticsStaker;
        creatorFees[asset] += distribution.creator;
        treasuryFees[asset] += distribution.treasury;
    }

    function registerPool(PoolKey calldata key) external returns (PoolId) {
        return IStaticsSwapFeeHook(hook).registerPool(key, IStaticsSwapFeeHook.PoolKind.General, address(this));
    }

    function setPoolFeeRate(PoolId poolId, uint16 inputFeeBps, uint16 outputFeeBps) external {
        IStaticsSwapFeeHook(hook).setPoolFeeRate(poolId, inputFeeBps, outputFeeBps);
    }

    function setGeneralFeeAllocation(IStaticsSwapFeeHook.GeneralFeeAllocation calldata allocation) external {
        IStaticsSwapFeeHook(hook).setGeneralFeeAllocation(allocation);
    }
}

contract HookAccountingHandler is Test {
    uint16 private constant INPUT_FEE_BPS = 25;
    uint16 private constant OUTPUT_FEE_BPS = 25;

    PoolSwapTest private immutable router;
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
        StaticsSwapFeeHook hook_,
        HookInvariantFeeReceiver receiver_,
        PoolKey memory key_
    ) {
        router = router_;
        hook = hook_;
        receiver = receiver_;
        key = key_;
        poolId = key_.toId();
        token0 = Currency.unwrap(key_.currency0);
        token1 = Currency.unwrap(key_.currency1);
        IERC20(token0).approve(address(router_), type(uint256).max);
        IERC20(token1).approve(address(router_), type(uint256).max);
    }

    function swapExactInput(uint256 rawAmount, bool zeroForOne) external {
        uint256 amount = bound(rawAmount, 1_000, 0.001 ether);
        _swap(-int256(amount), zeroForOne);
    }

    function swapExactOutput(uint256 rawAmount, bool zeroForOne) external {
        uint256 amount = bound(rawAmount, 1_000, 0.0001 ether);
        _swap(int256(amount), zeroForOne);
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
        // Keep LP allocation at zero (no eligible LPs) so all configurable weight lands in observable
        // staker/treasury buckets; POL is exercised through a nonzero pol share.
        uint256 polShareBps = bound(rawPolShareBps, 0, 9_500);
        uint256 staticsStakerShareBps = bound(rawStakerShareBps, 0, 9_500 - polShareBps);
        uint256 treasuryShareBps = 9_500 - polShareBps - staticsStakerShareBps;
        // silence unused param without changing the fuzz surface
        rawLiquidityProviderShareBps;
        receiver.setPoolFeeRate(poolId, uint16(inputFeeBps), uint16(outputFeeBps));
        receiver.setGeneralFeeAllocation(
            IStaticsSwapFeeHook.GeneralFeeAllocation({
                polShareBps: uint16(polShareBps),
                liquidityProviderShareBps: 0,
                staticsStakerShareBps: uint16(staticsStakerShareBps),
                treasuryShareBps: uint16(treasuryShareBps)
            })
        );
    }

    function clearPoolConfiguration() external {
        receiver.setPoolFeeRate(poolId, INPUT_FEE_BPS, OUTPUT_FEE_BPS);
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
            // With staker+treasury+creator always summing to configurable+creator > 0, every realized
            // two-asset swap must route both legs.
            if (
                delta.amount0() != 0 && delta.amount1() != 0
                    && (_routed(token0) <= token0FeesBefore || _routed(token1) <= token1FeesBefore)
            ) missedFeeLeg = true;
            uint128 locked = hook.lockedLiquidity(poolId);
            if (locked < lastLockedLiquidity) liquidityDecreased = true;
            lastLockedLiquidity = locked;
        } catch {}
    }

    function _routed(address asset) private view returns (uint256) {
        return receiver.stakerFees(asset) + receiver.treasuryFees(asset) + receiver.creatorFees(asset);
    }
}

contract HookAccountingInvariantTest is StdInvariant, Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint16 private constant INPUT_FEE_BPS = 25;
    uint16 private constant OUTPUT_FEE_BPS = 25;
    uint160 private constant REQUIRED_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        | Hooks.BEFORE_DONATE_FLAG;

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

        handler = new HookAccountingHandler(swapRouter, hook, receiver, poolKey);
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
        IStaticsSwapFeeHook.PoolFeeRate memory rate = hook.poolFeeRate(poolId);
        assertLe(uint256(rate.inputFeeBps) + uint256(rate.outputFeeBps), 200);
        IStaticsSwapFeeHook.GeneralFeeAllocation memory allocation = hook.generalFeeAllocation();
        assertEq(
            uint256(allocation.polShareBps) + uint256(allocation.liquidityProviderShareBps)
                + uint256(allocation.staticsStakerShareBps) + uint256(allocation.treasuryShareBps),
            9_500
        );
    }

    function _assertReceiverBalance(Currency currency) private view {
        address asset = Currency.unwrap(currency);
        assertEq(
            IERC20(asset).balanceOf(address(receiver)),
            receiver.stakerFees(asset) + receiver.treasuryFees(asset) + receiver.creatorFees(asset)
        );
    }

    function _deployHook() private returns (StaticsSwapFeeHook deployed) {
        bytes memory constructorArgs = abi.encode(manager, address(receiver), INPUT_FEE_BPS, OUTPUT_FEE_BPS);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_FLAGS, type(StaticsSwapFeeHook).creationCode, constructorArgs);
        deployed = new StaticsSwapFeeHook{salt: salt}(manager, address(receiver), INPUT_FEE_BPS, OUTPUT_FEE_BPS);
        assertEq(address(deployed), expected);
    }
}
