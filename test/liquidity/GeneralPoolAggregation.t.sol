// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsProtocolRevenue} from "../../src/interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsPositionFees} from "../../src/interfaces/IStaticsPosition.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {GeneralPoolLifecycleTestBase} from "../helpers/GeneralPoolLifecycleTestBase.sol";

/// @notice Proves multi-asset creator-credit aggregation and cross-pool global Statics-staker reward
/// aggregation for a single creator operating several general markets. Fee routing is driven through
/// the installed hook context so exact per-asset accounting can be asserted directly.
contract GeneralPoolAggregationTest is GeneralPoolLifecycleTestBase {
    IStaticsProtocolRevenue private revenue;
    IStaticsGlobalRewards private staticsStakers;
    address private creator = makeAddr("aggregate-creator");
    address private staker = makeAddr("aggregate-staker");

    function setUp() public override {
        super.setUp();
        revenue = IStaticsProtocolRevenue(address(diamond));
        staticsStakers = IStaticsGlobalRewards(address(diamond));
    }

    function testCreatorCreditAggregatesAcrossPoolsPerAssetAndReconciles() public {
        // A shared asset (USDC-like) participates in three markets created by the same creator.
        address shared = _newToken("Shared");
        address tokenX = _newToken("TokenX");
        address tokenY = _newToken("TokenY");

        (PoolId poolXShared,) = _createGeneralPool(tokenX, shared, 10, creator);
        (PoolId poolYShared,) = _createGeneralPool(tokenY, shared, 60, creator);
        (PoolId poolXY,) = _createGeneralPool(tokenX, tokenY, 60, creator);

        // Route creator credit in `shared` from the two shared-asset pools.
        _routeCreator(poolXShared, shared, 500);
        _routeCreator(poolYShared, shared, 700);
        // Route creator credit in tokenX from the XY pool.
        _routeCreator(poolXY, tokenX, 300);

        // Per-asset creator credit sums across pools; identity is one immutable creator.
        assertEq(revenue.creatorRevenue(creator, shared), 1_200);
        assertEq(revenue.creatorRevenue(creator, tokenX), 300);

        // Aggregate liability reconciles with the outstanding per-asset credit.
        assertEq(revenue.totalCreatorRevenue(shared), 1_200);
        assertEq(revenue.totalCreatorRevenue(tokenX), 300);

        // A claim of one asset decrements only that asset's aggregate.
        vm.prank(creator);
        revenue.claimCreatorRevenue(shared, creator, 0);
        assertEq(revenue.creatorRevenue(creator, shared), 0);
        assertEq(revenue.totalCreatorRevenue(shared), 0);
        assertEq(revenue.totalCreatorRevenue(tokenX), 300);
    }

    function testTwoCreatorsShareAssetLiabilityAggregate() public {
        address second = makeAddr("second-creator");
        address shared = _newToken("SharedTwo");
        address tokenX = _newToken("TokenX2");
        address tokenY = _newToken("TokenY2");
        (PoolId poolA,) = _createGeneralPool(tokenX, shared, 10, creator);
        (PoolId poolB,) = _createGeneralPool(tokenY, shared, 60, second);

        _routeCreator(poolA, shared, 400);
        _routeCreator(poolB, shared, 600);

        // Per-creator credit is isolated; aggregate is their sum for the shared asset.
        assertEq(revenue.creatorRevenue(creator, shared), 400);
        assertEq(revenue.creatorRevenue(second, shared), 600);
        assertEq(revenue.totalCreatorRevenue(shared), 1_000);
    }

    function testGlobalStakerRewardsAggregateSameAssetAcrossPools() public {
        address shared = _newToken("Reward");
        address tokenX = _newToken("PairX");
        address tokenY = _newToken("PairY");
        (PoolId poolX,) = _createGeneralPool(tokenX, shared, 10, creator);
        (PoolId poolY,) = _createGeneralPool(tokenY, shared, 60, creator);

        // A staker opts into the shared reward token and matures past the eligibility delay.
        uint256 stakePositionId = _stakeStakerFor(staker, shared);
        vm.warp(block.timestamp + 25 hours);
        vm.roll(block.number + 1);

        // Route staker rewards in `shared` from both pools.
        _routeStaker(poolX, shared, 1_000);
        _routeStaker(poolY, shared, 2_500);

        // Both pools converge into one global reward book keyed by the exact reward-token address.
        address[] memory query = new address[](1);
        query[0] = shared;
        vm.prank(staker);
        uint256[] memory pending = staticsStakers.pendingRewards(stakePositionId, query);
        assertEq(pending[0], 3_500, "cross-pool staker rewards did not aggregate");
    }

    // --- helpers ---

    function _routeCreator(PoolId poolId, address asset, uint256 amount) private {
        _fundHook(asset, amount);
        vm.prank(address(swapFeeHook));
        revenue.routeProtocolSwapFees(
            poolId,
            asset,
            IStaticsProtocolRevenue.ProtocolFeeDistribution({
                liquidityProvider: 0, basketStaker: 0, staticsStaker: 0, creator: amount, treasury: 0
            })
        );
    }

    function _routeStaker(PoolId poolId, address asset, uint256 amount) private {
        _fundHook(asset, amount);
        vm.prank(address(swapFeeHook));
        revenue.routeProtocolSwapFees(
            poolId,
            asset,
            IStaticsProtocolRevenue.ProtocolFeeDistribution({
                liquidityProvider: 0, basketStaker: 0, staticsStaker: amount, creator: 0, treasury: 0
            })
        );
    }

    function _stakeStakerFor(address user, address rewardAsset) private returns (uint256 positionId) {
        uint256 fee = IStaticsPositionFees(address(diamond)).positionCreationFee();
        uint256 stakeAmount = 10 ether;
        stakingAsset.mint(user, stakeAmount);
        address[] memory rewards = new address[](1);
        rewards[0] = rewardAsset;
        vm.deal(user, user.balance + fee);
        vm.startPrank(user);
        IERC20(address(stakingAsset)).approve(address(diamond), stakeAmount);
        positionId = staticsStakers.createAndStake{value: fee}(stakeAmount, user, rewards);
        vm.stopPrank();
    }

    function _fundHook(address token, uint256 amount) private {
        MockERC20(token).mint(address(swapFeeHook), amount);
        vm.prank(address(swapFeeHook));
        IERC20(token).approve(address(diamond), amount);
    }
}
