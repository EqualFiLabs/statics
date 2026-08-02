// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GlobalRewardsFacet} from "../../src/facets/GlobalRewardsFacet.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {LibCustody} from "../../src/libraries/LibCustody.sol";
import {LibGlobalRewards} from "../../src/libraries/LibGlobalRewards.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Narrow test-only ingress for exercising the registry state machine. Production
/// fee sources call the same internal routing function after exact-delta receipt.
contract FeeAccrualHarness {
    bytes32 private constant SOURCE_ACCOUNT = keccak256("statics.test.fee.source");

    function accrueNonSwapFee(address asset, uint256 amount) external {
        uint256 received = LibCustody.pullAndReserve(SOURCE_ACCOUNT, asset, msg.sender, amount);
        require(received == amount, "incompatible token");
        LibGlobalRewards.accrueNonSwapFee(SOURCE_ACCOUNT, asset, amount);
    }
}

contract GlobalRewardsTest is StaticsTestBase {
    function testBasketFeesAccrueAgainstSingleStakingBalanceAndRemainInKind() external {
        stakingAsset.mint(alice, 100 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), type(uint256).max);
        uint256 positionId = globalRewards.createAndStake(100 ether, alice);
        vm.stopPrank();

        (uint256 basketId,) = _createDefaultBasket(0.1 ether, 0);
        uint256[] memory quote = baskets.quoteMint(basketId, 10 ether);
        _fundAndApprove(bob, quote[0], quote[1]);
        vm.prank(bob);
        baskets.mint(basketId, 10 ether, bob, quote);

        address[] memory assets = new address[](2);
        assets[0] = address(assetA);
        assets[1] = address(assetB);
        vm.prank(alice);
        uint256[] memory pending = globalRewards.pendingRewards(positionId, assets);
        assertEq(pending[0], 0.18 ether);
        assertEq(pending[1], 0.45 ether);
        assertEq(globalRewards.treasuryAccrued(address(assetA)), 0.02 ether);
        assertEq(globalRewards.treasuryAccrued(address(assetB)), 0.05 ether);

        uint256[] memory minimums = new uint256[](2);
        vm.prank(alice);
        uint256[] memory claimed = globalRewards.claimRewards(positionId, assets, alice, minimums);
        assertEq(claimed[0], pending[0]);
        assertEq(claimed[1], pending[1]);
        assertEq(assetA.balanceOf(alice), pending[0]);
        assertEq(assetB.balanceOf(alice), pending[1]);

        globalRewards.distributeTreasuryFees(address(assetA));
        globalRewards.distributeTreasuryFees(address(assetB));
        assertEq(assetA.balanceOf(treasury), 0.02 ether);
        assertEq(assetB.balanceOf(treasury), 0.05 ether);
    }

    function testEmptyStakeRoutesNonSwapFeeToTreasury() external {
        (uint256 basketId,) = _createDefaultBasket(0.1 ether, 0);
        uint256[] memory quote = baskets.quoteMint(basketId, 10 ether);
        _fundAndApprove(bob, quote[0], quote[1]);
        vm.prank(bob);
        baskets.mint(basketId, 10 ether, bob, quote);

        assertEq(globalRewards.treasuryAccrued(address(assetA)), 0.2 ether);
        assertEq(globalRewards.treasuryAccrued(address(assetB)), 0.5 ether);
    }

    function testStakeIncreaseRestartsCooldownAndUnstakeSettlesRewards() external {
        stakingAsset.mint(alice, 11 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), type(uint256).max);
        uint256 positionId = globalRewards.createAndStake(10 ether, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 24 hours);
        vm.prank(alice);
        globalRewards.stake(positionId, 1 ether);
        vm.prank(alice);
        uint256 availableAt = globalRewards.stakePosition(positionId).unstakeAvailableAt;
        vm.expectRevert(
            abi.encodeWithSelector(GlobalRewardsFacet.UnstakeCooldownActive.selector, availableAt)
        );
        vm.prank(alice);
        globalRewards.unstake(positionId, 1 ether, alice);

        vm.warp(availableAt);
        vm.prank(alice);
        globalRewards.unstake(positionId, 11 ether, alice);
        assertEq(stakingAsset.balanceOf(alice), 11 ether);
        assertEq(globalRewards.totalStaked(), 0);
    }

    function testGovernanceCanEvictASettledSlotForAnyQueuedAsset() external {
        _installFeeAccrualHarness();
        stakingAsset.mint(alice, 1 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), type(uint256).max);
        uint256 positionId = globalRewards.createAndStake(1 ether, alice);
        vm.stopPrank();

        address[] memory rewardAssets = new address[](65);
        for (uint256 i; i < rewardAssets.length; ++i) {
            MockERC20 reward = new MockERC20("Reward", "RWD", 18);
            rewardAssets[i] = address(reward);
            reward.mint(alice, 1 ether);
            vm.startPrank(alice);
            reward.approve(address(diamond), 1 ether);
            FeeAccrualHarness(address(diamond)).accrueNonSwapFee(address(reward), 1 ether);
            vm.stopPrank();
        }

        assertTrue(globalRewards.queuedRewardAsset(rewardAssets[64]));
        (address[] memory queuedAssets, bool[] memory queuedStates, uint256 queueLength) =
            globalRewards.rewardAssetQueue(0, 1);
        assertEq(queueLength, 1);
        assertEq(queuedAssets.length, 1);
        assertEq(queuedAssets[0], rewardAssets[64]);
        assertTrue(queuedStates[0]);
        (queuedAssets, queuedStates, queueLength) = globalRewards.rewardAssetQueue(1, type(uint256).max);
        assertEq(queueLength, 1);
        assertEq(queuedAssets.length, 0);
        assertEq(queuedStates.length, 0);
        (uint256 firstSlot, bool registered) = globalRewards.rewardAssetSlot(rewardAssets[0]);
        assertTrue(registered);
        globalRewards.beginRewardAssetRetirement(firstSlot);
        (uint256 nextPositionId, bool complete) = globalRewards.settleRetiringRewardAsset(firstSlot, 10);
        assertTrue(complete);
        assertEq(nextPositionId, 2);
        globalRewards.finalizeRewardAssetRetirement(firstSlot, rewardAssets[64]);

        IStaticsGlobalRewards.RewardAssetView memory replacement = globalRewards.rewardAsset(firstSlot);
        assertEq(replacement.asset, rewardAssets[64]);
        assertEq(uint256(replacement.status), uint256(IStaticsGlobalRewards.RewardAssetStatus.Active));
        assertEq(replacement.generation, 2);
        assertFalse(globalRewards.queuedRewardAsset(rewardAssets[64]));
        (queuedAssets, queuedStates, queueLength) = globalRewards.rewardAssetQueue(0, 1);
        assertEq(queueLength, 1);
        assertEq(queuedAssets[0], rewardAssets[64]);
        assertFalse(queuedStates[0]);

        address[] memory claimAssets = new address[](1);
        claimAssets[0] = rewardAssets[0];
        uint256[] memory minimums = new uint256[](1);
        vm.prank(alice);
        uint256[] memory claimed = globalRewards.claimRewards(positionId, claimAssets, alice, minimums);
        assertEq(claimed[0], 0.9 ether);

        MockERC20 replacementToken = MockERC20(rewardAssets[64]);
        replacementToken.mint(alice, 1 ether);
        vm.startPrank(alice);
        replacementToken.approve(address(diamond), 1 ether);
        FeeAccrualHarness(address(diamond)).accrueNonSwapFee(address(replacementToken), 1 ether);
        claimAssets[0] = address(replacementToken);
        uint256[] memory pending = globalRewards.pendingRewards(positionId, claimAssets);
        vm.stopPrank();
        assertEq(pending[0], 0.9 ether);
    }

    function _installFeeAccrualHarness() private returns (FeeAccrualHarness harness) {
        harness = new FeeAccrualHarness();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = FeeAccrualHarness.accrueNonSwapFee.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(harness),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors
        });
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
    }
}
