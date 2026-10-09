// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {MockERC20} from "../mocks/MockERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {IStaticsGaugeIncentives} from "../../src/interfaces/IStaticsGaugeIncentives.sol";
import {BatchRewardsFlowTestBase} from "../helpers/BatchRewardsFlowTestBase.sol";

contract StatementAllocationWallet {
    function replaceTwice(
        IStaticsGaugeIncentives target,
        uint256 id,
        PoolId[] calldata pools,
        uint256[] calldata amounts
    ) external {
        target.setGaugeAllocations(id, pools, amounts);
        target.setGaugeAllocations(id, new PoolId[](0), new uint256[](0));
    }
}

/// @notice Statement events are checked against real v4 transfers and managed NFT operations.
contract PositionStatementEventsTest is BatchRewardsFlowTestBase {
    function _event(bytes32 topic) private returns (Vm.Log memory found) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(diamond) && logs[i].topics[0] == topic) {
                found = logs[i];
                ++count;
            }
        }
        assertEq(count, 1, "one canonical diamond event");
    }

    function testProvideRecordsGrossFundingAndActualRefund() public {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _createPosition(alice);
        PoolKey memory key = _poolKey(pool);
        vm.recordLogs();
        IStaticsRangeGauge.LiquidityMovement memory result = _provide(id, pool, alice);
        Vm.Log memory log = _event(IStaticsRangeGauge.ManagedLiquidityProvided.selector);
        (,,, IStaticsRangeGauge.LiquidityStatementMovement memory movement) =
            abi.decode(log.data, (address, int24, int24, IStaticsRangeGauge.LiquidityStatementMovement));
        assertEq(uint256(log.topics[1]), id);
        assertEq(log.topics[2], PoolId.unwrap(pool));
        assertEq(uint256(log.topics[3]), result.posmTokenId);
        assertEq(movement.liquidityBefore, 0);
        assertEq(movement.liquidityAfter, INITIAL_LIQUIDITY);
        assertEq(movement.payer, alice);
        assertEq(movement.receiver, alice);
        assertEq(movement.paid0, TOKEN_MAXIMUM);
        assertEq(movement.paid1, TOKEN_MAXIMUM);
        assertEq(movement.received0, result.received0);
        assertEq(movement.received1, result.received1);
        assertEq(movement.paid0 - movement.received0, result.spent0);
        assertEq(movement.paid1 - movement.received1, result.spent1);
        assertEq(_balance(key.currency0, alice), movement.received0);
        assertEq(_balance(key.currency1, alice), movement.received1);
    }

    function testApprovedOperatorPaysAndOwnerReceivesIncreaseRefund() public {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _createPosition(alice);
        _provide(id, pool, alice);
        PoolKey memory key = _poolKey(pool);
        _fundAndApprovePoolAssets(key, bob, TOKEN_MAXIMUM);
        vm.prank(alice);
        IERC721(address(diamond)).approve(bob, id);
        uint256 before0 = _balance(key.currency0, alice);
        uint256 before1 = _balance(key.currency1, alice);
        vm.recordLogs();
        vm.prank(bob);
        rangeGauge.increaseLiquidity(
            id,
            pool,
            IStaticsRangeGauge.IncreaseLiquidityParams(1 ether, TOKEN_MAXIMUM, TOKEN_MAXIMUM, block.timestamp + 1 hours)
        );
        IStaticsRangeGauge.LiquidityStatementMovement memory movement = abi.decode(
            _event(IStaticsRangeGauge.ManagedLiquidityChanged.selector).data,
            (IStaticsRangeGauge.LiquidityStatementMovement)
        );
        assertEq(movement.payer, bob);
        assertEq(movement.receiver, alice);
        assertEq(movement.liquidityBefore, INITIAL_LIQUIDITY);
        assertEq(movement.liquidityAfter, INITIAL_LIQUIDITY + 1 ether);
        assertEq(movement.paid0, TOKEN_MAXIMUM);
        assertEq(movement.paid1, TOKEN_MAXIMUM);
        assertEq(_balance(key.currency0, bob), 0);
        assertEq(_balance(key.currency1, bob), 0);
        assertEq(_balance(key.currency0, alice) - before0, movement.received0);
        assertEq(_balance(key.currency1, alice) - before1, movement.received1);
    }

    function testDecreaseAndExitRecordOutputOnlyMovement() public {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _createPosition(alice);
        _provide(id, pool, alice);
        vm.recordLogs();
        vm.prank(alice);
        IStaticsRangeGauge.LiquidityMovement memory result = rangeGauge.decreaseLiquidity(
            id, pool, IStaticsRangeGauge.DecreaseLiquidityParams(1 ether, 0, 0, block.timestamp + 1 hours)
        );
        IStaticsRangeGauge.LiquidityStatementMovement memory movement = abi.decode(
            _event(IStaticsRangeGauge.ManagedLiquidityChanged.selector).data,
            (IStaticsRangeGauge.LiquidityStatementMovement)
        );
        _assertOutput(movement, result, INITIAL_LIQUIDITY, INITIAL_LIQUIDITY - 1 ether);
        vm.recordLogs();
        vm.prank(alice);
        result = rangeGauge.exitLiquidity(id, pool, 0, 0, block.timestamp + 1 hours);
        movement = abi.decode(
            _event(IStaticsRangeGauge.ManagedLiquidityExited.selector).data,
            (IStaticsRangeGauge.LiquidityStatementMovement)
        );
        _assertOutput(movement, result, INITIAL_LIQUIDITY - 1 ether, 0);
    }

    function testZeroFeeCollectionHasScopedDiamondEvent() public {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _createPosition(alice);
        IStaticsRangeGauge.LiquidityMovement memory provided = _provide(id, pool, alice);
        vm.recordLogs();
        vm.prank(alice);
        rangeGauge.collectNativeFees(id, pool, 0, 0, block.timestamp + 1 hours);
        Vm.Log memory log = _event(IStaticsRangeGauge.ManagedLiquidityFeesCollected.selector);
        (address receiver, uint256 amount0, uint256 amount1) = abi.decode(log.data, (address, uint256, uint256));
        assertEq(uint256(log.topics[1]), id);
        assertEq(uint256(log.topics[3]), provided.posmTokenId);
        assertEq(receiver, alice);
        assertEq(amount0, 0);
        assertEq(amount1, 0);
    }

    function testPositiveFeeCollectionMatchesActualWalletCredits() public {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _createPosition(alice);
        _provide(id, pool, alice);
        PoolKey memory key = _poolKey(pool);
        _fundAndApprovePoolAssets(key, bob, 1 ether);
        _approveV4Router(bob, Currency.unwrap(key.currency0));
        _approveV4Router(bob, Currency.unwrap(key.currency1));
        vm.prank(bob);
        v4Router.swap(key, SwapParams(true, -int256(0.01 ether), TickMath.MIN_SQRT_PRICE + 1));
        uint256 before0 = _balance(key.currency0, alice);
        uint256 before1 = _balance(key.currency1, alice);
        vm.recordLogs();
        vm.prank(alice);
        IStaticsRangeGauge.LiquidityMovement memory result =
            rangeGauge.collectNativeFees(id, pool, 0, 0, block.timestamp + 1 hours);
        (address receiver, uint256 amount0, uint256 amount1) = abi.decode(
            _event(IStaticsRangeGauge.ManagedLiquidityFeesCollected.selector).data, (address, uint256, uint256)
        );
        assertEq(receiver, alice);
        assertGt(amount0 + amount1, 0);
        assertEq(amount0, result.received0);
        assertEq(amount1, result.received1);
        assertEq(amount0, _balance(key.currency0, alice) - before0);
        assertEq(amount1, _balance(key.currency1, alice) - before1);
    }

    function testRebalanceDistinguishesInternalProceedsFromWalletFunding() public {
        _rebalance(0);
    }

    function testRebalanceReportsAdditionalWalletFunding() public {
        _rebalance(TOKEN_MAXIMUM);
    }

    function _rebalance(uint256 topUp) private {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _createPosition(alice);
        _provide(id, pool, alice);
        if (topUp != 0) _fundAndApprovePoolAssets(_poolKey(pool), alice, topUp);
        vm.recordLogs();
        vm.prank(alice);
        rangeGauge.rebalanceLiquidity(
            id,
            pool,
            IStaticsRangeGauge.RebalanceLiquidityParams(
                -100, 100, 1 ether, topUp, topUp, 0, 0, block.timestamp + 1 hours
            )
        );
        (
            ,,,,
            IStaticsRangeGauge.LiquidityStatementMovement memory movement,
            IStaticsRangeGauge.RebalanceSettlement memory settlement
        ) = abi.decode(
            _event(IStaticsRangeGauge.ManagedLiquidityRebalanced.selector).data,
            (
                uint256,
                address,
                int24,
                int24,
                IStaticsRangeGauge.LiquidityStatementMovement,
                IStaticsRangeGauge.RebalanceSettlement
            )
        );
        assertEq(movement.liquidityBefore, INITIAL_LIQUIDITY);
        assertEq(movement.liquidityAfter, 1 ether);
        assertEq(movement.paid0, topUp);
        assertEq(movement.paid1, topUp);
        assertGt(settlement.withdrawn0 + settlement.withdrawn1, 0);
        assertEq(settlement.withdrawn0 + topUp + settlement.mintReceived0, settlement.mintSpent0 + movement.received0);
        assertEq(settlement.withdrawn1 + topUp + settlement.mintReceived1, settlement.mintSpent1 + movement.received1);
    }

    function testNativeFundingExcludesGasAndInternalProceeds() public {
        PoolId pool = _createRangeGaugePool(alice, address(0), address(assetA));
        uint256 id = _createPosition(alice);
        vm.recordLogs();
        IStaticsRangeGauge.LiquidityMovement memory result = _provide(id, pool, alice);
        (,,, IStaticsRangeGauge.LiquidityStatementMovement memory movement) = abi.decode(
            _event(IStaticsRangeGauge.ManagedLiquidityProvided.selector).data,
            (address, int24, int24, IStaticsRangeGauge.LiquidityStatementMovement)
        );
        assertEq(movement.paid0, TOKEN_MAXIMUM);
        assertEq(movement.paid0 - movement.received0, result.spent0);
    }

    function testAllocationEventCarriesExactReplacementOrder() public {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _stake(alice, new address[](0));
        vm.recordLogs();
        _allocate(id, pool);
        (uint256 total, PoolId[] memory pools, uint256[] memory amounts) = abi.decode(
            _event(IStaticsGaugeIncentives.PositionGaugeAllocationsSet.selector).data, (uint256, PoolId[], uint256[])
        );
        assertEq(total, 100 ether);
        assertEq(pools.length, 1);
        assertEq(PoolId.unwrap(pools[0]), PoolId.unwrap(pool));
        assertEq(amounts[0], total);
    }

    function testAllocationEncodingMaximumAndWrappedSameBlockClearing() public {
        uint256 id = _stake(alice, new address[](0));
        PoolId[] memory pools = new PoolId[](16);
        uint256[] memory amounts = new uint256[](16);
        for (uint256 i; i < 16; ++i) {
            pools[i] = _createRangeGaugePool(alice, address(assetA), address(new MockERC20("Pool", "POOL", 18)));
            amounts[i] = 1 ether;
        }
        incentives.setGaugeAllocationCooldown(0);
        (uint40 nextAt,,,) = incentives.gaugePositionAllocations(id);
        vm.warp(nextAt);
        StatementAllocationWallet wallet = new StatementAllocationWallet();
        vm.prank(alice);
        IERC721(address(diamond)).approve(address(wallet), id);
        vm.recordLogs();
        wallet.replaceTwice(incentives, id, pools, amounts);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(diamond)
                    || logs[i].topics[0] != IStaticsGaugeIncentives.PositionGaugeAllocationsSet.selector
            ) continue;
            (uint256 total, PoolId[] memory loggedPools, uint256[] memory loggedAmounts) =
                abi.decode(logs[i].data, (uint256, PoolId[], uint256[]));
            if (count++ == 0) {
                assertEq(total, 16 ether);
                assertEq(abi.encode(loggedPools, loggedAmounts), abi.encode(pools, amounts));
            } else {
                assertEq(total, 0);
                assertEq(loggedPools.length, 0);
                assertEq(loggedAmounts.length, 0);
            }
        }
        assertEq(count, 2, "preserve distinct same-block replacements");
    }

    function _balance(Currency asset, address owner) private view returns (uint256) {
        return asset.isAddressZero() ? owner.balance : asset.balanceOf(owner);
    }

    function _assertOutput(
        IStaticsRangeGauge.LiquidityStatementMovement memory movement,
        IStaticsRangeGauge.LiquidityMovement memory result,
        uint128 before_,
        uint128 after_
    ) private view {
        assertEq(movement.payer, address(0));
        assertEq(movement.receiver, alice);
        assertEq(movement.paid0 + movement.paid1, 0);
        assertEq(movement.received0, result.received0);
        assertEq(movement.received1, result.received1);
        assertEq(movement.liquidityBefore, before_);
        assertEq(movement.liquidityAfter, after_);
    }
}
