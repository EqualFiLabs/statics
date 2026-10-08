// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {StaticsSwapFeeHook} from "../../src/liquidity/StaticsSwapFeeHook.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {RangeGaugeLifecycleTestBase} from "../helpers/RangeGaugeLifecycleTestBase.sol";
import {CanonicalV4Router} from "../helpers/CanonicalPoolTestBase.sol";

contract PolCallbackToken is MockERC20 {
    address private triggerSender;
    address private callbackTarget;
    bytes private callbackData;
    bool private onApproval;
    bool private armed;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    bytes public callbackResult;

    constructor() MockERC20("POL Callback", "POLCALL", 18) {}

    function armTransfer(address sender, address target, bytes calldata data) external {
        _arm(sender, target, data, false);
    }

    function armApproval(address sender, address target, bytes calldata data) external {
        _arm(sender, target, data, true);
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        if (armed && onApproval && msg.sender == triggerSender) _runCallback();
        return super.approve(spender, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (armed && !onApproval && from == triggerSender && to != address(0)) _runCallback();
    }

    function _arm(address sender, address target, bytes calldata data, bool approval) private {
        triggerSender = sender;
        callbackTarget = target;
        callbackData = data;
        onApproval = approval;
        armed = true;
        callbackAttempted = false;
        callbackSucceeded = false;
        delete callbackResult;
    }

    function _runCallback() private {
        armed = false;
        callbackAttempted = true;
        (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
    }
}

contract PolCallbackSwap {
    CanonicalV4Router private immutable router;
    PoolKey private key;

    constructor(CanonicalV4Router router_, PoolKey memory key_) {
        router = router_;
        key = key_;
    }

    receive() external payable {}

    function perform() external {
        router.swap{value: 0.1 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(0.1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );
    }
}

/// @notice Real v4 pool, PositionManager NFT, hook, and POL custody with callback-capable ERC-20.
contract ProtocolPolSwapGuardTest is RangeGaugeLifecycleTestBase {
    using PoolIdLibrary for PoolKey;

    IStaticsProtocolPools private pools;
    PolCallbackToken private token;
    PolCallbackSwap private swapper;
    PoolId private poolId;
    PoolKey private key;

    function setUp() public override {
        super.setUp();
        pools = IStaticsProtocolPools(address(diamond));
        token = new PolCallbackToken();
        poolId = _createRangeGaugePool(alice, address(0), address(token));
        key = pools.protocolPool(poolId).key;
        swapper = new PolCallbackSwap(v4Router, key);
        vm.deal(address(swapper), 1 ether);
        vm.deal(alice, 1_000 ether);
        pools.setProtocolPolOperator(address(this));
    }

    function testFundingTransferCallbackCannotReclassifyNativeLpFee() public {
        uint256 positionId = _seedPol();
        IStaticsProtocolPools.ProtocolPolLiquidityParams memory params = _increaseParams(positionId);
        uint256 snapshot = vm.snapshotState();

        pools.increaseProtocolPolPosition(params);
        uint256 expectedReserve = _nativeReserve();
        uint256 expectedTreasury = globalRewards.treasuryAccrued(address(wrappedNative));
        assertTrue(vm.revertToState(snapshot));

        token.armTransfer(address(diamond), address(swapper), abi.encodeCall(PolCallbackSwap.perform, ()));
        pools.increaseProtocolPolPosition(params);
        _assertCallbackBlocked();
        assertEq(_nativeReserve(), expectedReserve);
        assertEq(globalRewards.treasuryAccrued(address(wrappedNative)), expectedTreasury);
        assertEq(custody.globalReservedByToken(address(0)), address(diamond).balance);

        swapper.perform();
        pools.collectProtocolPolFees(positionId, block.timestamp + 1 hours);
        assertGt(globalRewards.treasuryAccrued(address(wrappedNative)), expectedTreasury);
    }

    function testManagerApprovalCallbackCannotReclassifyNativeLpFee() public {
        uint256 positionId = _seedPol();
        IStaticsProtocolPools.ProtocolPolLiquidityParams memory params = _increaseParams(positionId);
        uint256 snapshot = vm.snapshotState();

        pools.increaseProtocolPolPosition(params);
        uint256 expectedReserve = _nativeReserve();
        uint256 expectedTreasury = globalRewards.treasuryAccrued(address(wrappedNative));
        assertTrue(vm.revertToState(snapshot));

        token.armApproval(address(rangeLiquidityManager), address(swapper), abi.encodeCall(PolCallbackSwap.perform, ()));
        pools.increaseProtocolPolPosition(params);
        _assertCallbackBlocked();
        assertEq(_nativeReserve(), expectedReserve);
        assertEq(globalRewards.treasuryAccrued(address(wrappedNative)), expectedTreasury);
    }

    function testFeePayoutCallbackCannotReclassifyDecrease() public {
        uint256 positionId = _seedPol();
        _swap(false, 0.2 ether);
        uint256 treasuryBefore = globalRewards.treasuryAccrued(address(token));
        token.armTransfer(address(rangeLiquidityManager), address(swapper), abi.encodeCall(PolCallbackSwap.perform, ()));

        pools.decreaseProtocolPolPosition(
            IStaticsProtocolPools.ProtocolPolLiquidityParams(positionId, 1e13, 0, 0, block.timestamp + 1 hours)
        );
        _assertCallbackBlocked();
        assertGt(globalRewards.treasuryAccrued(address(token)), treasuryBefore);
        assertEq(custody.globalReservedByToken(address(0)), address(diamond).balance);
    }

    function testFeePayoutCallbackCannotReclassifyClose() public {
        uint256 positionId = _seedPol();
        _swap(false, 0.2 ether);
        uint256 treasuryBefore = globalRewards.treasuryAccrued(address(token));
        token.armTransfer(address(rangeLiquidityManager), address(swapper), abi.encodeCall(PolCallbackSwap.perform, ()));

        pools.closeProtocolPolPosition(positionId, 0, 0, block.timestamp + 1 hours);
        _assertCallbackBlocked();
        assertFalse(pools.protocolPolPosition(positionId).active);
        assertGt(globalRewards.treasuryAccrued(address(token)), treasuryBefore);
        assertEq(custody.globalReservedByToken(address(0)), address(diamond).balance);
    }

    function testRebalanceKeepsSamePoolSwapsBlockedAcrossItsLegs() public {
        uint256 positionId = _seedPol();
        _swap(false, 0.2 ether);
        token.armTransfer(address(rangeLiquidityManager), address(swapper), abi.encodeCall(PolCallbackSwap.perform, ()));

        IStaticsProtocolPools.ProtocolPolCloseLeg[] memory closes = new IStaticsProtocolPools.ProtocolPolCloseLeg[](1);
        closes[0] = IStaticsProtocolPools.ProtocolPolCloseLeg(positionId, 0, 0);
        IStaticsProtocolPools.ProtocolPolOpenLeg[] memory opens = new IStaticsProtocolPools.ProtocolPolOpenLeg[](1);
        opens[0] = IStaticsProtocolPools.ProtocolPolOpenLeg(-600, 600, 1e13, 1e14, 1e14);
        uint256[] memory replacements = pools.rebalanceProtocolPolPositions(
            IStaticsProtocolPools.ProtocolPolRebalanceParams(
                poolId, closes, opens, 1e14, 1e14, block.timestamp + 1 hours
            )
        );

        _assertCallbackBlocked();
        assertFalse(pools.protocolPolPosition(positionId).active);
        assertTrue(pools.protocolPolPosition(replacements[0]).active);
        assertEq(custody.globalReservedByToken(address(0)), address(diamond).balance);
    }

    function testRevertingPolMutationDoesNotLeaveTransientSwapBlock() public {
        uint256 positionId = _seedPol();
        vm.expectRevert();
        pools.increaseProtocolPolPosition(
            IStaticsProtocolPools.ProtocolPolLiquidityParams(positionId, 1e14, 0, 0, block.timestamp + 1 hours)
        );
        assertFalse(governance.protocolPoolSwapsBlocked(poolId));
        swapper.perform();
    }

    function testOtherPoolCanSwapDuringPolMutation() public {
        uint256 positionId = _seedPol();
        PoolId other = _createRangeGaugePool(alice, address(0), address(assetA));
        _provide(_createPosition(alice), other, alice);
        PolCallbackSwap otherSwapper = new PolCallbackSwap(v4Router, pools.protocolPool(other).key);
        vm.deal(address(otherSwapper), 1 ether);
        token.armTransfer(address(diamond), address(otherSwapper), abi.encodeCall(PolCallbackSwap.perform, ()));

        pools.increaseProtocolPolPosition(_increaseParams(positionId));
        assertTrue(token.callbackAttempted());
        assertTrue(token.callbackSucceeded());
        assertFalse(governance.protocolPoolSwapsBlocked(poolId));
        assertFalse(governance.protocolPoolSwapsBlocked(other));
    }

    function _assertCallbackBlocked() private view {
        assertTrue(token.callbackAttempted());
        assertFalse(token.callbackSucceeded());
        bytes memory reason = token.callbackResult();
        assertGe(reason.length, 200);
        bytes4 wrapper;
        bytes4 cause;
        assembly ("memory-safe") {
            wrapper := mload(add(reason, 32))
            cause := mload(add(reason, 196))
        }
        assertEq(wrapper, CustomRevert.WrappedError.selector);
        assertEq(cause, StaticsSwapFeeHook.SwapsQuarantined.selector);
        assertFalse(governance.protocolPoolSwapsBlocked(poolId));
    }

    function _seedPol() private returns (uint256 positionId) {
        _provide(_createPosition(alice), poolId, alice);
        vm.prank(alice);
        pools.activateProtocolPoolPol(poolId);
        _swap(true, 0.2 ether);
        _swap(false, 0.2 ether);
        pools.settleProtocolPoolPol(poolId, address(0), 0);
        pools.settleProtocolPoolPol(poolId, address(token), 0);
        positionId = pools.openProtocolPolPosition(
            IStaticsProtocolPools.ProtocolPolOpenParams(
                poolId, -600, 600, 1e14, _nativeReserve(), _tokenReserve(), block.timestamp + 1 hours
            )
        );
    }

    function _increaseParams(uint256 positionId)
        private
        view
        returns (IStaticsProtocolPools.ProtocolPolLiquidityParams memory)
    {
        return IStaticsProtocolPools.ProtocolPolLiquidityParams(
            positionId, 1e14, _nativeReserve(), _tokenReserve(), block.timestamp + 1 hours
        );
    }

    function _swap(bool zeroForOne, uint256 amount) private {
        if (!zeroForOne) {
            token.mint(alice, amount);
            _approveV4Router(alice, address(token));
        }
        vm.prank(alice);
        v4Router.swap{value: zeroForOne ? amount : 0}(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    function _nativeReserve() private view returns (uint256) {
        return custody.reservedByAccount(custody.protocolPolCustodyAccount(PoolId.unwrap(poolId)), address(0));
    }

    function _tokenReserve() private view returns (uint256) {
        return custody.reservedByAccount(custody.protocolPolCustodyAccount(PoolId.unwrap(poolId)), address(token));
    }
}
