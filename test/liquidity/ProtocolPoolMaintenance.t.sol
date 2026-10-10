// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
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
            IStaticsProtocolPools.ProtocolPoolMaintenanceConfig({revenueTipBps: 100})
        );
    }

    function testRevenueSettlementIsPermissionlessSingleCurrencyAndTreasuryFunded() public {
        (PoolId poolId, PoolKey memory key) = _liquidPool("Revenue A", "Revenue B");
        _swapGeneralPool(key, trader, true, 0.02 ether);

        IStaticsSwapFeeHook.FeeDistribution memory pending0 = swapFeeHook.pendingFeeDistribution(poolId, key.currency0);
        IStaticsSwapFeeHook.FeeDistribution memory pending1 = swapFeeHook.pendingFeeDistribution(poolId, key.currency1);
        uint256 grossExpected = _total(pending0);
        uint256 tipExpected = Math.mulDiv(pending0.treasury, 100, 10_000);
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

    function _liquidPool(string memory name0, string memory name1) private returns (PoolId poolId, PoolKey memory key) {
        (poolId, key) = _createGeneralPool(_newToken(name0), _newToken(name1), 10, creator);
        _mintFullRangeGeneralPosition(key, lp, 5 ether);
    }

    function _total(IStaticsSwapFeeHook.FeeDistribution memory distribution) private pure returns (uint256) {
        return distribution.basketStaker + distribution.staticsStaker + distribution.creator + distribution.treasury;
    }
}
