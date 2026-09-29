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
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsRewardPolicy} from "../../src/interfaces/IStaticsRewardPolicy.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
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
        pools.setProtocolPoolMaintenanceConfig(
            IStaticsProtocolPools.ProtocolPoolMaintenanceConfig({
                revenueTipBps: 0, compoundTipBps: 0, twapWindow: 30 minutes, maxTickDeviation: 500
            })
        );
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
        _maintainPool(poolId, key);

        assertGt(revenue.creatorRevenue(poolId, tokenA), 0);
        assertGt(revenue.creatorRevenue(poolId, tokenB), 0);
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
        _settlePool(poolId, key);
        assertGt(staticsStakers.treasuryAccrued(tokenA) + staticsStakers.treasuryAccrued(tokenB), treasuryBefore);
        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenId), lp);

        uint256 creatorBefore = IERC20(tokenA).balanceOf(creator);
        uint256 creatorOwed = revenue.creatorRevenue(poolId, tokenA);
        vm.prank(creator);
        (uint256 claimed,) = revenue.claimCreatorRevenue(poolId, tokenA, creator, 0);
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
        _maintainPool(poolHigh, keyHigh);

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
        _maintainPool(poolLow, keyLow);
        _maintainPool(poolHigh, keyHigh);

        assertGt(swapFeeHook.lockedLiquidity(poolLow), 0);
        assertGt(swapFeeHook.lockedLiquidity(poolHigh), 0);
    }

    function testSwapTimeStakerOwnershipSurvivesDelayedFundingAndStakeTurnover() public {
        address tokenA = _newToken("Crystallized Alpha");
        address tokenB = _newToken("Crystallized Beta");
        (, PoolKey memory key) = _createGeneralPool(tokenA, tokenB, 10, creator);
        _mintFullRangeGeneralPosition(key, lp, 5 ether);

        uint256 alicePosition = _stakeStaticsFor(trader, tokenA, tokenB);
        vm.warp(block.timestamp + 25 hours);
        vm.roll(block.number + 1);
        _swapGeneralPool(key, trader, true, 0.05 ether);

        address[] memory assets = new address[](2);
        assets[0] = tokenA;
        assets[1] = tokenB;
        vm.prank(trader);
        uint256[] memory aliceBeforeExit = staticsStakers.pendingRewards(alicePosition, assets);
        assertGt(aliceBeforeExit[0] + aliceBeforeExit[1], 0, "swap did not crystallize ownership");
        assertGt(
            staticsStakers.unfundedSwapRewards(tokenA) + staticsStakers.unfundedSwapRewards(tokenB),
            0,
            "swap rewards were unexpectedly funded"
        );

        vm.prank(trader);
        staticsStakers.unstake(alicePosition, 10 ether, trader);

        address bob = makeAddr("later-staker");
        uint256 bobPosition = _stakeStaticsFor(bob, tokenA, tokenB);
        vm.warp(block.timestamp + 25 hours);
        vm.roll(block.number + 1);

        vm.prank(bob);
        uint256[] memory bobPending = staticsStakers.pendingRewards(bobPosition, assets);
        assertEq(bobPending[0] + bobPending[1], 0, "later staker captured historical rewards");

        uint256 before0 = IERC20(tokenA).balanceOf(trader);
        uint256 before1 = IERC20(tokenB).balanceOf(trader);
        uint256[] memory minimums = new uint256[](2);
        vm.prank(trader);
        uint256[] memory claimed = staticsStakers.claimRewards(alicePosition, assets, trader, minimums);
        assertEq(IERC20(tokenA).balanceOf(trader) - before0, claimed[0]);
        assertEq(IERC20(tokenB).balanceOf(trader) - before1, claimed[1]);
        assertGt(claimed[0] + claimed[1], 0);
        assertEq(staticsStakers.unfundedSwapRewards(tokenA), 0);
        assertEq(staticsStakers.unfundedSwapRewards(tokenB), 0);
    }

    function testRestrictedAssetFallsBackBeforeCrystallizationAndPreservesHistory() public {
        address tokenA = _newToken("Restricted Alpha");
        address tokenB = _newToken("Restricted Beta");
        (PoolId poolId, PoolKey memory key) = _createGeneralPool(tokenA, tokenB, 10, creator);
        _mintFullRangeGeneralPosition(key, lp, 5 ether);

        uint256 positionId = _stakeStaticsFor(trader, tokenA, tokenB);
        vm.warp(block.timestamp + 25 hours);
        vm.roll(block.number + 1);
        _swapGeneralPool(key, trader, true, 0.05 ether);

        address restricted = Currency.unwrap(key.currency0);
        address paired = Currency.unwrap(key.currency1);
        uint256 restrictedPendingBefore = _pendingReward(positionId, restricted, trader);
        uint256 pairedPendingBefore = _pendingReward(positionId, paired, trader);
        uint256 restrictedUnfundedBefore = staticsStakers.unfundedSwapRewards(restricted);
        uint256 restrictedHookPendingBefore = swapFeeHook.pendingStakerRewards(key.currency0);
        uint256 treasuryBucketBefore = swapFeeHook.pendingFeeDistribution(poolId, key.currency0).treasury;
        assertGt(restrictedPendingBefore, 0, "historical restricted entitlement missing");
        assertGt(restrictedUnfundedBefore, 0, "historical restricted backing was already settled");

        vm.prank(guardian);
        IStaticsRewardPolicy(address(diamond)).addRewardRestriction(restricted);

        _swapGeneralPool(key, trader, true, 0.05 ether);
        _swapGeneralPool(key, trader, false, 0.05 ether);

        assertFalse(staticsStakers.canAccrueStakerRewards(restricted));
        assertTrue(staticsStakers.canAccrueStakerRewards(paired));
        assertEq(swapFeeHook.pendingStakerRewards(key.currency0), restrictedHookPendingBefore);
        assertEq(staticsStakers.unfundedSwapRewards(restricted), restrictedUnfundedBefore);
        assertEq(_pendingReward(positionId, restricted, trader), restrictedPendingBefore);
        assertGt(_pendingReward(positionId, paired, trader), pairedPendingBefore);
        assertGt(swapFeeHook.pendingFeeDistribution(poolId, key.currency0).treasury, treasuryBucketBefore);

        uint256 treasuryBefore = staticsStakers.treasuryAccrued(restricted);
        pools.settleProtocolPoolRevenue(poolId, restricted);
        assertGt(staticsStakers.treasuryAccrued(restricted), treasuryBefore);
        _assertHookClaimsBacked(key.currency0);

        uint256 balanceBefore = IERC20(restricted).balanceOf(trader);
        uint256 claimed = _claimReward(positionId, restricted, trader);
        assertEq(claimed, restrictedPendingBefore);
        assertEq(IERC20(restricted).balanceOf(trader) - balanceBefore, claimed);
        _assertHookClaimsBacked(key.currency0);

        IStaticsRewardPolicy(address(diamond)).removeRewardRestriction(restricted);
        assertTrue(staticsStakers.canAccrueStakerRewards(restricted));
        uint256 resumedPendingBefore = swapFeeHook.pendingStakerRewards(key.currency0);
        _swapGeneralPool(key, trader, true, 0.05 ether);
        assertGt(swapFeeHook.pendingStakerRewards(key.currency0), resumedPendingBefore);
    }

    function testRestrictedAssetFallsBackForExactOutputInBothDirections() public {
        address tokenA = _newToken("Exact Output Alpha");
        address tokenB = _newToken("Exact Output Beta");
        (PoolId poolId, PoolKey memory key) = _createGeneralPool(tokenA, tokenB, 10, creator);
        _mintFullRangeGeneralPosition(key, lp, 5 ether);

        _stakeStaticsFor(trader, tokenA, tokenB);
        vm.warp(block.timestamp + 25 hours);
        vm.roll(block.number + 1);
        address restricted = Currency.unwrap(key.currency0);
        vm.prank(guardian);
        IStaticsRewardPolicy(address(diamond)).addRewardRestriction(restricted);

        _swapGeneralPoolExactOutput(key, trader, true, 0.005 ether);
        _swapGeneralPoolExactOutput(key, trader, false, 0.005 ether);

        assertEq(swapFeeHook.pendingStakerRewards(key.currency0), 0);
        assertGt(swapFeeHook.pendingStakerRewards(key.currency1), 0);
        assertGt(swapFeeHook.pendingFeeDistribution(poolId, key.currency0).treasury, 0);
        _assertHookClaimsBacked(key.currency0);
        _assertHookClaimsBacked(key.currency1);
    }

    function testZeroEligibleWeightAndRoundedZeroStakerShareKeepSwapsLive() public {
        address tokenA = _newToken("Zero Weight Alpha");
        address tokenB = _newToken("Zero Weight Beta");
        (PoolId poolId, PoolKey memory key) = _createGeneralPool(tokenA, tokenB, 10, creator);
        _mintFullRangeGeneralPosition(key, lp, 5 ether);

        _swapGeneralPool(key, trader, true, 0.02 ether);
        assertEq(swapFeeHook.pendingStakerRewards(key.currency0), 0);
        assertEq(swapFeeHook.pendingStakerRewards(key.currency1), 0);
        assertGt(swapFeeHook.pendingFeeDistribution(poolId, key.currency0).treasury, 0);

        _swapGeneralPool(key, trader, false, 400);
        assertEq(swapFeeHook.pendingStakerRewards(key.currency0), 0);
        assertEq(swapFeeHook.pendingStakerRewards(key.currency1), 0);
        _assertHookClaimsBacked(key.currency0);
        _assertHookClaimsBacked(key.currency1);
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

    function _swapGeneralPoolExactOutput(PoolKey memory key, address user, bool zeroForOne, uint256 amountOut) private {
        address inputToken = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        MockERC20(inputToken).mint(user, 1 ether);
        _approveV4Router(user, inputToken);
        vm.prank(user);
        v4Router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(amountOut),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    function _pendingReward(uint256 positionId, address asset, address owner) private returns (uint256 amount) {
        address[] memory assets = new address[](1);
        assets[0] = asset;
        vm.prank(owner);
        amount = staticsStakers.pendingRewards(positionId, assets)[0];
    }

    function _claimReward(uint256 positionId, address asset, address owner) private returns (uint256 amount) {
        address[] memory assets = new address[](1);
        assets[0] = asset;
        uint256[] memory minimums = new uint256[](1);
        vm.prank(owner);
        amount = staticsStakers.claimRewards(positionId, assets, owner, minimums)[0];
    }

    function _assertHookClaimsBacked(Currency currency) private view {
        uint256 liability = swapFeeHook.claimLiability(currency);
        uint256 claimId = uint256(uint160(Currency.unwrap(currency)));
        assertEq(poolManager.balanceOf(address(swapFeeHook), claimId), liability);
    }

    function _maintainPool(PoolId poolId, PoolKey memory key) private {
        vm.warp(block.timestamp + 30 minutes);
        vm.roll(block.number + 1);
        _swapGeneralPool(key, trader, true, 0.001 ether);
        pools.compoundProtocolPoolPol(poolId);
        _settlePool(poolId, key);
    }

    function _settlePool(PoolId poolId, PoolKey memory key) private {
        pools.settleProtocolPoolRevenue(poolId, Currency.unwrap(key.currency0));
        pools.settleProtocolPoolRevenue(poolId, Currency.unwrap(key.currency1));
    }
}
