// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {MockERC20} from "../mocks/MockERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {BatchRewardsFlowTestBase} from "../helpers/BatchRewardsFlowTestBase.sol";

/// @dev ABI-neutral baseline/candidate benchmark: includes only the external action,
/// not pool/NFT fixture construction. Run with the repository's unchanged profile.
contract PositionStatementGasTest is BatchRewardsFlowTestBase {
    function testGasOrdinaryLpClaim() public {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _createPosition(alice);
        _provide(id, pool, alice);
        _fundReward(pool, assetA, 100 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 beforeGas = gasleft();
        uint256 received = _claim(id, pool, address(assetA), 0, alice, alice);
        emit log_named_uint("statement ordinary LP claim gas", beforeGas - gasleft());
        assertGt(received, 0);
    }

    function testGasManagedLiquidityActions() public {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _createPosition(alice);
        uint256 beforeGas = gasleft();
        _provide(id, pool, alice);
        emit log_named_uint("statement provide fixture/action gas", beforeGas - gasleft());
        _fundAndApprovePoolAssets(_poolKey(pool), alice, TOKEN_MAXIMUM);
        vm.startPrank(alice);
        beforeGas = gasleft();
        rangeGauge.increaseLiquidity(
            id,
            pool,
            IStaticsRangeGauge.IncreaseLiquidityParams(1 ether, TOKEN_MAXIMUM, TOKEN_MAXIMUM, block.timestamp + 1 hours)
        );
        emit log_named_uint("statement increase gas", beforeGas - gasleft());
        beforeGas = gasleft();
        rangeGauge.decreaseLiquidity(
            id, pool, IStaticsRangeGauge.DecreaseLiquidityParams(1 ether, 0, 0, block.timestamp + 1 hours)
        );
        emit log_named_uint("statement decrease gas", beforeGas - gasleft());
        beforeGas = gasleft();
        rangeGauge.collectNativeFees(id, pool, 0, 0, block.timestamp + 1 hours);
        emit log_named_uint("statement collect zero gas", beforeGas - gasleft());
        beforeGas = gasleft();
        rangeGauge.rebalanceLiquidity(
            id,
            pool,
            IStaticsRangeGauge.RebalanceLiquidityParams(-100, 100, 1 ether, 0, 0, 0, 0, block.timestamp + 1 hours)
        );
        emit log_named_uint("statement rebalance gas", beforeGas - gasleft());
        beforeGas = gasleft();
        rangeGauge.exitLiquidity(id, pool, 0, 0, block.timestamp + 1 hours);
        emit log_named_uint("statement exit gas", beforeGas - gasleft());
        vm.stopPrank();
    }

    function testGasAllocationOneAndSixteen() public {
        uint256 id = _stake(alice, new address[](0));
        PoolId[] memory pools = new PoolId[](16);
        uint256[] memory amounts = new uint256[](16);
        for (uint256 i; i < 16; ++i) {
            pools[i] = _createRangeGaugePool(alice, address(assetA), address(new MockERC20("Pool token", "POOL", 18)));
            amounts[i] = 1 ether;
        }
        (uint40 firstAt,,,) = incentives.gaugePositionAllocations(id);
        vm.warp(firstAt);
        vm.prank(alice);
        uint256 beforeGas = gasleft();
        incentives.setGaugeAllocations(id, pools, amounts);
        emit log_named_uint("statement allocation sixteen gas", beforeGas - gasleft());
        (uint40 nextAt,,,) = incentives.gaugePositionAllocations(id);
        vm.warp(nextAt);
        pools = new PoolId[](1);
        pools[0] = _createRangeGaugePool(alice, address(assetA), address(new MockERC20("Next pool", "NEXT", 18)));
        amounts = new uint256[](1);
        amounts[0] = 1 ether;
        vm.prank(alice);
        beforeGas = gasleft();
        incentives.setGaugeAllocations(id, pools, amounts);
        emit log_named_uint("statement allocation one replacement gas", beforeGas - gasleft());
    }
}
