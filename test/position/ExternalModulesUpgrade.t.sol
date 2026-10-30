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
        uint256 historyRoot = uint256(keccak256("statics.storage.nft.transfer.history.v1"));
        // Only minting has occurred: no journal or per-NFT transfer entries exist.
        vm.store(address(diamond), bytes32(historyRoot), 0);
        uint256 coverageSlot = uint256(keccak256(abi.encode(address(diamond), historyRoot + 2)));
        for (uint256 field; field < 3; ++field) {
            vm.store(address(diamond), bytes32(coverageSlot + field), 0);
        }
        vm.roll(block.number + 100);
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
        assertEq(IStaticsExternalModules(address(diamond)).historyCoverage(address(diamond)).startBlock, block.number);
        vm.prank(alice);
        vm.expectRevert();
        positions.closePosition(id);
    }
}
