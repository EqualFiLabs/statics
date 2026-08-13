// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsPosition} from "../../src/interfaces/IStaticsPosition.sol";
import {LibCustody} from "../../src/libraries/LibCustody.sol";
import {LibGlobalRewards} from "../../src/libraries/LibGlobalRewards.sol";
import {LibPosition} from "../../src/position/LibPosition.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Narrow test-only ingress for exercising the reward state machine. Production
/// fee sources call the same internal routing function after exact-delta receipt.
contract FeeAccrualHarness {
    bytes32 private constant SOURCE_ACCOUNT = keccak256("statics.test.fee.source");

    function accrueNonSwapFee(address asset, uint256 amount) external {
        uint256 received = LibCustody.pullAndReserve(SOURCE_ACCOUNT, asset, msg.sender, amount);
        require(received == amount, "incompatible token");
        LibGlobalRewards.accrueNonSwapFee(SOURCE_ACCOUNT, asset, amount);
    }

    function accrueStakerFee(address asset, uint256 amount) external {
        uint256 received = LibCustody.pullAndReserve(LibCustody.feeAccount(), asset, msg.sender, amount);
        require(received == amount, "incompatible token");
        LibGlobalRewards.accrueReservedSwapStakerFee(asset, amount);
    }
}

contract GlobalRewardsTest is StaticsTestBase {
    function testBasketFeesAccrueAgainstSingleStakingBalanceAndRemainInKind() external {
        address[] memory selectedAssets = _assets(address(assetA), address(assetB));
        stakingAsset.mint(alice, 100 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), type(uint256).max);
        uint256 positionId = globalRewards.createAndStake(100 ether, alice, selectedAssets);
        vm.stopPrank();
        _warpEligible(positionId, address(assetA), alice);

        (uint256 basketId,) = _createDefaultBasket(0.1 ether, 0);
        vm.prank(alice);
        uint256[] memory launchPending = globalRewards.pendingRewards(positionId, selectedAssets);
        assertEq(launchPending[0], 0.18 ether);
        assertEq(launchPending[1], 0.45 ether);
        assertEq(globalRewards.treasuryAccrued(address(assetA)), 0.02 ether);
        assertEq(globalRewards.treasuryAccrued(address(assetB)), 0.05 ether);

        uint256[] memory quote = baskets.quoteMint(basketId, 10 ether);
        _fundAndApprove(bob, quote[0], quote[1]);
        vm.prank(bob);
        baskets.mint(basketId, 10 ether, bob, quote);

        vm.prank(alice);
        uint256[] memory pending = globalRewards.pendingRewards(positionId, selectedAssets);
        assertEq(pending[0], 0.36 ether);
        assertEq(pending[1], 0.9 ether);
        assertEq(globalRewards.treasuryAccrued(address(assetA)), 0.04 ether);
        assertEq(globalRewards.treasuryAccrued(address(assetB)), 0.1 ether);

        uint256[] memory minimums = new uint256[](2);
        vm.prank(alice);
        uint256[] memory claimed = globalRewards.claimRewards(positionId, selectedAssets, alice, minimums);
        assertEq(claimed[0], pending[0]);
        assertEq(claimed[1], pending[1]);
        assertEq(assetA.balanceOf(alice), pending[0]);
        assertEq(assetB.balanceOf(alice), pending[1]);

        globalRewards.distributeTreasuryFees(address(assetA));
        globalRewards.distributeTreasuryFees(address(assetB));
        assertEq(assetA.balanceOf(treasury), 0.04 ether);
        assertEq(assetB.balanceOf(treasury), 0.1 ether);
    }

    function testEmptyStakeRoutesNonSwapFeeToTreasury() external {
        (uint256 basketId,) = _createDefaultBasket(0.1 ether, 0);
        assertEq(globalRewards.treasuryAccrued(address(assetA)), 0.2 ether);
        assertEq(globalRewards.treasuryAccrued(address(assetB)), 0.5 ether);

        uint256[] memory quote = baskets.quoteMint(basketId, 10 ether);
        _fundAndApprove(bob, quote[0], quote[1]);
        vm.prank(bob);
        baskets.mint(basketId, 10 ether, bob, quote);

        assertEq(globalRewards.treasuryAccrued(address(assetA)), 0.4 ether);
        assertEq(globalRewards.treasuryAccrued(address(assetB)), 1 ether);
    }

    function testStakeAndTopUpsRemainWithdrawableWhileOnlyNewStakeWaits() external {
        address[] memory selectedAssets = _asset(address(assetA));
        stakingAsset.mint(alice, 15 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), type(uint256).max);
        uint256 positionId = globalRewards.createAndStake(10 ether, alice, selectedAssets);
        globalRewards.unstake(positionId, 4 ether, alice);
        vm.stopPrank();

        vm.prank(alice);
        IStaticsGlobalRewards.RewardSelectionView memory initial =
            globalRewards.rewardSelection(positionId, address(assetA));
        assertEq(initial.actualEligibleStake, 0);
        assertEq(initial.actualPendingStake, 6 ether);
        assertEq(stakingAsset.balanceOf(alice), 9 ether);

        vm.warp(initial.eligibleAt);
        _checkpointPosition(positionId, alice);
        vm.prank(alice);
        globalRewards.stake(positionId, 5 ether);
        vm.prank(alice);
        IStaticsGlobalRewards.RewardSelectionView memory toppedUp =
            globalRewards.rewardSelection(positionId, address(assetA));
        assertEq(toppedUp.actualEligibleStake, 6 ether);
        assertEq(toppedUp.actualPendingStake, 5 ether);

        vm.prank(alice);
        globalRewards.unstake(positionId, 3 ether, alice);
        vm.prank(alice);
        IStaticsGlobalRewards.RewardSelectionView memory afterPartial =
            globalRewards.rewardSelection(positionId, address(assetA));
        assertEq(afterPartial.actualEligibleStake, 6 ether);
        assertEq(afterPartial.actualPendingStake, 2 ether);

        vm.prank(alice);
        globalRewards.unstake(positionId, 8 ether, alice);
        assertEq(stakingAsset.balanceOf(alice), 15 ether);
        assertEq(globalRewards.totalStaked(), 0);
        vm.prank(alice);
        assertEq(globalRewards.positionRewardAssets(positionId).length, 0);
    }

    function testMatureStakeKeepsEarningWhileTopUpWaits() external {
        _installFeeAccrualHarness();
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        address[] memory rewardAssets = _asset(address(reward));
        stakingAsset.mint(alice, 20 ether);
        reward.mint(alice, 2 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 20 ether);
        reward.approve(address(diamond), 2 ether);
        uint256 positionId = globalRewards.createAndStake(10 ether, alice, rewardAssets);
        vm.stopPrank();
        _warpEligible(positionId, address(reward), alice);

        vm.startPrank(alice);
        FeeAccrualHarness(address(diamond)).accrueNonSwapFee(address(reward), 1 ether);
        globalRewards.stake(positionId, 10 ether);
        FeeAccrualHarness(address(diamond)).accrueNonSwapFee(address(reward), 1 ether);
        uint256 pending = globalRewards.pendingRewards(positionId, rewardAssets)[0];
        IStaticsGlobalRewards.RewardSelectionView memory selection =
            globalRewards.rewardSelection(positionId, address(reward));
        vm.stopPrank();

        assertEq(pending, 1.8 ether);
        assertEq(selection.actualEligibleStake, 10 ether);
        assertEq(selection.actualPendingStake, 10 ether);
    }

    function testPendingOptInCannotCaptureHistoricalRewards() external {
        _installFeeAccrualHarness();
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        address[] memory rewardAssets = _asset(address(reward));
        stakingAsset.mint(alice, 10 ether);
        stakingAsset.mint(bob, 10 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), type(uint256).max);
        uint256 alicePosition = globalRewards.createAndStake(10 ether, alice, rewardAssets);
        reward.mint(alice, 3 ether);
        reward.approve(address(diamond), 3 ether);
        vm.stopPrank();
        _warpEligible(alicePosition, address(reward), alice);
        vm.startPrank(alice);
        FeeAccrualHarness(address(diamond)).accrueNonSwapFee(address(reward), 1 ether);
        vm.stopPrank();

        address[] memory noAssets = new address[](0);
        vm.startPrank(bob);
        stakingAsset.approve(address(diamond), type(uint256).max);
        uint256 bobPosition = globalRewards.createAndStake(10 ether, bob, noAssets);
        globalRewards.optInRewardAssets(bobPosition, rewardAssets);
        vm.stopPrank();

        vm.prank(bob);
        assertEq(globalRewards.pendingRewards(bobPosition, rewardAssets)[0], 0);
        vm.prank(bob);
        IStaticsGlobalRewards.RewardSelectionView memory bobSelection =
            globalRewards.rewardSelection(bobPosition, address(reward));
        assertEq(bobSelection.actualEligibleStake, 0);
        assertEq(bobSelection.actualPendingStake, 10 ether);

        vm.prank(alice);
        FeeAccrualHarness(address(diamond)).accrueNonSwapFee(address(reward), 1 ether);
        vm.prank(alice);
        assertEq(globalRewards.pendingRewards(alicePosition, rewardAssets)[0], 1.8 ether);
        vm.prank(bob);
        assertEq(globalRewards.pendingRewards(bobPosition, rewardAssets)[0], 0);

        vm.warp(bobSelection.eligibleAt);
        vm.prank(alice);
        FeeAccrualHarness(address(diamond)).accrueNonSwapFee(address(reward), 1 ether);
        vm.prank(alice);
        assertEq(globalRewards.pendingRewards(alicePosition, rewardAssets)[0], 2.25 ether);
        vm.prank(bob);
        assertEq(globalRewards.pendingRewards(bobPosition, rewardAssets)[0], 0.45 ether);
    }

    function testOptOutPreservesEarnedRewardsAndStopsFutureAccrual() external {
        _installFeeAccrualHarness();
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        address[] memory rewardAssets = _asset(address(reward));
        stakingAsset.mint(alice, 10 ether);
        reward.mint(alice, 2 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), type(uint256).max);
        reward.approve(address(diamond), type(uint256).max);
        uint256 positionId = globalRewards.createAndStake(10 ether, alice, rewardAssets);
        vm.stopPrank();
        _warpEligible(positionId, address(reward), alice);
        vm.startPrank(alice);
        FeeAccrualHarness(address(diamond)).accrueNonSwapFee(address(reward), 1 ether);
        globalRewards.optOutRewardAssets(positionId, rewardAssets);
        FeeAccrualHarness(address(diamond)).accrueNonSwapFee(address(reward), 1 ether);
        uint256[] memory pending = globalRewards.pendingRewards(positionId, rewardAssets);
        vm.stopPrank();

        assertEq(pending[0], 0.9 ether);
        assertEq(globalRewards.treasuryAccrued(address(reward)), 1.1 ether);
        assertFalse(globalRewards.canAccrueStakerRewards(address(reward)));
        (address[] memory retained,) = positionPortfolio.globalRewardAssetsOfPosition(positionId, 0, 100);
        assertEq(retained.length, 1);
        assertEq(retained[0], address(reward));

        vm.prank(alice);
        globalRewards.claimRewards(positionId, rewardAssets, alice, new uint256[](1));
        (address[] memory cleared,) = positionPortfolio.globalRewardAssetsOfPosition(positionId, 0, 100);
        assertEq(cleared.length, 0);
    }

    function testEachPositionMaySelectSixtyFourAcrossMoreThanSixtyFourGlobalAssets() external {
        address[] memory aliceAssets = new address[](64);
        address[] memory bobAssets = new address[](64);
        for (uint256 i; i < 64; ++i) {
            aliceAssets[i] = address(new MockERC20("Alice Reward", "AR", 18));
            bobAssets[i] = address(new MockERC20("Bob Reward", "BR", 18));
        }

        stakingAsset.mint(alice, 1 ether);
        stakingAsset.mint(bob, 1 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 1 ether);
        uint256 alicePosition = globalRewards.createAndStake(1 ether, alice, aliceAssets);
        vm.stopPrank();
        vm.startPrank(bob);
        stakingAsset.approve(address(diamond), 1 ether);
        uint256 bobPosition = globalRewards.createAndStake(1 ether, bob, bobAssets);
        vm.stopPrank();

        vm.prank(alice);
        assertEq(globalRewards.positionRewardAssets(alicePosition).length, 64);
        vm.prank(bob);
        assertEq(globalRewards.positionRewardAssets(bobPosition).length, 64);
        assertEq(globalRewards.rewardAsset(aliceAssets[0]).actualEligibleStake, 0);
        assertEq(globalRewards.rewardAsset(aliceAssets[0]).actualPendingStake, 1 ether);
        assertEq(globalRewards.rewardAsset(bobAssets[63]).actualEligibleStake, 0);
        assertEq(globalRewards.rewardAsset(bobAssets[63]).actualPendingStake, 1 ether);

        address[] memory extra = _asset(address(new MockERC20("Extra Reward", "XR", 18)));
        vm.expectRevert(abi.encodeWithSelector(LibGlobalRewards.RewardAssetLimitExceeded.selector, alicePosition));
        vm.prank(alice);
        globalRewards.optInRewardAssets(alicePosition, extra);

        vm.warp(block.timestamp + 60 days);
        _checkpointPosition(alicePosition, alice);
        vm.prank(alice);
        globalRewards.unstake(alicePosition, 1 ether, alice);
        vm.prank(alice);
        assertEq(globalRewards.positionRewardAssets(alicePosition).length, 0);
    }

    function testHistoricalClaimAssetDoesNotConsumeActiveSelectionCapacity() external {
        _installFeeAccrualHarness();
        address[] memory assets = new address[](64);
        for (uint256 i; i < assets.length; ++i) {
            assets[i] = address(new MockERC20("Reward", "RWD", 18));
        }
        stakingAsset.mint(alice, 1 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 1 ether);
        uint256 positionId = globalRewards.createAndStake(1 ether, alice, assets);
        vm.stopPrank();
        _warpEligible(positionId, assets[0], alice);

        MockERC20(assets[0]).mint(alice, 1 ether);
        vm.startPrank(alice);
        IERC20(assets[0]).approve(address(diamond), 1 ether);
        FeeAccrualHarness(address(diamond)).accrueNonSwapFee(assets[0], 1 ether);
        globalRewards.optOutRewardAssets(positionId, _asset(assets[0]));
        address extra = address(new MockERC20("Extra", "X", 18));
        globalRewards.optInRewardAssets(positionId, _asset(extra));
        vm.stopPrank();

        vm.prank(alice);
        assertEq(globalRewards.positionRewardAssets(positionId).length, 64);
        (address[] memory unionAssets,) = positionPortfolio.globalRewardAssetsOfPosition(positionId, 0, 100);
        assertEq(unionAssets.length, 65);
    }

    function testFullUnstakeClearsSelectionsButRetainsClaimableRewards() external {
        _installFeeAccrualHarness();
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        address[] memory rewardAssets = _asset(address(reward));
        stakingAsset.mint(alice, 10 ether);
        reward.mint(alice, 1 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 10 ether);
        reward.approve(address(diamond), 1 ether);
        uint256 positionId = globalRewards.createAndStake(10 ether, alice, rewardAssets);
        vm.stopPrank();
        _warpEligible(positionId, address(reward), alice);
        vm.startPrank(alice);
        FeeAccrualHarness(address(diamond)).accrueNonSwapFee(address(reward), 1 ether);
        globalRewards.unstake(positionId, 10 ether, alice);
        address[] memory selected = globalRewards.positionRewardAssets(positionId);
        uint256[] memory pending = globalRewards.pendingRewards(positionId, rewardAssets);
        vm.stopPrank();

        assertEq(selected.length, 0);
        assertEq(pending[0], 0.9 ether);
        assertEq(globalRewards.rewardAsset(address(reward)).actualEligibleStake, 0);
        assertFalse(globalRewards.canAccrueStakerRewards(address(reward)));
        (address[] memory retained,) = positionPortfolio.globalRewardAssetsOfPosition(positionId, 0, 100);
        assertEq(retained.length, 1);

        vm.prank(alice);
        globalRewards.claimRewards(positionId, rewardAssets, alice, new uint256[](1));
        (address[] memory cleared,) = positionPortfolio.globalRewardAssetsOfPosition(positionId, 0, 100);
        assertEq(cleared.length, 0);
    }

    function testTransferKeepsCrystallizedClaimInsidePosition() external {
        _installFeeAccrualHarness();
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        address[] memory rewardAssets = _asset(address(reward));
        stakingAsset.mint(alice, 10 ether);
        reward.mint(alice, 1 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 10 ether);
        reward.approve(address(diamond), 1 ether);
        uint256 positionId = globalRewards.createAndStake(10 ether, alice, rewardAssets);
        vm.stopPrank();
        _warpEligible(positionId, address(reward), alice);
        vm.startPrank(alice);
        FeeAccrualHarness(address(diamond)).accrueNonSwapFee(address(reward), 1 ether);
        globalRewards.unstake(positionId, 10 ether, alice);
        IERC721(address(diamond)).transferFrom(alice, bob, positionId);
        vm.stopPrank();

        IStaticsPosition positions = IStaticsPosition(address(diamond));
        assertTrue(positions.isLegActive(positionId, LibPosition.stakingLegKey(address(diamond))));
        vm.prank(bob);
        assertEq(globalRewards.pendingRewards(positionId, rewardAssets)[0], 0.9 ether);
        vm.prank(bob);
        globalRewards.claimRewards(positionId, rewardAssets, bob, new uint256[](1));
        assertEq(reward.balanceOf(bob), 0.9 ether);
        assertFalse(positions.isLegActive(positionId, LibPosition.stakingLegKey(address(diamond))));
        vm.prank(bob);
        positions.closePosition(positionId);
        assertFalse(positions.positionState(positionId).exists);
    }

    function testTransferPreservesUnsettledRewardsAndRewardBooks() external {
        _installFeeAccrualHarness();
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        address[] memory rewardAssets = _asset(address(reward));
        stakingAsset.mint(alice, 10 ether);
        reward.mint(alice, 1 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 10 ether);
        reward.approve(address(diamond), 1 ether);
        uint256 positionId = globalRewards.createAndStake(10 ether, alice, rewardAssets);
        vm.stopPrank();
        _warpEligible(positionId, address(reward), alice);
        vm.prank(alice);
        FeeAccrualHarness(address(diamond)).accrueNonSwapFee(address(reward), 1 ether);

        vm.prank(alice);
        uint256 pendingBefore = globalRewards.pendingRewards(positionId, rewardAssets)[0];
        IStaticsGlobalRewards.RewardAssetView memory bookBefore = globalRewards.rewardAsset(address(reward));
        vm.prank(alice);
        IStaticsGlobalRewards.RewardSelectionView memory selectionBefore =
            globalRewards.rewardSelection(positionId, address(reward));

        vm.prank(alice);
        IERC721(address(diamond)).transferFrom(alice, bob, positionId);

        IStaticsGlobalRewards.RewardAssetView memory bookAfter = globalRewards.rewardAsset(address(reward));
        vm.prank(bob);
        IStaticsGlobalRewards.RewardSelectionView memory selectionAfter =
            globalRewards.rewardSelection(positionId, address(reward));
        vm.prank(bob);
        assertEq(globalRewards.pendingRewards(positionId, rewardAssets)[0], pendingBefore);
        assertEq(keccak256(abi.encode(bookAfter)), keccak256(abi.encode(bookBefore)));
        assertEq(keccak256(abi.encode(selectionAfter)), keccak256(abi.encode(selectionBefore)));

        vm.prank(alice);
        vm.expectRevert();
        globalRewards.pendingRewards(positionId, rewardAssets);
        vm.prank(bob);
        globalRewards.claimRewards(positionId, rewardAssets, bob, new uint256[](1));
        assertEq(reward.balanceOf(bob), pendingBefore);
    }

    function testOptInReactivatesAnEmptyPositionStakingLeg() external {
        address[] memory noAssets = new address[](0);
        stakingAsset.mint(alice, 1 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 1 ether);
        uint256 positionId = globalRewards.createAndStake(1 ether, alice, noAssets);
        globalRewards.unstake(positionId, 1 ether, alice);
        vm.stopPrank();

        IStaticsPosition positions = IStaticsPosition(address(diamond));
        assertFalse(positions.isLegActive(positionId, LibPosition.stakingLegKey(address(diamond))));

        vm.prank(alice);
        globalRewards.optInRewardAssets(positionId, _asset(address(assetA)));

        assertTrue(positions.isLegActive(positionId, LibPosition.stakingLegKey(address(diamond))));
    }

    function testZeroStakeOptInChurnCannotChangeIndexRounding() external {
        _installFeeAccrualHarness();
        MockERC20 churnedReward = new MockERC20("Churned Reward", "CR", 0);
        MockERC20 controlReward = new MockERC20("Control Reward", "CTR", 0);
        address[] memory selectedAssets = _assets(address(churnedReward), address(controlReward));
        uint256 largeStake = 2 * LibGlobalRewards.RAY;

        stakingAsset.mint(alice, largeStake);
        churnedReward.mint(alice, 4);
        controlReward.mint(alice, 4);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), largeStake);
        churnedReward.approve(address(diamond), 4);
        controlReward.approve(address(diamond), 4);
        uint256 stakerPosition = globalRewards.createAndStake(largeStake, alice, selectedAssets);
        vm.stopPrank();
        _warpEligible(stakerPosition, address(churnedReward), alice);
        vm.startPrank(alice);
        FeeAccrualHarness(address(diamond)).accrueNonSwapFee(address(churnedReward), 2);
        FeeAccrualHarness(address(diamond)).accrueNonSwapFee(address(controlReward), 2);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 emptyPosition = IStaticsPosition(address(diamond)).createPosition(bob);
        globalRewards.optInRewardAssets(emptyPosition, _asset(address(churnedReward)));
        globalRewards.optOutRewardAssets(emptyPosition, _asset(address(churnedReward)));
        vm.stopPrank();

        vm.startPrank(alice);
        FeeAccrualHarness(address(diamond)).accrueNonSwapFee(address(churnedReward), 2);
        FeeAccrualHarness(address(diamond)).accrueNonSwapFee(address(controlReward), 2);
        uint256[] memory pending = globalRewards.pendingRewards(stakerPosition, selectedAssets);
        vm.stopPrank();

        IStaticsGlobalRewards.RewardAssetView memory churned = globalRewards.rewardAsset(address(churnedReward));
        IStaticsGlobalRewards.RewardAssetView memory control = globalRewards.rewardAsset(address(controlReward));
        assertEq(churned.indexRay, control.indexRay);
        assertEq(churned.indexedReserve, control.indexedReserve);
        assertEq(pending[0], pending[1]);
        assertEq(churned.indexRemainder, control.indexRemainder);
        assertEq(pending[0], 2);

        vm.prank(alice);
        globalRewards.optOutRewardAssets(stakerPosition, selectedAssets);
        assertEq(globalRewards.treasuryAccrued(address(churnedReward)), 2);
        assertEq(globalRewards.treasuryAccrued(address(controlReward)), 2);
    }

    function testPerAssetIndexCarriesDivisionRemainder() external {
        _installFeeAccrualHarness();
        MockERC20 reward = new MockERC20("Reward", "RWD", 0);
        uint256 stakeAmount = 3 * LibGlobalRewards.RAY;
        stakingAsset.mint(alice, stakeAmount);
        reward.mint(alice, 3);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), stakeAmount);
        reward.approve(address(diamond), 3);
        uint256 positionId = globalRewards.createAndStake(stakeAmount, alice, _asset(address(reward)));
        vm.stopPrank();
        _warpEligible(positionId, address(reward), alice);

        vm.startPrank(alice);
        FeeAccrualHarness(address(diamond)).accrueStakerFee(address(reward), 1);
        IStaticsGlobalRewards.RewardAssetView memory first = globalRewards.rewardAsset(address(reward));
        FeeAccrualHarness(address(diamond)).accrueStakerFee(address(reward), 1);
        IStaticsGlobalRewards.RewardAssetView memory second = globalRewards.rewardAsset(address(reward));
        FeeAccrualHarness(address(diamond)).accrueStakerFee(address(reward), 1);
        IStaticsGlobalRewards.RewardAssetView memory third = globalRewards.rewardAsset(address(reward));
        uint256 pending = globalRewards.pendingRewards(positionId, _asset(address(reward)))[0];
        vm.stopPrank();

        assertEq(first.indexRay, 0);
        assertEq(first.indexRemainder, LibGlobalRewards.RAY);
        assertEq(second.indexRay, 0);
        assertEq(second.indexRemainder, 2 * LibGlobalRewards.RAY);
        assertEq(third.indexRay, 1);
        assertEq(third.indexRemainder, 0);
        assertEq(pending, 3);
    }

    function testPerAssetIndexCarriesDivisionRemainderAcrossDenominatorChange() external {
        _installFeeAccrualHarness();
        MockERC20 reward = new MockERC20("Reward", "RWD", 0);
        uint256 stakeAmount = 3 * LibGlobalRewards.RAY;
        stakingAsset.mint(alice, stakeAmount);
        reward.mint(alice, 3);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), stakeAmount);
        reward.approve(address(diamond), 3);
        uint256 positionId = globalRewards.createAndStake(stakeAmount, alice, _asset(address(reward)));
        vm.stopPrank();
        _warpEligible(positionId, address(reward), alice);

        vm.startPrank(alice);
        FeeAccrualHarness(address(diamond)).accrueStakerFee(address(reward), 2);
        assertEq(globalRewards.rewardAsset(address(reward)).indexRemainder, 2 * LibGlobalRewards.RAY);
        globalRewards.unstake(positionId, 2 * LibGlobalRewards.RAY, alice);
        FeeAccrualHarness(address(diamond)).accrueStakerFee(address(reward), 1);
        uint256 pending = globalRewards.pendingRewards(positionId, _asset(address(reward)))[0];
        vm.stopPrank();

        IStaticsGlobalRewards.RewardAssetView memory book = globalRewards.rewardAsset(address(reward));
        assertEq(book.actualEligibleStake, LibGlobalRewards.RAY);
        assertEq(book.effectiveEligibleWeight, LibGlobalRewards.RAY);
        assertEq(book.indexRay, 3);
        assertEq(book.indexRemainder, 0);
        assertEq(pending, 3);
    }

    function testIndexRemainderClearsWhenEligibleCohortExits() external {
        _installFeeAccrualHarness();
        MockERC20 reward = new MockERC20("Reward", "RWD", 0);
        uint256 stakeAmount = 3 * LibGlobalRewards.RAY;
        stakingAsset.mint(alice, stakeAmount);
        reward.mint(alice, 1);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), stakeAmount);
        reward.approve(address(diamond), 1);
        uint256 positionId = globalRewards.createAndStake(stakeAmount, alice, _asset(address(reward)));
        vm.stopPrank();
        _warpEligible(positionId, address(reward), alice);

        vm.startPrank(alice);
        FeeAccrualHarness(address(diamond)).accrueStakerFee(address(reward), 1);
        assertEq(globalRewards.rewardAsset(address(reward)).indexRemainder, LibGlobalRewards.RAY);
        globalRewards.unstake(positionId, stakeAmount, alice);
        vm.stopPrank();

        IStaticsGlobalRewards.RewardAssetView memory book = globalRewards.rewardAsset(address(reward));
        assertEq(book.indexRemainder, 0);
        assertEq(book.indexedReserve, 0);
        assertEq(globalRewards.treasuryAccrued(address(reward)), 1);
    }

    function testEligibilityRoundsUpAndNeverBeginsBeforeTwentyFourHours() external {
        vm.warp(30 days + 17 minutes);
        stakingAsset.mint(alice, 1 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 1 ether);
        uint256 positionId = globalRewards.createAndStake(1 ether, alice, _asset(address(assetA)));
        IStaticsGlobalRewards.RewardSelectionView memory selection =
            globalRewards.rewardSelection(positionId, address(assetA));
        vm.stopPrank();

        assertGe(selection.eligibleAt, block.timestamp + 24 hours);
        assertLt(selection.eligibleAt, block.timestamp + 25 hours);
        vm.warp(selection.eligibleAt - 1);
        assertFalse(globalRewards.canAccrueStakerRewards(address(assetA)));
        vm.warp(selection.eligibleAt);
        assertTrue(globalRewards.canAccrueStakerRewards(address(assetA)));
    }

    function testRepeatedPendingTopUpPreservesWeightedTimeCredit() external {
        vm.warp(30 days);
        stakingAsset.mint(alice, 20 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 20 ether);
        uint256 positionId = globalRewards.createAndStake(10 ether, alice, _asset(address(assetA)));
        vm.warp(block.timestamp + 12 hours);
        globalRewards.stake(positionId, 10 ether);
        IStaticsGlobalRewards.RewardSelectionView memory selection =
            globalRewards.rewardSelection(positionId, address(assetA));
        vm.stopPrank();

        assertEq(selection.actualEligibleStake, 0);
        assertEq(selection.actualPendingStake, 20 ether);
        assertEq(selection.eligibleAt, 30 days + 30 hours);
    }

    function testWeightedTimeCreditMarksEarlyMaturityBucketForCheckpoint() external {
        vm.warp(30 days);
        stakingAsset.mint(alice, 101 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 101 ether);
        uint256 positionId = globalRewards.createAndStake(100 ether, alice, _asset(address(assetA)));
        vm.warp(block.timestamp + 23 hours);
        globalRewards.checkpointRewardAssets(_asset(address(assetA)));
        globalRewards.stake(positionId, 1 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours);
        assertTrue(globalRewards.rewardBookNeedsCheckpoint(address(assetA)));

        globalRewards.checkpointRewardAssets(_asset(address(assetA)));
        assertFalse(globalRewards.rewardBookNeedsCheckpoint(address(assetA)));
    }

    function testFuzzPendingTopUpUsesWeightedTimeCredit(uint256 initialAmount, uint256 addedAmount, uint256 elapsed)
        external
    {
        initialAmount = bound(initialAmount, 1, 1e24);
        addedAmount = bound(addedAmount, 1, 1e24);
        elapsed = bound(elapsed, 0, 24 hours - 1);
        uint256 startedAt = 30 days;
        vm.warp(startedAt);
        stakingAsset.mint(alice, initialAmount + addedAmount);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), initialAmount + addedAmount);
        uint256 positionId = globalRewards.createAndStake(initialAmount, alice, _asset(address(assetA)));
        vm.warp(startedAt + elapsed);
        globalRewards.stake(positionId, addedAmount);
        IStaticsGlobalRewards.RewardSelectionView memory selection =
            globalRewards.rewardSelection(positionId, address(assetA));
        vm.stopPrank();

        uint256 weightedCredit = Math.mulDiv(initialAmount, elapsed, initialAmount + addedAmount);
        uint256 rawMaturity = startedAt + elapsed - weightedCredit + 24 hours;
        uint256 expectedEligibleAt = Math.ceilDiv(rawMaturity, 1 hours) * 1 hours;
        assertEq(selection.actualEligibleStake, 0);
        assertEq(selection.actualPendingStake, initialAmount + addedAmount);
        assertEq(selection.eligibleAt, expectedEligibleAt);
    }

    function testLongIdlePeriodRollsMaturityBeforeNextFee() external {
        _installFeeAccrualHarness();
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        address[] memory rewardAssets = _asset(address(reward));
        stakingAsset.mint(alice, 10 ether);
        reward.mint(alice, 1 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 10 ether);
        reward.approve(address(diamond), 1 ether);
        uint256 positionId = globalRewards.createAndStake(10 ether, alice, rewardAssets);
        vm.warp(block.timestamp + 60 days);
        assertTrue(globalRewards.canAccrueStakerRewards(address(reward)));
        FeeAccrualHarness(address(diamond)).accrueNonSwapFee(address(reward), 1 ether);
        uint256 pending = globalRewards.pendingRewards(positionId, rewardAssets)[0];
        vm.stopPrank();

        assertEq(pending, 0.9 ether);
        assertEq(globalRewards.rewardAsset(address(reward)).actualEligibleStake, 10 ether);
        assertEq(globalRewards.rewardAsset(address(reward)).actualPendingStake, 0);
    }

    function _installFeeAccrualHarness() private returns (FeeAccrualHarness harness) {
        harness = new FeeAccrualHarness();
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = FeeAccrualHarness.accrueNonSwapFee.selector;
        selectors[1] = FeeAccrualHarness.accrueStakerFee.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(harness), action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
    }

    function _asset(address asset) private pure returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = asset;
    }

    function _assets(address first, address second) private pure returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = first;
        assets[1] = second;
    }

    function _warpEligible(uint256 positionId, address asset, address owner) private {
        vm.prank(owner);
        uint40 eligibleAt = globalRewards.rewardSelection(positionId, asset).eligibleAt;
        vm.warp(eligibleAt);
        _checkpointPosition(positionId, owner);
    }

    function _checkpointPosition(uint256 positionId, address owner) private {
        vm.prank(owner);
        address[] memory assets = globalRewards.positionRewardAssets(positionId);
        for (uint256 offset; offset < assets.length; offset += 8) {
            uint256 count = assets.length - offset;
            if (count > 8) count = 8;
            address[] memory batch = new address[](count);
            for (uint256 i; i < count; ++i) {
                batch[i] = assets[offset + i];
            }
            globalRewards.checkpointRewardAssets(batch);
        }
    }
}
