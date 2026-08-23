// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {IERC5192} from "../../src/interfaces/IERC5192.sol";
import {IStaticsCustody} from "../../src/interfaces/IStaticsCustody.sol";
import {IStaticsGenesisIntegration} from "../../src/interfaces/IStaticsGenesisIntegration.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {
    PrepareStaticsGenesisUpgrade,
    StaticsGenesisUpgradeParts
} from "../../script/PrepareStaticsGenesisUpgrade.s.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

contract GenesisUpgradeRehearsalTest is StaticsTestBase {
    function testUpgradePreservesExistingGlobalRewardState() public {
        stakingAsset.mint(alice, 100 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 100 ether);
        uint256 positionId = globalRewards.createAndStake(100 ether, alice, _asset(address(assetA)));
        vm.stopPrank();
        vm.startPrank(alice);
        IStaticsGlobalRewards.StakePositionView memory stakeBefore = globalRewards.stakePosition(positionId);
        IStaticsGlobalRewards.RewardSelectionView memory selectionBefore =
            globalRewards.rewardSelection(positionId, address(assetA));
        vm.stopPrank();
        IStaticsGlobalRewards.RewardAssetView memory bookBefore = globalRewards.rewardAsset(address(assetA));

        IDiamondCut.FacetCut[] memory removal = new IDiamondCut.FacetCut[](1);
        bytes4[] memory newSelectors = new bytes4[](4);
        newSelectors[0] = IStaticsGlobalRewards.checkpointRewardAssets.selector;
        newSelectors[1] = IStaticsGlobalRewards.rewardBookNeedsCheckpoint.selector;
        newSelectors[2] = IERC5192.locked.selector;
        newSelectors[3] = IStaticsCustody.genesisRewardCustodyAccount.selector;
        removal[0] = IDiamondCut.FacetCut({
            facetAddress: address(0), action: IDiamondCut.FacetCutAction.Remove, functionSelectors: newSelectors
        });
        IDiamondCut(address(diamond)).diamondCut(removal, address(0), "");
        assertEq(
            IDiamondLoupe(address(diamond)).facetAddress(IStaticsGenesisIntegration.registerGenesis.selector),
            address(0)
        );

        PrepareStaticsGenesisUpgrade preparer = new PrepareStaticsGenesisUpgrade();
        StaticsGenesisUpgradeParts memory parts = preparer.deploy();
        IDiamondCut(address(diamond)).diamondCut(preparer.buildCut(parts), address(0), "");

        vm.startPrank(alice);
        IStaticsGlobalRewards.StakePositionView memory stakeAfter = globalRewards.stakePosition(positionId);
        IStaticsGlobalRewards.RewardSelectionView memory selectionAfter =
            globalRewards.rewardSelection(positionId, address(assetA));
        vm.stopPrank();
        IStaticsGlobalRewards.RewardAssetView memory bookAfter = globalRewards.rewardAsset(address(assetA));
        assertEq(stakeAfter.stakedBalance, stakeBefore.stakedBalance);
        assertEq(stakeAfter.rewardMultiplierBps, stakeBefore.rewardMultiplierBps);
        assertEq(selectionAfter.pendingStake, selectionBefore.pendingStake);
        assertEq(selectionAfter.pendingWeight, selectionBefore.pendingWeight);
        assertEq(selectionAfter.eligibleAt, selectionBefore.eligibleAt);
        assertEq(bookAfter.pendingStake, bookBefore.pendingStake);
        assertEq(bookAfter.pendingWeight, bookBefore.pendingWeight);
        assertEq(globalRewards.totalStaked(), 100 ether);
        assertFalse(IStaticsGenesisIntegration(address(diamond)).genesisIntegrationReady());
        assertTrue(
            IDiamondLoupe(address(diamond)).facetAddress(IStaticsGenesisIntegration.registerGenesis.selector)
                != address(0)
        );
    }

    function _asset(address asset) private pure returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = asset;
    }

    function _installLocalLiquidityIntegration() internal pure override returns (bool) {
        return false;
    }
}
