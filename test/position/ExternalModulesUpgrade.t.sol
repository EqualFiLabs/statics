// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;
import {PositionNFTTest} from "./PositionNFT.t.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IModularPositionNFT} from "../../src/interfaces/IModularPositionNFT.sol";
import {IStaticsExternalModules} from "../../src/interfaces/IStaticsExternalModules.sol";
import {PrepareStaticsExternalModulesUpgrade} from "../../script/PrepareStaticsExternalModulesUpgrade.s.sol";

contract ExternalModulesUpgradeTest is PositionNFTTest {
    function testExternalUpgradeBeforeGenesisPreservesInternalLegsAndObligations() public {
        vm.prank(alice);
        uint256 id = positions.createPosition(alice);
        vm.startPrank(alice);
        moduleHarness.activate(id, BASKET, bytes32(uint256(7)));
        moduleHarness.openObligation(id);
        vm.stopPrank();
        IModularPositionNFT.PositionState memory beforeState = IModularPositionNFT(address(diamond)).positionState(id);
        vm.store(address(diamond), keccak256("statics.storage.nft.transfer.history.v1"), bytes32(0));
        (IDiamondCut.FacetCut[] memory cut, address init, bytes memory data) =
            new PrepareStaticsExternalModulesUpgrade().deploy(address(diamond));
        assertEq(cut.length, 2);
        IDiamondCut(address(diamond)).diamondCut(cut, init, data);
        assertEq(nft.ownerOf(id), alice);
        assertEq(
            keccak256(abi.encode(IModularPositionNFT(address(diamond)).positionState(id))),
            keccak256(abi.encode(beforeState))
        );
        assertEq(ownerIndex.positionCount(alice), 1);
        assertTrue(IStaticsExternalModules(address(diamond)).historyCoverage(address(diamond)).ready);
        assertFalse(IStaticsExternalModules(address(diamond)).historyCoverage(address(0x123)).ready);
        vm.prank(alice);
        vm.expectRevert();
        positions.closePosition(id);
    }
}
