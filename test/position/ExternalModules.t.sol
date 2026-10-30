// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {GenesisPositionIntegrationTest} from "../genesis/GenesisPositionIntegration.t.sol";
import {ExternalRewardConsumer, ExternalLifecycleConsumer} from "./helpers/ExternalRewardConsumer.sol";
import {IStaticsExternalModules} from "../../src/interfaces/IStaticsExternalModules.sol";
import {ExternalModuleFacet} from "../../src/facets/ExternalModuleFacet.sol";
import {LibExternalModules} from "../../src/libraries/LibExternalModules.sol";
import {LibNFTTransferHistory} from "../../src/libraries/LibNFTTransferHistory.sol";
import {LibPosition} from "../../src/position/LibPosition.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IStaticsPosition} from "../../src/interfaces/IStaticsPosition.sol";
import {IModularPositionNFT} from "../../src/interfaces/IModularPositionNFT.sol";
import {PrepareStaticsExternalModulesUpgrade} from "../../script/PrepareStaticsExternalModulesUpgrade.s.sol";

contract AttachingPositionReceiver is IERC721Receiver {
    IStaticsExternalModules public immutable core;
    bytes4 public failure;
    uint256 public observedSequence;

    constructor(address core_) {
        core = IStaticsExternalModules(core_);
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        observedSequence = core.transferState(msg.sender, id).lastSequence;
        try core.attachExternalAccountLeg(id, bytes32("receiver"), 0) {}
        catch (bytes memory reason) {
            failure = bytes4(reason);
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract ExternalModulesTest is GenesisPositionIntegrationTest {
    IStaticsExternalModules internal externalCore;
    ExternalRewardConsumer internal single;
    ExternalRewardConsumer internal multi;
    ExternalLifecycleConsumer internal lifecycle;
    bytes32 internal constant TYPE = keccak256("external.test");

    function setUp() public virtual override {
        super.setUp();
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut(
            address(new ExternalModuleFacet()), IDiamondCut.FacetCutAction.Add, StaticsSelectors.externalModules()
        );
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        externalCore = IStaticsExternalModules(address(diamond));
        address[] memory assets = new address[](1);
        assets[0] = address(stakingAsset);
        single = new ExternalRewardConsumer(
            address(diamond), address(genesis), address(activationRegistry), stakingAsset, assets
        );
        assets = new address[](2);
        assets[0] = address(stakingAsset);
        assets[1] = address(numeraire);
        multi = new ExternalRewardConsumer(
            address(diamond), address(genesis), address(activationRegistry), stakingAsset, assets
        );
        lifecycle = new ExternalLifecycleConsumer(address(diamond));
        externalCore.setExternalModule(address(single), single.MODULE(), true);
        externalCore.setExternalModule(address(multi), multi.MODULE(), true);
        externalCore.setExternalModule(address(lifecycle), lifecycle.MODULE(), true);
        stakingAsset.mint(alice, 1_000_000 ether);
        stakingAsset.mint(bob, 1_000_000 ether);
        stakingAsset.mint(address(this), 1_000_000 ether);
        numeraire.mint(address(this), 1_000_000 ether);
        stakingAsset.approve(address(single), type(uint256).max);
        stakingAsset.approve(address(multi), type(uint256).max);
        numeraire.approve(address(multi), type(uint256).max);
        vm.startPrank(alice);
        stakingAsset.approve(address(single), type(uint256).max);
        stakingAsset.approve(address(multi), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        stakingAsset.approve(address(single), type(uint256).max);
        stakingAsset.approve(address(multi), type(uint256).max);
        vm.stopPrank();
    }

    function testExternalNamespacesDisableCleanupAndInternalLegs() public {
        uint256 id = _createPosition(alice);
        _buyGenesis(alice, 1);
        vm.startPrank(alice);
        integration.linkGenesis(id, 1);
        single.deposit(id, 10 ether, false);
        multi.depositCash(id, 20 ether);
        lifecycle.open(id);
        vm.stopPrank();
        assertEq(externalCore.externalLegCount(id), 3);
        assertEq(IModularPositionNFT(address(diamond)).positionState(id).activeLegCount, 4);
        externalCore.setExternalModule(address(single), single.MODULE(), false);
        vm.startPrank(alice);
        single.withdraw(id, 10 ether);
        single.cleanup(id);
        assertEq(externalCore.externalLegCount(id), 2);
        vm.expectRevert();
        IStaticsPosition(address(diamond)).closePosition(id);
        multi.withdrawCash(id);
        multi.cleanup(id);
        lifecycle.close(id);
        vm.expectRevert();
        IStaticsPosition(address(diamond)).closePosition(id);
        integration.unlinkGenesis(id, 1);
        IStaticsPosition(address(diamond)).closePosition(id);
        vm.stopPrank();
    }

    function testExternalAuthorityCapacityPaginationAndAtomicFunding() public {
        uint256 id = _createPosition(alice);
        vm.prank(alice);
        vm.expectRevert();
        externalCore.attachExternalAccountLeg(id, TYPE, 0);
        externalCore.setExternalModule(address(this), TYPE, true);
        externalCore.setExternalModule(alice, TYPE, true);
        externalCore.attachExternalAccountLeg(id, TYPE, 0);
        vm.expectRevert();
        externalCore.attachExternalAccountLeg(id, TYPE, 0);
        vm.prank(alice);
        externalCore.attachExternalAccountLeg(id, TYPE, 0);
        assertEq(externalCore.externalLegCount(id), 2);
        externalCore.detachExternalAccountLeg(id, TYPE, 0);
        vm.expectRevert();
        externalCore.detachExternalAccountLeg(id, TYPE, 0);
        for (uint256 i = 1; i < 64; ++i) {
            externalCore.attachExternalAccountLeg(id, TYPE, bytes32(i));
        }
        uint256 beforeBalance = stakingAsset.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibExternalModules.ExternalLegCapacityReached.selector, id));
        single.deposit(id, 1 ether, true);
        assertEq(stakingAsset.balanceOf(alice), beforeBalance);
        assertEq(stakingAsset.balanceOf(address(single)), 0);
        assertFalse(single.attached(id));
        (IStaticsExternalModules.ExternalLeg[] memory first, uint256 next) = externalCore.externalLegs(id, 0, 37);
        assertEq(first.length, 37);
        (IStaticsExternalModules.ExternalLeg[] memory rest, uint256 end) = externalCore.externalLegs(id, next, 100);
        assertEq(rest.length, 27);
        assertEq(end, 64);
        for (uint256 i; i < first.length; ++i) {
            assertTrue(IModularPositionNFT(address(diamond)).isLegActive(id, first[i].legKey));
        }
        vm.expectRevert(LibExternalModules.InvalidPage.selector);
        externalCore.externalLegs(id, 0, 101);
        vm.expectRevert();
        externalCore.attachExternalAccountLeg(99999, TYPE, 0);
    }

    function testExternalSafeMintRejectsAttachmentAndSafeTransferObservesHistory() public {
        AttachingPositionReceiver receiver = new AttachingPositionReceiver(address(diamond));
        externalCore.setExternalModule(address(receiver), bytes32("receiver"), true);
        uint256 id = IStaticsPosition(address(diamond)).createPosition(address(receiver));
        assertEq(receiver.failure(), LibExternalModules.PositionInitializing.selector);
        assertEq(externalCore.externalLegCount(id), 0);
        uint256 aliceId = _createPosition(alice);
        vm.prank(alice);
        IERC721(address(diamond)).safeTransferFrom(alice, address(receiver), aliceId);
        assertEq(receiver.observedSequence(), 1);
        assertEq(externalCore.externalLegCount(aliceId), 1);
    }

    function testExternalTransferOrderingRecoveryAndCoverage() public {
        uint256 id = _createPosition(alice);
        _buyGenesis(alice, 1);
        uint256 initialHead = externalCore.transferHead();
        uint256 initialNonce = externalCore.transferState(address(genesis), 1).nonce;
        assertTrue(externalCore.historyCoverage(address(diamond)).ready);
        assertTrue(externalCore.historyCoverage(address(genesis)).ready);
        vm.startPrank(alice);
        IERC721(address(diamond)).transferFrom(alice, bob, id);
        genesis.transferFrom(alice, bob, 1);
        vm.stopPrank();
        vm.startPrank(bob);
        IERC721(address(diamond)).transferFrom(bob, alice, id);
        genesis.transferFrom(bob, alice, 1);
        vm.stopPrank();
        vm.prank(alice);
        genesis.transferFrom(alice, alice, 1);
        _activate(alice, 1, 1);
        assertEq(externalCore.transferHead(), initialHead + 4);
        assertEq(externalCore.transferState(address(genesis), 1).nonce, initialNonce + 2);
        (IStaticsExternalModules.TransferChange[] memory changes, uint256 next) =
            externalCore.transferChanges(initialHead, 2);
        assertEq(next, initialHead + 2);
        assertEq(changes[0].collection, address(diamond));
        assertEq(changes[1].collection, address(genesis));
        assertEq(changes[0].transferredAt, changes[1].transferredAt);
        (changes, next) = externalCore.transferChanges(next, 100);
        assertEq(next, initialHead + 4);
        assertEq(changes[0].nonce, 2);
        assertEq(changes[1].nonce, initialNonce + 2);
        vm.warp(epochEnd);
        vm.prank(alice);
        vault.openGenesisCredit{value: 0.003 ether}(1, 100_000 ether);
        vm.warp(vault.creditRecoverableAt(1) + 1);
        vault.recoverGenesisCredit(1);
        assertEq(externalCore.transferHead(), initialHead + 5);
        assertEq(externalCore.transferState(address(genesis), 1).nonce, initialNonce + 3);
        assertEq(externalCore.transferState(address(genesis), 1).transferredAt, block.timestamp);
        vm.prank(alice);
        IStaticsPosition(address(diamond)).closePosition(id);
        assertEq(externalCore.transferState(address(diamond), id).nonce, 2);
        assertEq(externalCore.transferHead(), initialHead + 5);
    }

    function testExternalOwnerAuthorityHistoricalRewardsAndIndependentModules() public {
        uint256 id = _createPosition(alice);
        vm.startPrank(alice);
        single.deposit(id, 100 ether, true);
        multi.deposit(id, 100 ether, true);
        lifecycle.open(id);
        IERC721(address(diamond)).approve(bob, id);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert("owner");
        single.unstake(id, 1);
        single.fund(address(stakingAsset), 900 ether);
        multi.fund(address(numeraire), 300 ether);
        vm.prank(alice);
        IERC721(address(diamond)).transferFrom(alice, bob, id);
        vm.prank(alice);
        vm.expectRevert("owner");
        single.claim(id, address(stakingAsset));
        vm.startPrank(bob);
        assertEq(single.claim(id, address(stakingAsset)), 900 ether);
        assertEq(multi.claim(id, address(numeraire)), 300 ether);
        single.unstake(id, 100 ether);
        single.withdraw(id, 100 ether);
        single.cleanup(id);
        vm.expectRevert();
        IStaticsPosition(address(diamond)).closePosition(id);
        multi.unstake(id, 100 ether);
        multi.withdraw(id, 100 ether);
        multi.cleanup(id);
        lifecycle.close(id);
        IStaticsPosition(address(diamond)).closePosition(id);
        vm.stopPrank();
    }

    function testExternalRegistrationUniqueRefreshAndLinkIndependence() public {
        uint256 a = _createPosition(alice);
        uint256 b = _createPosition(alice);
        _buyGenesis(alice, 1);
        _buyGenesis(alice, 2);
        _activate(alice, 1, 1);
        vm.startPrank(alice);
        single.deposit(a, 100 ether, true);
        single.deposit(b, 100 ether, true);
        single.register(a, 1);
        uint256 oldWeight = single.totalWeight();
        integration.linkGenesis(a, 1);
        integration.unlinkGenesis(a, 1);
        assertEq(single.totalWeight(), oldWeight);
        vm.expectRevert("operator occupied");
        single.register(b, 1);
        vm.stopPrank();
        _activate(alice, 1, 4);
        assertEq(single.totalWeight(), oldWeight);
        single.fund(address(stakingAsset), 440 ether);
        uint256 beforeRefresh = single.pendingRay(a, address(stakingAsset));
        vm.startPrank(alice);
        single.register(a, 1);
        single.register(a, 2);
        assertEq(single.operatorAccount(1), 0);
        single.register(b, 1);
        assertEq(single.operatorAccount(1), b);
        assertEq(single.operatorAccount(2), a);
        vm.stopPrank();
        assertEq(single.pendingRay(a, address(stakingAsset)), beforeRefresh);
        vm.prank(alice);
        genesis.transferFrom(alice, bob, 1);
        single.process(100);
        assertEq(single.operatorAccount(1), 0);
        vm.prank(bob);
        genesis.transferFrom(bob, alice, 1);
        _activate(alice, 1, 4);
        uint256 baseWeight = single.totalWeight();
        single.process(100);
        assertEq(single.totalWeight(), baseWeight);
        vm.prank(alice);
        single.register(a, 1);
        assertEq(single.operatorAccount(2), 0);
    }

    function testExternalDormantDenominatorAndFundedBatchOrdering() public {
        uint256 a = _createPosition(alice);
        uint256 b = _createPosition(bob);
        _buyGenesis(alice, 1);
        _activate(alice, 1, 4);
        vm.startPrank(alice);
        single.deposit(a, 100 ether, true);
        single.register(a, 1);
        vm.stopPrank();
        vm.prank(bob);
        single.deposit(b, 100 ether, true);
        uint256 boostedWeight = single.totalWeight();
        single.fund(address(stakingAsset), boostedWeight);
        uint256 oldEarned = single.pendingRay(a, address(stakingAsset));
        // More than one transfer creates a pending batch under fund's one-work limit.
        vm.startPrank(alice);
        genesis.transferFrom(alice, bob, 1);
        IERC721(address(diamond)).transferFrom(alice, bob, a);
        vm.stopPrank();
        single.fund(address(stakingAsset), 900 ether);
        assertEq(single.nextBatch(), 1);
        vm.prank(bob);
        IERC721(address(diamond)).transferFrom(bob, alice, a);
        single.fund(address(stakingAsset), 600 ether);
        while (single.nextBatch() < 3 || single.cursor() < externalCore.transferHead()) single.process(1);
        assertEq(single.totalWeight(), 200 ether);
        assertEq(single.pendingRay(a, address(stakingAsset)), oldEarned + 750 ether * single.RAY());
        assertEq(single.pendingRay(b, address(stakingAsset)), (100 ether + 750 ether) * single.RAY());
        assertEq(single.operatorAccount(1), 0);
        assertEq(
            stakingAsset.balanceOf(address(single)) * single.RAY(),
            200 ether * single.RAY() + single.pendingRay(a, address(stakingAsset))
                + single.pendingRay(b, address(stakingAsset))
        );
    }

    function testExternalPendingBoostedBatchPrecedesLaterOperatorTransfer() public {
        uint256 a = _createPosition(alice);
        uint256 b = _createPosition(bob);
        uint256 unrelated = _createPosition(alice);
        _buyGenesis(alice, 1);
        _activate(alice, 1, 4);
        vm.startPrank(alice);
        single.deposit(a, 100 ether, true);
        single.register(a, 1);
        vm.stopPrank();
        vm.prank(bob);
        single.deposit(b, 100 ether, true);
        uint256 boostedTotal = single.totalWeight();
        vm.prank(alice);
        IERC721(address(diamond)).transferFrom(alice, bob, unrelated);
        vm.prank(bob);
        IERC721(address(diamond)).transferFrom(bob, alice, unrelated);
        single.fund(address(stakingAsset), boostedTotal);
        assertEq(single.nextBatch(), 0);
        // This invalidation is later than the still-pending boosted allocation.
        vm.prank(alice);
        genesis.transferFrom(alice, bob, 1);
        single.fund(address(stakingAsset), 200 ether);
        assertEq(single.nextBatch(), 0);
        single.process(1);
        assertEq(single.nextBatch(), 1);
        assertEq(single.totalWeight(), boostedTotal);
        assertEq(single.pendingRay(a, address(stakingAsset)), (boostedTotal - 100 ether) * single.RAY());
        single.process(1);
        assertEq(single.totalWeight(), 200 ether);
        single.process(1);
        assertEq(single.nextBatch(), 2);
        assertEq(single.pendingRay(a, address(stakingAsset)), boostedTotal * single.RAY());
        assertEq(single.pendingRay(b, address(stakingAsset)), 200 ether * single.RAY());
    }

    function testExternalZeroStakeAndFractionalDustCannotBeCaptured() public {
        uint256 a = _createPosition(alice);
        uint256 b = _createPosition(bob);
        multi.fund(address(numeraire), 17);
        vm.prank(alice);
        multi.deposit(a, 3, true);
        multi.fund(address(numeraire), 1);
        vm.prank(bob);
        multi.deposit(b, 7, true);
        assertEq(multi.pendingRay(b, address(numeraire)), 0);
        assertEq(multi.zeroStakeRevenue(address(numeraire)), 17);
        uint256 ray = multi.RAY();
        assertEq(
            numeraire.balanceOf(address(multi)) * ray,
            17 * ray + multi.pendingRay(a, address(numeraire)) + multi.pendingRay(b, address(numeraire))
                + multi.dustRay(address(numeraire))
        );
        multi.fund(address(stakingAsset), 33);
        assertEq(
            stakingAsset.balanceOf(address(multi)) * ray,
            10 * ray + multi.pendingRay(a, address(stakingAsset)) + multi.pendingRay(b, address(stakingAsset))
                + multi.dustRay(address(stakingAsset))
        );
    }

    function testExternalFailedTransferAndSpoofedNotificationLeaveHistoryUnchanged() public {
        uint256 id = _createPosition(alice);
        uint256 head = externalCore.transferHead();
        vm.prank(alice);
        vm.expectRevert();
        IERC721(address(diamond)).safeTransferFrom(alice, address(single), id);
        assertEq(IERC721(address(diamond)).ownerOf(id), alice);
        assertEq(externalCore.transferHead(), head);
        assertEq(externalCore.transferState(address(diamond), id).nonce, 0);
        vm.prank(alice);
        vm.expectRevert();
        integration.onGenesisTransition(1, alice, bob, 10_000, 10_000);
        assertEq(externalCore.transferHead(), head);
        vm.expectRevert(LibExternalModules.InvalidPage.selector);
        externalCore.transferChanges(head + 1, 1);
        vm.expectRevert(LibExternalModules.InvalidPage.selector);
        externalCore.transferChanges(head, 0);
    }

    function testExternalBacklogBlocksStakeUntilPermissionlessReplay() public {
        uint256 id = _createPosition(alice);
        vm.prank(alice);
        single.deposit(id, 100 ether, false);
        for (uint256 i; i < 104; ++i) {
            address from = i % 2 == 0 ? alice : bob;
            address to = i % 2 == 0 ? bob : alice;
            vm.prank(from);
            IERC721(address(diamond)).transferFrom(from, to, id);
        }
        single.fund(address(stakingAsset), 9 ether);
        vm.prank(alice);
        vm.expectRevert("backlog");
        single.stake(id, 1 ether);
        assertEq(single.nextBatch(), 0);
        single.process(100);
        single.process(10);
        vm.prank(alice);
        single.stake(id, 1 ether);
        assertEq(single.zeroStakeRevenue(address(stakingAsset)), 9 ether);
        assertEq(single.pendingRay(id, address(stakingAsset)), 0);
    }

    function testFuzzExternalMultiAssetConservation(uint256 stakeA, uint256 stakeB, uint256 revenueA, uint256 revenueB)
        public
    {
        stakeA = bound(stakeA, 1, 100 ether);
        stakeB = bound(stakeB, 1, 100 ether);
        revenueA = bound(revenueA, 1, 1000 ether);
        revenueB = bound(revenueB, 1, 1000 ether);
        uint256 a = _createPosition(alice);
        uint256 b = _createPosition(bob);
        vm.prank(alice);
        multi.deposit(a, stakeA, true);
        vm.prank(bob);
        multi.deposit(b, stakeB, true);
        multi.fund(address(stakingAsset), revenueA);
        multi.fund(address(numeraire), revenueB);
        vm.prank(alice);
        multi.claim(a, address(stakingAsset));
        vm.prank(bob);
        multi.claim(b, address(numeraire));
        vm.prank(alice);
        multi.unstake(a, stakeA);
        multi.fund(address(stakingAsset), revenueB);
        multi.fund(address(numeraire), revenueA);
        uint256 ray = multi.RAY();
        assertEq(
            stakingAsset.balanceOf(address(multi)) * ray,
            (stakeA + stakeB) * ray + multi.pendingRay(a, address(stakingAsset))
                + multi.pendingRay(b, address(stakingAsset)) + multi.dustRay(address(stakingAsset))
        );
        assertEq(
            numeraire.balanceOf(address(multi)) * ray,
            multi.pendingRay(a, address(numeraire)) + multi.pendingRay(b, address(numeraire))
                + multi.dustRay(address(numeraire))
        );
    }

    function testExternalUpgradePreservesOccupiedStateAndRejectsReinitialization() public {
        uint256 id = _createPosition(alice);
        _buyGenesis(alice, 1);
        vm.prank(alice);
        integration.linkGenesis(id, 1);
        IModularPositionNFT.PositionState memory beforeState = IModularPositionNFT(address(diamond)).positionState(id);
        // Leave all pre-existing protocol state intact, but empty the new namespace.
        _emptyHistoryFixture();
        vm.roll(block.number + 100);
        bytes4[] memory selectors = StaticsSelectors.externalModules();
        IDiamondCut.FacetCut[] memory removal = new IDiamondCut.FacetCut[](1);
        removal[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, selectors);
        IDiamondCut(address(diamond)).diamondCut(removal, address(0), "");
        (IDiamondCut.FacetCut[] memory cut, address init, bytes memory data) =
            new PrepareStaticsExternalModulesUpgrade().deploy(address(diamond));
        IDiamondCut(address(diamond)).diamondCut(cut, init, data);
        assertEq(IERC721(address(diamond)).ownerOf(id), alice);
        IModularPositionNFT.PositionState memory afterState = IModularPositionNFT(address(diamond)).positionState(id);
        assertEq(keccak256(abi.encode(afterState)), keccak256(abi.encode(beforeState)));
        assertEq(integration.linkedGenesis(id), 1);
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IStaticsExternalModules).interfaceId));
        assertTrue(externalCore.historyCoverage(address(genesis)).ready);
        assertEq(externalCore.historyCoverage(address(genesis)).startBlock, block.number);
        assertEq(externalCore.historyCoverage(address(diamond)).startBlock, block.number);
        assertEq(externalCore.transferHead(), 0);
        assertEq(externalCore.transferState(address(genesis), 1).nonce, 0);
        vm.expectRevert(LibNFTTransferHistory.HistoryAlreadyInitialized.selector);
        IDiamondCut(address(diamond)).diamondCut(new IDiamondCut.FacetCut[](0), init, data);
    }

    function _emptyHistoryFixture() private {
        uint256 root = uint256(keccak256("statics.storage.nft.transfer.history.v1"));
        uint256 head = externalCore.transferHead();
        for (uint256 sequence = 1; sequence <= head; ++sequence) {
            (IStaticsExternalModules.TransferChange[] memory changes,) = externalCore.transferChanges(sequence - 1, 1);
            IStaticsExternalModules.TransferChange memory change = changes[0];
            uint256 stateSlot =
                uint256(keccak256(abi.encode(change.tokenId, keccak256(abi.encode(change.collection, root + 3)))));
            vm.store(address(diamond), bytes32(stateSlot), 0);
            vm.store(address(diamond), bytes32(stateSlot + 1), 0);
            uint256 recordSlot = uint256(keccak256(abi.encode(sequence, root + 4)));
            for (uint256 field; field < 3; ++field) {
                vm.store(address(diamond), bytes32(recordSlot + field), 0);
            }
        }
        address[2] memory collections = [address(diamond), address(genesis)];
        for (uint256 c; c < collections.length; ++c) {
            uint256 coverageSlot = uint256(keccak256(abi.encode(collections[c], root + 2)));
            for (uint256 field; field < 3; ++field) {
                vm.store(address(diamond), bytes32(coverageSlot + field), 0);
            }
        }
        vm.store(address(diamond), bytes32(root), 0);
        vm.store(address(diamond), bytes32(root + 1), 0);
    }
}
