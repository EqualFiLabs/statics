// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {IERC5192} from "../../src/interfaces/IERC5192.sol";
import {IStaticsCustody} from "../../src/interfaces/IStaticsCustody.sol";
import {IStaticsGenesisIntegration} from "../../src/interfaces/IStaticsGenesisIntegration.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsPosition} from "../../src/interfaces/IStaticsPosition.sol";
import {
    PrepareStaticsGenesisUpgrade,
    StaticsGenesisUpgradeParts
} from "../../script/PrepareStaticsGenesisUpgrade.s.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";
import {LegacyGlobalRewardsSeeder} from "../helpers/LegacyGlobalRewardsSeeder.sol";

contract GenesisUpgradeRehearsalTest is StaticsTestBase {
    uint256 private constant LEGACY_TOTAL_STAKED = 150 ether;
    uint256 private constant LEGACY_ASSET_A_CLAIM = 111 ether;
    uint256 private constant LEGACY_ASSET_B_CLAIM = 172 ether;

    function testUpgradePreservesExactPreGenesisGlobalRewardLayout() public {
        vm.warp(30 days);
        vm.prank(alice);
        uint256 positionId = IStaticsPosition(address(diamond)).createPosition(alice);
        uint40 pendingEligibleAt = uint40(block.timestamp + 24 hours);

        LegacyGlobalRewardsSeeder writer = _installLegacyWriter();
        writer.seedLegacyGlobalRewards(positionId, address(assetA), address(assetB), pendingEligibleAt);
        assertEq(writer.legacyPendingBucket(address(assetA), 5), 50 ether);
        _reserveLegacyClaims(writer);

        _restorePreGenesisSelectorSet();
        assertEq(
            IDiamondLoupe(address(diamond)).facetAddress(IStaticsGenesisIntegration.registerGenesis.selector),
            address(0)
        );

        PrepareStaticsGenesisUpgrade preparer = new PrepareStaticsGenesisUpgrade();
        StaticsGenesisUpgradeParts memory parts = preparer.deploy();
        IDiamondCut(address(diamond)).diamondCut(preparer.buildCut(parts), address(0), "");

        _assertLegacyStateBeforeLazyMigration(positionId, pendingEligibleAt);
        address[] memory assets = _assets();
        assertTrue(globalRewards.rewardBookNeedsCheckpoint(address(assetA)));
        assertTrue(globalRewards.rewardBookNeedsCheckpoint(address(assetB)));
        globalRewards.checkpointRewardAssets(assets);
        assertFalse(globalRewards.rewardBookNeedsCheckpoint(address(assetA)));
        assertFalse(globalRewards.rewardBookNeedsCheckpoint(address(assetB)));

        vm.warp(pendingEligibleAt);
        assertTrue(globalRewards.rewardBookNeedsCheckpoint(address(assetA)));
        globalRewards.checkpointRewardAssets(_singleAsset(address(assetA)));
        _assertLegacyClaimsAndMaturity(positionId, assets);

        assertFalse(IStaticsGenesisIntegration(address(diamond)).genesisIntegrationReady());
        assertTrue(
            IDiamondLoupe(address(diamond)).facetAddress(IStaticsGenesisIntegration.registerGenesis.selector)
                != address(0)
        );
    }

    function _installLegacyWriter() private returns (LegacyGlobalRewardsSeeder writer) {
        writer = new LegacyGlobalRewardsSeeder();
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = LegacyGlobalRewardsSeeder.seedLegacyGlobalRewards.selector;
        selectors[1] = LegacyGlobalRewardsSeeder.reserveLegacyRewardAsset.selector;
        selectors[2] = LegacyGlobalRewardsSeeder.legacyPendingBucket.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(writer), action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        writer = LegacyGlobalRewardsSeeder(address(diamond));
    }

    function _reserveLegacyClaims(LegacyGlobalRewardsSeeder writer) private {
        assetA.mint(address(this), 1_000 ether);
        assetB.mint(address(this), 2_000 ether);
        assetA.approve(address(diamond), 1_000 ether);
        assetB.approve(address(diamond), 2_000 ether);
        writer.reserveLegacyRewardAsset(address(assetA), 1_000 ether);
        writer.reserveLegacyRewardAsset(address(assetB), 2_000 ether);
    }

    function _restorePreGenesisSelectorSet() private {
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = IStaticsGlobalRewards.checkpointRewardAssets.selector;
        selectors[1] = IStaticsGlobalRewards.rewardBookNeedsCheckpoint.selector;
        selectors[2] = IERC5192.locked.selector;
        selectors[3] = IStaticsCustody.genesisRewardCustodyAccount.selector;
        selectors[4] = LegacyGlobalRewardsSeeder.seedLegacyGlobalRewards.selector;
        selectors[5] = LegacyGlobalRewardsSeeder.reserveLegacyRewardAsset.selector;
        selectors[6] = LegacyGlobalRewardsSeeder.legacyPendingBucket.selector;
        IDiamondCut.FacetCut[] memory removal = new IDiamondCut.FacetCut[](1);
        removal[0] = IDiamondCut.FacetCut({
            facetAddress: address(0), action: IDiamondCut.FacetCutAction.Remove, functionSelectors: selectors
        });
        IDiamondCut(address(diamond)).diamondCut(removal, address(0), "");
    }

    function _assertLegacyStateBeforeLazyMigration(uint256 positionId, uint40 pendingEligibleAt) private {
        vm.startPrank(alice);
        IStaticsGlobalRewards.StakePositionView memory stake = globalRewards.stakePosition(positionId);
        IStaticsGlobalRewards.RewardSelectionView memory selectionA =
            globalRewards.rewardSelection(positionId, address(assetA));
        IStaticsGlobalRewards.RewardSelectionView memory selectionB =
            globalRewards.rewardSelection(positionId, address(assetB));
        uint256[] memory pending = globalRewards.pendingRewards(positionId, _assets());
        address[] memory selected = globalRewards.positionRewardAssets(positionId);
        vm.stopPrank();

        assertEq(globalRewards.totalStaked(), LEGACY_TOTAL_STAKED);
        assertEq(stake.stakedBalance, LEGACY_TOTAL_STAKED);
        assertEq(stake.rewardMultiplierBps, 10_000);
        assertEq(stake.claimAssetCount, 2);
        assertEq(stake.optedInAssetCount, 2);
        assertEq(selected.length, 2);
        assertEq(selected[0], address(assetA));
        assertEq(selected[1], address(assetB));

        assertTrue(selectionA.selected);
        assertEq(selectionA.eligibleStake, 100 ether);
        assertEq(selectionA.eligibleWeight, 100 ether);
        assertEq(selectionA.pendingStake, 50 ether);
        assertEq(selectionA.pendingWeight, 50 ether);
        assertEq(selectionA.eligibleAt, pendingEligibleAt);
        assertTrue(selectionB.selected);
        assertEq(selectionB.eligibleStake, 150 ether);
        assertEq(selectionB.eligibleWeight, 150 ether);
        assertEq(selectionB.pendingStake, 0);

        IStaticsGlobalRewards.RewardAssetView memory bookA = globalRewards.rewardAsset(address(assetA));
        IStaticsGlobalRewards.RewardAssetView memory bookB = globalRewards.rewardAsset(address(assetB));
        assertEq(bookA.eligibleStake, 100 ether);
        assertEq(bookA.eligibleWeight, 100 ether);
        assertEq(bookA.pendingStake, 50 ether);
        assertEq(bookA.pendingWeight, 50 ether);
        assertEq(bookA.indexRay, 5e27);
        assertEq(bookA.indexedReserve, 1_000 ether);
        assertEq(bookA.totalClaimable, 11 ether);
        assertEq(bookB.eligibleStake, 150 ether);
        assertEq(bookB.eligibleWeight, 150 ether);
        assertEq(bookB.indexRay, 8e27);
        assertEq(bookB.indexedReserve, 2_000 ether);
        assertEq(bookB.totalClaimable, 22 ether);
        assertEq(globalRewards.treasuryAccrued(address(assetA)), 13 ether);
        assertEq(globalRewards.treasuryAccrued(address(assetB)), 17 ether);
        assertEq(pending[0], LEGACY_ASSET_A_CLAIM);
        assertEq(pending[1], LEGACY_ASSET_B_CLAIM);
    }

    function _assertLegacyClaimsAndMaturity(uint256 positionId, address[] memory assets) private {
        vm.prank(alice);
        IStaticsGlobalRewards.RewardSelectionView memory matured =
            globalRewards.rewardSelection(positionId, address(assetA));
        assertEq(matured.eligibleStake, 150 ether);
        assertEq(matured.eligibleWeight, 150 ether);
        assertEq(matured.pendingStake, 0);
        assertEq(matured.pendingWeight, 0);
        assertEq(matured.eligibleAt, 0);

        uint256[] memory minimums = new uint256[](2);
        minimums[0] = LEGACY_ASSET_A_CLAIM;
        minimums[1] = LEGACY_ASSET_B_CLAIM;
        vm.prank(alice);
        uint256[] memory claimed = globalRewards.claimRewards(positionId, assets, alice, minimums);
        assertEq(claimed[0], LEGACY_ASSET_A_CLAIM);
        assertEq(claimed[1], LEGACY_ASSET_B_CLAIM);
        assertEq(globalRewards.rewardAsset(address(assetA)).totalClaimable, 0);
        assertEq(globalRewards.rewardAsset(address(assetB)).totalClaimable, 0);
    }

    function _assets() private view returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = address(assetA);
        assets[1] = address(assetB);
    }

    function _singleAsset(address asset) private pure returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = asset;
    }

    function _installLocalLiquidityIntegration() internal pure override returns (bool) {
        return false;
    }
}
