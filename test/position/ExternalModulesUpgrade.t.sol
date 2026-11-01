// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PositionNFTTest} from "./PositionNFT.t.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IModularPositionNFT} from "../../src/interfaces/IModularPositionNFT.sol";
import {IStaticsExternalModules} from "../../src/interfaces/IStaticsExternalModules.sol";
import {StaticsInterfaceInit} from "../../src/diamond/StaticsInterfaceInit.sol";
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
        address beforePositionFacet = IDiamondLoupe(address(diamond)).facetAddress(positions.closePosition.selector);
        // The partial fixture uses current interface initialization. Model an older Diamond by
        // clearing only the newly introduced ERC-165 flag through the governed interface setter.
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = type(IStaticsExternalModules).interfaceId;
        IDiamondCut(address(diamond))
            .diamondCut(
                new IDiamondCut.FacetCut[](0),
                address(new StaticsInterfaceInit()),
                abi.encodeCall(StaticsInterfaceInit.setInterfaces, (ids, new bool[](1)))
            );
        assertFalse(IERC165(address(diamond)).supportsInterface(ids[0]));
        (IDiamondCut.FacetCut[] memory cut, address init, bytes memory data) =
            new PrepareStaticsExternalModulesUpgrade().deploy();
        assertEq(cut.length, 1);
        assertEq(cut[0].functionSelectors.length, 7);
        assertEq(uint256(cut[0].action), uint256(IDiamondCut.FacetCutAction.Add));
        vm.prank(alice);
        vm.expectRevert();
        IDiamondCut(address(diamond)).diamondCut(cut, init, data);
        assertFalse(IERC165(address(diamond)).supportsInterface(ids[0]));
        IDiamondCut(address(diamond)).diamondCut(cut, init, data);
        assertEq(IDiamondLoupe(address(diamond)).facetAddress(positions.closePosition.selector), beforePositionFacet);
        assertEq(nft.ownerOf(id), alice);
        assertEq(
            keccak256(abi.encode(IModularPositionNFT(address(diamond)).positionState(id))),
            keccak256(abi.encode(beforeState))
        );
        assertEq(ownerIndex.positionCount(alice), 1);
        assertTrue(IERC165(address(diamond)).supportsInterface(ids[0]));
        IStaticsExternalModules core = IStaticsExternalModules(address(diamond));
        bytes32 moduleType = keccak256("upgrade.module");
        core.setExternalModule(address(this), moduleType, true);
        core.attachExternalAccountLeg(id, moduleType, bytes32(id));
        vm.startPrank(alice);
        moduleHarness.deactivate(id, BASKET, bytes32(uint256(7)));
        moduleHarness.resolveObligation(id);
        vm.expectRevert();
        positions.closePosition(id);
        vm.stopPrank();
        core.detachExternalAccountLeg(id, moduleType, bytes32(id));
        vm.prank(alice);
        positions.closePosition(id);
    }
}
