// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
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
import {StaticsLaunchFeeClaimRedeemer} from "../../src/liquidity/StaticsLaunchFeeClaimRedeemer.sol";
import {StaticsLaunchLiquidityHook} from "../../src/liquidity/StaticsLaunchLiquidityHook.sol";

contract LaunchLiquidityHandler is Test {
    using PoolIdLibrary for PoolKey;

    PoolSwapTest private immutable router;
    IPoolManager private immutable manager;
    StaticsLaunchLiquidityHook private immutable hook;
    StaticsLaunchFeeClaimRedeemer private immutable redeemer;
    Currency private immutable currency0;
    Currency private immutable currency1;
    address private immutable redemptionRecipient;
    PoolKey private primaryKey;
    PoolKey private secondaryKey;
    address[3] private receivers;

    mapping(PoolId poolId => uint16 fee) public expectedInputFee;
    mapping(PoolId poolId => uint16 fee) public expectedOutputFee;
    mapping(address receiver => mapping(Currency currency => uint256 amount)) public totalClaimsMinted;
    mapping(address receiver => mapping(Currency currency => uint256 amount)) public totalClaimsRedeemed;

    address public currentReceiver;
    bool public claimAccountingDecreased;
    bool public hookRetainedTokens;
    uint256 public successfulSwaps;
    uint256 public successfulRedemptions;
    uint256 public configurationChanges;
    uint256 public actionCalls;

    constructor(
        PoolSwapTest router_,
        IPoolManager manager_,
        StaticsLaunchLiquidityHook hook_,
        StaticsLaunchFeeClaimRedeemer redeemer_,
        PoolKey memory primaryKey_,
        PoolKey memory secondaryKey_,
        address[3] memory receivers_
    ) {
        router = router_;
        manager = manager_;
        hook = hook_;
        redeemer = redeemer_;
        primaryKey = primaryKey_;
        secondaryKey = secondaryKey_;
        currency0 = primaryKey_.currency0;
        currency1 = primaryKey_.currency1;
        receivers = receivers_;
        redemptionRecipient = address(0xA11CE);
        currentReceiver = receivers_[0];
        expectedInputFee[primaryKey_.toId()] = 25;
        expectedOutputFee[primaryKey_.toId()] = 75;
        expectedInputFee[secondaryKey_.toId()] = 100;
        expectedOutputFee[secondaryKey_.toId()] = 200;
        IERC20(Currency.unwrap(currency0)).approve(address(router_), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(router_), type(uint256).max);
    }

    function swapExactInput(bool useSecondary, bool zeroForOne, uint256 rawAmount) external {
        actionCalls++;
        _swap(useSecondary, zeroForOne, -int256(bound(rawAmount, 1_000, 0.00025 ether)));
    }

    function swapExactOutput(bool useSecondary, bool zeroForOne, uint256 rawAmount) external {
        actionCalls++;
        _swap(useSecondary, zeroForOne, int256(bound(rawAmount, 1_000, 0.0001 ether)));
    }

    function setFees(bool useSecondary, uint256 rawInputFee, uint256 rawOutputFee) external {
        actionCalls++;
        PoolId poolId = _key(useSecondary).toId();
        uint16 inputFee = uint16(bound(rawInputFee, 0, hook.MAX_HOOK_FEE_BPS()));
        uint16 outputFee = uint16(bound(rawOutputFee, 0, hook.MAX_HOOK_FEE_BPS()));
        hook.setHookFees(poolId, inputFee, outputFee);
        expectedInputFee[poolId] = inputFee;
        expectedOutputFee[poolId] = outputFee;
        configurationChanges++;
        _observe();
    }

    function rotateReceiver(uint256 rawIndex) external {
        actionCalls++;
        address next = receivers[bound(rawIndex, 0, receivers.length - 1)];
        hook.setFeeReceiver(next);
        currentReceiver = next;
        configurationChanges++;
        _observe();
    }

    function redeemClaims(uint256 rawReceiverIndex, bool useCurrency1, uint256 rawAmount) external {
        actionCalls++;
        address receiver = receivers[bound(rawReceiverIndex, 0, receivers.length - 1)];
        Currency currency = useCurrency1 ? currency1 : currency0;
        uint256 available = manager.balanceOf(receiver, currency.toId());
        if (available == 0) {
            _observe();
            return;
        }
        uint256 amount = bound(rawAmount, 1, available);
        uint256 recipientBefore = currency.balanceOf(redemptionRecipient);
        vm.prank(receiver);
        redeemer.redeem(currency, amount, redemptionRecipient);
        assertEq(currency.balanceOf(redemptionRecipient) - recipientBefore, amount);
        totalClaimsRedeemed[receiver][currency] += amount;
        successfulRedemptions++;
        _observe();
    }

    function receiverAt(uint256 index) external view returns (address) {
        return receivers[index];
    }

    function keyAt(bool secondary) external view returns (PoolKey memory) {
        return _key(secondary);
    }

    function _swap(bool useSecondary, bool zeroForOne, int256 amountSpecified) private {
        PoolKey memory selected = _key(useSecondary);
        try router.swap(
            selected,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) returns (
            BalanceDelta
        ) {
            successfulSwaps++;
        } catch {}
        _observe();
    }

    function _observe() private {
        for (uint256 i; i < receivers.length; ++i) {
            address receiver = receivers[i];
            uint256 balance0 = manager.balanceOf(receiver, currency0.toId());
            uint256 balance1 = manager.balanceOf(receiver, currency1.toId());
            _observeClaims(receiver, currency0, balance0);
            _observeClaims(receiver, currency1, balance1);
        }
        if (currency0.balanceOf(address(hook)) != 0 || currency1.balanceOf(address(hook)) != 0) {
            hookRetainedTokens = true;
        }
    }

    function _observeClaims(address receiver, Currency currency, uint256 outstanding) private {
        uint256 accounted = outstanding + totalClaimsRedeemed[receiver][currency];
        if (accounted < totalClaimsMinted[receiver][currency]) {
            claimAccountingDecreased = true;
        } else {
            totalClaimsMinted[receiver][currency] = accounted;
        }
    }

    function _key(bool secondary) private view returns (PoolKey memory) {
        return secondary ? secondaryKey : primaryKey;
    }
}

contract LaunchLiquidityInvariantTest is StdInvariant, Test, Deployers, DeployPermit2 {
    using PoolIdLibrary for PoolKey;

    uint160 private constant REQUIRED_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    address[3] private receivers = [makeAddr("receiverA"), makeAddr("receiverB"), makeAddr("receiverC")];
    StaticsLaunchLiquidityHook private hook;
    StaticsLaunchFeeClaimRedeemer private redeemer;
    LaunchLiquidityHandler private handler;
    PoolKey private primaryKey;
    PoolKey private secondaryKey;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        IAllowanceTransfer permit2 = IAllowanceTransfer(deployPermit2());
        PositionManager positionManager =
            new PositionManager(manager, permit2, 100_000, IPositionDescriptor(address(0)), IWETH9(address(0)));
        hook = _deployHook(IPositionManager(address(positionManager)));
        redeemer = new StaticsLaunchFeeClaimRedeemer(IPoolManager(manager));
        primaryKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3_000, tickSpacing: 60, hooks: IHooks(hook)});
        secondaryKey = primaryKey;
        secondaryKey.fee = 5_000;
        hook.registerPool(primaryKey, SQRT_PRICE_1_1, 25, 75, address(this));
        hook.registerPool(secondaryKey, SQRT_PRICE_1_1, 100, 200, address(this));
        positionManager.initializePool(primaryKey, SQRT_PRICE_1_1);
        positionManager.initializePool(secondaryKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(primaryKey, LIQUIDITY_PARAMS, "");
        modifyLiquidityRouter.modifyLiquidity(secondaryKey, LIQUIDITY_PARAMS, "");
        hook.activatePool(primaryKey.toId());
        hook.activatePool(secondaryKey.toId());

        for (uint256 i; i < receivers.length; ++i) {
            vm.prank(receivers[i]);
            manager.setOperator(address(redeemer), true);
        }

        handler = new LaunchLiquidityHandler(
            swapRouter, IPoolManager(manager), hook, redeemer, primaryKey, secondaryKey, receivers
        );
        hook.transferOwnership(address(handler));
        vm.prank(address(handler));
        hook.acceptOwnership();
        MockERC20(Currency.unwrap(currency0)).mint(address(handler), 1_000_000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(handler), 1_000_000 ether);
        targetContract(address(handler));
    }

    function invariantHookNeverCustodiesSwapFees() public view {
        assertEq(currency0.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);
        assertFalse(handler.hookRetainedTokens());
    }

    function invariantClaimsEqualMintedMinusRedeemed() public view {
        assertFalse(handler.claimAccountingDecreased());
        for (uint256 i; i < receivers.length; ++i) {
            address receiver = handler.receiverAt(i);
            assertEq(
                handler.totalClaimsMinted(receiver, currency0),
                manager.balanceOf(receiver, currency0.toId()) + handler.totalClaimsRedeemed(receiver, currency0)
            );
            assertEq(
                handler.totalClaimsMinted(receiver, currency1),
                manager.balanceOf(receiver, currency1.toId()) + handler.totalClaimsRedeemed(receiver, currency1)
            );
        }
    }

    function invariantCurrentReceiverMatchesGovernedState() public view {
        assertEq(hook.feeReceiver(), handler.currentReceiver());
    }

    function invariantRegisteredPoolConfigurationsRemainIsolated() public view {
        _assertRegistration(primaryKey, 3_000, 60);
        _assertRegistration(secondaryKey, 5_000, 60);
    }

    function afterInvariant() public view {
        assertGt(handler.actionCalls(), 0);
        assertGt(handler.successfulSwaps(), 0);
    }

    function _assertRegistration(PoolKey memory selected, uint24 nativeFee, int24 tickSpacing) private view {
        PoolId poolId = selected.toId();
        IStaticsLaunchLiquidityHook.PoolRegistration memory registration = hook.poolRegistration(poolId);
        assertTrue(registration.registered);
        assertEq(Currency.unwrap(registration.currency0), Currency.unwrap(selected.currency0));
        assertEq(Currency.unwrap(registration.currency1), Currency.unwrap(selected.currency1));
        assertEq(registration.nativeLpFee, nativeFee);
        assertEq(registration.tickSpacing, tickSpacing);
        assertEq(registration.expectedSqrtPriceX96, SQRT_PRICE_1_1);
        assertEq(registration.inputFeeBps, handler.expectedInputFee(poolId));
        assertEq(registration.outputFeeBps, handler.expectedOutputFee(poolId));
        assertLe(registration.inputFeeBps, hook.MAX_HOOK_FEE_BPS());
        assertLe(registration.outputFeeBps, hook.MAX_HOOK_FEE_BPS());
        assertTrue(registration.initialized);
        assertTrue(registration.active);
    }

    function _deployHook(IPositionManager positionManager_) private returns (StaticsLaunchLiquidityHook deployed) {
        bytes memory args = abi.encode(manager, positionManager_, address(this), receivers[0]);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_FLAGS, type(StaticsLaunchLiquidityHook).creationCode, args);
        deployed = new StaticsLaunchLiquidityHook{salt: salt}(manager, positionManager_, address(this), receivers[0]);
        assertEq(address(deployed), expected);
    }
}
