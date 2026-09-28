// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ProtocolPoolMaintenanceFacet} from "../../src/facets/ProtocolPoolMaintenanceFacet.sol";
import {IStaticsGovernance} from "../../src/interfaces/IStaticsGovernance.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsProtocolRevenue} from "../../src/interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {GeneralPoolLifecycleTestBase} from "../helpers/GeneralPoolLifecycleTestBase.sol";

contract ProtocolPoolMaintenanceTest is GeneralPoolLifecycleTestBase {
    address private creator = makeAddr("maintenance-creator");
    address private lp = makeAddr("maintenance-lp");
    address private trader = makeAddr("maintenance-trader");
    address private caller = makeAddr("maintenance-caller");

    function setUp() public override {
        super.setUp();
        pools.setProtocolPoolMaintenanceConfig(
            IStaticsProtocolPools.ProtocolPoolMaintenanceConfig({
                revenueTipBps: 500, compoundTipBps: 100, twapWindow: 30 minutes, maxTickDeviation: 500
            })
        );
    }

    function testRevenueSettlementIsPermissionlessSingleCurrencyAndTreasuryFunded() public {
        (PoolId poolId, PoolKey memory key) = _liquidPool("Revenue A", "Revenue B");
        _swapGeneralPool(key, trader, true, 0.02 ether);

        IStaticsSwapFeeHook.FeeDistribution memory pending0 = swapFeeHook.pendingFeeDistribution(poolId, key.currency0);
        IStaticsSwapFeeHook.FeeDistribution memory pending1 = swapFeeHook.pendingFeeDistribution(poolId, key.currency1);
        uint256 grossExpected = _total(pending0);
        uint256 tipExpected = Math.mulDiv(pending0.treasury, 500, 10_000);
        assertGt(grossExpected, 0);
        assertGt(_total(pending1), 0);

        address asset0 = Currency.unwrap(key.currency0);
        uint256 callerBefore = IERC20(asset0).balanceOf(caller);
        vm.prank(caller);
        (uint256 gross, uint256 tip) = pools.settleProtocolPoolRevenue(poolId, asset0);

        assertEq(gross, grossExpected);
        assertEq(tip, tipExpected);
        assertEq(IERC20(asset0).balanceOf(caller) - callerBefore, tipExpected);
        assertEq(_total(swapFeeHook.pendingFeeDistribution(poolId, key.currency0)), 0);
        assertEq(_total(swapFeeHook.pendingFeeDistribution(poolId, key.currency1)), _total(pending1));
        assertEq(IStaticsProtocolRevenue(address(diamond)).creatorRevenue(poolId, asset0), pending0.creator);
    }

    function testPolCompoundingRequiresHistoryAndDoesNotRunInsideSwap() public {
        (PoolId poolId, PoolKey memory key) = _liquidPool("Compound A", "Compound B");
        _swapGeneralPool(key, trader, true, 0.02 ether);
        assertEq(swapFeeHook.lockedLiquidity(poolId), 0);

        vm.prank(caller);
        vm.expectPartialRevert(ProtocolPoolMaintenanceFacet.InsufficientMarketHistory.selector);
        pools.compoundProtocolPoolPol(poolId);

        vm.warp(block.timestamp + 30 minutes);
        vm.roll(block.number + 1);
        _swapGeneralPool(key, trader, false, 0.02 ether);
        assertEq(swapFeeHook.lockedLiquidity(poolId), 0);

        IStaticsSwapFeeHook.FeeDistribution memory pending0 = swapFeeHook.pendingFeeDistribution(poolId, key.currency0);
        IStaticsSwapFeeHook.FeeDistribution memory pending1 = swapFeeHook.pendingFeeDistribution(poolId, key.currency1);
        uint256 caller0Before = IERC20(Currency.unwrap(key.currency0)).balanceOf(caller);
        uint256 caller1Before = IERC20(Currency.unwrap(key.currency1)).balanceOf(caller);
        vm.prank(caller);
        IStaticsProtocolPools.ProtocolPoolPolCompoundResult memory result = pools.compoundProtocolPoolPol(poolId);

        assertGt(result.liquidityAdded, 0);
        assertGt(result.amount0Consumed, 0);
        assertGt(result.amount1Consumed, 0);
        assertEq(result.tip0, Math.min(pending0.treasury, Math.mulDiv(result.amount0Consumed, 100, 10_000)));
        assertEq(result.tip1, Math.min(pending1.treasury, Math.mulDiv(result.amount1Consumed, 100, 10_000)));
        assertEq(IERC20(Currency.unwrap(key.currency0)).balanceOf(caller) - caller0Before, result.tip0);
        assertEq(IERC20(Currency.unwrap(key.currency1)).balanceOf(caller) - caller1Before, result.tip1);
        assertEq(swapFeeHook.lockedLiquidity(poolId), result.liquidityAdded);
    }

    function testLiquidityPauseOnlyBlocksCompounding() public {
        (PoolId poolId, PoolKey memory key) = _liquidPool("Pause A", "Pause B");
        _swapGeneralPool(key, trader, true, 0.02 ether);
        vm.warp(block.timestamp + 30 minutes);
        vm.roll(block.number + 1);
        _swapGeneralPool(key, trader, false, 0.02 ether);

        vm.prank(guardian);
        IStaticsGovernance(address(diamond)).pause(1 << 5);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ProtocolPoolMaintenanceFacet.ActionPaused.selector, 1 << 5));
        pools.compoundProtocolPoolPol(poolId);

        vm.prank(caller);
        (uint256 gross,) = pools.settleProtocolPoolRevenue(poolId, Currency.unwrap(key.currency0));
        assertGt(gross, 0);
    }

    function _liquidPool(string memory name0, string memory name1) private returns (PoolId poolId, PoolKey memory key) {
        (poolId, key) = _createGeneralPool(_newToken(name0), _newToken(name1), 10, creator);
        _mintFullRangeGeneralPosition(key, lp, 5 ether);
    }

    function _total(IStaticsSwapFeeHook.FeeDistribution memory distribution) private pure returns (uint256) {
        return distribution.basketStaker + distribution.staticsStaker + distribution.creator + distribution.treasury;
    }
}
