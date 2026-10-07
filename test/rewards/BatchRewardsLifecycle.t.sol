// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Vm} from "forge-std/Vm.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BatchRewardsFlowTestBase} from "../helpers/BatchRewardsFlowTestBase.sol";
import {IStaticsBatchRewards} from "../../src/interfaces/IStaticsBatchRewards.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsGaugeIncentives} from "../../src/interfaces/IStaticsGaugeIncentives.sol";
import {BatchRewardsFacet} from "../../src/facets/BatchRewardsFacet.sol";
import {GlobalRewardsFacet} from "../../src/facets/GlobalRewardsFacet.sol";
import {LibPosition} from "../../src/position/LibPosition.sol";
import {LibGaugeRouting} from "../../src/libraries/LibGaugeRouting.sol";
import {MockERC20, MockFeeOnTransferERC20, MockRevertingERC20, MockReentrantERC20} from "../mocks/MockERC20.sol";

contract BatchRewardsLifecycleTest is BatchRewardsFlowTestBase {
    PoolId internal firstPool;
    PoolId internal secondPool;
    uint256 internal firstId;
    uint256 internal secondId;
    MockERC20 internal reward;
    MockERC20 internal third;

    function setUp() public virtual override {
        super.setUp();
        _installBatch();
    }

    function _mixedState() internal {
        firstPool = _createRangeGaugePool(alice);
        third = new MockERC20("Third", "THIRD", 18);
        secondPool = _createRangeGaugePool(alice, address(assetA), address(third));
        firstId = _stake(alice, _assets());
        secondId = _stake(alice, _assets());
        _provide(firstId, firstPool, alice);
        _provide(secondId, secondPool, alice);
        _allocate(firstId, firstPool);
        _allocate(secondId, secondPool);
        reward = new MockERC20("Reward", "RWD", 18);
        _bribe(firstPool, reward, 5_000);
        _bribe(secondPool, reward, 5_000);
        _activateReserve();
        vm.warp(block.timestamp + 3.5 days);
        _swaps(firstPool);
        _swaps(secondPool);
    }

    function _assets() internal view returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = address(assetA);
        assets[1] = address(assetB);
    }

    function _swaps(PoolId pool) internal {
        PoolKey memory key = _poolKey(pool);
        _fundAndApprovePoolAssets(key, bob, 1 ether);
        _approveV4Router(bob, Currency.unwrap(key.currency0));
        _approveV4Router(bob, Currency.unwrap(key.currency1));
        vm.startPrank(bob);
        v4Router.swap(key, SwapParams(true, -int256(0.02 ether), TickMath.MIN_SQRT_PRICE + 1));
        v4Router.swap(key, SwapParams(false, -int256(0.02 ether), TickMath.MAX_SQRT_PRICE - 1));
        vm.stopPrank();
    }

    function _globals() internal view returns (IStaticsBatchRewards.GlobalClaim[] memory claims) {
        claims = new IStaticsBatchRewards.GlobalClaim[](2);
        claims[0] = IStaticsBatchRewards.GlobalClaim(firstId, _assets(), new uint256[](2));
        claims[1] = IStaticsBatchRewards.GlobalClaim(secondId, _assets(), new uint256[](2));
    }

    function _pools(bool allocator) internal view returns (IStaticsBatchRewards.PoolClaim[] memory claims) {
        claims = new IStaticsBatchRewards.PoolClaim[](2);
        uint8[] memory slots = _slots(1, !allocator);
        claims[0] =
            IStaticsBatchRewards.PoolClaim(firstId, PoolId.unwrap(firstPool), slots, new uint256[](slots.length));
        claims[1] =
            IStaticsBatchRewards.PoolClaim(secondId, PoolId.unwrap(secondPool), slots, new uint256[](slots.length));
    }

    function _individual() internal returns (bytes memory result) {
        IStaticsBatchRewards.GlobalClaim[] memory g = _globals();
        IStaticsBatchRewards.PoolClaim[] memory l = _pools(false);
        IStaticsBatchRewards.PoolClaim[] memory a = _pools(true);
        uint256[][] memory gr = new uint256[][](2);
        uint256[][] memory lr = new uint256[][](2);
        uint256[][] memory ar = new uint256[][](2);
        vm.startPrank(alice);
        for (uint256 i; i < 2; ++i) {
            gr[i] = globalRewards.claimRewards(g[i].positionId, g[i].assets, bob, g[i].minimumAmounts);
        }
        for (uint256 i; i < 2; ++i) {
            lr[i] = rangeGauge.claimLpRewards(
                l[i].positionId, PoolId.wrap(l[i].poolId), l[i].slots, l[i].minimumAmounts, bob
            );
        }
        for (uint256 i; i < 2; ++i) {
            ar[i] = incentives.claimGaugeAllocatorRewards(
                a[i].positionId, PoolId.wrap(a[i].poolId), a[i].slots, a[i].minimumAmounts, bob
            );
        }
        vm.stopPrank();
        result = abi.encode(gr, lr, ar);
    }

    function _mixedBatch() internal returns (bytes memory result) {
        IStaticsBatchRewards.GlobalClaim[] memory g = _globals();
        IStaticsBatchRewards.PoolClaim[] memory l = _pools(false);
        IStaticsBatchRewards.PoolClaim[] memory a = _pools(true);
        vm.prank(alice);
        (uint256[][] memory gr, uint256[][] memory lr, uint256[][] memory ar) = batch.batchClaimRewards(g, l, a, bob);
        for (uint256 i; i < 2; ++i) {
            assertGt(gr[i][0], 0);
            assertGt(gr[i][1], 0);
            assertGt(lr[i][0], 0);
            assertGt(lr[i][1], 0);
            assertGt(ar[i][0], 0);
        }
        result = abi.encode(gr, lr, ar);
    }

    function _accountingHash() internal view returns (bytes32) {
        bytes32 reserve = keccak256(abi.encode(incentives.gaugeReserve()));
        bytes32 streams = keccak256(
            abi.encode(
                rangeGauge.poolRewardStream(firstPool, 0),
                rangeGauge.poolRewardStream(firstPool, 1),
                rangeGauge.poolRewardStream(secondPool, 0),
                rangeGauge.poolRewardStream(secondPool, 1),
                incentives.gaugeAllocatorReward(firstPool, 1),
                incentives.gaugeAllocatorReward(secondPool, 1)
            )
        );
        bytes32 globals = keccak256(
            abi.encode(
                globalRewards.rewardAsset(address(assetA)),
                globalRewards.rewardAsset(address(assetB)),
                globalRewards.unfundedSwapRewards(address(assetA)),
                globalRewards.unfundedSwapRewards(address(assetB))
            )
        );
        return keccak256(
            abi.encode(
                reserve,
                streams,
                globals,
                _tokenState(stakingAsset),
                _tokenState(reward),
                _tokenState(assetA),
                _tokenState(assetB),
                _tokenState(third)
            )
        );
    }

    function _tokenState(MockERC20 token) internal view returns (bytes32) {
        uint256 physical = token.balanceOf(address(diamond));
        uint256 reserved = custody.globalReservedByToken(address(token));
        assertGe(physical, reserved, "custody backing");
        return keccak256(abi.encode(physical, reserved, token.balanceOf(bob), token.balanceOf(alice)));
    }

    function testBatchMatchesIndividualsIncludingAccountingAndEvents() public {
        _mixedState();
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        bytes memory expected = _individual();
        Vm.Log[] memory individualLogs = vm.getRecordedLogs();
        bytes32 expectedState = _accountingHash();
        assertTrue(vm.revertToStateAndDelete(snapshot));
        vm.recordLogs();
        uint256 beforeGas = gasleft();
        assertEq(_mixedBatch(), expected);
        Vm.Log[] memory batchLogs = vm.getRecordedLogs();
        emit log_named_uint("mixed 6 groups / 10 entries gas", beforeGas - gasleft());
        assertEq(_accountingHash(), expectedState);
        assertEq(batchLogs.length, individualLogs.length);
        uint256 claims;
        for (uint256 i; i < batchLogs.length; ++i) {
            assertEq(abi.encode(batchLogs[i]), abi.encode(individualLogs[i]));
            bytes32 topic = batchLogs[i].topics[0];
            if (
                topic == IStaticsGlobalRewards.RewardClaimed.selector
                    || topic == IStaticsRangeGauge.LpRewardsClaimed.selector
                    || topic == IStaticsGaugeIncentives.GaugeAllocatorRewardClaimed.selector
            ) ++claims;
        }
        assertEq(claims, 10, "distinct claim logs at separate receipt indexes");
    }

    function testApprovedCallerAndTransferredNftAuthorization() public {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _createPosition(alice);
        _provide(id, pool, alice);
        MockERC20 token = new MockERC20("Reward", "RWD", 18);
        uint8 slot = _bribe(pool, token, 0);
        vm.warp(block.timestamp + 1 days);
        IStaticsBatchRewards.PoolClaim[] memory claims = _poolClaims(id, pool, _slots(slot, false));
        vm.prank(bob);
        vm.expectPartialRevert(LibPosition.NotPositionOwnerOrApproved.selector);
        batch.batchClaimRewards(
            new IStaticsBatchRewards.GlobalClaim[](0), claims, new IStaticsBatchRewards.PoolClaim[](0), bob
        );
        vm.prank(alice);
        IERC721(address(diamond)).approve(bob, id);
        vm.prank(bob);
        (, uint256[][] memory received,) = batch.batchClaimRewards(
            new IStaticsBatchRewards.GlobalClaim[](0), claims, new IStaticsBatchRewards.PoolClaim[](0), bob
        );
        assertGt(received[0][0], 0);
        vm.prank(alice);
        IERC721(address(diamond)).transferFrom(alice, bob, id);
        vm.prank(alice);
        vm.expectPartialRevert(LibPosition.NotPositionOwnerOrApproved.selector);
        batch.batchClaimRewards(
            new IStaticsBatchRewards.GlobalClaim[](0), claims, new IStaticsBatchRewards.PoolClaim[](0), alice
        );
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        (, received,) = batch.batchClaimRewards(
            new IStaticsBatchRewards.GlobalClaim[](0), claims, new IStaticsBatchRewards.PoolClaim[](0), bob
        );
        assertGt(received[0][0], 0);
    }

    function testLateMinimumFailureRollsBackAllRewardBooksAndTransfers() public {
        _mixedState();
        bytes32 beforeState = _accountingHash();
        IStaticsBatchRewards.PoolClaim[] memory a = _pools(true);
        a[1].minimumAmounts[0] = type(uint256).max;
        IStaticsBatchRewards.GlobalClaim[] memory g = _globals();
        IStaticsBatchRewards.PoolClaim[] memory l = _pools(false);
        vm.prank(alice);
        vm.expectPartialRevert(IStaticsGaugeIncentives.GaugeAllocatorAmountBelowMinimum.selector);
        batch.batchClaimRewards(g, l, a, bob);
        assertEq(_accountingHash(), beforeState);
        _mixedBatch();
    }

    function testApprovedOperatorCanClaimAllCategoriesForMultipleNfts() public {
        _mixedState();
        IStaticsBatchRewards.GlobalClaim[] memory g = _globals();
        IStaticsBatchRewards.PoolClaim[] memory l = _pools(false);
        IStaticsBatchRewards.PoolClaim[] memory a = _pools(true);
        vm.prank(alice);
        IERC721(address(diamond)).setApprovalForAll(bob, true);
        vm.prank(bob);
        (uint256[][] memory gr, uint256[][] memory lr, uint256[][] memory ar) = batch.batchClaimRewards(g, l, a, bob);
        assertGt(gr[1][0], 0);
        assertGt(lr[1][0], 0);
        assertGt(ar[1][0], 0);
    }

    function testTransferredGlobalNftLateInBatchRollsBackEarlierClaims() public {
        _mixedState();
        vm.prank(alice);
        IERC721(address(diamond)).transferFrom(alice, bob, secondId);
        bytes32 beforeState = _accountingHash();
        IStaticsBatchRewards.GlobalClaim[] memory g = _globals();
        IStaticsBatchRewards.PoolClaim[] memory l = _pools(false);
        IStaticsBatchRewards.PoolClaim[] memory a = _pools(true);
        vm.prank(alice);
        vm.expectPartialRevert(LibPosition.NotPositionOwnerOrApproved.selector);
        batch.batchClaimRewards(g, l, a, bob);
        assertEq(_accountingHash(), beforeState);
    }

    function testGlobalNoRewardsRemainsAtomicAndLpZeroRewardsRemainSuccessful() public {
        firstPool = _createRangeGaugePool(alice);
        firstId = _stake(alice, _assets());
        _provide(firstId, firstPool, alice);
        IStaticsBatchRewards.GlobalClaim[] memory g = new IStaticsBatchRewards.GlobalClaim[](1);
        g[0] = IStaticsBatchRewards.GlobalClaim(firstId, _assets(), new uint256[](2));
        IStaticsBatchRewards.PoolClaim[] memory l = _poolClaims(firstId, firstPool, _slots(0, false));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GlobalRewardsFacet.NoRewards.selector, firstId));
        batch.batchClaimRewards(g, l, new IStaticsBatchRewards.PoolClaim[](0), alice);
        assertEq(_lpBatch(l)[0][0], 0);
    }

    function testExitedLpStubAndRetainedAllocatorClaimsResolve() public {
        firstPool = _createRangeGaugePool(alice);
        firstId = _stake(alice, new address[](0));
        _provide(firstId, firstPool, alice);
        _allocate(firstId, firstPool);
        reward = new MockERC20("Reward", "RWD", 18);
        _bribe(firstPool, reward, 5_000);
        vm.warp(block.timestamp + 3.5 days);
        _exit(firstId, firstPool, alice);
        vm.prank(alice);
        incentives.setGaugeAllocations(firstId, new PoolId[](0), new uint256[](0));
        IStaticsBatchRewards.PoolClaim[] memory claims = _poolClaims(firstId, firstPool, _slots(1, false));
        vm.prank(alice);
        (, uint256[][] memory lp, uint256[][] memory alloc) =
            batch.batchClaimRewards(new IStaticsBatchRewards.GlobalClaim[](0), claims, claims, alice);
        assertApproxEqAbs(lp[0][0], 25 ether, 2);
        assertApproxEqAbs(alloc[0][0], 25 ether, 2);
        (PoolId[] memory pools,) = rangeGauge.positionGaugePools(firstId, 0, 100);
        assertEq(pools.length, 0, "resolved LP stub removed");
        (pools,) = incentives.positionGaugeAllocatorPools(firstId, 0, 100);
        assertEq(pools.length, 0, "retained allocator claim removed");
    }

    function testTaxedTokenReturnsActualPayoutAndChecksMinimum() public {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _createPosition(alice);
        _provide(id, pool, alice);
        MockFeeOnTransferERC20 taxed = new MockFeeOnTransferERC20();
        uint8 slot = _bribe(pool, taxed, 0);
        vm.warp(block.timestamp + 7 days);
        IStaticsBatchRewards.PoolClaim[] memory claims = _poolClaims(id, pool, _slots(slot, false));
        claims[0].minimumAmounts[0] = 99 ether;
        uint256 beforeBalance = taxed.balanceOf(alice);
        vm.prank(alice);
        vm.expectPartialRevert(IStaticsRangeGauge.RewardAmountBelowMinimum.selector);
        batch.batchClaimRewards(
            new IStaticsBatchRewards.GlobalClaim[](0), claims, new IStaticsBatchRewards.PoolClaim[](0), alice
        );
        assertEq(taxed.balanceOf(alice), beforeBalance);
        claims[0].minimumAmounts[0] = 98.01 ether - 2;
        uint256 paid = _lpBatch(claims)[0][0];
        assertApproxEqAbs(paid, 98.01 ether, 2);
        assertEq(taxed.balanceOf(alice) - beforeBalance, paid);
        assertGe(taxed.balanceOf(address(diamond)), custody.globalReservedByToken(address(taxed)));
    }

    function testRevertingTokenLateInBatchRollsBackPreviousPayout() public {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _createPosition(alice);
        _provide(id, pool, alice);
        MockERC20 first = new MockERC20("First", "FIRST", 18);
        MockRevertingERC20 last = new MockRevertingERC20();
        _bribe(pool, first, 0);
        _bribe(pool, last, 0);
        vm.warp(block.timestamp + 7 days);
        uint8[] memory slots = new uint8[](2);
        slots[0] = 1;
        slots[1] = 2;
        IStaticsBatchRewards.PoolClaim[] memory claims = _poolClaims(id, pool, slots);
        uint256 reserved = custody.globalReservedByToken(address(first));
        last.setTransfersRevert(true);
        vm.prank(alice);
        vm.expectRevert(MockRevertingERC20.TransferBlocked.selector);
        batch.batchClaimRewards(
            new IStaticsBatchRewards.GlobalClaim[](0), claims, new IStaticsBatchRewards.PoolClaim[](0), alice
        );
        assertEq(first.balanceOf(alice), 0);
        assertEq(custody.globalReservedByToken(address(first)), reserved);
        last.setTransfersRevert(false);
        assertGt(_lpBatch(claims)[0][1], 0);
    }

    function _reentry(bytes memory callback, bytes4 errorSelector, bool individual) internal {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _stake(alice, new address[](0));
        _provide(id, pool, alice);
        MockReentrantERC20 token = new MockReentrantERC20();
        uint8 slot = _bribe(pool, token, 0);
        vm.warp(block.timestamp + 1 days);
        token.setCallback(address(diamond), address(diamond), callback);
        IStaticsBatchRewards.PoolClaim[] memory claims = _poolClaims(id, pool, _slots(slot, false));
        if (individual) _claim(id, pool, address(token), 0, alice, alice);
        else assertGt(_lpBatch(claims)[0][0], 0);
        assertFalse(token.reentrySucceeded());
        assertEq(bytes4(token.reentryResult()), errorSelector);
        token.setCallback(address(0), address(0), "");
        vm.warp(block.timestamp + 1 days);
        assertGt(_lpBatch(claims)[0][0], 0, "both guards recovered");
    }

    function _nestedBatch() internal view returns (bytes memory) {
        return abi.encodeCall(
            IStaticsBatchRewards.batchClaimRewards,
            (
                new IStaticsBatchRewards.GlobalClaim[](0),
                new IStaticsBatchRewards.PoolClaim[](0),
                new IStaticsBatchRewards.PoolClaim[](0),
                alice
            )
        );
    }

    function testBatchCallbackCannotReenterBatch() public {
        _reentry(_nestedBatch(), IStaticsBatchRewards.BatchClaimReentrantCall.selector, false);
    }

    function testIndividualCallbackCannotEnterBatch() public {
        _reentry(_nestedBatch(), IStaticsBatchRewards.BatchClaimReentrantCall.selector, true);
    }

    function testBatchCallbackCannotEnterIndividualClaim() public {
        _reentry(
            abi.encodeCall(IStaticsGlobalRewards.claimRewards, (uint256(1), new address[](0), alice, new uint256[](0))),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
            false
        );
    }

    function testBatchCallbackCannotEnterOtherCustodyAction() public {
        _reentry(
            abi.encodeCall(IStaticsGlobalRewards.unstake, (uint256(1), uint256(1), alice)),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
            false
        );
    }

    function testBoundedScheduleCatchupRequiresExplicitCheckpointAndRecovers() public {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _stake(alice, new address[](0));
        _provide(id, pool, alice);
        _allocate(id, pool);
        _activateReserve();
        vm.warp(block.timestamp + 60 weeks);
        IStaticsBatchRewards.PoolClaim[] memory claims = _poolClaims(id, pool, _slots(0, false));
        vm.prank(alice);
        vm.expectPartialRevert(LibGaugeRouting.GaugeScheduleCatchupRequired.selector);
        batch.batchClaimRewards(
            new IStaticsBatchRewards.GlobalClaim[](0), claims, new IStaticsBatchRewards.PoolClaim[](0), alice
        );
        incentives.checkpointGaugeSchedule(52);
        incentives.checkpointGaugeSchedule(52);
        uint256 beforeGas = gasleft();
        assertGt(_lpBatch(claims)[0][0], 0);
        emit log_named_uint("catch-up settled LP claim gas", beforeGas - gasleft());
    }

    function testMaximumBatchGas() public {
        PoolId pool = _createRangeGaugePool(alice);
        IStaticsBatchRewards.PoolClaim[] memory claims = new IStaticsBatchRewards.PoolClaim[](16);
        for (uint256 i; i < 16; ++i) {
            uint256 id = _createPosition(alice);
            _provide(id, pool, alice);
            uint8[] memory slots = new uint8[](4);
            slots[0] = 1;
            slots[1] = 2;
            slots[2] = 3;
            slots[3] = 4;
            claims[i] = IStaticsBatchRewards.PoolClaim(id, PoolId.unwrap(pool), slots, new uint256[](4));
        }
        for (uint256 i; i < 4; ++i) {
            _bribe(pool, new MockERC20("Reward", "RWD", 18), 0);
        }
        vm.warp(block.timestamp + 7 days);
        uint256 beforeGas = gasleft();
        uint256[][] memory amounts = _lpBatch(claims);
        emit log_named_uint("maximum 16 groups / 64 entries gas", beforeGas - gasleft());
        assertEq(amounts.length, 16);
        for (uint256 i; i < 16; ++i) {
            for (uint256 j; j < 4; ++j) {
                assertGt(amounts[i][j], 0);
            }
        }
    }

    function testMaximumBatchGasWithFiftyWeekSettlement() public {
        PoolId pool = _createRangeGaugePool(alice);
        IStaticsBatchRewards.PoolClaim[] memory claims = new IStaticsBatchRewards.PoolClaim[](16);
        for (uint256 i; i < 16; ++i) {
            uint256 id = _stake(alice, new address[](0));
            _provide(id, pool, alice);
            _allocate(id, pool);
            uint8[] memory slots = new uint8[](4);
            slots[0] = 0;
            slots[1] = 1;
            slots[2] = 2;
            slots[3] = 3;
            claims[i] = IStaticsBatchRewards.PoolClaim(id, PoolId.unwrap(pool), slots, new uint256[](4));
        }
        for (uint256 i; i < 3; ++i) {
            _bribe(pool, new MockERC20("Reward", "RWD", 18), 0);
        }
        _activateReserve();
        vm.warp(block.timestamp + 50 weeks);
        uint256 beforeGas = gasleft();
        uint256[][] memory amounts = _lpBatch(claims);
        emit log_named_uint("maximum 16 groups / 64 entries with 50-week settlement gas", beforeGas - gasleft());
        for (uint256 i; i < 16; ++i) {
            for (uint256 j; j < 4; ++j) {
                assertGt(amounts[i][j], 0);
            }
        }
        assertGe(stakingAsset.balanceOf(address(diamond)), custody.globalReservedByToken(address(stakingAsset)));
    }

    function test_BatchRewardsFacetRetainsEip170Headroom() public {
        // Coverage excludes this size check with the EIP-170 test filter.
        assertLe(type(BatchRewardsFacet).runtimeCode.length, 24_576);
        emit log_named_uint("BatchRewardsFacet runtime bytes", type(BatchRewardsFacet).runtimeCode.length);
    }
}
