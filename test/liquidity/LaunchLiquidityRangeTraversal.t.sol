// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
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
import {LiquidityOperations} from "@uniswap/v4-periphery/test/shared/LiquidityOperations.sol";
import {PositionConfig} from "@uniswap/v4-periphery/test/shared/PositionConfig.sol";
import {StaticsLaunchLiquidityHook} from "../../src/liquidity/StaticsLaunchLiquidityHook.sol";

/// @notice Exercises full-fill boundaries while swaps traverse independently owned concentrated positions.
contract LaunchLiquidityRangeTraversalTest is Test, Deployers, DeployPermit2, LiquidityOperations {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 private constant REQUIRED_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint256 private constant SEARCH_CEILING = 1 ether;
    uint128 private constant BROAD_LIQUIDITY = 1e18;
    uint128 private constant NARROW_LIQUIDITY = 7e17;
    uint128 private constant SIDE_LIQUIDITY = 5e17;

    address private feeReceiver = makeAddr("rangeTraversalReceiver");
    address private firstOwner = makeAddr("rangeTraversalFirstOwner");
    address private secondOwner = makeAddr("rangeTraversalSecondOwner");
    IAllowanceTransfer private permit2;
    PositionManager private positionManager;
    StaticsLaunchLiquidityHook private hook;
    PoolId private poolId;
    uint256[4] private tokenIds;

    struct ObservableState {
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 activeLiquidity;
        uint256 feeGrowth0;
        uint256 feeGrowth1;
        uint256 receiverClaim0;
        uint256 receiverClaim1;
        uint256 userBalance0;
        uint256 userBalance1;
        uint256 managerBalance0;
        uint256 managerBalance1;
        uint128 position0Liquidity;
        uint128 position1Liquidity;
        uint128 position2Liquidity;
        uint128 position3Liquidity;
    }

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        permit2 = IAllowanceTransfer(deployPermit2());
        positionManager =
            new PositionManager(manager, permit2, 100_000, IPositionDescriptor(address(0)), IWETH9(address(0)));
        lpm = IPositionManager(address(positionManager));
        hook = _deployHook();
        key = PoolKey({currency0: currency0, currency1: currency1, fee: 3_000, tickSpacing: 60, hooks: IHooks(hook)});
        poolId = hook.registerPool(key, SQRT_PRICE_1_1, 35, 80, firstOwner);
        positionManager.initializePool(key, SQRT_PRICE_1_1);
        _approvePositionManager(currency0);
        _approvePositionManager(currency1);
        _mintTraversalPositions();
        vm.prank(firstOwner);
        hook.activatePool(poolId);
    }

    function testExactInputZeroForOneStopsAtExactCapacityAndRollsBackOverflow() public {
        _assertExactCapacity(true, true);
    }

    function testExactInputOneForZeroStopsAtExactCapacityAndRollsBackOverflow() public {
        _assertExactCapacity(false, true);
    }

    function testExactOutputZeroForOneStopsAtExactCapacityAndRollsBackOverflow() public {
        _assertExactCapacity(true, false);
    }

    function testExactOutputOneForZeroStopsAtExactCapacityAndRollsBackOverflow() public {
        _assertExactCapacity(false, false);
    }

    function _assertExactCapacity(bool zeroForOne, bool exactInput) private {
        assertTrue(_canSwap(zeroForOne, exactInput, 1));
        assertFalse(_canSwap(zeroForOne, exactInput, SEARCH_CEILING));
        uint256 maximum = _findMaximum(zeroForOne, exactInput);
        assertGt(maximum, 1);
        assertFalse(_canSwap(zeroForOne, exactInput, maximum + 1));

        ObservableState memory beforeOverflow = _observableState();
        vm.expectRevert();
        _executeSwap(zeroForOne, exactInput, maximum + 1);
        _assertStateEquals(_observableState(), beforeOverflow);
        _assertNftOwnership();

        uint256 claimsBefore = beforeOverflow.receiverClaim0 + beforeOverflow.receiverClaim1;
        _executeSwap(zeroForOne, exactInput, maximum);
        ObservableState memory afterMaximum = _observableState();
        assertTrue(afterMaximum.tick != beforeOverflow.tick);
        assertGt(afterMaximum.receiverClaim0 + afterMaximum.receiverClaim1, claimsBefore);
        assertEq(currency0.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);
        _assertNftOwnership();
    }

    function _findMaximum(bool zeroForOne, bool exactInput) private returns (uint256 maximum) {
        uint256 low = 1;
        uint256 high = SEARCH_CEILING;
        while (low + 1 < high) {
            uint256 middle = low + (high - low) / 2;
            if (_canSwap(zeroForOne, exactInput, middle)) {
                low = middle;
            } else {
                high = middle;
            }
        }
        return low;
    }

    function _canSwap(bool zeroForOne, bool exactInput, uint256 amount) private returns (bool succeeded) {
        uint256 state = vm.snapshotState();
        try this.executeSwap(zeroForOne, exactInput, amount) returns (BalanceDelta) {
            succeeded = true;
        } catch {
            succeeded = false;
        }
        assertTrue(vm.revertToState(state));
    }

    function executeSwap(bool zeroForOne, bool exactInput, uint256 amount) external returns (BalanceDelta delta) {
        require(msg.sender == address(this));
        return _executeSwap(zeroForOne, exactInput, amount);
    }

    function _executeSwap(bool zeroForOne, bool exactInput, uint256 amount) private returns (BalanceDelta delta) {
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactInput ? -int256(amount) : int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function _mintTraversalPositions() private {
        tokenIds[0] = lpm.nextTokenId();
        mint(_config(-600, 600), BROAD_LIQUIDITY, firstOwner, ZERO_BYTES);
        tokenIds[1] = lpm.nextTokenId();
        mint(_config(-120, 120), NARROW_LIQUIDITY, secondOwner, ZERO_BYTES);
        tokenIds[2] = lpm.nextTokenId();
        mint(_config(60, 600), SIDE_LIQUIDITY, firstOwner, ZERO_BYTES);
        tokenIds[3] = lpm.nextTokenId();
        mint(_config(-600, -60), SIDE_LIQUIDITY, secondOwner, ZERO_BYTES);
    }

    function _config(int24 tickLower, int24 tickUpper) private view returns (PositionConfig memory) {
        return PositionConfig({poolKey: key, tickLower: tickLower, tickUpper: tickUpper});
    }

    function _observableState() private view returns (ObservableState memory observed) {
        (observed.sqrtPriceX96, observed.tick,,) = manager.getSlot0(poolId);
        observed.activeLiquidity = manager.getLiquidity(poolId);
        (observed.feeGrowth0, observed.feeGrowth1) = manager.getFeeGrowthGlobals(poolId);
        observed.receiverClaim0 = manager.balanceOf(feeReceiver, currency0.toId());
        observed.receiverClaim1 = manager.balanceOf(feeReceiver, currency1.toId());
        observed.userBalance0 = currency0.balanceOfSelf();
        observed.userBalance1 = currency1.balanceOfSelf();
        observed.managerBalance0 = currency0.balanceOf(address(manager));
        observed.managerBalance1 = currency1.balanceOf(address(manager));
        observed.position0Liquidity = lpm.getPositionLiquidity(tokenIds[0]);
        observed.position1Liquidity = lpm.getPositionLiquidity(tokenIds[1]);
        observed.position2Liquidity = lpm.getPositionLiquidity(tokenIds[2]);
        observed.position3Liquidity = lpm.getPositionLiquidity(tokenIds[3]);
    }

    function _assertStateEquals(ObservableState memory actual, ObservableState memory expected) private pure {
        assertEq(actual.sqrtPriceX96, expected.sqrtPriceX96);
        assertEq(actual.tick, expected.tick);
        assertEq(actual.activeLiquidity, expected.activeLiquidity);
        assertEq(actual.feeGrowth0, expected.feeGrowth0);
        assertEq(actual.feeGrowth1, expected.feeGrowth1);
        assertEq(actual.receiverClaim0, expected.receiverClaim0);
        assertEq(actual.receiverClaim1, expected.receiverClaim1);
        assertEq(actual.userBalance0, expected.userBalance0);
        assertEq(actual.userBalance1, expected.userBalance1);
        assertEq(actual.managerBalance0, expected.managerBalance0);
        assertEq(actual.managerBalance1, expected.managerBalance1);
        assertEq(actual.position0Liquidity, expected.position0Liquidity);
        assertEq(actual.position1Liquidity, expected.position1Liquidity);
        assertEq(actual.position2Liquidity, expected.position2Liquidity);
        assertEq(actual.position3Liquidity, expected.position3Liquidity);
    }

    function _assertNftOwnership() private view {
        assertEq(positionManager.ownerOf(tokenIds[0]), firstOwner);
        assertEq(positionManager.ownerOf(tokenIds[1]), secondOwner);
        assertEq(positionManager.ownerOf(tokenIds[2]), firstOwner);
        assertEq(positionManager.ownerOf(tokenIds[3]), secondOwner);
    }

    function _approvePositionManager(Currency currency) private {
        address token = Currency.unwrap(currency);
        IERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, address(lpm), type(uint160).max, type(uint48).max);
    }

    function _deployHook() private returns (StaticsLaunchLiquidityHook deployed) {
        IPositionManager positionManager_ = IPositionManager(address(positionManager));
        bytes memory args = abi.encode(manager, positionManager_, address(this), feeReceiver);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_FLAGS, type(StaticsLaunchLiquidityHook).creationCode, args);
        deployed = new StaticsLaunchLiquidityHook{salt: salt}(
            IPoolManager(manager), positionManager_, address(this), feeReceiver
        );
        assertEq(address(deployed), expected);
    }
}
