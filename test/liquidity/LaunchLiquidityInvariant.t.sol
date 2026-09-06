// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
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
import {StaticsLaunchLiquidityHook} from "../../src/liquidity/StaticsLaunchLiquidityHook.sol";

contract LaunchLiquidityHandler is Test {
    PoolSwapTest private immutable router;
    StaticsLaunchLiquidityHook private immutable hook;
    PoolId private immutable poolId;
    Currency private immutable currency0;
    Currency private immutable currency1;
    address private immutable feeReceiver;
    PoolKey private key;

    uint128 public lastLiquidity;
    uint256 public lastReceiver0;
    uint256 public lastReceiver1;
    bool public liquidityDecreased;
    bool public receiverBalanceDecreased;
    bool public maintenancePaidCaller;

    constructor(PoolSwapTest router_, StaticsLaunchLiquidityHook hook_, PoolKey memory key_, address feeReceiver_) {
        router = router_;
        hook = hook_;
        key = key_;
        poolId = key_.toId();
        currency0 = key_.currency0;
        currency1 = key_.currency1;
        feeReceiver = feeReceiver_;
        IERC20(Currency.unwrap(currency0)).approve(address(router_), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(router_), type(uint256).max);
    }

    function swapExactInput(bool zeroForOne, uint256 rawAmount) external {
        _swap(zeroForOne, -int256(bound(rawAmount, 1_000, 0.001 ether)));
    }

    function swapExactOutput(bool zeroForOne, uint256 rawAmount) external {
        _swap(zeroForOne, int256(bound(rawAmount, 1_000, 0.0005 ether)));
    }

    function compound() external {
        uint256 balance0 = currency0.balanceOf(address(this));
        uint256 balance1 = currency1.balanceOf(address(this));
        try hook.compoundPOL(key) {} catch {}
        if (currency0.balanceOf(address(this)) > balance0 || currency1.balanceOf(address(this)) > balance1) {
            maintenancePaidCaller = true;
        }
        _recordMonotonicState();
    }

    function harvest() external {
        uint256 balance0 = currency0.balanceOf(address(this));
        uint256 balance1 = currency1.balanceOf(address(this));
        try hook.harvestPOLFees(key) {} catch {}
        if (currency0.balanceOf(address(this)) > balance0 || currency1.balanceOf(address(this)) > balance1) {
            maintenancePaidCaller = true;
        }
        _recordMonotonicState();
    }

    function _swap(bool zeroForOne, int256 amountSpecified) private {
        try router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) returns (
            BalanceDelta
        ) {}
            catch {}
        _recordMonotonicState();
    }

    function _recordMonotonicState() private {
        uint128 liquidity = hook.polLiquidity(poolId);
        uint256 receiver0 = currency0.balanceOf(feeReceiver);
        uint256 receiver1 = currency1.balanceOf(feeReceiver);
        if (liquidity < lastLiquidity) liquidityDecreased = true;
        if (receiver0 < lastReceiver0 || receiver1 < lastReceiver1) receiverBalanceDecreased = true;
        lastLiquidity = liquidity;
        lastReceiver0 = receiver0;
        lastReceiver1 = receiver1;
    }
}

contract LaunchLiquidityInvariantTest is StdInvariant, Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint160 private constant REQUIRED_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    address private feeReceiver = makeAddr("feeReceiver");
    StaticsLaunchLiquidityHook private hook;
    LaunchLiquidityHandler private handler;
    PoolKey private poolKey;
    PoolId private poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        hook = _deployHook();
        poolKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3_000, tickSpacing: 60, hooks: IHooks(hook)});
        poolId = hook.registerAndInitialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, "");

        handler = new LaunchLiquidityHandler(swapRouter, hook, poolKey, feeReceiver);
        MockERC20(Currency.unwrap(currency0)).mint(address(handler), 1_000_000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(handler), 1_000_000 ether);
        targetContract(address(handler));
    }

    function invariantPendingPOLIsFullySolvent() public view {
        _assertPending(currency0);
        _assertPending(currency1);
    }

    function invariantPermissionlessMaintenanceCannotDecreasePOLOrRevenue() public view {
        assertFalse(handler.liquidityDecreased(), "active POL liquidity decreased");
        assertFalse(handler.receiverBalanceDecreased(), "fee receiver balance decreased");
        assertFalse(handler.maintenancePaidCaller(), "permissionless maintenance paid caller");
    }

    function _assertPending(Currency currency) private view {
        uint256 pending = hook.pendingPOL(poolId, currency);
        assertEq(pending, hook.totalPendingPOL(currency));
        assertEq(currency.balanceOf(address(hook)), pending);
    }

    function _deployHook() private returns (StaticsLaunchLiquidityHook deployed) {
        bytes memory args = abi.encode(manager, address(this), feeReceiver, address(this), address(this));
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_FLAGS, type(StaticsLaunchLiquidityHook).creationCode, args);
        deployed = new StaticsLaunchLiquidityHook{salt: salt}(
            manager, address(this), feeReceiver, address(this), address(this)
        );
        assertEq(address(deployed), expected);
    }
}
