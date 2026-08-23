// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {GenesisLaunchDistributor} from "../../src/genesis/GenesisLaunchDistributor.sol";
import {StaticsFeeReceiver} from "../../src/genesis/StaticsFeeReceiver.sol";
import {IGenesisLaunchDistributor} from "../../src/interfaces/IGenesisLaunchDistributor.sol";
import {FormalFeeSource, FormalGenesisEnvironment, FormalWrappedNative} from "./mocks/FormalGenesisMocks.sol";

contract GenesisLaunchDistributorHalmosTest is SymTest, FormalGenesisEnvironment {
    uint16 private constant GENESIS_SHARE_BPS = 7_500;

    FormalWrappedNative private weth;
    FormalFeeSource private feeSource;
    StaticsFeeReceiver private feeReceiver;
    GenesisLaunchDistributor private distributor;
    address private alice;
    address private bob;

    function setUp() public {
        alice = makeAddr("formalAlice");
        bob = makeAddr("formalBob");
        _deployGenesis(block.timestamp + 30 days);
        weth = new FormalWrappedNative();
        feeSource = new FormalFeeSource();
        feeReceiver = new StaticsFeeReceiver(address(feeSource), address(weth), address(this));
        feeSource.configure(statics, weth, address(feeReceiver));
        feeReceiver.bindMarket(address(statics), keccak256("formal-distributor-pool"));
        distributor =
            new GenesisLaunchDistributor(feeReceiver, genesis, registry, treasury, address(this), GENESIS_SHARE_BPS);
        feeReceiver.proposeDistributor(address(distributor));
        distributor.acceptFeeReceiverRole();
        registry.proposeConsumer(address(distributor));
        distributor.acceptActivationConsumer();

        statics.mint(alice, 1_000_000 ether);
        _acquire(1, alice);
        vm.prank(alice);
        distributor.registerGenesis(1);
    }

    function check_globalRewardConservation(uint128 staticsAmount, uint128 wethAmount) public {
        _queue(staticsAmount, wethAmount);
        distributor.accrue();
        _assertConserved(address(statics), staticsAmount);
        _assertConserved(address(weth), wethAmount);
        assertEq(distributor.totalWeight(), distributor.effectiveWeight(1));
    }

    function check_transferAssignsPreCheckpointRewardsToPreviousOwner(
        uint128 preTransferReward,
        uint128 postTransferReward
    ) public {
        _queue(preTransferReward, 0);
        feeReceiver.harvest();
        uint256 expectedPreTransfer = Math.mulDiv(preTransferReward, GENESIS_SHARE_BPS, 10_000);

        vm.prank(alice);
        genesis.transferFrom(alice, bob, 1);
        assertEq(distributor.ownerClaimable(alice, address(statics)), expectedPreTransfer);
        assertEq(distributor.pendingGenesis(1, address(statics)), 0);
        assertEq(registry.tierOf(1), 0);

        _queue(postTransferReward, 0);
        distributor.accrue();
        uint256 expectedPostTransfer = Math.mulDiv(postTransferReward, GENESIS_SHARE_BPS, 10_000);
        assertEq(distributor.ownerClaimable(alice, address(statics)), expectedPreTransfer);
        assertEq(distributor.pendingGenesis(1, address(statics)), expectedPostTransfer);
        _assertConserved(address(statics), uint256(preTransferReward) + postTransferReward);
    }

    function check_activationSettlesAtPreviousWeight(uint128 reward, uint256 targetTier) public {
        vm.assume(targetTier >= 1 && targetTier <= registry.MAX_TIER());
        _queue(reward, 0);
        feeReceiver.harvest();
        uint256 expectedGenesisReward = Math.mulDiv(reward, GENESIS_SHARE_BPS, 10_000);
        uint256 activationCost = _activationCost(targetTier);
        uint256 treasuryBefore = statics.balanceOf(treasury);

        vm.startPrank(alice);
        statics.approve(address(registry), activationCost);
        registry.activate(1, uint8(targetTier));
        vm.stopPrank();

        assertEq(distributor.pendingGenesis(1, address(statics)), expectedGenesisReward);
        assertEq(distributor.effectiveWeight(1), registry.multiplierForTier(uint8(targetTier)));
        assertEq(registry.tierOf(1), targetTier);
        assertEq(statics.balanceOf(treasury) - treasuryBefore, activationCost);
        _assertConserved(address(statics), reward);
    }

    function check_claimCannotExceedAllocatedReward(uint128 reward) public {
        vm.assume(reward > 0);
        _queue(reward, 0);
        distributor.accrue();
        uint256 pending = distributor.pendingGenesis(1, address(statics));
        vm.assume(pending > 0);
        uint256 balanceBefore = statics.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = distributor.claimGenesis(1, address(statics), alice);
        assertEq(claimed, pending);
        assertEq(statics.balanceOf(alice) - balanceBefore, claimed);
        assertLe(claimed, reward);
        _assertConserved(address(statics), reward);
    }

    function check_twoGenesisRemaindersNeverCreateRewards(uint128 reward) public {
        statics.mint(bob, vault.GENESIS_PRICE());
        _acquire(2, bob);
        vm.prank(bob);
        distributor.registerGenesis(2);
        _queue(reward, 0);
        distributor.accrue();
        uint256 pendingAlice = distributor.pendingGenesis(1, address(statics));
        uint256 pendingBob = distributor.pendingGenesis(2, address(statics));
        uint256 genesisAllocation = Math.mulDiv(reward, GENESIS_SHARE_BPS, 10_000);
        assertLe(pendingAlice + pendingBob, genesisAllocation);
        _assertConserved(address(statics), reward);
    }

    function _queue(uint256 staticsAmount, uint256 wethAmount) private {
        if (staticsAmount != 0) statics.mint(address(feeSource), staticsAmount);
        if (wethAmount != 0) weth.mint(address(feeSource), wethAmount);
        feeSource.queue(staticsAmount, wethAmount);
    }

    function _activationCost(uint256 targetTier) private view returns (uint256 cost) {
        for (uint256 tier = 1; tier <= targetTier; ++tier) {
            cost += registry.tierCost(uint8(tier));
        }
    }

    function _assertConserved(address asset, uint256 allocated) private view {
        IGenesisLaunchDistributor.RewardBookView memory book = distributor.rewardBook(asset);
        assertGe(book.indexedAmount, book.crystallizedAmount);
        uint256 uncrystallized = book.indexedAmount - book.crystallizedAmount;
        assertLe(book.totalClaimed + book.totalClaimable + book.treasuryClaimable + uncrystallized, allocated);
        assertGe(
            distributor.accountedCustody(asset) + feeReceiver.distributorClaimable(address(distributor), asset),
            book.totalClaimable + book.treasuryClaimable
        );
    }
}
