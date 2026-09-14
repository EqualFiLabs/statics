// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsPositionFees} from "../../src/interfaces/IStaticsPosition.sol";
import {IStaticsProtocolRevenue} from "../../src/interfaces/IStaticsProtocolRevenue.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {GeneralPoolLifecycleTestBase} from "../helpers/GeneralPoolLifecycleTestBase.sol";

/// @notice End-to-end general-pool lifecycle proving native LP ownership remains with the user while
/// bilateral fee allocation, POL formation, native POL fee routing, creator claims, and decommissioning
/// operate through the protocol.
contract GeneralPoolLifecycleTest is GeneralPoolLifecycleTestBase {
    using PoolIdLibrary for PoolKey;

    IStaticsProtocolRevenue private revenue;
    IStaticsGlobalRewards private staticsStakers;

    address private creator = makeAddr("general-creator");
    address private lp = makeAddr("general-lp");
    address private trader = makeAddr("general-trader");

    function setUp() public override {
        super.setUp();
        revenue = IStaticsProtocolRevenue(address(diamond));
        staticsStakers = IStaticsGlobalRewards(address(diamond));
    }

    function testGeneralPoolUsesNativeFeesAndRoutesPolFeesToTreasury() public {
        address tokenA = _newToken("Alpha");
        address tokenB = _newToken("Beta");
        (PoolId poolId, PoolKey memory key) = _createGeneralPool(tokenA, tokenB, 10, creator);
        assertEq(key.fee, 3_000);
        assertEq(pools.protocolPool(poolId).key.fee, 3_000);

        uint256 tokenId = _mintFullRangeGeneralPosition(key, lp, 5 ether);
        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenId), lp);

        uint256 stakePositionId = _stakeStaticsFor(trader, tokenA, tokenB);
        vm.warp(block.timestamp + 25 hours);
        vm.roll(block.number + 1);
        _swapGeneralPool(key, trader, true, 0.02 ether);
        _swapGeneralPool(key, trader, false, 0.02 ether);

        assertGt(revenue.creatorRevenue(creator, tokenA), 0);
        assertGt(revenue.creatorRevenue(creator, tokenB), 0);
        assertGt(swapFeeHook.lockedLiquidity(poolId), 0);
        address[] memory rewardAssets = new address[](2);
        rewardAssets[0] = tokenA;
        rewardAssets[1] = tokenB;
        vm.prank(trader);
        uint256[] memory pending = staticsStakers.pendingRewards(stakePositionId, rewardAssets);
        assertGt(pending[0] + pending[1], 0);

        uint256 treasuryBefore = staticsStakers.treasuryAccrued(tokenA) + staticsStakers.treasuryAccrued(tokenB);
        _swapGeneralPool(key, trader, true, 0.04 ether);
        _swapGeneralPool(key, trader, false, 0.04 ether);
        assertGt(staticsStakers.treasuryAccrued(tokenA) + staticsStakers.treasuryAccrued(tokenB), treasuryBefore);
        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenId), lp);

        uint256 creatorBefore = IERC20(tokenA).balanceOf(creator);
        uint256 creatorOwed = revenue.creatorRevenue(creator, tokenA);
        vm.prank(creator);
        (uint256 claimed,) = revenue.claimCreatorRevenue(tokenA, creator, 0);
        assertEq(claimed, creatorOwed);
        assertEq(IERC20(tokenA).balanceOf(creator) - creatorBefore, creatorOwed);

        pools.decommissionGeneralPool(poolId);
        assertTrue(pools.protocolPool(poolId).decommissioned);
        assertEq(swapFeeHook.lockedLiquidity(poolId), 0);
        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenId), lp);

        MockERC20(Currency.unwrap(key.currency0)).mint(trader, 0.01 ether);
        _approveV4Router(trader, Currency.unwrap(key.currency0));
        vm.prank(trader);
        vm.expectRevert();
        v4Router.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(0.01 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );
    }

    function testSamePairDifferentTickSpacingKeepsPolAccountingIsolated() public {
        address tokenA = _newToken("Gamma");
        address tokenB = _newToken("Delta");
        (PoolId poolLow, PoolKey memory keyLow) = _createGeneralPool(tokenA, tokenB, 10, creator);
        (PoolId poolHigh, PoolKey memory keyHigh) = _createGeneralPool(tokenA, tokenB, 60, creator);
        assertTrue(PoolId.unwrap(poolLow) != PoolId.unwrap(poolHigh));

        _mintFullRangeGeneralPosition(keyLow, lp, 5 ether);
        _mintFullRangeGeneralPosition(keyHigh, makeAddr("second-lp"), 5 ether);
        _swapGeneralPool(keyHigh, trader, true, 0.05 ether);
        _swapGeneralPool(keyHigh, trader, false, 0.05 ether);

        assertEq(swapFeeHook.lockedLiquidity(poolLow), 0);
        assertGt(swapFeeHook.lockedLiquidity(poolHigh), 0);
    }

    function testSamePairDifferentNativeFeesSwapAndAccountIndependently() public {
        address tokenA = _newToken("Fee Alpha");
        address tokenB = _newToken("Fee Beta");
        (PoolId poolLow, PoolKey memory keyLow) = _createGeneralPool(tokenA, tokenB, 500, 10, creator);
        (PoolId poolHigh, PoolKey memory keyHigh) = _createGeneralPool(tokenA, tokenB, 10_000, 10, creator);
        assertTrue(PoolId.unwrap(poolLow) != PoolId.unwrap(poolHigh));
        assertEq(keyLow.fee, 500);
        assertEq(keyHigh.fee, 10_000);

        _mintFullRangeGeneralPosition(keyLow, lp, 5 ether);
        _mintFullRangeGeneralPosition(keyHigh, makeAddr("fee-high-lp"), 5 ether);
        _swapGeneralPool(keyLow, trader, true, 0.05 ether);
        _swapGeneralPool(keyLow, trader, false, 0.05 ether);
        _swapGeneralPool(keyHigh, trader, true, 0.05 ether);
        _swapGeneralPool(keyHigh, trader, false, 0.05 ether);

        assertGt(swapFeeHook.lockedLiquidity(poolLow), 0);
        assertGt(swapFeeHook.lockedLiquidity(poolHigh), 0);
    }

    function _stakeStaticsFor(address user, address rewardA, address rewardB) private returns (uint256 positionId) {
        uint256 fee = IStaticsPositionFees(address(diamond)).positionCreationFee();
        uint256 stakeAmount = 10 ether;
        stakingAsset.mint(user, stakeAmount);
        address[] memory rewards = new address[](2);
        rewards[0] = rewardA;
        rewards[1] = rewardB;
        vm.deal(user, user.balance + fee);
        vm.startPrank(user);
        IERC20(address(stakingAsset)).approve(address(diamond), stakeAmount);
        positionId = staticsStakers.createAndStake{value: fee}(stakeAmount, user, rewards);
        vm.stopPrank();
    }
}
