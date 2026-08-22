// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsProtocolRevenue} from "../../src/interfaces/IStaticsProtocolRevenue.sol";
import {ProtocolRevenueFacet} from "../../src/facets/ProtocolRevenueFacet.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

/// @notice Focused coverage for hook-only fee routing, creator credit accrual, and CEI measured
/// creator claims. Routing is driven by pranking as the installed hook so the accounting can be
/// asserted directly rather than reconstructed from a full swap.
contract ProtocolRevenueTest is CanonicalPoolTestBase {
    IStaticsProtocolPools private pools;
    IStaticsProtocolRevenue private revenue;
    address private creator = makeAddr("pool-creator");
    PoolId private poolId;
    address private tokenA;
    address private tokenB;

    function setUp() public override {
        super.setUp();
        pools = IStaticsProtocolPools(address(diamond));
        revenue = IStaticsProtocolRevenue(address(diamond));
        tokenA = address(assetA);
        tokenB = address(assetB);
        IStaticsProtocolPools.CreatePoolParams memory params = IStaticsProtocolPools.CreatePoolParams({
            tokenA: tokenA,
            tokenB: tokenB,
            tickSpacing: 10,
            sqrtPriceBPerAX96: SQRT_PRICE_1_1,
            feeRate: IStaticsProtocolPools.PoolSwapFeeRate({inputFeeBps: 25, outputFeeBps: 25}),
            creator: creator,
            nonce: 1,
            deadline: block.timestamp + 1 days
        });
        poolId = pools.createPool(params, "");
    }

    function testOnlyHookCanRouteFees() public {
        IStaticsProtocolRevenue.ProtocolFeeDistribution memory distribution = _distribution(0, 0, 0, 100, 0);
        vm.expectRevert(
            abi.encodeWithSelector(ProtocolRevenueFacet.OnlySwapFeeHook.selector, address(this), address(swapFeeHook))
        );
        revenue.routeProtocolSwapFees(poolId, tokenA, distribution);
    }

    function testRouteCreditsCreatorAndClaimPaysMeasuredAmount() public {
        uint256 creatorAmount = 500;
        uint256 treasuryAmount = 9_500;
        uint256 total = creatorAmount + treasuryAmount;
        _fundHook(tokenA, total);

        vm.prank(address(swapFeeHook));
        revenue.routeProtocolSwapFees(poolId, tokenA, _distribution(0, 0, 0, creatorAmount, treasuryAmount));

        assertEq(revenue.creatorRevenue(creator, tokenA), creatorAmount);
        assertEq(revenue.totalCreatorRevenue(tokenA), creatorAmount);

        address receiver = makeAddr("revenue-receiver");
        uint256 receiverBefore = IERC20(tokenA).balanceOf(receiver);
        vm.prank(creator);
        (uint256 amount, uint256 received) = revenue.claimCreatorRevenue(tokenA, receiver, creatorAmount);
        assertEq(amount, creatorAmount);
        assertEq(received, creatorAmount);
        assertEq(IERC20(tokenA).balanceOf(receiver) - receiverBefore, creatorAmount);
        assertEq(revenue.creatorRevenue(creator, tokenA), 0);
        assertEq(revenue.totalCreatorRevenue(tokenA), 0);
    }

    function testCreatorRevenueAccruesInBothCurrencies() public {
        _fundHook(tokenA, 500);
        _fundHook(tokenB, 700);
        vm.startPrank(address(swapFeeHook));
        revenue.routeProtocolSwapFees(poolId, tokenA, _distribution(0, 0, 0, 500, 0));
        revenue.routeProtocolSwapFees(poolId, tokenB, _distribution(0, 0, 0, 700, 0));
        vm.stopPrank();
        assertEq(revenue.creatorRevenue(creator, tokenA), 500);
        assertEq(revenue.creatorRevenue(creator, tokenB), 700);
    }

    function testClaimRejectsZeroReceiverAndEmptyCredit() public {
        vm.prank(creator);
        vm.expectRevert(ProtocolRevenueFacet.InvalidReceiver.selector);
        revenue.claimCreatorRevenue(tokenA, address(0), 0);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ProtocolRevenueFacet.NoCreatorRevenue.selector, creator, tokenA));
        revenue.claimCreatorRevenue(tokenA, makeAddr("r"), 0);
    }

    function testClaimEnforcesMinimumOutput() public {
        _fundHook(tokenA, 500);
        vm.prank(address(swapFeeHook));
        revenue.routeProtocolSwapFees(poolId, tokenA, _distribution(0, 0, 0, 500, 0));
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ProtocolRevenueFacet.MinimumOutputNotMet.selector, tokenA, 500, 501));
        revenue.claimCreatorRevenue(tokenA, makeAddr("r"), 501);
        // credit preserved after failed claim
        assertEq(revenue.creatorRevenue(creator, tokenA), 500);
    }

    function testGeneralPoolRejectsBasketStakerShare() public {
        _fundHook(tokenA, 100);
        vm.prank(address(swapFeeHook));
        vm.expectRevert(
            abi.encodeWithSelector(ProtocolRevenueFacet.GeneralPoolBasketReward.selector, poolId, uint256(100))
        );
        revenue.routeProtocolSwapFees(poolId, tokenA, _distribution(0, 100, 0, 0, 0));
    }

    function _distribution(
        uint256 lp,
        uint256 basketStaker,
        uint256 staticsStaker,
        uint256 creatorAmt,
        uint256 treasury
    ) private pure returns (IStaticsProtocolRevenue.ProtocolFeeDistribution memory) {
        return IStaticsProtocolRevenue.ProtocolFeeDistribution({
            liquidityProvider: lp,
            basketStaker: basketStaker,
            staticsStaker: staticsStaker,
            creator: creatorAmt,
            treasury: treasury
        });
    }

    function _fundHook(address token, uint256 amount) private {
        MockERC20(token).mint(address(swapFeeHook), amount);
        vm.prank(address(swapFeeHook));
        IERC20(token).approve(address(diamond), amount);
    }
}
