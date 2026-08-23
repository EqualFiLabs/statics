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

    function check_globalRewardConservation(uint96 staticsAmount, uint96 wethAmount) public {
        _queue(staticsAmount, wethAmount);
        distributor.accrue();
        _assertConserved(address(statics), staticsAmount);
        _assertConserved(address(weth), wethAmount);
        assertEq(distributor.totalWeight(), distributor.effectiveWeight(1));
    }

    function check_transferAssignsPreCheckpointRewardsToPreviousOwner() public {
        uint256 preTransferReward = 1 ether + 7;
        uint256 postTransferReward = 2 ether + 11;
        _queue(preTransferReward, 0);
        feeReceiver.harvest();
        uint256 expectedPreTransfer = Math.mulDiv(preTransferReward, GENESIS_SHARE_BPS, 10_000);

        vm.prank(alice);
        genesis.transferFrom(alice, bob, 1);
        assertEq(distributor.ownerClaimable(alice, address(statics)), expectedPreTransfer, "pre-transfer owner");
        assertEq(distributor.pendingGenesis(1, address(statics)), 0, "transfer checkpoint");
        assertEq(registry.tierOf(1), 0, "activation reset");
        _queue(postTransferReward, 0);
        distributor.accrue();
        assertEq(distributor.ownerClaimable(alice, address(statics)), expectedPreTransfer, "old owner unchanged");
    }

    function testTransferCheckpointRepresentativeRewards() public {
        check_transferAssignsPreCheckpointRewardsToPreviousOwner();
        assertEq(distributor.pendingGenesis(1, address(statics)), 1_500_000_000_000_000_008);
    }

    function check_activationSettlesAtPreviousWeight() public {
        uint256 reward = 1 ether + 1;
        _queue(reward, 0);
        feeReceiver.harvest();
        distributor.accrue();
        uint256 pendingBefore = distributor.pendingGenesis(1, address(statics));
        uint256 activationCost = registry.tierCost(1);
        uint256 treasuryBefore = statics.balanceOf(treasury);

        vm.startPrank(alice);
        statics.approve(address(registry), activationCost);
        registry.activate(1, 1);
        vm.stopPrank();

        assertEq(distributor.pendingGenesis(1, address(statics)), pendingBefore);
        assertEq(distributor.effectiveWeight(1), registry.multiplierForTier(1));
        assertEq(registry.tierOf(1), 1);
        assertEq(statics.balanceOf(treasury) - treasuryBefore, activationCost);
    }

    function check_claimCannotExceedIndexedReward() public {
        uint256 reward = 1 ether + 3;
        _queue(reward, 0);
        distributor.accrue();
        uint256 pending = distributor.pendingGenesis(1, address(statics));
        assertGt(pending, 0);
        uint256 balanceBefore = statics.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = distributor.claimGenesis(1, address(statics), alice);
        IGenesisLaunchDistributor.RewardBookView memory book = distributor.rewardBook(address(statics));
        assertEq(claimed, pending);
        assertEq(statics.balanceOf(alice) - balanceBefore, claimed);
        assertLe(book.totalClaimed, book.indexedAmount);
    }

    function check_twoGenesisRemaindersNeverCreateRewards() public {
        uint256 reward = 1 ether + 5;
        statics.mint(bob, vault.GENESIS_PRICE());
        _acquire(2, bob);
        vm.prank(bob);
        distributor.registerGenesis(2);
        _queue(reward, 0);
        distributor.accrue();
        uint256 pendingAlice = distributor.pendingGenesis(1, address(statics));
        uint256 pendingBob = distributor.pendingGenesis(2, address(statics));
        IGenesisLaunchDistributor.RewardBookView memory book = distributor.rewardBook(address(statics));
        assertLe(pendingAlice + pendingBob, book.indexedAmount);
        assertLe(book.indexedAmount, reward);
    }

    function _queue(uint256 staticsAmount, uint256 wethAmount) private {
        if (staticsAmount != 0) statics.mint(address(feeSource), staticsAmount);
        if (wethAmount != 0) weth.mint(address(feeSource), wethAmount);
        feeSource.queue(staticsAmount, wethAmount);
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
