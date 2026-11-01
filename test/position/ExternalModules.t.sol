// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {GenesisPositionIntegrationTest} from "../genesis/GenesisPositionIntegration.t.sol";
import {ExternalAccountConsumer} from "./helpers/ExternalAccountConsumer.sol";
import {IStaticsExternalModules} from "../../src/interfaces/IStaticsExternalModules.sol";
import {LibExternalModules} from "../../src/libraries/LibExternalModules.sol";
import {LibPosition} from "../../src/position/LibPosition.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {IStaticsPosition} from "../../src/interfaces/IStaticsPosition.sol";
import {IModularPositionNFT} from "../../src/interfaces/IModularPositionNFT.sol";
import {PrepareStaticsExternalModulesUpgrade} from "../../script/PrepareStaticsExternalModulesUpgrade.s.sol";

contract AttachingPositionReceiver is IERC721Receiver {
    IStaticsExternalModules public immutable core;
    bytes4 public failure;

    constructor(address core_) {
        core = IStaticsExternalModules(core_);
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        try core.attachExternalAccountLeg(id, bytes32("receiver"), 0) {}
        catch (bytes memory reason) {
            failure = bytes4(reason);
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract ExternalModulesTest is GenesisPositionIntegrationTest {
    IStaticsExternalModules internal externalCore;
    ExternalAccountConsumer internal first;
    ExternalAccountConsumer internal second;
    bytes32 internal constant TYPE = keccak256("external.test");

    function setUp() public virtual override {
        super.setUp();
        (IDiamondCut.FacetCut[] memory cut, address init, bytes memory data) =
            new PrepareStaticsExternalModulesUpgrade().deploy();
        IDiamondCut(address(diamond)).diamondCut(cut, init, data);
        externalCore = IStaticsExternalModules(address(diamond));
        first = new ExternalAccountConsumer(address(diamond), stakingAsset);
        second = new ExternalAccountConsumer(address(diamond), stakingAsset);
        externalCore.setExternalModule(address(first), first.MODULE(), true);
        externalCore.setExternalModule(address(second), second.MODULE(), true);
        stakingAsset.mint(alice, 1_000_000 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(first), type(uint256).max);
        stakingAsset.approve(address(second), type(uint256).max);
        vm.stopPrank();
    }

    function testExternalNamespacesDisableCleanupAndInternalLegs() public {
        uint256 id = _createPosition(alice);
        _buyGenesis(alice, 1);
        vm.startPrank(alice);
        integration.linkGenesis(id, 1);
        first.deposit(id, 10 ether);
        second.deposit(id, 20 ether);
        vm.expectRevert("occupied");
        first.cleanup(id);
        vm.stopPrank();
        assertEq(externalCore.externalLegCount(id), 2);
        assertEq(IModularPositionNFT(address(diamond)).positionState(id).activeLegCount, 3);
        externalCore.setExternalModule(address(first), first.MODULE(), false);
        uint256 other = _createPosition(alice);
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LibExternalModules.ModuleNotEnabled.selector, address(first), first.MODULE())
        );
        first.deposit(other, 1 ether);
        first.withdraw(id, 10 ether);
        first.cleanup(id);
        assertEq(externalCore.externalLegCount(id), 1);
        vm.expectRevert();
        IStaticsPosition(address(diamond)).closePosition(id);
        second.withdraw(id, 20 ether);
        second.cleanup(id);
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
        externalCore.setExternalModule(alice, TYPE, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibExternalModules.ModuleNotEnabled.selector, alice, TYPE));
        externalCore.attachExternalAccountLeg(id, TYPE, 0);
        externalCore.setExternalModule(address(this), TYPE, true);
        externalCore.setExternalModule(alice, TYPE, true);
        bytes32 ours = externalCore.attachExternalAccountLeg(id, TYPE, 0);
        assertEq(ours, keccak256(abi.encode(address(this), TYPE, bytes32(0))));
        vm.expectRevert(abi.encodeWithSelector(LibPosition.PositionLegAlreadyActive.selector, id, ours));
        externalCore.attachExternalAccountLeg(id, TYPE, 0);
        vm.prank(alice);
        bytes32 hers = externalCore.attachExternalAccountLeg(id, TYPE, 0);
        assertTrue(ours != hers);
        externalCore.detachExternalAccountLeg(id, TYPE, 0);
        vm.expectRevert(abi.encodeWithSelector(LibPosition.PositionLegNotActive.selector, id, ours));
        externalCore.detachExternalAccountLeg(id, TYPE, 0);
        assertTrue(IModularPositionNFT(address(diamond)).isLegActive(id, hers));
        // Approval is scoped to both caller and module type.
        vm.expectRevert();
        externalCore.attachExternalAccountLeg(id, bytes32("unapproved"), 0);
        for (uint256 i = 1; i < 64; ++i) {
            externalCore.attachExternalAccountLeg(id, TYPE, bytes32(i));
        }
        assertEq(externalCore.externalLegCapacity(), 64);
        uint256 beforeBalance = stakingAsset.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibExternalModules.ExternalLegCapacityReached.selector, id));
        first.deposit(id, 1 ether);
        assertEq(stakingAsset.balanceOf(alice), beforeBalance);
        assertEq(stakingAsset.balanceOf(address(first)), 0);
        assertEq(first.balance(id), 0);
        assertFalse(first.attached(id));
        (IStaticsExternalModules.ExternalLeg[] memory page, uint256 next) = externalCore.externalLegs(id, 0, 37);
        assertEq(page.length, 37);
        (page, next) = externalCore.externalLegs(id, next, 100);
        assertEq(page.length, 27);
        assertEq(next, 64);
        (page, next) = externalCore.externalLegs(id, next, 1);
        assertEq(page.length, 0);
        assertEq(next, 64);
        vm.expectRevert(LibExternalModules.InvalidPage.selector);
        externalCore.externalLegs(id, 0, 0);
        vm.expectRevert(LibExternalModules.InvalidPage.selector);
        externalCore.externalLegs(id, 0, 101);
        vm.expectRevert(LibExternalModules.InvalidPage.selector);
        externalCore.externalLegs(id, 65, 1);
        vm.expectRevert();
        externalCore.attachExternalAccountLeg(99999, TYPE, 0);
    }

    function testExternalSafeMintRejectsAttachmentAndSafeTransferAllowsAttachment() public {
        AttachingPositionReceiver receiver = new AttachingPositionReceiver(address(diamond));
        externalCore.setExternalModule(address(receiver), bytes32("receiver"), true);
        uint256 id = IStaticsPosition(address(diamond)).createPosition(address(receiver));
        assertEq(receiver.failure(), LibExternalModules.PositionInitializing.selector);
        assertEq(externalCore.externalLegCount(id), 0);
        uint256 aliceId = _createPosition(alice);
        vm.prank(alice);
        IERC721(address(diamond)).safeTransferFrom(alice, address(receiver), aliceId);
        assertEq(externalCore.externalLegCount(aliceId), 1);
    }

    function testExternalFinancialAuthorityFollowsOwnerWithoutProductCalls() public {
        uint256 id = _createPosition(alice);
        vm.startPrank(alice);
        first.deposit(id, 100 ether);
        second.deposit(id, 50 ether);
        IERC721(address(diamond)).approve(bob, id);
        IERC721(address(diamond)).setApprovalForAll(bob, true);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert("owner");
        first.withdraw(id, 1);
        // Both products can be entirely unavailable during a transfer.
        bytes memory firstCode = address(first).code;
        bytes memory secondCode = address(second).code;
        vm.etch(address(first), hex"5f5ffd");
        vm.etch(address(second), hex"5f5ffd");
        vm.prank(bob);
        IERC721(address(diamond)).transferFrom(alice, bob, id);
        vm.etch(address(first), firstCode);
        vm.etch(address(second), secondCode);
        assertEq(first.balance(id), 100 ether);
        assertEq(second.balance(id), 50 ether);
        assertEq(stakingAsset.balanceOf(address(first)), 100 ether);
        assertEq(stakingAsset.balanceOf(address(second)), 50 ether);
        assertEq(externalCore.externalLegCount(id), 2);
        vm.prank(alice);
        vm.expectRevert("owner");
        first.withdraw(id, 1);
        uint256 beforeBalance = stakingAsset.balanceOf(bob);
        vm.startPrank(bob);
        first.withdraw(id, 100 ether);
        first.cleanup(id);
        vm.expectRevert();
        IStaticsPosition(address(diamond)).closePosition(id);
        second.withdraw(id, 50 ether);
        second.cleanup(id);
        IStaticsPosition(address(diamond)).closePosition(id);
        vm.stopPrank();
        assertEq(stakingAsset.balanceOf(bob), beforeBalance + 150 ether);
    }

    function testFuzzExternalPaginationAndSwapRemoval(uint256 amount, uint256 requested, uint256 removed) public {
        amount = bound(amount, 1, 64);
        requested = bound(requested, 1, 100);
        removed = bound(removed, 0, amount - 1);
        uint256 id = _createPosition(alice);
        externalCore.setExternalModule(address(this), TYPE, true);
        for (uint256 i; i < amount; ++i) {
            externalCore.attachExternalAccountLeg(id, TYPE, bytes32(i));
        }
        externalCore.detachExternalAccountLeg(id, TYPE, bytes32(removed));
        uint256 cursor;
        uint256 seen;
        do {
            (IStaticsExternalModules.ExternalLeg[] memory page, uint256 next) =
                externalCore.externalLegs(id, cursor, requested);
            assertLe(page.length, requested);
            for (uint256 i; i < page.length; ++i) {
                assertTrue(page[i].localId != bytes32(removed));
                assertTrue(IModularPositionNFT(address(diamond)).isLegActive(id, page[i].legKey));
            }
            seen += page.length;
            cursor = next;
        } while (cursor < amount - 1);
        assertEq(seen, amount - 1);
        assertEq(IModularPositionNFT(address(diamond)).positionState(id).activeLegCount, amount - 1);
    }

    function testExternalUpgradePreservesGenesisAndExistingFacetRoutes() public {
        uint256 id = _createPosition(alice);
        _buyGenesis(alice, 1);
        vm.prank(alice);
        integration.linkGenesis(id, 1);
        bytes32 beforeState = keccak256(abi.encode(IModularPositionNFT(address(diamond)).positionState(id)));
        IDiamondCut.FacetCut[] memory removal = new IDiamondCut.FacetCut[](1);
        removal[0] =
            IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, StaticsSelectors.externalModules());
        IDiamondCut(address(diamond)).diamondCut(removal, address(0), "");
        IDiamondLoupe.Facet[] memory beforeFacets = IDiamondLoupe(address(diamond)).facets();
        (IDiamondCut.FacetCut[] memory cut, address init, bytes memory data) =
            new PrepareStaticsExternalModulesUpgrade().deploy();
        assertEq(cut.length, 1);
        assertEq(uint256(cut[0].action), uint256(IDiamondCut.FacetCutAction.Add));
        assertEq(cut[0].functionSelectors.length, 7);
        IDiamondCut(address(diamond)).diamondCut(cut, init, data);
        for (uint256 i; i < beforeFacets.length; ++i) {
            for (uint256 j; j < beforeFacets[i].functionSelectors.length; ++j) {
                assertEq(
                    IDiamondLoupe(address(diamond)).facetAddress(beforeFacets[i].functionSelectors[j]),
                    beforeFacets[i].facetAddress
                );
            }
        }
        assertEq(IERC721(address(diamond)).ownerOf(id), alice);
        assertEq(keccak256(abi.encode(IModularPositionNFT(address(diamond)).positionState(id))), beforeState);
        assertEq(integration.linkedGenesis(id), 1);
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IStaticsExternalModules).interfaceId));
        bytes4 previous = type(IStaticsExternalModules).interfaceId ^ bytes4(keccak256("transferHead()"))
            ^ bytes4(keccak256("transferState(address,uint256)"))
            ^ bytes4(keccak256("transferChanges(uint256,uint256)")) ^ bytes4(keccak256("historyCoverage(address)"));
        assertFalse(IERC165(address(diamond)).supportsInterface(previous));
        vm.startPrank(alice);
        first.deposit(id, 1 ether);
        integration.unlinkGenesis(id, 1);
        vm.expectRevert();
        IStaticsPosition(address(diamond)).closePosition(id);
        first.withdraw(id, 1 ether);
        first.cleanup(id);
        IStaticsPosition(address(diamond)).closePosition(id);
        vm.stopPrank();
    }
}
