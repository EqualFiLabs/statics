// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsRewardSelectionTiming} from "../../src/interfaces/IStaticsRewardSelectionTiming.sol";
import {PositionMarketFacet} from "../../src/facets/PositionMarketFacet.sol";
import {StaticsInterfaceInit} from "../../src/diamond/StaticsInterfaceInit.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

contract RewardSelectionTimingTest is StaticsTestBase {
    function testFreshPendingStartIsExactBeforeRoundedMaturity() public {
        vm.warp(30 days + 17 minutes);
        uint256 id = _stake(10 ether);
        (IStaticsGlobalRewards.RewardSelectionView memory selection, uint40 start) = _read(id);
        assertEq(start, 30 days + 17 minutes);
        assertEq(selection.eligibleAt, 31 days + 1 hours);
        _assertLegacyParity(id, selection);
        vm.warp(selection.eligibleAt - 1);
        (, uint40 beforeMaturity) = _read(id);
        assertEq(beforeMaturity, start);
        vm.warp(selection.eligibleAt);
        (selection, start) = _read(id);
        assertEq(selection.pendingStake, 0);
        assertEq(selection.eligibleStake, 10 ether);
        assertEq(start, 0);
        _assertLegacyParity(id, selection);
    }

    function testFuzzTopUpReportsWeightedStart(uint256 initialAmount, uint256 addedAmount, uint256 elapsed) public {
        initialAmount = bound(initialAmount, 1, 1e24);
        addedAmount = bound(addedAmount, 1, 1e24);
        elapsed = bound(elapsed, 0, 24 hours - 1);
        vm.warp(30 days + 17 minutes);
        uint256 initialStart = block.timestamp;
        uint256 id = _stake(initialAmount);
        vm.warp(initialStart + elapsed);
        _topUp(id, addedAmount);
        (IStaticsGlobalRewards.RewardSelectionView memory selection, uint40 start) = _read(id);
        uint256 expectedStart =
            initialStart + elapsed - Math.mulDiv(initialAmount, elapsed, initialAmount + addedAmount);
        assertEq(start, expectedStart);
        assertEq(selection.eligibleAt, Math.ceilDiv(expectedStart + 24 hours, 1 hours) * 1 hours);
        assertEq(selection.pendingStake, initialAmount + addedAmount);
        _assertLegacyParity(id, selection);
    }

    function testPendingTopUpCapsAgeCreditBeforeRoundedMaturity() public {
        vm.warp(30 days + 17 minutes);
        uint256 id = _stake(10 ether);
        vm.warp(block.timestamp + 24 hours + 10 minutes);
        _topUp(id, 10 ether);
        (IStaticsGlobalRewards.RewardSelectionView memory selection, uint40 start) = _read(id);
        assertEq(start, block.timestamp - 12 hours);
        assertEq(selection.pendingStake, 20 ether);
        _assertLegacyParity(id, selection);
    }

    function testAssetTimingIsIndependentAndOptOutResetsStart() public {
        vm.warp(30 days + 17 minutes);
        uint256 id = _stake(10 ether);
        uint256 firstStart = block.timestamp;
        vm.warp(block.timestamp + 4 hours);
        address[] memory secondAsset = new address[](1);
        secondAsset[0] = address(assetB);
        vm.prank(alice);
        globalRewards.optInRewardAssets(id, secondAsset);
        (, uint40 startA) = _read(id);
        (, uint40 startB) =
            IStaticsRewardSelectionTiming(address(diamond)).rewardSelectionWithTiming(id, address(assetB));
        assertEq(startA, firstStart);
        assertEq(startB, block.timestamp);
        vm.prank(alice);
        globalRewards.optOutRewardAssets(id, secondAsset);
        (, startB) = IStaticsRewardSelectionTiming(address(diamond)).rewardSelectionWithTiming(id, address(assetB));
        assertEq(startB, 0);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        globalRewards.optInRewardAssets(id, secondAsset);
        (, startB) = IStaticsRewardSelectionTiming(address(diamond)).rewardSelectionWithTiming(id, address(assetB));
        assertEq(startB, block.timestamp);
        (, startA) = _read(id);
        assertEq(startA, firstStart);
    }

    function testReadDoesNotRollStorageAndNewStakeStartsFreshAfterMaturity() public {
        vm.warp(30 days);
        uint256 id = _stake(10 ether);
        (IStaticsGlobalRewards.RewardSelectionView memory selection,) = _read(id);
        vm.warp(selection.eligibleAt);
        vm.record();
        (, uint40 start) = _read(id);
        (, bytes32[] memory writes) = vm.accesses(address(diamond));
        assertEq(writes.length, 0);
        assertEq(start, 0);
        _topUp(id, 1 ether);
        (selection, start) = _read(id);
        assertEq(start, block.timestamp);
        assertEq(selection.pendingStake, 1 ether);
        assertEq(selection.eligibleStake, 10 ether);
        _assertLegacyParity(id, selection);
    }

    function testUnstakePreservesPendingStartThenClearsEffectiveSelection() public {
        vm.warp(30 days + 17 minutes);
        uint256 id = _stake(10 ether);
        vm.prank(alice);
        globalRewards.unstake(id, 4 ether, alice);
        (IStaticsGlobalRewards.RewardSelectionView memory selection, uint40 start) = _read(id);
        assertEq(start, 30 days + 17 minutes);
        assertEq(selection.pendingStake, 6 ether);
        vm.prank(alice);
        globalRewards.unstake(id, 6 ether, alice);
        (selection, start) = _read(id);
        assertFalse(selection.selected);
        assertEq(start, 0);
        _assertLegacyParity(id, selection);
    }

    function testUnselectedAssetsReturnZeroTiming() public {
        uint256 id = _stake(10 ether);
        (IStaticsGlobalRewards.RewardSelectionView memory selection, uint40 start) =
            IStaticsRewardSelectionTiming(address(diamond)).rewardSelectionWithTiming(id, address(assetB));
        assertFalse(selection.selected);
        assertEq(selection.pendingStake, 0);
        assertEq(start, 0);
    }

    function testPublicReadFollowsTransferredPositionAndRejectsMissingNft() public {
        uint256 id = _stake(10 ether);
        vm.prank(bob);
        (IStaticsGlobalRewards.RewardSelectionView memory selection, uint40 start) = _read(id);
        vm.prank(alice);
        IERC721(address(diamond)).transferFrom(alice, bob, id);
        vm.prank(alice);
        (IStaticsGlobalRewards.RewardSelectionView memory transferred, uint40 transferredStart) = _read(id);
        assertEq(abi.encode(selection), abi.encode(transferred));
        assertEq(start, transferredStart);
        vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", type(uint256).max));
        _read(type(uint256).max);
    }

    function testAdditiveUpgradeRetainsPopulatedSelections() public {
        vm.warp(30 days + 17 minutes);
        uint256 id = _stake(10 ether);
        IStaticsGlobalRewards.RewardSelectionView memory beforeSelection =
            globalRewards.rewardSelection(id, address(assetA));
        bytes4[] memory timing = new bytes4[](1);
        timing[0] = IStaticsRewardSelectionTiming.rewardSelectionWithTiming.selector;
        IDiamondCut.FacetCut[] memory remove = new IDiamondCut.FacetCut[](1);
        remove[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, timing);
        StaticsInterfaceInit init = new StaticsInterfaceInit();
        bool[] memory supported = new bool[](1);
        IDiamondCut(address(diamond))
            .diamondCut(remove, address(init), abi.encodeCall(init.setInterfaces, (timing, supported)));
        assertFalse(IERC165(address(diamond)).supportsInterface(timing[0]));

        // Emulate the prior installation: nine existing routes, populated reward storage, no timing route.
        bytes4[] memory existing = StaticsSelectors.positionMarket();
        assembly ("memory-safe") { mstore(existing, sub(mload(existing), 1)) }
        address replacement = address(new PositionMarketFacet());
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](2);
        cut[0] = IDiamondCut.FacetCut(replacement, IDiamondCut.FacetCutAction.Replace, existing);
        cut[1] = IDiamondCut.FacetCut(replacement, IDiamondCut.FacetCutAction.Add, timing);
        supported[0] = true;
        IDiamondCut(address(diamond))
            .diamondCut(cut, address(init), abi.encodeCall(init.setInterfaces, (timing, supported)));
        assertTrue(IERC165(address(diamond)).supportsInterface(timing[0]));
        (IStaticsGlobalRewards.RewardSelectionView memory selection, uint40 start) = _read(id);
        assertEq(abi.encode(selection), abi.encode(beforeSelection));
        assertEq(start, 30 days + 17 minutes);
        _assertLegacyParity(id, selection);
    }

    function testSolidityTimingEncodingFixture() public {
        bytes memory callData =
            abi.encodeCall(IStaticsRewardSelectionTiming.rewardSelectionWithTiming, (uint256(7), address(0x22)));
        IStaticsGlobalRewards.RewardSelectionView memory selection = IStaticsGlobalRewards.RewardSelectionView({
            selected: true,
            eligibleStake: 50 ether,
            eligibleWeight: 50 ether,
            pendingStake: 100 ether,
            pendingWeight: 100 ether,
            eligibleAt: 123456
        });
        emit log_named_bytes("timingCalldata", callData);
        emit log_named_bytes("timingResult", abi.encode(selection, uint40(23456)));
    }

    function _stake(uint256 amount) private returns (uint256 id) {
        stakingAsset.mint(alice, amount);
        address[] memory assets = new address[](1);
        assets[0] = address(assetA);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), amount);
        id = globalRewards.createAndStake(amount, alice, assets);
        vm.stopPrank();
    }

    function _topUp(uint256 id, uint256 amount) private {
        stakingAsset.mint(alice, amount);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), amount);
        globalRewards.stake(id, amount);
        vm.stopPrank();
    }

    function _read(uint256 id)
        private
        view
        returns (IStaticsGlobalRewards.RewardSelectionView memory selection, uint40 start)
    {
        return IStaticsRewardSelectionTiming(address(diamond)).rewardSelectionWithTiming(id, address(assetA));
    }

    function _assertLegacyParity(uint256 id, IStaticsGlobalRewards.RewardSelectionView memory selection) private view {
        assertEq(abi.encode(selection), abi.encode(globalRewards.rewardSelection(id, address(assetA))));
    }
}
