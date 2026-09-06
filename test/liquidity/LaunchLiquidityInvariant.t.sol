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
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IStaticsLaunchLiquidityHook} from "../../src/interfaces/IStaticsLaunchLiquidityHook.sol";
import {StaticsLaunchLiquidityHook} from "../../src/liquidity/StaticsLaunchLiquidityHook.sol";

contract LaunchLiquidityHandler is Test {
    PoolSwapTest private immutable router;
    StaticsLaunchLiquidityHook private immutable hook;
    Currency private immutable currency0;
    Currency private immutable currency1;
    address private immutable feeReceiver;
    PoolKey private key;

    uint256 public lastReceiver0;
    uint256 public lastReceiver1;
    bool public receiverBalanceDecreased;
    bool public hookRetainedTokens;

    constructor(PoolSwapTest router_, StaticsLaunchLiquidityHook hook_, PoolKey memory key_, address feeReceiver_) {
        router = router_;
        hook = hook_;
        key = key_;
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
        uint256 receiver0 = currency0.balanceOf(feeReceiver);
        uint256 receiver1 = currency1.balanceOf(feeReceiver);
        if (receiver0 < lastReceiver0 || receiver1 < lastReceiver1) receiverBalanceDecreased = true;
        if (currency0.balanceOf(address(hook)) != 0 || currency1.balanceOf(address(hook)) != 0) {
            hookRetainedTokens = true;
        }
        lastReceiver0 = receiver0;
        lastReceiver1 = receiver1;
    }
}

contract LaunchLiquidityInvariantTest is StdInvariant, Test, Deployers, DeployPermit2 {
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
        IAllowanceTransfer permit2 = IAllowanceTransfer(deployPermit2());
        PositionManager positionManager =
            new PositionManager(manager, permit2, 100_000, IPositionDescriptor(address(0)), IWETH9(address(0)));
        hook = _deployHook(IPositionManager(address(positionManager)));
        poolKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3_000, tickSpacing: 60, hooks: IHooks(hook)});
        poolId = hook.registerPool(poolKey, SQRT_PRICE_1_1, 25, 75);
        positionManager.initializePool(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, "");

        handler = new LaunchLiquidityHandler(swapRouter, hook, poolKey, feeReceiver);
        MockERC20(Currency.unwrap(currency0)).mint(address(handler), 1_000_000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(handler), 1_000_000 ether);
        targetContract(address(handler));
    }

    function invariantHookNeverCustodiesSwapFees() public view {
        assertEq(currency0.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);
        assertFalse(handler.hookRetainedTokens());
    }

    function invariantFeeReceiverBalancesNeverDecrease() public view {
        assertFalse(handler.receiverBalanceDecreased());
    }

    function invariantRegisteredPoolConfigurationIsIsolated() public view {
        IStaticsLaunchLiquidityHook.PoolRegistration memory registration = hook.poolRegistration(poolId);
        assertTrue(registration.registered);
        assertEq(registration.nativeLpFee, 3_000);
        assertEq(registration.tickSpacing, 60);
        assertEq(registration.expectedSqrtPriceX96, SQRT_PRICE_1_1);
        assertEq(registration.inputFeeBps, 25);
        assertEq(registration.outputFeeBps, 75);
    }

    function _deployHook(IPositionManager positionManager_) private returns (StaticsLaunchLiquidityHook deployed) {
        bytes memory args = abi.encode(manager, positionManager_, address(this), feeReceiver);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_FLAGS, type(StaticsLaunchLiquidityHook).creationCode, args);
        deployed = new StaticsLaunchLiquidityHook{salt: salt}(manager, positionManager_, address(this), feeReceiver);
        assertEq(address(deployed), expected);
    }
}
